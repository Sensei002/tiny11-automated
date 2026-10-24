<#
.SYNOPSIS
    Brings a mounted Windows image up to the newest cumulative update Microsoft
    has published for its build, before the debloat passes run.

.DESCRIPTION
    Microsoft's download page serves a static ISO. On this project that is build
    26300.9457 while Windows Update is already at 26300.9711, so every image built
    from the media ships weeks behind - missing the security fixes and the feature
    bits that arrive inside cumulative updates.

    This script closes that gap without replacing the ISO pipeline:

      1. map the image's build family (26300) to the catalog's product name
      2. ask the Microsoft Update Catalog for the newest cumulative update
      3. download it (plus the checkpoint prerequisite, when the catalog lists one)
      4. DISM /Add-Package into the mounted image
      5. prove the image build actually moved

    It runs BEFORE the debloat passes on purpose. Debloating after the update means
    the removals act on the final payload rather than on a superseded one, and it
    must run before Optimize-WinSxS: gutting the component store first removes the
    servicing stack that Add-Package needs.

    Everything is best-effort by default. A missing update, a failed download or a
    package the image rejects logs a warning and lets the build continue at its
    base build, because shipping an unpatched image is better than shipping none.
    Pass -RequireUpdate to turn any of those into a hard failure.

.PARAMETER ImageDir
    Path to the mounted Windows image (the DISM mount point).

.PARAMETER DownloadDir
    Where the .msu packages are downloaded. Defaults to a folder beside the image.

.PARAMETER ImageVersion
    The image's version, e.g. '26300.9457'. Only the build family (26300) is used,
    to pick the right product name in the catalog.

.PARAMETER Arch
    'x64' or 'arm64'. Matches the catalog's '<arch>-based Systems' titles.

.PARAMETER RequireUpdate
    Fail the build when no update can be found or applied. Off by default.

.PARAMETER DryRun
    Resolve and report what would be installed, without downloading anything.

.PARAMETER KeepPackages
    Keep the downloaded .msu files instead of deleting them afterwards.

.EXAMPLE
    .\apply-latest-lcu.ps1 -ImageDir D:\scratchdir -ImageVersion 26300.9457 -Arch x64

.EXAMPLE
    .\apply-latest-lcu.ps1 -ImageDir D:\scratchdir -ImageVersion 26300.9457 -DryRun

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$ImageDir,
    [string]$DownloadDir,
    [string]$ImageVersion,
    [string]$Arch = 'x64',
    [switch]$RequireUpdate,
    [switch]$DryRun,
    [switch]$KeepPackages,
    [string]$LogFile
)

# Deliberately NOT set at script scope: this file is dot-sourced by its tests, and
# a script-scope assignment would rewrite the caller's error preference.

# The catalog is queried by product name, not by build number. Searching for
# '26300' happens to work, but '26100' returns nothing and '24H2' returns graphics
# drivers, so the mapping is explicit. The two commented entries share a build with
# the consumer release and take the same cumulative update.
$script:BuildFamilyProducts = @{
    22000 = 'Windows 11, version 21H2'
    22621 = 'Windows 11, version 22H2'
    22631 = 'Windows 11, version 23H2'
    26100 = 'Windows 11, version 24H2'   # also Windows 11 Enterprise LTSC 2024
    26200 = 'Windows 11, version 25H2'
    26300 = 'Windows 11, version 26H2'
    19044 = 'Windows 10 Version 21H2'    # also Windows 10 Enterprise LTSC 2021
    19045 = 'Windows 10 Version 22H2'
}

$script:CatalogBase = 'https://www.catalog.update.microsoft.com'
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) tiny11-automated'

# Declared here rather than left to default: the builders run under
# Set-StrictMode -Version Latest, where reading an unassigned variable throws.
$script:LcuLogFile = $null

#---------[ Logging ]---------#

function Write-LcuLog {
    # Write-Host rather than Write-Output: the functions in this file return
    # values, and emitting log lines on the success stream would corrupt them.
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [LCU] [$Level] $Message"
    Write-Host $line
    if ($script:LcuLogFile) {
        Add-Content -Path $script:LcuLogFile -Value $line -ErrorAction SilentlyContinue
    }
}

#---------[ Pure helpers ]---------#

