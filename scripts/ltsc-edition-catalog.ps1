<#
.SYNOPSIS
    Catalogue of the Windows 11 / Windows 10 IoT Enterprise LTSC editions.

.DESCRIPTION
    Single source of truth for the two LTSC workflows: which editions exist on
    which media, at which index, and how each one is spelled in an ISO file name,
    a release tag and a SourceForge folder.

    The index values mirror Microsoft's LTSC media layout:

      Windows 11 Enterprise LTSC 2024 (build 26100)
        1  Windows 11 Enterprise LTSC
        2  Windows 11 IoT Enterprise LTSC
        3  Windows 11 IoT Enterprise Subscription LTSC

      Windows 10 Enterprise LTSC 2021 (build 19044)
        1  Windows 10 Enterprise LTSC
        2  Windows 10 IoT Enterprise LTSC

    Nothing here is trusted blindly. Both LTSC workflows re-read the mounted ISO
    with Get-WindowsImage and match on the image NAME, then build with the index
    the ISO actually reports. A reordered Microsoft release therefore produces a
    warning and a correct build, not the wrong edition.

    Dot-source this file to use it:

        . .\scripts\ltsc-edition-catalog.ps1
        $edition = Resolve-LTSCEdition -Name 'Windows 11 IoT Enterprise LTSC'

    Running it directly prints the catalogue.

.EXAMPLE
    .\scripts\ltsc-edition-catalog.ps1

.NOTES
    Author: kelexine (https://github.com/kelexine)
    License: MIT
#>

function Get-LTSCEditionCatalog {
    # Ordered on purpose: the dropdown in both workflows lists these in the same
    # order, so a build log reads top to bottom like the ISO's own image table.
    return @(
        [pscustomobject]@{
            Name      = 'Windows 11 Enterprise LTSC'
            Index     = 1
            Family    = 'Windows 11'
            Release   = '2024'
            Build     = '26100'
            Slug      = 'EnterpriseLTSC'
            TagSuffix = 'ltsc-win11-enterprise'
            Note      = 'The plain Enterprise LTSC image. No IoT feature set, no subscription activation.'
        }
        [pscustomobject]@{
            Name      = 'Windows 11 IoT Enterprise LTSC'
            Index     = 2
            Family    = 'Windows 11'
            Release   = '2024'
            Build     = '26100'
            Slug      = 'IoTEnterpriseLTSC'
            TagSuffix = 'ltsc-win11-iot-enterprise'
            Note      = 'IoT feature set, no subscription. The usual choice for a debloated desktop build.'
        }
        [pscustomobject]@{
            Name      = 'Windows 11 IoT Enterprise Subscription LTSC'
            Index     = 3
            Family    = 'Windows 11'
            Release   = '2024'
            Build     = '26100'
            Slug      = 'IoTEnterpriseSubscriptionLTSC'
            TagSuffix = 'ltsc-win11-iot-enterprise-subscription'
            Note      = 'IoT feature set with subscription activation. Needs a subscription licence to stay activated.'
        }
        [pscustomobject]@{
            Name      = 'Windows 10 Enterprise LTSC'
            Index     = 1
            Family    = 'Windows 10'
            Release   = '2021'
            Build     = '19044'
            Slug      = 'EnterpriseLTSC'
            TagSuffix = 'ltsc-win10-enterprise'
            Note      = 'Windows 10 LTSC 2021, build 19044. Service ends January 2027.'
        }
        [pscustomobject]@{
            Name      = 'Windows 10 IoT Enterprise LTSC'
            Index     = 2
            Family    = 'Windows 10'
            Release   = '2021'
            Build     = '19044'
            Slug      = 'IoTEnterpriseLTSC'
            TagSuffix = 'ltsc-win10-iot-enterprise'
            Note      = 'Windows 10 IoT LTSC 2021. Service ends January 2032.'
        }
    )
}

function ConvertTo-NormalizedEditionName {
    <#
    .SYNOPSIS
        Reduces an edition name to the part that identifies the SKU.

    .DESCRIPTION
        DISM reports the same SKU under slightly different spellings depending on
        the media: 'Windows 10 Enterprise LTSC 2021' on the ISO, 'Windows 10
        Enterprise LTSC' in the catalogue. Stripping the 'Windows NN ' prefix and
        a trailing release year makes the two compare equal without loosening the
        match enough to confuse Enterprise with IoT Enterprise.

        The order matters. 'Enterprise LTSC' is a substring of 'IoT Enterprise
        LTSC', so a substring test would happily install the IoT image when the
        plain one was asked for. This produces an exact comparison instead:
            enterprise ltsc
            iot enterprise ltsc
            iot enterprise subscription ltsc

        -KeepFamily exists because dropping the OS token collapses the Windows 10
        and Windows 11 catalogues together: 'Windows 10 Enterprise LTSC 2021' and
        'Windows 11 Enterprise LTSC' both normalize to 'enterprise ltsc'. That is
        fine when comparing against the images on one ISO (an ISO only ever holds
        one family), and wrong when resolving a name against the whole catalogue.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name,

        [switch]$KeepFamily
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $normalized = $Name.Trim().ToLowerInvariant()
    if (-not $KeepFamily) {
        $normalized = $normalized -replace '^windows\s+(?:10|11)\s+', ''
    }
    $normalized = $normalized -replace '\s+20\d{2}$', ''
    $normalized = $normalized -replace '\s+', ' '
    return $normalized.Trim()
}

function Get-LTSCEditionFamily {
    <#
    .SYNOPSIS
        The 'Windows 10' / 'Windows 11' family an edition name belongs to, or ''
        when the name does not carry one.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name -match '^\s*windows\s+(10|11)\b') { return "Windows $($Matches[1])" }
    return ''
}

