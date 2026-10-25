<#
.SYNOPSIS
    Pester tests for the cumulative-update stage.

.DESCRIPTION
    Covers the three things that decide whether an image ships patched:

      1. The catalog parsing - the page is ASP.NET with single-quoted anchors, and
         a parser that only matches double quotes returns zero rows without
         erroring, which looks exactly like "no update available".
      2. The selection rules - a bundle contains .NET updates, Dynamic duplicates,
         Server updates and the other architecture, and picking any of them
         installs the wrong thing or nothing.
      3. The wiring and its order - the update has to run before the removals and
         before Optimize-WinSxS, because that strip deletes the servicing stack
         Add-Package needs. Nothing fails loudly if the order regresses.

    No image is mounted and nothing is downloaded: the catalog fixture is inline.

.EXAMPLE
    Invoke-Pester -Path tests/Test-LatestLcu.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptsDir = Join-Path $repoRoot 'scripts'
    $workflowsDir = Join-Path (Join-Path $repoRoot '.github') 'workflows'

    $lcuPath = Join-Path $scriptsDir 'apply-latest-lcu.ps1'
    . $lcuPath

    $builders = @(
        @{ Name = 'Standard'; Path = Join-Path $scriptsDir 'tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = Join-Path $scriptsDir 'tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = Join-Path $scriptsDir 'nano11builder-headless.ps1' }
    )

    $workflows = @(
        'build-tiny11.yml'
        'build-tiny11-core.yml'
        'build-tiny11-core-gaming.yml'
        'build-nano11.yml'
        'build-tiny11-ltsc.yml'
        'build-tiny11-core-ltsc.yml'
    )

    # A trimmed copy of the real catalog page. The row id carries the update GUID
    # and the anchor id is single-quoted - that detail is the whole point of the
    # parser test, so it must stay faithful to the live markup.
    $catalogFixture = @'
<table><tr id="aaaaaaaa-1111-1111-1111-111111111111_R0">
<td id="aaaaaaaa-1111-1111-1111-111111111111_C0_R0"> </td>
<td id="aaaaaaaa-1111-1111-1111-111111111111_C1_R0"> <a id='aaaaaaaa-1111-1111-1111-111111111111_link' href= "javascript:void(0);" class="x"> 2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5127648) (26300.9711) </a> </td>
</tr><tr id="bbbbbbbb-2222-2222-2222-222222222222_R1">
<td id="bbbbbbbb-2222-2222-2222-222222222222_C0_R1"> </td>
<td id="bbbbbbbb-2222-2222-2222-222222222222_C1_R1"> <a id='bbbbbbbb-2222-2222-2222-222222222222_link' href= "javascript:void(0);" class="x"> 2026-09 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5129195) (26300.9457) </a> </td>
</tr><tr id="cccccccc-3333-3333-3333-333333333333_R2">
<td id="cccccccc-3333-3333-3333-333333333333_C0_R2"> </td>
<td id="cccccccc-3333-3333-3333-333333333333_C1_R2"> <a id='cccccccc-3333-3333-3333-333333333333_link' href= "javascript:void(0);" class="x"> 2026-10 Cumulative Update for Windows 11, version 26H2 for arm64-based Systems (KB5127648) (26300.9711) </a> </td>
</tr><tr id="dddddddd-4444-4444-4444-444444444444_R3">
<td id="dddddddd-4444-4444-4444-444444444444_C0_R3"> </td>
<td id="dddddddd-4444-4444-4444-444444444444_C1_R3"> <a id='dddddddd-4444-4444-4444-444444444444_link' href= "javascript:void(0);" class="x"> 2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5128999) </a> </td>
</tr><tr id="eeeeeeee-5555-5555-5555-555555555555_R4">
<td id="eeeeeeee-5555-5555-5555-555555555555_C0_R4"> </td>
<td id="eeeeeeee-5555-5555-5555-555555555555_C1_R4"> <a id='eeeeeeee-5555-5555-5555-555555555555_link' href= "javascript:void(0);" class="x"> 2026-09 Dynamic Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5127649) (26300.9711) </a> </td>
</tr><tr id="ffffffff-6666-6666-6666-666666666666_R5">
<td id="ffffffff-6666-6666-6666-666666666666_C0_R5"> </td>
<td id="ffffffff-6666-6666-6666-666666666666_C1_R5"> <a id='ffffffff-6666-6666-6666-666666666666_link' href= "javascript:void(0);" class="x"> 2026-10 Cumulative Update for Microsoft server operating system version 26H2 for x64-based Systems (KB5127777) (26300.9711) </a> </td>
</tr></table>
'@

    $parsed = ConvertFrom-CatalogSearchHtml -Html $catalogFixture
}

