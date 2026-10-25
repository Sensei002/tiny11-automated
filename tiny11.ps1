<#
.SYNOPSIS
    One-line installer for the Tiny11 Local Builder.

.DESCRIPTION
    The target of the short command:

        irm https://github.com/Sensei002/tiny11-automated/releases/latest/download/tiny11.ps1 | iex

    It deliberately does almost nothing. It downloads a pinned copy of the repository,
    verifies it if a hash was supplied, unpacks it under LOCALAPPDATA, and starts the
    GUI. The GUI then relaunches itself elevated, because only the DISM work needs an
    admin token - the download does not. Keeping the download unelevated means a
    tampered archive cannot do anything until a human clicks through UAC.

    This script must stay self-contained: it runs before any of the repository is on
    disk, so it cannot rely on local/lib.ps1.

.PARAMETER Ref
    Branch, tag or commit SHA to install. Pin this to a tag for reproducible installs.

.PARAMETER Sha256
    Expected SHA256 of the downloaded archive. When supplied, a mismatch is fatal.

.PARAMETER InstallDir
    Where to unpack. Defaults to %LOCALAPPDATA%\tiny11-automated\app.

.PARAMETER NoLaunch
    Unpack only; do not start the GUI.

.EXAMPLE
    irm https://github.com/Sensei002/tiny11-automated/releases/latest/download/tiny11.ps1 | iex

.EXAMPLE
    .\install.ps1 -Ref v1.2.0 -Sha256 3f2a...
#>
param(
    [string]$Owner = 'Sensei002',
    [string]$Repo = 'tiny11-automated',
    [string]$Ref = 'main',
    [string]$Sha256 = '',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'tiny11-automated\app'),
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ArchiveUrl {
    <#
    .SYNOPSIS
        codeload URL for a repository archive at a branch, tag or SHA.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$Ref = 'main'
    )

    return "https://codeload.github.com/$Owner/$Repo/zip/$Ref"
}

function Assert-ArchiveHash {
    <#
    .SYNOPSIS
        Throws unless the file matches the expected SHA256.

    .DESCRIPTION
        No hash means no pinning, which is allowed but reported. A supplied hash that
        does not match is always fatal - that is the only case where this can protect
        anyone, so it must not be a warning.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Expected
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Write-Output 'No SHA256 supplied - skipping verification. Pass -Sha256 to pin this install.'
        return
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $wanted = $Expected -replace '[^0-9A-Fa-f]', ''

    if ($actual -ne $wanted) {
        throw "Archive hash mismatch.`n  expected: $wanted`n  actual:   $actual"
    }

    Write-Output 'Archive hash verified.'
}

function Expand-RepoArchive {
    <#
    .SYNOPSIS
        Unpacks a GitHub archive, stripping the single wrapper folder it contains.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("tiny11-unpack-" + [guid]::NewGuid().ToString('N'))

    # Expand-Archive writes a progress bar straight to the host, which turns a
    # one-line install into hundreds of lines of redraws in a console or in a
    # captured log.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
    } finally {
        $ProgressPreference = $previousProgress
    }

    $roots = @(Get-ChildItem -LiteralPath $staging -Directory)
    if ($roots.Count -ne 1) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw "Expected one folder inside the archive, found $($roots.Count)."
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    Get-ChildItem -LiteralPath $roots[0].FullName -Force | Move-Item -Destination $Destination -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    return $Destination
}

function Install-Tiny11LocalBuilder {
    <#
    .SYNOPSIS
        Downloads, verifies, unpacks and optionally launches the builder.
    #>
    param(
        [string]$Owner = 'Sensei002',
        [string]$Repo = 'tiny11-automated',
        [string]$Ref = 'main',
        [string]$Sha256 = '',
        [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'tiny11-automated\app'),
        [switch]$NoLaunch
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $url = Get-ArchiveUrl -Owner $Owner -Repo $Repo -Ref $Ref
    Write-Output "Downloading $url"

    $archive = Join-Path ([System.IO.Path]::GetTempPath()) ("tiny11-" + [guid]::NewGuid().ToString('N') + '.zip')
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    } finally {
        $ProgressPreference = $previous
    }

    try {
        Assert-ArchiveHash -Path $archive -Expected $Sha256
        Expand-RepoArchive -ArchivePath $archive -Destination $InstallDir | Out-Null
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }

    $gui = Join-Path $InstallDir 'local\gui.ps1'
    if (-not (Test-Path -LiteralPath $gui)) {
        throw "The archive did not contain local\gui.ps1 - is '$Ref' the right ref?"
    }

    Write-Output "Installed to $InstallDir"

    if ($NoLaunch) { return $InstallDir }

    Write-Output 'Starting the builder - it will ask for administrator rights.'
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gui)

    return $InstallDir
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-Tiny11LocalBuilder -Owner $Owner -Repo $Repo -Ref $Ref -Sha256 $Sha256 `
        -InstallDir $InstallDir -NoLaunch:$NoLaunch
}
