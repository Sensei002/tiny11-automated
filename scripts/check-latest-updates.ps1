<#
.SYNOPSIS
    Detects newly published cumulative updates for the build families the repo ships.

.DESCRIPTION
    The build workflows already slipstream the newest cumulative update, so the only
    reason to re-run them is that Microsoft has published a newer update. This script
    answers "is there a newer cumulative update than the last one I recorded?" for each
    build family, by reusing the exact catalog logic the builders use
    (Find-LatestCumulativeUpdate in apply-latest-lcu.ps1) - no second, drifting copy of
    the catalog scrape.

    It records what it saw in a tracking file and reports only the families whose KB
    moved (or that it has never seen before). The companion watch-updates.yml workflow
    turns that into a Discord ping; it never triggers a build, so a human decides.

    On the very first run (no tracking file yet) it seeds the file and reports nothing,
    so enabling the watcher does not immediately page you about the current state.

.PARAMETER TrackingFile
    JSON file holding the last-seen KB per family. Created/updated in place.

.PARAMETER Families
    Build families to watch. 26100 = 24H2 (and LTSC 2024), 26200 = 25H2, 26300 = 26H2.

.PARAMETER Arch
    Architecture to query the catalog for. x64 by default.

.PARAMETER GitHubOutput
    When set (a path), writes has_new=true|false and a new_updates multiline value for
    a GitHub Actions step to consume.

.OUTPUTS
    The new/updated entries as JSON on the success stream (empty array when none).

.EXAMPLE
    .\scripts\check-latest-updates.ps1 -TrackingFile tracked_updates.json -GitHubOutput $env:GITHUB_OUTPUT
#>
[CmdletBinding()]
param(
    [string]$TrackingFile = 'tracked_updates.json',
    [int[]]$Families = @(26100, 26200, 26300),
    [string]$Arch = 'x64',
    [switch]$NoSave,
    [string]$GitHubOutput = ''
)

function Compare-TrackedUpdates {
    <#
        Pure comparison: given the previously tracked map and the freshly observed map
        (both keyed by family string, values @{ kb; build; title; month }), return the
        entries that are new or whose KB changed. Kept side-effect free so it can be
        unit-tested without touching the catalog.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Tracked,
        [Parameter(Mandatory = $true)][hashtable]$Current
    )

    $changed = @()
    foreach ($family in ($Current.Keys | Sort-Object)) {
        $now = $Current[$family]
        # ContainsKey + indexer rather than Hashtable.TryGetValue: the latter is not
        # present on .NET Framework's Hashtable (Windows PowerShell 5.1), which is
        # where these tests run.
        $isNew = -not $Tracked.ContainsKey($family)
        $had = if ($isNew) { $null } else { $Tracked[$family] }
        $moved = (-not $isNew) -and ("$($had.kb)" -ne "$($now.kb)")
        if ($isNew -or $moved) {
            $changed += [pscustomobject]@{
                family      = $family
                kb          = $now.kb
                build       = $now.build
                title       = $now.title
                month       = $now.month
                previous_kb = if ($isNew) { '' } else { "$($had.kb)" }
            }
        }
    }
    return $changed
}

# The catalog lookup lives in apply-latest-lcu.ps1. Dot-sourcing it loads its functions
# and skips its entry point (guarded by $MyInvocation.InvocationName -ne '.'), so this
# reuses the tested scrape instead of duplicating it.
. (Join-Path $PSScriptRoot 'apply-latest-lcu.ps1')

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by tests: stop here

# Only for a real run: set these here rather than at script scope, so tests can
# dot-source this file (to reach Compare-TrackedUpdates) without inheriting them.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$trackedExisted = Test-Path -LiteralPath $TrackingFile
$tracked = @{}
if ($trackedExisted) {
    try {
        $loaded = Get-Content -LiteralPath $TrackingFile -Raw | ConvertFrom-Json -AsHashtable
        if ($loaded) { $tracked = $loaded }
    } catch {
        Write-Warning "Could not read $TrackingFile ($($_.Exception.Message)); treating as first run."
        $trackedExisted = $false
    }
}

$current = @{}
foreach ($family in $Families) {
    $key = "$family"
    try {
        $rec = Find-LatestCumulativeUpdate -Family $family -Arch $Arch
    } catch {
        Write-Warning "Catalog lookup failed for family $family`: $($_.Exception.Message)"
        continue
    }
    if (-not $rec) {
        Write-Warning "No cumulative update found for family $family on $Arch."
        continue
    }
    $current[$key] = @{
        kb    = $rec.Kb
        build = $rec.TargetBuild
        title = $rec.Title
        month = $rec.Month
    }
    Write-Output "family $key -> $($rec.Kb) ($($rec.TargetBuild))"
}

if ($current.Count -eq 0) {
    Write-Warning 'No families resolved; leaving the tracking file untouched.'
    if ($GitHubOutput) {
        'has_new=false' | Out-File -FilePath $GitHubOutput -Append -Encoding utf8
    }
    '[]'
    return
}

$changed = @(Compare-TrackedUpdates -Tracked $tracked -Current $current)

# First run only seeds the file - it must not raise a "new update" page about the
# status quo. It still reports first_run=true so the workflow can send a one-off
# "watcher is now tracking X" confirmation instead of staying silent.
$firstRun = -not $trackedExisted
$report = if ($firstRun) { @() } else { $changed }
if ($firstRun) {
    Write-Output "First run: seeded $TrackingFile with the current updates."
}

if (-not $NoSave) {
    $directory = Split-Path -Parent $TrackingFile
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $current | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $TrackingFile -Encoding utf8
}

$reportJson = (@($report) | ConvertTo-Json -Compress -Depth 6)

# The full current map, for the "initialized" / manual-test status ping.
$currentList = foreach ($k in ($current.Keys | Sort-Object)) {
    $c = $current[$k]
    [pscustomobject]@{
        family      = $k
        kb          = $c.kb
        build       = $c.build
        title       = $c.title
        month       = $c.month
        previous_kb = ''
    }
}
$currentJson = (@($currentList) | ConvertTo-Json -Compress -Depth 6)

if ($GitHubOutput) {
    if (@($report).Count -gt 0) { 'has_new=true' | Out-File -FilePath $GitHubOutput -Append -Encoding utf8 }
    else { 'has_new=false' | Out-File -FilePath $GitHubOutput -Append -Encoding utf8 }
    "first_run=$(if ($firstRun) { 'true' } else { 'false' })" | Out-File -FilePath $GitHubOutput -Append -Encoding utf8
    "current_updates<<EOF`n$currentJson`nEOF" | Out-File -FilePath $GitHubOutput -Append -Encoding utf8
    if (@($report).Count -gt 0) {
        "new_updates<<EOF`n$reportJson`nEOF" | Out-File -FilePath $GitHubOutput -Append -Encoding utf8
    }
}

$reportJson
