<#
.SYNOPSIS
    Pester tests for the Tiny11 Core-Gaming profile.

.DESCRIPTION
    Validates the data-driven gaming profile: the JSON schema, group references,
    registry hive names, and the wiring between the profile, the engine module, the
    Core builder and the GitHub Actions workflow.

    These tests do NOT build an ISO - they are pure static validation, so they run
    anywhere Pester is available (including ubuntu-latest via pwsh).

.EXAMPLE
    Invoke-Pester -Path tests/Test-GamingProfile.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $configDir = Join-Path $repoRoot 'config'
    $scriptsDir = Join-Path $repoRoot 'scripts'

    $profilePath = Join-Path $configDir 'gaming_profile.json'
    $powerPath = Join-Path $configDir 'gaming_power_settings.json'
    $modulePath = Join-Path $scriptsDir 'gaming-profile.ps1'
    $builderPath = Join-Path $scriptsDir 'tiny11coremaker-headless.ps1'
    $firstBootPath = Join-Path $scriptsDir 'gaming-firstboot.ps1'
    $undoPath = Join-Path $scriptsDir 'Undo-GamingTweaks.ps1'
    $workflowPath = Join-Path $repoRoot '.github/workflows/build-tiny11-core-gaming.yml'

    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $power = Get-Content -LiteralPath $powerPath -Raw | ConvertFrom-Json
    $workflowRaw = Get-Content -LiteralPath $workflowPath -Raw

    # Returns the character offset of a CALL statement inside the builder's Main
    # Execution block, or -1. Matching on "line starts with whitespace then the name"
    # avoids false hits on function definitions and on comments that merely mention
    # the function (several gaming comments do).
    function Get-MainCallIndex {
        param([string]$Content, [string]$Name)
        $mainIndex = $Content.IndexOf('#---------[ Main Execution ]')
        if ($mainIndex -lt 0) { return -1 }
        $pattern = "(?m)^[ \t]+$([regex]::Escape($Name))\b"
        $match = [regex]::Match($Content.Substring($mainIndex), $pattern)
        if (-not $match.Success) { return -1 }
        return $mainIndex + $match.Index
    }
}

