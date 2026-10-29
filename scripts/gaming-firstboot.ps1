<#
.SYNOPSIS
    Tiny11 Core-Gaming first-boot payload.

.DESCRIPTION
    Executed once, as SYSTEM, by Windows\Setup\Scripts\SetupComplete.cmd at the end of
    Windows Setup - before the first logon. Everything here needs a live, elevated OS,
    which is why it cannot be baked into the offline image:

      * powercfg   - the scheme GUID is generated per machine
      * bcdedit    - the BCD store is not part of install.wim
      * NIC tweaks - adapter GUIDs do not exist until the driver is enumerated
      * MSI / USB  - the PnP tree of the target machine does not exist offline either

    Per-user settings (mouse, FSO, GPU preference) are NOT here - they are written into
    the Default user hive by the builder, so every new profile inherits them.

    This script also runs the first-boot half of the essentials pass (hibernation off,
    temp cleanup, baseline restore point, process count). That stage is unconditional:
    the essentials layer has no group flag, unlike every gaming group below.

    Safe to re-run manually: pass -Force to ignore the completion marker.

.PARAMETER GamingDir
    Directory holding this script and the power config.

.PARAMETER Force
    Re-run even if the completion marker exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\gaming-firstboot.ps1 -Force

.NOTES
    Author: Sensei002 (https://github.com/Sensei002)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$GamingDir = (Join-Path $env:WINDIR 'Tiny11Gaming'),
    [switch]$Force,
    # Boot-guard mode, used only when the image shipped with the update stack removed.
    # Invoked by the WindowsUpdateGuard scheduled task on every boot to re-assert a
    # state that Windows actively repairs. Not for interactive use - it deliberately
    # ignores the completion marker.
    [switch]$WuGuard
)

$ErrorActionPreference = 'Continue'

$script:LogFile = Join-Path $GamingDir 'gaming-firstboot.log'
$script:Marker = Join-Path $GamingDir '.firstboot-done'
$script:Failures = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Output $line
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Write-Section {
    param([string]$Title)
    Write-Log ('-' * 60)
    Write-Log $Title
    Write-Log ('-' * 60)
}

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

#---------[ Power scheme ]---------#

function New-GamingPowerScheme {
    param(
        [string]$ConfigPath,
        [hashtable]$Groups
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Power config not found at $ConfigPath - skipping power scheme" 'WARN'
        $script:Failures++
        return $null
    }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    # 1. Duplicate a base template. The GUID returned differs on every machine, so we
    #    parse it out of powercfg's output rather than assuming one.
    $candidates = @($cfg.baseTemplate.guid)
    foreach ($fallback in $cfg.baseTemplate.fallbacks) { $candidates += $fallback.guid }

    $schemeGuid = $null
    foreach ($candidate in $candidates) {
        $output = & powercfg -duplicatescheme $candidate 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $output -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $schemeGuid = $matches[1]
            Write-Log "Duplicated base template $candidate -> $schemeGuid"
            break
        }
        Write-Log "Base template $candidate unavailable, trying next" 'WARN'
    }

    if (-not $schemeGuid) {
        Write-Log "Could not duplicate any base power template - power scheme skipped" 'ERROR'
        $script:Failures++
        return $null
    }

    # 2. Name it. This is a genuinely new scheme, not a renamed Ultimate Performance.
    & powercfg -changename $schemeGuid $cfg.schemeName $cfg.schemeDescription 2>&1 | Out-Null
    Write-Log "Scheme renamed to '$($cfg.schemeName)'"

    # 3. Apply every setting the profile has enabled.
    $applied = 0
    $skipped = 0
    foreach ($setting in $cfg.settings) {
        $group = $setting.group
        if ($group -and $Groups -and $Groups.ContainsKey($group) -and -not $Groups[$group]) {
            $skipped++
            continue
        }

        # Some settings ship hidden and cannot be written until unhidden.
        if ($setting.hidden) {
            & powercfg -attributes $setting.subgroup $setting.setting -ATTRIB_HIDE 2>&1 | Out-Null
        }

        & powercfg -setacvalueindex $schemeGuid $setting.subgroup $setting.setting $setting.ac 2>&1 | Out-Null
        $acOk = ($LASTEXITCODE -eq 0)
        & powercfg -setdcvalueindex $schemeGuid $setting.subgroup $setting.setting $setting.dc 2>&1 | Out-Null
        $dcOk = ($LASTEXITCODE -eq 0)

        if ($acOk -or $dcOk) {
            $applied++
            Write-Log "  $($setting.name) = $($setting.ac)"
        } else {
            Write-Log "  $($setting.name): not supported on this platform (skipped)" 'WARN'
        }
    }

    # 4. Activate.
    & powercfg -setactive $schemeGuid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Activated '$($cfg.schemeName)' ($applied settings applied, $skipped skipped)"
    } else {
        Write-Log "Failed to activate the gaming power scheme" 'ERROR'
        $script:Failures++
    }

    # 5. Export for portability so the user can move the scheme to another machine.
    $powPath = Join-Path $GamingDir 'Atlas-Power-Scheme.pow'
    & powercfg -export $powPath $schemeGuid 2>&1 | Out-Null
    if (Test-Path -LiteralPath $powPath) {
        Write-Log "Exported scheme to $powPath"
    }

    return $schemeGuid
}

