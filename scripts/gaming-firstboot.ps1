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
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$GamingDir = (Join-Path $env:WINDIR 'Tiny11Gaming'),
    [switch]$Force
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

#---------[ Main ]---------#

Write-Log "=============================================="
Write-Log "Tiny11 Core-Gaming first-boot payload starting"
Write-Log "=============================================="

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated - aborting. Run this from an Administrator prompt." 'ERROR'
    exit 1
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
        }
    } else {
        Write-Log "Power scheme group disabled - skipping"
    }

    if (Test-GroupEnabled 'disable_security_mitigations') {
        Write-Section 'Boot configuration'
        Set-GamingBootConfiguration -ConfigPath $powerConfig -Groups $groups
    }

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
