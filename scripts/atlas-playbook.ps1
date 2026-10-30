# Offline applier for an AtlasOS playbook plan.
#
# Author: Sensei002 (https://github.com/Sensei002)
# License: MIT
#
# The Atlas playbook is written for the AME Wizard, which runs on a *live* Windows
# install: it kills explorer, loads the default-user hive from C:\Users\Default,
# starts services and runs scripts from the Atlas folder. None of that exists in CI,
# where the target is an install.wim mounted by DISM. This module executes the part
# of the playbook that is declarative - registry values and keys, service start
# types, and provisioned AppX packages - against the mounted image's own hives.
#
# Path mapping is the whole trick. The playbook writes to the live machine:
#
#   HKLM\SOFTWARE\...        -> HKLM\zSOFTWARE\...      (the image's SOFTWARE hive)
#   HKLM\SYSTEM\...          -> HKLM\zSYSTEM\...        (the image's SYSTEM hive)
#   HKLM\COMPONENTS\...      -> HKLM\zCOMPONENTS\...
#   HKLM\OfflineSys\...      -> the hive named after OfflineSys (playbook's own
#                               ISO-mode spelling, used by exactly one action)
#   HKCU\...                 -> HKLM\zNTUSER\...        (the image's default-user hive)
#   HKU\AME_UserHive_Default -> HKLM\zNTUSER\...
#   HKCR\...                 -> HKLM\zSOFTWARE\Classes\...
#
# The z* names are the builder's convention (see Load-RegistryHives in
# tiny11coremaker-headless.ps1); the applier assumes they are already loaded and
# never loads or unloads a hive itself.
#
# Two verbs are deliberately not executed here and are reported instead:
#   !powerShell / !cmd / !run / !taskKill  - need a running system
#   !scheduledTask                          - needs the Task Scheduler service
# They are counted in the build manifest so the coverage gap is visible rather than
# silently swallowed.

Set-StrictMode -Version Latest

$script:AtlasLogFile = $null
$script:AtlasPlan = $null
$script:AtlasConfig = $null
$script:AtlasStats = $null
$script:AtlasRegistryRoot = $null

function Get-AtlasRegistryRoot {
    # Everything the applier writes lands under one root. Production uses HKLM,
    # where the builder's z* hives are loaded; the tests point it at HKCU so the
    # real write path can be exercised without touching the machine.
    if ($null -eq $script:AtlasRegistryRoot) {
        $script:AtlasRegistryRoot = [Microsoft.Win32.Registry]::LocalMachine
    }
    return $script:AtlasRegistryRoot
}

function Initialize-AtlasModule {
    param(
        [string]$LogFile,
        [string]$ProfileDirectory,
        $RegistryRoot
    )

    $script:AtlasLogFile = $LogFile
    if ($RegistryRoot) { $script:AtlasRegistryRoot = $RegistryRoot }

    if (-not $ProfileDirectory) {
        $ProfileDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'config'
    }
    $configPath = Join-Path $ProfileDirectory 'atlas_options.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Atlas option map not found at $configPath"
    }
    $script:AtlasConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

    $script:AtlasStats = @{
        RegistryApplied = 0
        RegistryFailed  = 0
        KeysApplied     = 0
        ServicesApplied = 0
        AppxRemoved     = 0
        AppxAbsent      = 0
        AppxFailed      = 0
        SkippedByOption = 0
        SkippedByArch   = 0
        SkippedVerb     = 0
        UnmappedPaths   = 0
    }
}

