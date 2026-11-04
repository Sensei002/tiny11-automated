<#
.SYNOPSIS
    Pester tests for the Tiny11 Standard-Gaming variant.

.DESCRIPTION
    Validates the compatibility-first preset, the Standard builder's gaming switches,
    the dedicated workflow and the shared first-boot/revert payload. Static checks only:
    nothing here mounts an image or runs DISM, so the suite runs anywhere Pester 5 is
    available.

.EXAMPLE
    Invoke-Pester -Path tests/Test-StandardGaming.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $configDir = Join-Path $repoRoot 'config'
    $scriptsDir = Join-Path $repoRoot 'scripts'

    $compatiblePath = Join-Path $configDir 'gaming_profile_compatible.json'
    $baseProfilePath = Join-Path $configDir 'gaming_profile.json'
    $builderPath = Join-Path $scriptsDir 'tiny11maker-headless.ps1'
    $enginePath = Join-Path $scriptsDir 'gaming-profile.ps1'
    $firstBootPath = Join-Path $scriptsDir 'gaming-firstboot.ps1'
    $undoPath = Join-Path $scriptsDir 'Undo-GamingTweaks.ps1'
    $workflowPath = Join-Path $repoRoot '.github/workflows/build-tiny11-standard-gaming.yml'

    $compatible = Get-Content -LiteralPath $compatiblePath -Raw | ConvertFrom-Json
    $baseProfile = Get-Content -LiteralPath $baseProfilePath -Raw | ConvertFrom-Json
    $builder = Get-Content -LiteralPath $builderPath -Raw
    $workflowRaw = Get-Content -LiteralPath $workflowPath -Raw

    function Get-GroupDefault {
        param($Profile, [string]$Name)
        $prop = $Profile.defaultGroups.PSObject.Properties[$Name]
        if ($prop) { return [bool]$prop.Value }
        return $null
    }
}

