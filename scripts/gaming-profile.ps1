<#
.SYNOPSIS
    Tiny11 Core-Gaming profile engine.

.DESCRIPTION
    Dot-sourced by tiny11coremaker-headless.ps1 when -GamingProfile is set.

    Every tweak is data-driven from config/gaming_profile.json so the profile can be
    reviewed, diffed and changed without editing this file. This module only knows how
    to APPLY the data - it never hardcodes a registry path or a service name.

    Application order (driven by the builder):
      1. Invoke-GamingAppxRemoval / SystemPackage / OptionalFeature  (image offline, hives not loaded)
      2. Invoke-GamingRegistryTweaks                                  (hives loaded, after Apply-PerformanceTweaks)
      3. Invoke-GamingServiceTweaks                                   (hives loaded)
      4. New-GamingFirstBootPayload                                   (image offline, before dismount)

    Everything is best-effort: a single missing service or an unavailable DISM feature
    logs a warning and continues, because a half-applied gaming profile is far better
    than a failed 90-minute ISO build.

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

$script:GamingLogFile = $null
$script:GamingProfileDir = $null
$script:GamingStats = @{ registry = 0; services = 0; appx = 0; packages = 0; features = 0; runtimes = 0 }

#---------[ Logging / helpers ]---------#

function Initialize-GamingModule {
    param(
        [string]$LogFile,
        [string]$ProfileDirectory
    )
    if ($LogFile) { $script:GamingLogFile = $LogFile }
    if ($ProfileDirectory) { $script:GamingProfileDir = $ProfileDirectory }
}