Describe 'Build family mapping' {

    It 'reads the family out of <Version>' -ForEach @(
        @{ Version = '10.0.26300.9457'; Family = 26300 }
        @{ Version = '26300.9457'; Family = 26300 }
        @{ Version = '10.0.26100.1742'; Family = 26100 }
        @{ Version = '10.0.19044.3803'; Family = 19044 }
        @{ Version = '10.0.22631.3155'; Family = 22631 }
    ) {
        Get-BuildFamily -Version $Version | Should -Be $Family
    }

    It 'returns 0 for junk instead of throwing' -ForEach @(
        @{ Version = '' }
        @{ Version = 'not-a-version' }
        @{ Version = '10' }
    ) {
        Get-BuildFamily -Version $Version | Should -Be 0
    }

    It 'maps <Family> to a catalog phrase' -ForEach @(
        @{ Family = 26300; Expect = 'Cumulative Update for Windows 11, version 26H2 for x64-based Systems' }
        @{ Family = 26100; Expect = 'Cumulative Update for Windows 11, version 24H2 for x64-based Systems' }
        @{ Family = 19044; Expect = 'Cumulative Update for Windows 10 Version 21H2 for x64-based Systems' }
    ) {
        Get-UpdateSearchQuery -Family $Family -Arch 'x64' | Should -Be $Expect
    }

    It 'switches the architecture token' {
        Get-UpdateSearchQuery -Family 26300 -Arch 'arm64' | Should -BeLike '*arm64-based Systems'
    }

    It 'returns nothing for an unmapped family' {
        Get-UpdateSearchQuery -Family 99999 -Arch 'x64' | Should -BeNullOrEmpty
    }
}

Describe 'Version comparison' {

    It 'detects <Before> -> <After> as <Advanced>' -ForEach @(
        @{ Before = '26300.9457'; After = '26300.9711'; Advanced = $true }
        @{ Before = '26300.9711'; After = '26300.9457'; Advanced = $false }
        @{ Before = '26300.9711'; After = '26300.9711'; Advanced = $false }
        @{ Before = '26300.9999'; After = '26300.10000'; Advanced = $true }
        @{ Before = '26100.1742'; After = '26300.9711'; Advanced = $true }
    ) {
        Test-BuildAdvanced -Before $Before -After $After | Should -Be $Advanced
    }

    It 'refuses to compare when either side is empty or malformed' -ForEach @(
        @{ Before = ''; After = '26300.9711' }
        @{ Before = '26300.9711'; After = '' }
        @{ Before = 'abc'; After = '26300.9711' }
    ) {
        Test-BuildAdvanced -Before $Before -After $After | Should -BeFalse
    }
}

Describe 'Catalog page parsing' {

    It 'finds every row, not just the ones with double-quoted anchors' {
        # The live page uses id='...' for the title anchor. A parser matching only
        # double quotes silently returns nothing, which reads as "no update".
        $parsed.Count | Should -Be 6
    }

    It 'extracts the KB, the target build and the month' {
        # KB5127648 appears twice in the fixture - once per architecture - so the
        # x64 row has to be named explicitly rather than taking the first match.
        $first = $parsed |
            Where-Object { $_.Kb -eq 'KB5127648' -and $_.TargetBuild -eq '26300.9711' -and $_.Title -match 'x64' } |
            Select-Object -First 1
        $first | Should -Not -BeNullOrEmpty
        $first.Month | Should -Be '2026-10'
    }

    It 'leaves the target build empty when the title has none' {
        $record = ConvertFrom-CatalogSearchHtml -Html @'
<tr id="99999999-9999-9999-9999-999999999999_R0"><td id="x_C1_R0"><a id='99999999-9999-9999-9999-999999999999_link' href="#">2026-10 Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5126657)</a></td></tr>
'@
        $record[0].TargetBuild | Should -Be ''
        $record[0].Kb | Should -Be 'KB5126657'
    }
}