function Test-GamingPowerScheme {
    # Reads the effective values back out of the activated scheme and reports them.
    #
    # The apply loop above counts a setting as applied when either the AC or the DC
    # write returned 0, which is enough to know powercfg accepted the call but not
    # enough to know the platform honoured it. A silently unapplied value is exactly
    # how a CPU ends up pinned below its rated frequency with no visible error, so
    # the four values that set the clock floor and ceiling are asserted, not assumed.
    #
    # The floor matters as much as the ceiling: a scheme with maximum state 100 but
    # minimum state 5 passes every ceiling check while idling at its lowest P-state,
    # which reads as "the CPU is not reaching its rated clock". Minimum processor
    # state is the value that actually holds a 3.6 GHz part at 3.6 GHz, and it was
    # the one thing this function did not look at.
    param([string]$SchemeGuid)

    if (-not $SchemeGuid) { return }

    $query = & powercfg -query $SchemeGuid 2>&1 | Out-String
    if (-not $query) {
        Write-Log "  could not read the scheme back - clock verification skipped" 'WARN'
        return
    }

    $checks = @(
        @{ Name = 'Minimum processor state';           Guid = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Expected = 100 },
        @{ Name = 'Maximum processor state';           Guid = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Expected = 100 },
        @{ Name = 'Processor performance boost mode';  Guid = 'be337238-0d82-4146-a960-4f3749d470c7'; Expected = 1   },
        @{ Name = 'Processor performance boost policy';Guid = '45bcc044-d885-43e2-8605-ee0ec6e96b59'; Expected = 100 }
    )

    foreach ($check in $checks) {
        # powercfg prints the setting GUID in the header line, then the effective
        # values a few lines below it.
        $pattern = [regex]::Escape($check.Guid) + '[\s\S]{0,800}?Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)'
        $match = [regex]::Match($query, $pattern)
        if (-not $match.Success) {
            Write-Log "  $($check.Name): not exposed on this platform (skipped)" 'WARN'
            continue
        }

        $actual = [Convert]::ToInt32($match.Groups[1].Value, 16)
        if ($actual -eq $check.Expected) {
            Write-Log "  verified: $($check.Name) = $actual"
        } else {
            Write-Log "  MISMATCH: $($check.Name) = $actual, expected $($check.Expected) - the CPU will not reach its rated clock" 'WARN'
            $script:Failures++
        }
    }
}

#---------[ BCD ]---------#

function Set-GamingBootConfiguration {
    param(
        [string]$ConfigPath,
        [hashtable]$Groups
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    foreach ($entry in $cfg.bcd) {
        $group = $entry.group
        if ($group -and $Groups -and $Groups.ContainsKey($group) -and -not $Groups[$group]) {
            Write-Log "  bcdedit $($entry.args) skipped (group '$group' disabled)"
            continue
        }

        $parts = $entry.args -split '\s+'
        & bcdedit @parts 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  bcdedit $($entry.args)"
        } elseif ($entry.ignoreFailure) {
            # '/deletevalue' on a value that was never set is the expected outcome,
            # not a problem - reporting it as a warning would train people to ignore
            # the log.
            Write-Log "  bcdedit $($entry.args) - nothing to remove (already absent)"
        } else {
            Write-Log "  bcdedit $($entry.args) failed (may not apply on this firmware)" 'WARN'
        }
    }
}

#---------[ Network latency ]---------#

function Set-GamingNetworkTweaks {
    # Per-adapter TCP values. The builder already wrote the global defaults; these are
    # per-interface and therefore only exist once the adapter has been enumerated.
    $interfaces = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $count = 0
    Get-ChildItem -Path $interfaces -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay'      -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name 'TCPDelAckTicks'  -Value 0 -Type DWord -ErrorAction SilentlyContinue
        $count++
    }
    Write-Log "  Nagle / delayed-ACK disabled on $count network interface(s)"

    # Disable "allow the computer to turn off this device to save power" for every NIC.
    $nicClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $nics = 0
    Get-ChildItem -Path $nicClass -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord -ErrorAction SilentlyContinue
            # Wireless adapters additionally expose a power-save mode; 0 = max performance.
            Set-ItemProperty -Path $_.PSPath -Name '*PowerSaveMode' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            $nics++
        }
    Write-Log "  NIC power management disabled on $nics adapter(s)"
}

#---------[ Device-level latency (interrupt_latency) ]---------#
#
# Everything below needs enumerated devices, so it cannot be baked into the image.
# It is also the half of the profile that Core cannot do at all: Core works on
# install.wim, where the PnP tree of the target machine does not exist yet.
#
# The target is 1% lows, not average FPS. Average FPS is set by the GPU and the
# CPU frequency; 1% lows are set by how long a frame waits for something else to
# finish - a DPC, an interrupt shared with another device, a NIC that batched its
# packets, a storage link that had to wake up. That is what these four functions
# address.