function Write-GamingLog {
    # Deliberately uses Write-Host rather than Write-Output: several functions in this
    # module return a value, and emitting log lines on the output stream would corrupt
    # those return values (Import-GamingProfile would hand back an array of log strings
    # plus the profile). Write-Host still reaches the console and the CI log, and the
    # log file is written separately below.
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [GAMING] [$Level] $Message"
    Write-Host $line
    if ($script:GamingLogFile) {
        Add-Content -Path $script:GamingLogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Get-GamingProp {
    # StrictMode-safe property access. Returns $Default when the property is absent,
    # which matters because most JSON entries carry an optional "note" field.
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-GamingConfigPath {
    param([string]$FileName)

    $candidates = @()
    if ($script:GamingProfileDir) {
        $candidates += (Join-Path $script:GamingProfileDir $FileName)
    }
    $candidates += (Join-Path $PSScriptRoot "..\config\$FileName")
    $candidates += (Join-Path $PSScriptRoot "config\$FileName")
    $parent = Split-Path $PSScriptRoot -Parent
    if ($parent) { $candidates += (Join-Path $parent "config\$FileName") }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

#---------[ Profile load / validate ]---------#

function Import-GamingProfile {
    param([string]$Path)

    if (-not $Path) { $Path = Get-GamingConfigPath 'gaming_profile.json' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        throw "Gaming profile not found. Expected config/gaming_profile.json (or pass -GamingProfileFile)."
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $profile = $null
    try {
        $profile = $raw | ConvertFrom-Json
    } catch {
        throw "Gaming profile JSON at $Path is invalid: $_"
    }

    Test-GamingProfile -Profile $profile -SourcePath $Path | Out-Null
    Write-GamingLog "Loaded gaming profile '$($profile.profile)' from $Path"
    return $profile
}

function Test-GamingProfile {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [string]$SourcePath
    )

    $where = ''
    if ($SourcePath) { $where = " in $SourcePath" }

    $requiredKeys = @(
        'schemaVersion', 'profile', 'hivePrefixes', 'defaultGroups',
        'registry', 'services', 'appxPrefixes', 'systemPackages',
        'optionalFeatures', 'runtimeDownloads', 'revert'
    )
    $present = @($Profile.PSObject.Properties.Name)
    foreach ($key in $requiredKeys) {
        if ($present -notcontains $key) {
            throw "Gaming profile$where is missing required key '$key'"
        }
    }

    $validHives = @('SYSTEM', 'SOFTWARE', 'DEFAULT', 'NTUSER')
    $knownGroups = @($Profile.defaultGroups.PSObject.Properties.Name)

    $index = 0
    foreach ($entry in $Profile.registry) {
        $index++
        foreach ($field in @('group', 'hive', 'path', 'type')) {
            if (-not (Get-GamingProp $entry $field)) {
                throw "registry[$index]$where is missing '$field'"
            }
        }
        $hive = Get-GamingProp $entry 'hive'
        if ($validHives -notcontains $hive) {
            throw "registry[$index]$where uses unknown hive '$hive'. Expected one of: $($validHives -join ', ')"
        }
        if (-not (Get-GamingProp $Profile.hivePrefixes $hive)) {
            throw "registry[$index]$where uses hive '$hive' which has no entry in hivePrefixes"
        }
        $group = Get-GamingProp $entry 'group'
        if ($knownGroups -notcontains $group) {
            throw "registry[$index]$where references unknown group '$group'"
        }
    }

    foreach ($section in @('services', 'appxPrefixes', 'systemPackages', 'optionalFeatures', 'runtimeDownloads')) {
        $i = 0
        foreach ($entry in $Profile.$section) {
            $i++
            $group = Get-GamingProp $entry 'group'
            if ($group -and ($knownGroups -notcontains $group)) {
                throw "$section[$i]$where references unknown group '$group'"
            }
        }
    }

    foreach ($entry in $Profile.services) {
        if (-not (Get-GamingProp $entry 'name')) {
            throw "services$where has an entry with no 'name'"
        }
        if ($null -eq (Get-GamingProp $entry 'start')) {
            throw "services$where entry '$($entry.name)' has no 'start' value"
        }
    }

    return $true
}

function Resolve-GamingGroups {
    # Merges workflow-supplied overrides on top of the profile defaults.
    param(
        $Profile,
        [hashtable]$Overrides
    )

    $groups = @{}
    foreach ($prop in $Profile.defaultGroups.PSObject.Properties) {
        $groups[$prop.Name] = [bool]$prop.Value
    }

    if ($Overrides) {
        foreach ($key in $Overrides.Keys) {
            if ($groups.ContainsKey($key)) {
                $groups[$key] = [bool]$Overrides[$key]
            } else {
                Write-GamingLog "Ignoring unknown gaming group override '$key'" 'WARN'
            }
        }
    }
    return $groups
}

function Test-GamingGroupEnabled {
    param(
        [hashtable]$Groups,
        [string]$Name
    )
    if (-not $Name) { return $true }
    if ($null -eq $Groups) { return $true }
    if (-not $Groups.ContainsKey($Name)) { return $true }
    return [bool]$Groups[$Name]
}

function Get-GamingHivePrefixMap {
    param($Profile)
    $map = @{}
    foreach ($prop in $Profile.hivePrefixes.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
    }
    return $map
}

#---------[ Registry ]---------#

function Test-GamingRegistryKeyExists {
    param([string]$KeyPath)
    & reg query $KeyPath 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-GamingRegistryValue {
    param(
        [string]$KeyPath,
        [string]$Name,
        [string]$Type,
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Name)) {
        & reg add $KeyPath /ve /t $Type /d $Value /f | Out-Null
    } else {
        & reg add $KeyPath /v $Name /t $Type /d $Value /f | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "reg add failed for $KeyPath\$Name (exit $LASTEXITCODE)"
    }
}

function Invoke-GamingRegistryTweaks {
    param(
        $Profile,
        [hashtable]$Groups
    )

    $prefixMap = Get-GamingHivePrefixMap -Profile $Profile
    $applied = 0
    $skipped = 0
    $failed = 0

    Write-GamingLog "Applying gaming registry tweaks..."

    foreach ($entry in $Profile.registry) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) {
            $skipped++
            continue
        }

        $hive = Get-GamingProp $entry 'hive'
        $path = Get-GamingProp $entry 'path'
        $name = Get-GamingProp $entry 'name' ''
        $type = Get-GamingProp $entry 'type'
        $value = Get-GamingProp $entry 'value' ''
        $note = Get-GamingProp $entry 'note'

        $keyPath = "$($prefixMap[$hive])\$path"
        $label = "$hive\$path\$name"

        try {
            Set-GamingRegistryValue -KeyPath $keyPath -Name $name -Type $type -Value $value
            $applied++
            $suffix = ''
            if ($note) { $suffix = "  ($note)" }
            Write-GamingLog "  set $label = $value$suffix"
        } catch {
            $failed++
            Write-GamingLog "  FAILED $label : $_" 'WARN'
        }
    }

    $script:GamingStats.registry = $applied
    Write-GamingLog "Registry tweaks: $applied applied, $skipped skipped (group disabled), $failed failed"
}

#---------[ Services ]---------#

function Invoke-GamingServiceTweaks {
    param(
        $Profile,
        [hashtable]$Groups
    )

    $prefixMap = Get-GamingHivePrefixMap -Profile $Profile
    $systemRoot = "$($prefixMap['SYSTEM'])\ControlSet001\Services"
    $applied = 0
    $missing = 0

    Write-GamingLog "Applying gaming service tweaks..."

    foreach ($svc in $Profile.services) {
        $group = Get-GamingProp $svc 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }

        $name = Get-GamingProp $svc 'name'
        $start = Get-GamingProp $svc 'start' 4
        $note = Get-GamingProp $svc 'note'

        $keyPath = "$systemRoot\$name"

        # Never create a service key that does not exist - that would leave a bogus
        # entry in the registry of the finished image.
        if (-not (Test-GamingRegistryKeyExists -KeyPath $keyPath)) {
            $missing++
            Write-GamingLog "  skip $name (not present in this image)" 'WARN'
            continue
        }

        try {
            Set-GamingRegistryValue -KeyPath $keyPath -Name 'Start' -Type 'REG_DWORD' -Value "$start"
            $applied++
            $suffix = ''
            if ($note) { $suffix = "  ($note)" }
            Write-GamingLog "  disable $name (Start=$start)$suffix"
        } catch {
            Write-GamingLog "  FAILED to disable $name : $_" 'WARN'
        }
    }

    $script:GamingStats.services = $applied
    Write-GamingLog "Service tweaks: $applied disabled, $missing not present"
}

#---------[ HAGS ]---------#

function Set-GamingHagsMode {
    # AtlasOS treats HAGS as system-dependent rather than a universal win, so it is a
    # workflow toggle here instead of being forced on like the Core default.
    param(
        $Profile,
        [ValidateSet('on', 'off', 'leave')]
        [string]$HagsMode = 'on'
    )

    if ($HagsMode -eq 'leave') {
        Write-GamingLog "HAGS left at the Core default (on)"
        return
    }

    $prefixMap = Get-GamingHivePrefixMap -Profile $Profile
    $keyPath = "$($prefixMap['SYSTEM'])\ControlSet001\Control\GraphicsDrivers"

    # 2 = enabled, 1 = disabled.
    $value = '2'
    if ($HagsMode -eq 'off') { $value = '1' }

    try {
        Set-GamingRegistryValue -KeyPath $keyPath -Name 'HwSchMode' -Type 'REG_DWORD' -Value $value
        Write-GamingLog "HAGS forced $HagsMode (HwSchMode=$value)"
    } catch {
        Write-GamingLog "Failed to set HAGS mode: $_" 'WARN'
    }
}

#---------[ AppX / packages / features ]---------#

function Get-GamingEnabledPrefixes {
    param($Profile, [hashtable]$Groups, [string]$Section, [string]$Field)
    $result = @()
    foreach ($entry in $Profile.$Section) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $value = Get-GamingProp $entry $Field
        if ($value) { $result += $value }
    }
    return $result
}