Describe 'Update selection' {

    It 'picks the newest x64 OS update and ignores everything else' {
        $best = Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26300
        $best | Should -Not -BeNullOrEmpty
        $best.Kb | Should -Be 'KB5127648'
        $best.TargetBuild | Should -Be '26300.9711'
        $best.UpdateId | Should -Be 'aaaaaaaa-1111-1111-1111-111111111111'
    }

    It 'never selects the other architecture' {
        $best = Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26300
        $best.Title | Should -Not -Match 'arm64'
    }

    It 'never selects a .NET Framework update' {
        $best = Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26300
        $best.Title | Should -Not -Match '\.NET'
    }

    It 'never selects a Dynamic duplicate' {
        $best = Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26300
        $best.Title | Should -Not -Match 'Dynamic'
    }

    It 'never selects a Server update' {
        $best = Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26300
        $best.Title | Should -Not -Match 'server'
    }

    It 'returns nothing when the family does not match the title build' {
        Select-LatestCumulativeUpdate -Updates $parsed -Arch 'x64' -Family 26100 | Should -BeNullOrEmpty
    }

    It 'orders a checkpoint package before the cumulative update' {
        $urls = @(
            'https://x/public/windows11.0-kb5127648-x64_abc.msu'
            'https://x/public/windows11.0-kb5043080-x64_def.msu'
        )
        $ordered = @($urls | Sort-Object -Property @{ Expression = { Get-PackageSortKey -Url $_ } })
        $ordered[0] | Should -BeLike '*kb5043080*'
        $ordered[1] | Should -BeLike '*kb5127648*'
    }
}

Describe 'Bundle package handling' {

    # The catalog answers one update with a bundle. KB5127648 (26H2, 26300.9711)
    # ships KB5043080 - the 24H2 checkpoint - alongside it. On 26300 media that
    # checkpoint is already incorporated, and DISM rejects it with 552/0x80070228
    # rather than CBS_E_NOT_APPLICABLE. Treating it as mandatory aborted the build
    # before the real update was ever attempted.

    It 'treats the package carrying the selected KB as the payload' {
        Test-PrimaryPackage -FileName 'windows11.0-kb5127648-x64_2b88d2d3.msu' -Kb 'KB5127648' |
            Should -BeTrue
    }

    It 'treats the checkpoint in the same bundle as a prerequisite' {
        Test-PrimaryPackage -FileName 'windows11.0-kb5043080-x64_953449672073f8fb99.msu' -Kb 'KB5127648' |
            Should -BeFalse
    }

    It 'matches case-insensitively and accepts a bare KB number' {
        Test-PrimaryPackage -FileName 'Windows11.0-KB5127648-x64.msu' -Kb '5127648' |
            Should -BeTrue
    }

    It 'does not match a KB that merely starts with the selected one' {
        Test-PrimaryPackage -FileName 'windows11.0-kb51276489-x64.msu' -Kb 'KB5127648' |
            Should -BeFalse
    }

    It 'treats every package as a prerequisite when the KB is unknown' {
        Test-PrimaryPackage -FileName 'windows11.0-kb5043080-x64.msu' -Kb '' |
            Should -BeFalse
    }

    It 'lets an optional package fail without throwing' {
        Get-PackageOutcome -Code 552 -Optional | Should -Be 'failed-optional'
    }

    It 'still fails the build when the payload itself is rejected' {
        Get-PackageOutcome -Code 552 | Should -Be 'failed'
    }

    It 'reads CBS_E_NOT_APPLICABLE as already incorporated, not as a failure' -ForEach @(
        @{ Code = -2146498530; Label = 'signed' }
        @{ Code = 2148468766; Label = 'unsigned' }
    ) {
        Get-PackageOutcome -Code $Code | Should -Be 'not-applicable'
        Get-PackageOutcome -Code $Code -Optional | Should -Be 'not-applicable'
    }

    It 'reports a clean apply as applied' {
        Get-PackageOutcome -Code 0 | Should -Be 'applied'
    }
}

