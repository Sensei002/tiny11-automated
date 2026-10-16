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

    It "vendors the NVCleanstall binary in the repository" {
        $script:Profile.nvcleanstall.bundledPath | Should -Be 'tools/NVCleanstall_1.19.0.exe'
        Test-Path -LiteralPath (Join-Path $script:RepoRoot $script:Profile.nvcleanstall.bundledPath) | Should -BeTrue
    }

    It "the vendored binary matches the pinned SHA256" {
        $bundled = Join-Path $script:RepoRoot $script:Profile.nvcleanstall.bundledPath
        (Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash |
            Should -Be $script:Profile.nvcleanstall.sha256.ToUpper()
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

    It "ships with the GUI path disabled so the deterministic build runs by default" {
        [bool]$script:Profile.gui.enabled | Should -BeFalse
    }

    It "templates the NVIDIA download across more than one host" {
        $script:Profile.fallback.driverUrlTemplate | Should -Match '\{host\}'
        @($script:Profile.fallback.downloadHosts).Count | Should -BeGreaterThan 1
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

    It "prefers the vendored copy over downloading" {
        $script:EngineContent -match 'bundledPath'      | Should -BeTrue
        $script:EngineContent -match '\$NvCleanstallPath' | Should -BeTrue
    }

    It "keeps log output off the success stream" {
        # Write-Output here would append every log line to the return value of the
        # function that logged it, so a function returning a path would hand back an
        # array and the caller would try to launch a process named after the log line.
        $script:EngineContent | Should -Match 'Write-Host \$line'
        $script:EngineContent | Should -Not -Match 'Write-Output \$line'
    }

    It "returns a real Boolean from the download helper" {
        $script:EngineContent | Should -Match 'function Get-FileWithRetry'
        $script:EngineContent | Should -Match '\$ok = \(\$LASTEXITCODE -eq 0\)'
        $script:EngineContent | Should -Match 'MinBytes'
    }

    It "chooses the build path from -Method or the profile" {
        $script:EngineContent | Should -Match "ValidateSet\('auto', 'gui', 'fallback'\)"
        $script:EngineContent | Should -Match '\$nvProfile\.gui\.enabled'
    }

    It "toggles VCL check boxes by clicking and reads the state back" {
        # BM_SETCHECK only repaints the native button; VCL keeps its own Checked
        # property and would go on to apply the previous selection.
        $script:EngineContent | Should -Match '\$script:BM_GETCHECK'
        $script:EngineContent | Should -Not -Match '\$script:BM_SETCHECK'
    }

    It "only edits the INF when a replacement catalog can be built" {
        # Editing the INF invalidates NVIDIA's catalog, and a driver whose catalog
        # does not match will not install from the DriverStore. inf2cat (WDK) is what
        # rebuilds it, so the tweaks are gated on that tooling being present.
        $script:EngineContent | Should -Match 'function Get-Inf2CatPath'
        $script:EngineContent | Should -Match '\$canRebuild'
        $script:EngineContent | Should -Match 'tweaks_in_inf'
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
        $script:WorkflowContent -match "nvidia-driver-builder\.ps1 @builderArgs" | Should -BeTrue
    }

    It "stays within the 25-input workflow_dispatch limit" {
        # GitHub rejects the entire workflow with HTTP 422 - "you may only define up
        # to 25 inputs" - if more are declared, which makes the workflow impossible
        # to trigger at all. That is why the driver build path is a profile flag
        # rather than a 26th input.
        # Line endings are normalised first: with CRLF the `$` anchor in multiline
        # mode never matches, so the count would silently come back as 0.
        $normalized = $script:WorkflowContent -replace "`r`n", "`n"
        $inputLines = [regex]::Matches($normalized, '(?m)^ {6}[a-z][a-z0-9_]*:$')
        $inputLines.Count | Should -BeGreaterThan 0
        $inputLines.Count | Should -BeLessOrEqual 25
        $normalized | Should -Not -Match '(?m)^ {6}nvidia_driver_method:'
    }

    It "passes the build method to the engine from the profile" {
        $script:WorkflowContent -match "'-Method',\s*\$method" | Should -BeTrue
        $script:Profile.gui.PSObject.Properties.Name | Should -Contain 'enabled'
    }

    It "fails the step when the engine exits non-zero" {
        $script:WorkflowContent -match 'nvidia-driver-builder\.ps1 exited with code' | Should -BeTrue
    }

    It "runs on an image that actually ships the Windows Driver Kit" {
        # windows-latest moved to windows-2025, which only has the WDK Visual Studio
        # extension - no inf2cat.exe, so a tweaked driver could never get a matching
        # catalog. windows-2022 has the full WDK.
        $script:WorkflowContent | Should -Match 'runs-on: windows-2022'
    }

    It "reports the signing toolchain before building the driver" {
        $script:WorkflowContent | Should -Match 'inf2cat\.exe :'
        $script:WorkflowContent | Should -Match 'signtool\.exe:'
    }

    It "passes the driver path to the builder" {
        $script:WorkflowContent -match 'NvidiaDriverPath = \$env:NVIDIA_DRIVER_PATH' | Should -BeTrue
    }
}