function Set-GamingInterruptLatency {
    # MSI (message-signalled interrupts) replace line-based interrupts with a
    # memory write, so a device no longer shares an IRQ line with whatever else
    # the firmware happened to put there. A shared line means one device's ISR
    # delays another's, which is exactly how a GPU frame gets held up by a NIC.
    #
    # Safety: only devices that already publish MessageSignaledInterruptProperties
    # are touched. That key is written by a driver that supports MSI, so a device
    # that cannot do MSI is never forced into it. A device that rejects the flag
    # keeps its line interrupt and still boots - this cannot brick anything.
    #
    # DevicePolicy (interrupt affinity) is deliberately NOT set. Pinning a GPU's
    # interrupts to specific cores is a per-machine experiment whose right answer
    # depends on the core topology; a wrong default here is worse than the machine
    # default Windows already picks.
    $classGuids = @{
        '{4d36e968-e325-11ce-bfc1-08002be10318}' = 'display'
        '{4d36e972-e325-11ce-bfc1-08002be10318}' = 'network'
        '{36fc9e60-c465-11cf-8056-444553540000}' = 'USB controller'
        '{4d36e96c-e325-11ce-bfc1-08002be10318}' = 'audio'
    }

    $enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
    if (-not (Test-Path -LiteralPath $enumRoot)) {
        Write-Log "  PCI enumeration key not found - MSI mode skipped" 'WARN'
        return
    }

    $changed = 0
    $alreadyMsi = 0

    foreach ($device in (Get-ChildItem -Path $enumRoot -ErrorAction SilentlyContinue)) {
        foreach ($instance in (Get-ChildItem -Path $device.PSPath -ErrorAction SilentlyContinue)) {
            $classGuid = $null
            $desc = $null
            try {
                $props = Get-ItemProperty -Path $instance.PSPath -ErrorAction Stop
                $classGuid = $props.ClassGUID
                # Instance keys carry DeviceDesc, not DriverDesc; FriendlyName is the
                # only human-readable one and is not always present.
                $desc = $props.FriendlyName
                if (-not $desc) { $desc = $props.DeviceDesc }
                if (-not $desc) { $desc = $props.Service }
                if (-not $desc) { $desc = $instance.PSChildName }
            } catch {
                continue
            }

            if (-not $classGuid) { continue }
            $classGuid = $classGuid.ToLower()
            if (-not $classGuids.ContainsKey($classGuid)) { continue }

            $msiKey = "$($instance.PSPath)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            if (-not (Test-Path -LiteralPath $msiKey)) { continue }

            $current = $null
            try {
                $current = (Get-ItemProperty -Path $msiKey -Name 'MSISupported' -ErrorAction Stop).MSISupported
            } catch { }

            if ($current -eq 1) {
                $alreadyMsi++
            } else {
                try {
                    New-ItemProperty -Path $msiKey -Name 'MSISupported' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    $changed++
                    Write-Log "  MSI on: $desc"
                } catch {
                    Write-Log "  MSI refused by $desc ($_)" 'WARN'
                    continue
                }
            }

            # Priority is a hint the kernel honours when two ISRs are ready at once.
            # 'High' is what the GPU and the NIC want; everything else keeps Normal.
            if ($classGuids[$classGuid] -eq 'display' -or $classGuids[$classGuid] -eq 'network') {
                $affinityKey = "$($instance.PSPath)\Device Parameters\Interrupt Management\Affinity Policy"
                try {
                    if (-not (Test-Path -LiteralPath $affinityKey)) {
                        New-Item -Path $affinityKey -Force -ErrorAction Stop | Out-Null
                    }
                    New-ItemProperty -Path $affinityKey -Name 'DevicePriority' -Value 'High' -PropertyType String -Force -ErrorAction Stop | Out-Null
                } catch {
                    Write-Log "  could not set interrupt priority on $desc ($_)" 'WARN'
                }
            }
        }
    }

    Write-Log "  MSI enabled on $changed device(s); $alreadyMsi already had it"
}

function Set-GamingNetworkAdapter {
    # Driver-level knobs that only exist once the adapter is enumerated. Each is
    # written independently and failures are counted, not thrown: an adapter that
    # does not expose '*RSS' is normal (most Wi-Fi and USB dongles), not an error.
    #
    # -NoRestart on purpose. SetupComplete runs before the first logon and the
    # settings are read by the driver at its next load; bouncing the adapter here
    # would only risk hanging setup with no benefit.
    if (-not (Get-Command Set-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue)) {
        Write-Log "  NetAdapter module unavailable - NIC advanced properties skipped" 'WARN'
        return
    }

    $properties = [ordered]@{
        '*InterruptModeration' = 0   # batch interrupts -> latency spike per batch
        '*RSS'                 = 1   # receive queues spread across cores
        '*EEE'                 = 0   # energy-efficient ethernet: idle link sleep
        '*FlowControl'         = 0   # pause frames stall the queue
        '*RscIPv4'             = 0   # receive segment coalescing delays delivery
        '*LsoV2IPv4'           = 0   # large send offload batches transmit
    }

    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        Write-Log "  no physical adapter found - NIC advanced properties skipped" 'WARN'
        return
    }

    $applied = 0
    $unsupported = 0
    foreach ($adapter in $adapters) {
        foreach ($key in $properties.Keys) {
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $key `
                    -RegistryValue $properties[$key] -NoRestart -ErrorAction Stop | Out-Null
                $applied++
            } catch {
                $unsupported++
            }
        }
    }

    Write-Log "  NIC advanced properties: $applied applied, $unsupported not supported by the driver"
    Write-Log "  (take effect on the next boot - the adapters were not restarted)"
}

function Set-GamingUsbPower {
    # A USB mouse that Windows may suspend is a mouse that has to wake its port
    # before it can report movement. That does not show up as input lag on the
    # average, it shows up as an occasional late frame - the same class of problem
    # as a parked core. Selective suspend is already off at the power-scheme level;
    # these are the per-device switches underneath it.
    $roots = @(
        'HKLM:\SYSTEM\CurrentControlSet\Enum\USB',
        'HKLM:\SYSTEM\CurrentControlSet\Enum\HID'
    )

    $values = @{
        'EnhancedPowerManagementEnabled' = 0
        'SelectiveSuspendEnabled'        = 0
        'AllowIdleIrpInD3'               = 0
        'DeviceIdleEnabled'              = 0
    }

    $devices = 0
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($device in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            foreach ($instance in (Get-ChildItem -Path $device.PSPath -ErrorAction SilentlyContinue)) {
                $params = "$($instance.PSPath)\Device Parameters"
                if (-not (Test-Path -LiteralPath $params)) { continue }
                try {
                    foreach ($name in $values.Keys) {
                        New-ItemProperty -Path $params -Name $name -Value $values[$name] `
                            -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    }
                    $devices++
                } catch {
                    # A handful of composite devices lock their Device Parameters
                    # key; skipping them is fine.
                }
            }
        }
    }

    Write-Log "  USB/HID power management disabled on $devices device(s)"
}

