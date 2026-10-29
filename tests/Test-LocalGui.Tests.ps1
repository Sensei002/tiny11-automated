<#
.SYNOPSIS
    Pester tests for the local GUI builder.

.DESCRIPTION
    The GUI is a thin shell, so almost everything worth testing is in local/lib.ps1:
    the profile schema, the mapping from a form onto a builder's parameters, and the
    two generated scripts. All three can drift silently - a renamed builder parameter
    or a renamed workflow input produces no error until someone runs a build an hour
    long - so they are asserted against the real files rather than against fixtures.

    The workflow side (input keys existing in the YAML) is checked in
    tests/validate_workflow.py, because Pester cannot parse YAML.

.EXAMPLE
    Invoke-Pester -Path tests/Test-LocalGui.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $localDir = Join-Path $repoRoot 'local'

    . (Join-Path $localDir 'lib.ps1')

    $profilePath = Join-Path $repoRoot 'config\local_build_profiles.json'
    $profile = Get-LocalBuildProfile -Path $profilePath

    function Get-BuilderParameterNames {
        param([Parameter(Mandatory = $true)][string]$Path)

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if (-not $ast.ParamBlock) { return @() }

        return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    function Get-BuilderOutputIso {
        param([Parameter(Mandatory = $true)][string]$Path)

        $text = Get-Content -LiteralPath $Path -Raw
        if ($text -match '\$outputISO\s*=\s*"\$PSScriptRoot\\([^"]+)"') { return $Matches[1] }
        return $null
    }

    # Keys the GUI chrome supplies; they are not variant inputs.
    $chromeKeys = @('isoDrive', 'scratchDrive', 'updateToLatest', 'requireLatestUpdate')
}

