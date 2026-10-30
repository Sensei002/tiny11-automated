<#
.SYNOPSIS
    Pester tests for the offline Atlas playbook layer.

.DESCRIPTION
    Covers the parts that can be checked without an ISO: the registry path mapping
    that turns a live-machine playbook into writes against the mounted image's
    hives, the answer-to-option translation, the registry write path itself (run
    against HKCU through the injectable root, so no machine state is touched), and
    the wiring between the compiler, the applier, the builder and the workflow.

    These tests do NOT download the playbook and do NOT build an ISO.

.EXAMPLE
    Invoke-Pester -Path tests/Test-AtlasPlaybook.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $configDir = Join-Path $repoRoot 'config'
    $scriptsDir = Join-Path $repoRoot 'scripts'

    $applierPath = Join-Path $scriptsDir 'atlas-playbook.ps1'
    $compilerPath = Join-Path $scriptsDir 'atlas-playbook.py'
    $optionsPath = Join-Path $configDir 'atlas_options.json'
    $builderPath = Join-Path $scriptsDir 'tiny11coremaker-headless.ps1'
    $workflowPath = Join-Path $repoRoot '.github/workflows/build-tiny11-atlas.yml'

    $options = Get-Content -LiteralPath $optionsPath -Raw | ConvertFrom-Json
    $builderRaw = Get-Content -LiteralPath $builderPath -Raw
    $workflowRaw = Get-Content -LiteralPath $workflowPath -Raw

    . $applierPath

    # A plan shaped like the real compiler's output, but small enough to assert on.
    $script:planFixture = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-plan-fixture-$PID.json"
    $fixture = [ordered]@{
        schemaVersion = '1.0.0'
        playbook      = [ordered]@{
            name            = 'AtlasOS'
            title           = 'Atlas v0.5.0'
            version         = '0.5.0'
            uniqueId        = '00000000-0000-4000-6174-6c6173203a33'
            source          = 'fixture'
            sha256          = ('a' * 64)
            supportedBuilds = @('26100', '26200', '26300')
            addedBuild      = '26300'
            imageBuild      = '26300'
        }
        options       = @(
            'defender-enable', 'defender-disable',
            'mitigations-default', 'mitigations-disable',
            'auto-updates-disable', 'auto-updates-default',
            'disable-hibernation', 'disable-power-saving', 'disable-core-isolation',
            'remove-snipping-tool', 'uninstall-edge', 'install-another-browser',
            'install-toolbox', 'browser-brave', 'browser-librewolf',
            'browser-firefox', 'browser-chrome'
        ) | ForEach-Object {
            [ordered]@{ name = $_; text = $_; page = 'RadioPage'; default = $false; dependsOn = '' }
        }
        actions       = @(
            [ordered]@{ kind = 'registry'; action = 'registryValue'; file = 'fixture.yml'; options = @(); path = 'HKLM\SOFTWARE\AtlasTest'; value = 'UnGated'; data = '1'; type = 'REG_DWORD' },
            [ordered]@{ kind = 'registry'; action = 'registryValue'; file = 'fixture.yml'; options = @('uninstall-edge'); path = 'HKLM\SOFTWARE\AtlasTest'; value = 'Gated'; data = '1'; type = 'REG_DWORD' },
            [ordered]@{ kind = 'registry'; action = 'registryValue'; file = 'fixture.yml'; options = @(); path = 'HKLM\SYSTEM\CurrentControlSet\Services\AtlasTestSvc'; value = 'Deliberate'; data = '7'; type = 'REG_DWORD' },
            [ordered]@{ kind = 'registry'; action = 'registryKey'; file = 'fixture.yml'; options = @(); path = 'HKCU\SOFTWARE\AtlasTestKey'; operation = 'add' },
            [ordered]@{ kind = 'registry'; action = 'service'; file = 'fixture.yml'; options = @(); name = 'AtlasTestSvc'; operation = 'change'; startup = 4 }
        )
        skipped       = @()
        stats         = [ordered]@{ applied = @{}; appliedTotal = 5; skipped = @{}; skippedTotal = 0; files = 1 }
    }
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:planFixture -Encoding UTF8

    # Every registry write in the tests lands under one throwaway HKCU subtree. The
    # applier takes the root as a parameter so the real write path can be exercised
    # without touching HKLM.
    $script:testRootKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("AtlasPlaybookTests_$PID")
    Initialize-AtlasModule -LogFile $null -ProfileDirectory $configDir -RegistryRoot $script:testRootKey
    $null = Import-AtlasPlan -Path $script:planFixture

    function Get-MainCallIndex {
        param([string]$Content, [string]$Name)
        $mainIndex = $Content.IndexOf('#---------[ Main Execution ]')
        if ($mainIndex -lt 0) { return -1 }
        $pattern = "(?m)^[ \t]+$([regex]::Escape($Name))\b"
        $match = [regex]::Match($Content.Substring($mainIndex), $pattern)
        if (-not $match.Success) { return -1 }
        return $mainIndex + $match.Index
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:planFixture) {
        Remove-Item -LiteralPath $script:planFixture -Force -ErrorAction SilentlyContinue
    }
    if ($script:testRootKey) {
        $script:testRootKey.Dispose()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("AtlasPlaybookTests_$PID", $false)
    }
}