function Set-GamingMemoryCompression {
    # Memory compression trades CPU for RAM: when the system is under pressure it
    # compresses pages instead of paging them out. On a 16 GB+ gaming machine that
    # trade is backwards - the compression worker shows up as a CPU spike exactly
    # when the game is streaming assets. Below 16 GB the trade is worth keeping,
    # so this is deliberately conditional.
    $ram = $null
    try {
        $ram = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    } catch {
        Write-Log "  could not read installed RAM - memory compression left alone" 'WARN'
        return
    }

    if (-not $ram) {
        Write-Log "  could not read installed RAM - memory compression left alone" 'WARN'
        return
    }

    $gb = [math]::Round($ram / 1GB, 1)
    if ($ram -lt 16GB) {
        Write-Log "  memory compression kept (only $gb GB installed)"
        return
    }

    try {
        Disable-MMAgent -MemoryCompression -ErrorAction Stop
        Write-Log "  memory compression disabled ($gb GB installed)"
    } catch {
        Write-Log "  could not disable memory compression ($_)" 'WARN'
    }
}

#---------[ Essentials pass ]---------#

function Invoke-EssentialsFirstBoot {
    <#
        The half of the essentials layer that needs a live OS. Everything here was
        defined in config/essentials_profile.json and staged next to this script by the
        builder.

        Deliberately NOT group-gated. The essentials pass is part of what a Core-Gaming
        build is, so - unlike every gaming group - it cannot be switched off with
        gaming_groups.json.
    #>
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Essentials config not found at $ConfigPath - skipping the first-boot half" 'WARN'
        return
    }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $fb = $cfg.firstBoot
    if (-not $fb) {
        Write-Log "essentials_profile.json has no firstBoot block - skipping" 'WARN'
        return
    }

    # 1. Hibernation. The registry half is already baked into the image; this is the
    #    half that deletes hiberfil.sys and actually reclaims the disk space.
    if ($fb.hibernateOff) {
        & powercfg -hibernate off 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  hibernation off - hiberfil.sys removed"
        } else {
            Write-Log "  powercfg -hibernate off failed (exit $LASTEXITCODE)" 'WARN'
            $script:Failures++
        }
    }

    # 2. Temp cleanup. install.wim ships an empty %TEMP%, but the setup process fills it
    #    while the image is being laid down, so this runs after that.
    if ($fb.cleanTemp) {
        $targets = @(
            (Join-Path $env:WINDIR 'Temp'),
            $env:TEMP
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

        $removed = 0
        foreach ($dir in $targets) {
            Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    $removed++
                } catch { }
            }
        }
        Write-Log "  temp cleanup: removed $removed item(s) from $($targets.Count) location(s)"
    }

    # 3. Baseline restore point. Best-effort by design: System Restore is frequently
    #    disabled by policy on a trimmed image, and a failure here must never fail the
    #    boot. The point of it is to have one known-good state before the first driver
    #    install.
    if ($fb.restorePoint) {
        $description = $fb.restorePointDescription
        if (-not $description) { $description = 'Tiny11 Core-Gaming baseline' }
        try {
            $systemDrive = "$env:SystemDrive\"
            Enable-ComputerRestore -Drive $systemDrive -ErrorAction Stop
            Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            Write-Log "  restore point created: '$description'"
        } catch {
            Write-Log "  restore point not created ($_)" 'WARN'
        }
    }

    # 4. Process count. Recorded for the build log so the claim can be checked against
    #    something. Note this is the SetupComplete session, not an interactive desktop -
    #    expect it to read lower than Task Manager after logon.
    if ($fb.reportProcessCount) {
        try {
            $count = @(Get-Process).Count
            Write-Log "  processes in this session: $count (informational - SetupComplete, not an interactive desktop)"
        } catch {
            Write-Log "  could not count processes ($_)" 'WARN'
        }
    }

    Write-Log "Essentials first-boot half complete"
}

#---------[ Windows Update lockdown re-assert ]---------#
#
# The builder sets wuauserv / UsoSvc / WaaSMedicSvc to Start=4 in the mounted
# image and deletes the Windows Update task folders. That state does not survive
# contact with a real machine.
#
# Observed on a shipped Core-Gaming install: the image booted with wuauserv at
# Start=3 and InstallService\ScanForUpdates live, while UsoSvc and WaaSMedicSvc
# stayed at 4. The Windows Update client then scanned from 00:59, found 17 updates
# and staged them at 02:02 - hours before anything else touched the machine, and
# before any third-party playbook ran. UsoSvc being off is not a barrier: wuauserv
# is startable on demand by the client, so a half-disabled stack still updates.
#
# That wuauserv specifically was reverted is the tell. The builder writes wuauserv
# first in the loop, so a failed write would have left all three at their defaults;
# instead three are at 4 and one is at 3. The write landed and one value was undone
# afterwards.
#
# The mechanism is the first online boot's servicing pass, which re-registers
# inbox service start types from the component manifests and re-creates the task
# folders out of the same store. Anything written into the offline hive is only a
# default that pass is free to overwrite.
#
# So the offline pass is not the last word. This runs on the target, after that
# pass, and re-asserts the identical state. It is idempotent and safe to re-run.
#
# Everything above applies only when the image shipped with the stack REMOVED. Under
# the 'paused' default the stack is intact and merely told to stop, and none of that
# reasoning holds: Windows does not repair a paused device, so there is nothing to
# chase and no guard is registered.

$script:WindowsUpdatePauseExpiry = '3000-01-01T00:00:00Z'
$script:WindowsUpdatePauseMaxDays = 3650000