Describe 'Profile schema' {

    It 'declares all six build variants' {
        @($profile.variants).Count | Should -Be 6
    }

    It 'uses unique variant ids' {
        $ids = @($profile.variants | ForEach-Object { $_.id })
        $ids.Count | Should -Be (@($ids | Select-Object -Unique)).Count
    }

    It 'points every variant at a builder that exists' {
        $missing = @()
        foreach ($variant in $profile.variants) {
            $path = Join-Path $repoRoot ($variant.builder -replace '/', '\')
            if (-not (Test-Path -LiteralPath $path)) { $missing += "$($variant.id) -> $($variant.builder)" }
        }
        $missing | Should -BeNullOrEmpty -Because "every variant must drive a real builder: $($missing -join '; ')"
    }

    It 'points every variant at a workflow that exists' {
        $missing = @()
        foreach ($variant in $profile.variants) {
            $path = Join-Path $repoRoot (Join-Path '.github\workflows' $variant.workflow)
            if (-not (Test-Path -LiteralPath $path)) { $missing += "$($variant.id) -> $($variant.workflow)" }
        }
        $missing | Should -BeNullOrEmpty -Because "every variant mirrors a CI workflow: $($missing -join '; ')"
    }

    It 'names the ISO the builder actually writes' {
        $bad = @()
        foreach ($variant in $profile.variants) {
            $builderPath = Join-Path $repoRoot ($variant.builder -replace '/', '\')
            $actual = Get-BuilderOutputIso -Path $builderPath
            if ($actual -ne $variant.outputIso) {
                $bad += "$($variant.id): profile says '$($variant.outputIso)', builder writes '$actual'"
            }
        }
        $bad | Should -BeNullOrEmpty -Because "a wrong outputIso means the export step looks in the wrong place: $($bad -join '; ')"
    }
}

Describe 'Parameter mapping' {

    It 'only maps onto parameters the builder really declares' {
        $bad = @()
        foreach ($variant in $profile.variants) {
            $builderPath = Join-Path $repoRoot ($variant.builder -replace '/', '\')
            $declared = Get-BuilderParameterNames -Path $builderPath

            foreach ($entry in $variant.paramMap.PSObject.Properties) {
                if ($declared -notcontains $entry.Name) {
                    $bad += "$($variant.id): -$($entry.Name) is not a parameter of $($variant.builder)"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "a renamed builder parameter would only fail an hour into a build: $($bad -join '; ')"
    }

    It 'maps every value from an input the variant declares' {
        $bad = @()
        foreach ($variant in $profile.variants) {
            $inputs = @($variant.inputs | ForEach-Object { $_.key })
            # Values the variant computes rather than asks for, e.g. the LTSC image index.
            $derived = @()
            if ($variant.PSObject.Properties['derived'] -and $variant.derived) {
                $derived = @($variant.derived)
            }

            foreach ($entry in $variant.paramMap.PSObject.Properties) {
                $source = ([string]$entry.Value).Split(':')[0]
                if ($source -eq '@static') { continue }
                if ($chromeKeys -contains $source) { continue }
                if ($derived -contains $source) { continue }
                if ($inputs -notcontains $source) {
                    $bad += "$($variant.id): -$($entry.Name) reads '$source', which is neither an input nor declared as derived"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "a typo here surfaces as a missing parameter at runtime: $($bad -join '; ')"
    }

    It 'declares a derived value as derived, not as a hidden input' {
        # LTSC takes its image index from the catalogue; if that ever moves into the
        # form, this test should fail so the schema and the GUI are updated together.
        foreach ($variant in $profile.variants) {
            $inputs = @($variant.inputs | ForEach-Object { $_.key })
            $derived = @()
            if ($variant.PSObject.Properties['derived'] -and $variant.derived) {
                $derived = @($variant.derived)
            }

            foreach ($key in $derived) {
                $inputs | Should -Not -Contain $key -Because "$($variant.id) cannot both derive and ask for '$key'"
            }
        }
    }

    It 'gives every variant an ISO, INDEX and SCRATCH mapping' {
        foreach ($variant in $profile.variants) {
            $map = $variant.paramMap
            $map.PSObject.Properties['ISO']   | Should -Not -BeNullOrEmpty -Because "$($variant.id) must pass -ISO"
            $map.PSObject.Properties['INDEX'] | Should -Not -BeNullOrEmpty -Because "$($variant.id) must pass -INDEX"
            $map.PSObject.Properties['SCRATCH'] | Should -Not -BeNullOrEmpty -Because "$($variant.id) must pass -SCRATCH"
        }
    }
}

Describe 'Gaming profile groups' {

    BeforeAll {
        $gamingProfile = Get-Content -LiteralPath (Join-Path $repoRoot 'config\gaming_profile.json') -Raw | ConvertFrom-Json
    }

    It 'matches the groups declared in gaming_profile.json' {
        $declared = @($gamingProfile.defaultGroups.PSObject.Properties.Name | Sort-Object)
        $gui = @($profile.gamingGroups | ForEach-Object { $_.value } | Sort-Object)
        $gui | Should -Be $declared
    }

    It 'keeps the same default for every group' {
        $bad = @()
        foreach ($group in $profile.gamingGroups) {
            $expected = [bool]$gamingProfile.defaultGroups.($group.value)
            if ([bool]$group.default -ne $expected) {
                $bad += "$($group.value): gui=$($group.default) profile=$expected"
            }
        }
        $bad | Should -BeNullOrEmpty -Because "a GUI default that disagrees with the profile is a silent behaviour change: $($bad -join '; ')"
    }
}

Describe 'Argument assembly' {

    BeforeAll {
        $gaming = Get-BuildVariant -Profile $profile -Id 'core-gaming'

        $baseContext = @{
            isoDrive            = ''
            image_index         = '6'
            scratchDrive        = 'D'
            skip_cleanup        = $false
            enable_dotnet35     = $true
            remove_defender     = $false
            account_setup       = 'auto-admin'
            hags                = 'on'
            ltsc_edition        = ''
            gaming_groups       = @{ atlas_power_scheme = $true }
            pause_windows_update = $true
            updateToLatest      = $true
            requireLatestUpdate = $false
        }
    }

    It 'omits a switch that is off' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args.Contains('SkipCleanup') | Should -BeFalse
        $args.Contains('RequireLatestUpdate') | Should -BeFalse
    }

    It 'includes a switch that is on' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args['ENABLE_DOTNET35'] | Should -BeTrue
        $args['UpdateToLatest'] | Should -BeTrue
    }

    It 'casts the image index to an integer' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args['INDEX'] | Should -BeOfType [int]
        $args['INDEX'] | Should -Be 6
    }

    It 'sets a switch the variant implies' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args['GamingProfile'] | Should -BeTrue
    }

    It 'passes the gaming groups through as a hashtable' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args['GamingGroups'] | Should -BeOfType [hashtable]
    }

    It 'omits a blank string rather than passing an empty parameter' {
        $args = New-BuilderArguments -Variant $gaming -Context $baseContext
        $args.Contains('ISO') | Should -BeFalse
    }

    It 'turns the pause checkbox into a builder mode' {
        # The form asks a yes/no question; the builder takes paused|live. Both
        # directions are asserted because a mapping that only ever yields one value
        # would look correct in every other test here.
        $on = New-BuilderArguments -Variant $gaming -Context $baseContext
        $on['WindowsUpdateMode'] | Should -Be 'paused'

        $offContext = $baseContext.Clone()
        $offContext['pause_windows_update'] = $false
        $off = New-BuilderArguments -Variant $gaming -Context $offContext
        $off['WindowsUpdateMode'] | Should -Be 'live'
    }

    It 'refuses a context that is missing a mapped value' {
        $broken = @{ isoDrive = '' }
        { New-BuilderArguments -Variant $gaming -Context $broken } |
            Should -Throw '*which the context does not define*'
    }
}

Describe 'Update modes' {

    It 'maps <Mode> to the right switch pair' -ForEach @(
        @{ Mode = 'required';    Update = $true;  Require = $true }
        @{ Mode = 'best-effort'; Update = $true;  Require = $false }
        @{ Mode = 'off';         Update = $false; Require = $false }
    ) {
        $flags = Get-UpdateModeFlags -Profile $profile -Mode $Mode
        $flags.UpdateToLatest | Should -Be $Update
        $flags.RequireLatestUpdate | Should -Be $Require
    }

    It 'falls back to best effort for an unknown mode instead of refusing to start' {
        $flags = Get-UpdateModeFlags -Profile $profile -Mode 'nonsense'
        $flags.UpdateToLatest | Should -BeTrue
        $flags.RequireLatestUpdate | Should -BeFalse
    }
}

Describe 'Generated scripts' {

    BeforeAll {
        $variant = Get-BuildVariant -Profile $profile -Id 'core'
        $context = @{
            isoDrive = ''; image_index = '6'; scratchDrive = 'D'; skip_cleanup = $false
            enable_dotnet35 = $false; remove_defender = $false; account_setup = 'auto-admin'
            hags = 'on'; ltsc_edition = ''; gaming_groups = @{}
            pause_windows_update = $true
            updateToLatest = $true; requireLatestUpdate = $true
        }
        $arguments = New-BuilderArguments -Variant $variant -Context $context

        $launcherPath = Join-Path $TestDrive 'params.ps1'
        $pipelinePath = Join-Path $TestDrive 'pipeline.ps1'

        $builderPath = Join-Path $repoRoot 'scripts\tiny11coremaker-headless.ps1'
        ConvertTo-LauncherScript -Variant $variant -Arguments $arguments `
            -BuilderPath $builderPath -ScriptPath $launcherPath | Out-Null

        $plan = @{
            RepoRoot      = $repoRoot
            Source        = 'download'
            ScratchRoot   = 'D:\'
            OutputDir     = 'C:\out'
            BuilderPath   = $builderPath
            BuiltIsoPath  = Join-Path $repoRoot 'scripts\tiny11-core.iso'
            SourceIsoPath = ''
            UpdateMode    = 'required'
            Language      = 'English (United States)'
            MountedDrive  = ''
            LauncherPath  = $launcherPath
            Arguments     = $arguments
        }
        ConvertTo-PipelineScript -Variant $variant -Plan $plan -ScriptPath $pipelinePath | Out-Null

        $launcherText = Get-Content -LiteralPath $launcherPath -Raw
        $pipelineText = Get-Content -LiteralPath $pipelinePath -Raw
    }

    It 'feeds -ISO from the environment, never from a baked-in value' {
        $launcherText | Should -Match 'ISO\s*=\s*\$env:TINY11_ISO_DRIVE'
    }

    It 'runs the builder in its own process' {
        # All three builders end in a bare `exit`, which would terminate the
        # orchestrator and skip both the export and the unmount.
        $pipelineText | Should -Match '-File'
        $pipelineText | Should -Not -Match '&\s+''.*tiny11coremaker-headless\.ps1'''
    }

    It 'sets and clears the drive variable around the build' {
        $pipelineText | Should -Match '\$env:TINY11_ISO_DRIVE = \$prepared\.DriveLetter'
        $pipelineText | Should -Match 'Remove-Item Env:TINY11_ISO_DRIVE'
    }

    It 'exports only after a successful build' {
        $pipelineText | Should -Match 'if \(\$exitCode -eq 0\)'
        $pipelineText | Should -Match 'Export-BuildIso'
    }

    It 'detaches the mounted image on every path' {
        $pipelineText | Should -Match 'finally\s*\{'
        $pipelineText | Should -Match 'Invoke-IsoRelease'
    }

    It 'writes <Name> that parses' -ForEach @(
        @{ Name = 'the launcher' }
        @{ Name = 'the pipeline' }
    ) {
        $path = if ($Name -eq 'the launcher') { $launcherPath } else { $pipelinePath }
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Literal formatting' {

    It 'escapes a quote in a path' {
        Format-PsLiteral -Value "C:\it's here" | Should -Be "'C:\it''s here'"
    }

    It 'renders booleans as PowerShell literals' {
        Format-PsLiteral -Value $true | Should -Be '$true'
        Format-PsLiteral -Value $false | Should -Be '$false'
    }

    It 'leaves an integer unquoted' {
        Format-PsLiteral -Value 6 | Should -Be '6'
    }
}

Describe 'Window markup' {

    BeforeAll {
        $guiText = Get-Content -LiteralPath (Join-Path $localDir 'gui.ps1') -Raw

        $start = $guiText.IndexOf("`$xaml = @'")
        $start = $guiText.IndexOf("`n", $start) + 1
        $end = $guiText.IndexOf("`n'@", $start)
        $script:xaml = $guiText.Substring($start, $end - $start)
    }

    It 'is well-formed XML' {
        { [xml]$script:xaml } | Should -Not -Throw
    }

    It 'defines every control the code looks up by name' {
        # A renamed control fails at startup with a null reference deep in the
        # handler wiring, which reads as "the app does not open" and nothing else.
        $guiText = Get-Content -LiteralPath (Join-Path $localDir 'gui.ps1') -Raw

        $block = [regex]::Match($guiText, '\$controls = @\{\}([\s\S]*?)\$controls\[', 'Singleline')
        $block.Success | Should -BeTrue

        $names = [regex]::Matches($block.Groups[1].Value, "'([A-Za-z]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique

        $names.Count | Should -BeGreaterThan 5

        $missing = @()
        foreach ($name in $names) {
            if ($script:xaml -notmatch ('x:Name="{0}"' -f [regex]::Escape($name))) { $missing += $name }
        }
        $missing | Should -BeNullOrEmpty -Because "the code looks these up by name: $($missing -join ', ')"
    }
}

Describe 'Installer helpers' {
    BeforeAll {
        # The installer sits at the repo root so the release asset can be published
        # as tiny11.ps1, which is the name the documented one-liner asks for.
        . (Join-Path $repoRoot 'tiny11.ps1')
    }

    It 'builds a codeload URL for a ref' {
        Get-ArchiveUrl -Owner 'Sensei002' -Repo 'tiny11-automated' -Ref 'v1.2.3' |
            Should -Be 'https://codeload.github.com/Sensei002/tiny11-automated/zip/v1.2.3'
    }

    It 'defaults the ref to main' {
        Get-ArchiveUrl -Owner 'a' -Repo 'b' | Should -BeLike '*/zip/main'
    }

    It 'accepts a matching hash' {
        $file = Join-Path $TestDrive 'payload.bin'
        Set-Content -LiteralPath $file -Value 'hello' -NoNewline -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        { Assert-ArchiveHash -Path $file -Expected $hash } | Should -Not -Throw
    }

    It 'rejects a mismatched hash' {
        $file = Join-Path $TestDrive 'payload2.bin'
        Set-Content -LiteralPath $file -Value 'hello' -NoNewline -Encoding ASCII
        { Assert-ArchiveHash -Path $file -Expected ('0' * 64) } | Should -Throw '*hash mismatch*'
    }

    It 'tolerates a missing hash but says so' {
        $file = Join-Path $TestDrive 'payload3.bin'
        Set-Content -LiteralPath $file -Value 'hello' -NoNewline -Encoding ASCII
        # Informational output goes to the host so the function's return value stays
        # clean, hence the information-stream redirect.
        $output = Assert-ArchiveHash -Path $file -Expected '' 6>&1
        ($output -join ' ') | Should -Match 'skipping verification'
    }
}
