<#
.SYNOPSIS
    Builds a debloated NVIDIA display driver and prepares it for offline injection
    into a Tiny11 Core-Gaming ISO.

.DESCRIPTION
    Two build paths, tried in order of preference:

      1. GUI (primary) - downloads NVCleanstall, drives its wizard with Win32 control
                         messages to reproduce the reference component selection and
                         Installation Tweaks exactly, then captures the repackaged
                         driver folder it produces.

      2. Fallback      - if the GUI path fails or is skipped, downloads the official
                         NVIDIA DCH package, extracts it, prunes it to the Display
                         Driver component, applies the same tweaks as INF AddReg
                         edits and re-signs the result with a locally generated
                         certificate.

    Either way the result is a folder that contains an NVIDIA display INF plus its
    payload, ready for offline injection with DISM. When the driver is re-signed, a
    public .cer is emitted next to it so the image can trust it.

    This script only PRODUCES the driver. It never touches the Windows ISO - the
    injection itself is done by tiny11coremaker-headless.ps1 via -NvidiaDriverPath.

.PARAMETER DriverVersion
    NVIDIA driver version to build, e.g. '566.36'. Required. The literal value
    'latest' is accepted and resolves to the newest driver NVCleanstall offers
    (GUI path) or is rejected on the fallback path, which needs a concrete version.

.PARAMETER OutputDir
    Folder to write the injectable driver into. Default: <scriptroot>\nvidia-driver.

.PARAMETER WorkDir
    Scratch folder for downloads and intermediate files.
    Default: <scriptroot>\nvidia-driver-work.

.PARAMETER ConfigFile
    Path to config/nvidia_driver_profile.json.
    Default: the repository config folder relative to this script.

.PARAMETER SkipGui
    Skip the NVCleanstall GUI path and go straight to the deterministic fallback.

.PARAMETER ForceFallback
    Alias for -SkipGui, kept so workflow YAML reads clearly.

.PARAMETER Method
    Which build path to use. 'auto' (default) defers to the profile's gui.enabled
    flag, 'gui' forces the NVCleanstall GUI path, 'fallback' forces the
    deterministic rebuild. The profile ships with the GUI path disabled because it
    cannot complete unattended: NVCleanstall's first page expects a driver it
    downloads through its own wizard, and its component/tweak pages are owner-drawn
    VCL controls rather than standard Win32 dialogs.

.PARAMETER GuiTimeoutSeconds
    Hard timeout for the whole GUI automation, in seconds. 0 = use the profile value.

.PARAMETER LogFile
    Optional explicit log path. Default: <WorkDir>\nvidia-driver-builder.log.

.EXAMPLE
    .\nvidia-driver-builder.ps1 -DriverVersion 566.36

.EXAMPLE
    .\nvidia-driver-builder.ps1 -DriverVersion latest -SkipGui:$false

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="NVIDIA driver version to build, e.g. 566.36")]
    [string]$DriverVersion,

    [Parameter(Mandatory=$false)]
    [string]$OutputDir,

    [Parameter(Mandatory=$false)]
    [string]$WorkDir,

    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false)]
    [switch]$SkipGui,

    [Parameter(Mandatory=$false)]
    [switch]$ForceFallback,

    [Parameter(Mandatory=$false)]
    [int]$GuiTimeoutSeconds = 0,

    [Parameter(Mandatory=$false)]
    [string]$LogFile,

    [Parameter(Mandatory=$false, HelpMessage="Explicit path to NVCleanstall.exe. When omitted, a copy vendored in the repository (tools/) is used, then the download.")]
    [string]$NvCleanstallPath,

    [Parameter(Mandatory=$false, HelpMessage="Build path: 'auto' (profile decides), 'gui' (drive NVCleanstall) or 'fallback' (deterministic rebuild).")]
    [ValidateSet('auto', 'gui', 'fallback')]
    [string]$Method = 'auto'
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# PowerShell 7.3+ can promote a native command's stderr into a terminating error when
# $ErrorActionPreference is 'Stop'. aria2c, 7z and signtool all write progress and
# warnings to stderr, so keep the classic native-command behaviour.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

#---------[ Configuration ]---------
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'nvidia-driver' }
if (-not $WorkDir)   { $WorkDir   = Join-Path $PSScriptRoot 'nvidia-driver-work' }
if (-not $LogFile)   { $LogFile   = Join-Path $WorkDir 'nvidia-driver-builder.log' }
if (-not $ConfigFile) {
    $ConfigFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\nvidia_driver_profile.json'
}

$script:DriverVersion = $DriverVersion.Trim()
$script:WantLatest    = ($script:DriverVersion -ieq 'latest')

New-Item -ItemType Directory -Force -Path $WorkDir   | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

#---------[ Logging ]---------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    # Write-Host, deliberately NOT Write-Output. Almost every function in this script
    # calls Write-Log and then returns a value to its caller. Anything placed on the
    # success stream is captured along with that return value, so a function that
    # returns a path would hand back @('<log line>', '<path>') instead - and the
    # caller would then try to launch a process literally named after the log line.
    # Write-Host goes to the host/information stream, which CI still captures as
    # ordinary output.
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Import-NvidiaProfile {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "NVIDIA driver profile not found at $ConfigFile"
    }
    try {
        $profile = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        throw "NVIDIA driver profile at $ConfigFile is not valid JSON: $_"
    }
    foreach ($required in @('nvcleanstall', 'components', 'tweaks', 'fallback', 'gui')) {
        if (-not $profile.PSObject.Properties.Name.Contains($required)) {
            throw "NVIDIA driver profile is missing the '$required' section"
        }
    }
    return $profile
}