function Get-BuildFamily {
    <#
    .SYNOPSIS
        The 5-digit build family from a version string: '10.0.26300.9711' -> 26300.
    #>
    param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return 0 }
    if ($Version -match '(\d{5})\.\d+') { return [int]$Matches[1] }
    if ($Version -match '^\s*(\d{5})\s*$') { return [int]$Matches[1] }
    return 0
}

function Get-UpdateSearchQuery {
    <#
    .SYNOPSIS
        The exact catalog phrase for a build family, or $null when unmapped.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Family,
        [string]$Arch = 'x64'
    )

    if (-not $script:BuildFamilyProducts.ContainsKey($Family)) { return $null }
    return "Cumulative Update for $($script:BuildFamilyProducts[$Family]) for $Arch-based Systems"
}

function ConvertFrom-CatalogSearchHtml {
    <#
    .SYNOPSIS
        Turns a catalog search page into update records.

    .DESCRIPTION
        The catalog is an ASP.NET page. Each result row carries the update GUID in
        the row id and the title in an anchor whose id is single-quoted - matching
        only double quotes silently returns zero rows, which is how the first
        version of this parser failed.
    #>
    param([Parameter(Mandatory = $true)][string]$Html)

    $records = @()
    $rows = [regex]::Matches($Html, '<tr[^>]*id="([0-9a-f-]{36})_R\d+"[^>]*>(.*?)</tr>', 'Singleline')

    foreach ($row in $rows) {
        $updateId = $row.Groups[1].Value
        $body = $row.Groups[2].Value

        $titleMatch = [regex]::Match($body, "id=[""'][0-9a-f-]{36}_link[""'][^>]*>([^<]+)<")
        if (-not $titleMatch.Success) { continue }

        $title = [regex]::Replace($titleMatch.Groups[1].Value, '\s+', ' ').Trim()

        $kb = ''
        $kbMatch = [regex]::Match($title, '(KB\d{7})')
        if ($kbMatch.Success) { $kb = $kbMatch.Groups[1].Value }

        # Windows 11 titles end in '(<build>.<rev>)'; Windows 10 titles carry no
        # build at all, so this stays empty there and the caller must not require it.
        $targetBuild = ''
        $buildMatch = [regex]::Match($title, '\((\d{5}\.\d+)\)')
        if ($buildMatch.Success) { $targetBuild = $buildMatch.Groups[1].Value }

        # Every cumulative update title starts with the release month.
        $month = ''
        $monthMatch = [regex]::Match($title, '^(\d{4}-\d{2})')
        if ($monthMatch.Success) { $month = $monthMatch.Groups[1].Value }

        $records += [pscustomobject]@{
            UpdateId    = $updateId
            Title       = $title
            Kb          = $kb
            TargetBuild = $targetBuild
            Month       = $month
        }
    }

    return $records
}

function Select-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        Picks the newest OS cumulative update from a parsed result set.

    .DESCRIPTION
        Filters out everything that is not the OS update itself:
          - 'Dynamic Cumulative Update' is the same KB listed a second time
          - .NET Framework cumulative updates share the phrase but not the payload
          - Server updates look identical apart from the word Server
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Updates,
        [string]$Arch = 'x64',
        [int]$Family = 0
    )

    $archPattern = '(?i)' + [regex]::Escape($Arch) + '-based'
    $filtered = @($Updates | Where-Object {
            $_.Title -match '(?i)cumulative update for windows' -and
            $_.Title -notmatch '(?i)\bdynamic\b' -and
            $_.Title -notmatch '(?i)\bserver\b' -and
            $_.Title -notmatch '(?i)\.net framework' -and
            $_.Title -match $archPattern
        })

    if ($Family -gt 0) {
        # When the title carries a build it must belong to this family. Windows 10
        # titles carry none, so an empty value is not a mismatch.
        $filtered = @($filtered | Where-Object {
                [string]::IsNullOrEmpty($_.TargetBuild) -or $_.TargetBuild.StartsWith("$Family.")
            })
    }

    if ($filtered.Count -eq 0) { return $null }

    $sorted = @($filtered | Sort-Object -Property `
        @{ Expression = { $_.Month }; Descending = $true }, `
        @{ Expression = { $_.TargetBuild }; Descending = $true })

    return $sorted[0]
}

