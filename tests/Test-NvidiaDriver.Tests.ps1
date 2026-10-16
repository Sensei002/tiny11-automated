<#
.SYNOPSIS
    Unit tests for the clean-room NVIDIA driver builder (scripts/nvidia-driver-builder.ps1)
    and the ISO injection switch on the headless builder.

    The builder executes its whole build at load time, so its internals cannot be
    dot-sourced directly. The function definitions are therefore lifted out of the
    file with the PowerShell AST, which also guarantees the param() block and the
    Main block never run.

    Author: kelexine (https://github.com/kelexine)
    Run: Invoke-Pester ./tests/Test-NvidiaDriver.Tests.ps1
#>

BeforeAll {
    $repoRoot    = Split-Path $PSScriptRoot -Parent
    $builderPath = Join-Path $repoRoot 'scripts\nvidia-driver-builder.ps1'
    $headlessPath = Join-Path $repoRoot 'scripts\tiny11coremaker-headless.ps1'
    $profilePath = Join-Path $repoRoot 'config\nvidia_driver_profile.json'
    $workflowPath = Join-Path $repoRoot '.github\workflows\build-tiny11-core-gaming-experimental.yml'

    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "nvidia-driver-builder.ps1 has parse errors" }
    foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($f.Extent.Text))
    }

    $script:DriverVersion = '582.28'
    $script:InfsTweaked   = 0
    $script:ConfigFile    = $profilePath
    $script:OutputDir     = Join-Path ([System.IO.Path]::GetTempPath()) ("nvdrv-" + [guid]::NewGuid().ToString('N'))
    $script:WorkDir       = $script:OutputDir
    $script:LogFile       = Join-Path $script:OutputDir 'test.log'
    New-Item -ItemType Directory -Force -Path $script:OutputDir | Out-Null

    function New-SyntheticInf {
        param([Parameter(Mandatory = $true)][string]$Directory)
        $inf = Join-Path $Directory 'nv_dispi.inf'
        @'
[Version]
Signature="$Windows NT$"

[Manufacturer]
%NVIDIA_A% = NVIDIA_Devices,NTamd64.10.0...17134

[NVIDIA_Devices.NTamd64.10.0...17134]
%NVIDIA_DEV.1380% = Section005, PCI\VEN_10DE&DEV_1380
%NVIDIA_DEV.1382% = Section006, PCI\VEN_10DE&DEV_1382

[Section005]
AddReg = nv_commonBase_addreg__01

[Section005.HW]
AddReg = nv_msiSupport_addreg

[Section006]
AddReg = nv_commonBase_addreg__01

[Section006.HW]
AddReg = nv_msiSupport_addreg

[NvDisplayContainer_ServiceInstall]
AddReg = NvDisplayContainer_ServiceInstall_AddReg
ServiceBinary = %13%\Display.NvContainer\NVDisplay.Container.exe

[Strings]
NVIDIA_A = "NVIDIA"
'@ | Set-Content -LiteralPath $inf -Encoding ASCII
        return $inf
    }

    function Get-InfSectionBody {
        param([string]$Text, [string]$Name)
        $out = @(); $cap = $false
        foreach ($l in ($Text -split "`r?`n")) {
            if ($l -match '^\s*\[(.+?)\]\s*$') { $cap = ($Matches[1] -eq $Name); continue }
            if ($cap) { $out += $l }
        }
        return ($out -join "`n")
    }
}