Describe 'Standard-Gaming compatible preset' {

    It 'exists' {
        Test-Path -LiteralPath $compatiblePath | Should -BeTrue
    }

    It 'declares its own profile name instead of masquerading as Core-Gaming' {
        $compatible.profile | Should -Be 'standard-gaming-compatible'
        $compatible.title | Should -Match 'Standard-Gaming'
    }

    It 'keeps the same schema version and group set as the base profile' {
        $compatible.schemaVersion | Should -Be $baseProfile.schemaVersion
        $baseGroups = @($baseProfile.defaultGroups.PSObject.Properties.Name | Sort-Object)
        $newGroups = @($compatible.defaultGroups.PSObject.Properties.Name | Sort-Object)
        $newGroups | Should -Be $baseGroups
    }

    It 'has every required top-level key' {
        $required = @(
            'schemaVersion', 'profile', 'hivePrefixes', 'defaultGroups',
            'registry', 'services', 'appxPrefixes', 'systemPackages',
            'optionalFeatures', 'revert'
        )
        $present = @($compatible.PSObject.Properties.Name)
        foreach ($key in $required) {
            $present | Should -Contain $key
        }
    }

    It 'references only groups declared in defaultGroups' {
        $known = @($compatible.defaultGroups.PSObject.Properties.Name)

        foreach ($entry in $compatible.registry)         { $known | Should -Contain $entry.group }
        foreach ($entry in $compatible.services)         { $known | Should -Contain $entry.group }
        foreach ($entry in $compatible.appxPrefixes)     { $known | Should -Contain $entry.group }
        foreach ($entry in $compatible.systemPackages)   { $known | Should -Contain $entry.group }
        foreach ($entry in $compatible.optionalFeatures) { $known | Should -Contain $entry.group }
    }

    It 'documents every group' {
        $documented = @($compatible.groupDescriptions.PSObject.Properties.Name)
        foreach ($group in $compatible.defaultGroups.PSObject.Properties.Name) {
            $documented | Should -Contain $group
        }
    }

    It 'leaves security mitigations, the Xbox stack, background noise and printing on' {
        (Get-GroupDefault $compatible 'disable_security_mitigations') | Should -BeFalse
        (Get-GroupDefault $compatible 'remove_xbox_gaming_stack')   | Should -BeFalse
        (Get-GroupDefault $compatible 'strip_background_noise')     | Should -BeFalse
        (Get-GroupDefault $compatible 'disable_printing')           | Should -BeFalse
    }

    It 'leaves Fast Startup off the group list so hibernation survives' {
        # The group is coupled to 'powercfg -h off' in gaming-firstboot.ps1. Enabling it
        # would delete hiberfil.sys, which is not what a daily driver wants.
        (Get-GroupDefault $compatible 'disable_fast_startup') | Should -BeFalse
        $firstBoot = Get-Content -LiteralPath $firstBootPath -Raw
        $firstBoot | Should -Match "if \(Test-GroupEnabled 'disable_fast_startup'\)"
        $firstBoot | Should -Match 'powercfg -h off'
    }

    It 'does not disable hibernation through the power-scheme group' {
        # atlas_power_scheme writes HibernateEnabled=0 in the base profile. The
        # compatible preset enables that group but must not lose hibernation with it.
        $entries = @($compatible.registry |
            Where-Object { $_.name -in @('HibernateEnabled', 'HibernateEnabledDefault') })
        $entries | Should -BeNullOrEmpty
        @($baseProfile.registry | Where-Object { $_.name -eq 'HibernateEnabled' }).Count |
            Should -BeGreaterThan 0
    }

    It 'keeps the low-risk latency groups enabled' {
        foreach ($group in @(
            'atlas_power_scheme', 'instant_windows', 'network_latency_tweaks',
            'disable_mpo', 'latency_input_tweaks', 'interrupt_latency',
            'disable_fso', 'disable_game_mode'
        )) {
            (Get-GroupDefault $compatible $group) | Should -BeTrue -Because "$group is a compatible latency tweak"
        }
        (Get-GroupDefault $compatible 'disable_cpu_idle') | Should -BeFalse
    }

    It 'removes no AppX packages, system packages or optional features by default' {
        $enabled = @()
        foreach ($entry in $compatible.appxPrefixes) {
            if (Get-GroupDefault $compatible $entry.group) { $enabled += "appx:$($entry.prefix)" }
        }
        foreach ($entry in $compatible.systemPackages) {
            if (Get-GroupDefault $compatible $entry.group) { $enabled += "package:$($entry.pattern)" }
        }
        foreach ($entry in $compatible.optionalFeatures) {
            if (Get-GroupDefault $compatible $entry.group) { $enabled += "feature:$($entry.name)" }
        }
        $enabled | Should -BeNullOrEmpty
    }

    It 'changes no services by default' {
        $enabled = @()
        foreach ($entry in $compatible.services) {
            if (Get-GroupDefault $compatible $entry.group) { $enabled += $entry.name }
        }
        $enabled | Should -BeNullOrEmpty
    }

    It 'has an empty serviceRestore list because it disables no services' {
        @($compatible.revert.serviceRestore).Count | Should -Be 0
    }

    It 'still ships an honest irreversible list' {
        @($compatible.revert.irreversible).Count | Should -BeGreaterThan 0
        @($compatible.revert.reversible).Count | Should -BeGreaterThan 0
    }

    It 'does not revert security, hibernation or background values it never changed' {
        foreach ($name in @(
            'EnableVirtualizationBasedSecurity', 'FeatureSettingsOverride',
            'FeatureSettingsOverrideMask', 'HiberbootEnabled', 'HibernateEnabled',
            'GlobalUserDisabled', 'VisualFXSetting'
        )) {
            @($compatible.revert.reversible | Where-Object { $_.name -eq $name }).Count |
                Should -Be 0 -Because "$name belongs to a disabled group"
        }
        $security = @($compatible.revert.reversible | Where-Object {
            $_.path -like '*DeviceGuard*' -or $_.path -like '*HypervisorEnforcedCodeIntegrity*'
        })
        $security | Should -BeNullOrEmpty
    }

    It 'does not alter the aggressive Core-Gaming preset' {
        $baseProfile.profile | Should -Be 'core-gaming'
        (Get-GroupDefault $baseProfile 'disable_security_mitigations') | Should -BeTrue
        (Get-GroupDefault $baseProfile 'remove_xbox_gaming_stack')   | Should -BeTrue
        (Get-GroupDefault $baseProfile 'disable_fast_startup')       | Should -BeTrue
        (Get-GroupDefault $baseProfile 'disable_printing')           | Should -BeTrue
    }
}