#---------[ Win32 helpers for GUI automation ]---------
# NVCleanstall is a Delphi VCL application. VCL controls are ordinary Win32 windows,
# so they can be driven with control messages (BM_CLICK / BM_GETCHECK / WM_SETTEXT)
# without needing the window to be visible or focused. That is the only reliable way
# to automate it on a headless CI runner.
function Initialize-Win32Interop {
    if ('NvidiaWin32' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class NvidiaWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageStr(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    // Window style bits. VCL (Delphi) does not give its controls distinct window
    // classes: a TButton and a TCheckBox are both plain 'Button' windows and differ
    // only in their style, so the style is the only reliable way to tell them apart.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    public static extern int GetWindowLongStyle(IntPtr hWnd, int nIndex);
}
'@
}

$script:BM_CLICK      = 0x00F5
$script:BM_GETCHECK   = 0x00F0
$script:BST_CHECKED   = 0x0001
$script:WM_SETTEXT    = 0x000C
$script:CB_SETCURSEL  = 0x014E
$script:CB_SELECTSTRING = 0x014D

# GWL_STYLE plus the BS_* button-type bits used to classify a 'Button' window.
$script:GWL_STYLE       = -16
$script:BS_TYPEMASK     = 0x0000000F
$script:BS_CHECKBOX_BITS = @(0x02, 0x03, 0x04, 0x05, 0x06, 0x09)

function Get-Win32Text {
    param([IntPtr]$Handle)
    $sb = New-Object System.Text.StringBuilder 1024
    [void][NvidiaWin32]::GetWindowText($Handle, $sb, $sb.Capacity)
    return $sb.ToString()
}

function Get-Win32Class {
    param([IntPtr]$Handle)
    $sb = New-Object System.Text.StringBuilder 256
    [void][NvidiaWin32]::GetClassName($Handle, $sb, $sb.Capacity)
    return $sb.ToString()
}

function Get-Win32Style {
    param([IntPtr]$Handle)
    return [NvidiaWin32]::GetWindowLongStyle($Handle, $script:GWL_STYLE)
}

function Test-CheckBoxControl {
    # True for a check box or radio button. VCL and Win32 both expose these as
    # class 'Button' with a BS_CHECKBOX / BS_AUTOCHECKBOX / BS_3STATE / BS_RADIOBUTTON
    # button type, which is what distinguishes them from a push button.
    param($Control)
    if ($Control.Class -notlike 'Button') { return $false }
    $bits = $Control.Style -band $script:BS_TYPEMASK
    return ($script:BS_CHECKBOX_BITS -contains $bits)
}

function Test-PushButtonControl {
    param($Control)
    if ($Control.Class -notlike 'Button') { return $false }
    $bits = $Control.Style -band $script:BS_TYPEMASK
    return -not ($script:BS_CHECKBOX_BITS -contains $bits)
}

function Get-ChildControl {
    # Enumerates the descendants of $Root once and returns them as objects so callers
    # can match on caption text / class without re-walking the tree per lookup.
    param([IntPtr]$Root)
    $controls = New-Object System.Collections.ArrayList
    $callback = {
        param($hWnd, $lParam)
        $script:__childHandles.Add($hWnd) | Out-Null
        return $true
    }
    $script:__childHandles = New-Object System.Collections.ArrayList
    [void][NvidiaWin32]::EnumChildWindows($Root, $callback, [IntPtr]::Zero)
    foreach ($h in $script:__childHandles) {
        $controls.Add([PSCustomObject]@{
            Handle = $h
            Text   = (Get-Win32Text -Handle $h)
            Class  = (Get-Win32Class -Handle $h)
            Style  = (Get-Win32Style -Handle $h)
        }) | Out-Null
    }
    $script:__childHandles = $null
    return $controls
}

function Find-TopLevelWindow {
    param([string]$TitleFragment, [int]$TimeoutSeconds = 60, [int]$ProcessId = 0)
    # The enumeration callback is invoked by native code, so it must not rely on
    # enclosing-function locals - everything it needs is parked in script scope.
    $script:__winTitle = $TitleFragment
    $script:__winPid   = $ProcessId
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $cb = {
            param($hWnd, $lParam)
            $text = Get-Win32Text -Handle $hWnd
            if ($text -like "*$($script:__winTitle)*") {
                if ($script:__winPid -eq 0) {
                    $script:__winMatch = $hWnd
                    return $false
                }
                [uint32]$procId = 0
                [void][NvidiaWin32]::GetWindowThreadProcessId($hWnd, [ref]$procId)
                if ($procId -eq $script:__winPid) {
                    $script:__winMatch = $hWnd
                    return $false
                }
            }
            return $true
        }
        $script:__winMatch = [IntPtr]::Zero
        [void][NvidiaWin32]::EnumWindows($cb, [IntPtr]::Zero)
        if ($script:__winMatch -ne [IntPtr]::Zero) { return $script:__winMatch }
        Start-Sleep -Milliseconds 500
    }
    return [IntPtr]::Zero
}