function Get-PackageSortKey {
    <#
    .SYNOPSIS
        Orders packages so prerequisites come first.

    .DESCRIPTION
        A catalog bundle can contain a checkpoint cumulative update alongside the
        current one (KB5043080 for 24H2/26H2). The checkpoint must be present
        before the newer update applies, and its KB number is always the lower of
        the two, so ascending KB order is the correct order to hand to DISM.
    #>
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($Url -match '(?i)kb(\d{7})') { return [int]$Matches[1] }
    return [int]::MaxValue
}

function Test-BuildAdvanced {
    <#
    .SYNOPSIS
        True when $After is a later build than $Before, comparing numerically.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Before,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$After
    )

    if ([string]::IsNullOrWhiteSpace($Before) -or [string]::IsNullOrWhiteSpace($After)) { return $false }
    if ($Before -notmatch '^\d+(\.\d+)*$' -or $After -notmatch '^\d+(\.\d+)*$') { return $false }

    $left = $Before.Split('.') | ForEach-Object { [int]$_ }
    $right = $After.Split('.') | ForEach-Object { [int]$_ }

    $count = [Math]::Max($left.Count, $right.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = if ($i -lt $left.Count) { $left[$i] } else { 0 }
        $r = if ($i -lt $right.Count) { $right[$i] } else { 0 }
        if ($r -gt $l) { return $true }
        if ($r -lt $l) { return $false }
    }
    return $false
}

#---------[ Catalog access ]---------#

function Get-CatalogPage {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Form
    )

    $request = @{
        Uri             = $Url
        UseBasicParsing = $true
        TimeoutSec      = 180
        Headers         = @{ 'User-Agent' = $script:UserAgent }
    }
    if ($Form) {
        $request.Method = 'Post'
        $request.Body = $Form
    }

    # Windows PowerShell draws a progress bar straight to the host for every
    # Invoke-WebRequest, which turns a CI log into hundreds of lines of "Reading
    # web response". Suppress it for the duration of the call only.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        return (Invoke-WebRequest @request).Content
    } finally {
        $ProgressPreference = $previousProgress
    }
}

function Find-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        Returns the newest cumulative update record for a build family.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Family,
        [string]$Arch = 'x64'
    )

    $query = Get-UpdateSearchQuery -Family $Family -Arch $Arch
    if (-not $query) {
        Write-LcuLog "No catalog product mapping for build family $Family. Add it to BuildFamilyProducts, or the image will be built at its base build." 'WARN'
        return $null
    }

    Write-LcuLog "Catalog query: $query"
    $encoded = [System.Uri]::EscapeDataString($query)
    $html = Get-CatalogPage -Url "$($script:CatalogBase)/Search.aspx?q=$encoded"

    $records = ConvertFrom-CatalogSearchHtml -Html $html
    Write-LcuLog "Catalog returned $($records.Count) row(s)"

    $latest = Select-LatestCumulativeUpdate -Updates $records -Arch $Arch -Family $Family
    if (-not $latest) {
        Write-LcuLog "No cumulative update for build family $Family on $Arch." 'WARN'
        return $null
    }

    Write-LcuLog "Newest available: $($latest.Title)"
    return $latest
}

