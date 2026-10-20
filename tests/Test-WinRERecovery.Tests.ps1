<#
.SYNOPSIS
    Regression tests for the WinRE / ReAgent.xml contract that decides whether the
    finished ISO can be installed at all.

.DESCRIPTION
    Windows Setup reads <install image>\Windows\System32\Recovery\ReAgent.xml while
    it applies the image, and stages SafeOS from whatever ImageLocation points at.
    If the build deletes winre.wim but ships the stock ReAgent.xml, Setup chases a
    file that is not on the media and dies at ~11% with 0x80070003 - which the user
    sees as "installation failed after 10%".

    That is exactly what happened: Remove-WinRE deleted winre.wim and left
    ReAgent.xml naming it, and the only ReAgent patch ran against boot.wim *after*
    install.wim had already been committed. These tests pin the invariant:

        an image has winre.wim, or it has a zeroed ReAgent.xml - never neither,
        and never a ReAgent.xml that still points at a deleted image.

    Run: Invoke-Pester ./tests/Test-WinRERecovery.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $builderPath = Join-Path $repoRoot 'scripts/tiny11coremaker-headless.ps1'
    $workflowPath = Join-Path $repoRoot '.github/workflows/build-tiny11-core-gaming.yml'

    $builderSource = Get-Content -LiteralPath $builderPath -Raw
    $workflowSource = Get-Content -LiteralPath $workflowPath -Raw

    # The stub ships as a single-quoted here-string; pull it out of the source so the
    # test validates what the builder actually writes, not a copy of it.
    $stubMatch = [regex]::Match(
        $builderSource,
        "(?s)\`$script:CleanReAgentXml\s*=\s*@'\r?\n(.*?)\r?\n'@"
    )
    $stubXml = if ($stubMatch.Success) { $stubMatch.Groups[1].Value } else { '' }

    function Get-FunctionBody {
        param(
            [Parameter(Mandatory = $true)][string]$Source,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $m = [regex]::Match($Source, "(?s)function\s+$([regex]::Escape($Name))\s*\{.*?\n\}")
        if ($m.Success) { $m.Value } else { '' }
    }

    # Assertions below look at executable code only. Comments in this codebase quote
    # the very patterns being asserted on (e.g. "return $true"), which would make a
    # naive match report a violation that does not exist.
    function Get-FunctionCode {
        param(
            [Parameter(Mandatory = $true)][string]$Source,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $body = Get-FunctionBody -Source $Source -Name $Name
        ($body -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
}

Describe 'WinRE removal leaves a consistent image' {

    It 'defines exactly one ReAgent stub' {
        ([regex]::Matches($builderSource, '\$script:CleanReAgentXml\s*=\s*@''')).Count |
            Should -Be 1
    }

    It 'ships a well-formed ReAgent.xml' {
        $stubXml | Should -Not -BeNullOrEmpty
        { [xml]$stubXml } | Should -Not -Throw

        $doc = [xml]$stubXml
        $doc.DocumentElement.Name | Should -Be 'WindowsRE'
    }

    It 'zeroes every WinRE location and staging field' {
        $doc = [xml]$stubXml
        $re = $doc.DocumentElement

        $re.WinREStaged.state   | Should -Be '0'
        $re.InstallState.state  | Should -Be '0'
        $re.OsInstallAvailable.state | Should -Be '0'
        $re.ImageLocation.path  | Should -BeNullOrEmpty
        $re.WinreLocation.path  | Should -BeNullOrEmpty
    }

    It 'does not leave a ReAgent.xml that still names a winre.wim' {
        # Mirrors the guard in Assert-InstallImageRecoveryConsistent.
        $stubXml | Should -Not -Match '<WinREStaged\s+state="1"'
        $stubXml | Should -Not -Match '<ImageLocation[^>]*\spath="[^"]+"'
    }

    It 'writes the stub into the OS image when it deletes winre.wim' {
        $body = Get-FunctionBody -Source $builderSource -Name 'Remove-WinRE'
        $body | Should -Not -BeNullOrEmpty
        # -CreateIfMissing is what makes this the OS image path: the invariant must
        # hold even if the stock image had no ReAgent.xml to patch.
        $body | Should -Match 'Write-CleanReAgentXml[^\r\n]*-CreateIfMissing'
    }

    It 'keeps a single ReAgent implementation rather than a second inline copy' {
        $code = Get-FunctionCode -Source $builderSource -Name 'Patch-ReAgentXml'
        $code | Should -Match 'Write-CleanReAgentXml'
        $code | Should -Not -Match '<WindowsRE'
    }

    It 'never returns a value from Write-CleanReAgentXml' {
        # Write-Log writes to the output stream, so a boolean return would hand the
        # caller [logstring, bool] and every `-not` on it would test the array.
        $code = Get-FunctionCode -Source $builderSource -Name 'Write-CleanReAgentXml'
        $code | Should -Not -Match 'return\s+\$(true|false)'
        $code | Should -Match '\$script:ReAgentXmlPatched'
    }

    It 'verifies the exported image before the ISO is built' {
        $body = Get-FunctionBody -Source $builderSource -Name 'Create-TinyISO'
        $body | Should -Match 'Assert-InstallImageRecoveryConsistent'
    }
}

Describe 'Workflow defaults do not ship an un-installable image' {

    It 'preserves WinRE by default' {
        # Line scan rather than one regex over the whole workflow: a nested-quantifier
        # pattern such as (?:\r?\n.*)*? backtracks catastrophically on a 54KB YAML file
        # and takes the whole Pester run down with it.
        $lines = $workflowSource -split "`r?`n"
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^      preserve_winre:\s*$') { $start = $i; break }
        }

        $start | Should -BeGreaterThan -1

        $defaultValue = $null
        for ($i = $start + 1; $i -lt [Math]::Min($start + 8, $lines.Count); $i++) {
            if ($lines[$i] -match '^ {6}[^\s]') { break }          # next top-level input
            if ($lines[$i] -match '^\s+default:\s*(\S+)\s*$') {
                $defaultValue = $Matches[1]
                break
            }
        }

        $defaultValue | Should -Be 'true'
    }
}