function Invoke-GamingAppxRemoval {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$ScratchDir
    )

    $prefixes = Get-GamingEnabledPrefixes -Profile $Profile -Groups $Groups -Section 'appxPrefixes' -Field 'prefix'
    if ($prefixes.Count -eq 0) {
        Write-GamingLog "AppX removal: no groups enabled, skipping"
        return
    }

    Write-GamingLog "Removing gaming-related provisioned AppX packages..."

    $packages = & dism /English "/image:$ScratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') { $matches[1] }
        }

    $removed = 0
    foreach ($package in $packages) {
        foreach ($prefix in $prefixes) {
            if ($package -like "$prefix*") {
                Write-GamingLog "  removing $package"
                & dism /English "/image:$ScratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$package" | Out-Null
                if ($LASTEXITCODE -eq 0) { $removed++ }
                break
            }
        }
    }

    $script:GamingStats.appx = $removed
    Write-GamingLog "AppX removal: $removed package(s) removed"
}

function Invoke-GamingSystemPackageRemoval {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$ScratchDir
    )

    $patterns = Get-GamingEnabledPrefixes -Profile $Profile -Groups $Groups -Section 'systemPackages' -Field 'pattern'
    if ($patterns.Count -eq 0) {
        Write-GamingLog "System package removal: no groups enabled, skipping"
        return
    }

    Write-GamingLog "Removing gaming-related system packages..."

    $allPackages = & dism /image:$ScratchDir /Get-Packages /Format:Table
    $allPackages = $allPackages -split "`n" | Select-Object -Skip 1

    $removed = 0
    foreach ($pattern in $patterns) {
        $targets = $allPackages | Where-Object { $_ -like "$pattern*" }
        foreach ($target in $targets) {
            $identity = ($target -split "\s+")[0]
            if (-not $identity) { continue }
            Write-GamingLog "  removing $identity"
            try {
                & dism /image:$ScratchDir /Remove-Package /PackageName:$identity /Quiet /NoRestart | Out-Null
                if ($LASTEXITCODE -eq 0) { $removed++ }
            } catch {
                Write-GamingLog "  FAILED to remove $identity : $_" 'WARN'
            }
        }
    }

    $script:GamingStats.packages = $removed
    Write-GamingLog "System package removal: $removed package(s) removed"
}