Describe 'Standard builder gaming integration' {

    It 'declares the gaming switches as opt-in' {
        $builder | Should -Match '\[switch\]\$GamingProfile'
        $builder | Should -Match '\[string\]\$GamingProfileFile'
        $builder | Should -Match '\[hashtable\]\$GamingGroups'
        $builder | Should -Match '\[switch\]\$PreserveWebView2'
        $builder | Should -Match '\[switch\]\$PreserveXbox'
    }

    It 'defaults HAGS to leave on the Standard builder' {
        $builder | Should -Match "\[string\]\`$HagsMode\s*=\s*'leave'"
    }

    It 'dot-sources the engine only when -GamingProfile is set' {
        $builder | Should -Match '(?s)if \(\$GamingProfile\) \{.*?\. \$gamingModule'
    }

    It 'runs all four engine stages in the Standard pipeline' {
        foreach ($function in @(
            'Invoke-GamingAppxRemoval', 'Invoke-GamingSystemPackageRemoval',
            'Invoke-GamingOptionalFeatureRemoval', 'Invoke-GamingRegistryTweaks',
            'Invoke-GamingServiceTweaks', 'New-GamingFirstBootPayload'
        )) {
            $builder | Should -Match ("(?m)^[ \t]+$([regex]::Escape($function))\b")
        }
    }

    It 'bundles the selected profile, not always gaming_profile.json' {
        $builder | Should -Match '-ProfilePath \$gamingProfilePath'
    }

    It 'writes Standard-Gaming build info only after a gaming build' {
        $builder | Should -Match 'tiny11-standard-gaming-buildinfo\.json'
        $builder | Should -Match '(?s)if \(\$GamingProfile\) \{.*?Write-GamingBuildInfo'
    }

    It 'guards the WebView2 paths behind -PreserveWebView2' {
        ([regex]::Matches($builder, 'if \(-not \$PreserveWebView2\)')).Count |
            Should -BeGreaterThan 1
        $builder | Should -Match 'Microsoft\\EdgeWebView'
        $builder | Should -Match 'microsoft-edge-webview_31bf3856ad364e35'
    }

    It 'still removes Edge and OneDrive when WebView2 is preserved' {
        $builder | Should -Match 'Program Files \(x86\)\\Microsoft\\Edge"'
        $builder | Should -Match 'OneDrive'
    }

    It 'keeps Xbox packages out of the Standard removal list under -PreserveXbox' {
        $builder | Should -Match "if \(\`$PreserveXbox\)"
        $builder | Should -Match "-notlike 'Microsoft\.Xbox\*'"
        $builder | Should -Match "Microsoft\.GamingApp"
    }
}

Describe 'Standard-Gaming workflow' {

    It 'exists and is named as requested' {
        Test-Path -LiteralPath $workflowPath | Should -BeTrue
        $workflowRaw | Should -Match '(?m)^name:\s*Build and Release Tiny11 Standard-Gaming\s*$'
    }

    It 'declares exactly 11 workflow_dispatch inputs' {
        $start = $workflowRaw.IndexOf('workflow_dispatch:')
        $end = $workflowRaw.IndexOf("`nenv:", $start)
        $inputsBlock = $workflowRaw.Substring($start, $end - $start)
        $inputs = [regex]::Matches($inputsBlock, '(?m)^ {6}([a-zA-Z_0-9-]+):')
        @($inputs).Count | Should -Be 11
    }

    It 'keeps the Standard inputs and adds only three gaming inputs' {
        $start = $workflowRaw.IndexOf('workflow_dispatch:')
        $end = $workflowRaw.IndexOf("`nenv:", $start)
        $inputsBlock = $workflowRaw.Substring($start, $end - $start)

        foreach ($input in @(
            'windows_version', 'windows_iso_url', 'windows_build', 'image_index',
            'language', 'skip_cleanup', 'account_setup', 'update_to_latest'
        )) {
            $inputsBlock | Should -Match "(?m)^ {6}$([regex]::Escape($input)):"
        }
        foreach ($input in @('gaming_preset', 'disable_cpu_idle', 'hags')) {
            $inputsBlock | Should -Match "(?m)^ {6}$([regex]::Escape($input)):"
        }
        $inputsBlock | Should -Not -Match '(?m)^ {6}pause_windows_update:'
    }

    It 'does not reintroduce a toggle per profile group' {
        $start = $workflowRaw.IndexOf('workflow_dispatch:')
        $end = $workflowRaw.IndexOf("`nenv:", $start)
        $inputsBlock = $workflowRaw.Substring($start, $end - $start)

        foreach ($group in @($baseProfile.defaultGroups.PSObject.Properties.Name)) {
            if ($group -eq 'disable_cpu_idle') { continue }
            $inputsBlock | Should -Not -Match "(?m)^ {6}$([regex]::Escape($group)):"
        }
    }

    It 'defaults to the compatible preset and maps aggressive to the Core profile' {
        $workflowRaw | Should -Match "if \(\[string\]::IsNullOrWhiteSpace\(\`$gamingPreset\)\) \{ \`$gamingPreset = 'compatible' \}"
        $workflowRaw | Should -Match 'config\\gaming_profile_compatible\.json'
        $workflowRaw | Should -Match "if \(\`$gamingPreset -eq 'aggressive'\)"
        $workflowRaw | Should -Match 'config\\gaming_profile\.json'
    }

    It 'passes the gaming layer and both preservation switches to the Standard builder' {
        $workflowRaw | Should -Match '\$params\.GamingProfile\s*=\s*\$true'
        $workflowRaw | Should -Match '\$params\.GamingProfileFile\s*=\s*\$gamingProfileFile'
        $workflowRaw | Should -Match '\$params\.PreserveWebView2\s*=\s*\$true'
        $workflowRaw | Should -Match '\$params\.PreserveXbox\s*=\s*\$true'
        $workflowRaw | Should -Match '\$params\.HagsMode\s*=\s*\$hags'
        $workflowRaw | Should -Match 'tiny11maker-headless\.ps1 @params'
    }

    It 'verifies the gaming build info and fails instead of shipping a plain Standard ISO' {
        $workflowRaw | Should -Match 'tiny11-standard-gaming-buildinfo\.json'
        $guardIndex = $workflowRaw.IndexOf('if (-not (Test-Path $gamingInfoPath))')
        $guardIndex | Should -BeGreaterThan 0
        $guardBlock = $workflowRaw.Substring($guardIndex, 400)
        $guardBlock | Should -Match 'the gaming layer did not run'
        $guardBlock | Should -Match 'exit 1'
    }

    It 'uses Standard-Gaming folder, ISO and tag names' {
        $workflowRaw | Should -Match 'Tiny11StandardGaming-\$edition-\$version'
        $workflowRaw | Should -Match 'Tiny11StandardGaming-\$version-\$buildNumber'
        $workflowRaw | Should -Match 'stdgaming'
    }

    It 'runs the Standard builder job' {
        $workflowRaw | Should -Match '(?m)^  build-tiny11-standard-gaming:'
        $workflowRaw | Should -Match 'tiny11maker-headless\.ps1'
    }
}