Describe 'Builder wiring' {

    It 'declares -UpdateToLatest in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match '(?m)^\s*\[switch\]\$UpdateToLatest'
    }

    It 'does nothing unless the switch is passed in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match 'if \(-not \$UpdateToLatest\) \{ return \}'
    }

    It 'runs the update before the removals in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        # Matched as an indented line, not a substring: the file is CRLF on
        # checkout and also contains the function definition of the same name.
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $call = [regex]::Match($source, '(?m)^    Invoke-ImageUpdate\s*$').Index
        $debloat = [regex]::Match($source, '(?m)^    Remove-BloatwareApps\s*$').Index
        $call | Should -BeGreaterThan -1
        $debloat | Should -BeGreaterThan -1
        $call | Should -BeLessThan $debloat
    }

    It 'runs the update before Optimize-WinSxS in the <Name> builder' -ForEach @(
        # Standard has no WinSxS strip - it keeps a serviceable component store -
        # so this ordering only exists to break in Core and Nano.
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        # Optimize-WinSxS deletes the servicing stack. Add-Package afterwards can
        # never succeed, and nothing about the build fails until DISM does.
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $call = [regex]::Match($source, '(?m)^    Invoke-ImageUpdate\s*$')
        $strip = [regex]::Match($source, '(?m)^    Optimize-WinSxS\s*$')
        $call.Success | Should -BeTrue
        $strip.Success | Should -BeTrue -Because "$Name is expected to strip WinSxS"
        $call.Index | Should -BeLessThan $strip.Index
    }

    It 'runs the update before the image is optimized in the Standard builder' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/tiny11maker-headless.ps1') -Raw
        $call = [regex]::Match($source, '(?m)^    Invoke-ImageUpdate\s*$')
        $optimize = [regex]::Match($source, '(?m)^    Optimize-WindowsImage\s*$')
        $call.Success | Should -BeTrue
        $optimize.Success | Should -BeTrue
        $call.Index | Should -BeLessThan $optimize.Index
    }

    It 'treats a failed update as a warning, not a build failure in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match 'Update step failed:'
        $source | Should -Match 'Image kept at'
    }
}

Describe 'Workflow wiring' {

    It 'declares update_to_latest in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match '(?m)^\s{6}update_to_latest:'
        $raw | Should -Match '\$params\.UpdateToLatest = \$true'
    }

    It 'defaults the input to required (update on) in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        # "required" is the default mode, so a published image is always the
        # current build. An automation dispatch that omits the key gets this.
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $block = [regex]::Match($raw, '(?ms)^\s{6}update_to_latest:.*?(?=^\s{6}\w|\z)').Value
        $block | Should -Match "default:\s*'required'"
        $block | Should -Match "options:"
        $block | Should -Match "- 'required'"
        $block | Should -Match "- 'best-effort'"
        $block | Should -Match "- 'off'"
    }

    It 'lets an automation dispatch keep the default in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        # The version-matrix workflow dispatches builds without this key, and an
        # omitted value must degrade to "required" (update on) rather than off.
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match 'github\.event\.inputs\.update_to_latest \}\}"'
        $raw | Should -Match 'IsNullOrWhiteSpace\(\$updateMode\)'
    }
}

Describe 'Latest-build guarantee' {

    It 'declares -RequireLatestUpdate in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match '(?m)^\s*\[switch\]\$RequireLatestUpdate'
    }

    It 'publishes the build it actually produced, not the ISO it started from, in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        # Without this the filename, release tag and checksum names all carry the
        # base build, so a patched 26300.9711 image ships labelled 26300.9457 and
        # nothing downstream can tell the difference.
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match 'if \("\$\(\$outcome\.After\)" -match ''\(\\d\+\\\.\\d\+\)\$''\)'
        $source | Should -Match '\$script:DetectedBuildNumber = \$Matches\[1\]'
    }

    It 'fails instead of shipping a stale image when the update is required, in the <Name> builder' -ForEach @(
        @{ Name = 'Standard'; Path = 'scripts/tiny11maker-headless.ps1' }
        @{ Name = 'Core'; Path = 'scripts/tiny11coremaker-headless.ps1' }
        @{ Name = 'Nano'; Path = 'scripts/nano11builder-headless.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match 'throw "The image was not updated to the latest build'
        $source | Should -Match 'throw "Could not update the image to the latest build'
    }

    It 'forwards -RequireLatestUpdate when the mode is required in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        # The two update booleans were collapsed into one tri-state
        # (required / best-effort / off). "required" is the default, so the
        # fail-if-not-updated behaviour still ships by default; it is now gated
        # on the mode rather than a second input.
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match '\$params\.RequireLatestUpdate = \$true'
        $raw | Should -Match '\$updateMode -eq ''required'''
    }
}

