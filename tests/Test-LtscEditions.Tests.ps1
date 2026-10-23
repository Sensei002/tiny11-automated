<#
.SYNOPSIS
    Pester tests for the LTSC build variants.

.DESCRIPTION
    Covers the three pieces that make an LTSC build safe, because each one fails
    silently if it regresses:

      1. The catalogue - the index each edition sits at on Microsoft's media, and
         the fact that Enterprise and IoT Enterprise never resolve to each other.
      2. The builders - the -ExpectedEdition path that re-checks the image name
         after the ISO is mounted, instead of trusting a number.
      3. The workflows - that the index is derived rather than typed, that the
         catalogue is the source of it, and that the ISO is verified before the
         builder runs.

    No ISO is mounted and nothing is built: these are static and behavioural
    checks that run anywhere Pester is available.

.EXAMPLE
    Invoke-Pester -Path tests/Test-LtscEditions.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $scriptsDir = Join-Path $repoRoot 'scripts'
    $workflowsDir = Join-Path (Join-Path $repoRoot '.github') 'workflows'

    $catalogPath = Join-Path $scriptsDir 'ltsc-edition-catalog.ps1'
    $standardWorkflowPath = Join-Path $workflowsDir 'build-tiny11-ltsc.yml'
    $coreWorkflowPath = Join-Path $workflowsDir 'build-tiny11-core-ltsc.yml'

    . $catalogPath

    $catalog = Get-LTSCEditionCatalog
    $standardRaw = Get-Content -LiteralPath $standardWorkflowPath -Raw
    $coreRaw = Get-Content -LiteralPath $coreWorkflowPath -Raw

    # Pull a function's real source out of a builder and turn it into a callable
    # scriptblock, so the test exercises the shipped implementation rather than a
    # copy of it. The builders cannot be dot-sourced (they run a build on import).
    function Get-FunctionFromScript {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Name
        )

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true)

        if (-not $definition) { return $null }
        return [scriptblock]::Create($definition.Extent.Text)
    }
}

Describe 'LTSC catalogue' {

    It 'exists' {
        Test-Path -LiteralPath $catalogPath | Should -BeTrue
    }

    It 'lists exactly the five editions Microsoft ships' {
        $catalog.Count | Should -Be 5
        $catalog.Name | Should -Contain 'Windows 11 Enterprise LTSC'
        $catalog.Name | Should -Contain 'Windows 11 IoT Enterprise LTSC'
        $catalog.Name | Should -Contain 'Windows 11 IoT Enterprise Subscription LTSC'
        $catalog.Name | Should -Contain 'Windows 10 Enterprise LTSC'
        $catalog.Name | Should -Contain 'Windows 10 IoT Enterprise LTSC'
    }

    It 'puts the Windows 11 LTSC 2024 images at 1, 2 and 3' {
        $win11 = $catalog | Where-Object { $_.Family -eq 'Windows 11' }
        $win11.Count | Should -Be 3
        ($win11 | Sort-Object Index).Index | Should -Be @(1, 2, 3)
        ($win11 | Where-Object Index -EQ 1).Name | Should -Be 'Windows 11 Enterprise LTSC'
        ($win11 | Where-Object Index -EQ 2).Name | Should -Be 'Windows 11 IoT Enterprise LTSC'
        ($win11 | Where-Object Index -EQ 3).Name | Should -Be 'Windows 11 IoT Enterprise Subscription LTSC'
    }

    It 'puts the Windows 10 LTSC 2021 images at 1 and 2' {
        $win10 = $catalog | Where-Object { $_.Family -eq 'Windows 10' }
        $win10.Count | Should -Be 2
        ($win10 | Sort-Object Index).Index | Should -Be @(1, 2)
        ($win10 | Where-Object Index -EQ 1).Name | Should -Be 'Windows 10 Enterprise LTSC'
        ($win10 | Where-Object Index -EQ 2).Name | Should -Be 'Windows 10 IoT Enterprise LTSC'
    }

    It 'gives every edition a unique release tag suffix' {
        ($catalog.TagSuffix | Sort-Object -Unique).Count | Should -Be $catalog.Count
    }

    It 'gives every edition a unique file-name slug within its family' {
        $pairs = $catalog | ForEach-Object { "$($_.Family)|$($_.Slug)" }
        ($pairs | Sort-Object -Unique).Count | Should -Be $catalog.Count
    }

    It 'names the media release and build for each family' {
        ($catalog | Where-Object Family -EQ 'Windows 11').Release | Sort-Object -Unique | Should -Be '2024'
        ($catalog | Where-Object Family -EQ 'Windows 11').Build | Sort-Object -Unique | Should -Be '26100'
        ($catalog | Where-Object Family -EQ 'Windows 10').Release | Sort-Object -Unique | Should -Be '2021'
        ($catalog | Where-Object Family -EQ 'Windows 10').Build | Sort-Object -Unique | Should -Be '19044'
    }
}