function Invoke-GamingOptionalFeatureRemoval {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$ScratchDir
    )

    $features = Get-GamingEnabledPrefixes -Profile $Profile -Groups $Groups -Section 'optionalFeatures' -Field 'name'
    if ($features.Count -eq 0) {
        Write-GamingLog "Optional feature removal: no groups enabled, skipping"
        return
    }

    Write-GamingLog "Removing gaming-related optional features..."

    $removed = 0
    foreach ($feature in $features) {
        try {
            & dism /image:$ScratchDir /Disable-Feature "/FeatureName:$feature" /Remove /Quiet /NoRestart | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $removed++
                Write-GamingLog "  removed $feature"
            } else {
                Write-GamingLog "  skip $feature (not present or has dependents)" 'WARN'
            }
        } catch {
            Write-GamingLog "  FAILED $feature : $_" 'WARN'
        }
    }

    $script:GamingStats.features = $removed
    Write-GamingLog "Optional feature removal: $removed feature(s) removed"
}

#---------[ Runtime payload ]---------#

function Get-GamingRuntimePayload {
    # Downloads the runtime installers that ship inside the image.
    #
    # This is deliberately fatal by default. A silent failure here produces an ISO that
    # looks fine but is missing the runtimes, which the user only discovers after
    # installing. The builder calls this EARLY (before the Windows ISO is downloaded)
    # so a network problem costs seconds, not the whole build.
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$Destination,
        [bool]$FailOnError = $true,
        [int]$MinimumBytes = 102400
    )

    if (-not (Test-GamingGroupEnabled -Groups $Groups -Name 'install_game_runtimes')) {
        Write-GamingLog "Game runtime download skipped (group disabled)"
        return
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    # Older PowerShell defaults to TLS 1.0, which aka.ms and download.microsoft.com reject.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-GamingLog "Could not force TLS 1.2: $_" 'WARN'
    }

    $downloaded = 0
    $failures = @()

    foreach ($runtime in $Profile.runtimeDownloads) {
        $group = Get-GamingProp $runtime 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }

        $url = Get-GamingProp $runtime 'url'
        $file = Get-GamingProp $runtime 'file'
        $note = Get-GamingProp $runtime 'note'
        $outFile = Join-Path $Destination $file

        try {
            Write-GamingLog "  downloading $file ($note)"
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec 300

            $bytes = (Get-Item -LiteralPath $outFile).Length
            if ($bytes -lt $MinimumBytes) {
                # A 404 or an error page saved under an .exe name is the classic silent
                # failure here, so reject anything implausibly small.
                throw "downloaded file is only $bytes bytes - expected at least $MinimumBytes"
            }

            $sizeMB = [math]::Round($bytes / 1MB, 1)
            Write-GamingLog "  got $file (${sizeMB} MB)"
            $downloaded++
        } catch {
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            $failures += "$file : $($_.Exception.Message)"
            Write-GamingLog "  FAILED $file : $($_.Exception.Message)" 'ERROR'
        }
    }

    $script:GamingStats.runtimes = $downloaded

    if ($failures.Count -gt 0) {
        $message = "Could not bundle $($failures.Count) game runtime(s): " + ($failures -join ' | ')
        if ($FailOnError) {
            throw $message
        }
        Write-GamingLog $message 'WARN'
    }

    Write-GamingLog "Game runtimes bundled: $downloaded"
}

#---------[ Manifest ]---------#

