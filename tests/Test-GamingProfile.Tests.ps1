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
            'optionalFeatures', 'revert'
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

    It 'enables the device-latency group by default' {
        $profile.defaultGroups.interrupt_latency | Should -BeTrue
    }

    It 'leaves VRR optimisation ON in the DirectX global settings' {
        # It was 0 in an earlier revision. 0 tells DWM not to align presentation to the
        # display's refresh window, which is the opposite of what frame pacing wants.
        $entry = $profile.registry |
            Where-Object { $_.name -eq 'DirectXUserGlobalSettings' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.value | Should -Match 'SwapEffectUpgradeEnable=1'
        $entry.value | Should -Match 'VRROptimizeEnable=1'
        $entry.value | Should -Not -Match 'VRROptimizeEnable=0'
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

    It 'uses the Ultimate Performance template, because that is what Atlas derives from' {
        # Verified against the live Atlas scheme: 25 of its 27 visible settings are
        # byte-identical to Ultimate Performance. Duplicating any other base would not
        # reproduce it, so this must NOT be changed to High performance.
        $power.baseTemplate.guid | Should -Be 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    }

    It 'provides fallback templates' {
        @($power.baseTemplate.fallbacks).Count | Should -BeGreaterThan 0
    }

    It 'records what it was matched against' {
        $power.matchedAgainst.guid | Should -Be '11111111-1111-1111-1111-111111111111'
        $power.matchedAgainst.name | Should -Be 'Atlas Power Scheme'
        $power.matchedAgainst.finding | Should -Match 'Ultimate Performance'
    }

    It 'carries all 27 settings from the live Atlas scheme' {
        $atlasSettings = @($power.settings | Where-Object { -not $_.beyondAtlas })
        $atlasSettings.Count | Should -Be 27
    }

    It 'marks exactly the two settings that differ from Ultimate Performance' {
        $overrides = @($power.settings | Where-Object { $_.atlasOverride })
        $overrides.Count | Should -Be 2
        @($overrides | ForEach-Object { $_.setting }) | Should -Contain '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
        @($overrides | ForEach-Object { $_.setting }) | Should -Contain '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    }

    It 'matches the Atlas values for the two overrides' {
        $usb = $power.settings | Where-Object { $_.setting -eq '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
        $usb.ac | Should -Be 0
        $usb.dc | Should -Be 1

        $display = $power.settings | Where-Object { $_.setting -eq '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' }
        $display.ac | Should -Be 0
        $display.dc | Should -Be 180
    }

    It 'keeps the CPU-idle divergence gated behind its own group and flagged' {
        # Atlas leaves CPU idle ENABLED. Ours disables it, so it must be both
        # independently switchable and labelled as a divergence.
        $idle = $power.settings | Where-Object { $_.setting -eq '5d76a2ca-e8c0-402f-a133-2158492d58ad' }
        $idle | Should -Not -BeNullOrEmpty
        $idle.group | Should -Be 'disable_cpu_idle'
        $idle.beyondAtlas | Should -BeTrue
    }

    It 'gives every power setting a subgroup, GUID, and AC/DC value' {
        foreach ($setting in $power.settings) {
            $setting.subgroup | Should -Match '^[0-9a-fA-F-]{36}$'
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

    It 'sets the energy-performance preference and boost policy unconditionally' {
        # These two can only widen the clock ceiling, never narrow it, so they must
        # apply even when C-states are left enabled. Gating them behind
        # disable_cpu_idle meant a build could ship with a capped clock AND no idle
        # states - the exact combination that pins a 3.6 GHz part at 3.4 GHz.
        $epp = $power.settings | Where-Object { $_.setting -eq '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' }
        $epp | Should -Not -BeNullOrEmpty
        $epp.ac | Should -Be 0
        $epp.group | Should -BeNullOrEmpty
        $epp.beyondAtlas | Should -BeTrue

        $boost = $power.settings | Where-Object { $_.setting -eq '45bcc044-d885-43e2-8605-ee0ec6e96b59' }
        $boost | Should -Not -BeNullOrEmpty
        $boost.ac | Should -Be 100
        $boost.group | Should -BeNullOrEmpty
    }

    It 'uses the Enabled boost mode rather than Aggressive' {
        # 2 (Aggressive) overrides the platform's own boost and power budget, and on
        # locked/non-K parts can hold the package at its guaranteed frequency.
        $mode = $power.settings | Where-Object { $_.setting -eq 'be337238-0d82-4146-a960-4f3749d470c7' }
        $mode | Should -Not -BeNullOrEmpty
        $mode.ac | Should -Be 1
        $mode.dc | Should -Be 1
    }

    It 'keeps the storage and USB links out of low-power states' {
        $ahci = $power.settings | Where-Object { $_.setting -eq '0b2d69d7-a2a1-449c-9680-f91c70521c60' }
        $ahci | Should -Not -BeNullOrEmpty
        $ahci.ac | Should -Be 0

        $usb3 = $power.settings | Where-Object { $_.setting -eq 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' }
        $usb3 | Should -Not -BeNullOrEmpty
        $usb3.ac | Should -Be 0
        $usb3.group | Should -Be 'latency_input_tweaks'
    }

    It 'deletes useplatformtick instead of setting it' {
        # Forcing the platform tick source is slower than the invariant TSC, so the
        # profile must never re-introduce it.
        ($power.bcd | Where-Object { $_.args -match '/set\s+useplatformtick\s+yes' }) | Should -BeNullOrEmpty
        ($power.bcd | Where-Object { $_.args -match '/deletevalue\s+useplatformtick' }) | Should -Not -BeNullOrEmpty
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
            'Invoke-GamingOptionalFeatureRemoval',
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

    It 'first-boot script applies the device-latency layer' {
        $content = Get-Content -LiteralPath $firstBootPath -Raw
        foreach ($fn in @(
            'Set-GamingInterruptLatency', 'Set-GamingNetworkAdapter',
            'Set-GamingUsbPower', 'Set-GamingMemoryCompression'
        )) {
            $content | Should -Match ("function\s+$([regex]::Escape($fn))\b")
        }
    }

    It 'only enables MSI where the driver already publishes MSI properties' {
        # This is the safety property: forcing MSI on a device that cannot do it is how
        # a latency tweak turns into a machine that will not boot.
        $content = Get-Content -LiteralPath $firstBootPath -Raw
        $content | Should -Match 'MessageSignaledInterruptProperties'
        $content | Should -Match 'Test-Path -LiteralPath \$msiKey'
    }

    It 'honours group gating for bcdedit entries' {
        $content = Get-Content -LiteralPath $firstBootPath -Raw
        $content | Should -Match '\$entry\.group'
        $content | Should -Match '-Groups \$groups'
    }

    It 'core builder no longer sets useplatformtick' {
        $content = Get-Content -LiteralPath $builderPath -Raw
        $content | Should -Not -Match 'bcdedit /set useplatformtick yes'
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
        # preserve_winre is deliberately absent: WinRE is always kept, so there is no
        # toggle to mirror. See Test-WinRERecovery.Tests.ps1.
        foreach ($input in @(
            'windows_version', 'windows_iso_url', 'windows_build', 'image_index',
            'language', 'skip_cleanup', 'enable_dotnet35',
            'remove_defender', 'account_setup'
        )) {
            $workflowRaw | Should -Match "(?m)^\s{6}$([regex]::Escape($input)):"
        }
    }

    It 'offers the gaming preset plus the two independent exceptions' {
        # The workflow sits at GitHub's 25 workflow_dispatch input cap: a 26th input
        # makes the whole file unparseable, and it then shows up named after its path
        # and runs as a 0-job failure. The 14 group switches still exist - on the
        # builder as -GamingGroups, in config/gaming_profile.json, and as a group
        # editor in the local GUI - so the workflow only has to offer the preset, the
        # one group with a documented hardware downside, and HAGS.
        foreach ($input in @('gaming_tweaks', 'disable_cpu_idle', 'hags', 'pause_windows_update')) {
            $workflowRaw | Should -Match "(?m)^\s{6}$([regex]::Escape($input)):"
        }
    }

    It 'no longer declares a toggle per profile group' {
        # A regression here means the collapse was partly undone, which is how the
        # input cap gets hit again.
        $start = $workflowRaw.IndexOf('workflow_dispatch:')
        $end   = $workflowRaw.IndexOf("`nenv:", $start)
        $inputsBlock = $workflowRaw.Substring($start, $end - $start)

        foreach ($group in @($profile.defaultGroups.PSObject.Properties.Name)) {
            if ($group -eq 'disable_cpu_idle') { continue }
            $inputsBlock | Should -Not -Match "(?m)^\s{6}$([regex]::Escape($group)):"
        }
    }

    It 'names every profile group when the preset is turned off' {
        # gaming_tweaks off has to force every group off explicitly, or a group added
        # to the profile later would stay enabled in a "bare Core" build.
        foreach ($group in @($profile.defaultGroups.PSObject.Properties.Name)) {
            if ($group -eq 'disable_cpu_idle') { continue }
            $workflowRaw | Should -Match ([regex]::Escape("'$group'"))
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

        # Drive a real override so the group gating is exercised.
        $script:TestGroups = Resolve-GamingGroups -Profile $script:EngineProfile `
            -Overrides @{ disable_mpo = $false }

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
        $script:TestGroups['disable_mpo']       | Should -BeFalse
        $script:TestGroups['disable_game_mode'] | Should -BeTrue
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
        $parsed.groups.disable_mpo | Should -BeFalse
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

Describe 'Windows Update modes' {

    BeforeAll {
        $builder = Get-Content -LiteralPath $builderPath -Raw
        $gamingGate = [regex]::Escape('if ($RemoveDefender -or $GamingProfile) {')

        # The pause function body, so the "pause does not disable anything" tests read
        # the implementation rather than the whole file.
        $pauseMatch = [regex]::Match($builder, '(?s)function Set-WindowsUpdatePause \{.*?\n\}')
        $pauseBody = $pauseMatch.Value
    }

    It 'defines all three Windows Update passes' {
        $builder | Should -Match 'function Remove-WindowsUpdatePayload'
        $builder | Should -Match 'function Remove-WindowsUpdateStack'
        $builder | Should -Match 'function Set-WindowsUpdatePause'
    }

    It 'gates both halves of the removal behind the removed mode' {
        # Removal is no longer the default, so an unguarded call here would ship a
        # non-serviceable image whatever the build asked for.
        foreach ($fn in @('Remove-WindowsUpdatePayload', 'Remove-WindowsUpdateStack')) {
            $callIndex = Get-MainCallIndex -Content $builder -Name $fn
            $callIndex | Should -BeGreaterThan 0

            $gateIndex = $builder.Substring(0, $callIndex).LastIndexOf('$WindowsUpdateMode -eq ''removed''')
            $gateIndex | Should -BeGreaterThan 0
            ($callIndex - $gateIndex) | Should -BeLessThan 200
        }
    }

    It 'writes the pause window only in the paused branch' {
        $callIndex = Get-MainCallIndex -Content $builder -Name 'Set-WindowsUpdatePause'
        $callIndex | Should -BeGreaterThan 0

        $gateIndex = $builder.Substring(0, $callIndex).LastIndexOf('$WindowsUpdateMode -eq ''paused''')
        $gateIndex | Should -BeGreaterThan 0
        ($callIndex - $gateIndex) | Should -BeLessThan 200
    }

    It 'pauses until the year 3000 and raises the client pause cap' {
        # FlightSettingsMaxPauseDays is the whole feature: the client clamps the pause
        # window to the 35-day Settings maximum unless it is raised, and a clamped
        # window looks identical in Settings while the client keeps scanning.
        $builder | Should -Match ([regex]::Escape("`$script:WindowsUpdatePauseExpiry = '3000-01-01T00:00:00Z'"))
        $pauseBody | Should -Match 'FlightSettingsMaxPauseDays'
        $pauseBody | Should -Match "'3650000'"
        foreach ($value in @('PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime')) {
            $pauseBody | Should -Match ([regex]::Escape($value))
        }
    }

    It 'does not disable a service, delete a task or hide the page while pausing' {
        # A paused device is a supported state, so nothing has to be torn out to hold
        # it - and tearing things out is what made Windows repair the stack.
        $pauseBody | Should -Not -BeNullOrEmpty
        $pauseBody | Should -Not -Match ([regex]::Escape("'Start' 'REG_DWORD' '4'"))
        $pauseBody | Should -Not -Match 'Remove-Item'
        $pauseBody | Should -Not -Match 'SettingsPageVisibility'
        $pauseBody | Should -Not -Match 'Unregister-ScheduledTask'
    }

    It 'disables the three services that make a WU disable stick, only when removing' {
        # WaaSMedicSvc repairs a disabled Windows Update, UsoSvc runs the boot
        # servicing pass, wuauserv is Windows Update itself. Leaving any of them is
        # what lets "Updates are underway, do not turn off your PC" come back.
        #
        # They are DISABLED, not deleted: deleting an inbox service key gets undone
        # by the servicing stack on the first online boot, and that delete/restore
        # cycle is what produces the back-to-back double restart.
        foreach ($service in @('WaaSMedicSvc', 'UsoSvc', 'wuauserv')) {
            $builder | Should -Match ([regex]::Escape("'$service'"))
        }
        $builder | Should -Not -Match "Remove-Item[^\r\n]*Services\\wuauserv"
        $builder | Should -Not -Match "Remove-RegistryKey[^\r\n]*Services\\wuauserv"

        # Slice to the function that owns the write: the same literals appear in the
        # removal function too, so searching the whole file answers the wrong question.
        $fn = [regex]::Match($builder, '(?s)function Apply-RegistryTweaks \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty

        $gate = $fn.IndexOf("if (`$WindowsUpdateMode -eq 'removed') {")
        $loop = $fn.IndexOf("@('wuauserv', 'UsoSvc', 'WaaSMedicSvc')")
        # Search from the loop header: Apply-RegistryTweaks disables other services
        # (dmwappushservice, Defender) earlier in the same function with the same
        # value, so the first match in the slice belongs to a different tweak.
        $start = $fn.IndexOf("'Start' 'REG_DWORD' '4'", $loop)
        $gate | Should -BeGreaterThan 0 -Because 'the service disable must sit inside the removal branch'
        $loop | Should -BeGreaterThan $gate
        $start | Should -BeGreaterThan $loop
    }

    It 'removes the Update Orchestrator scheduled tasks, only when removing' {
        # Under 'paused' these folders have to stay: WaaSMedic does not touch a paused
        # device, and the orchestrator is what reads the pause window.
        $fn = [regex]::Match($builder, '(?s)function Remove-ScheduledTasks \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty

        $gate = $fn.IndexOf("if (`$WindowsUpdateMode -eq 'removed') {")
        # Case-sensitive IndexOf, and the literal in the script is "$tasksPath\Microsoft\...",
        # so match from "Windows\UpdateOrchestrator" rather than from "Tasks".
        $task = $fn.IndexOf('Windows\UpdateOrchestrator')
        $gate | Should -BeGreaterThan 0
        $task | Should -BeGreaterThan $gate
    }

    It 'sets the NoAutoUpdate policy only in the removal branch' {
        # NoAutoUpdate makes the Settings page report a managed state, which is the
        # opposite of what a paused image is supposed to show.
        $fn = [regex]::Match($builder, '(?s)function Apply-RegistryTweaks \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty

        $gate = $fn.IndexOf("if (`$WindowsUpdateMode -eq 'removed') {")
        $noAuto = $fn.IndexOf("WindowsUpdate\AU' 'NoAutoUpdate'")
        $gate | Should -BeGreaterThan 0
        $noAuto | Should -BeGreaterThan $gate
    }

    It 'hides the Windows Update page only when the stack is removed' {
        # Page ids are the ms-settings URI minus the 'ms-settings:' prefix. The
        # Windows Security page is 'windowsdefender'; 'virus' is not a page id.
        # Under 'paused' the page is the only place the pause is visible and the only
        # way back, so hiding it would turn a reversible state into a mystery.
        $builder | Should -Match ([regex]::Escape("`$hiddenPages = 'windowsupdate;windowsdefender'"))
        $builder | Should -Match ([regex]::Escape('hide:$hiddenPages'))
        $builder | Should -Not -Match ([regex]::Escape("SettingsPageVisibility' 'REG_SZ' 'hide:virus"))
    }

    It 'writes the Settings page visibility value from exactly one place' {
        # Two write sites made the shipped value depend on call order - the gaming
        # function ran last and won. Asserting a single write site removes the
        # ordering question entirely, instead of pinning the order down.
        ([regex]::Matches($builder, "SettingsPageVisibility' 'REG_SZ")).Count | Should -Be 1
    }

    It 'removes only the WU client executables, not the shared DLLs' {
        # wuaueng.dll and wuapi.dll are linked by other inbox components and a
        # missing DLL fails hard, so they are deliberately kept.
        $builder | Should -Match ([regex]::Escape("'Windows\System32\wuauclt.exe'"))
        $builder | Should -Match ([regex]::Escape("'Windows\System32\wuapihost.exe'"))
        $builder | Should -Not -Match ([regex]::Escape("'Windows\System32\wuaueng.dll'"))
        $builder | Should -Not -Match ([regex]::Escape("'Windows\System32\wuapi.dll'"))
    }

    It 'removes Defender on a Core-Gaming build, not only with -RemoveDefender' {
        $builder | Should -Match $gamingGate
        ([regex]::Matches($builder, $gamingGate)).Count | Should -Be 2
    }

    It 'verifies the state it was asked for, for every Core build' {
        # The pause is the default for all of them now, so an unverified pause is
        # exactly as bad as an unverified removal.
        $builder | Should -Match 'function Assert-WindowsUpdateState'

        $assert = [regex]::Match($builder, '(?m)^\s*Assert-WindowsUpdateState\s+-MountDir\s+\$scratchDir\s+-Mode\s+\$WindowsUpdateMode')
        $assert.Success | Should -BeTrue -Because 'the mode has to reach the assertion, or every build is checked as removed'

        # LastIndexOf, not IndexOf: the function definition of Unload-RegistryHives
        # sits near the top of the file and would satisfy an IndexOf comparison
        # without proving anything about the call order.
        $unload = $builder.LastIndexOf('Unload-RegistryHives')
        $assert.Index | Should -BeLessThan $unload
    }

    It 'does not touch DoSvc, which belongs to the profile groups' {
        # DoSvc is owned by strip_background_noise, so an unconditional delete here
        # would ignore that group's toggle.
        $builder | Should -Not -Match ([regex]::Escape("'DoSvc'"))
    }
}