function Get-WindowsUpdateMode {
    # The mode travels in gaming_groups.json rather than being inferred from the
    # machine: a paused image and a live one are byte-for-byte identical in service
    # state, task folders and binaries. Only the pause keys differ, and those are
    # exactly what a user is allowed to delete.
    $file = Join-Path $GamingDir 'gaming_groups.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            $prop = $json.PSObject.Properties['windowsUpdateMode']
            if ($prop -and $prop.Value -in @('paused', 'live', 'removed')) { return [string]$prop.Value }
        } catch { }
    }

    # No field means an image built before the mode existed, and those all shipped with
    # the stack removed. Defaulting to 'removed' keeps such a machine behaving exactly
    # as it did, instead of silently un-pausing something built never to update.
    return 'removed'
}

function Restore-WindowsUpdatePause {
    # Idempotent re-assert of the pause window on the target machine.
    #
    # The builder already wrote these values into the offline hive. Repeating them here
    # makes the first-boot log record which mode the image is in, and means a servicing
    # pass that rewrote UX\Settings cannot leave the machine quietly unpaused.
    #
    # Nothing here disables a service, deletes a task folder or hides the Settings page.
    # A paused device is a supported state, so Windows has no reason to repair it - and
    # that is precisely why this needs no repeating guard.
    $settings = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (-not (Test-Path $settings)) { New-Item -Path $settings -Force -ErrorAction SilentlyContinue | Out-Null }

    $start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $values = [ordered]@{
        FlightSettingsMaxPauseDays   = $script:WindowsUpdatePauseMaxDays
        PauseUpdatesStartTime        = $start
        PauseUpdatesExpiryTime       = $script:WindowsUpdatePauseExpiry
        PauseFeatureUpdatesStartTime = $start
        PauseFeatureUpdatesEndTime   = $script:WindowsUpdatePauseExpiry
        PauseQualityUpdatesStartTime = $start
        PauseQualityUpdatesEndTime   = $script:WindowsUpdatePauseExpiry
    }

    foreach ($name in $values.Keys) {
        $type = 'String'
        if ($name -eq 'FlightSettingsMaxPauseDays') { $type = 'DWord' }
        Set-ItemProperty -Path $settings -Name $name -Value $values[$name] -Type $type -ErrorAction SilentlyContinue
    }

    # Verify by reading back. The pause window is client-enforced, so a write that did
    # not land is indistinguishable from a pause that is about to expire silently.
    $expiry = (Get-ItemProperty -Path $settings -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    if ("$expiry" -eq $script:WindowsUpdatePauseExpiry) {
        Write-Log "  verified: Windows Update paused until $expiry" 'SUCCESS'
    } else {
        Write-Log "  could not set the pause window (read back '$expiry')" 'WARN'
        $script:Failures++
    }
}

function Remove-WindowsUpdateGuardTask {
    # A paused image has nothing to chase, and a guard inherited from an image that
    # shipped with the stack removed would keep re-disabling Windows Update behind a
    # user who deliberately resumed it. Remove it rather than leave it dormant.
    $task = Get-ScheduledTask -TaskName $script:GuardTaskName -TaskPath $script:GuardTaskPath -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Unregister-ScheduledTask -TaskName $script:GuardTaskName -TaskPath $script:GuardTaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "  removed the leftover Windows Update guard task"
}

function Test-GamingGroupEnabled {
    param([string]$Name)

    # Guard mode runs before the main flow loads $groups, so resolve the flag from the
    # staged JSON instead of depending on script state that does not exist yet.
    $existing = Get-Variable -Name groups -Scope Script -ErrorAction SilentlyContinue
    if ($existing -and $existing.Value -and $existing.Value.ContainsKey($Name)) {
        return [bool]$existing.Value[$Name]
    }
    $file = Join-Path $GamingDir 'gaming_groups.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $flags = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            # The flags are nested under .groups - reading them off the root object
            # always missed, which silently turned every lookup into "enabled".
            if ($flags.groups -and $flags.groups.PSObject.Properties.Name -contains $Name) {
                return [bool]$flags.groups.$Name
            }
        } catch { }
    }
    return $true
}

function Disable-ServiceThroughScm {
    param([string]$Name)

    # A service the image does not carry cannot serve the update client, and Set-Service
    # throws rather than no-ops on a missing name.
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
        Write-Log "  $Name not present - nothing to disable"
        return $true
    }

    # Set-Service is ChangeServiceConfig: it writes the hive AND notifies the running
    # SCM. Set-ItemProperty on the same value only does the first half, and that gap is
    # not theoretical. On a 26H1 guest a stopped wuauserv with Start=0x4 still reached
    # RUNNING from Start-Service, and returned 1058 only after an `sc config`. The SCM
    # keeps the start type it read at boot until something tells it otherwise, so the
    # registry write alone left the service startable for the rest of the session.
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        return $true
    } catch {
        # A few inbox services cannot be re-read by Set-Service. sc.exe config is the
        # same ChangeServiceConfig call through a different door.
        & sc.exe config $Name start= disabled 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Log "  could not disable $Name through the SCM: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Test-ServiceStartBlocked {
    param([string]$Name)

    # sc.exe rather than Start-Service, on purpose. PowerShell wraps the refusal in a
    # ServiceCommandException whose message is only "Cannot start service X on computer
    # '.'." - it carries neither the Win32 code nor the word "disabled", so matching on
    # the exception reported every service as startable on a build where the lockdown was
    # in fact holding. sc.exe exits with the SCM's own code, which is language neutral:
    # 1058 means disabled.
    #
    # The probe is still the only real proof. Reading the Start value - or even `sc qc`,
    # which also said DISABLED - answers a different question: on 26H1 both reported
    # disabled while the service was startable.
    & sc.exe start $Name 2>&1 | Out-Null
    $code = $LASTEXITCODE

    if ($code -eq 1058) { return $true }

    if ($code -eq 0) {
        # It started, so the lockdown is not holding. Put it back before returning.
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }

    # Anything else is not proof of a disabled service, so report it rather than pass.
    return $false
}

