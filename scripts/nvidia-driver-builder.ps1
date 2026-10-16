<#
.SYNOPSIS
    Builds a debloated NVIDIA display driver for offline injection into a
    Tiny11 Core-Gaming ISO.

.DESCRIPTION
    Clean-room implementation. This script does not use, bundle or drive
    NVCleanstall and contains no third-party code. The debloating approach is
    inspired by TechPowerUp's NVCleanstall.

    Pipeline:
      1. Resolve  - turn a driver version into a downloadable NVIDIA URL.
      2. Download - fetch the official DCH package (or use a local copy) and
                    verify it is really a driver package, not an error page.
      3. Extract  - unpack the self-extracting 7-Zip archive.
      4. Prune    - drop every component folder except the display driver.
      5. Tweak    - write the registry tweaks into the display INF as AddReg.
      6. Sign     - rebuild the catalog (inf2cat) and re-sign (signtool).
      7. Report   - emit nvidia-driver-buildinfo.json.

    Editing the INF invalidates NVIDIA's catalog, so a tweaked driver will not
    install from the DriverStore unless it is re-signed. When the WDK/SDK
    toolchain is unavailable the tweak stage is skipped entirely and the
    pristine NVIDIA-signed driver is shipped instead, so the output always
    installs.

    This script only PRODUCES the driver. It never touches the Windows ISO -
    injection is done by tiny11coremaker-headless.ps1 -NvidiaDriverPath.

.PARAMETER DriverVersion
    NVIDIA driver version to build, e.g. '582.28'. Required.

.PARAMETER OutputDir
    Folder to write the injectable driver into. Default: <scriptroot>\nvidia-driver.

.PARAMETER WorkDir
    Scratch folder for downloads and intermediate files.
    Default: <scriptroot>\nvidia-driver-work.

.PARAMETER ConfigFile
    Path to config/nvidia_driver_profile.json.
    Default: the repository config folder relative to this script.

.PARAMETER LocalPackage
    Path to an already-downloaded NVIDIA package. When set, the download stage
    is skipped. Useful in CI to reuse a cached or vendored package.

.PARAMETER SkipTweaks
    Skip the INF tweak stage, leaving NVIDIA's catalog signature valid.

.PARAMETER SkipSigning
    Skip the re-signing stage.

.PARAMETER LogFile
    Optional explicit log path. Default: <WorkDir>\nvidia-driver-builder.log.

.EXAMPLE
    .\nvidia-driver-builder.ps1 -DriverVersion 582.28

.EXAMPLE
    .\nvidia-driver-builder.ps1 -DriverVersion 582.28 -LocalPackage D:\Drivers\582.28.exe

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="NVIDIA driver version to build, e.g. 582.28")]
    [string]$DriverVersion,

    [Parameter(Mandatory=$false)]
    [string]$OutputDir,

    [Parameter(Mandatory=$false)]
    [string]$WorkDir,

    [Parameter(Mandatory=$false)]
    [string]$ConfigFile,

    [Parameter(Mandatory=$false)]
    [string]$LocalPackage,

    [Parameter(Mandatory=$false)]
    [switch]$SkipTweaks,

    [Parameter(Mandatory=$false)]
    [switch]$SkipSigning,

    [Parameter(Mandatory=$false)]
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
# PowerShell 7.3+ can promote native-command stderr to a terminating error. We
# inspect exit codes ourselves, so turn that off when the property exists.
if ($PSVersionTable.PSVersion.Major -ge 7) {
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
$script:InfsTweaked = 0

New-Item -ItemType Directory -Force -Path $WorkDir   | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

#---------[ Logging ]---------
function Write-Log {
    # Writes to the HOST stream on purpose. A function that logs must never
    # pollute the success stream, or its return value silently becomes an array
    # of log lines plus the real result.
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$false)][ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

#---------[ Profile ]---------
function Import-NvidiaProfile {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "NVIDIA driver profile not found: $ConfigFile"
    }
    try {
        $p = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        throw "NVIDIA driver profile is not valid JSON: $_"
    }
    if (-not $p.resolver -or -not $p.resolver.urlTemplates) {
        throw "NVIDIA driver profile is missing resolver.urlTemplates"
    }
    if (-not $p.components -or -not $p.components.keepFolders) {
        throw "NVIDIA driver profile is missing components.keepFolders"
    }
    return $p
}