Describe 'Edition name matching' {

    It 'matches the same SKU spelled with or without a release year' {
        Test-LTSCEditionName -Expected 'Windows 10 Enterprise LTSC' -Actual 'Windows 10 Enterprise LTSC 2021' | Should -BeTrue
        Test-LTSCEditionName -Expected 'Windows 10 IoT Enterprise LTSC' -Actual 'Windows 10 IoT Enterprise LTSC 2021' | Should -BeTrue
    }

    It 'never confuses Enterprise with IoT Enterprise' {
        # 'Enterprise LTSC' is a substring of 'IoT Enterprise LTSC', so a lazy
        # implementation would pass this and install the wrong image.
        Test-LTSCEditionName -Expected 'Windows 11 Enterprise LTSC' -Actual 'Windows 11 IoT Enterprise LTSC' | Should -BeFalse
        Test-LTSCEditionName -Expected 'Windows 10 Enterprise LTSC' -Actual 'Windows 10 IoT Enterprise LTSC 2021' | Should -BeFalse
    }

    It 'never confuses IoT Enterprise with IoT Enterprise Subscription' {
        Test-LTSCEditionName -Expected 'Windows 11 IoT Enterprise LTSC' -Actual 'Windows 11 IoT Enterprise Subscription LTSC' | Should -BeFalse
    }

    It 'rejects an image from the other Windows family' {
        Test-LTSCEditionName -Expected 'Windows 11 Enterprise LTSC' -Actual 'Windows 10 Enterprise LTSC 2021' | Should -BeFalse
        Test-LTSCEditionName -Expected 'Windows 10 Enterprise LTSC' -Actual 'Windows 11 Enterprise LTSC' | Should -BeFalse
    }

    It 'rejects a consumer edition' {
        Test-LTSCEditionName -Expected 'Windows 11 Enterprise LTSC' -Actual 'Windows 11 Pro' | Should -BeFalse
    }

    It 'rejects empty input instead of matching everything' {
        Test-LTSCEditionName -Expected 'Windows 11 Enterprise LTSC' -Actual '' | Should -BeFalse
    }
}

Describe 'Catalogue resolution' {

    It 'resolves every catalogue name to itself' -ForEach @(
        @{ Name = 'Windows 11 Enterprise LTSC' }
        @{ Name = 'Windows 11 IoT Enterprise LTSC' }
        @{ Name = 'Windows 11 IoT Enterprise Subscription LTSC' }
        @{ Name = 'Windows 10 Enterprise LTSC' }
        @{ Name = 'Windows 10 IoT Enterprise LTSC' }
    ) {
        (Resolve-LTSCEdition -Name $Name).Name | Should -Be $Name
    }

    It 'resolves a year-suffixed spelling to the right family' {
        (Resolve-LTSCEdition -Name 'Windows 10 Enterprise LTSC 2021').Family | Should -Be 'Windows 10'
        (Resolve-LTSCEdition -Name 'Windows 10 Enterprise LTSC 2021').TagSuffix | Should -Be 'ltsc-win10-enterprise'
        (Resolve-LTSCEdition -Name 'Windows 11 Enterprise LTSC').TagSuffix | Should -Be 'ltsc-win11-enterprise'
    }

    It 'throws on an unknown edition and lists the valid ones' {
        { Resolve-LTSCEdition -Name 'Windows 11 LTSC Nope' } | Should -Throw '*Windows 11 IoT Enterprise LTSC*'
    }
}