function Restore-WindowsUpdateLockdown {
    # DoSvc is owned by the profile's strip_background_noise group, and the builder leaves
    # it alone for exactly that reason (see tiny11coremaker-headless.ps1). Disabling it
    # here unconditionally would quietly override a toggle the user turned off.
    $services = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')
    if (Test-GamingGroupEnabled 'strip_background_noise') { $services += 'DoSvc' }

    # Stop before disabling: a service that is still running serves the WU client even
    # with Start=4 written, and a scan started now finishes regardless of the flag.
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -eq 'Stopped') { continue }

        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        # wuauserv measured 10-45 s to reach STOPPED on a 26H1 guest, so allow 60. The
        # previous 15 s wait expired while it was still STOP_PENDING, logged "stopped"
        # anyway, and left a running service behind a verification that reported success.
        try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60)) } catch { }
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') {
            Write-Log "  stopped $name"
        } else {
            Write-Log "  $name did not stop (status $($svc.Status))" 'WARN'
            $script:Failures++
        }
    }

    foreach ($name in $services) {
        if (-not (Disable-ServiceThroughScm -Name $name)) { $script:Failures++ }
    }

    # Policy layer. Same values the builder writes; repeated here because the
    # hives are re-read from disk at boot and a third-party playbook can overwrite
    # them wholesale.
    $wuPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $wuAuPolicy = Join-Path $wuPolicy 'AU'
    foreach ($pair in @(
        @{ Path = $wuPolicy;   Name = 'DoNotConnectToWindowsUpdateInternetLocations' },
        @{ Path = $wuPolicy;   Name = 'DisableWindowsUpdateAccess' },
        @{ Path = $wuPolicy;   Name = 'SetDisableUXWUAccess' },
        @{ Path = $wuPolicy;   Name = 'ExcludeWUDriversInQualityUpdate' },
        @{ Path = $wuAuPolicy; Name = 'NoAutoUpdate' }
    )) {
        if (-not (Test-Path $pair.Path)) { New-Item -Path $pair.Path -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $pair.Path -Name $pair.Name -Value 1 -Type DWord -ErrorAction SilentlyContinue
    }

    # Hide the Settings page, but MERGE rather than overwrite.
    #
    # The builder writes the literal 'hide:windowsupdate;windowsdefender'. That value
    # is fragile in both directions: the ReviOS playbook overwrites it wholesale with
    # its own list (aicomponents, cortana, ...) that does not mention windowsupdate,
    # so a blind write on either side loses the other's ids. Merging keeps both.
    #
    # Note this is cosmetic and is NOT what makes Windows Update work or not work. On
    # the reference install the page was reported visible again before the playbook
    # ran, while wuauserv had already been scanning for hours - so treat the page as
    # a symptom. The service state below is the actual control.
    $explorerKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path $explorerKey)) { New-Item -Path $explorerKey -Force -ErrorAction SilentlyContinue | Out-Null }
    $wanted = @('windowsupdate', 'windowsdefender')
    $hide = New-Object System.Collections.Generic.List[string]
    $show = New-Object System.Collections.Generic.List[string]
    $current = (Get-ItemProperty -Path $explorerKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($current) {
        # The value is a flat directive list, not a per-item prefix: 'hide:a;b;show:c'
        # means hide a and b, show c. So the mode carries forward until the next
        # directive, and a token is never parsed on its own.
        $mode = 'hide'
        foreach ($token in ($current -split ';')) {
            $t = $token.Trim()
            if (-not $t) { continue }
            if ($t -match '^hide:(.*)$') { $mode = 'hide'; $id = $matches[1].Trim() }
            elseif ($t -match '^show:(.*)$') { $mode = 'show'; $id = $matches[1].Trim() }
            else { $id = $t }
            if (-not $id) { continue }
            if ($mode -eq 'show') { $show.Add($id) } else { $hide.Add($id) }
        }
    }
    foreach ($id in $wanted) { if (-not $hide.Contains($id)) { $hide.Add($id) } }
    $show = @($show | Where-Object { $wanted -notcontains $_ })

    $visibility = 'hide:' + (($hide | Select-Object -Unique) -join ';')
    if ($show.Count -gt 0) { $visibility += ';show:' + ($show -join ';') }
    Set-ItemProperty -Path $explorerKey -Name 'SettingsPageVisibility' -Value $visibility -Type String -ErrorAction SilentlyContinue
    Write-Log "  SettingsPageVisibility = $visibility"

    # Scheduling layer. Unregister through the task service rather than deleting XML,
    # because the task cache is live at this point. Count only what actually went away:
    # Unregister-ScheduledTask with -ErrorAction SilentlyContinue returns the same nothing
    # whether it succeeded or was denied, which is how the original bug shipped with
    # InstallService\ScanForUpdates still registered and no line in the log to say so.
    $taskPaths = @(
        '\Microsoft\Windows\WaaSMedic\',
        '\Microsoft\Windows\UpdateOrchestrator\',
        '\Microsoft\Windows\WindowsUpdate\',
        '\Microsoft\Windows\InstallService\'
    )
    $removed = 0
    $stubborn = @()
    foreach ($path in $taskPaths) {
        foreach ($task in @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
            if (@(Get-ScheduledTask -TaskName $task.TaskName -TaskPath $path -ErrorAction SilentlyContinue).Count -eq 0) {
                $removed++
            } else {
                $stubborn += "$path$($task.TaskName)"
            }
        }
    }
    if ($stubborn.Count -gt 0) {
        Write-Log "  could not unregister: $($stubborn -join ', ')" 'WARN'
        $script:Failures++
    }
    Write-Log "  unregistered $removed Windows Update task(s)"

    # Verify by behaviour, not by intent. A registry read said "disabled" throughout the
    # failure this guard exists for, so the state is only trusted after a start attempt
    # has been refused.
    $bad = @()
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $svc.Refresh()
        if ($svc.Status -ne 'Stopped') { $bad += "$name $($svc.Status)"; continue }
        if (-not (Test-ServiceStartBlocked -Name $name)) { $bad += "$name still startable" }
    }
    $pageVisible = (Get-ItemProperty -Path $explorerKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($pageVisible -notmatch 'windowsupdate') { $bad += 'SettingsPageVisibility' }

    if ($bad.Count -eq 0) {
        Write-Log "  verified: $($services.Count) service(s) stopped, disabled and refusing to start; page hidden" 'SUCCESS'
    } else {
        Write-Log "  verification failed: $($bad -join ', ')" 'WARN'
        $script:Failures++
    }
}

