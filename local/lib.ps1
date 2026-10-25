<#
.SYNOPSIS
    Pure logic behind the local GUI builder: profile loading, parameter mapping and
    launcher generation.

.DESCRIPTION
    Everything the GUI needs to decide *what to run* lives here, deliberately free of
    any WPF or process code. That keeps the interesting part - mapping a form onto a
    builder's parameters - testable without opening a window, and it means a test can
    assert the mapping still matches the builder's param block.

    The GUI (gui.ps1) is only responsible for collecting values and showing progress.
#>

Set-StrictMode -Version Latest

function Get-LocalBuildProfile {
    <#
    .SYNOPSIS
        Loads and validates config/local_build_profiles.json.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Build profile not found at $Path"
    }

    try {
        $profile = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Build profile at $Path is not valid JSON: $($_.Exception.Message)"
    }

    if (-not $profile.variants -or @($profile.variants).Count -eq 0) {
        throw "Build profile at $Path declares no variants."
    }

    $seen = @{}
    foreach ($variant in $profile.variants) {
        foreach ($field in 'id', 'label', 'workflow', 'builder', 'outputIso', 'paramMap') {
            if (-not $variant.PSObject.Properties[$field] -or
                [string]::IsNullOrWhiteSpace([string]$variant.$field)) {
                throw "Variant '$($variant.id)' is missing required field '$field'."
            }
        }

        if ($seen.ContainsKey($variant.id)) {
            throw "Duplicate variant id '$($variant.id)' in $Path."
        }
        $seen[$variant.id] = $true
    }

    return $profile
}

function Get-BuildVariant {
    <#
    .SYNOPSIS
        Returns one variant by id, or throws listing the valid ids.
    #>
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $match = $Profile.variants | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $match) {
        $valid = ($Profile.variants | ForEach-Object { $_.id }) -join ', '
        throw "Unknown variant '$Id'. Valid variants are: $valid"
    }
    return $match
}

function Get-VariantInput {
    <#
    .SYNOPSIS
        Returns one input definition from a variant, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)]$Variant,
        [Parameter(Mandatory = $true)][string]$Key
    )

    return ($Variant.inputs | Where-Object { $_.key -eq $Key } | Select-Object -First 1)
}

function Get-UpdateModeFlags {
    <#
    .SYNOPSIS
        Turns a tri-state update mode into the two switches the builders take.

    .DESCRIPTION
        'required'    -> -UpdateToLatest -RequireLatestUpdate
        'best-effort' -> -UpdateToLatest
        'off'         -> neither

        An unknown mode falls back to best-effort rather than throwing: a build that
        carries on at its base build is a better outcome than a GUI that refuses to
        start because a config value drifted.
    #>
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Mode
    )

    $entry = $Profile.updateModes | Where-Object { $_.id -eq $Mode } | Select-Object -First 1
    if (-not $entry) {
        $entry = $Profile.updateModes | Where-Object { $_.id -eq 'best-effort' } | Select-Object -First 1
    }
    if (-not $entry) {
        return @{ UpdateToLatest = $false; RequireLatestUpdate = $false }
    }

    return @{
        UpdateToLatest       = [bool]$entry.updateToLatest
        RequireLatestUpdate  = [bool]$entry.requireLatestUpdate
    }
}