function Get-CatalogDownloadUrls {
    <#
    .SYNOPSIS
        Resolves the direct .msu URLs for one catalog update.
    #>
    param([Parameter(Mandatory = $true)][string]$UpdateId)

    $uidJson = '[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]'
    $form = @{
        updateIDs                = $uidJson
        updateIDsBlockedForImport = ''
        wsusApiPresent           = ''
        contentImport            = ''
        sku                      = ''
        serverName               = ''
        ssl                      = ''
        version                  = ''
        alternateId              = ''
    }

    $html = Get-CatalogPage -Url "$($script:CatalogBase)/DownloadDialog.aspx" -Form $form
    $matches = [regex]::Matches($html, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'")

    $urls = @($matches | ForEach-Object { $_.Groups[1].Value })
    if ($urls.Count -eq 0) {
        throw "The catalog returned no download URL for update $UpdateId."
    }

    return @($urls | Sort-Object -Property @{ Expression = { Get-PackageSortKey -Url $_ } })
}

#---------[ Image work ]---------#

function Get-MountedImageVersion {
    <#
    .SYNOPSIS
        Reads the image build straight off the kernel binary.

    .DESCRIPTION
        Cheaper and more reliable than parsing DISM output: the kernel's file
        version is replaced by every cumulative update, so it is the value that
        proves the package actually landed.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $kernel = Join-Path $Path 'Windows\System32\ntoskrnl.exe'
    if (-not (Test-Path -LiteralPath $kernel)) { return '' }

    $version = (Get-Item -LiteralPath $kernel).VersionInfo.ProductVersion
    if ($version -match '(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

function Save-UpdatePackage {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $name = Split-Path -Leaf $Destination
    $dir = Split-Path -Parent $Destination

    # aria2c is already installed by every build workflow for the ISO download and
    # turns a 4.5 GB fetch from a single stream into eight.
    $aria = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($aria) {
        & aria2c --console-log-level=warn --summary-interval=60 `
            --max-connection-per-server=8 --split=8 --min-split-size=5M `
            --max-tries=5 --retry-wait=3 --continue=true --allow-overwrite=true `
            --auto-file-renaming=false --file-allocation=none `
            "--dir=$dir" "--out=$name" $Url 2>&1 | Out-Host

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Destination)) {
            throw "aria2c failed to download $Url (exit $LASTEXITCODE)."
        }
        return
    }

    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Download did not produce $Destination."
    }
}

function Add-PackageToMountedImage {
    <#
    .SYNOPSIS
        DISM /Add-Package, tolerating a package the image already contains.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [string]$LogPath
    )

    $arguments = @('/English', "/Image:$Path", '/Add-Package', "/PackagePath:$PackagePath")
    if ($LogPath) { $arguments += "/LogPath:$LogPath" }

    $output = & dism @arguments 2>&1
    $code = $LASTEXITCODE

    # 0x800f081e = CBS_E_NOT_APPLICABLE. Expected for a checkpoint package the
    # image already incorporates; it must not fail the build.
    if ($code -eq 0) { return 'applied' }
    if ($code -eq -2146498530 -or $code -eq 2148468766) { return 'not-applicable' }

    $tail = ($output | Select-Object -Last 12) -join [Environment]::NewLine
    throw "DISM /Add-Package failed with exit code $code.`n$tail"
}

#---------[ Orchestrator ]---------#