Describe 'Builder -ExpectedEdition support' {

    It 'declares -ExpectedEdition in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match '(?m)^\s*\[string\]\$ExpectedEdition'
    }

    It 'locates the image by name when -ExpectedEdition is supplied in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match 'if \(\$ExpectedEdition\)'
        $source | Should -Match 'Test-EditionNameMatch -Expected \$ExpectedEdition -Actual \$_\$?\.?ImageName'
    }

    It 'fails the build when the requested edition is missing in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        # Single-quoted so PowerShell leaves the regex escapes alone: \$ is a
        # literal dollar, which is what the builder's message actually contains.
        $source | Should -Match 'throw "Expected edition ''\$ExpectedEdition'' not found'
    }

    It 'behaves the same as the catalogue matcher in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
    ) {
        $definition = Get-FunctionFromScript -Path (Join-Path $repoRoot $Path) -Name 'Test-EditionNameMatch'
        $definition | Should -Not -BeNullOrEmpty

        # Dot-source the extracted definition so the shipped implementation is what
        # runs, not a copy of it kept in this test.
        . $definition

        $cases = @(
            @{ Expected = 'Windows 11 Enterprise LTSC'; Actual = 'Windows 11 Enterprise LTSC'; Want = $true }
            @{ Expected = 'Windows 11 Enterprise LTSC'; Actual = 'Windows 11 IoT Enterprise LTSC'; Want = $false }
            @{ Expected = 'Windows 11 IoT Enterprise LTSC'; Actual = 'Windows 11 IoT Enterprise Subscription LTSC'; Want = $false }
            @{ Expected = 'Windows 10 Enterprise LTSC'; Actual = 'Windows 10 Enterprise LTSC 2021'; Want = $true }
            @{ Expected = 'Windows 10 Enterprise LTSC'; Actual = 'Windows 11 Enterprise LTSC'; Want = $false }
        )

        foreach ($case in $cases) {
            Test-EditionNameMatch -Expected $case.Expected -Actual $case.Actual |
                Should -Be $case.Want -Because "$($case.Expected) vs $($case.Actual)"
        }
    }
}

Describe 'LTSC workflows' {

    It 'exists as <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        Test-Path -LiteralPath (Join-Path $workflowsDir $File) | Should -BeTrue
    }

    It 'is named <Expected> in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml'; Expected = 'Build and Release Tiny11 LTSC' }
        @{ File = 'build-tiny11-core-ltsc.yml'; Expected = 'Build and Release Tiny11 Core LTSC' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match "(?m)^name: $([regex]::Escape($Expected))\s*$"
    }

    It 'offers exactly the catalogue editions, in catalogue order, in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw

        $positions = @()
        foreach ($edition in $catalog) {
            $needle = "- '$($edition.Name)'"
            $index = $raw.IndexOf($needle)
            $index | Should -BeGreaterThan -1 -Because "$($edition.Name) should be a choice option"
            $positions += $index
        }

        # Order matters for readability only, but a reordered dropdown is the first
        # sign that someone hand-edited the list away from the catalogue.
        $sorted = $positions | Sort-Object
        $positions | Should -Be $sorted
    }

    It 'takes a pasted ISO URL and no index in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw

        $raw | Should -Match '(?m)^\s{6}windows_iso_url:'
        # The whole point of the LTSC menu: the index is derived, never typed.
        $raw | Should -Not -Match '(?m)^\s{6}image_index:'
    }

    It 'derives the index from the catalogue in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match 'ltsc-edition-catalog\.ps1'
        $raw | Should -Match 'Resolve-LTSCEdition -Name'
        $raw | Should -Match 'LTSC_IMAGE_INDEX'
    }

    It 'verifies the ISO before the builder runs in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml'; Builder = 'tiny11maker-headless.ps1' }
        @{ File = 'build-tiny11-core-ltsc.yml'; Builder = 'tiny11coremaker-headless.ps1' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw

        $verifyAt = $raw.IndexOf('Verify the LTSC edition is on the ISO')
        $builderAt = $raw.IndexOf($Builder)
        $verifyAt | Should -BeGreaterThan -1
        $builderAt | Should -BeGreaterThan -1
        $verifyAt | Should -BeLessThan $builderAt
    }

    It 'passes -ExpectedEdition to the builder in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml'; Builder = 'tiny11maker-headless.ps1' }
        @{ File = 'build-tiny11-core-ltsc.yml'; Builder = 'tiny11coremaker-headless.ps1' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match 'ExpectedEdition = \$env:LTSC_EDITION_NAME'
        $raw | Should -Match ([regex]::Escape($Builder))
    }

    It 'publishes under a tag that cannot collide with the non-LTSC build in <File>' -ForEach @(
        @{ File = 'build-tiny11-ltsc.yml'; Prefix = 'Tiny11-LTSC' }
        @{ File = 'build-tiny11-core-ltsc.yml'; Prefix = 'Tiny11Core-LTSC' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match ([regex]::Escape("`$isoName = `"$Prefix-"))
        $raw | Should -Match 'LTSC_TAG_SUFFIX'
    }
}