function Set-ControlChecked {
    # Toggle by CLICKING rather than by forcing the check state. BM_SETCHECK only
    # repaints the native button; a VCL TCheckBox keeps its own Checked property and
    # never learns about the change, so the wizard would go on to apply the OLD
    # selection. BM_CLICK goes through the notification path VCL actually listens on.
    # Returns $true when the requested state is confirmed by reading it back.
    param([IntPtr]$Handle, [bool]$Checked)

    $cur = [NvidiaWin32]::SendMessage($Handle, $script:BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)
    if (($cur.ToInt64() -eq $script:BST_CHECKED) -eq $Checked) { return $true }

    [void][NvidiaWin32]::SendMessage($Handle, $script:BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 150

    $after = [NvidiaWin32]::SendMessage($Handle, $script:BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)
    return (($after.ToInt64() -eq $script:BST_CHECKED) -eq $Checked)
}

function Invoke-ControlClick {
    param([IntPtr]$Handle)
    [void][NvidiaWin32]::SendMessage($Handle, $script:BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Set-CheckboxByKeyword {
    # Finds the first checkbox whose caption contains $Keyword and sets its state.
    # Returns $true when a control was found, $false otherwise.
    param([IntPtr]$Root, [string]$Keyword, [bool]$Checked)
    $controls = Get-ChildControl -Root $Root
    foreach ($c in $controls) {
        if ((Test-CheckBoxControl -Control $c) -and $c.Text -like "*$Keyword*") {
            $applied = Set-ControlChecked -Handle $c.Handle -Checked $Checked
            $note = if ($applied) { '' } else { ' (STATE NOT CONFIRMED)' }
            Write-Log ("    [checkbox] '{0}' -> {1}{2}" -f $c.Text, $(if ($Checked) { 'CHECK' } else { 'uncheck' }), $note)
            return $applied
        }
    }
    Write-Log ("    [checkbox] no control matched keyword '{0}'" -f $Keyword) "WARN"
    return $false
}

function Invoke-ButtonByKeyword {
    param([IntPtr]$Root, [string]$Keyword)
    $controls = Get-ChildControl -Root $Root
    foreach ($c in $controls) {
        if ((Test-PushButtonControl -Control $c) -and $c.Text -like "*$Keyword*") {
            Invoke-ControlClick -Handle $c.Handle
            Write-Log ("    [button] clicked '{0}'" -f $c.Text)
            return $true
        }
    }
    return $false
}

function Save-ScreenCapture {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
    } catch {
        Write-Log "Screenshot capture failed: $_" "WARN"
    }
}

#---------[ Downloads ]---------
function Get-FileWithRetry {
    # Returns a real [bool]. Every failure path falls through to `return $false`
    # without leaving anything else on the success stream, because the callers test
    # the result with `if (-not (Get-FileWithRetry ...))`. A stray log line on the
    # success stream would make that array truthy and the caller would carry on as
    # though the download had worked.
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MaxAttempts = 3,
        [long]$MinBytes = 1MB
    )

    $dir  = Split-Path -Parent $Destination
    $name = Split-Path -Leaf   $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $aria = Get-Command aria2c -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        $ok = $false
        try {
            if ($aria) {
                # aria2c resolves --out relative to --dir, so pass them separately:
                # a full path inside --out is not portable across aria2c builds.
                & aria2c --console-log-level=warn --summary-interval=0 `
                    --max-connection-per-server=16 --split=16 --min-split-size=5M `
                    --max-tries=3 --retry-wait=3 --timeout=60 --connect-timeout=30 `
                    --continue=true --allow-overwrite=true --auto-file-renaming=false `
                    --file-allocation=none --dir="$dir" --out="$name" "$Url"
                $ok = ($LASTEXITCODE -eq 0)
                if (-not $ok) {
                    $code = $LASTEXITCODE
                    Write-Log "aria2c exited with code $code for $Url" "WARN"
                    # 3 = resource not found, 24 = HTTP authorization failed. Both are
                    # permanent for this URL, so retrying only wastes runner time.
                    if ($code -eq 3 -or $code -eq 24) { return $false }
                }
            } else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
                $ok = $true
            }
        } catch {
            Write-Log "Download attempt $attempt for $Url failed: $_" "WARN"
            $ok = $false
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            if ($status -eq 403 -or $status -eq 404 -or $status -eq 410) {
                Write-Log "  $Url returned HTTP $status - not retrying this URL" "WARN"
                return $false
            }
        }

        if ($ok -and (Test-Path -LiteralPath $Destination)) {
            $len = (Get-Item -LiteralPath $Destination).Length
            if ($len -ge $MinBytes) { return $true }
            Write-Log "Download from $Url produced only $len bytes (need $MinBytes) - discarding" "WARN"
        } else {
            Write-Log "Download attempt $attempt for $Url did not produce a file" "WARN"
        }

        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Get-NvCleanstallTool {
    param($NvProfile, [string]$ExplicitPath)

    # Resolution order:
    #   1. An explicitly supplied path (-NvCleanstallPath / workflow input).
    #   2. A copy vendored in the repository (config: nvcleanstall.bundledPath).
    #   3. A previously downloaded copy in the work dir.
    #   4. Download from TechPowerUp (last resort - their CDN is anti-bot, which is
    #      exactly why the binary is vendored in tools/).
    $repoRoot   = Split-Path $PSScriptRoot -Parent
    $candidates = New-Object System.Collections.ArrayList
    if ($ExplicitPath) { $candidates.Add($ExplicitPath) | Out-Null }
    if ($NvProfile.nvcleanstall.bundledPath) {
        $candidates.Add((Join-Path $repoRoot $NvProfile.nvcleanstall.bundledPath)) | Out-Null
    }
    $cachedPath = Join-Path $WorkDir ("NVCleanstall_{0}.exe" -f $NvProfile.nvcleanstall.version)
    $candidates.Add($cachedPath) | Out-Null

    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $hash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($hash -ieq $NvProfile.nvcleanstall.sha256) {
            Write-Log "Using verified NVCleanstall at $candidate"
            return $candidate
        }
        Write-Log "Ignoring $candidate - SHA256 mismatch (got $hash, expected $($NvProfile.nvcleanstall.sha256))" "WARN"
    }

    $toolPath = $cachedPath
    if (Test-Path -LiteralPath $toolPath) {
        Remove-Item -LiteralPath $toolPath -Force -ErrorAction SilentlyContinue
    }

    $urls = @($NvProfile.nvcleanstall.downloadUrl) + @($NvProfile.nvcleanstall.mirrors)
    foreach ($url in $urls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        Write-Log "Downloading NVCleanstall from $url"
        if (-not (Get-FileWithRetry -Url $url -Destination $toolPath -MinBytes 1MB)) { continue }

        # TechPowerUp's anti-bot layer answers scripted clients with a tiny HTML page
        # and a 200/404. Reject anything that is not a PE image before hashing.
        $len = (Get-Item -LiteralPath $toolPath).Length
        $fs  = [System.IO.File]::OpenRead($toolPath)
        try {
            $magic = New-Object byte[] 2
            [void]$fs.Read($magic, 0, 2)
        } finally {
            $fs.Dispose()
        }
        if ($len -lt 1MB -or $magic[0] -ne 0x4D -or $magic[1] -ne 0x5A) {
            Write-Log "Response from $url is not a PE executable ($len bytes, magic '$([System.Text.Encoding]::ASCII.GetString($magic))')" "WARN"
            Remove-Item -LiteralPath $toolPath -Force -ErrorAction SilentlyContinue
            continue
        }

        $hash = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash
        if ($hash -ieq $NvProfile.nvcleanstall.sha256) {
            Write-Log "NVCleanstall downloaded and verified (SHA256 $hash)"
            return $toolPath
        }
        Write-Log "SHA256 mismatch for $url (got $hash, expected $($NvProfile.nvcleanstall.sha256))" "WARN"
        Remove-Item -LiteralPath $toolPath -Force -ErrorAction SilentlyContinue
    }

    throw "Could not find a verified copy of NVCleanstall. Expected it bundled at '$($NvProfile.nvcleanstall.bundledPath)', and the download mirrors did not return a matching file."
}