function New-BuilderArguments {
    <#
    .SYNOPSIS
        Maps a flat context onto the builder's PowerShell parameters.

    .DESCRIPTION
        Each variant declares paramMap entries of the form '<contextKey>:<type>'. Types:

          string    - passed through, omitted when blank
          int       - cast, so INDEX is never handed over as '6'
          switch    - included only when true, so the launcher stays readable
          hashtable - passed as-is (the gaming groups)
          @static   - always true; a switch the variant implies rather than asks about

        Omitted keys are the point: passing -SkipCleanup:$false everywhere would work
        but makes the generated launcher a worse record of what actually ran.
    #>
    param(
        [Parameter(Mandatory = $true)]$Variant,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $result = [ordered]@{}

    foreach ($entry in $Variant.paramMap.PSObject.Properties) {
        $paramName = $entry.Name
        $spec = [string]$entry.Value
        $parts = $spec.Split(':')
        $source = $parts[0]
        $type = 'string'
        if ($parts.Count -gt 1) { $type = $parts[1] }

        if ($source -eq '@static') {
            $result[$paramName] = $true
            continue
        }

        if (-not $Context.ContainsKey($source)) {
            throw "Variant '$($Variant.id)' maps -$paramName from '$source', which the context does not define."
        }

        $value = $Context[$source]

        if ($type -eq 'int') {
            $result[$paramName] = [int]$value
            continue
        }

        if ($type -eq 'switch') {
            if ($value) { $result[$paramName] = $true }
            continue
        }

        if ($type -eq 'hashtable') {
            if ($value -and @($value.Keys).Count -gt 0) { $result[$paramName] = $value }
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $result[$paramName] = [string]$value
        }
    }

    return $result
}

function Format-PsLiteral {
    <#
    .SYNOPSIS
        Renders a value as PowerShell source that reproduces it exactly.
    #>
    param(
        [Parameter(Mandatory = $false)]$Value
    )

    if ($null -eq $Value) { return '$null' }

    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return [string]$Value
    }

    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        $inner = foreach ($key in $Value.Keys) {
            '    {0} = {1}' -f $key, (Format-PsLiteral -Value $Value[$key])
        }
        return "@{`r`n" + ($inner -join "`r`n") + "`r`n}"
    }

    # Single-quoted: no interpolation, so a path with $ or a quote in it survives.
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function ConvertTo-LauncherScript {
    <#
    .SYNOPSIS
        Writes a launcher that reproduces the build invocation exactly.

    .DESCRIPTION
        The GUI cannot pass -GamingGroups on a command line, and quoting a path with
        spaces through Start-Process is a reliable source of bugs. Generating a small
        script sidesteps both, and leaves a file that says precisely what ran - which
        is the first thing anyone will want when a build fails.
    #>
    param(
        [Parameter(Mandatory = $true)]$Variant,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [Parameter(Mandatory = $true)][string]$BuilderPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $lines = @(
        "# Generated by the Tiny11 Local Builder for variant '$($Variant.id)'."
        '# Kept after the build so a failure can be reproduced exactly as it ran.'
        ''
        '$params = @{'
    )

    # -ISO is always taken from the environment. It cannot be baked in: the drive
    # letter does not exist until the media is mounted, which happens in the parent
    # orchestrator, and New-BuilderArguments deliberately omits blank values - so
    # leaving this to the loop below would silently drop the one mandatory parameter.
    $hasIso = $null -ne $Variant.paramMap.PSObject.Properties['ISO']
    if ($hasIso) {
        $lines += '    ISO = $env:TINY11_ISO_DRIVE'
    }

    foreach ($key in $Arguments.Keys) {
        if ($key -eq 'ISO') { continue }
        $lines += ('    {0} = {1}' -f $key, (Format-PsLiteral -Value $Arguments[$key]))
    }

    $lines += '}'
    $lines += ''
    $lines += 'try {'
    $lines += ('    & {0} @params' -f (Format-PsLiteral -Value $BuilderPath))
    $lines += '    exit 0'
    $lines += '} catch {'
    $lines += '    Write-Output "BUILD FAILED: $($_.Exception.Message)"'
    $lines += '    exit 1'
    $lines += '}'

    $directory = Split-Path -Parent $ScriptPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Set-Content -LiteralPath $ScriptPath -Value ($lines -join "`r`n") -Encoding UTF8
    return $ScriptPath
}

function Get-LtscIndexHint {
    <#
    .SYNOPSIS
        The catalogue index for an LTSC edition, used as a hint only.

    .DESCRIPTION
        The builder takes -ExpectedEdition and re-checks the image name, correcting
        the index if the media numbers its images differently. So this value only has
        to be close; being wrong is survivable, being absent is not.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Edition,
        [Parameter(Mandatory = $true)][string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "LTSC catalogue not found at $CatalogPath"
    }

    . $CatalogPath
    $entry = Resolve-LTSCEdition -Name $Edition
    return [int]$entry.Index
}

function ConvertTo-PipelineScript {
    <#
    .SYNOPSIS
        Writes the whole prepare -> build -> export run as one script.

    .DESCRIPTION
        The GUI runs this and tails its output instead of orchestrating three async
        steps on the UI thread. One child process means one log, one cancel, and one
        place where a failure is reported - and the file survives the run, so a
        failing build can be reproduced by hand.

        The builder is launched as a further child process rather than invoked with
        &. All three builders end in a bare `exit 0` / `exit 1`, and exit terminates
        the host, so calling one directly would skip both the export and the unmount
        below without raising anything.
    #>
    param(
        [Parameter(Mandatory = $true)]$Variant,
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    foreach ($required in 'RepoRoot', 'Source', 'ScratchRoot', 'OutputDir', 'LauncherPath', 'BuiltIsoPath') {
        if (-not $Plan.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$Plan[$required])) {
            throw "Plan is missing '$required'."
        }
    }

    $libPath = Join-Path $Plan.RepoRoot 'local\lib.ps1'

    $lines = @(
        "# Generated by the Tiny11 Local Builder for variant '$($Variant.id)'."
        '# Kept after the run: this is the exact sequence that produced (or failed to'
        '# produce) the ISO, and it can be re-run by hand.'
        ''
        "`$ErrorActionPreference = 'Stop'"
        '# Dot-sourced, not invoked: the helper functions have to stay in scope.'
        ('. {0}' -f (Format-PsLiteral -Value $libPath))
        ''
        '$prepared = $null'
        '$exitCode = 1'
        'try {'
        '    $prepareArgs = @{'
        ('        Source = {0}' -f (Format-PsLiteral -Value $Plan.Source))
        ('        RepoRoot = {0}' -f (Format-PsLiteral -Value $Plan.RepoRoot))
        ('        ScratchRoot = {0}' -f (Format-PsLiteral -Value $Plan.ScratchRoot))
        ('        Language = {0}' -f (Format-PsLiteral -Value $Plan.Language))
        '    }'
    )

    if ($Plan.SourceIsoPath) {
        $lines += ('    $prepareArgs.IsoPath = {0}' -f (Format-PsLiteral -Value $Plan.SourceIsoPath))
    }
    if ($Plan.MountedDrive) {
        $lines += ('    $prepareArgs.MountedDrive = {0}' -f (Format-PsLiteral -Value $Plan.MountedDrive))
    }

    $lines += @(
        '    $prepared = Invoke-IsoPrepare @prepareArgs'
        '    Write-Output "Media ready on drive $($prepared.DriveLetter):"'
        ''
        '    # Hand the drive letter to the builder process through the environment.'
        '    $env:TINY11_ISO_DRIVE = $prepared.DriveLetter'
        ''
        "    `$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }"
        ('    & $shell -NoProfile -ExecutionPolicy Bypass -File {0}' -f (Format-PsLiteral -Value $Plan.LauncherPath))
        '    $exitCode = $LASTEXITCODE'
        '    if ($null -eq $exitCode) { $exitCode = 1 }'
        '} catch {'
        '    Write-Output "BUILD FAILED: $($_.Exception.Message)"'
        '    $exitCode = 1'
        '} finally {'
        '    Remove-Item Env:TINY11_ISO_DRIVE -ErrorAction SilentlyContinue'
        '    Invoke-IsoRelease -Prepared $prepared -RemoveDownloadedIso:$true'
        '}'
        ''
        'if ($exitCode -eq 0) {'
        '    try {'
        '        $metadata = @{'
        ('            Variant = {0}' -f (Format-PsLiteral -Value $Variant.label))
        ('            UpdateMode = {0}' -f (Format-PsLiteral -Value $Plan.UpdateMode))
        '        }'
        ('        $final = Export-BuildIso -IsoPath {0} -OutputDir {1} -Metadata $metadata' -f (Format-PsLiteral -Value $Plan.BuiltIsoPath), (Format-PsLiteral -Value $Plan.OutputDir))
        '        Write-Output "EXPORTED: $final"'
        '    } catch {'
        '        Write-Output "EXPORT FAILED: $($_.Exception.Message)"'
        '        $exitCode = 1'
        '    }'
        '}'
        ''
        'exit $exitCode'
    )

    $directory = Split-Path -Parent $ScriptPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Set-Content -LiteralPath $ScriptPath -Value ($lines -join "`r`n") -Encoding UTF8
    return $ScriptPath
}

function Get-RepoArchiveUrl {
    <#
    .SYNOPSIS
        codeload URL for a repo archive at a ref (branch, tag or SHA).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$Ref = 'main'
    )

    return "https://codeload.github.com/$Owner/$Repo/zip/$Ref"
}

