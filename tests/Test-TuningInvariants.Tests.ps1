<#
.SYNOPSIS
    Regression tests for the three tuning decisions that are easy to reintroduce
    and expensive to notice: the CPU clock ceiling, Windows Update coming back, and
    the idle memory footprint.

.DESCRIPTION
    Each of these shipped as a real bug in a released image, and each has the same
    shape: a tweak that looks reasonable in isolation, fails silently on real
    hardware, and is invisible in the build log.

      1. CPU clock. 'bcdedit /set disabledynamictick yes' plus a C-State-0 power
         override stops the processor power engine offering turbo on a lot of
         platforms. The CPU then parks at its highest non-boost P-state, so a
         3.6 GHz part reads a constant 3.4 GHz. Nothing errors; the machine just
         runs below its rating.

      2. Windows Update. Disabling only wuauserv leaves WaaSMedicSvc and its
         PerformRemediation task in place, and that task exists to re-enable
         wuauserv. A reboot or two after the machine first sees a network,
         Windows Update is back. Deleting the service keys instead does not help:
         the servicing stack restores missing inbox service registrations, and the
         delete/restore cycle is itself the pending servicing operation that
         produces the back-to-back double restart. The localhost WSUS redirect that
         used to ship alongside it is what made the Settings page show
         "An error occurred" rather than a managed state.

      3. Memory. DisablePagingExecutive=1 and NtfsMemoryUsage=2 both hand scarce
         RAM to the kernel and the file-system cache. On 16 GB that is a fair
         trade; on 8 GB it is not, and the image cannot know what the target has.

    These are asserted as invariants rather than documented as preferences,
    because the failure mode is silent: a build that reintroduces any of them
    still completes and still installs.

    Run: Invoke-Pester ./tests/Test-TuningInvariants.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    $builderPaths = @{
        Core     = Join-Path $repoRoot 'scripts/tiny11coremaker-headless.ps1'
        Nano     = Join-Path $repoRoot 'scripts/nano11builder-headless.ps1'
        Standard = Join-Path $repoRoot 'scripts/tiny11maker-headless.ps1'
    }

    $builderSource = @{}
    foreach ($k in $builderPaths.Keys) {
        $builderSource[$k] = Get-Content -LiteralPath $builderPaths[$k] -Raw
    }

    $firstBootSource = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/gaming-firstboot.ps1') -Raw

    $powerConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'config/gaming_power_settings.json') -Raw | ConvertFrom-Json
    $profileConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'config/gaming_profile.json') -Raw | ConvertFrom-Json
    $gamingWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/build-tiny11-core-gaming.yml') -Raw

    # Comments in this codebase quote the very patterns being asserted on - the note
    # explaining why 'disabledynamictick yes' was removed contains that exact string.
    # Assertions therefore run against executable lines only.
    function Get-ExecutableCode {
        param([Parameter(Mandatory = $true)][string]$Source)
        ($Source -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
}

Describe 'CPU clock ceiling' {

    It 'never sets disabledynamictick in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
        @{ Name = 'Standard' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match 'disabledynamictick\s+yes'
    }

    It 'actively deletes disabledynamictick so older images are corrected' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Match 'bcdedit\s+/deletevalue\s+disabledynamictick'
    }

    It 'has no bcd entry that sets disabledynamictick' {
        $entries = @($powerConfig.bcd | Where-Object { $_.args -match 'disabledynamictick\s+yes' })
        $entries.Count | Should -Be 0
    }

    It 'uses the Enabled boost mode, not Aggressive' {
        $boost = @($powerConfig.settings | Where-Object { $_.setting -eq 'be337238-0d82-4146-a960-4f3749d470c7' })
        $boost.Count | Should -Be 1
        $boost[0].ac | Should -Be 1
        $boost[0].dc | Should -Be 1
    }

    It 'keeps the two ceiling-widening settings outside the disable_cpu_idle group' {
        # EPP and boost policy can only raise the clock ceiling, so they must apply
        # even when C-states are left enabled. Gating them behind disable_cpu_idle
        # was how the build ended up with both a capped clock and no idle states.
        foreach ($guid in @('36687f9e-e3a5-4dbf-b1dc-15eb381c6863', '45bcc044-d885-43e2-8605-ee0ec6e96b59')) {
            $entry = @($powerConfig.settings | Where-Object { $_.setting -eq $guid })
            $entry.Count | Should -Be 1
            $entry[0].group | Should -BeNullOrEmpty
        }
    }

    It 'leaves disable_cpu_idle off by default' {
        $profileConfig.defaultGroups.disable_cpu_idle | Should -BeFalse
        $gamingWorkflow | Should -Match '(?s)disable_cpu_idle:.*?default:\s*false'
    }

    It 'verifies the applied scheme instead of trusting the apply count' {
        $firstBootSource | Should -Match 'function\s+Test-GamingPowerScheme'
        $firstBootSource | Should -Match 'Test-GamingPowerScheme\s+-SchemeGuid'
    }
}

Describe 'Windows Update stays gone' {

    It 'disables all three Windows Update services in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
            $code | Should -Match ([regex]::Escape($svc))
        }
        $code | Should -Not -Match "Services\\WaaSMedicSVC'"
    }

    It 'never deletes a Windows Update service key in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        # Deleting the key looks final but is not: the servicing stack restores it,
        # and the restore is what triggers the double restart.
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match "Remove-Item[^\r\n]*Services\\wuauserv"
        $code | Should -Not -Match "Remove-RegistryKey[^\r\n]*Services\\wuauserv"
        $code | Should -Not -Match "Remove-RegistryKey[^\r\n]*Services\\UsoSvc"
    }

    It 'removes the WaaSMedic task folder in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        # The task array is written as "$tasksPath\Microsoft\Windows\WaaSMedic", so
        # match on the tail of that literal rather than on 'Tasks\' - the variable
        # name is lowercase 'tasksPath' and a capitalised prefix never matches.
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Match 'Windows\\WaaSMedic"'
    }

    It 'does not redirect Windows Update at a local WSUS in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        # WUServer=localhost is what made the Settings page throw instead of
        # reporting a managed state.
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match "'WUServer'"
        $code | Should -Not -Match "'WUStatusServer'"
        $code | Should -Not -Match "'UpdateServiceUrlAlternate'"
        $code | Should -Not -Match "'UseWUServer'"
    }

    It 'keeps the access policies that close the door instead' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Match 'DoNotConnectToWindowsUpdateInternetLocations'
        $code | Should -Match 'DisableWindowsUpdateAccess'
        $code | Should -Match 'NoAutoUpdate'
    }
}

Describe 'Idle memory footprint' {

    It 'uses the default NTFS memory usage in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
        @{ Name = 'Standard' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match "NtfsMemoryUsage'\s+'REG_DWORD'\s+'2'"
        $code | Should -Match "NtfsMemoryUsage'\s+'REG_DWORD'\s+'1'"
    }

    It 'does not pin the kernel executive in RAM in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
        @{ Name = 'Standard' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match "DisablePagingExecutive'\s+'REG_DWORD'\s+'1'"
    }
}