function New-GamingManifest {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$Destination,
        [string]$HagsMode = 'on'
    )

    $lines = @()
    $lines += "# $($Profile.title) - applied tweak manifest"
    $lines += ""
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ""
    $lines += $Profile.description
    $lines += ""
    $lines += "## Groups"
    $lines += ""
    $lines += "| Group | State | What it does |"
    $lines += "|-------|-------|--------------|"
    foreach ($prop in $Profile.defaultGroups.PSObject.Properties) {
        $name = $prop.Name
        $enabled = Test-GamingGroupEnabled -Groups $Groups -Name $name
        $state = 'off'
        if ($enabled) { $state = 'ON' }
        $desc = Get-GamingProp $Profile.groupDescriptions $name ''
        $lines += "| ``$name`` | $state | $desc |"
    }
    $lines += ""
    $lines += "HAGS (Hardware Accelerated GPU Scheduling): **$HagsMode**"
    $lines += ""

    $lines += "## Registry values written"
    $lines += ""
    $lines += "| Group | Key | Value |"
    $lines += "|-------|-----|-------|"
    foreach ($entry in $Profile.registry) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $hive = Get-GamingProp $entry 'hive'
        $path = Get-GamingProp $entry 'path'
        $name = Get-GamingProp $entry 'name'
        $value = Get-GamingProp $entry 'value'
        $lines += "| $group | ``$hive\$path\$name`` | ``$value`` |"
    }
    $lines += ""

    $lines += "## Services disabled"
    $lines += ""
    $lines += "| Service | Start |"
    $lines += "|---------|-------|"
    foreach ($svc in $Profile.services) {
        $group = Get-GamingProp $svc 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $lines += "| ``$(Get-GamingProp $svc 'name')`` | $(Get-GamingProp $svc 'start') |"
    }
    $lines += ""

    $lines += "## Removed packages / features"
    $lines += ""
    foreach ($entry in $Profile.appxPrefixes) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $lines += "- AppX: ``$(Get-GamingProp $entry 'prefix')``"
    }
    foreach ($entry in $Profile.systemPackages) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $lines += "- Package: ``$(Get-GamingProp $entry 'pattern')``"
    }
    foreach ($entry in $Profile.optionalFeatures) {
        $group = Get-GamingProp $entry 'group'
        if (-not (Test-GamingGroupEnabled -Groups $Groups -Name $group)) { continue }
        $lines += "- Feature: ``$(Get-GamingProp $entry 'name')``"
    }
    $lines += ""

    $lines += "## Not reversible without reinstalling Windows"
    $lines += ""
    foreach ($item in $Profile.revert.irreversible) {
        $lines += "- $item"
    }
    $lines += ""
    $lines += "Run ``C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1`` (as Administrator) to"
    $lines += "restore the reversible settings listed in the profile's ``revert`` block."
    $lines += ""

    $lines -join "`r`n" | Out-File -FilePath $Destination -Encoding UTF8 -Force
    Write-GamingLog "Manifest written to $Destination"
}

#---------[ First-boot payload injection ]---------#