#---------[ Toolchain discovery ]---------
function Get-KitToolPath {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string[]]$RelativeCandidates
    )
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $versions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        foreach ($v in $versions) {
            foreach ($rel in $RelativeCandidates) {
                $candidate = Join-Path $v.FullName $rel
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }
    return $null
}

function Test-DriverToolchain {
    # signtool ships with the Windows SDK, inf2cat with the Windows Driver Kit.
    $signtool = Get-KitToolPath -Name 'signtool.exe' -RelativeCandidates @('x64\signtool.exe', 'x86\signtool.exe')
    $inf2cat  = Get-KitToolPath -Name 'inf2cat.exe' -RelativeCandidates @('x86\inf2cat.exe', 'x64\inf2cat.exe')
    return @{ signtool = $signtool; inf2cat = $inf2cat }
}

function Get-SevenZipPath {
    $candidates = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "7-Zip (7z.exe) was not found; it is required to unpack the NVIDIA installer."
}

#---------[ Stage 1: resolve ]---------
function Get-DriverDownloadUrl {
    param([Parameter(Mandatory=$true)]$NvProfile)

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($branch in $NvProfile.resolver.branchCandidates) {
        foreach ($tpl in $NvProfile.resolver.urlTemplates) {
            $urls.Add($tpl.Replace('{version}', $script:DriverVersion).Replace('{branch}', $branch))
        }
    }
    return $urls
}

#---------[ Stage 2: download ]---------
function Test-LooksLikeDriverPackage {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][int64]$MinBytes)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt $MinBytes) { return $false }

    # A real driver package is a PE executable. Read the two magic bytes only -
    # never load a ~900 MB file into memory.
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $b0 = $stream.ReadByte()
        $b1 = $stream.ReadByte()
    } finally {
        $stream.Dispose()
    }
    return ($b0 -eq 0x4D -and $b1 -eq 0x5A)   # 'MZ'
}