Describe 'Atlas option map' {
    It 'declares every answer the workflow exposes' {
        $keys = @($options.answers | ForEach-Object { $_.key })
        foreach ($expected in @('defender', 'mitigations', 'auto_updates', 'disable_hibernation', 'remove_snipping_tool', 'uninstall_edge')) {
            $keys | Should -Contain $expected
        }
    }

    It 'maps every answer onto an option the playbook declares' {
        # The option names below are the ones Atlas v0.5.0 ships in playbook.conf.
        # If a future playbook renames one, this test is the first thing to fail.
        $known = @(
            'defender-enable', 'defender-disable',
            'mitigations-default', 'mitigations-disable',
            'auto-updates-disable', 'auto-updates-default',
            'disable-hibernation', 'disable-power-saving', 'disable-core-isolation',
            'remove-snipping-tool', 'uninstall-edge', 'install-another-browser',
            'install-toolbox', 'browser-brave', 'browser-librewolf',
            'browser-firefox', 'browser-chrome'
        )

        foreach ($answer in $options.answers) {
            foreach ($property in $answer.options.PSObject.Properties) {
                $known | Should -Contain $property.Value
            }
        }
    }

    It 'has no option that is neither answerable nor explicitly accounted for' {
        $known = @(
            'defender-enable', 'defender-disable',
            'mitigations-default', 'mitigations-disable',
            'auto-updates-disable', 'auto-updates-default',
            'disable-hibernation', 'disable-power-saving', 'disable-core-isolation',
            'remove-snipping-tool', 'uninstall-edge', 'install-another-browser',
            'install-toolbox', 'browser-brave', 'browser-librewolf',
            'browser-firefox', 'browser-chrome'
        )

        $mapped = @()
        foreach ($answer in $options.answers) {
            $mapped += @($answer.options.PSObject.Properties | ForEach-Object { $_.Value })
        }
        $mapped += @($options.fixedOptions.PSObject.Properties | ForEach-Object { $_.Name })
        $mapped += @($options.notApplicable.PSObject.Properties | ForEach-Object { $_.Name })

        # Everything the playbook asks must be answered, fixed, or explained.
        foreach ($option in $known) {
            $mapped | Should -Contain $option
        }
    }
}