Describe 'SourceForge upload resilience' {

    It 'keeps the connection alive so a stall cannot hang the job, in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        # A run sat on this step for 17 minutes having written zero bytes; without
        # ServerAliveInterval scp waits for the job's 360-minute timeout.
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match "ServerAliveInterval=15"
        $raw | Should -Match "ServerAliveCountMax=4"
        $raw | Should -Match "ConnectTimeout=30"
    }

    It 'retries the upload once before failing, in <File>' -ForEach @(
        @{ File = 'build-tiny11.yml' }
        @{ File = 'build-tiny11-core.yml' }
        @{ File = 'build-tiny11-core-gaming.yml' }
        @{ File = 'build-nano11.yml' }
        @{ File = 'build-tiny11-ltsc.yml' }
        @{ File = 'build-tiny11-core-ltsc.yml' }
    ) {
        $raw = Get-Content -LiteralPath (Join-Path $workflowsDir $File) -Raw
        $raw | Should -Match 'for \(\$attempt = 1; \$attempt -le 2; \$attempt\+\+\)'
        $raw | Should -Match 'SCP Upload failed after 2 attempt'
    }
}

Describe 'Mounted-image version detection' {

    BeforeAll {
        # Make Get-WindowsImage present so it can be mocked both on a host without the
        # Dism module (a local / non-Windows test runner) and on a Windows runner.
        if (-not (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue)) {
            function Get-WindowsImage { param([switch]$Mounted) }
        }
    }

    It 'reads the DISM build (26300.9457), not the misstamped kernel, for 26H2 media' {
        # This is the exact regression from run #40133719975: the kernel on the
        # 26H2 ISO reports 26100.9457, so a kernel read selects the 24H2 catalog and
        # DISM rejects the package (exit 552 / 0x80070228).
        Mock Get-WindowsImage -ParameterFilter { $Mounted -eq $true } -MockWith {
            return @(
                [pscustomobject]@{ MountPath = 'C:\mount'; ImageVersion = [version]'10.0.26300.9457' }
            )
        }
        Get-MountedImageVersion -Path 'C:\mount' | Should -Be '26300.9457'
    }

    It 'matches by mount path and ignores other mounted images' {
        Mock Get-WindowsImage -ParameterFilter { $Mounted -eq $true } -MockWith {
            return @(
                [pscustomobject]@{ MountPath = 'C:\other'; ImageVersion = [version]'10.0.26100.1742' }
                [pscustomobject]@{ MountPath = 'C:\mount'; ImageVersion = [version]'10.0.26300.9457' }
            )
        }
        Get-MountedImageVersion -Path 'C:\mount' | Should -Be '26300.9457'
    }

    It 'falls back to the kernel when DISM reports nothing' {
        Mock Get-WindowsImage -ParameterFilter { $Mounted -eq $true } -MockWith { return @() }
        # No real kernel on the fake path, so it returns empty rather than throwing.
        Get-MountedImageVersion -Path 'C:\nope' | Should -Be ''
    }

    It 'returns empty when DISM throws and no kernel exists' {
        Mock Get-WindowsImage -ParameterFilter { $Mounted -eq $true } -MockWith { throw 'boom' }
        Get-MountedImageVersion -Path 'C:\nope' | Should -Be ''
    }
}

Describe 'LCU version selection' {

    BeforeAll {
        $lcuSource = Get-Content -LiteralPath $lcuPath -Raw
    }

    It 'prefers the caller-supplied -Version for the before-build (26H2-safe)' {
        # Without this the kernel read returns 26100 on 26H2 media and the wrong CU
        # family is selected.
        $lcuSource | Should -Match '\$before = \$Version'
    }

    It 'reads the mounted build from DISM, not the kernel, to pick the update family' {
        $lcuSource | Should -Match 'Get-WindowsImage -Mounted'
    }
}