#---------[ Boot guard ]---------#
#
# A single re-assert at SetupComplete is not a guarantee, and the reference install
# proves it: the payload ran at 00:49, the Windows Update client scanned at 00:59 and
# online package staging began at 02:02. The one-shot fires before the events it is
# meant to guard against, and the revert is recurring - any servicing of the Windows
# Update Agent component can re-register wuauserv, so there is no single moment after
# which the image is safe.
#
# The guard is a SYSTEM startup task that re-asserts the lockdown on every boot, and
# repeats during the first 20 minutes of the boot because that is when the servicing
# pass runs. It is permanent.
#
# It used to unregister itself after three clean boots. That was wrong on the evidence:
# on a fresh install of the fixed image the boot servicing pass re-registers wuauserv to
# Manual and starts it again on boot 2, roughly three minutes in. Nothing suggests boot
# 3 is the last time that happens, and a later LCU or feature update can do it again at
# any point in the machine's life. A guard that stops watching is a guard that fails
# silently, which is the failure mode this whole change exists to remove. The measured
# cost of keeping it is about a second per run when the state is already correct.
$script:GuardTaskName = 'WindowsUpdateGuard'
$script:GuardTaskPath = '\Tiny11\'
$script:GuardIntervalMinutes = 2
$script:GuardDurationMinutes = 20

function Register-WindowsUpdateGuard {
    # Called from the first-boot payload, which runs as SYSTEM under SetupComplete -
    # the one context where Register-ScheduledTask is both elevated and allowed to
    # target SYSTEM.
    $stateFile = Join-Path $GamingDir '.wu-guard-state'
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = Join-Path $GamingDir 'gaming-firstboot.ps1' }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -WuGuard"

    # A boot trigger fires before the boot servicing pass has necessarily finished, so
    # the first run waits two minutes. That delay also keeps the guard off the critical
    # path of a user waiting at the desktop.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT2M'

    # Repetition has to be grafted on: New-ScheduledTaskTrigger has no
    # -RepetitionInterval for a boot trigger, but the underlying MSFT_TaskBootTrigger
    # does support it. Without this the guard only runs once per boot, and the servicing
    # pass can re-enable wuauserv after that run and keep it for the rest of the session.
    $repeater = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $script:GuardIntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Minutes $script:GuardDurationMinutes)
    $trigger.Repetition = $repeater.Repetition

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # 10 minutes, not 5: wuauserv alone can take 45 s to stop, and the verification now
    # attempts a start per service instead of reading a registry value.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask -TaskName $script:GuardTaskName -TaskPath $script:GuardTaskPath `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description "Re-asserts the Tiny11 Windows Update lockdown on every boot, every $($script:GuardIntervalMinutes) minutes for the first $($script:GuardDurationMinutes)." `
        -Force -ErrorAction Stop | Out-Null

    Write-Log "  guard task registered: $($script:GuardTaskPath)$($script:GuardTaskName) (permanent, every $($script:GuardIntervalMinutes) min for $($script:GuardDurationMinutes) min per boot)"
}

function Invoke-WindowsUpdateGuard {
    # -WuGuard entry point. Runs on every boot, then on the repetition interval.
    #
    # Only an image that shipped with the stack removed needs this. If the task
    # survived into a paused or live image - an upgrade, or a mode change - retire it
    # here rather than let it re-disable Windows Update behind the user's back.
    $mode = Get-WindowsUpdateMode
    if ($mode -ne 'removed') {
        Write-Log "Windows Update guard: image mode is '$mode', so there is nothing to re-assert - removing the task"
        Remove-WindowsUpdateGuardTask
        return
    }

    $stateFile = Join-Path $GamingDir '.wu-guard-state'
    $runs = 0
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $text = Get-Content -LiteralPath $stateFile -Raw
            if ($text -match 'runs\s*=\s*(\d+)') { $runs = [int]$matches[1] }
        } catch { }
    }
    $runs++

    # Logged before the work, so a run that hangs is still visible as the last line.
    Write-Log "Windows Update guard: run $runs"

    Restore-WindowsUpdateLockdown

    $result = if ($script:Failures -eq 0) { 'clean' } else { "failed($($script:Failures))" }

    # Diagnostics only - nothing retires on this any more.
    @(
        "runs=$runs",
        "lastRun=$(Get-Date -Format 'o')",
        "lastResult=$result"
    ) -join "`r`n" | Out-File -FilePath $stateFile -Encoding UTF8 -Force
}

#---------[ Main ]---------#