Describe 'Atlas registry path mapping' {
    It 'maps HKLM\SOFTWARE onto the image SOFTWARE hive' {
        Convert-AtlasRegistryPath -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' |
            Should -Be 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    }

    It 'maps HKLM\SYSTEM onto the image SYSTEM hive' {
        Convert-AtlasRegistryPath -Path 'HKLM\SYSTEM\ControlSet001\Services\WdBoot' |
            Should -Be 'HKLM\zSYSTEM\ControlSet001\Services\WdBoot'
    }

    It 'rewrites CurrentControlSet, which does not exist in an offline hive' {
        Convert-AtlasRegistryPath -Path 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' |
            Should -Be 'HKLM\zSYSTEM\ControlSet001\Control\Lsa'
    }

    It 'maps the playbook OfflineSys spelling onto SYSTEM' {
        Convert-AtlasRegistryPath -Path 'HKLM\OfflineSys\ControlSet001\Services\WdBoot' |
            Should -Be 'HKLM\zSYSTEM\ControlSet001\Services\WdBoot'
    }

    It 'maps HKLM\COMPONENTS onto the image COMPONENTS hive' {
        Convert-AtlasRegistryPath -Path 'HKLM\COMPONENTS\CanonicalData\Deployments' |
            Should -Be 'HKLM\zCOMPONENTS\CanonicalData\Deployments'
    }

    It 'maps HKCU onto the default-user hive' {
        # The playbook's own APPLYDUHIVE.ps1 replays HKCU writes into the default
        # user hive; offline we write there directly.
        Convert-AtlasRegistryPath -Path 'HKCU\SOFTWARE\Microsoft\Siuf\Rules' |
            Should -Be 'HKLM\zNTUSER\SOFTWARE\Microsoft\Siuf\Rules'
    }

    It 'maps the AME default-user hive onto the same place' {
        Convert-AtlasRegistryPath -Path 'HKU\AME_UserHive_Default\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' |
            Should -Be 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    }

    It 'maps HKCR onto the machine classes hive' {
        Convert-AtlasRegistryPath -Path 'HKCR\.bat\ShellNew' |
            Should -Be 'HKLM\zSOFTWARE\Classes\.bat\ShellNew'
    }

    It 'is case insensitive, because the playbook is not consistent' {
        Convert-AtlasRegistryPath -Path 'HKLM\Software\Microsoft\Windows' |
            Should -Be 'HKLM\zSOFTWARE\Microsoft\Windows'
        Convert-AtlasRegistryPath -Path 'hkcu\Software\Microsoft' |
            Should -Be 'HKLM\zNTUSER\Software\Microsoft'
    }

    It 'returns null for a hive with no offline equivalent' {
        Convert-AtlasRegistryPath -Path 'HKLM\BCDE\Objects' | Should -BeNullOrEmpty
        Convert-AtlasRegistryPath -Path 'HKU\S-1-5-21-1-2-3-1001\Software' | Should -BeNullOrEmpty
    }
}

Describe 'Atlas registry data conversion' {
    It 'converts REG_DWORD from a decimal string, wrapping above Int32.MaxValue' {
        # 4294967295 is 0xFFFFFFFF. RegistryValueKind.DWord is a signed Int32, so the
        # correct representation is -1 - a plain [int] cast would throw on every
        # Atlas value written that way.
        Convert-AtlasRegistryData -Type 'REG_DWORD' -Data '4294967295' | Should -Be -1
    }

    It 'converts REG_DWORD from a hex string' {
        Convert-AtlasRegistryData -Type 'REG_DWORD' -Data '0x1F' | Should -Be 31
    }

    It 'converts a REG_BINARY hex blob into bytes' {
        $bytes = Convert-AtlasRegistryData -Type 'REG_BINARY' -Data '9012038010000000'
        $bytes.Length | Should -Be 8
        $bytes[0] | Should -Be 0x90
        $bytes[7] | Should -Be 0x00
    }

    It 'returns a real byte[] rather than an unrolled object[]' {
        # The first real playbook run failed every binary value with "the type of the
        # value object did not match the specified RegistryValueKind": PowerShell had
        # unrolled the array into the pipeline, so SetValue received object[].
        $bytes = Convert-AtlasRegistryData -Type 'REG_BINARY' -Data '9012038010000000'
        $bytes.GetType().Name | Should -Be 'Byte[]'
        $bytes.Length | Should -Be 8
    }

    It 'returns an empty byte[] for REG_NONE instead of null' {
        # A null value is rejected by SetValue for RegistryValueKind.None.
        $none = Convert-AtlasRegistryData -Type 'REG_NONE' -Data ''
        $none.GetType().Name | Should -Be 'Byte[]'
        $none.Length | Should -Be 0
    }

    It 'returns a real string[] for REG_MULTI_SZ' {
        $multi = Convert-AtlasRegistryData -Type 'REG_MULTI_SZ' -Data "one`0two`0"
        $multi.GetType().Name | Should -Be 'String[]'
        $multi.Length | Should -Be 2
        $multi[0] | Should -Be 'one'
        $multi[1] | Should -Be 'two'
    }

    It 'keeps REG_SZ verbatim, including the %variables% Atlas writes' {
        Convert-AtlasRegistryData -Type 'REG_SZ' -Data '%windir%\System32\acppage.dll' |
            Should -Be '%windir%\System32\acppage.dll'
    }

    It 'returns null data for REG_NONE' {
        Convert-AtlasRegistryData -Type 'REG_NONE' -Data '' | Should -BeNullOrEmpty
    }
}