Describe 'Gaming profile JSON' {

    It 'exists' {
        Test-Path -LiteralPath $profilePath | Should -BeTrue
    }

    It 'declares a schema version and profile name' {
        $profile.schemaVersion | Should -Not -BeNullOrEmpty
        $profile.profile | Should -Be 'core-gaming'
    }

    It 'has every required top-level key' {
        $required = @(
            'schemaVersion', 'profile', 'hivePrefixes', 'defaultGroups',
            'registry', 'services', 'appxPrefixes', 'systemPackages',
            'optionalFeatures', 'runtimeDownloads', 'revert'
        )
        $present = @($profile.PSObject.Properties.Name)
        foreach ($key in $required) {
            $present | Should -Contain $key
        }
    }

    It 'has a hive prefix for every valid hive' {
        foreach ($hive in @('SYSTEM', 'SOFTWARE', 'DEFAULT', 'NTUSER')) {
            $profile.hivePrefixes.PSObject.Properties.Name | Should -Contain $hive
        }
    }

    It 'uses only valid hives in registry entries' {
        $valid = @('SYSTEM', 'SOFTWARE', 'DEFAULT', 'NTUSER')
        foreach ($entry in $profile.registry) {
            $valid | Should -Contain $entry.hive
        }
    }

    It 'references only groups that exist in defaultGroups' {
        $known = @($profile.defaultGroups.PSObject.Properties.Name)

        foreach ($entry in $profile.registry)          { $known | Should -Contain $entry.group }
        foreach ($entry in $profile.services)          { $known | Should -Contain $entry.group }
        foreach ($entry in $profile.appxPrefixes)      { $known | Should -Contain $entry.group }
        foreach ($entry in $profile.systemPackages)    { $known | Should -Contain $entry.group }
        foreach ($entry in $profile.optionalFeatures)  { $known | Should -Contain $entry.group }
        foreach ($entry in $profile.runtimeDownloads)  { $known | Should -Contain $entry.group }
    }

    It 'gives every registry entry a path and a type' {
        foreach ($entry in $profile.registry) {
            $entry.path | Should -Not -BeNullOrEmpty
            $entry.type | Should -Match '^REG_(DWORD|SZ|EXPAND_SZ|MULTI_SZ|QWORD|BINARY)$'
        }
    }

    It 'gives every service entry a name and a start value' {
        foreach ($entry in $profile.services) {
            $entry.name | Should -Not -BeNullOrEmpty
            $entry.start | Should -BeIn @(0, 1, 2, 3, 4)
        }
    }

    It 'gives every runtime download a url and a file name' {
        foreach ($entry in $profile.runtimeDownloads) {
            $entry.url  | Should -Match '^https://'
            $entry.file | Should -Match '\.exe$'
        }
    }

    It 'has a revert block covering reversible, serviceRestore and irreversible' {
        $profile.revert.PSObject.Properties.Name | Should -Contain 'reversible'
        $profile.revert.PSObject.Properties.Name | Should -Contain 'serviceRestore'
        $profile.revert.PSObject.Properties.Name | Should -Contain 'irreversible'
        @($profile.revert.irreversible).Count | Should -BeGreaterThan 0
    }

    It 'documents every group in groupDescriptions' {
        $documented = @($profile.groupDescriptions.PSObject.Properties.Name)
        foreach ($group in $profile.defaultGroups.PSObject.Properties.Name) {
            $documented | Should -Contain $group
        }
    }

    It 'disables Game Mode and enables the AtlasOS power scheme by default' {
        $profile.defaultGroups.disable_game_mode           | Should -BeTrue
        $profile.defaultGroups.atlas_power_scheme          | Should -BeTrue
        $profile.defaultGroups.disable_security_mitigations | Should -BeTrue
        $profile.defaultGroups.disable_fso                 | Should -BeTrue
    }

    It 'sets SystemResponsiveness to the AtlasOS value of 10' {
        $entry = $profile.registry |
            Where-Object { $_.name -eq 'SystemResponsiveness' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.value | Should -Be '10'
    }

    It 'disables VBS, HVCI, Credential Guard and Spectre/Meltdown mitigations' {
        $names = @($profile.registry | Where-Object { $_.group -eq 'disable_security_mitigations' })
        ($names | Where-Object { $_.name -eq 'EnableVirtualizationBasedSecurity' }) | Should -Not -BeNullOrEmpty
        ($names | Where-Object { $_.name -eq 'Enabled' })                            | Should -Not -BeNullOrEmpty
        ($names | Where-Object { $_.name -eq 'FeatureSettingsOverride' -and $_.value -eq '3' }) | Should -Not -BeNullOrEmpty
    }

    It 'removes shell delays and shortens the close timeouts for instant window response' {
        $byName = @{}
        foreach ($entry in $profile.registry) { $byName["$($entry.group)/$($entry.name)"] = $entry.value }

        # Animations and delays
        $byName['instant_windows/MinAnimate']         | Should -Be '0'
        $byName['instant_windows/MenuShowDelay']      | Should -Be '0'
        $byName['instant_windows/MouseHoverTime']     | Should -Be '0'
        $byName['instant_windows/TaskbarAnimations']  | Should -Be '0'
        $byName['instant_windows/EnableTransparency'] | Should -Be '0'

        # Close-path timeouts - these are the ones that make closing feel instant.
        # Windows defaults are 5000 / 20000 / 5000 ms respectively.
        $byName['instant_windows/HungAppTimeout']           | Should -Be '1000'
        $byName['instant_windows/WaitToKillAppTimeout']     | Should -Be '2000'
        $byName['instant_windows/WaitToKillServiceTimeout'] | Should -Be '2000'
        $byName['instant_windows/AutoEndTasks']             | Should -Be '1'
    }

    It 'reverts every instant_windows value it changes' {
        $revertNames = @($profile.revert.reversible | Where-Object {
            $_.path -like 'Control Panel\Desktop*' -or
            $_.name -in @('TaskbarAnimations', 'EnableTransparency', 'MinAnimate',
                          'MenuShowDelay', 'MouseHoverTime', 'EnableAeroPeek',
                          'ListviewAlphaSelect', 'ListviewShadow', 'DisallowShaking',
                          'Start_TrackProgs', 'Start_TrackDocs',
                          'ExtendedUIHoverTime', 'WaitToKillServiceTimeout',
                          'HungAppTimeout', 'WaitToKillAppTimeout', 'AutoEndTasks')
        } | ForEach-Object { $_.name })

        foreach ($name in @('MinAnimate', 'MenuShowDelay', 'MouseHoverTime', 'AutoEndTasks',
                            'HungAppTimeout', 'WaitToKillAppTimeout', 'WaitToKillServiceTimeout',
                            'EnableTransparency', 'TaskbarAnimations', 'DisallowShaking')) {
            $revertNames | Should -Contain $name
        }
    }
}

Describe 'Gaming power settings JSON' {

    It 'exists and parses' {
        Test-Path -LiteralPath $powerPath | Should -BeTrue
        $power | Should -Not -BeNullOrEmpty
    }

    It 'names a scheme that is not the built-in Ultimate Performance' {
        $power.schemeName | Should -Be 'Tiny11 Core-Gaming'
        $power.schemeName | Should -Not -Match 'Ultimate'
    }

    It 'uses the High performance template first' {
        $power.baseTemplate.guid | Should -Be '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    }

    It 'provides fallback templates' {
        @($power.baseTemplate.fallbacks).Count | Should -BeGreaterThan 0
    }

    It 'gives every power setting a subgroup, GUID, and AC/DC value' {
        foreach ($setting in $power.settings) {
            $setting.subgroup | Should -Not -BeNullOrEmpty
            $setting.setting  | Should -Match '^[0-9a-fA-F-]{36}$'
            $setting.name     | Should -Not -BeNullOrEmpty
            $setting.PSObject.Properties.Name | Should -Contain 'ac'
            $setting.PSObject.Properties.Name | Should -Contain 'dc'
        }
    }

    It 'disables processor idle under the disable_cpu_idle group' {
        $entry = $power.settings |
            Where-Object { $_.setting -eq '5d76a2ca-e8c0-402f-a133-2158492d58ad' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.ac | Should -Be 1
        $entry.group | Should -Be 'disable_cpu_idle'
    }

    It 'defines bcdedit entries including hypervisorlaunchtype off' {
        @($power.bcd).Count | Should -BeGreaterThan 0
        ($power.bcd | Where-Object { $_.args -match 'hypervisorlaunchtype off' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Gaming profile engine' {

    It 'exists' {
        Test-Path -LiteralPath $modulePath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $modulePath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'defines the functions the builder calls' {
        $content = Get-Content -LiteralPath $modulePath -Raw
        foreach ($fn in @(
            'Initialize-GamingModule', 'Import-GamingProfile', 'Test-GamingProfile',
            'Resolve-GamingGroups', 'Invoke-GamingRegistryTweaks',
            'Invoke-GamingServiceTweaks', 'Set-GamingHagsMode',
            'Invoke-GamingAppxRemoval', 'Invoke-GamingSystemPackageRemoval',
            'Invoke-GamingOptionalFeatureRemoval', 'Get-GamingRuntimePayload',
            'New-GamingFirstBootPayload', 'New-GamingManifest', 'Write-GamingBuildInfo'
        )) {
            $content | Should -Match ("function\s+$([regex]::Escape($fn))\b")
        }
    }

    It 'does not hardcode registry hive paths' {
        # Everything must come from the profile's hivePrefixes map.
        $content = Get-Content -LiteralPath $modulePath -Raw
        $content | Should -Not -Match 'HKLM\\zSYSTEM'
        $content | Should -Not -Match 'HKLM\\zSOFTWARE'
    }
}

Describe 'Core builder wiring' {

    It 'exposes the gaming parameters' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        foreach ($param in @('$GamingProfile', '$GamingProfileFile', '$GamingGroups', '$HagsMode')) {
            $content | Should -Match ([regex]::Escape($param))
        }
    }

    It 'dot-sources the engine only when -GamingProfile is set' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $content | Should -Match 'if\s*\(\$GamingProfile\)\s*\{[\s\S]{0,400}gaming-profile\.ps1'
    }

    It 'applies gaming registry tweaks after Apply-PerformanceTweaks' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $perfIndex   = Get-MainCallIndex -Content $content -Name 'Apply-PerformanceTweaks'
        $gamingIndex = Get-MainCallIndex -Content $content -Name 'Invoke-GamingRegistryTweaks'
        $perfIndex   | Should -BeGreaterThan 0
        $gamingIndex | Should -BeGreaterThan $perfIndex
    }

    It 'disables gaming services after Remove-NonEssentialServices' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $svcIndex    = Get-MainCallIndex -Content $content -Name 'Remove-NonEssentialServices'
        $gamingIndex = Get-MainCallIndex -Content $content -Name 'Invoke-GamingServiceTweaks'
        $svcIndex    | Should -BeGreaterThan 0
        $gamingIndex | Should -BeGreaterThan $svcIndex
    }

    It 'stages the first-boot payload before the image is dismounted' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $payloadIndex  = Get-MainCallIndex -Content $content -Name 'New-GamingFirstBootPayload'
        $dismountIndex = Get-MainCallIndex -Content $content -Name 'Dismount-AndExport'
        $payloadIndex  | Should -BeGreaterThan 0
        $dismountIndex | Should -BeGreaterThan 0
        $payloadIndex  | Should -BeLessThan $dismountIndex
    }

    It 'removes gaming packages while the registry hives are still unloaded' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $appxIndex     = Get-MainCallIndex -Content $content -Name 'Invoke-GamingAppxRemoval'
        $loadHiveIndex = Get-MainCallIndex -Content $content -Name 'Load-RegistryHives'
        $appxIndex     | Should -BeGreaterThan 0
        $loadHiveIndex | Should -BeGreaterThan 0
        $appxIndex     | Should -BeLessThan $loadHiveIndex
    }
}

Describe 'First-boot and undo scripts' {

    It 'first-boot script exists and parses' {
        Test-Path -LiteralPath $firstBootPath | Should -BeTrue
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $firstBootPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'undo script exists and parses' {
        Test-Path -LiteralPath $undoPath | Should -BeTrue
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $undoPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'first-boot script creates and activates the power scheme' {
        $content = Get-Content -LiteralPath $firstBootPath -Raw
        $content | Should -Match 'powercfg -duplicatescheme'
        $content | Should -Match 'powercfg -changename'
        $content | Should -Match 'powercfg -setactive'
    }

    It 'undo script reads its instructions from the bundled profile' {
        $content = Get-Content -LiteralPath $undoPath -Raw
        $content | Should -Match 'gaming_profile\.json'
        $content | Should -Match 'revert'
    }

    It 'undo script is honest about what it cannot restore' {
        $content = Get-Content -LiteralPath $undoPath -Raw
        $content | Should -Match 'irreversible'
    }
}

Describe 'Core-Gaming workflow' {

    It 'exists' {
        Test-Path -LiteralPath $workflowPath | Should -BeTrue
    }

    It 'is named as requested' {
        $workflowRaw | Should -Match '(?m)^name:\s*Build and Release Tiny11 Core-Gaming\s*$'
    }

    It 'preserves every input from the Core workflow' {
        foreach ($input in @(
            'windows_version', 'windows_iso_url', 'windows_build', 'image_index',
            'language', 'skip_cleanup', 'enable_dotnet35', 'preserve_winre',
            'remove_defender', 'account_setup'
        )) {
            $workflowRaw | Should -Match "(?m)^\s{6}$([regex]::Escape($input)):"
        }
    }

    It 'adds a toggle for every gaming group' {
        foreach ($input in @(
            'hags', 'atlas_power_scheme', 'disable_cpu_idle', 'disable_security_mitigations',
            'remove_xbox_gaming_stack', 'strip_background_noise', 'instant_windows',
            'disable_fast_startup',
            'network_latency_tweaks', 'disable_mpo', 'latency_input_tweaks', 'disable_fso',
            'disable_game_mode', 'disable_printing', 'install_game_runtimes'
        )) {
            $workflowRaw | Should -Match "(?m)^\s{6}$([regex]::Escape($input)):"
        }
    }

    It 'declares exactly one toggle per profile group' {
        # Catches a group added to the profile but never exposed in the workflow UI.
        # Slice to the workflow_dispatch block so unrelated 6-space keys (e.g. the
        # permissions entries) are not picked up.
        $start = $workflowRaw.IndexOf('workflow_dispatch:')
        $end   = $workflowRaw.IndexOf("`nenv:", $start)
        $start | Should -BeGreaterThan 0
        $end   | Should -BeGreaterThan $start
        $inputsBlock = $workflowRaw.Substring($start, $end - $start)

        $gamingInputs = [regex]::Matches($inputsBlock, '(?m)^\s{6}([a-z_]+):') |
            ForEach-Object { $_.Groups[1].Value }

        foreach ($group in @($profile.defaultGroups.PSObject.Properties.Name)) {
            $gamingInputs | Should -Contain $group
        }
    }

    It 'passes -GamingProfile and -GamingGroups to the builder' {
        $workflowRaw | Should -Match '-GamingProfile'
        $workflowRaw | Should -Match '-GamingGroups'
        $workflowRaw | Should -Match '-HagsMode'
    }

    It 'validates the profile before downloading the ISO' {
        $validateIndex = $workflowRaw.IndexOf('Validate gaming profile')
        $downloadIndex = $workflowRaw.IndexOf('Download Windows 11 ISO')
        $validateIndex | Should -BeGreaterThan 0
        $validateIndex | Should -BeLessThan $downloadIndex
    }

    It 'targets the Core builder script' {
        $workflowRaw | Should -Match 'tiny11coremaker-headless\.ps1'
    }
}

Describe 'Profile engine functional behaviour' {

    BeforeAll {
        # Dot-source the real engine and drive it against a throwaway scratch tree.
        # DISM / registry / download paths are not exercised - they need the offline image.
        . (Join-Path $repoRoot 'scripts/gaming-profile.ps1')
        Initialize-GamingModule -LogFile $null -ProfileDirectory (Join-Path $repoRoot 'config')

        $script:EngineProfile = Import-GamingProfile
        $script:StagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("tiny11-gaming-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:ScratchDir = Join-Path $script:StagingRoot 'scratchdir'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:ScratchDir 'Windows\System32\config') | Out-Null

        # install_game_runtimes stays off so the test never touches the network.
        $script:TestGroups = Resolve-GamingGroups -Profile $script:EngineProfile `
            -Overrides @{ install_game_runtimes = $false }

        New-GamingFirstBootPayload -Profile $script:EngineProfile -Groups $script:TestGroups `
            -ScratchDir $script:ScratchDir -ScriptRoot (Join-Path $repoRoot 'scripts') -HagsMode 'on' |
            Out-Null

        $script:GamingDir = Join-Path $script:ScratchDir 'Windows\Tiny11Gaming'
    }

    AfterAll {
        if ($script:StagingRoot -and (Test-Path -LiteralPath $script:StagingRoot)) {
            Remove-Item -LiteralPath $script:StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns a single profile object rather than an array' {
        # Regression guard: log output or a validator return value leaking onto the
        # output stream turns this into an array and silently breaks every lookup.
        $script:EngineProfile | Should -Not -BeOfType [array]
        $script:EngineProfile.PSObject.Properties.Name | Should -Contain 'registry'
        $script:EngineProfile.PSObject.Properties.Name | Should -Contain 'schemaVersion'
    }

    It 'honours group overrides without disturbing other groups' {
        $script:TestGroups['install_game_runtimes'] | Should -BeFalse
        $script:TestGroups['disable_game_mode']     | Should -BeTrue
    }

    It 'ignores an unknown group override instead of throwing' {
        { Resolve-GamingGroups -Profile $script:EngineProfile -Overrides @{ not_real = $false } } |
            Should -Not -Throw
    }

    It 'stages every file the target machine needs' {
        foreach ($name in @(
            'gaming-firstboot.ps1',
            'Undo-GamingTweaks.ps1',
            'gaming_power_settings.json',
            'gaming_profile.json',
            'gaming_groups.json',
            'GAMING_PROFILE.md'
        )) {
            Test-Path -LiteralPath (Join-Path $script:GamingDir $name) | Should -BeTrue
        }
    }

    It 'writes a SetupComplete.cmd that invokes the first-boot payload' {
        $setupComplete = Join-Path $script:ScratchDir 'Windows\Setup\Scripts\SetupComplete.cmd'
        Test-Path -LiteralPath $setupComplete | Should -BeTrue
        (Get-Content -LiteralPath $setupComplete -Raw) | Should -Match 'gaming-firstboot\.ps1'
    }

    It 'records the resolved group flags for the target machine' {
        $groupsFile = Join-Path $script:GamingDir 'gaming_groups.json'
        $parsed = Get-Content -LiteralPath $groupsFile -Raw | ConvertFrom-Json
        $parsed.groups.install_game_runtimes | Should -BeFalse
        $parsed.hagsMode | Should -Be 'on'
    }

    It 'writes a manifest listing what was applied and what cannot be undone' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:GamingDir 'GAMING_PROFILE.md') -Raw
        $manifest | Should -Match 'Tiny11 Core-Gaming'
        $manifest | Should -Match 'disable_security_mitigations'
        $manifest | Should -Match 'HAGS'
        $manifest | Should -Match 'Not reversible'
    }

    It 'rejects a profile whose registry entry uses an unknown hive' {
        $bad = $script:EngineProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $bad.registry[0].hive = 'NOTAHIVE'
        { Test-GamingProfile -Profile $bad } | Should -Throw '*unknown hive*'
    }

    It 'rejects a profile that is missing a required key' {
        $bad = $script:EngineProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $bad.PSObject.Properties.Remove('services')
        { Test-GamingProfile -Profile $bad } | Should -Throw '*missing required key*'
    }
}