function Invoke-LatestLcuUpdate {
    <#
    .SYNOPSIS
        Resolves, downloads and applies the newest cumulative update to a mounted
        image, then verifies the build advanced.

    .OUTPUTS
        PSCustomObject: Before, After, Applied, Kb, Title, Packages, Reason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WorkDir,
        [string]$Version,
        [string]$Arch = 'x64',
        [switch]$RequireUpdate,
        [switch]$DryRun,
        [switch]$KeepPackages,
        [string]$LogPath
    )

    $result = [pscustomobject]@{
        Before   = ''
        After    = ''
        Applied  = $false
        Kb       = ''
        Title    = ''
        Packages = 0
        Reason   = ''
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mounted image not found at $Path."
    }

    $before = Get-MountedImageVersion -Path $Path
    if ([string]::IsNullOrWhiteSpace($before) -and $Version) { $before = $Version }
    $result.Before = $before

    $family = Get-BuildFamily -Version $before
    if ($family -eq 0) {
        $message = "Could not determine the image build from '$before'."
        if ($RequireUpdate) { throw $message }
        Write-LcuLog $message 'WARN'
        $result.Reason = 'unknown-build'
        return $result
    }

    Write-LcuLog "Image build $before (family $family, $Arch)"

    $update = Find-LatestCumulativeUpdate -Family $family -Arch $Arch
    if (-not $update) {
        $result.Reason = 'no-update-found'
        if ($RequireUpdate) { throw "No cumulative update found for build family $family." }
        Write-LcuLog 'Continuing without an update - the image keeps its base build.' 'WARN'
        return $result
    }

    $result.Kb = $update.Kb
    $result.Title = $update.Title

    if ($update.TargetBuild -and -not (Test-BuildAdvanced -Before $before -After $update.TargetBuild)) {
        Write-LcuLog "Image is already at or above $($update.TargetBuild) - nothing to do."
        $result.After = $before
        $result.Reason = 'already-current'
        return $result
    }

    if ($DryRun) {
        Write-LcuLog "DRY RUN: would install $($update.Kb) ($($update.TargetBuild))"
        $result.Reason = 'dry-run'
        return $result
    }

    if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) 'tiny11-lcu' }

    # The package is ~5 GB and DISM expands it into the image, so a build that only
    # just cleared the workflow's 25 GB guard can still run out here. Measure the
    # volume that actually receives the download and skip cleanly rather than
    # dying halfway through Add-Package, which would leave a half-applied image.
    $freeGb = $null
    try {
        $root = [System.IO.Path]::GetPathRoot($WorkDir)
        $freeGb = [math]::Round((Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction Stop).Free / 1GB, 1)
    } catch {
        Write-LcuLog "Could not measure free space on $WorkDir - continuing without the check." 'WARN'
    }

    if ($null -ne $freeGb -and $freeGb -lt 12) {
        $message = "Only $freeGb GB free where the update would be staged; it needs about 12 GB."
        if ($RequireUpdate) { throw $message }
        Write-LcuLog "$message Skipping the update." 'WARN'
        $result.Reason = 'low-disk'
        return $result
    }

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    $urls = Get-CatalogDownloadUrls -UpdateId $update.UpdateId
    Write-LcuLog "$($urls.Count) package(s) to install"

    $downloaded = @()
    foreach ($url in $urls) {
        $fileName = [System.IO.Path]::GetFileName(([System.Uri]$url).AbsolutePath)
        $destination = Join-Path $WorkDir $fileName
        Write-LcuLog "Downloading $fileName"
        Save-UpdatePackage -Url $url -Destination $destination
        $sizeMb = [math]::Round((Get-Item -LiteralPath $destination).Length / 1MB, 1)
        Write-LcuLog "  $sizeMb MB"
        $downloaded += $destination
    }

    $result.Packages = $downloaded.Count

    foreach ($package in $downloaded) {
        $name = Split-Path -Leaf $package
        Write-LcuLog "Adding $name"
        $outcome = Add-PackageToMountedImage -Path $Path -PackagePath $package -LogPath $LogPath
        if ($outcome -eq 'not-applicable') {
            Write-LcuLog "  $name is not applicable (already incorporated) - skipped" 'WARN'
        } else {
            Write-LcuLog "  $name applied"
        }
    }

    $after = Get-MountedImageVersion -Path $Path
    $result.After = $after

    if (Test-BuildAdvanced -Before $before -After $after) {
        Write-LcuLog "Image updated: $before -> $after" 'SUCCESS'
        $result.Applied = $true
    } else {
        $result.Reason = 'build-unchanged'
        $message = "Packages were added but the image build is still $after (expected $($update.TargetBuild))."
        if ($RequireUpdate) { throw $message }
        Write-LcuLog $message 'WARN'
    }

    if (-not $KeepPackages) {
        foreach ($package in $downloaded) {
            Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

#---------[ Entry point ]---------#

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($LogFile) { $script:LcuLogFile = $LogFile }

    if ([string]::IsNullOrWhiteSpace($ImageDir)) {
        throw "Specify -ImageDir (the DISM mount point of the image to update)."
    }
    if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
        $DownloadDir = Join-Path ([System.IO.Path]::GetTempPath()) 'tiny11-lcu'
    }

    $outcome = Invoke-LatestLcuUpdate -Path $ImageDir -WorkDir $DownloadDir `
        -Version $ImageVersion -Arch $Arch -RequireUpdate:$RequireUpdate `
        -DryRun:$DryRun -KeepPackages:$KeepPackages

    if ($outcome.Applied) {
        Write-Host "LCU_RESULT=applied BEFORE=$($outcome.Before) AFTER=$($outcome.After) KB=$($outcome.Kb)"
    } else {
        Write-Host "LCU_RESULT=skipped REASON=$($outcome.Reason) BUILD=$($outcome.Before)"
    }

    # Emitted on the success stream so a caller can inspect the outcome instead of
    # scraping the line above:  $lcu = & .\apply-latest-lcu.ps1 -ImageDir ...
    $outcome
}
