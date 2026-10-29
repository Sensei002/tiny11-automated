<#
.SYNOPSIS
    Reverts the reversible parts of the Tiny11 Core-Gaming profile.

.DESCRIPTION
    Shipped inside the image at C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1.

    Reads the "revert" block of the bundled gaming_profile.json and restores the
    settings the builder changed. It is deliberately honest about what it CANNOT undo:
    removed Defender, removed printing features, removed AppX packages and the BCD
    mitigation flags are not restorable from inside the running OS.

    Run from an elevated PowerShell prompt:
        powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1

.PARAMETER GamingDir
    Directory holding gaming_profile.json. Defaults to this script's folder.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER KeepPowerPlan
    Do not switch the active power plan back to Balanced.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Undo-GamingTweaks.ps1 -Force

.NOTES
    Author: Sensei002 (https://github.com/Sensei002)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$GamingDir = $PSScriptRoot,
    [switch]$Force,
    [switch]$KeepPowerPlan
)

$ErrorActionPreference = 'Continue'

$script:LogFile = Join-Path $GamingDir 'undo-gaming-tweaks.log'
$script:Failures = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Output $line
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
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

# Registry prefix used by the revert block. Unlike the builder these are the LIVE
# hives on the running machine, not the offline z-prefixed ones.
$liveHivePrefixes = @{
    'SYSTEM'   = 'HKLM:\SYSTEM'
    'SOFTWARE' = 'HKLM:\SOFTWARE'
    'DEFAULT'  = 'HKU:\.DEFAULT'
    'NTUSER'   = 'HKCU:'
}

Write-Log "=============================================="
Write-Log "Tiny11 Core-Gaming revert"
Write-Log "=============================================="

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated. Re-launch from an Administrator prompt." 'ERROR'
    exit 1
}

$profilePath = Join-Path $GamingDir 'gaming_profile.json'
if (-not (Test-Path -LiteralPath $profilePath)) {
    Write-Log "gaming_profile.json not found in $GamingDir - cannot determine what to revert." 'ERROR'
    exit 1
}

try {
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
} catch {
    Write-Log "Could not parse gaming_profile.json: $_" 'ERROR'
    exit 1
}

$revert = $profile.revert

Write-Log ""
Write-Log "This will re-enable: Game Mode, Fullscreen Optimizations, VBS / Memory Integrity,"
Write-Log "Spectre/Meltdown mitigations, Fast Startup, mouse acceleration, background apps"
Write-Log "and Windows Search / Bluetooth services."
Write-Log ""

if (-not $Force) {
    $answer = Read-Host "Continue? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Log "Aborted by user."
        exit 0
    }
}

#---------[ Registry ]---------#

Write-Log ""
Write-Log "Restoring registry values..."

$restored = 0
foreach ($entry in $revert.reversible) {
    $hive = $entry.hive
    $prefix = $liveHivePrefixes[$hive]
    if (-not $prefix) {
        Write-Log "  unknown hive '$hive' - skipped" 'WARN'
        continue
    }

    $keyPath = "$prefix\$($entry.path)"
    $label = "$hive\$($entry.path)\$($entry.name)"

    try {
        if (-not (Test-Path -LiteralPath $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        $type = 'DWord'
        if ($entry.type -eq 'REG_SZ') { $type = 'String' }
        New-ItemProperty -Path $keyPath -Name $entry.name -Value $entry.value -PropertyType $type -Force | Out-Null
        Write-Log "  restored $label = $($entry.value)"
        $restored++
    } catch {
        Write-Log "  FAILED $label : $_" 'WARN'
        $script:Failures++
    }
}

#---------[ Services ]---------#

Write-Log ""
Write-Log "Restoring services..."

foreach ($svc in $revert.serviceRestore) {
    try {
        $current = Get-Service -Name $svc.name -ErrorAction SilentlyContinue
        if (-not $current) {
            Write-Log "  $($svc.name) not present - skipped" 'WARN'
            continue
        }
        Set-Service -Name $svc.name -StartupType Manual -ErrorAction Stop
        Write-Log "  $($svc.name) -> Manual"
    } catch {
        Write-Log "  FAILED to restore $($svc.name) : $_" 'WARN'
        $script:Failures++
    }
}

#---------[ Windows Update pause ]---------#

# Clearing these is the entire undo for a paused image. The stack was never touched, so
# there is no service to re-enable and no task folder to restore - which is the whole
# reason pause replaced removal. A removed image cannot be recovered this way; the
# manifest says so in its irreversible list.
Write-Log ""
Write-Log "Checking for a Windows Update pause..."

$wuSettings = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$pausedUntil = (Get-ItemProperty -Path $wuSettings -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
if ($pausedUntil) {
    foreach ($name in @(
        'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime',
        'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'
    )) {
        Remove-ItemProperty -Path $wuSettings -Name $name -ErrorAction SilentlyContinue
    }
    Write-Log "  cleared the pause that ran to $pausedUntil"
    Write-Log "  Windows Update will scan again on its next scheduled pass"
} else {
    Write-Log "  no pause is set - nothing to do"
}

#---------[ Power plan ]---------#

if (-not $KeepPowerPlan) {
    Write-Log ""
    Write-Log "Switching the active power plan back to Balanced..."
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    & powercfg -setactive $balanced 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Balanced is now active. The gaming scheme is still installed -"
        Write-Log "  remove it with: powercfg -delete <GUID>   (list with powercfg -list)"
    } else {
        Write-Log "  Could not switch power plan automatically" 'WARN'
        $script:Failures++
    }
}

#---------[ Not reversible ]---------#

Write-Log ""
Write-Log "=============================================="
Write-Log "NOT reversible from inside Windows"
Write-Log "=============================================="
foreach ($item in $revert.irreversible) {
    Write-Log "  * $item"
}

Write-Log ""
Write-Log "Some changes need a reboot: VBS / Memory Integrity, mitigation flags and"
Write-Log "hypervisorlaunchtype only take effect after a restart."
Write-Log ""
if ($script:Failures -eq 0) {
    Write-Log "Revert complete with no errors." 'SUCCESS'
} else {
    Write-Log "Revert complete with $($script:Failures) failure(s)." 'WARN'
}
Write-Log "Log: $($script:LogFile)"

exit 0
