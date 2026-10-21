<#
.SYNOPSIS
    Regression tests for the builder's "delete a hostile tree" path.

.DESCRIPTION
    Optimize-WinSxS throws away the stock WinSxS tree and renames a trimmed copy
    into its place. That delete is the most fragile operation in the whole build:
    the tree is owned by TrustedInstaller, carries ReadOnly attributes, and has
    paths at MAX_PATH.

    Two ways it took the build down, both now pinned:

    1. Get-ChildItem -Recurse over a tree the preceding Remove-Item had already
       half-deleted raised ERROR_DEVICE_DOES_NOT_EXIST ("A device which does not
       exist was specified") as a *terminating* .NET exception. -ErrorAction
       SilentlyContinue does not suppress those, so it escaped the cleanup
       function and hit the script-level catch as FATAL.

    2. Write-Log writes to the success stream, so Remove-TreeForcefully returned
       [log lines..., bool]. A non-empty array is always true, so the graceful
       "could not delete, keep the original WinSxS" fallback was unreachable -
       and the Rename-Item that followed would have thrown anyway.

    These checks are line scans over the whole file on purpose: extracting a
    single function body with a regex is fragile here (the code contains
    single-line catch blocks and a nested scriptblock), and a helper that
    silently matched the wrong span would turn every assertion into a no-op.

    Run: Invoke-Pester ./tests/Test-BuilderRobustness.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $builderPath = Join-Path $repoRoot 'scripts/tiny11coremaker-headless.ps1'
    $builderSource = Get-Content -LiteralPath $builderPath -Raw
    $lines = $builderSource -split "`r?`n"

    # Lines from the declaration matching -StartPattern through the first line that
    # is exactly '}' at column 0 - which is how every top-level function in this
    # script ends.
    function Get-ScriptBlock {
        param([Parameter(Mandatory = $true)][string]$StartPattern)
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $StartPattern) { $start = $i; break }
        }
        if ($start -lt 0) { return @() }

        $block = New-Object System.Collections.Generic.List[string]
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $block.Add($lines[$i])
            if ($i -gt $start -and $lines[$i] -eq '}') { break }
        }
        return $block.ToArray()
    }
}

Describe 'WinSxS cleanup cannot kill the build' {

    It 'routes every call through the boolean-returning wrapper' {
        # Calling Remove-TreeForcefully directly in an `if` tests the log array,
        # not the result - which is how the fallback became unreachable.
        $block = Get-ScriptBlock -StartPattern '^function Optimize-WinSxS \{'
        $block.Count | Should -BeGreaterThan 5

        $raw = @($block | Where-Object { $_ -match 'Remove-TreeForcefully' -and $_ -notmatch '^\s*#' })
        $raw.Count | Should -Be 0
        @($block | Where-Object { $_ -match 'Test-TreeRemoved' }).Count | Should -BeGreaterThan 0
    }

    It 'defines a wrapper that returns only the boolean' {
        $block = Get-ScriptBlock -StartPattern '^function Test-TreeRemoved \{'
        $block.Count | Should -BeGreaterThan 5
        $text = $block -join "`n"
        # @(...) collects the log lines, [-1] takes the boolean.
        $text | Should -Match '@\(Remove-TreeForcefully'
        $text | Should -Match '\$result\[-1\]'
    }

    It 'has no bare call to Remove-TreeForcefully anywhere else' {
        $bare = @($lines | Where-Object {
            $_ -match 'Remove-TreeForcefully' -and
            $_ -notmatch '^\s*#' -and
            $_ -notmatch 'function\s+Remove-TreeForcefully' -and
            $_ -notmatch '@\(Remove-TreeForcefully'
        })
        $bare.Count | Should -Be 0
    }

    It 'wraps the directory enumeration, which throws on a half-deleted tree' {
        # The enumeration is the part that raised ERROR_DEVICE_DOES_NOT_EXIST.
        # A bare Get-ChildItem here is what aborted the build.
        $block = Get-ScriptBlock -StartPattern '^function Remove-TreeForcefully \{'
        # Skip comment lines: the function's own documentation names Get-ChildItem
        # when explaining the crash, and picking that up would test a comment.
        $idx = -1
        for ($i = 0; $i -lt $block.Count; $i++) {
            if ($block[$i].Trim().StartsWith('#')) { continue }
            if ($block[$i] -match 'Get-ChildItem') { $idx = $i; break }
        }
        $idx | Should -BeGreaterThan -1

        # Nearest preceding line that is neither blank nor a comment must open a
        # try block. (The code comments this spot heavily, so skip those too.)
        $prev = $null
        for ($i = $idx - 1; $i -ge 0; $i--) {
            $trimmed = $block[$i].Trim()
            if (-not $trimmed) { continue }
            if ($trimmed.StartsWith('#')) { continue }
            $prev = $trimmed
            break
        }
        $prev | Should -Be 'try {'
    }

    It 'has a robocopy fallback for trees the provider cannot walk' {
        $block = Get-ScriptBlock -StartPattern '^function Remove-TreeForcefully \{'
        $text = $block -join "`n"
        $text | Should -Match 'robocopy\.exe'
        $text | Should -Match '/MIR'
    }

    It 'catches unexpected errors instead of letting them reach the script-level FATAL' {
        $block = Get-ScriptBlock -StartPattern '^function Remove-TreeForcefully \{'
        $text = $block -join "`n"
        $text | Should -Match 'Force-delete hit an unexpected error'
        $text | Should -Match '\$isGone'
    }

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $builderPath, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }
}