function Invoke-Download {
    # Returns [bool]. Never returns the downloaded object, so callers can test it.
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][int64]$MinBytes
    )
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    $aria = Get-Command aria2c.exe -ErrorAction SilentlyContinue
    if ($aria) {
        $dir  = Split-Path -Parent $Destination
        $leaf = Split-Path -Leaf $Destination
        & $aria.Source `
            --console-log-level=warn `
            --summary-interval=0 `
            --max-connection-per-server=8 `
            --split=8 `
            --min-split-size=5M `
            --max-tries=3 `
            --retry-wait=3 `
            --timeout=60 `
            --connect-timeout=30 `
            --allow-overwrite=true `
            --auto-file-renaming=false `
            --file-allocation=none `
            --dir=$dir `
            --out=$leaf `
            $Url 2>&1 | Out-Null
    } else {
        Write-Log "aria2c not found; falling back to Invoke-WebRequest"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
        } catch {
            Write-Log "  download error: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }

    if (-not (Test-LooksLikeDriverPackage -Path $Destination -MinBytes $MinBytes)) {
        if (Test-Path -LiteralPath $Destination) {
            $got = (Get-Item -LiteralPath $Destination).Length
            Write-Log ("  rejected: {0} MB, not a driver package" -f [math]::Round($got / 1MB, 1)) 'WARN'
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    return $true
}

function Get-DriverPackage {
    param([Parameter(Mandatory=$true)]$NvProfile)

    $minBytes = [int64]$NvProfile.resolver.minPackageBytes
    $dest = Join-Path $WorkDir ("nvidia-{0}.exe" -f $script:DriverVersion)

    if ($LocalPackage) {
        if (-not (Test-Path -LiteralPath $LocalPackage)) {
            throw "LocalPackage not found: $LocalPackage"
        }
        if (-not (Test-LooksLikeDriverPackage -Path $LocalPackage -MinBytes $minBytes)) {
            $got = (Get-Item -LiteralPath $LocalPackage).Length
            throw "LocalPackage is only $([math]::Round($got / 1MB, 1)) MB and is not a usable driver package: $LocalPackage"
        }
        Write-Log ("Using local NVIDIA package: {0} ({1} MB)" -f $LocalPackage, [math]::Round((Get-Item -LiteralPath $LocalPackage).Length / 1MB, 1))
        return $LocalPackage
    }

    if (Test-LooksLikeDriverPackage -Path $dest -MinBytes $minBytes) {
        Write-Log "Reusing cached package: $dest"
        return $dest
    }

    foreach ($url in (Get-DriverDownloadUrl -NvProfile $NvProfile)) {
        Write-Log "Trying $url"
        if (Invoke-Download -Url $url -Destination $dest -MinBytes $minBytes) {
            Write-Log ("Downloaded {0} MB" -f [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1))
            return $dest
        }
    }
    throw "Could not download the NVIDIA $($script:DriverVersion) package from any known URL. Check the version number, or pass -LocalPackage."
}

#---------[ Stage 3: extract ]---------
function Expand-NvidiaPackage {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    $extractDir = Join-Path $WorkDir 'nvidia-extracted'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    $sevenZip = Get-SevenZipPath
    Write-Log "Extracting with $sevenZip"
    & $sevenZip x -y -bso0 -bsp0 ("-o{0}" -f $extractDir) $PackagePath
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to extract the NVIDIA package (exit code $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $extractDir)) {
        throw "Extraction produced no output directory"
    }
    return $extractDir
}

#---------[ Stage 4: prune ]---------
function Remove-NvidiaComponents {
    # Allowlist-based: only the folders in components.keepFolders survive. This
    # drops every optional component (Ansel, telemetry, HD Audio, PhysX,
    # NvContainer, NVIDIA App, ...) in one pass.
    param([Parameter(Mandatory=$true)][string]$ExtractDir, [Parameter(Mandatory=$true)]$NvProfile)

    $keep = @($NvProfile.components.keepFolders)
    Write-Log "Pruning to: $($keep -join ', ')"

    $removed = 0
    foreach ($dir in (Get-ChildItem -LiteralPath $ExtractDir -Directory -ErrorAction SilentlyContinue)) {
        if ($keep -contains $dir.Name) { continue }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    # The bundled installers are not needed for offline injection.
    foreach ($file in (Get-ChildItem -LiteralPath $ExtractDir -File -ErrorAction SilentlyContinue)) {
        if ($file.Extension -in @('.exe', '.msi')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Removed $removed optional component folder(s)"
    return $removed
}

#---------[ Stage 5: tweak ]---------
function Get-InfInstallTargets {
    # Works out which DDInstall sections the tweak AddReg section must be attached
    # to. The correct set is the sections that the [Manufacturer] models sections
    # point at, plus their .HW variants.
    #
    # Matching on the section NAME does not work: NVIDIA names its install sections
    # [Section001]..[Section0NN], so a DDInstall/nv_/install name filter misses
    # almost every one of them. Following the [Manufacturer] -> models -> DDInstall
    # chain is layout-independent and always correct.
    param([Parameter(Mandatory=$true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines)

    $headerIdx = @{}
    $firstAddRegIdx = @{}
    $current = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $current = $Matches[1]
            if (-not $headerIdx.ContainsKey($current)) { $headerIdx[$current] = $i }
            continue
        }
        if ($current -and -not $firstAddRegIdx.ContainsKey($current) -and $line -match '^\s*AddReg\s*=') {
            $firstAddRegIdx[$current] = $i
        }
    }

    # The models sections that [Manufacturer] points at.
    $modelSections = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $current = $Matches[1]; continue }
        if ($current -ieq 'Manufacturer' -and $line -match '^\s*[^;=]+\s*=\s*([^,]+)') {
            $base = $Matches[1].Trim()
            foreach ($key in @($headerIdx.Keys)) {
                if ($key -eq $base -or $key -like "$base.*") {
                    if (-not $modelSections.Contains($key)) { $modelSections.Add($key) }
                }
            }
        }
    }

    # The DDInstall sections referenced from those models sections.
    $targets = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $current = $Matches[1]; continue }
        if ($modelSections.Contains($current) -and $line -match '=\s*([^,]+?)\s*,') {
            $t = $Matches[1].Trim()
            if ($t -and -not $targets.Contains($t)) { $targets.Add($t) }
        }
    }

    # Fallback: no usable [Manufacturer] chain - attach to every section that
    # declares AddReg, which is what we want anyway.
    if ($targets.Count -eq 0) {
        foreach ($key in @($firstAddRegIdx.Keys)) { $targets.Add($key) }
    }

    return [pscustomobject]@{
        HeaderIdx      = $headerIdx
        FirstAddRegIdx = $firstAddRegIdx
        Targets        = $targets
    }
}

function Get-DisplayInfFiles {
    # Every display INF in the driver folder. A DCH package splits devices across
    # dozens of INFs - nv_dispi.inf, nvami.inf, nvbli.inf, nvdmi.inf, nvlti.inf and
    # so on, one per GPU family - and each one is self-contained (no Include=/Needs=).
    # The tweaks therefore have to be applied to ALL of them, not just the first, or
    # most GPUs would silently keep the untouched driver.
    param([Parameter(Mandatory=$true)][string]$DriverDir, [Parameter(Mandatory=$true)]$NvProfile)

    $glob = [string]$NvProfile.components.displayInfGlob
    if ([string]::IsNullOrWhiteSpace($glob)) { $glob = 'nv*.inf' }

    $infs = @(Get-ChildItem -LiteralPath $DriverDir -Filter $glob -File -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) {
        $infs = @(Get-ChildItem -LiteralPath $DriverDir -Filter '*.inf' -File -ErrorAction SilentlyContinue)
    }
    return $infs
}

function Add-TweakSectionToInf {
    # Attaches the tweak AddReg section to every DDInstall section and .HW variant
    # in a single INF. Returns the number of sections wired.
    param(
        [Parameter(Mandatory=$true)][string]$InfPath,
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Entries
    )

    $lines = @(Get-Content -LiteralPath $InfPath)
    if ($lines.Count -eq 0) { return 0 }
    $index = Get-InfInstallTargets -Lines $lines

    # Attach to each DDInstall section and, where it exists, its .HW variant.
    # HKR resolves to the software key in DDInstall and the hardware key in
    # DDInstall.HW, so covering both is what makes the tweaks land correctly.
    $insertAfter = @{}
    foreach ($t in $index.Targets) {
        foreach ($name in @($t, "$t.HW")) {
            if (-not $index.HeaderIdx.ContainsKey($name)) { continue }
            if ($index.FirstAddRegIdx.ContainsKey($name)) {
                $insertAfter[$index.FirstAddRegIdx[$name]] = $true
            } else {
                $insertAfter[$index.HeaderIdx[$name]] = $true
            }
        }
    }
    if ($insertAfter.Count -eq 0) { return 0 }

    $out = New-Object System.Collections.Generic.List[string]
    $wired = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $out.Add($lines[$i])
        if ($insertAfter.ContainsKey($i)) { $out.Add("AddReg=$Section"); $wired++ }
    }

    $out.Add('')
    $out.Add('; --- Tiny11 debloated-driver tweaks (injected by nvidia-driver-builder.ps1) ---')
    $out.Add("[$Section]")
    foreach ($e in $Entries) { $out.Add($e) }

    Set-Content -LiteralPath $InfPath -Value $out -Encoding ASCII
    return $wired
}

function Set-NvidiaInfTweaks {
    # Writes the tweaks into every display INF as AddReg entries. Editing the INFs
    # invalidates NVIDIA's catalogs - the caller must re-sign afterwards.
    param([Parameter(Mandatory=$true)][string]$DriverDir, [Parameter(Mandatory=$true)]$NvProfile)

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($t in $NvProfile.tweaks.addReg) {
        foreach ($e in $t.entries) { $entries.Add([string]$e) }
    }
    if ($entries.Count -eq 0) {
        Write-Log "No tweaks defined in the profile" 'WARN'
        return 0
    }

    $section = [string]$NvProfile.tweaks.sectionName
    if ([string]::IsNullOrWhiteSpace($section)) { $section = 'Tiny11NvidiaTweaks' }

    $infs = @(Get-DisplayInfFiles -DriverDir $DriverDir -NvProfile $NvProfile)
    if ($infs.Count -eq 0) {
        throw "No display INF found in $DriverDir"
    }
    Write-Log "Display INFs to tweak: $($infs.Count)"

    $entryArray = $entries.ToArray()
    $totalWired = 0
    $tweakedInfs = 0
    foreach ($inf in $infs) {
        $wired = Add-TweakSectionToInf -InfPath $inf.FullName -Section $section -Entries $entryArray
        if ($wired -gt 0) { $tweakedInfs++; $totalWired += $wired }
    }
    if ($tweakedInfs -eq 0) {
        throw "Could not attach '$section' to any install section; the INF layout may have changed."
    }

    $script:InfsTweaked = $tweakedInfs
    Write-Log "Wired '$section' into $totalWired install section(s) across $tweakedInfs INF(s)"
    return $totalWired
}

#---------[ Stage 6: sign ]---------
function New-DriverSigningCertificate {
    param([Parameter(Mandatory=$true)]$NvProfile)

    $subject = [string]$NvProfile.signing.subject
    if ([string]::IsNullOrWhiteSpace($subject)) { $subject = 'CN=Tiny11 NVIDIA Driver Rebuild' }

    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(10)

    $cerPath  = Join-Path $OutputDir 'tinynvidia-driver.cer'
    $pfxPath  = Join-Path $WorkDir  'tinynvidia-driver.pfx'
    $password = 'tiny11'
    $secure   = ConvertTo-SecureString -String $password -Force -AsPlainText

    Export-Certificate     -Cert $cert -FilePath $cerPath -Force | Out-Null
    Export-PfxCertificate  -Cert $cert -FilePath $pfxPath -Password $secure -Force | Out-Null

    Write-Log "Generated signing certificate $($cert.Thumbprint)"
    return [pscustomobject]@{ Thumbprint = $cert.Thumbprint; CerPath = $cerPath; PfxPath = $pfxPath; Password = $password }
}

function Set-DriverSignature {
    param(
        [Parameter(Mandatory=$true)][string]$DriverDir,
        [Parameter(Mandatory=$true)]$Signing,
        [Parameter(Mandatory=$true)]$Toolchain,
        [Parameter(Mandatory=$true)]$NvProfile
    )

    $signtool = $Toolchain.signtool
    if (-not $signtool) {
        Write-Log "signtool.exe not found - the driver will not be re-signed" 'WARN'
        return $false
    }
    $timestamp = [string]$NvProfile.signing.timestampUrl
    if ([string]::IsNullOrWhiteSpace($timestamp)) { $timestamp = 'http://timestamp.digicert.com' }

    $binaries = Get-ChildItem -LiteralPath $DriverDir -Recurse -File -Include '*.sys', '*.dll' -ErrorAction SilentlyContinue
    Write-Log "Signing $($binaries.Count) driver binary/binaries"
    foreach ($bin in $binaries) {
        & $signtool sign /fd SHA256 /f $Signing.PfxPath /p $Signing.Password /t $timestamp $bin.FullName | Out-Null
    }

    if ($Toolchain.inf2cat -and $NvProfile.signing.rebuildCatalog) {
        Write-Log "Rebuilding the catalog with inf2cat"
        & $Toolchain.inf2cat /driver:$DriverDir /os:10_X64,11_X64 | Out-Null
        $catalogs = Get-ChildItem -LiteralPath $DriverDir -Filter '*.cat' -File -ErrorAction SilentlyContinue
        foreach ($cat in $catalogs) {
            & $signtool sign /fd SHA256 /f $Signing.PfxPath /p $Signing.Password /t $timestamp $cat.FullName | Out-Null
        }
        Write-Log "Signed $($catalogs.Count) catalog(s)"
    } else {
        Write-Log "inf2cat.exe (WDK) not available or catalog rebuild disabled" 'WARN'
    }
    return $true
}

#---------[ Stage 7: report ]---------
function Export-NvidiaDriverReport {
    param(
        [Parameter(Mandatory=$true)][string]$DriverDir,
        [Parameter(Mandatory=$true)][int]$RemovedFolders,
        [Parameter(Mandatory=$true)][int]$TweaksWired,
        [Parameter(Mandatory=$true)][bool]$Resigned,
        [Parameter(Mandatory=$false)][string]$CertPath
    )

    $infs = @(Get-ChildItem -LiteralPath $DriverDir -Filter '*.inf' -File -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) {
        throw "No display INF found in the produced driver folder ($DriverDir)"
    }

    $files = Get-ChildItem -LiteralPath $DriverDir -Recurse -File
    $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $sizeBytes) { $sizeBytes = 0 }

    $report = [pscustomobject]@{
        profile            = 'nvidia-debloated-driver'
        driver_version     = $script:DriverVersion
        success            = $true
        display_inf        = $infs[0].Name
        display_inf_count  = $infs.Count
        infs_tweaked       = $script:InfsTweaked
        driver_dir         = $DriverDir
        file_count         = $files.Count
        size_bytes         = [int64]$sizeBytes
        size_mb            = [math]::Round($sizeBytes / 1MB, 1)
        removed_folders    = $RemovedFolders
        tweaks_wired       = $TweaksWired
        resigned           = $Resigned
        certificate        = $CertPath
        timestamp          = (Get-Date).ToString('o')
    }
    $reportPath = Join-Path $OutputDir 'nvidia-driver-buildinfo.json'
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8

    Write-Log "Driver ready: $DriverDir ($($report.file_count) files, $($report.size_mb) MB, tweaks=$TweaksWired, resigned=$Resigned)"
    Write-Log "Report: $reportPath"
    return $report
}

#---------[ Main ]---------
try {
    Write-Log "=== NVIDIA debloated driver builder (clean-room) ==="
    Write-Log "Driver version : $($script:DriverVersion)"
    Write-Log "Output         : $OutputDir"
    Write-Log "Work           : $WorkDir"

    if ($script:DriverVersion -notmatch '^\d{3}\.\d{2,3}(\.\d{2})?$') {
        Write-Log "Driver version '$($script:DriverVersion)' does not look like an NVIDIA version (expected e.g. 582.28)" 'WARN'
    }

    $nvProfile = Import-NvidiaProfile
    Write-Log "Profile: $($nvProfile.profile) (schema $($nvProfile.schemaVersion))"

    $toolchain = Test-DriverToolchain
    $sigState = if ($toolchain.signtool) { 'yes' } else { 'no' }
    $catState = if ($toolchain.inf2cat)  { 'yes' } else { 'no' }
    Write-Log "Toolchain: signtool=$sigState inf2cat=$catState"

    $wantTweaks = [bool]$nvProfile.tweaks.enabled -and (-not $SkipTweaks)
    $canTweak   = [bool]$toolchain.signtool -and [bool]$toolchain.inf2cat -and (-not $SkipSigning)
    if ($wantTweaks -and -not $canTweak) {
        Write-Log "INF tweaks were requested but the WDK/SDK toolchain is unavailable." 'WARN'
        Write-Log "Skipping tweaks so NVIDIA's signature stays valid and the driver still installs." 'WARN'
        $wantTweaks = $false
    }

    $package = Get-DriverPackage -NvProfile $nvProfile
    $extract = Expand-NvidiaPackage -PackagePath $package
    $removed = Remove-NvidiaComponents -ExtractDir $extract -NvProfile $nvProfile

    $driverSrc = Join-Path $extract 'Display.Driver'
    if (-not (Test-Path -LiteralPath $driverSrc)) {
        throw "Display.Driver was not found after extraction; the NVIDIA package layout may have changed."
    }

    $driverOut = Join-Path $OutputDir 'driver'
    if (Test-Path -LiteralPath $driverOut) {
        Remove-Item -LiteralPath $driverOut -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $driverOut | Out-Null
    Copy-Item -Path (Join-Path $driverSrc '*') -Destination $driverOut -Recurse -Force

    $tweaksWired = 0
    if ($wantTweaks) {
        $tweaksWired = Set-NvidiaInfTweaks -DriverDir $driverOut -NvProfile $nvProfile
    } else {
        Write-Log "INF tweaks skipped"
    }

    $resigned = $false
    $certPath = $null
    if ($tweaksWired -gt 0 -and -not $SkipSigning) {
        try {
            $signing  = New-DriverSigningCertificate -NvProfile $nvProfile
            $resigned = Set-DriverSignature -DriverDir $driverOut -Signing $signing -Toolchain $toolchain -NvProfile $nvProfile
            if (-not $resigned) { throw "signtool was unavailable" }
            $certPath = $signing.CerPath
        } catch {
            throw "INF tweaks were applied but re-signing failed ($_). Refusing to emit a driver whose catalog no longer matches NVIDIA's signature."
        }
    }

    $null = Export-NvidiaDriverReport -DriverDir $driverOut -RemovedFolders $removed `
        -TweaksWired $tweaksWired -Resigned $resigned -CertPath $certPath

    Write-Log "=== NVIDIA debloated driver builder finished successfully ==="
    exit 0
} catch {
    Write-Log "FATAL: $_" 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
    try {
        [pscustomobject]@{
            profile        = 'nvidia-debloated-driver'
            driver_version = $script:DriverVersion
            success        = $false
            error          = "$_"
            timestamp      = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $OutputDir 'nvidia-driver-buildinfo.json') -Encoding UTF8
    } catch { }
    exit 1
}
