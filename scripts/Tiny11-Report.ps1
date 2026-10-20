<#
.SYNOPSIS
    Post-install report for a Tiny11 Core-Gaming image.

.DESCRIPTION
    Prints the numbers that actually answer "did the essentials pass work":
    process count, running services, startup entries, and the state of each item
    the essentials layer is supposed to have applied.

    The Capture / OBS section prints the GPU-scheduling, MPO, FSO, power-throttling and
    timer-resolution values that OBS-SETTINGS.md assumes, plus the GPU list and OBS's
    own process priority when it is running.

    Ships inside the image at C:\Windows\Tiny11Gaming\Tiny11-Report.ps1. Nothing is
    changed by running it - it only reads.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Tiny11-Report.ps1
#>

[CmdletBinding()]
param(
    [switch]$Detailed
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

function Get-State {
    param([string]$Path, [string]$Name)
    $v = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -eq $v) { return '(not set)' }
    return $v
}

Write-Head 'Tiny11 Core-Gaming - post-install report'
Write-Host ("Computer : {0}" -f $env:COMPUTERNAME)
Write-Host ("User     : {0}" -f $env:USERNAME)
Write-Host ("When     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

#---------[ Process count ]---------#
Write-Head 'Process count'

$procs = @(Get-Process)
Write-Host ("Processes            : {0}" -f $procs.Count) -ForegroundColor Yellow
Write-Host ("  of which svchost   : {0}" -f @($procs | Where-Object { $_.ProcessName -eq 'svchost' }).Count)
Write-Host ("  distinct names     : {0}" -f @($procs | Select-Object -ExpandProperty ProcessName -Unique).Count)
Write-Host ''
Write-Host 'Reference: a stock Windows 11 24H2 install idles at roughly 100-115'
Write-Host 'processes. A Core-Gaming build with the essentials pass targets 50-65.'
Write-Host ''

if ($Detailed) {
    $procs | Group-Object ProcessName | Sort-Object Count -Descending |
        Select-Object -First 25 Name, Count | Format-Table -AutoSize | Out-String | Write-Host
}

#---------[ Services ]---------#
Write-Head 'Services'

$running = @(Get-Service | Where-Object { $_.Status -eq 'Running' })
$auto    = @(Get-Service | Where-Object { $_.StartType -eq 'Automatic' })
$disabled = @(Get-Service | Where-Object { $_.StartType -eq 'Disabled' })

Write-Host ("Running              : {0}" -f $running.Count) -ForegroundColor Yellow
Write-Host ("Automatic            : {0}" -f $auto.Count)
Write-Host ("Disabled             : {0}" -f $disabled.Count)
Write-Host ''

if ($Detailed) {
    Write-Host 'Running services:' -ForegroundColor DarkGray
    $running | Sort-Object Name | Select-Object Name, DisplayName |
        Format-Table -AutoSize | Out-String | Write-Host
}

#---------[ Essentials verification ]---------#
Write-Head 'Essentials pass - item by item'

$checks = @(
    @{ Item = 'Activity History';        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Expect = '0' },
    @{ Item = 'BitLocker auto-encrypt';  Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Expect = '1' },
    @{ Item = 'Delivery Optimization';   Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Expect = '0' },
    @{ Item = 'End Task right-click';    Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarEndTask'; Expect = '1' },
    @{ Item = 'Folder auto-discovery';   Path = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name = 'FolderType'; Expect = 'NotSpecified' },
    @{ Item = 'Hibernation';             Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'; Name = 'HibernateEnabled'; Expect = '0' },
    @{ Item = 'Location tracking';       Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'; Name = 'DisableLocation'; Expect = '1' },
    @{ Item = 'Store recommendations';   Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Expect = '0' },
    @{ Item = 'Device companion apps';   Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'; Name = 'PreventDeviceCompanionAppInstall'; Expect = '1' },
    @{ Item = 'Start menu layout';       Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_Layout'; Expect = '1' },
    @{ Item = 'Telemetry';               Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Expect = '0' },
    @{ Item = 'Widgets';                 Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Expect = '0' },
    @{ Item = 'WPBT';                    Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Name = 'DisableWpbtExecution'; Expect = '1' },
    @{ Item = 'OneDrive sync';           Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Expect = '1' },
    @{ Item = 'Windows AI';              Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Expect = '1' }
)

$okCount = 0
$badCount = 0
foreach ($c in $checks) {
    $actual = Get-State -Path $c.Path -Name $c.Name
    $pass = ("$actual" -eq "$($c.Expect)")
    if ($pass) { $okCount++ } else { $badCount++ }
    $mark = if ($pass) { 'OK  ' } else { 'MISS' }
    $colour = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-24} {2,-24} = {3}" -f $mark, $c.Item, $c.Name, $actual) -ForegroundColor $colour
}

Write-Host ''
Write-Host ("Applied: {0}   Missing: {1}" -f $okCount, $badCount) -ForegroundColor Yellow

#---------[ Service spot checks ]---------#
Write-Head 'Key services'

$svcChecks = @(
    @{ Name = 'DiagTrack';      Label = 'Telemetry' },
    @{ Name = 'WSearch';        Label = 'Search indexing' },
    @{ Name = 'Spooler';        Label = 'Print spooler' },
    @{ Name = 'SysMain';        Label = 'Superfetch' },
    @{ Name = 'BDESVC';         Label = 'BitLocker' },
    @{ Name = 'lfsvc';          Label = 'Geolocation' },
    @{ Name = 'OneSyncSvc';     Label = 'Sync host' },
    @{ Name = 'CDPUserSvc';     Label = 'Connected devices' },
    @{ Name = 'XblAuthManager'; Label = 'Xbox auth' },
    @{ Name = 'DoSvc';          Label = 'Delivery Optimization' }
)

foreach ($s in $svcChecks) {
    $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host ("  {0,-22} {1,-24} (service not present)" -f $s.Name, $s.Label) -ForegroundColor DarkGray
        continue
    }
    $colour = switch ($svc.StartType) {
        'Disabled' { 'Green' }
        'Manual'   { 'Yellow' }
        default    { 'Red' }
    }
    Write-Host ("  {0,-22} {1,-24} {2} / {3}" -f $svc.Name, $s.Label, $svc.StartType, $svc.Status) -ForegroundColor $colour
}

#---------[ Capture / OBS state ]---------#
Write-Head 'Capture / OBS'

# These are the values OBS-SETTINGS.md assumes. Printing them turns "the build is
# supposed to have done X" into something checkable on the machine in front of you.
$captureChecks = @(
    @{ Label = 'HAGS (2=on)';              Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode' },
    @{ Label = 'MPO (5=off)';              Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; Name = 'OverlayTestMode' },
    @{ Label = 'FSO (2=off)';              Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode' },
    @{ Label = 'GameDVR enabled';          Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled' },
    @{ Label = 'GameDVR policy';           Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR' },
    @{ Label = 'Power throttling off';     Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff' },
    @{ Label = 'Global 1ms timers';        Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Name = 'GlobalTimerResolutionRequests' },
    @{ Label = 'DXGI / VRR settings';      Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'DirectXUserGlobalSettings' }
)

foreach ($c in $captureChecks) {
    $actual = Get-State -Path $c.Path -Name $c.Name
    $colour = if ("$actual" -eq '(not set)') { 'DarkGray' } else { 'Green' }
    Write-Host ("  {0,-24} {1,-24} = {2}" -f $c.Label, $c.Name, $actual) -ForegroundColor $colour
}

Write-Host ''
Write-Host '  GPU(s):' -ForegroundColor DarkGray
$gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'Basic|Remote|Mirror' })
if ($gpus.Count -eq 0) {
    Write-Host '    (could not enumerate)' -ForegroundColor DarkGray
}
foreach ($g in $gpus) {
    Write-Host ("    {0}  driver {1}" -f $g.Name, $g.DriverVersion) -ForegroundColor DarkGray
}

$obs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^obs' })
if ($obs.Count -gt 0) {
    foreach ($o in $obs) {
        $colour = if ($o.PriorityClass -in @('AboveNormal', 'High')) { 'Green' } else { 'Yellow' }
        Write-Host ("    OBS running: {0} (PID {1}) priority {2}" -f $o.ProcessName, $o.Id, $o.PriorityClass) -ForegroundColor $colour
    }
    Write-Host '    AboveNormal or High is what OBS-SETTINGS.md recommends.' -ForegroundColor DarkGray
} else {
    Write-Host '    OBS is not running.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Guidance: C:\Windows\Tiny11Gaming\OBS-SETTINGS.md' -ForegroundColor DarkGray
Write-Host '  If clips still stutter, the frame cap is the first thing to change,' -ForegroundColor DarkGray
Write-Host '  not another registry value.' -ForegroundColor DarkGray
Write-Host ''

#---------[ Startup entries ]---------#
Write-Head 'Startup entries'

$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
)
$startupCount = 0
foreach ($key in $runKeys) {
    if (-not (Test-Path $key)) { continue }
    $props = Get-ItemProperty -Path $key
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        Write-Host ("  {0,-30} {1}" -f $p.Name, $p.Value) -ForegroundColor DarkGray
        $startupCount++
    }
}
if ($startupCount -eq 0) { Write-Host '  (none)' -ForegroundColor Green }

Write-Host ''
Write-Host 'Done. Re-run with -Detailed for the full process and service lists.' -ForegroundColor Cyan