function Write-AtlasLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # Write-Host, deliberately, and never Write-Output or the builder's Write-Log.
    #
    # The builder's Write-Log emits to the output stream, so a function here that
    # logs and then returns a value would hand its caller the log lines in front of
    # the value. That is not theoretical: Import-AtlasPlan returned
    # @(log, log, ..., $plan), the caller's $atlasPlan aliased $script:AtlasPlan
    # (variable names are case-insensitive), and the plan was replaced by an array -
    # which then failed deep inside Resolve-AtlasOptions with "the array index
    # evaluated to null". Host output cannot be captured by accident.
    Write-Host $line

    if ($script:AtlasLogFile) {
        Add-Content -LiteralPath $script:AtlasLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Get-AtlasField {
    # StrictMode-safe property read: a PSCustomObject throws on a missing property,
    # and half of these fields are optional in the playbook schema.
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Import-AtlasPlan {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Atlas plan not found at $Path"
    }

    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $actions = @(Get-AtlasField $plan 'actions')
    if ($actions.Count -eq 0) {
        throw "Atlas plan $Path contains no actions - refusing to continue"
    }

    $script:AtlasPlan = $plan
    Write-AtlasLog "Atlas plan loaded: $($plan.playbook.name) $($plan.playbook.version) ($($actions.Count) action(s))"
    return $plan
}

function Resolve-AtlasOptions {
    <#
        Turns the workflow's answers into the set of playbook option names.

        The playbook names its answers in its own vocabulary (defender-enable,
        auto-updates-disable, ...). Keeping the translation in config/atlas_options.json
        means a workflow input can be renamed without touching code, and - more
        importantly - a playbook that renames an option fails the build here instead
        of silently applying the wrong branch.
    #>
    param([hashtable]$Answers)

    if ($null -eq $script:AtlasPlan) {
        throw "Import-AtlasPlan must run before Resolve-AtlasOptions"
    }
    if ($null -eq $Answers) { $Answers = @{} }

    $declared = @{}
    foreach ($option in @(Get-AtlasField $script:AtlasPlan 'options')) {
        $optionName = Get-AtlasField $option 'name'
        if ([string]::IsNullOrWhiteSpace($optionName)) {
            # Guard, not decoration: indexing a hashtable with $null reports
            # "the array index evaluated to null", which says nothing about the
            # real problem. This only fires if the plan is malformed.
            throw "Atlas plan contains an option with no name: $($option | Out-String)"
        }
        $declared[$optionName] = $true
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $resolved = [ordered]@{}

    foreach ($answer in @($script:AtlasConfig.answers)) {
        $key = $answer.key
        $value = $Answers[$key]

        if ($null -eq $value -or "$value" -eq '') {
            $value = $answer.default
        }

        if ($answer.type -eq 'boolean') {
            $flag = "$value".Trim().ToLowerInvariant()
            $isOn = $flag -in @('true', '1', 'yes', 'on')
            $resolved[$key] = $isOn
            if (-not $isOn) { continue }
            $optionName = $answer.options.'true'
        } else {
            $resolved[$key] = "$value"
            $optionName = Get-AtlasField $answer.options "$value"
            if (-not $optionName) {
                $allowed = (@($answer.options.PSObject.Properties | ForEach-Object { $_.Name })) -join ', '
                throw "Atlas answer '$key' = '$value' is not one of: $allowed"
            }
        }

        if (-not $declared.ContainsKey($optionName)) {
            throw "Atlas playbook does not declare the option '$optionName' (answer '$key'). The playbook changed its vocabulary - update config/atlas_options.json."
        }

        if (-not $selected.Contains($optionName)) { $selected.Add($optionName) }
    }

    Write-AtlasLog "Atlas options selected: $(if ($selected.Count) { $selected -join ', ' } else { '(none)' })"

    foreach ($fixed in $script:AtlasConfig.PSObject.Properties['fixedOptions'].Value.PSObject.Properties) {
        Write-AtlasLog "Atlas option '$($fixed.Name)' is fixed: $($fixed.Value)"
    }
    foreach ($na in $script:AtlasConfig.PSObject.Properties['notApplicable'].Value.PSObject.Properties) {
        Write-AtlasLog "Atlas option '$($na.Name)' is not applied: $($na.Value)"
    }

    return @{
        Selected = $selected.ToArray()
        Answers  = $resolved
    }
}

function Test-AtlasActionEnabled {
    param(
        $Action,
        [string[]]$SelectedOptions
    )

    $required = @(Get-AtlasField $Action 'options')
    foreach ($option in $required) {
        if ($option -and ($SelectedOptions -notcontains $option)) { return $false }
    }

    # cpuArch gates a handful of tweaks per architecture. The image is always amd64,
    # so an Arm64 action must not run.
    $arch = Get-AtlasField $Action 'cpuArch'
    if ($arch) {
        $normalised = "$arch".ToLowerInvariant()
        if ($normalised -notin @('x64', 'amd64', 'x86')) {
            $script:AtlasStats.SkippedByArch++
            return $false
        }
    }

    return $true
}

function Convert-AtlasRegistryPath {
    <#
        Maps a playbook registry path onto the mounted image's loaded hive.
        Returns $null when the path targets something that has no offline equivalent.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimmed = $Path.Trim()
    $separator = $trimmed.IndexOf('\')
    if ($separator -lt 1) { return $null }

    $root = $trimmed.Substring(0, $separator).ToUpperInvariant()
    $rest = $trimmed.Substring($separator + 1)

    switch ($root) {
        { $_ -in @('HKLM', 'HKEY_LOCAL_MACHINE') } {
            $split = $rest.IndexOf('\')
            if ($split -lt 1) { return $null }
            $hive = $rest.Substring(0, $split).ToUpperInvariant()
            $tail = $rest.Substring($split + 1)

            switch ($hive) {
                'SOFTWARE'   { return "HKLM\zSOFTWARE\$tail" }
                'COMPONENTS' { return "HKLM\zCOMPONENTS\$tail" }
                'SYSTEM' {
                    # An offline hive has no CurrentControlSet symlink; every builder
                    # pass in this repo writes ControlSet001, so pin it.
                    $tail = [regex]::Replace($tail, '(?i)^CurrentControlSet\\', 'ControlSet001\')
                    return "HKLM\zSYSTEM\$tail"
                }
                'OFFLINESYS' {
                    # The playbook's own ISO-mode spelling, e.g.
                    # HKLM\OfflineSys\ControlSet001\Services\WdBoot
                    $innerSplit = $tail.IndexOf('\')
                    if ($innerSplit -lt 1) { return $null }
                    $innerHiveRaw = $tail.Substring(0, $innerSplit)
                    $innerHive = $innerHiveRaw.ToUpperInvariant()
                    $innerTail = $tail.Substring($innerSplit + 1)
                    switch ($innerHive) {
                        'SOFTWARE'   { return "HKLM\zSOFTWARE\$innerTail" }
                        'COMPONENTS' { return "HKLM\zCOMPONENTS\$innerTail" }
                        'SYSTEM'     { return "HKLM\zSYSTEM\$innerTail" }
                        default {
                            # ControlSet001 keeps its original spelling: the hive is
                            # case-insensitive, but a manifest that reads
                            # CONTROLSET001 is harder to match against the builder.
                            $innerTail = [regex]::Replace($innerTail, '(?i)^CurrentControlSet\\', 'ControlSet001\')
                            return "HKLM\zSYSTEM\$innerHiveRaw\$innerTail"
                        }
                    }
                }
                default { return $null }
            }
        }
        { $_ -in @('HKCU', 'HKEY_CURRENT_USER') } {
            # Offline there is no logged-on user; the playbook's own APPLYDUHIVE.ps1
            # copies its HKCU writes into the default-user hive, so write there
            # directly and skip the replay.
            return "HKLM\zNTUSER\$rest"
        }
        { $_ -in @('HKU', 'HKEY_USERS') } {
            if ($rest -match '(?i)^AME_UserHive_Default\\(.*)$') {
                return "HKLM\zNTUSER\$($Matches[1])"
            }
            return $null
        }
        { $_ -in @('HKCR', 'HKEY_CLASSES_ROOT') } {
            # HKCR is a merged view; the machine half is what an offline image can
            # carry, and every HKCR action in the playbook is a machine-wide shell
            # registration (ShellNew, context-menu handlers, CLSID entries).
            return "HKLM\zSOFTWARE\Classes\$rest"
        }
        default { return $null }
    }
}

function Convert-AtlasRegistryData {
    <#
        Converts a playbook `data:` string into the CLR type SetValue expects.

        Every array return is wrapped in the comma operator. Without it PowerShell
        unrolls the array into the pipeline, so a byte[] arrives at the caller as
        object[] (and an empty byte[] arrives as $null) - which is exactly the
        "type of the value object did not match the specified RegistryValueKind"
        failure this hit on the first real playbook run.
    #>
    param(
        [string]$Type,
        $Data
    )

    $text = if ($null -eq $Data) { '' } else { "$Data" }

    switch ($Type.ToUpperInvariant()) {
        'REG_DWORD' {
            # RegistryValueKind.DWord is a signed Int32, so 0xFFFFFFFF has to arrive
            # as -1. Atlas writes a few of those (and a few 4294967295s) and a plain
            # [int] cast would throw on every one of them.
            if ($text -match '^0x[0-9a-fA-F]+$') { $number = [Convert]::ToUInt32($text.Substring(2), 16) }
            elseif ($text -eq '') { return [int]0 }
            elseif ($text.StartsWith('-')) { return [int]$text }
            else { $number = [uint32]$text }
            return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$number), 0)
        }
        'REG_QWORD' {
            if ($text -match '^0x[0-9a-fA-F]+$') { $wide = [Convert]::ToUInt64($text.Substring(2), 16) }
            elseif ($text -eq '') { return [long]0 }
            elseif ($text.StartsWith('-')) { return [long]$text }
            else { $wide = [uint64]$text }
            return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$wide), 0)
        }
        'REG_BINARY' {
            $hex = $text -replace '[^0-9a-fA-F]', ''
            if ($hex.Length -eq 0) { return , ([byte[]]@()) }
            if ($hex.Length % 2 -ne 0) { $hex = '0' + $hex }
            # [int] matters: PowerShell's / yields a double, and byte[]::new with a
            # double does not produce a Byte[] that SetValue accepts.
            $length = [int]($hex.Length / 2)
            $bytes = [byte[]]::new($length)
            for ($i = 0; $i -lt $length; $i++) {
                $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
            }
            return , $bytes
        }
        'REG_MULTI_SZ' {
            if ($text -eq '') { return , ([string[]]@()) }
            return , ([string[]]($text -split "`0" | Where-Object { $_ -ne '' }))
        }
        'REG_NONE' {
            # A REG_NONE value has no payload - Atlas uses it as a marker on the
            # "Unpinned" quick actions and the Autoplay handlers. SetValue rejects a
            # null value for this kind, so an empty byte array is what goes in.
            return , ([byte[]]@())
        }
        default { return $text }
    }
}

function Get-AtlasRegistryKind {
    param([string]$Type)
    switch ($Type.ToUpperInvariant()) {
        'REG_SZ'        { return [Microsoft.Win32.RegistryValueKind]::String }
        'REG_EXPAND_SZ' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'REG_MULTI_SZ'  { return [Microsoft.Win32.RegistryValueKind]::MultiString }
        'REG_DWORD'     { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'REG_QWORD'     { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'REG_BINARY'    { return [Microsoft.Win32.RegistryValueKind]::Binary }
        'REG_NONE'      { return [Microsoft.Win32.RegistryValueKind]::None }
        default         { return [Microsoft.Win32.RegistryValueKind]::String }
    }
}

function Invoke-AtlasRegistryPhase {
    <#
        Applies every registry-shaped action. Runs while the image hives are loaded,
        so the builder calls it immediately before Unload-RegistryHives.
    #>
    param(
        [string[]]$SelectedOptions = @()
    )

    if ($null -eq $script:AtlasPlan) { throw "Import-AtlasPlan must run first" }

    Write-AtlasLog "Applying Atlas registry actions..."

    foreach ($action in @(Get-AtlasField $script:AtlasPlan 'actions')) {
        $kind = Get-AtlasField $action 'kind'
        if ($kind -ne 'registry') { continue }

        $verb = Get-AtlasField $action 'action'
        $source = Get-AtlasField $action 'file'

        if (-not (Test-AtlasActionEnabled -Action $action -SelectedOptions $SelectedOptions)) {
            if ((@(Get-AtlasField $action 'options')).Count -gt 0) {
                $script:AtlasStats.SkippedByOption++
            }
            continue
        }

        if ($verb -eq 'service') {
            $name = Get-AtlasField $action 'name'
            $operation = Get-AtlasField $action 'operation'
            if ($operation -ne 'change') {
                # 'stop'/'start' only mean something on a running system. The start
                # type still gets set by the 'change' entries for the same service.
                $script:AtlasStats.SkippedVerb++
                continue
            }
            $startup = Get-AtlasField $action 'startup'
            $servicePath = "HKLM\zSYSTEM\ControlSet001\Services\$name"
            try {
                $key = (Get-AtlasRegistryRoot).CreateSubKey(
                    $servicePath.Substring('HKLM\'.Length))
                $key.SetValue('Start', [int]$startup, [Microsoft.Win32.RegistryValueKind]::DWord)
                $key.Dispose()
                $script:AtlasStats.ServicesApplied++
            } catch {
                Write-AtlasLog "  service $name : $($_.Exception.Message)" 'WARN'
            }
            continue
        }

        $rawPath = Get-AtlasField $action 'path'
        $mapped = Convert-AtlasRegistryPath -Path $rawPath
        if (-not $mapped) {
            $script:AtlasStats.UnmappedPaths++
            Write-AtlasLog "  unmapped registry path skipped: $rawPath ($source)" 'WARN'
            continue
        }

        $operation = Get-AtlasField $action 'operation'
        $subKey = $mapped.Substring('HKLM\'.Length)

        try {
            if ($verb -eq 'registryKey') {
                if ($operation -eq 'delete') {
                    (Get-AtlasRegistryRoot).DeleteSubKeyTree($subKey, $false)
                } else {
                    $key = (Get-AtlasRegistryRoot).CreateSubKey($subKey)
                    $key.Dispose()
                }
                $script:AtlasStats.KeysApplied++
                continue
            }

            if ($verb -ne 'registryValue') { continue }

            $valueName = Get-AtlasField $action 'value'
            if ($null -eq $valueName) { $valueName = '' }

            if ($operation -eq 'delete') {
                $key = (Get-AtlasRegistryRoot).OpenSubKey($subKey, $true)
                if ($key) {
                    try { $key.DeleteValue($valueName, $false) } finally { $key.Dispose() }
                }
                $script:AtlasStats.RegistryApplied++
                continue
            }

            $type = Get-AtlasField $action 'type'
            if (-not $type) { $type = 'REG_SZ' }

            $data = Convert-AtlasRegistryData -Type $type -Data (Get-AtlasField $action 'data')
            $kind = Get-AtlasRegistryKind -Type $type

            $key = (Get-AtlasRegistryRoot).CreateSubKey($subKey)
            try {
                $key.SetValue($valueName, $data, $kind)
            } finally {
                $key.Dispose()
            }
            $script:AtlasStats.RegistryApplied++
        } catch {
            $script:AtlasStats.RegistryFailed++
            Write-AtlasLog "  registry action failed: $mapped\$valueName ($source): $($_.Exception.Message)" 'WARN'
        }
    }

    Write-AtlasLog ("Atlas registry pass: {0} value(s), {1} key(s), {2} service(s), {3} failed" -f `
        $script:AtlasStats.RegistryApplied, $script:AtlasStats.KeysApplied, `
        $script:AtlasStats.ServicesApplied, $script:AtlasStats.RegistryFailed)
}

function Get-AtlasProvisionedPackages {
    param([Parameter(Mandatory = $true)][string]$MountDir)

    $output = & dism.exe /English /Image:$MountDir /Get-ProvisionedAppxPackages 2>&1
    if ($LASTEXITCODE -ne 0) {
        $reason = ($output | Where-Object { "$_" -match '\S' } | Select-Object -Last 1)
        throw "DISM could not list provisioned packages: $reason"
    }

    $packages = @()
    foreach ($line in $output) {
        if ("$line" -match '^\s*PackageName\s*:\s*(\S+)\s*$') {
            $packages += $Matches[1]
        }
    }
    return , $packages
}

function Invoke-AtlasAppxPhase {
    <#
        Removes provisioned AppX packages named by the plan.

        DISM package operations must not race a loaded hive (the builder documents
        the same rule for its own passes), so this runs after Unload-RegistryHives.

        Packages are matched against the image's own provisioned list first: a Core
        image has already dropped most of them, and issuing 40 DISM removals that all
        fail on "not found" would hide a real failure in the noise.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MountDir,
        [string[]]$SelectedOptions = @()
    )

    if ($null -eq $script:AtlasPlan) { throw "Import-AtlasPlan must run first" }

    $wanted = @()
    foreach ($action in @(Get-AtlasField $script:AtlasPlan 'actions')) {
        if ((Get-AtlasField $action 'kind') -ne 'appx') { continue }
        if (-not (Test-AtlasActionEnabled -Action $action -SelectedOptions $SelectedOptions)) {
            if ((@(Get-AtlasField $action 'options')).Count -gt 0) {
                $script:AtlasStats.SkippedByOption++
            }
            continue
        }
        $wanted += [pscustomobject]@{
            Pattern = "$(Get-AtlasField $action 'name')"
            Source  = Get-AtlasField $action 'file'
        }
    }

    if ($wanted.Count -eq 0) { return }

    Write-AtlasLog "Applying Atlas AppX removals ($($wanted.Count) pattern(s))..."

    $present = @()
    $enumerated = $false
    try {
        $present = Get-AtlasProvisionedPackages -MountDir $MountDir
        $enumerated = $true
    } catch {
        Write-AtlasLog "  could not enumerate provisioned packages: $($_.Exception.Message)" 'WARN'
    }

    if (-not $enumerated) {
        # A failed listing is not the same as an empty image: report it as failed
        # rather than quietly claiming every package was already gone.
        $script:AtlasStats.AppxFailed += $wanted.Count
        return
    }

    $toRemove = @{}
    foreach ($item in $wanted) {
        $pattern = $item.Pattern
        # A family name such as 'MicrosoftTeams*' matches the provisioned package
        # name 'MicrosoftTeams_1.0.0.0_neutral_~_8wekyb3d8bbwe' by prefix, which is
        # exactly what the playbook's `type: family` means.
        $matches = @($present | Where-Object { $_ -like $pattern })
        if ($matches.Count -eq 0) {
            $script:AtlasStats.AppxAbsent++
            continue
        }
        foreach ($match in $matches) { $toRemove[$match] = $pattern }
    }

    foreach ($package in $toRemove.Keys) {
        $result = & dism.exe /English /Image:$MountDir /Remove-ProvisionedAppxPackage /PackageName:$package 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:AtlasStats.AppxRemoved++
            Write-AtlasLog "  removed provisioned package $package"
        } else {
            $script:AtlasStats.AppxFailed++
            $reason = ($result | Where-Object { "$_" -match '\S' } | Select-Object -Last 1)
            Write-AtlasLog "  could not remove $package : $reason" 'WARN'
        }
    }

    Write-AtlasLog ("Atlas AppX pass: {0} removed, {1} already absent, {2} failed" -f `
        $script:AtlasStats.AppxRemoved, $script:AtlasStats.AppxAbsent, $script:AtlasStats.AppxFailed)
}

function Add-AtlasModulePath {
    <#
        Puts AtlasModules on the machine PATH, the way the playbook's start.yml does.

        Must run while the image hives are loaded, which is why it is a separate call
        from Invoke-AtlasFolderPhase: the files can be copied at any point, but this is
        a registry write.
    #>
    param([string[]]$Entries = @('%windir%\AtlasModules', '%windir%\AtlasModules\Tools', '%windir%\AtlasModules\Scripts'))

    $keyPath = 'zSYSTEM\ControlSet001\Control\Session Manager\Environment'
    try {
        $key = (Get-AtlasRegistryRoot).CreateSubKey($keyPath)
        try {
            # DoNotExpandEnvironmentNames: the existing PATH is stored unexpanded and
            # must be written back the same way, or every %SystemRoot% in it becomes a
            # hard-coded C:\Windows.
            $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $parts = @($current -split ';' | Where-Object { $_ -ne '' })

            $added = @()
            foreach ($entry in $Entries) {
                if ($parts -notcontains $entry) { $parts += $entry; $added += $entry }
            }

            if ($added.Count -gt 0) {
                $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                Write-AtlasLog "  PATH += $($added -join '; ')"
            } else {
                Write-AtlasLog "  PATH already contains the Atlas entries"
            }
        } finally {
            $key.Dispose()
        }
    } catch {
        Write-AtlasLog "  could not extend PATH: $($_.Exception.Message)" 'WARN'
    }
}

function New-AtlasShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$IconLocation,
        [string]$Description
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
        if ($Description) { $shortcut.Description = $Description }
        $shortcut.Save()
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Invoke-AtlasFolderPhase {
    <#
        Copies the Atlas folder into the image: AtlasDesktop, AtlasModules and the
        theme files, plus the Desktop / Start Menu shortcuts that point at it.

        This is what custom.yml does on a live install (`Copy-Item AtlasDesktop,
        AtlasModules -Destination $windir`). Doing it offline means the folder is
        present from first boot, so the Atlas toggles are usable without ever running
        the AME Wizard.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MountDir,
        [Parameter(Mandatory = $true)][string]$ExtractedPath
    )

    $executables = Join-Path $ExtractedPath 'Executables'
    if (-not (Test-Path -LiteralPath $executables)) {
        throw "Atlas folder not found at $executables - the extracted playbook is missing"
    }

    $windowsDir = Join-Path $MountDir 'Windows'

    foreach ($folder in @('AtlasDesktop', 'AtlasModules')) {
        $source = Join-Path $executables $folder
        if (-not (Test-Path -LiteralPath $source)) {
            Write-AtlasLog "  $folder is missing from the playbook - skipped" 'WARN'
            continue
        }
        $destination = Join-Path $windowsDir $folder
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        # Copy the contents, not the directory: Windows already exists, so copying
        # the folder itself would nest it as Windows\Windows\AtlasDesktop.
        Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
        $count = @(Get-ChildItem -LiteralPath $destination -Recurse -File).Count
        Write-AtlasLog "  $folder -> Windows\$folder ($count file(s))"
    }

    $themes = Join-Path $executables 'Themes'
    if (Test-Path -LiteralPath $themes) {
        $themeTarget = Join-Path $windowsDir 'Resources\Themes'
        New-Item -ItemType Directory -Path $themeTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $themes '*') -Destination $themeTarget -Recurse -Force
        Write-AtlasLog "  Themes -> Windows\Resources\Themes"
    }

    # Shortcuts. The .lnk files point at C:\Windows\... because that is where the
    # folder lands on the installed system; they are written here, not resolved here.
    $icon = 'C:\Windows\AtlasModules\Other\atlas-folder.ico,0'
    $targets = @(
        (Join-Path $MountDir 'Users\Default\Desktop\Atlas.lnk'),
        (Join-Path $MountDir 'ProgramData\Microsoft\Windows\Start Menu\Programs\Atlas.lnk')
    )
    foreach ($shortcutPath in $targets) {
        try {
            New-AtlasShortcut -Path $shortcutPath -TargetPath 'C:\Windows\AtlasDesktop' `
                -IconLocation $icon -Description 'AtlasOS folder'
            Write-AtlasLog "  shortcut: $(Split-Path -Leaf (Split-Path -Parent $shortcutPath))"
        } catch {
            Write-AtlasLog "  could not create $shortcutPath : $($_.Exception.Message)" 'WARN'
        }
    }

    # SHORTCUTS.ps1 also drops a services-restore shortcut inside the folder. Only
    # create it when the target script is really there.
    $servicesScript = Join-Path $windowsDir 'AtlasDesktop\9. Troubleshooting\Set services to defaults.cmd'
    if (Test-Path -LiteralPath $servicesScript) {
        try {
            New-AtlasShortcut `
                -Path (Join-Path $windowsDir 'AtlasDesktop\6. Advanced Configuration\Services\Set services to defaults.lnk') `
                -TargetPath 'C:\Windows\AtlasDesktop\9. Troubleshooting\Set services to defaults.cmd' `
                -Description 'Restore the default Windows services'
        } catch {
            Write-AtlasLog "  could not create the services-restore shortcut: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Invoke-AtlasToolboxPhase {
    <#
        Stages the official Atlas Toolbox installer and runs it at first boot.

        The playbook installs Toolbox by downloading AtlasToolbox-Setup.exe and
        running it silently - impossible against a mounted image, because an Inno
        Setup installer writes to the live %ProgramFiles%, registry and Start Menu.
        The installer is therefore baked into the image and executed by
        SetupComplete.cmd, which runs elevated as SYSTEM before the first logon, so
        Toolbox is already there the first time anyone signs in.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MountDir,
        [Parameter(Mandatory = $true)][string]$InstallerPath
    )

    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "Atlas Toolbox installer not found at $InstallerPath"
    }

    $payloadDir = Join-Path $MountDir 'Windows\AtlasPlaybook\payload'
    New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

    $staged = Join-Path $payloadDir 'AtlasToolbox-Setup.exe'
    Copy-Item -LiteralPath $InstallerPath -Destination $staged -Force
    $sizeMB = [math]::Round((Get-Item -LiteralPath $staged).Length / 1MB, 1)
    Write-AtlasLog "  staged Atlas Toolbox installer (${sizeMB}MB)"

    $firstBoot = @'
# Installs the Atlas Toolbox that was staged into this image.
#
# Written by tiny11-automated. Runs once from SetupComplete.cmd, elevated as SYSTEM,
# before the first logon. Inno Setup's silent switches are the ones Atlas itself
# uses in AtlasModules\Scripts\installToolbox.ps1.
$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\AtlasPlaybook\atlas-firstboot.log'

function Write-Log([string]$Message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Out-File -FilePath $log -Append -Encoding UTF8
}

$setup = 'C:\Windows\AtlasPlaybook\payload\AtlasToolbox-Setup.exe'

try {
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-Log "installer missing at $setup - nothing to do"
        exit 0
    }
    if (Test-Path -LiteralPath 'C:\Program Files\Atlas Toolbox\AtlasToolbox.exe') {
        Write-Log 'Atlas Toolbox is already installed'
    } else {
        Write-Log 'installing Atlas Toolbox'
        $process = Start-Process -FilePath $setup `
            -ArgumentList '/verysilent', '/install', '/norestart', '/MERGETASKS="desktopicon"' `
            -Wait -PassThru
        Write-Log "installer exited with $($process.ExitCode)"
    }
} catch {
    Write-Log "failed: $($_.Exception.Message)"
}

# The installer is 55MB and has done its job; do not carry it in the image.
Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
'@

    $firstBootPath = Join-Path $MountDir 'Windows\AtlasPlaybook\atlas-firstboot.ps1'
    $firstBoot | Out-File -LiteralPath $firstBootPath -Encoding UTF8
    Write-AtlasLog "  staged Windows\AtlasPlaybook\atlas-firstboot.ps1"

    # SetupComplete.cmd is the only offline hook that is guaranteed to run elevated
    # before the first logon. The gaming payload appends to the same file, so this
    # has to append too rather than overwrite.
    $setupScriptsDir = Join-Path $MountDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $setupScriptsDir -Force | Out-Null
    $setupComplete = Join-Path $setupScriptsDir 'SetupComplete.cmd'

    $existing = ''
    if (Test-Path -LiteralPath $setupComplete) {
        $existing = Get-Content -LiteralPath $setupComplete -Raw
    }
    if ($existing -notmatch 'atlas-firstboot\.ps1') {
        $line = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "C:\Windows\AtlasPlaybook\atlas-firstboot.ps1"'
        $payload = (@('@echo off', $line, 'exit /b 0') -join "`r`n") + "`r`n"
        ($existing + $payload) | Out-File -LiteralPath $setupComplete -Encoding ASCII -Force
        Write-AtlasLog "  SetupComplete.cmd -> runs atlas-firstboot.ps1"
    } else {
        Write-AtlasLog "  SetupComplete.cmd already runs atlas-firstboot.ps1"
    }
}

function Write-AtlasManifest {
    <#
        Drops a readable report inside the image so the person running the finished
        ISO can see exactly what the Atlas layer did - and, just as importantly, what
        it could not do offline.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MountDir,
        [Parameter(Mandatory = $true)][string]$SelectedOptions,
        $ResolvedAnswers,
        [bool]$FolderInstalled = $false,
        [bool]$ToolboxStaged = $false
    )

    $directory = Join-Path $MountDir 'Windows\AtlasPlaybook'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $playbook = $script:AtlasPlan.playbook
    $stats = $script:AtlasStats

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# AtlasOS playbook layer')
    $lines.Add('')
    $lines.Add('Applied offline by tiny11-automated while the image was mounted.')
    $lines.Add('')
    $lines.Add('## Playbook')
    $lines.Add('')
    $lines.Add("- Name: $($playbook.name) $($playbook.version)")
    $lines.Add("- Source: $($playbook.source)")
    $lines.Add("- SHA256: $($playbook.sha256)")
    $lines.Add("- Image build: $($playbook.imageBuild)")
    if ($playbook.addedBuild) {
        $lines.Add("- Build gate: $($playbook.addedBuild) was added to SupportedBuilds for this image (the playbook did not ship it)")
    }
    $lines.Add('')
    $lines.Add('## Options')
    $lines.Add('')
    if ("$SelectedOptions".Trim() -eq '') {
        $lines.Add('- (none selected)')
    } else {
        foreach ($option in ($SelectedOptions -split ',')) {
            $lines.Add("- $($option.Trim())")
        }
    }
    $lines.Add('')
    $lines.Add('## Applied')
    $lines.Add('')
    $lines.Add("| Kind | Count |")
    $lines.Add("|------|-------|")
    $lines.Add("| Registry values | $($stats.RegistryApplied) |")
    $lines.Add("| Registry keys | $($stats.KeysApplied) |")
    $lines.Add("| Service start types | $($stats.ServicesApplied) |")
    $lines.Add("| Provisioned AppX packages removed | $($stats.AppxRemoved) |")
    $lines.Add("| AppX already absent | $($stats.AppxAbsent) |")
    $lines.Add('')
    $lines.Add('## Not applied')
    $lines.Add('')
    $lines.Add('The playbook also contains actions that only mean something on a running')
    $lines.Add('Windows install. They were not executed:')
    $lines.Add('')
    $skipped = Get-AtlasField $script:AtlasPlan 'skipped'
    $byTag = @{}
    foreach ($item in @($skipped)) {
        $tag = Get-AtlasField $item 'tag'
        if (-not $byTag.ContainsKey($tag)) { $byTag[$tag] = 0 }
        $byTag[$tag]++
    }
    foreach ($tag in ($byTag.Keys | Sort-Object)) {
        $lines.Add("- ``!$tag`` x$($byTag[$tag])")
    }
    $lines.Add('')
    $lines.Add('## Atlas folder')
    $lines.Add('')
    if ($FolderInstalled) {
        $lines.Add('Installed at `C:\Windows\AtlasDesktop` and `C:\Windows\AtlasModules`,')
        $lines.Add('with the theme files in `C:\Windows\Resources\Themes`.')
        $lines.Add('')
        $lines.Add('An **Atlas** shortcut sits on the default user''s desktop and in the')
        $lines.Add('Start Menu, and `%windir%\AtlasModules` plus its `Tools` and `Scripts`')
        $lines.Add('subfolders are on the machine PATH, so the Atlas cmdlets resolve in any')
        $lines.Add('shell.')
    } else {
        $lines.Add('Not installed - the in-Windows toggles that normally ship with Atlas')
        $lines.Add('are absent from this build.')
    }
    $lines.Add('')
    $lines.Add('## Atlas Toolbox')
    $lines.Add('')
    if ($ToolboxStaged) {
        $lines.Add('The official installer is staged in `C:\Windows\AtlasPlaybook\payload`')
        $lines.Add('and run once by `SetupComplete.cmd` before the first logon, so Toolbox')
        $lines.Add('is present the first time anyone signs in. The log is at')
        $lines.Add('`C:\Windows\AtlasPlaybook\atlas-firstboot.log`.')
    } else {
        $lines.Add('Not staged.')
    }
    $lines.Add('')
    $lines.Add('Tweaks applied here are baked into the image. The Atlas folder can undo')
    $lines.Add('most of them after install; anything it does not cover needs a rebuild.')
    $lines.Add('')

    $target = Join-Path $directory 'ATLAS_PLAYBOOK.md'
    $lines -join "`r`n" | Out-File -LiteralPath $target -Encoding UTF8
    Write-AtlasLog "Atlas manifest written to $target"
}

function Get-AtlasStats {
    return $script:AtlasStats
}