Describe 'Atlas option resolution' {
    It 'selects the defaults when no answers are supplied' {
        $resolution = Resolve-AtlasOptions -Answers @{}
        $resolution.Selected | Should -Contain 'defender-enable'
        $resolution.Selected | Should -Contain 'mitigations-default'
        $resolution.Selected | Should -Contain 'auto-updates-disable'
        $resolution.Selected | Should -Not -Contain 'defender-disable'
    }

    It 'follows the answers it is given' {
        $resolution = Resolve-AtlasOptions -Answers @{
            defender    = 'disable'
            auto_updates = 'default'
            uninstall_edge = $true
        }
        $resolution.Selected | Should -Contain 'defender-disable'
        $resolution.Selected | Should -Contain 'auto-updates-default'
        $resolution.Selected | Should -Contain 'uninstall-edge'
        $resolution.Selected | Should -Not -Contain 'defender-enable'
    }

    It 'treats a boolean answer given as a string the way the workflow sends it' {
        $resolution = Resolve-AtlasOptions -Answers @{ remove_snipping_tool = 'true' }
        $resolution.Selected | Should -Contain 'remove-snipping-tool'
    }

    It 'throws on an answer value the playbook cannot express' {
        { Resolve-AtlasOptions -Answers @{ defender = 'maybe' } } | Should -Throw
    }

    It 'throws when the playbook no longer declares a mapped option' {
        $broken = Get-Content -LiteralPath $script:planFixture -Raw | ConvertFrom-Json
        $broken.options = @($broken.options | Where-Object { $_.name -ne 'defender-enable' })
        $brokenPath = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-plan-broken-$PID.json"
        $broken | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $brokenPath -Encoding UTF8
        try {
            $null = Import-AtlasPlan -Path $brokenPath
            { Resolve-AtlasOptions -Answers @{} } | Should -Throw
        } finally {
            $null = Import-AtlasPlan -Path $script:planFixture
            Remove-Item -LiteralPath $brokenPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Atlas registry phase' {
    BeforeAll {
        # Everything the applier writes is rooted at the test key, so the paths below
        # are HKCU\AtlasPlaybookTests_<pid>\... rather than HKCU\...
        $script:testPrefix = "HKCU:\AtlasPlaybookTests_$PID"
    }

    It 'writes ungated values, honours option gates, and sets service start types' {
        Invoke-AtlasRegistryPhase -SelectedOptions @('defender-enable')

        $software = "$script:testPrefix\zSOFTWARE\AtlasTest"
        (Get-ItemProperty -LiteralPath $software -Name 'UnGated').UnGated | Should -Be 1

        # The gated value must not exist: uninstall-edge was not selected.
        $gated = Get-Item -LiteralPath $software
        $gated.GetValueNames() | Should -Not -Contain 'Gated'

        # CurrentControlSet was rewritten to ControlSet001 on the way in.
        $system = "$script:testPrefix\zSYSTEM\ControlSet001\Services\AtlasTestSvc"
        (Get-ItemProperty -LiteralPath $system -Name 'Deliberate').Deliberate | Should -Be 7
        (Get-ItemProperty -LiteralPath $system -Name 'Start').Start | Should -Be 4

        # HKU\AME_UserHive_Default lands under the default-user hive.
        Test-Path -LiteralPath "$script:testPrefix\zNTUSER\SOFTWARE\AtlasTestKey" | Should -BeTrue
    }

    It 'applies a gated value once its option is selected' {
        Invoke-AtlasRegistryPhase -SelectedOptions @('defender-enable', 'uninstall-edge')
        (Get-ItemProperty -LiteralPath "$script:testPrefix\zSOFTWARE\AtlasTest" -Name 'Gated').Gated | Should -Be 1
    }
}

Describe 'Atlas folder and Toolbox' {
    BeforeAll {
        # A stand-in for the unpacked playbook and for a mounted image.
        $script:fakePlaybook = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-pb-$PID"
        $script:fakeMount = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-mount-$PID"

        $desktop = Join-Path $script:fakePlaybook 'Executables\AtlasDesktop'
        $modules = Join-Path $script:fakePlaybook 'Executables\AtlasModules'
        $themes = Join-Path $script:fakePlaybook 'Executables\Themes'

        New-Item -ItemType Directory -Force -Path (Join-Path $desktop '9. Troubleshooting') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $desktop '6. Advanced Configuration\Services') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $modules 'Other') | Out-Null
        New-Item -ItemType Directory -Force -Path $themes | Out-Null

        Set-Content -LiteralPath (Join-Path $desktop '9. Troubleshooting\Set services to defaults.cmd') -Value 'rem stub'
        Set-Content -LiteralPath (Join-Path $modules 'Other\atlas-folder.ico') -Value 'ico'
        Set-Content -LiteralPath (Join-Path $themes 'atlas.theme') -Value 'theme'

        New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeMount 'Windows\Resources\Themes') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeMount 'Windows\Setup\Scripts') | Out-Null

        $script:fakeInstaller = Join-Path ([System.IO.Path]::GetTempPath()) "AtlasToolbox-Setup-$PID.exe"
        Set-Content -LiteralPath $script:fakeInstaller -Value 'MZ stub'
    }

    AfterAll {
        foreach ($path in @($script:fakePlaybook, $script:fakeMount)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $script:fakeInstaller) { Remove-Item -LiteralPath $script:fakeInstaller -Force -ErrorAction SilentlyContinue }
    }

    It 'copies AtlasDesktop, AtlasModules and the themes into the image' {
        Invoke-AtlasFolderPhase -MountDir $script:fakeMount -ExtractedPath $script:fakePlaybook

        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\AtlasDesktop\9. Troubleshooting\Set services to defaults.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\AtlasModules\Other\atlas-folder.ico') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\Resources\Themes\atlas.theme') | Should -BeTrue
    }

    It 'does not nest the folder as Windows\Windows' {
        # Copying the directory instead of its contents would produce this.
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\Windows') | Should -BeFalse
    }

    It 'creates the desktop and Start Menu shortcuts' {
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Users\Default\Desktop\Atlas.lnk') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'ProgramData\Microsoft\Windows\Start Menu\Programs\Atlas.lnk') | Should -BeTrue
    }

    It 'puts AtlasModules on the machine PATH without dropping the existing entries' {
        $key = (Get-AtlasRegistryRoot).CreateSubKey('zSYSTEM\ControlSet001\Control\Session Manager\Environment')
        $key.SetValue('Path', '%SystemRoot%\system32;%SystemRoot%', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.Dispose()

        Add-AtlasModulePath

        $key = (Get-AtlasRegistryRoot).OpenSubKey('zSYSTEM\ControlSet001\Control\Session Manager\Environment')
        $path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $key.Dispose()

        # Parenthesised: in command-argument position a bare [regex]::Escape('...') is
        # read as a type literal, not a call.
        $path | Should -Match ([regex]::Escape('%SystemRoot%\system32'))
        $path | Should -Match ([regex]::Escape('%windir%\AtlasModules'))
        $path | Should -Match ([regex]::Escape('%windir%\AtlasModules\Tools'))
        $path | Should -Match ([regex]::Escape('%windir%\AtlasModules\Scripts'))
    }

    It 'is idempotent when the PATH is extended twice' {
        Add-AtlasModulePath
        $key = (Get-AtlasRegistryRoot).OpenSubKey('zSYSTEM\ControlSet001\Control\Session Manager\Environment')
        $path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $key.Dispose()

        ([regex]::Matches($path, [regex]::Escape('%windir%\AtlasModules;'))).Count | Should -Be 1
    }

    It 'stages the Toolbox installer and wires it into SetupComplete.cmd' {
        Invoke-AtlasToolboxPhase -MountDir $script:fakeMount -InstallerPath $script:fakeInstaller

        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\AtlasPlaybook\payload\AtlasToolbox-Setup.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:fakeMount 'Windows\AtlasPlaybook\atlas-firstboot.ps1') | Should -BeTrue

        $setupComplete = Get-Content -LiteralPath (Join-Path $script:fakeMount 'Windows\Setup\Scripts\SetupComplete.cmd') -Raw
        $setupComplete | Should -Match 'atlas-firstboot\.ps1'
    }

    It 'does not add the first-boot line twice' {
        Invoke-AtlasToolboxPhase -MountDir $script:fakeMount -InstallerPath $script:fakeInstaller
        $setupComplete = Get-Content -LiteralPath (Join-Path $script:fakeMount 'Windows\Setup\Scripts\SetupComplete.cmd') -Raw
        ([regex]::Matches($setupComplete, 'atlas-firstboot\.ps1')).Count | Should -Be 1
    }

    It 'keeps an existing SetupComplete.cmd written by the gaming payload' {
        $existing = "rem gaming payload`r`npowershell.exe -File `"C:\Windows\Tiny11Gaming\gaming-firstboot.ps1`"`r`n"
        Set-Content -LiteralPath (Join-Path $script:fakeMount 'Windows\Setup\Scripts\SetupComplete.cmd') -Value $existing -NoNewline
        Invoke-AtlasToolboxPhase -MountDir $script:fakeMount -InstallerPath $script:fakeInstaller

        $setupComplete = Get-Content -LiteralPath (Join-Path $script:fakeMount 'Windows\Setup\Scripts\SetupComplete.cmd') -Raw
        $setupComplete | Should -Match 'gaming-firstboot\.ps1'
        $setupComplete | Should -Match 'atlas-firstboot\.ps1'
    }

    It 'fails loudly when the plan points at an extraction that is gone' {
        { Invoke-AtlasFolderPhase -MountDir $script:fakeMount -ExtractedPath (Join-Path $script:fakeMount 'nope') } |
            Should -Throw
    }
}

Describe 'Atlas return values survive a chatty logger' {
    <#
        The builder's Write-Log emits to the output stream. Every test above ran
        without that function defined, so Write-AtlasLog fell back to Write-Host and
        the module looked fine - while in the real build Import-AtlasPlan returned
        @(log, log, ..., $plan) and the plan was replaced by that array. The build
        then died in Resolve-AtlasOptions with "the array index evaluated to null"
        after 0.0s, which is what sent the first CI run red.

        These tests pin the contract: logging must never enter the pipeline.
    #>

    It 'Write-AtlasLog writes to the host and the log file, never to the pipeline' {
        $logPath = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-log-$PID.log"
        Initialize-AtlasModule -LogFile $logPath -ProfileDirectory $configDir -RegistryRoot $script:testRootKey
        try {
            $captured = Write-AtlasLog 'pipeline check' 'INFO'
            $captured | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $logPath -Raw) | Should -Match 'pipeline check'
        } finally {
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Import-AtlasPlan returns exactly one object even with a Write-Log on the output stream' {
        # Reproduce the builder's logger, which is what broke the return value.
        function global:Write-Log {
            param([string]$Message, [string]$Level = 'INFO')
            Write-Output "[$Level] $Message"
        }
        try {
            $plan = Import-AtlasPlan -Path $script:planFixture
            @($plan).Count | Should -Be 1
            $plan.playbook.version | Should -Be '0.5.0'
        } finally {
            Remove-Item function:global:Write-Log -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolve-AtlasOptions returns exactly one object and a usable Selected list' {
        function global:Write-Log {
            param([string]$Message, [string]$Level = 'INFO')
            Write-Output "[$Level] $Message"
        }
        try {
            $resolution = Resolve-AtlasOptions -Answers @{ defender = 'disable' }
            @($resolution).Count | Should -Be 1
            $resolution.Selected | Should -Contain 'defender-disable'
        } finally {
            Remove-Item function:global:Write-Log -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Atlas wiring' {
    It 'exposes the plan, answers, folder and toolbox on the builder' {
        $builderRaw | Should -Match '\[string\]\$AtlasPlanPath'
        $builderRaw | Should -Match '\[hashtable\]\$AtlasAnswers'
        $builderRaw | Should -Match '\[bool\]\$AtlasInstallFolder'
        $builderRaw | Should -Match '\[string\]\$AtlasToolboxInstaller'
        $builderRaw | Should -Match 'atlas-playbook\.ps1'
    }

    It 'installs the Atlas folder after the hives unload and before the image is dismounted' {
        $folder = Get-MainCallIndex -Content $builderRaw -Name 'Invoke-AtlasFolderPhase'
        $unload = Get-MainCallIndex -Content $builderRaw -Name 'Unload-RegistryHives'
        $dismount = Get-MainCallIndex -Content $builderRaw -Name 'Dismount-AndExport'
        $folder | Should -BeGreaterThan $unload
        $folder | Should -BeLessThan $dismount
    }

    It 'extends the machine PATH while the hives are still loaded' {
        # PATH is a registry value, so it cannot be written after Unload-RegistryHives.
        $path = Get-MainCallIndex -Content $builderRaw -Name 'Add-AtlasModulePath'
        $unload = Get-MainCallIndex -Content $builderRaw -Name 'Unload-RegistryHives'
        $path | Should -BeGreaterThan 0
        $path | Should -BeLessThan $unload
    }

    It 'stages the Toolbox before the image is dismounted' {
        $toolbox = Get-MainCallIndex -Content $builderRaw -Name 'Invoke-AtlasToolboxPhase'
        $dismount = Get-MainCallIndex -Content $builderRaw -Name 'Dismount-AndExport'
        $toolbox | Should -BeGreaterThan 0
        $toolbox | Should -BeLessThan $dismount
    }

    It 'applies the registry phase after every built-in pass and before the hives unload' {
        $atlas = Get-MainCallIndex -Content $builderRaw -Name 'Invoke-AtlasRegistryPhase'
        $unload = Get-MainCallIndex -Content $builderRaw -Name 'Unload-RegistryHives'
        $gaming = Get-MainCallIndex -Content $builderRaw -Name 'Invoke-GamingServiceTweaks'
        $assert = Get-MainCallIndex -Content $builderRaw -Name 'Assert-WindowsUpdateState'

        $atlas | Should -BeGreaterThan 0
        $atlas | Should -BeGreaterThan $gaming
        $atlas | Should -BeGreaterThan $assert
        $atlas | Should -BeLessThan $unload
    }

    It 'runs the AppX phase after the hives are unloaded' {
        $appx = Get-MainCallIndex -Content $builderRaw -Name 'Invoke-AtlasAppxPhase'
        $unload = Get-MainCallIndex -Content $builderRaw -Name 'Unload-RegistryHives'
        $appx | Should -BeGreaterThan $unload
    }

    It 'writes the manifest before the image is dismounted' {
        $manifest = Get-MainCallIndex -Content $builderRaw -Name 'Write-AtlasManifest'
        $dismount = Get-MainCallIndex -Content $builderRaw -Name 'Dismount-AndExport'
        $manifest | Should -BeGreaterThan 0
        $manifest | Should -BeLessThan $dismount
    }

    It 'ships a compiler that exists and compiles' {
        Test-Path -LiteralPath $compilerPath | Should -BeTrue

        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            Set-ItResult -Skipped -Because 'python is not on PATH in this environment'
            return
        }

        & python -c "import sys; print(sys.version)" *> $null
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'the python on PATH is a Windows Store stub'
            return
        }

        & python -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" $compilerPath
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Atlas workflow wiring' {
    BeforeAll {
        $script:workflowText = Get-Content -LiteralPath $workflowPath -Raw

        # Should -Match is not multiline, so an anchored pattern only ever matches
        # the first line. Every check below goes through the same helper.
        function Test-WorkflowMatch {
            param([string]$Pattern)
            return [regex]::IsMatch($script:workflowText, $Pattern, 'Multiline')
        }
    }

    It 'is the Atlas channel' {
        Test-WorkflowMatch '^name: Build and Release Tiny11\+AtlasOS\s*$' | Should -BeTrue
    }

    It 'uses identifiers that cannot collide with the stable Core-Gaming channel' {
        # A run here must never write into the stable release or SourceForge folder.
        Test-WorkflowMatch 'Tiny11Atlas-\$edition-\$version' | Should -BeTrue
        Test-WorkflowMatch '\$buildNumber-atlas-\$\(\$edition\.ToLower\(\)\)' | Should -BeTrue
        Test-WorkflowMatch 'Tiny11Atlas-\$version-\$buildNumber' | Should -BeTrue
        $script:workflowText | Should -Not -Match 'Tiny11CoreGaming-\$edition'
        $script:workflowText | Should -Not -Match 'coregaming-\$\(\$edition'
    }

    It 'declares the Atlas questions as inputs' {
        foreach ($input in @('atlas_playbook', 'atlas_playbook_url', 'atlas_defender', 'atlas_mitigations',
                             'atlas_auto_updates', 'atlas_disable_hibernation',
                             'atlas_remove_snipping_tool', 'atlas_uninstall_edge',
                             'atlas_folder', 'atlas_toolbox')) {
            Test-WorkflowMatch "^\s+${input}:\s*$" |
                Should -BeTrue -Because "the playbook question '$input' must be answerable"
        }
    }

    It 'fetches the Toolbox installer before the builder runs' {
        $fetch = $script:workflowText.IndexOf('Fetch Atlas Toolbox installer')
        $build = $script:workflowText.IndexOf('Run tiny11coremaker')
        $fetch | Should -BeGreaterThan 0
        $fetch | Should -BeLessThan $build
        Test-WorkflowMatch 'atlas-toolbox/releases/latest' | Should -BeTrue
        Test-WorkflowMatch 'AtlasToolbox-Setup\.exe' | Should -BeTrue
    }

    It 'compiles the playbook before the builder runs' {
        $compile = $script:workflowText.IndexOf('atlas-playbook.py')
        $build = $script:workflowText.IndexOf('Run tiny11coremaker')
        $compile | Should -BeGreaterThan 0
        $build | Should -BeGreaterThan 0
        $compile | Should -BeLessThan $build
    }

    It 'passes the plan and the answers to the builder by splat' {
        Test-WorkflowMatch '\$atlasArgs\.AtlasPlanPath' | Should -BeTrue
        Test-WorkflowMatch '\$atlasArgs\.AtlasAnswers' | Should -BeTrue
        # The hashtable only reaches the builder if it is splatted on the call.
        Test-WorkflowMatch 'tiny11coremaker-headless\.ps1 @params @atlasArgs' | Should -BeTrue
    }

    It 'gates the whole layer behind the atlas_playbook toggle' {
        Test-WorkflowMatch "ATLAS_ENABLED -eq 'true'" | Should -BeTrue
        Test-WorkflowMatch "ATLAS_INPUT -eq 'off'" | Should -BeTrue
    }

    It 'stays inside the 25 workflow_dispatch input cap' {
        # GitHub silently refuses to parse a workflow_dispatch with more than 25
        # inputs, which shows up as a workflow named after its file path.
        $block = [regex]::Match($script:workflowText, '(?ms)^\s{2}workflow_dispatch:\s*\r?\n\s{4}inputs:\s*\r?\n(.*?)^\s{2}\w')
        $block.Success | Should -BeTrue
        $count = ([regex]::Matches($block.Groups[1].Value, '(?m)^\s{6}[a-z0-9_]+:\s*$')).Count
        ($count -le 25) | Should -BeTrue -Because "GitHub refuses to parse a workflow_dispatch with $count inputs"
        ($count -ge 20) | Should -BeTrue -Because "the Atlas questions should all be exposed (found $count)"
    }
}