Write-Log "=============================================="
Write-Log "Tiny11 Core-Gaming first-boot payload starting"
Write-Log "=============================================="

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated - aborting. Run this from an Administrator prompt." 'ERROR'
    exit 1
}

# Guard mode is handled before the completion marker check on purpose: by the time the
# first guarded boot happens, .firstboot-done already exists and the marker check would
# exit 0 without doing anything.
if ($WuGuard) {
    Invoke-WindowsUpdateGuard
    if ($script:Failures -gt 0) { exit 1 }
    exit 0
}

if ((Test-Path -LiteralPath $script:Marker) -and -not $Force) {
    Write-Log "Completion marker found at $script:Marker - nothing to do (use -Force to re-run)"
    exit 0
}

$powerConfig = Join-Path $GamingDir 'gaming_power_settings.json'
$groupsFile = Join-Path $GamingDir 'gaming_groups.json'
$essentialsConfig = Join-Path $GamingDir 'essentials_profile.json'

$groups = @{}
if (Test-Path -LiteralPath $groupsFile) {
    try {
        $groupsJson = Get-Content -LiteralPath $groupsFile -Raw | ConvertFrom-Json
        foreach ($prop in $groupsJson.groups.PSObject.Properties) {
            $groups[$prop.Name] = [bool]$prop.Value
        }
        Write-Log "Loaded $($groups.Count) group flag(s) from gaming_groups.json"
    } catch {
        Write-Log "Could not parse gaming_groups.json ($_) - assuming all groups enabled" 'WARN'
    }
} else {
    Write-Log "gaming_groups.json not found - assuming all groups enabled" 'WARN'
}

function Test-GroupEnabled {
    param([string]$Name)
    if (-not $groups.ContainsKey($Name)) { return $true }
    return [bool]$groups[$Name]
}

try {
    # Essentials first. It is unconditional, and running it before the power scheme
    # means the scheme is created and activated last - 'powercfg -hibernate off' can
    # reset the active scheme, so anything that touches power must come before it.
    Write-Section 'Essentials pass'
    Invoke-EssentialsFirstBoot -ConfigPath $essentialsConfig

    # Runs after the essentials pass and before anything else: this is the first
    # payload that executes after the boot-time servicing pass, so it is the only place
    # the Windows Update state can be settled before a scan gets a chance to run.
    #
    # Three modes, three different jobs. 'paused' re-asserts the pause window and drops
    # any guard left over from a removed image. 'removed' keeps the original lockdown
    # plus its permanent guard. 'live' does nothing at all, which is the whole point.
    $wuMode = Get-WindowsUpdateMode
    Write-Section "Windows Update ($wuMode)"
    switch ($wuMode) {
        'paused' {
            Restore-WindowsUpdatePause
            Remove-WindowsUpdateGuardTask
        }
        'removed' {
            Restore-WindowsUpdateLockdown
            try {
                Register-WindowsUpdateGuard
            } catch {
                # Not fatal: the lockdown above is already applied. A missing guard means the
                # state is only as good as this boot, which is worth a warning, not an abort.
                Write-Log "could not register the Windows Update guard task ($_)" 'WARN'
            }
        }
        default {
            Write-Log "Windows Update is live - the update stack is left exactly as Windows ships it"
        }
    }

    if (Test-GroupEnabled 'atlas_power_scheme') {
        Write-Section 'Power scheme'
        $schemeGuid = New-GamingPowerScheme -ConfigPath $powerConfig -Groups $groups
        if ($schemeGuid) {
            if (Test-GroupEnabled 'disable_fast_startup') {
                # Removes hiberfil.sys as well as the registry flag.
                & powercfg -h off 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Log "Hibernation disabled (powercfg -h off)" }
            }
            # Re-assert the active scheme; 'powercfg -h off' can reset it.
            & powercfg -setactive $schemeGuid 2>&1 | Out-Null
            Test-GamingPowerScheme -SchemeGuid $schemeGuid
        }
    } else {
        Write-Log "Power scheme group disabled - skipping"
    }

    # Always run this. Each bcd entry carries its own group, and gating the whole
    # function on disable_security_mitigations used to drop unrelated entries
    # ('timeout 5', 'nx OptIn', the useplatformtick cleanup) whenever that one
    # group was turned off.
    Write-Section 'Boot configuration'
    Set-GamingBootConfiguration -ConfigPath $powerConfig -Groups $groups

    if (Test-GroupEnabled 'network_latency_tweaks') {
        Write-Section 'Network latency'
        Set-GamingNetworkTweaks
    }

    if (Test-GroupEnabled 'interrupt_latency') {
        Write-Section 'Device latency'
        Set-GamingInterruptLatency
        Set-GamingNetworkAdapter
        Set-GamingUsbPower
    } else {
        Write-Log "Device latency group disabled - skipping"
    }

    if (Test-GroupEnabled 'strip_background_noise') {
        Write-Section 'Memory compression'
        Set-GamingMemoryCompression
    }

    Write-Section 'Summary'
    if ($script:Failures -eq 0) {
        Write-Log "Completed with no errors" 'SUCCESS'
    } else {
        Write-Log "Completed with $($script:Failures) non-fatal failure(s) - see log above" 'WARN'
    }

    $markerText = @(
        "completed=$(Get-Date -Format 'o')",
        "failures=$($script:Failures)",
        "computer=$env:COMPUTERNAME"
    ) -join "`r`n"
    $markerText | Out-File -FilePath $script:Marker -Encoding UTF8 -Force
    Write-Log "Marker written to $script:Marker"
    Write-Log "Log: $($script:LogFile)"

    exit 0
} catch {
    Write-Log "UNHANDLED ERROR: $_" 'ERROR'
    Write-Log "Stack: $($_.ScriptStackTrace)" 'ERROR'
    exit 1
}
