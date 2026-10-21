<#
.SYNOPSIS
    Regression tests for the WinRE contract that decides whether the finished ISO
    can be installed at all.

.DESCRIPTION
    Windows Setup stages SafeOS out of the install image it is applying. A build
    that ships no winre.wim gives SetupHost nothing to stage, and the install dies
    at ~10% - which the user sees as "installation failed after 10%".

    This project tried two ways to make a WinRE-less ISO work:

      1. delete winre.wim and leave the stock ReAgent.xml - Setup chased a file
         that was not on the media;
      2. delete winre.wim and zero ReAgent.xml - still failed at 10% on real
         hardware.

    So WinRE is now preserved unconditionally: no switch, no workflow input, no
    removal code. These tests pin that - the failure mode used to be configurable,
    and a configurable failure mode is one dispatch away from coming back.

    Run: Invoke-Pester ./tests/Test-WinRERecovery.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    $builderPaths = @{
        Core = Join-Path $repoRoot 'scripts/tiny11coremaker-headless.ps1'
        Nano = Join-Path $repoRoot 'scripts/nano11builder-headless.ps1'
    }

    $workflowPaths = @{
        'build-tiny11-core-gaming.yml' = Join-Path $repoRoot '.github/workflows/build-tiny11-core-gaming.yml'
        'build-tiny11-core.yml'        = Join-Path $repoRoot '.github/workflows/build-tiny11-core.yml'
        'build-nano11.yml'             = Join-Path $repoRoot '.github/workflows/build-nano11.yml'
    }

    $builderSource = @{}
    foreach ($k in $builderPaths.Keys) {
        $builderSource[$k] = Get-Content -LiteralPath $builderPaths[$k] -Raw
    }

    $workflowSource = @{}
    foreach ($k in $workflowPaths.Keys) {
        $workflowSource[$k] = Get-Content -LiteralPath $workflowPaths[$k] -Raw
    }

    function Get-FunctionBody {
        param(
            [Parameter(Mandatory = $true)][string]$Source,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $m = [regex]::Match($Source, "(?s)function\s+$([regex]::Escape($Name))\s*\{.*?\n\}")
        if ($m.Success) { $m.Value } else { '' }
    }

    # Assertions below look at executable code only. Comments in this codebase quote
    # the very patterns being asserted on (e.g. the note in the param block saying the
    # -PreserveWinRE switch is gone), which would make a naive match report a violation
    # that does not exist.
    function Get-FunctionCode {
        param(
            [Parameter(Mandatory = $true)][string]$Source,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $body = Get-FunctionBody -Source $Source -Name $Name
        ($body -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    # Same idea for a whole script: strip full-line comments before asserting that a
    # symbol is absent, so explanatory prose cannot fail the test.
    function Get-ExecutableCode {
        param([Parameter(Mandatory = $true)][string]$Source)
        ($Source -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
}

Describe 'WinRE is preserved unconditionally' {

    It 'has no PreserveWinRE switch in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        # A switch is a toggle by another name: it keeps the broken build reachable.
        $builderSource[$Name] | Should -Not -Match '\[switch\]\$PreserveWinRE'
        $builderSource[$Name] | Should -Not -Match '\$PreserveWinRE'
    }

    It 'has no WinRE removal code left in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        $code = Get-ExecutableCode -Source $builderSource[$Name]
        $code | Should -Not -Match 'function\s+Remove-WinRE'
        $code | Should -Not -Match 'function\s+Patch-ReAgentXml'
        $code | Should -Not -Match 'Write-CleanReAgentXml'
        $code | Should -Not -Match 'CleanReAgentXml'
    }

    It 'refuses to build an image that has no winre.wim in the <Name> builder' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        # The check has to run before the image is exported. Catching it after the
        # export would waste the build; catching it never is how a broken ISO ships.
        $builderSource[$Name] | Should -Match 'winre\.wim is missing from the mounted image'
        $builderSource[$Name] | Should -Match 'WinRE preserved:'
    }

    It 'parses without syntax errors: <Name>' -ForEach @(
        @{ Name = 'Core' }
        @{ Name = 'Nano' }
    ) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $builderPaths[$Name], [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'Core flow verifies the recovery state while the image is still a WIM' {

    It 'keeps a guard that requires winre.wim and rejects a truncated one' {
        $code = Get-FunctionCode -Source $builderSource['Core'] -Name 'Assert-InstallImageRecoveryConsistent'
        $code | Should -Not -BeNullOrEmpty
        $code | Should -Match 'install image has no winre\.wim'
        $code | Should -Match '\-lt 100'
    }

    It 'no longer accepts a WinRE-less image as valid' {
        # The old guard had a branch that passed when winre.wim was absent and
        # ReAgent.xml was zeroed. That is exactly the configuration that failed at 10%.
        $code = Get-FunctionCode -Source $builderSource['Core'] -Name 'Assert-InstallImageRecoveryConsistent'
        $code | Should -Not -Match 'winre\.wim removed and ReAgent\.xml zeroed'
        $code | Should -Not -Match 'has neither winre\.wim nor ReAgent\.xml'
    }

    It 'mounts index 1, because the export re-indexes to a single image' {
        # Mounting with the user's index (say 6) would fail with "index out of range"
        # and look like a corrupt image.
        $code = Get-FunctionCode -Source $builderSource['Core'] -Name 'Assert-InstallImageRecoveryConsistent'
        $code | Should -Match '/Index:1'
    }

    It 'runs the guard after Dismount-AndExport and before Convert-ToESD' {
        # Convert-ToESD deletes install.wim. DISM cannot mount the solid ESD that
        # replaces it, so a guard that only ran from Create-TinyISO would be handed
        # install.esd and abort every build with a misleading "the image is corrupt".
        #
        # LastIndexOf on purpose: these names each appear twice, once as the function
        # definition and once as the call in the main flow at the end of the script.
        $dismountCall = $builderSource['Core'].LastIndexOf('Dismount-AndExport')
        $assertCall = $builderSource['Core'].LastIndexOf('Assert-InstallImageRecoveryConsistent -ImagePath $wimFilePath')
        $esdCall = $builderSource['Core'].LastIndexOf('Convert-ToESD')

        $dismountCall | Should -BeGreaterThan -1
        $assertCall | Should -BeGreaterThan $dismountCall
        $esdCall | Should -BeGreaterThan $assertCall
    }

    It 'never mounts an image from Create-TinyISO' {
        $code = Get-FunctionCode -Source $builderSource['Core'] -Name 'Create-TinyISO'
        $code | Should -Not -Match 'Assert-InstallImageRecoveryConsistent'
    }
}

Describe 'No workflow offers a WinRE toggle' {

    It 'has no preserve_winre dispatch input: <Name>' -ForEach @(
        @{ Name = 'build-tiny11-core-gaming.yml' }
        @{ Name = 'build-tiny11-core.yml' }
        @{ Name = 'build-nano11.yml' }
    ) {
        # Line scan rather than one regex over the whole workflow: a nested-quantifier
        # pattern such as (?:\r?\n.*)*? backtracks catastrophically on a 54KB YAML file
        # and takes the whole Pester run down with it.
        $lines = $workflowSource[$Name] -split "`r?`n"
        @($lines | Where-Object { $_ -match '^\s+preserve_winre:\s*$' }).Count | Should -Be 0
    }

    It 'never passes a WinRE flag to a builder: <Name>' -ForEach @(
        @{ Name = 'build-tiny11-core-gaming.yml' }
        @{ Name = 'build-tiny11-core.yml' }
        @{ Name = 'build-nano11.yml' }
    ) {
        # The builders no longer accept the parameter, so a leftover flag would fail
        # the build with "A parameter cannot be found".
        $workflowSource[$Name] | Should -Not -Match 'PreserveWinRE'
        $workflowSource[$Name] | Should -Not -Match 'inputs\.preserve_winre'
    }

    It 'reports WinRE as preserved, never as removed: <Name>' -ForEach @(
        @{ Name = 'build-tiny11-core-gaming.yml' }
        @{ Name = 'build-tiny11-core.yml' }
        @{ Name = 'build-nano11.yml' }
    ) {
        $workflowSource[$Name] | Should -Not -Match 'Removed \(stub\)'
        $workflowSource[$Name] | Should -Not -Match 'No WinRE \(Recovery\)'
        $workflowSource[$Name] | Should -Match 'WinRE'
    }
}