function Get-MountedDriveLetter {
    <#
    .SYNOPSIS
        Waits for a freshly mounted image to expose a drive letter.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [int]$Attempts = 15
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $volume = Get-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
        if ($volume -and $volume.DriveLetter) { return [string]$volume.DriveLetter }
        Start-Sleep -Milliseconds 400
    }

    throw "Mounted $ImagePath but no drive letter appeared after $Attempts attempts."
}

function Invoke-IsoPrepare {
    <#
    .SYNOPSIS
        Produces a drive letter holding the Windows media, downloading or mounting as needed.

    .DESCRIPTION
        Returns an object with DriveLetter and Mounted. Mounted is true only when this
        call attached the image, so the caller knows whether it owns the unmount.

        Downloading mints a fresh link rather than reusing a stored one: Microsoft's
        links carry a token that expires after roughly a day, which is exactly why a
        pasted URL goes stale between runs.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('download', 'file', 'mounted')][string]$Source,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ScratchRoot,
        [string]$IsoPath,
        [string]$MountedDrive,
        [string]$Language = 'English (United States)'
    )

    if ($Source -eq 'mounted') {
        if ([string]::IsNullOrWhiteSpace($MountedDrive)) { throw "No mounted drive was selected." }
        $letter = $MountedDrive.TrimEnd(':')
        if (-not (Test-Path -LiteralPath "${letter}:\sources")) {
            throw "${letter}: does not look like Windows media - no \sources folder."
        }
        return [pscustomobject]@{ DriveLetter = $letter; Mounted = $false; ImagePath = $null }
    }

    if ($Source -eq 'file') {
        if ([string]::IsNullOrWhiteSpace($IsoPath)) { throw "No ISO file was selected." }
        if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found at $IsoPath" }
        $resolved = (Resolve-Path -LiteralPath $IsoPath).Path
        $image = Get-DiskImage -ImagePath $resolved -ErrorAction SilentlyContinue
        if (-not $image -or -not $image.Attached) {
            Mount-DiskImage -ImagePath $resolved -Access ReadOnly | Out-Null
        }
        return [pscustomobject]@{
            DriveLetter = (Get-MountedDriveLetter -ImagePath $resolved)
            Mounted     = $true
            ImagePath   = $resolved
        }
    }

    $resolver = Join-Path $RepoRoot 'scripts\resolve-windows-iso.ps1'
    if (-not (Test-Path -LiteralPath $resolver)) { throw "ISO resolver missing at $resolver" }

    # The resolver emits a PSCustomObject, but anything it happens to write to the
    # pipeline would land in the same array, so pick the object that has a Url.
    $resolvedLink = & $resolver -Language $Language |
        Where-Object { $_ -and $_.PSObject.Properties['Url'] } |
        Select-Object -Last 1

    if (-not $resolvedLink -or [string]::IsNullOrWhiteSpace([string]$resolvedLink.Url)) {
        throw "Could not resolve a Windows ISO link for '$Language'."
    }

    $isoDir = Join-Path $ScratchRoot 'tiny11-iso'
    if (-not (Test-Path -LiteralPath $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }

    $target = Join-Path $isoDir $resolvedLink.FileName
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Output "Downloading $($resolvedLink.FileName) ..."
        $aria = Get-Command aria2c -ErrorAction SilentlyContinue
        if ($aria) {
            & aria2c --console-log-level=warn --summary-interval=30 `
                --max-connection-per-server=8 --split=8 --min-split-size=5M `
                --max-tries=5 --retry-wait=3 --continue=true --allow-overwrite=true `
                --auto-file-renaming=false --file-allocation=none `
                "--dir=$isoDir" "--out=$($resolvedLink.FileName)" $resolvedLink.Url
            if ($LASTEXITCODE -ne 0) { throw "aria2c failed to download the ISO (exit $LASTEXITCODE)." }
        } else {
            $previous = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $resolvedLink.Url -OutFile $target -UseBasicParsing
            } finally {
                $ProgressPreference = $previous
            }
        }
    } else {
        Write-Output "Reusing the ISO already downloaded at $target"
    }

    Mount-DiskImage -ImagePath $target -Access ReadOnly | Out-Null
    return [pscustomobject]@{
        DriveLetter = (Get-MountedDriveLetter -ImagePath $target)
        Mounted     = $true
        ImagePath   = $target
    }
}

