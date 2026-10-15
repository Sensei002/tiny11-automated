<#
.SYNOPSIS
    Validation tests for the optional NVIDIA debloated-driver injection feature.
    Author: kelexine (https://github.com/kelexine)
    Run: Invoke-Pester ./tests/Test-NvidiaDriver.Tests.ps1

.NOTES
    These tests assert the SHAPE of the feature - the profile contents, the engine's
    parameter surface, the builder's injection hook and the workflow wiring. They do
    not download a driver, drive NVCleanstall or build an ISO, so they are safe to run
    anywhere and fast.
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:ProfilePath  = Join-Path $script:RepoRoot 'config\nvidia_driver_profile.json'
    $script:EnginePath   = Join-Path $script:RepoRoot 'scripts\nvidia-driver-builder.ps1'
    $script:BuilderPath  = Join-Path $script:RepoRoot 'scripts\tiny11coremaker-headless.ps1'
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github\workflows\build-tiny11-core-gaming.yml'

    $script:Profile         = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
    $script:EngineContent   = Get-Content -LiteralPath $script:EnginePath  -Raw
    $script:BuilderContent  = Get-Content -LiteralPath $script:BuilderPath -Raw
    $script:WorkflowContent = Get-Content -LiteralPath $script:WorkflowPath -Raw
}

Describe "NVIDIA driver profile" {

    It "exists and parses as JSON" {
        Test-Path -LiteralPath $script:ProfilePath | Should -BeTrue
        $script:Profile.profile | Should -Be 'nvidia-debloated-driver'
    }

    It "keeps only the Display Driver component" {
        @($script:Profile.components.keep) | Should -Be @('Display Driver (required)')
    }

    It "pins a verified NVCleanstall version and hash" {
        $script:Profile.nvcleanstall.version | Should -Be '1.19.0'
        $script:Profile.nvcleanstall.sha256  | Should -Match '^[0-9A-Fa-f]{64}$'
        $script:Profile.nvcleanstall.downloadUrl | Should -Match 'NVCleanstall_1\.19\.0\.exe$'
    }

    It "encodes every tweak that is ON in the reference screenshots" {
        $required = @(
            'disable_installer_telemetry_advertising',
            'unattended_express_install',
            'allow_automatic_reboot',
            'perform_clean_installation',
            'disable_ansel',
            'show_expert_tweaks',
            'disable_driver_telemetry',
            'disable_hd_audio_sleep_timer',
            'enable_msi',
            'disable_hdcp',
            'rebuild_digital_signature',
            'easy_anticheat_compatible',
            'auto_accept_unsigned_warning'
        )
        foreach ($key in $required) {
            $script:Profile.tweaks.PSObject.Properties.Name | Should -Contain $key
            [bool]$script:Profile.tweaks.$key | Should -BeTrue
        }
    }

    It "leaves the optional tweaks OFF" {
        [bool]$script:Profile.tweaks.add_hardware_support      | Should -BeFalse
        [bool]$script:Profile.tweaks.enable_dlss_indicator     | Should -BeFalse
        [bool]$script:Profile.tweaks.disable_mpo               | Should -BeFalse
        [bool]$script:Profile.tweaks.disable_nvidia_container  | Should -BeFalse
        [bool]$script:Profile.tweaks.nvenc_session_limit_patch | Should -BeFalse
    }

    It "defaults the interrupt policy to Default" {
        $script:Profile.tweaks.interrupt_policy   | Should -Be 'Default'
        $script:Profile.tweaks.interrupt_priority | Should -Be 'Default'
    }
}

Describe "NVIDIA driver engine" {

    It "parses cleanly" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:EnginePath, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It "requires a -DriverVersion parameter" {
        $script:EngineContent -match '\[string\]\$DriverVersion' | Should -BeTrue
    }

    It "offers both the GUI path and the deterministic fallback" {
        $script:EngineContent -match 'Invoke-NvCleanstallGuiBuild'      | Should -BeTrue
        $script:EngineContent -match 'Invoke-NvidiaDeterministicFallback' | Should -BeTrue
        $script:EngineContent -match '\$SkipGui'                        | Should -BeTrue
    }

    It "verifies the NVCleanstall download before use" {
        $script:EngineContent -match 'Get-FileHash' | Should -BeTrue
    }
}

Describe "Builder integration" {

    It "exposes an -NvidiaDriverPath parameter" {
        $script:BuilderContent -match '\[string\]\$NvidiaDriverPath' | Should -BeTrue
    }

    It "defines the injection function" {
        $script:BuilderContent -match 'function Add-NvidiaDriverToImage' | Should -BeTrue
    }

    It "injects the driver before WinSxS optimization" {
        $idxInject = $script:BuilderContent.IndexOf('Add-NvidiaDriverToImage -DriverPath')
        $idxInject | Should -BeGreaterThan 0
        $idxWinSxS = $script:BuilderContent.IndexOf('Optimize-WinSxS', $idxInject)
        $idxWinSxS | Should -BeGreaterThan $idxInject
    }

    It "hooks a first-boot install into SetupComplete.cmd" {
        $script:BuilderContent -match 'SetupComplete\.cmd'            | Should -BeTrue
        $script:BuilderContent -match 'Install-NvidiaDriver\.ps1'     | Should -BeTrue
    }
}

Describe "Workflow wiring" {

    It "adds the nvidia_driver_version input" {
        $script:WorkflowContent -match 'nvidia_driver_version:' | Should -BeTrue
    }

    It "runs the driver builder only when a version is supplied" {
        $script:WorkflowContent -match 'NVIDIA_DRIVER_REQUESTED=false' | Should -BeTrue
        $script:WorkflowContent -match 'nvidia-driver-builder\.ps1 -DriverVersion' | Should -BeTrue
    }

    It "passes the driver path to the builder" {
        $script:WorkflowContent -match 'NvidiaDriverPath = \$env:NVIDIA_DRIVER_PATH' | Should -BeTrue
    }
}