AfterAll {
    if ($script:OutputDir -and (Test-Path $script:OutputDir)) {
        Remove-Item $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'NVIDIA driver profile' {
    It 'parses and identifies itself' {
        $nv = Import-NvidiaProfile
        $nv.profile | Should -Be 'nvidia-debloated-driver'
        $nv.schemaVersion | Should -Be '2.0.0'
    }

    It 'keeps only Display.Driver' {
        $nv = Import-NvidiaProfile
        @($nv.components.keepFolders) | Should -Contain 'Display.Driver'
        @($nv.components.keepFolders).Count | Should -Be 1
    }

    It 'has a display INF glob that covers the per-family INFs' {
        $nv = Import-NvidiaProfile
        $nv.components.displayInfGlob | Should -Be 'nv*.inf'
        'nvami.inf' | Should -Match 'nv*.inf'
        'nv_dispi.inf' | Should -Match 'nv*.inf'
    }

    It 'defines the four registry tweak groups with five AddReg entries' {
        $nv = Import-NvidiaProfile
        @($nv.tweaks.addReg).Count | Should -Be 4
        ($nv.tweaks.addReg | ForEach-Object { $_.entries }).Count | Should -Be 5
    }
}

Describe 'Driver URL resolution' {
    It 'builds a URL for every template and branch' {
        $nv = Import-NvidiaProfile
        $urls = @(Get-DriverDownloadUrl -NvProfile $nv)
        $urls.Count | Should -Be 6
        $urls[0] | Should -Be 'https://us.download.nvidia.com/Windows/582.28/582.28-desktop-win10-win11-64bit-international-dch-whql.exe'
    }

    It 'leaves no placeholder tokens behind' {
        $nv = Import-NvidiaProfile
        ($urls = @(Get-DriverDownloadUrl -NvProfile $nv)) -join ' ' | Should -Not -Match '\{'
    }
}

Describe 'Package sanity check' {
    It 'rejects a small text file' {
        $f = Join-Path $script:OutputDir 'notadriver.txt'
        'hello' | Set-Content -LiteralPath $f
        Test-LooksLikeDriverPackage -Path $f -MinBytes 104857600 | Should -BeFalse
    }

    It 'rejects an MZ file that is too small to be a driver' {
        $f = Join-Path $script:OutputDir 'small.exe'
        [System.IO.File]::WriteAllBytes($f, [byte[]](0x4D, 0x5A, 0x00, 0x00))
        Test-LooksLikeDriverPackage -Path $f -MinBytes 104857600 | Should -BeFalse
    }
}

Describe 'Component pruning' {
    It 'removes everything except the keep-list and the root installers' {
        $nv = Import-NvidiaProfile
        $dir = Join-Path $script:OutputDir 'extract'
        foreach ($d in @('Display.Driver', 'PhysX', 'NvTelemetry', 'NvApp', 'HDAudio')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dir $d) | Out-Null
            'x' | Set-Content -LiteralPath (Join-Path $dir "$d\payload.bin")
        }
        'setup' | Set-Content -LiteralPath (Join-Path $dir 'setup.exe')
        'notes' | Set-Content -LiteralPath (Join-Path $dir 'EULA.txt')

        $removed = Remove-NvidiaComponents -ExtractDir $dir -NvProfile $nv
        $removed | Should -Be 4

        $left = @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object { $_.Name })
        $left.Count | Should -Be 1
        $left[0] | Should -Be 'Display.Driver'
        Test-Path (Join-Path $dir 'setup.exe') | Should -BeFalse
        Test-Path (Join-Path $dir 'EULA.txt') | Should -BeTrue
    }
}