Describe 'Shared first-boot and revert payload' {

    It 'describes the first-boot script as shared rather than Core-only' {
        $firstBoot = Get-Content -LiteralPath $firstBootPath -Raw
        $firstBoot | Should -Match 'Tiny11 gaming first-boot payload'
        $firstBoot | Should -Match 'Core-Gaming and Standard-Gaming'
        $firstBoot | Should -Match "Tiny11 gaming baseline"
    }

    It 'keeps powercfg -h off behind the Fast Startup group' {
        $firstBoot = Get-Content -LiteralPath $firstBootPath -Raw
        $pattern = "(?s)if \(Test-GroupEnabled 'disable_fast_startup'\) \{.*?powercfg -h off"
        $firstBoot | Should -Match $pattern
    }

    It 'drives the undo intro from the bundled profile instead of hardcoded claims' {
        $undo = Get-Content -LiteralPath $undoPath -Raw
        $undo | Should -Match '\$revertCount = @\(\$revert\.reversible\)\.Count'
        $undo | Should -Match '\$serviceCount = @\(\$revert\.serviceRestore\)\.Count'
        $undo | Should -Not -Match 'Windows Search / Bluetooth services'
    }
}

Describe 'Compatible preset staging' {

    BeforeAll {
        . $enginePath
        Initialize-GamingModule -LogFile $null -ProfileDirectory $configDir

        $script:CompatibleProfile = Import-GamingProfile -Path $compatiblePath
        $script:CompatibleGroups = Resolve-GamingGroups -Profile $script:CompatibleProfile

        $script:StagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("tiny11-stdgaming-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:ScratchDir = Join-Path $script:StagingRoot 'scratchdir'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:ScratchDir 'Windows\System32\config') | Out-Null

        New-GamingFirstBootPayload -Profile $script:CompatibleProfile -Groups $script:CompatibleGroups `
            -ScratchDir $script:ScratchDir -ScriptRoot $scriptsDir `
            -ProfilePath $compatiblePath -HagsMode 'leave' | Out-Null

        $script:GamingDir = Join-Path $script:ScratchDir 'Windows\Tiny11Gaming'
    }

    AfterAll {
        if ($script:StagingRoot -and (Test-Path -LiteralPath $script:StagingRoot)) {
            Remove-Item -LiteralPath $script:StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'bundles the compatible preset for the revert script' {
        $staged = Get-Content -LiteralPath (Join-Path $script:GamingDir 'gaming_profile.json') -Raw |
            ConvertFrom-Json
        $staged.profile | Should -Be 'standard-gaming-compatible'
    }

    It 'records the compatible group flags for the target machine' {
        $staged = Get-Content -LiteralPath (Join-Path $script:GamingDir 'gaming_groups.json') -Raw |
            ConvertFrom-Json
        $staged.groups.disable_fast_startup     | Should -BeFalse
        $staged.groups.remove_xbox_gaming_stack | Should -BeFalse
        $staged.groups.disable_printing         | Should -BeFalse
        $staged.hagsMode                        | Should -Be 'leave'
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
}