#---------[ Path A: NVCleanstall GUI automation ]---------
function Invoke-NvCleanstallGuiBuild {
    param($NvProfile, [string]$ToolPath)

    Initialize-Win32Interop

    $windowFragment = $NvProfile.nvcleanstall.windowTitleFragment
    $stepTimeout    = [int]$NvProfile.gui.stepTimeoutSeconds
    $delayMs        = [int]$NvProfile.gui.actionDelayMs
    $navDelayMs     = [int]$NvProfile.gui.navigationDelayMs

    if ($GuiTimeoutSeconds -gt 0) { $stepTimeout = $GuiTimeoutSeconds }

    $shotDir = Join-Path $WorkDir $NvProfile.gui.screenshotDir
    if ($NvProfile.gui.captureScreenshots) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }

    Write-Log "Launching NVCleanstall: $ToolPath"
    $proc = Start-Process -FilePath $ToolPath -PassThru
    if (-not $proc) { throw "Failed to start NVCleanstall" }

    try {
        Write-Log "Waiting for the NVCleanstall window..."
        $window = Find-TopLevelWindow -TitleFragment $windowFragment -TimeoutSeconds $stepTimeout -ProcessId $proc.Id
        if ($window -eq [IntPtr]::Zero) { throw "NVCleanstall window did not appear within $stepTimeout seconds" }
        Write-Log "NVCleanstall window found (0x$($window.ToString('X')))"

        # --- Page 1: driver source / version -------------------------------
        Start-Sleep -Milliseconds $navDelayMs
        if ($NvProfile.gui.captureScreenshots) { Save-ScreenCapture -Path (Join-Path $shotDir '01-driver-source.png') }

        $controls = Get-ChildControl -Root $window
        $combo = $controls | Where-Object { $_.Class -like '*ComboBox*' } | Select-Object -First 1
        $edit  = $controls | Where-Object { $_.Class -like '*Edit*' }     | Select-Object -First 1

        if ($script:WantLatest) {
            Write-Log "Driver version requested: latest (using NVCleanstall's automatic detection)"
        } else {
            if ($combo) {
                $idx = [NvidiaWin32]::SendMessageStr($combo.Handle, $script:CB_SELECTSTRING, [IntPtr](-1), $script:DriverVersion)
                if ([int64]$idx -lt 0) {
                    Write-Log "Version '$($script:DriverVersion)' not in the dropdown; typing it into the combo box" "WARN"
                    [void][NvidiaWin32]::SendMessageStr($combo.Handle, $script:WM_SETTEXT, [IntPtr]::Zero, $script:DriverVersion)
                } else {
                    Write-Log "Selected driver version from dropdown: $($script:DriverVersion)"
                }
            } elseif ($edit) {
                [void][NvidiaWin32]::SendMessageStr($edit.Handle, $script:WM_SETTEXT, [IntPtr]::Zero, $script:DriverVersion)
                Write-Log "Typed driver version into edit box: $($script:DriverVersion)"
            } else {
                throw "No driver-version control found on the NVCleanstall start page"
            }
        }

        if (-not (Invoke-ButtonByKeyword -Root $window -Keyword 'Next')) {
            throw "Could not find the 'Next' button on the driver-source page"
        }
        Start-Sleep -Milliseconds $navDelayMs

        # --- Page 2: components --------------------------------------------
        if ($NvProfile.gui.captureScreenshots) { Save-ScreenCapture -Path (Join-Path $shotDir '02-components.png') }
        Write-Log "Selecting components (Display Driver only)"

        # 'Minimum' selects exactly the required component. Fall back to unchecking
        # every optional component by caption if the link is not present.
        $clickedMinimum = $false
        foreach ($c in (Get-ChildControl -Root $window)) {
            if ($c.Text -match '^\s*Minimum\s*$') { Invoke-ControlClick -Handle $c.Handle; $clickedMinimum = $true; break }
        }
        if ($clickedMinimum) {
            Write-Log "    [components] clicked 'Minimum'"
        } else {
            Write-Log "    [components] 'Minimum' link not found; unchecking each optional component" "WARN"
        }
        foreach ($component in $NvProfile.components.remove) {
            $keyword = ($component -replace '\s*\(.*\)\s*$', '').Trim()
            [void](Set-CheckboxByKeyword -Root $window -Keyword $keyword -Checked $false)
        }

        if (-not (Invoke-ButtonByKeyword -Root $window -Keyword 'Next')) {
            throw "Could not find the 'Next' button on the components page"
        }
        Start-Sleep -Milliseconds $navDelayMs

        # --- Page 3: installation tweaks -----------------------------------
        if ($NvProfile.gui.captureScreenshots) { Save-ScreenCapture -Path (Join-Path $shotDir '03-tweaks.png') }
        Write-Log "Applying Installation Tweaks"

        # Keyword -> profile property. Order matters: longer, more specific keywords
        # first so 'Installer Telemetry' is matched before a bare 'Telemetry'.
        $tweakMap = [ordered]@{
            'Installer Telemetry'          = 'disable_installer_telemetry_advertising'
            'Unattended Express'           = 'unattended_express_install'
            'automatic reboot'             = 'allow_automatic_reboot'
            'Clean Installation'           = 'perform_clean_installation'
            'Hardware Support'             = 'add_hardware_support'
            'DLSS Indicator'               = 'enable_dlss_indicator'
            'Multiplane Overlay'           = 'disable_mpo'
            'Ansel'                        = 'disable_ansel'
            'Expert Tweaks'                = 'show_expert_tweaks'
            'Driver Telemetry'             = 'disable_driver_telemetry'
            'NVIDIA Container'             = 'disable_nvidia_container'
            'HD Audio device sleep'        = 'disable_hd_audio_sleep_timer'
            'Message Signaled Interrupts'  = 'enable_msi'
            'HDCP'                         = 'disable_hdcp'
            'NVENC'                        = 'nvenc_session_limit_patch'
            'digital signature'            = 'rebuild_digital_signature'
            'Easy-Anti-Cheat'              = 'easy_anticheat_compatible'
            'unsigned'                     = 'auto_accept_unsigned_warning'
        }
        foreach ($keyword in $tweakMap.Keys) {
            $prop = $tweakMap[$keyword]
            $desired = [bool]$NvProfile.tweaks.$prop
            [void](Set-CheckboxByKeyword -Root $window -Keyword $keyword -Checked $desired)
        }

        if (-not (Invoke-ButtonByKeyword -Root $window -Keyword 'Next')) {
            throw "Could not find the 'Next' button on the tweaks page"
        }
        Start-Sleep -Milliseconds $navDelayMs

        # --- Page 4: build / install ---------------------------------------
        if ($NvProfile.gui.captureScreenshots) { Save-ScreenCapture -Path (Join-Path $shotDir '04-build.png') }
        Write-Log "Starting the package build"

        foreach ($kw in @('Save', 'Extract', 'Build', 'Next', 'Finish', 'Install')) {
            if (Invoke-ButtonByKeyword -Root $window -Keyword $kw) {
                Write-Log "    [build] triggered '$kw'"
                break
            }
        }

        # Wait for NVCleanstall to finish downloading + repackaging, then find the
        # driver it produced rather than depending on the exact save dialog.
        Write-Log "Waiting for NVCleanstall to finish the package build (up to $stepTimeout s)..."
        $deadline = (Get-Date).AddSeconds($stepTimeout)
        $inf = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $candidate = Get-ChildItem -Path $WorkDir, $env:TEMP, (Split-Path $ToolPath -Parent) `
                -Recurse -Filter $NvProfile.fallback.displayInf -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $proc.StartTime } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($candidate) { $inf = $candidate; break }
            if ($proc.HasExited -and -not $candidate) { break }
        }

        if ($NvProfile.gui.captureScreenshots) { Save-ScreenCapture -Path (Join-Path $shotDir '05-finished.png') }

        if (-not $inf) {
            throw "NVCleanstall did not produce a driver package within $stepTimeout seconds"
        }
        Write-Log "NVCleanstall produced: $($inf.FullName)"
        return (Split-Path $inf.FullName -Parent)
    } finally {
        if ($proc -and -not $proc.HasExited) {
            Write-Log "Closing NVCleanstall"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

#---------[ Path B: deterministic fallback ]---------
function Get-NvidiaOfficialDriver {
    param($NvProfile)
    if ($script:WantLatest) {
        throw "The deterministic fallback needs a concrete driver version; 'latest' is only supported by the NVCleanstall GUI path."
    }

    $dest      = Join-Path $WorkDir ("nvidia-{0}.exe" -f $script:DriverVersion)
    $minDriver = 100MB

    if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt $minDriver) {
        Write-Log "Reusing previously downloaded NVIDIA package: $dest"
        return $dest
    }

    foreach ($branch in $NvProfile.fallback.branchCandidates) {
        foreach ($dlHost in $NvProfile.fallback.downloadHosts) {
            $url = $NvProfile.fallback.driverUrlTemplate
            $url = $url.Replace('{host}',    $dlHost)
            $url = $url.Replace('{version}', $script:DriverVersion)
            $url = $url.Replace('{branch}',  $branch)
            Write-Log "Trying NVIDIA package: $url"

            if (-not (Get-FileWithRetry -Url $url -Destination $dest -MinBytes $minDriver)) {
                Write-Log "No usable package from $url" "WARN"
                continue
            }

            # Never assume the file is present just because the downloader said so.
            if (-not (Test-Path -LiteralPath $dest)) {
                Write-Log "Downloader reported success but $dest does not exist" "WARN"
                continue
            }
            $size = (Get-Item -LiteralPath $dest).Length
            if ($size -gt $minDriver) {
                Write-Log "Downloaded NVIDIA $branch package from $dlHost ($([math]::Round($size/1MB,1)) MB)"
                return $dest
            }
            Write-Log "Downloaded file is only $([math]::Round($size/1MB,1)) MB - not a full driver package" "WARN"
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Could not download the NVIDIA $($script:DriverVersion) package from any known host/branch."
}

function Get-SevenZipPath {
    param($NvProfile)
    $candidates = @($NvProfile.fallback.sevenZipPath, 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "7-Zip (7z.exe) was not found; it is required to unpack the NVIDIA installer."
}

function Expand-NvidiaPackage {
    param([string]$InstallerPath, $NvProfile)
    $extractDir = Join-Path $WorkDir 'nvidia-extracted'
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

    $sevenZip = Get-SevenZipPath -NvProfile $NvProfile
    Write-Log "Extracting NVIDIA package with $sevenZip"
    & $sevenZip x -y -bso0 -bsp0 ("-o{0}" -f $extractDir) $InstallerPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $extractDir)) {
        throw "7-Zip failed to extract the NVIDIA package (exit code $LASTEXITCODE)"
    }
    return $extractDir
}

function Remove-NvidiaComponents {
    # Pruning to Display.Driver drops every optional component (Ansel, telemetry,
    # HD Audio, PhysX, NvContainer, NVIDIA App, ...) exactly as the NVCleanstall
    # component page does. Only the folders we keep survive.
    param([string]$ExtractDir, $NvProfile)
    $keep = @($NvProfile.fallback.keepFolders)
    Write-Log "Pruning NVIDIA package to: $($keep -join ', ')"
    $removed = 0
    foreach ($dir in Get-ChildItem -Path $ExtractDir -Directory) {
        if ($keep -contains $dir.Name) { continue }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    foreach ($file in Get-ChildItem -Path $ExtractDir -File) {
        # Keep nothing at the root except small manifests; the installer itself is
        # not needed for offline injection.
        if ($file.Extension -in @('.exe', '.msi')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Removed $removed optional component folder(s)"
}

function Add-NvidiaInfTweaks {
    # Applies the registry half of the Installation Tweaks directly to the display
    # INF so they take effect when Windows installs the injected driver. The tweaks
    # that are pure install-time behaviour (unattended express, clean install,
    # auto-accept warning) have no offline equivalent and are handled by the
    # installer flags / first-boot script instead.
    param([string]$DriverDir, $NvProfile)

    $infPath = Join-Path $DriverDir $NvProfile.fallback.displayInf
    if (-not (Test-Path -LiteralPath $infPath)) {
        # DCH packages sometimes ship nv_disp.inf instead of nv_dispi.inf.
        $alt = Get-ChildItem -Path $DriverDir -Filter 'nv_disp*.inf' | Select-Object -First 1
        if ($alt) { $infPath = $alt.FullName } else { throw "Display INF not found in $DriverDir" }
    }
    Write-Log "Applying INF tweaks to $infPath"

    $lines = Get-Content -LiteralPath $infPath
    $addRegLines = New-Object System.Collections.ArrayList
    $tweaks = $NvProfile.tweaks

    # Interrupt Management is the per-device key Windows reads to decide whether to
    # use MSI. HKR addresses the device's hardware key from an AddReg section.
    if ($tweaks.enable_msi) {
        $addRegLines.Add('HKR,"Interrupt Management\MessageSignaledInterruptProperties",MSISupported,0x00010001,1') | Out-Null
        $addRegLines.Add('HKR,"Interrupt Management\Affinity Policy",DevicePriority,0x00010001,3') | Out-Null
    }
    if ($tweaks.disable_hdcp) {
        $addRegLines.Add('HKR,,RMHdcpKeyglobZero,0x00010001,1') | Out-Null
    }
    if ($tweaks.disable_driver_telemetry) {
        $addRegLines.Add('HKR,"NVIDIA\Telemetry",DisableTelemetry,0x00010001,1') | Out-Null
    }
    if ($tweaks.disable_hd_audio_sleep_timer) {
        $addRegLines.Add('HKR,,DisableHDAudioSleepTimer,0x00010001,1') | Out-Null
    }

    if ($addRegLines.Count -eq 0) {
        Write-Log "No INF-level tweaks requested" "WARN"
        return $infPath
    }

    $sectionName = 'Tiny11NvidiaTweaks'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("; --- Tiny11 debloated-driver tweaks (injected by nvidia-driver-builder.ps1) ---")
    [void]$sb.AppendLine("[$sectionName]")
    foreach ($l in $addRegLines) { [void]$sb.AppendLine($l) }

    # Wire the new AddReg section into every DDInstall section. NVIDIA's INF spreads
    # its install directives across many sections, so we attach to each one that
    # already declares AddReg (or the primary install section) to be safe.
    $out = New-Object System.Collections.ArrayList
    $wired = 0
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $inSection = $Matches[1] -match 'DDInstall|nv_|install'
        }
        $out.Add($line) | Out-Null
        if ($inSection -and $line -match '^\s*AddReg\s*=') {
            $out.Add("AddReg=$sectionName") | Out-Null
            $wired++
        }
    }
    $out.Add($sb.ToString()) | Out-Null
    Set-Content -LiteralPath $infPath -Value $out -Encoding ASCII
    Write-Log "Wired '$sectionName' into $wired AddReg directive(s)"

    return $infPath
}

function New-DriverSigningCertificate {
    param($NvProfile)
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $NvProfile.fallback.signing.subject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(10)

    $cerPath = Join-Path $OutputDir 'tinynvidia-driver.cer'
    $pfxPath = Join-Path $WorkDir  'tinynvidia-driver.pfx'
    $pwd = ConvertTo-SecureString -String 'tiny11' -Force -AsPlainText

    Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pwd -Force | Out-Null
    Write-Log "Generated signing certificate (thumbprint $($cert.Thumbprint))"
    return [PSCustomObject]@{ Cert = $cert; CerPath = $cerPath; PfxPath = $pfxPath; Password = 'tiny11' }
}

function Get-SignToolPath {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($kit in $kits) {
        $exe = Join-Path $kit.FullName 'x64\signtool.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Get-Inf2CatPath {
    # inf2cat ships with the Windows DRIVER Kit (not the SDK), so it is missing on
    # images that only have the SDK. It is what lets us rebuild the catalog after the
    # INF is edited - without it a tweaked driver fails signature validation and
    # never installs, which is why its absence changes what we are allowed to do.
    $cmd = Get-Command inf2cat.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($kit in $kits) {
        foreach ($arch in 'x64', 'x86') {
            $exe = Join-Path $kit.FullName "$arch\inf2cat.exe"
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    return $null
}

function Set-DriverSignature {
    # Re-signs the modified driver with the locally generated certificate.
    #
    # Editing the INF invalidates NVIDIA's catalog, so a replacement catalog MUST be
    # produced or Windows refuses to install the driver from the DriverStore. inf2cat
    # (Windows DRIVER Kit) builds that catalog; signtool (Windows SDK) signs the
    # result. Returns $true only when the catalog was genuinely rebuilt and signed.
    param([string]$DriverDir, $SigningInfo)

    $signtool = Get-SignToolPath
    if (-not $signtool) {
        Write-Log "signtool.exe (Windows SDK) not found - cannot re-sign the driver" "WARN"
        return $false
    }
    $inf2cat = Get-Inf2CatPath
    if (-not $inf2cat) {
        Write-Log "inf2cat.exe (Windows Driver Kit) not found - cannot rebuild the catalog" "WARN"
        return $false
    }

    $binaries = @(Get-ChildItem -Path $DriverDir -Recurse -Include '*.sys', '*.dll' -File -ErrorAction SilentlyContinue)
    Write-Log "Signing $($binaries.Count) driver binaries"
    foreach ($bin in $binaries) {
        & $signtool sign /fd SHA256 /f $SigningInfo.PfxPath /p $SigningInfo.Password /t http://timestamp.digicert.com $bin.FullName | Out-Null
    }

    Write-Log "Regenerating the catalog with $inf2cat"
    & $inf2cat /driver:$DriverDir /os:10_X64,11_X64 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "inf2cat exited with code $LASTEXITCODE" "WARN"
        return $false
    }

    $cats = @(Get-ChildItem -Path $DriverDir -Filter '*.cat' -File)
    if ($cats.Count -eq 0) {
        Write-Log "inf2cat produced no catalog file" "WARN"
        return $false
    }
    foreach ($cat in $cats) {
        & $signtool sign /fd SHA256 /f $SigningInfo.PfxPath /p $SigningInfo.Password /t http://timestamp.digicert.com $cat.FullName | Out-Null
    }
    Write-Log "Catalog rebuilt and signed ($($cats.Count) file(s))"
    return $true
}

function Invoke-NvidiaDeterministicFallback {
    param($NvProfile)
    Write-Log "=== Deterministic fallback: building the driver from the official NVIDIA package ==="

    $installer = Get-NvidiaOfficialDriver -NvProfile $NvProfile
    $extracted = Expand-NvidiaPackage -InstallerPath $installer -NvProfile $NvProfile
    Remove-NvidiaComponents -ExtractDir $extracted -NvProfile $NvProfile

    $driverSrc = Join-Path $extracted 'Display.Driver'
    if (-not (Test-Path $driverSrc)) {
        throw "Display.Driver folder not found after extraction - the NVIDIA package layout may have changed."
    }

    $driverOut = Join-Path $OutputDir 'driver'
    if (Test-Path $driverOut) { Remove-Item $driverOut -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $driverOut | Out-Null
    Copy-Item -Path (Join-Path $driverSrc '*') -Destination $driverOut -Recurse -Force

    # Editing the INF invalidates NVIDIA's catalog, and a driver whose catalog does not
    # match will not install from the DriverStore at all. So the INF tweaks are only
    # applied when we can rebuild and sign a replacement catalog (inf2cat from the
    # Windows Driver Kit + signtool from the SDK). Without that tooling the driver is
    # left exactly as NVIDIA signed it - fewer tweaks, but it actually installs.
    $canRebuild = ($null -ne (Get-Inf2CatPath)) -and
                  ($null -ne (Get-SignToolPath)) -and
                  [bool]$NvProfile.fallback.signing.rebuildCatalog

    $tweaksInInf = $false
    $signed      = $false

    if ($canRebuild) {
        $null = Add-NvidiaInfTweaks -DriverDir $driverOut -NvProfile $NvProfile
        $tweaksInInf = $true
        try {
            $signingInfo = New-DriverSigningCertificate -NvProfile $NvProfile
            $signed = Set-DriverSignature -DriverDir $driverOut -SigningInfo $signingInfo
        } catch {
            Write-Log "Re-signing failed: $_" "WARN"
        }
        if (-not $signed) {
            throw "The INF tweaks were applied but the driver could not be re-signed, so it would not install. Run this on an image that has the Windows Driver Kit (inf2cat) and Windows SDK (signtool)."
        }
    } else {
        Write-Log "No catalog tooling available (inf2cat/signtool) - leaving the INF untouched so NVIDIA's own signature stays valid, and skipping the INF-level tweaks" "WARN"
    }

    return [PSCustomObject]@{
        DriverDir    = $driverOut
        Method       = 'fallback'
        Resigned     = $signed
        TweaksInInf  = $tweaksInInf
    }
}

#---------[ Result normalization ]---------
function Export-NvidiaDriverPackage {
    param([string]$SourceDir, [string]$Method, [bool]$Resigned, [bool]$TweaksInInf = $false)

    # Guarantee the caller always gets the driver at <OutputDir>\driver.
    $driverOut = Join-Path $OutputDir 'driver'
    $srcResolved = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    $dstResolved = if (Test-Path -LiteralPath $driverOut) {
        (Resolve-Path -LiteralPath $driverOut).Path.TrimEnd('\')
    } else { '' }
    if ($srcResolved -ne $dstResolved) {
        if (Test-Path $driverOut) { Remove-Item $driverOut -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $driverOut | Out-Null
        Copy-Item -Path (Join-Path $SourceDir '*') -Destination $driverOut -Recurse -Force
    }

    $inf = Get-ChildItem -Path $driverOut -Filter 'nv_disp*.inf' -File | Select-Object -First 1
    if (-not $inf) {
        throw "No NVIDIA display INF found in the produced driver folder ($driverOut)"
    }

    $files = Get-ChildItem -Path $driverOut -Recurse -File
    $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum

    $certPath = $null
    if ($Resigned) { $certPath = Join-Path $OutputDir 'tinynvidia-driver.cer' }

    $report = [PSCustomObject]@{
        profile          = 'nvidia-debloated-driver'
        driver_version   = $script:DriverVersion
        method           = $Method
        success          = $true
        display_inf      = $inf.Name
        driver_dir       = $driverOut
        file_count       = $files.Count
        size_bytes       = [int64]$sizeBytes
        size_mb          = [math]::Round($sizeBytes / 1MB, 1)
        resigned         = $Resigned
        tweaks_in_inf    = $TweaksInInf
        certificate      = $certPath
        timestamp        = (Get-Date).ToString('o')
    }
    $reportPath = Join-Path $OutputDir 'nvidia-driver-buildinfo.json'
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8

    Write-Log "Driver package ready: $driverOut ($($report.file_count) files, $($report.size_mb) MB, method=$Method, resigned=$Resigned, tweaksInInf=$TweaksInInf)"
    Write-Log "Report written to $reportPath"
    return $report
}

#---------[ Main ]---------
try {
    Write-Log "=== NVIDIA Debloated Driver Builder started ==="
    Write-Log "Requested driver version: $($script:DriverVersion)"
    Write-Log "Output: $OutputDir"
    Write-Log "Work:   $WorkDir"

    $nvProfile = Import-NvidiaProfile
    Write-Log "Loaded profile: $($nvProfile.profile) (schema $($nvProfile.schemaVersion))"

    $result = $null

    # Which path to try first. An explicit -Method wins; otherwise the profile
    # decides, and the profile ships with the GUI path disabled because it cannot
    # complete unattended on a clean machine - see the .PARAMETER Method notes.
    $useGui = switch ($Method) {
        'gui'      { $true }
        'fallback' { $false }
        default    { [bool]$nvProfile.gui.enabled }
    }
    if ($SkipGui -or $ForceFallback) { $useGui = $false }
    Write-Log "Build path: $(if ($useGui) { 'NVCleanstall GUI (fallback available)' } else { 'deterministic fallback' })"

    if ($useGui) {
        try {
            $tool = Get-NvCleanstallTool -NvProfile $nvProfile -ExplicitPath $NvCleanstallPath
            $guiDriverDir = Invoke-NvCleanstallGuiBuild -NvProfile $nvProfile -ToolPath $tool
            $result = [PSCustomObject]@{ DriverDir = $guiDriverDir; Method = 'gui'; Resigned = $true; TweaksInInf = $true }
            Write-Log "GUI path succeeded"
        } catch {
            Write-Log "GUI path failed: $_" "WARN"
            Write-Log "Falling back to the deterministic build" "WARN"
        }
    } else {
        Write-Log "GUI path skipped by request"
    }

    if (-not $result) {
        if (-not $nvProfile.fallback.enabled) {
            throw "The GUI path failed and the deterministic fallback is disabled in the profile."
        }
        $result = Invoke-NvidiaDeterministicFallback -NvProfile $nvProfile
    }

    $report = Export-NvidiaDriverPackage -SourceDir $result.DriverDir -Method $result.Method `
        -Resigned $result.Resigned -TweaksInInf $result.TweaksInInf

    Write-Log "=== NVIDIA Debloated Driver Builder finished successfully ==="
    exit 0
} catch {
    Write-Log "FATAL: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"

    $failure = [PSCustomObject]@{
        profile        = 'nvidia-debloated-driver'
        driver_version = $script:DriverVersion
        success        = $false
        error          = "$_"
        timestamp      = (Get-Date).ToString('o')
    }
    try {
        $failure | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $OutputDir 'nvidia-driver-buildinfo.json') -Encoding UTF8
    } catch { }

    exit 1
}