Describe 'INF tweak injection' {
    BeforeEach {
        $script:infDir = Join-Path $script:OutputDir ("inf-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:infDir | Out-Null
        $script:infPath = New-SyntheticInf -Directory $script:infDir
        $script:nv = Import-NvidiaProfile
    }

    It 'follows the Manufacturer -> models -> DDInstall chain, not the section name' {
        # The real NVIDIA INF names its install sections [Section001]..[Section0NN], so a
        # DDInstall/nv_/install name filter would miss almost all of them. This INF uses
        # the same naming to prove the chain is followed instead.
        $wired = Set-NvidiaInfTweaks -DriverDir $script:infDir -NvProfile $script:nv
        $wired | Should -Be 4   # Section005, Section005.HW, Section006, Section006.HW
    }

    It 'appends the tweak section and wires it into the DDInstall sections' {
        $null = Set-NvidiaInfTweaks -DriverDir $script:infDir -NvProfile $script:nv
        $text = (Get-Content -LiteralPath $script:infPath -Raw) -replace "`r", ''
        $text | Should -Match '\[Tiny11NvidiaTweaks\]'
        $text | Should -Match '(?m)^AddReg=Tiny11NvidiaTweaks$'
        (Get-InfSectionBody $text 'Section005')     | Should -Match 'Tiny11NvidiaTweaks'
        (Get-InfSectionBody $text 'Section005.HW')  | Should -Match 'Tiny11NvidiaTweaks'
    }

    It 'does not touch a service-install section' {
        $null = Set-NvidiaInfTweaks -DriverDir $script:infDir -NvProfile $script:nv
        $text = (Get-Content -LiteralPath $script:infPath -Raw) -replace "`r", ''
        (Get-InfSectionBody $text 'NvDisplayContainer_ServiceInstall') | Should -Not -Match 'Tiny11NvidiaTweaks'
    }

    It 'writes exactly the five registry values' {
        $null = Set-NvidiaInfTweaks -DriverDir $script:infDir -NvProfile $script:nv
        $text = (Get-Content -LiteralPath $script:infPath -Raw) -replace "`r", ''
        ([regex]::Matches($text, '0x00010001')).Count | Should -Be 5
        $text | Should -Match 'MSISupported,0x00010001,1'
        $text | Should -Match 'DisableTelemetry,0x00010001,1'
        $text | Should -Match 'DisableHDAudioSleepTimer,0x00010001,1'
        $text | Should -Match 'RMHdcpKeyglobZero,0x00010001,1'
    }

    It 'leaves the original INF content intact' {
        $null = Set-NvidiaInfTweaks -DriverDir $script:infDir -NvProfile $script:nv
        $text = Get-Content -LiteralPath $script:infPath -Raw
        $text | Should -Match 'nv_commonBase_addreg__01'
        $text | Should -Match 'PCI\\VEN_10DE&DEV_1380'
    }

    It 'tweaks EVERY display INF, not just the first' {
        # A DCH package ships dozens of per-family INFs; missing any one of them means
        # those GPUs silently keep the untouched driver.
        $multi = Join-Path $script:OutputDir ("multi-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $multi | Out-Null
        foreach ($n in @('nv_dispi.inf', 'nvami.inf', 'nvcli.inf')) {
            Copy-Item -LiteralPath $script:infPath -Destination (Join-Path $multi $n) -Force
        }
        $total = Set-NvidiaInfTweaks -DriverDir $multi -NvProfile $script:nv
        $total | Should -Be 12   # 4 sections x 3 INFs
        foreach ($n in @('nv_dispi.inf', 'nvami.inf', 'nvcli.inf')) {
            (Get-Content -LiteralPath (Join-Path $multi $n) -Raw) | Should -Match '\[Tiny11NvidiaTweaks\]'
        }
    }
}

Describe 'Driver build report' {
    It 'emits a parseable report describing the produced driver' {
        $dir = Join-Path $script:OutputDir 'report-driver'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $null = New-SyntheticInf -Directory $dir
        'bin' | Set-Content -LiteralPath (Join-Path $dir 'nvlddmkm.sys')

        $rep = Export-NvidiaDriverReport -DriverDir $dir -RemovedFolders 16 -TweaksWired 4 -Resigned $false -CertPath $null
        $rep.success | Should -BeTrue
        $rep.tweaks_wired | Should -Be 4
        $rep.display_inf_count | Should -Be 1
        Test-Path (Join-Path $script:OutputDir 'nvidia-driver-buildinfo.json') | Should -BeTrue
    }
}

Describe 'ISO injection switch' {
    It 'declares an optional -NvidiaDriverPath parameter on the headless builder' {
        $text = Get-Content -LiteralPath $headlessPath -Raw
        $text | Should -Match '\[string\]\$NvidiaDriverPath'
    }

    It 'injects before WinSxS optimization' {
        $text = Get-Content -LiteralPath $headlessPath -Raw
        $injectAt = $text.IndexOf('Add-NvidiaDriverToImage -DriverPath')
        $winsxsAt = $text.IndexOf('Optimize-WinSxS', $injectAt)
        $injectAt | Should -BeGreaterThan 0
        $winsxsAt | Should -BeGreaterThan $injectAt
    }
}

Describe 'Experimental workflow wiring' {
    It 'exposes the NVIDIA driver version input' {
        $text = Get-Content -LiteralPath $workflowPath -Raw
        $text | Should -Match 'nvidia_driver_version:'
    }

    It 'gates the driver build on a non-empty input' {
        $text = Get-Content -LiteralPath $workflowPath -Raw
        $text | Should -Match "if:.*github\.event\.inputs\.nvidia_driver_version != ''"
    }

    It 'uses hashtable splatting, never array splatting' {
        # Array splatting binds positionally and silently mis-binds named parameters.
        $text = Get-Content -LiteralPath $workflowPath -Raw
        $text | Should -Match '& \.\\scripts\\nvidia-driver-builder\.ps1 @params'
        $text | Should -Not -Match 'nvidia-driver-builder\.ps1 @builderArgs'
    }
}
