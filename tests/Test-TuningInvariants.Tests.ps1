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

    It 'verifies the clock floor as well as the ceiling' {
        # Maximum state, boost mode and boost policy all describe the ceiling. A
        # scheme can pass all three while sitting at its lowest P-state, because
        # nothing pins the floor - and the floor is what actually holds a 3.6 GHz
        # part at 3.6 GHz. Minimum processor state has to be in the checked set.
        $firstBootSource | Should -Match '893dee8e-2bef-41e0-89c6-b55d0929964c'
    }

    It 'writes a 100% minimum processor state on AC' {
        $floor = @($powerConfig.settings | Where-Object { $_.setting -eq '893dee8e-2bef-41e0-89c6-b55d0929964c' })
        $floor.Count | Should -Be 1
        $floor[0].ac | Should -Be 100
        $floor[0].group | Should -BeNullOrEmpty
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

    It 're-asserts the lockdown on the target, after the boot servicing pass' {
        # The offline pass writes Start=4 into the mounted hive and deletes the task
        # folders. The first online boot's servicing pass then re-registers inbox
        # service start types from the component manifests. A shipped Core-Gaming
        # image came up with wuauserv at Start=3 and InstallService\ScanForUpdates
        # live - UsoSvc stayed at 4, which is why it looked half-removed - and the
        # client scanned and staged 17 updates before the user did anything.
        #
        # The builder therefore cannot be the last word. The first-boot payload has
        # to write the same state again on the target, or the image only *looks*
        # debloated until the machine sees a network.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match 'function\s+Restore-WindowsUpdateLockdown'
        $code | Should -Match '(?m)^\s*Restore-WindowsUpdateLockdown\s*$'
        foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
            $code | Should -Match ([regex]::Escape($svc))
        }
    }

    It 'runs the re-assert before the power scheme is rebuilt' {
        # Ordering matters: 'powercfg -h off' and the scheme rebuild are the longest
        # part of the payload, and the window between the servicing pass and this
        # call is the only one where a scan can start.
        $code = Get-ExecutableCode -Source $firstBootSource
        $call = [regex]::Match($code, '(?m)^\s*Restore-WindowsUpdateLockdown\s*$')
        $power = [regex]::Match($code, '(?m)^\s*\$schemeGuid = New-GamingPowerScheme')
        $call.Success | Should -BeTrue
        $power.Success | Should -BeTrue
        $call.Index | Should -BeLessThan $power.Index
    }

    It 'merges SettingsPageVisibility instead of overwriting it' {
        # This value is the only thing that makes the Settings page disappear, and it
        # is the first thing a debloat playbook rewrites. The ReviOS playbook replaces
        # it with its own list that does not mention windowsupdate, so the page comes
        # back on a machine whose services are still disabled - and a blind write from
        # our side loses the playbook's list the same way. Merge both.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match "Get-ItemProperty[^\r\n]*SettingsPageVisibility"
        $code | Should -Not -Match "SettingsPageVisibility'\s+-Value\s+'hide:"
    }

    It 'registers a permanent boot guard that repeats through the boot phase' {
        # SetupComplete runs once, before the first logon. On the reference install the
        # payload ran at 00:49 and the Windows Update client scanned at 00:59 - the
        # guard fires before the event it guards against. One shot cannot hold a state
        # that a later servicing pass can revert.
        #
        # It used to unregister itself after three clean boots. A fresh install of the
        # fixed image disproved the assumption behind that: the boot servicing pass put
        # wuauserv back to Manual on boot 2, before the guard's first run. A guard that
        # stops watching fails silently, so it is permanent now.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match 'function\s+Register-WindowsUpdateGuard'
        $code | Should -Match '(?m)^\s*Register-WindowsUpdateGuard\s*$'
        # Repetition is what closes the window between servicing re-enabling the service
        # and the guard noticing it.
        $code | Should -Match '\$trigger\.Repetition'
        $code | Should -Match 'RepetitionInterval'
        # No retirement counter may come back.
        $code | Should -Not -Match 'GuardBoots'
        $code | Should -Not -Match 'GuardMaxAttempts'
    }

    It 'runs the guard before the completion marker check' {
        # .firstboot-done already exists by the time the first guarded boot happens, so
        # a guard handled after the marker check would exit 0 and never run.
        $code = Get-ExecutableCode -Source $firstBootSource
        $guard = [regex]::Match($code, '(?m)^\s*if\s*\(\$WuGuard\)')
        $marker = [regex]::Match($code, '(?m)Completion marker found')
        $guard.Success | Should -BeTrue
        $marker.Success | Should -BeTrue
        $guard.Index | Should -BeLessThan $marker.Index
    }

    It 'fails the build when the requested state did not land in the image' {
        # Every pass is best-effort against a system-owned hive and task tree, so a
        # build that changed nothing logs identically to one that changed everything.
        # Read the state back and fail, rather than shipping an ISO that behaves
        # differently from what the build asked for.
        #
        # The assertion is mode-aware since pause replaced removal as the default:
        # 'removed' requires Start=4 and no task folders, 'paused' and 'live' require
        # the opposite, so one unchecked assertion would pass the wrong image.
        $code = Get-ExecutableCode -Source $builderSource['Core']
        $code | Should -Match 'function\s+Assert-WindowsUpdateState'
        $code | Should -Match 'Assert-WindowsUpdateState\s+-MountDir'
        $assert = [regex]::Match($code, '(?m)^\s*Assert-WindowsUpdateState\s+-MountDir\s+\$scratchDir\s+-Mode\s+\$WindowsUpdateMode')
        $unload = [regex]::Match($code, '(?m)^\s*Unload-RegistryHives\s*$')
        $assert.Success | Should -BeTrue -Because 'the mode has to reach the assertion, or every build is checked as removed'
        $unload.Success | Should -BeTrue
        # The check is only authoritative while the hives are still loaded.
        $assert.Index | Should -BeLessThan $unload.Index
    }

    It 'disables the services through the SCM, not through the hive' {
        # Set-ItemProperty on HKLM\SYSTEM\...\Services\<svc>\Start updates the registry
        # and nothing else. The SCM caches each service's start type in memory and does
        # not watch the hive, so the service stays startable for the rest of the session
        # even though reg query, Get-Service and sc qc all report Disabled.
        #
        # Measured on a 26H1 Core-Gaming guest: a stopped wuauserv with Start=0x4 reached
        # RUNNING from Start-Service. `sc config wuauserv start= disabled` (the same
        # ChangeServiceConfig call Set-Service makes) then made it return 1058. The
        # registry write is only correct offline, where no SCM is running to cache it.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match 'function\s+Disable-ServiceThroughScm'
        $code | Should -Match 'Set-Service\s+-Name\s+\$Name\s+-StartupType\s+Disabled'
        # No direct Start write anywhere in the payload - that is the shape of the bug.
        $code | Should -Not -Match "-Name\s+'Start'"
    }

    It 'proves a disabled service cannot be started instead of reading the value' {
        # A registry read reported "disabled" for the entire window in which wuauserv was
        # running. The only evidence that holds is a start attempt that is refused with
        # 1058, so the verifier has to attempt one and treat a successful start as the
        # failure case.
        #
        # sc.exe, not Start-Service: PowerShell's wrapper message is "Cannot start service
        # X on computer '.'." and carries neither the code nor the word "disabled", so
        # matching the exception reported every service as startable on a build where the
        # lockdown was actually holding.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match 'function\s+Test-ServiceStartBlocked'
        $code | Should -Match 'sc\.exe\s+start\s+\$Name'
        $code | Should -Match '1058'
        $code | Should -Match '\$LASTEXITCODE'
    }

    It 'waits long enough for wuauserv to actually stop' {
        # wuauserv measured 10-45 s to reach STOPPED. The old 15 s wait expired while it
        # was still STOP_PENDING, and the log printed "stopped wuauserv" regardless.
        $code = Get-ExecutableCode -Source $firstBootSource
        $m = [regex]::Match($code, 'WaitForStatus\([^)]*FromSeconds\((\d+)\)')
        $m.Success | Should -BeTrue
        [int]$m.Groups[1].Value | Should -BeGreaterOrEqual 30
        # And the outcome is re-read, not assumed.
        $code | Should -Match '\$svc\.Refresh\(\)'
        $code | Should -Match 'did not stop'
    }

    It 'only disables DoSvc when strip_background_noise is enabled' {
        # The builder leaves DoSvc to that group on purpose (see the comment at the
        # service list in tiny11coremaker-headless.ps1). Disabling it unconditionally in
        # the first-boot payload silently overrides a toggle the user turned off.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match "Test-GamingGroupEnabled\s+'strip_background_noise'"
        $code | Should -Match "\`$services\s*\+=\s*'DoSvc'"
    }

    It 'counts only the update tasks that actually disappeared' {
        # Unregister-ScheduledTask with -ErrorAction SilentlyContinue returns the same
        # nothing whether it succeeded or was denied, so the old $removed++ counted
        # attempts. InstallService\ScanForUpdates was live on a shipped image while the
        # log claimed the tasks were gone.
        $code = Get-ExecutableCode -Source $firstBootSource
        $code | Should -Match 'Get-ScheduledTask\s+-TaskName\s+\$task\.TaskName\s+-TaskPath\s+\$path'
        $code | Should -Match 'could not unregister'
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

Describe 'Windows Update pause' {

    BeforeAll {
        $firstBoot = Get-ExecutableCode -Source $firstBootSource
        $builder = Get-ExecutableCode -Source $builderSource['Core']

        $pauseMatch = [regex]::Match($firstBoot, '(?s)function Restore-WindowsUpdatePause \{.*?\n\}')
        $pauseBody = $pauseMatch.Value
    }

    It 'travels the mode to the target machine instead of guessing it' {
        # A paused image and a live one are identical in service state, task folders
        # and binaries - only the pause keys differ, and those are exactly what a user
        # is allowed to delete. So the payload has to be told.
        $firstBoot | Should -Match 'function\s+Get-WindowsUpdateMode'
        $firstBoot | Should -Match 'windowsUpdateMode'
        $firstBoot | Should -Match 'gaming_groups\.json'
    }

    It 'defaults to removed for an image that predates the field' {
        # Every image built before the mode existed shipped with the stack removed.
        # Defaulting the other way would silently un-pause a machine that was built
        # never to update.
        $fn = [regex]::Match($firstBoot, '(?s)function Get-WindowsUpdateMode \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match "return 'removed'"
    }

    It 're-asserts the pause window with a cap large enough to hold it' {
        # Without FlightSettingsMaxPauseDays the client clamps the window to the 35-day
        # Settings maximum on the next scan, and the pause silently expires while the
        # page still says it is paused.
        $pauseBody | Should -Not -BeNullOrEmpty
        $pauseBody | Should -Match 'FlightSettingsMaxPauseDays'
        $pauseBody | Should -Match 'PauseUpdatesExpiryTime'
        $pauseBody | Should -Match 'PauseQualityUpdatesEndTime'
        $pauseBody | Should -Match 'PauseFeatureUpdatesEndTime'
    }

    It 'does not tear the update stack down while pausing' {
        $pauseBody | Should -Not -Match 'Start-Service'
        $pauseBody | Should -Not -Match 'Stop-Service'
        $pauseBody | Should -Not -Match 'Unregister-ScheduledTask'
        $pauseBody | Should -Not -Match 'Remove-Item'
    }

    It 'registers no boot guard in paused mode' {
        # The guard exists because Windows repairs a REMOVED stack. A paused device is
        # a supported state, so there is nothing to chase - and a guard that kept
        # re-pausing would fight a user who deliberately resumed updates.
        $paused = [regex]::Match($firstBoot, "(?s)'paused' \{\s*Restore-WindowsUpdatePause.*?\n        \}").Value
        $paused | Should -Not -BeNullOrEmpty
        $paused | Should -Not -Match 'Register-WindowsUpdateGuard'
        $paused | Should -Match 'Remove-WindowsUpdateGuardTask'
    }

    It 'retires a guard task inherited from a removed image' {
        # An upgrade or a mode change can leave the task behind; it would then keep
        # disabling Windows Update behind the user's back.
        $firstBoot | Should -Match 'function\s+Remove-WindowsUpdateGuardTask'
        $firstBoot | Should -Match 'Unregister-ScheduledTask'
        $guard = [regex]::Match($firstBoot, '(?s)function Invoke-WindowsUpdateGuard \{.*?\n\}').Value
        $guard | Should -Match 'Remove-WindowsUpdateGuardTask'
    }

    It 'writes the same expiry the builder wrote' {
        # A mismatch would ship a window that looks paused in the build log and is
        # already expired on the machine.
        $firstBoot | Should -Match "WindowsUpdatePauseExpiry = '3000-01-01T00:00:00Z'"
        $builder | Should -Match "WindowsUpdatePauseExpiry = '3000-01-01T00:00:00Z'"
    }
}
