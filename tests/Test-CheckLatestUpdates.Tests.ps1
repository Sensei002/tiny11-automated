<#
.SYNOPSIS
    Tests for the cumulative-update watcher (scripts/check-latest-updates.ps1).

.DESCRIPTION
    The watcher's only real logic is "which families moved since last time", which is
    Compare-TrackedUpdates - pure, no catalog, no network. The catalog lookup itself is
    Find-LatestCumulativeUpdate, already covered by Test-LatestLcu. Dot-sourcing the
    script defines the function and stops at the guarded entry point, so no update is
    applied and no network call is made.

    Run: Invoke-Pester ./tests/Test-CheckLatestUpdates.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\check-latest-updates.ps1')
}

Describe 'Compare-TrackedUpdates' {

    It 'reports a family it has never seen, with no previous KB' {
        $tracked = @{}
        $current = @{ '26300' = @{ kb = 'KB5127648'; build = '26300.9711' } }
        $r = @(Compare-TrackedUpdates -Tracked $tracked -Current $current)
        $r.Count | Should -Be 1
        $r[0].family | Should -Be '26300'
        $r[0].kb | Should -Be 'KB5127648'
        $r[0].previous_kb | Should -Be ''
    }

    It 'reports a family whose KB moved and carries the old KB' {
        $tracked = @{ '26300' = @{ kb = 'KB5129195' } }
        $current = @{ '26300' = @{ kb = 'KB5127648' } }
        $r = @(Compare-TrackedUpdates -Tracked $tracked -Current $current)
        $r.Count | Should -Be 1
        $r[0].kb | Should -Be 'KB5127648'
        $r[0].previous_kb | Should -Be 'KB5129195'
    }

    It 'stays silent when the KB is unchanged' {
        $tracked = @{ '26300' = @{ kb = 'KB5127648' } }
        $current = @{ '26300' = @{ kb = 'KB5127648' } }
        @(Compare-TrackedUpdates -Tracked $tracked -Current $current).Count | Should -Be 0
    }

    It 'reports only the families that changed across a full set' {
        $tracked = @{
            '26100' = @{ kb = 'KB-A' }
            '26200' = @{ kb = 'KB-B' }
            '26300' = @{ kb = 'KB-C' }
        }
        $current = @{
            '26100' = @{ kb = 'KB-A' }
            '26200' = @{ kb = 'KB-B2' }
            '26300' = @{ kb = 'KB-C' }
        }
        $r = @(Compare-TrackedUpdates -Tracked $tracked -Current $current)
        $r.Count | Should -Be 1
        $r[0].family | Should -Be '26200'
        $r[0].previous_kb | Should -Be 'KB-B'
    }

    It 'treats a KB present now but absent before as new, not as a move' {
        $tracked = @{ '26300' = @{ kb = '' } }
        $current = @{ '26300' = @{ kb = 'KB5127648' } }
        $r = @(Compare-TrackedUpdates -Tracked $tracked -Current $current)
        $r.Count | Should -Be 1
        $r[0].previous_kb | Should -Be ''
    }
}
