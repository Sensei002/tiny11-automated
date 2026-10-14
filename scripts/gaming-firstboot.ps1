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
      * runtimes   - VC++ / DirectX / .NET installers must actually run

    Per-user settings (mouse, FSO, GPU preference) are NOT here - they are written into
    the Default user hive by the builder, so every new profile inherits them.

    Safe to re-run manually: pass -Force to ignore the completion marker.

.PARAMETER GamingDir
    Directory holding this script, the runtime installers and the power config.

.PARAMETER Force
    Re-run even if the completion marker exists.

.PARAMETER KeepInstallers
    Do not delete the runtime installers after installing them.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\gaming-firstboot.ps1 -Force

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$GamingDir = (Join-Path $env:WINDIR 'Tiny11Gaming'),
    [switch]$Force,
    [switch]$KeepInstallers
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
    $powPath = Join-Path $GamingDir 'Tiny11-Core-Gaming.pow'
    & powercfg -export $powPath $schemeGuid 2>&1 | Out-Null
    if (Test-Path -LiteralPath $powPath) {
        Write-Log "Exported scheme to $powPath"
    }

    return $schemeGuid
}

#---------[ BCD ]---------#

function Set-GamingBootConfiguration {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    foreach ($entry in $cfg.bcd) {
        $parts = $entry.args -split '\s+'
        & bcdedit @parts 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  bcdedit $($entry.args)"
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

#---------[ Game runtimes ]---------#

function Install-GamingRuntimes {
    param([string]$RuntimeDir, [switch]$Keep)

    if (-not (Test-Path -LiteralPath $RuntimeDir)) {
        Write-Log "No runtime payload directory - skipping" 'WARN'
        return
    }

    $installers = Get-ChildItem -Path $RuntimeDir -Filter '*.exe' -File -ErrorAction SilentlyContinue
    if (-not $installers -or $installers.Count -eq 0) {
        Write-Log "No runtime installers bundled" 'WARN'
        return
    }

    foreach ($installer in $installers) {
        $name = $installer.Name
        try {
            if ($name -like 'directx*') {
                # DirectX June 2010 ships as a self-extracting archive, not an installer.
                $extractDir = Join-Path $RuntimeDir 'dx-redist'
                if (Test-Path -LiteralPath $extractDir) {
                    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-Log "  extracting $name"
                Start-Process -FilePath $installer.FullName -ArgumentList "/Q /T:`"$extractDir`"" -Wait -NoNewWindow

                $dxSetup = Join-Path $extractDir 'DXSETUP.exe'
                if (Test-Path -LiteralPath $dxSetup) {
                    Write-Log "  running DXSETUP.exe /silent"
                    Start-Process -FilePath $dxSetup -ArgumentList '/silent' -Wait -NoNewWindow
                } else {
                    Write-Log "  DXSETUP.exe not found after extraction" 'WARN'
                }
            } else {
                Write-Log "  installing $name"
                Start-Process -FilePath $installer.FullName -ArgumentList '/install /quiet /norestart' -Wait -NoNewWindow
            }
        } catch {
            Write-Log "  FAILED $name : $_" 'WARN'
            $script:Failures++
        }
    }

    if (-not $Keep) {
        # Installers are ~150 MB; reclaim it now that they have been consumed.
        Get-ChildItem -Path $RuntimeDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $dxDir = Join-Path $RuntimeDir 'dx-redist'
        if (Test-Path -LiteralPath $dxDir) {
            Remove-Item -LiteralPath $dxDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Runtime installers removed (pass -KeepInstallers to retain them)"
    }
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
        Set-GamingBootConfiguration -ConfigPath $powerConfig
    }

    if (Test-GroupEnabled 'network_latency_tweaks') {
        Write-Section 'Network latency'
        Set-GamingNetworkTweaks
    }

    if (Test-GroupEnabled 'install_game_runtimes') {
        Write-Section 'Game runtimes'
        Install-GamingRuntimes -RuntimeDir (Join-Path $GamingDir 'runtimes') -Keep:$KeepInstallers
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