function New-GamingFirstBootPayload {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$ScratchDir,
        [string]$ScriptRoot,
        [string]$HagsMode = 'on',
        [string]$RuntimeSource
    )

    $gamingDir = Join-Path $ScratchDir 'Windows\Tiny11Gaming'
    $runtimeDir = Join-Path $gamingDir 'runtimes'
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

    Write-GamingLog "Injecting first-boot payload into $gamingDir"

    # The scripts that run on the target machine.
    $payloadScripts = @('gaming-firstboot.ps1', 'Undo-GamingTweaks.ps1')
    foreach ($name in $payloadScripts) {
        $source = Join-Path $ScriptRoot $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $gamingDir $name) -Force
            Write-GamingLog "  staged $name"
        } else {
            Write-GamingLog "  MISSING payload script: $source" 'WARN'
        }
    }

    # Power scheme definition consumed by gaming-firstboot.ps1.
    $powerConfig = Get-GamingConfigPath 'gaming_power_settings.json'
    if ($powerConfig) {
        Copy-Item -LiteralPath $powerConfig -Destination (Join-Path $gamingDir 'gaming_power_settings.json') -Force
        Write-GamingLog "  staged gaming_power_settings.json"
    } else {
        Write-GamingLog "  MISSING gaming_power_settings.json - power scheme will be skipped" 'WARN'
    }

    # The full profile travels with the image so Undo-GamingTweaks.ps1 can read its
    # revert block from the same source of truth the builder used.
    $profileConfig = Get-GamingConfigPath 'gaming_profile.json'
    if ($profileConfig) {
        Copy-Item -LiteralPath $profileConfig -Destination (Join-Path $gamingDir 'gaming_profile.json') -Force
        Write-GamingLog "  staged gaming_profile.json"
    } else {
        Write-GamingLog "  MISSING gaming_profile.json - revert will be unavailable" 'WARN'
    }

    # Group flags consumed by gaming-firstboot.ps1 on the target machine.
    $groupsFile = [ordered]@{
        profile     = $Profile.profile
        hagsMode    = $HagsMode
        generatedAt = (Get-Date -Format 'o')
        groups      = $Groups
    }
    $groupsFile | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $gamingDir 'gaming_groups.json') -Encoding UTF8 -Force
    Write-GamingLog "  staged gaming_groups.json"

    # Audit manifest.
    New-GamingManifest -Profile $Profile -Groups $Groups `
        -Destination (Join-Path $gamingDir 'GAMING_PROFILE.md') -HagsMode $HagsMode

    # Runtime installers. The builder normally downloads these up front and hands over a
    # staging directory; the fallback download keeps this module usable standalone.
    if (Test-GamingGroupEnabled -Groups $Groups -Name 'install_game_runtimes') {
        if ($RuntimeSource -and (Test-Path -LiteralPath $RuntimeSource)) {
            # Copy-Item with a wildcard errors on an empty directory, so count first and
            # let the verification below produce the clear message instead.
            $sourceItems = @(Get-ChildItem -Path $RuntimeSource -File -ErrorAction SilentlyContinue)
            if ($sourceItems.Count -gt 0) {
                Copy-Item -Path (Join-Path $RuntimeSource '*') -Destination $runtimeDir -Force -Recurse
                Write-GamingLog "  copied $($sourceItems.Count) runtime file(s) from $RuntimeSource"
            } else {
                Write-GamingLog "  runtime staging directory is empty: $RuntimeSource" 'WARN'
            }
        } else {
            Get-GamingRuntimePayload -Profile $Profile -Groups $Groups -Destination $runtimeDir
        }

        # Never emit an ISO whose runtime folder is empty - that is precisely the
        # "not out of the box" failure this step exists to prevent.
        $staged = @(Get-ChildItem -Path $runtimeDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        if ($staged.Count -eq 0) {
            throw "install_game_runtimes is enabled but no runtime installers were staged into the image"
        }
        Write-GamingLog "  runtime payload verified: $($staged.Count) installer(s)"
    }

    # SetupComplete.cmd runs once as SYSTEM after setup finishes and before the first
    # logon. It is the only offline-injectable hook that is guaranteed to be elevated,
    # which is what powercfg / bcdedit / runtime installers need. Windows deletes it
    # after it runs, so it is naturally one-shot.
    $setupScriptsDir = Join-Path $ScratchDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $setupScriptsDir | Out-Null
    $setupComplete = Join-Path $setupScriptsDir 'SetupComplete.cmd'

    $cmdLines = @(
        '@echo off',
        'rem Tiny11 Core-Gaming first-boot payload (generated by the builder - do not edit in place)',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "C:\Windows\Tiny11Gaming\gaming-firstboot.ps1"',
        'exit /b 0'
    )

    $existing = ''
    if (Test-Path -LiteralPath $setupComplete) {
        $existing = Get-Content -LiteralPath $setupComplete -Raw
    }
    $payload = ($cmdLines -join "`r`n") + "`r`n"
    ($existing + $payload) | Out-File -FilePath $setupComplete -Encoding ASCII -Force
    Write-GamingLog "  staged Windows\Setup\Scripts\SetupComplete.cmd"
}

#---------[ Build info ]---------#

function Write-GamingBuildInfo {
    param(
        $Profile,
        [hashtable]$Groups,
        [string]$OutputPath,
        [string]$HagsMode = 'on',
        [string]$WindowsBuild
    )

    try {
        $info = [ordered]@{
            gaming_profile    = $Profile.profile
            profile_title     = $Profile.title
            schema_version    = $Profile.schemaVersion
            hags_mode         = $HagsMode
            windows_build     = $WindowsBuild
            generated_at      = (Get-Date -Format 'o')
            groups            = $Groups
            counts            = $script:GamingStats
        }
        $info | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-GamingLog "Gaming build info written to $OutputPath"
    } catch {
        Write-GamingLog "Failed to write gaming build info: $_" 'WARN'
    }
}