function Test-LTSCEditionName {
    <#
    .SYNOPSIS
        True when two edition names refer to the same LTSC SKU.

    .DESCRIPTION
        Two conditions, both required:
          1. the SKU part matches exactly after normalization, and
          2. the OS family does not contradict itself.

        Check 2 is what stops a Windows 11 ISO being accepted for a Windows 10
        request. It is skipped when either name carries no family token, so a
        caller passing a bare SKU still works.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual
    )

    $left = ConvertTo-NormalizedEditionName -Name $Expected
    $right = ConvertTo-NormalizedEditionName -Name $Actual
    if (-not $left -or -not $right -or ($left -ne $right)) { return $false }

    $expectedFamily = Get-LTSCEditionFamily -Name $Expected
    $actualFamily = Get-LTSCEditionFamily -Name $Actual
    if ($expectedFamily -and $actualFamily -and ($expectedFamily -ne $actualFamily)) {
        return $false
    }

    return $true
}

function Resolve-LTSCEdition {
    <#
    .SYNOPSIS
        Maps a catalogue name onto its index, family, release and naming slugs.

    .DESCRIPTION
        Accepts the exact catalogue name, or any spelling that normalizes to it
        while keeping the OS family (so 'Windows 10 Enterprise LTSC 2021' resolves
        to the LTSC 2021 entry, not the Windows 11 one). Throws with the full list
        of valid names when nothing matches, because a typo here would otherwise
        surface as a wrong-edition build an hour later.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $catalog = Get-LTSCEditionCatalog

    $exact = $catalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($exact) { return $exact }

    $normalized = ConvertTo-NormalizedEditionName -Name $Name -KeepFamily
    $loose = $catalog |
        Where-Object { (ConvertTo-NormalizedEditionName -Name $_.Name -KeepFamily) -eq $normalized } |
        Select-Object -First 1
    if ($loose) { return $loose }

    $valid = ($catalog | ForEach-Object { "  - $($_.Name)" }) -join [Environment]::NewLine
    throw "Unknown LTSC edition '$Name'. Valid editions are:$([Environment]::NewLine)$valid"
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host 'LTSC editions'
    Write-Host '============='
    Get-LTSCEditionCatalog |
        Format-Table Family, Release, Index, Name, Slug, TagSuffix -AutoSize |
        Out-String |
        Write-Host
}