function Invoke-IsoRelease {
    <#
    .SYNOPSIS
        Detaches an image this run mounted. Never touches a drive it did not mount.
    #>
    param(
        [Parameter(Mandatory = $false)]$Prepared,
        [switch]$RemoveDownloadedIso
    )

    if (-not $Prepared -or -not $Prepared.Mounted -or -not $Prepared.ImagePath) { return }

    try {
        Dismount-DiskImage -ImagePath $Prepared.ImagePath -ErrorAction Stop | Out-Null
    } catch {
        Write-Output "Could not detach $($Prepared.ImagePath): $($_.Exception.Message)"
        return
    }

    if ($RemoveDownloadedIso -and (Test-Path -LiteralPath $Prepared.ImagePath)) {
        Remove-Item -LiteralPath $Prepared.ImagePath -Force -ErrorAction SilentlyContinue
    }
}

function Export-BuildIso {
    <#
    .SYNOPSIS
        Moves the finished ISO to the chosen folder and writes its checksums.

    .DESCRIPTION
        The builders always write next to themselves, so exporting is a move rather
        than a parameter. Same-volume moves are a rename; cross-volume is a copy and
        delete, which is why the caller should prefer a folder on the scratch drive.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $false)][hashtable]$Metadata = @{}
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "Expected the builder to leave an ISO at $IsoPath, but it is not there."
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $name = Split-Path -Leaf $IsoPath
    $destination = Join-Path $OutputDir $name

    Write-Output "Exporting $name to $OutputDir"
    Move-Item -LiteralPath $IsoPath -Destination $destination -Force

    $sha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $md5 = (Get-FileHash -LiteralPath $destination -Algorithm MD5).Hash

    "$sha *$name" | Set-Content -LiteralPath "$destination.sha256" -Encoding ASCII
    "$md5 *$name"  | Set-Content -LiteralPath "$destination.md5" -Encoding ASCII

    $info = @("File: $name", "SHA256: $sha", "MD5: $md5", "Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    foreach ($key in $Metadata.Keys) { $info += "$key`: $($Metadata[$key])" }
    $info | Set-Content -LiteralPath "$destination.txt" -Encoding UTF8

    return $destination
}

function Test-FileHashMatches {
    <#
    .SYNOPSIS
        True when the file's SHA256 equals $Expected, or when no hash was supplied.

    .DESCRIPTION
        An absent hash is treated as "not pinned" rather than as a failure, so the
        loader still works against a moving branch. When a hash *is* given, a mismatch
        is fatal - that is the only case where this can protect anyone.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Expected
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $wanted = $Expected -replace '[^0-9A-Fa-f]', ''
    return $actual -eq $wanted
}
