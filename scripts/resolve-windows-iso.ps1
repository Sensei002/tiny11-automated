<#
.SYNOPSIS
    Resolves a fresh, signed Windows 11 ISO download URL straight from Microsoft.

.DESCRIPTION
    Microsoft's consumer download page does not expose a static URL. The page calls
    an internal API which hands back a *signed* dbazure link carrying a time-limited
    token (?t=...&P1=...&P4=...). Those links expire roughly 24 hours after they are
    generated, which is why a URL pasted into a workflow input goes stale.

    This script drives the same API at run time, so every run mints its own link and
    there is nothing to keep fresh. The request sequence is the one used by Fido
    (https://github.com/pbatard/Fido), the script Rufus ships:

      1. vlscppe.microsoft.com/tags          - whitelists the session id
      2. ov-df.microsoft.com/mdt.js          - hands back w + rticks
      3. ov-df.microsoft.com/                - sends the reply back
      4. getskuinformationbyproductedition   - language -> SKU map
      5. GetProductDownloadLinksBySku        - SKU -> signed ISO URLs

    Steps 1-3 are Microsoft's bot mitigation; skipping them makes step 4 fail.

    Only ONE download-links request is permitted per session, so the session created
    here is spent on the single ISO being resolved. Do not loop over languages
    against one session - mint a new session per ISO.

.PARAMETER Language
    A language exactly as Microsoft's own dropdown spells it, e.g.
    'English (United States)', 'English International', 'German', 'Japanese'.
    Run with -ListLanguages to print every accepted value.

.PARAMETER ProductEditionId
    3813 = Windows 11 26H2 (build 26300.9457) multi-edition ISO, x64.
    (3816 is the same release for ARM64; 3814/3815 are the China SKUs.)

.PARAMETER ListLanguages
    Print the languages Microsoft currently offers for this edition, then exit.

.OUTPUTS
    PSCustomObject with Url, FileName, Language, SkuId, ProductEditionId.

.EXAMPLE
    $iso = & .\scripts\resolve-windows-iso.ps1 -Language 'English (United States)'
    Write-Host $iso.Url
#>
[CmdletBinding()]
param(
    [string]$Language,

    [int]$ProductEditionId = 3813,

    [switch]$ListLanguages
)

$ErrorActionPreference = 'Stop'

# -Language is only optional so that -ListLanguages can be run without it; it is
# still required for an actual resolve. Checked here so we fail before any network I/O.
if (-not $ListLanguages -and [string]::IsNullOrWhiteSpace($Language)) {
    throw "Specify -Language (or use -ListLanguages to see the valid values)."
}

# Constants lifted from Fido.ps1. ProfileId identifies the "consumer Windows 11
# download" flow; InstanceId is the (currently constant) ov-df customer id.
$OrgId      = 'y6jn8c31'
$ProfileId  = '606624d44113'
$InstanceId = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
$Referer    = 'https://www.microsoft.com/software-download/windows11'
$UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

function Invoke-CurlText {
    <#
      curl.exe writes progress/warnings to stderr. Under $ErrorActionPreference='Stop'
      PowerShell 5.1 promotes redirected native stderr into a *terminating* error, so
      the preference is scoped down here for the duration of the call.
    #>
    param([string]$Url, [string]$Referer)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $args = @('-s', '-A', $UserAgent)
        if ($Referer) { $args += @('-e', $Referer) }
        $args += $Url
        return ((& curl.exe @args) -join "`n")
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-CurlQuiet {
    param([string]$Url)
    Invoke-CurlText -Url $Url | Out-Null
}

$session = [guid]::NewGuid().ToString()

# ---- 1) Whitelist the session -------------------------------------------------
Invoke-CurlQuiet "https://vlscppe.microsoft.com/tags?org_id=$OrgId&session_id=$session"

# ---- 2) mdt.js -> w + rticks --------------------------------------------------
$mdt = Invoke-CurlText "https://ov-df.microsoft.com/mdt.js?instanceId=$InstanceId&PageId=si&session_id=$session"
if ($mdt -notmatch '[?&]w=([A-Fa-f0-9]+)') {
    throw "Could not extract 'w' from the ov-df response. Microsoft may have changed their bot check."
}
$w = $Matches[1]
if ($mdt -notmatch 'rticks\s*=\s*"?\+?(\d+)') {
    throw "Could not extract 'rticks' from the ov-df response. Microsoft may have changed their bot check."
}
$rticks = $Matches[1]

# ---- 3) Send the reply back ---------------------------------------------------
$mdtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Invoke-CurlQuiet "https://ov-df.microsoft.com/?session_id=$session&CustomerId=$InstanceId&PageId=si&w=$w&mdt=$mdtMs&rticks=$rticks"

# ---- 4) Language -> SKU -------------------------------------------------------
$skuUrl = 'https://www.microsoft.com/software-download-connector/api/' +
          'getskuinformationbyproductedition' +
          "?profile=$ProfileId&productEditionId=$ProductEditionId" +
          "&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$session"

# This call is occasionally flaky and returns null/Errors; Fido retries it too.
$skuData = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
    try {
        $raw = Invoke-CurlText -Url $skuUrl -Referer $Referer
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -and -not $parsed.Errors -and $parsed.Skus) {
            $skuData = $parsed
            break
        }
        if ($parsed.Errors) {
            Write-Verbose "SKU lookup attempt ${attempt}: $($parsed.Errors[0].Value)"
        }
    } catch {
        Write-Verbose "SKU lookup attempt ${attempt} failed: $($_.Exception.Message)"
    }
}

if (-not $skuData) {
    throw "Could not retrieve the language list from Microsoft (3 attempts). The download service may be rate limiting, or Microsoft changed the API."
}

if ($ListLanguages) {
    $skuData.Skus |
        Sort-Object LocalizedLanguage |
        Select-Object -ExpandProperty LocalizedLanguage
    return
}

# Microsoft's own dropdown shows LocalizedLanguage; Language is an internal alias
# (e.g. LocalizedLanguage 'English International' is Language 'English (United Kingdom)').
# Accept either so the caller can type what the website shows.
$sku = $skuData.Skus |
    Where-Object { $_.LocalizedLanguage -eq $Language -or $_.Language -eq $Language } |
    Select-Object -First 1

if (-not $sku) {
    $valid = ($skuData.Skus | Sort-Object LocalizedLanguage |
              Select-Object -ExpandProperty LocalizedLanguage) -join ', '
    throw "Language '$Language' is not offered for this Windows edition. Valid values: $valid"
}

# ---- 5) SKU -> signed ISO URL -------------------------------------------------
$dlUrl = 'https://www.microsoft.com/software-download-connector/api/' +
         'GetProductDownloadLinksBySku' +
         "?profile=$ProfileId&productEditionId=undefined&SKU=$($sku.Id)" +
         "&friendlyFileName=undefined&Locale=en-US&sessionID=$session"

$dlData = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
    try {
        $raw = Invoke-CurlText -Url $dlUrl -Referer $Referer
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -and -not $parsed.Errors -and $parsed.ProductDownloadOptions) {
            $dlData = $parsed
            break
        }
        if ($parsed.Errors) {
            Write-Verbose "Link lookup attempt ${attempt}: $($parsed.Errors[0].Value)"
        }
    } catch {
        Write-Verbose "Link lookup attempt ${attempt} failed: $($_.Exception.Message)"
    }
}

if (-not $dlData) {
    throw "Could not retrieve a download link for '$Language'. Microsoft's service may be rate limiting; re-running usually clears it."
}

# DownloadType 1 is the x64 ISO. Prefer it explicitly, but fall back to whatever
# came back so a future rename of the type field does not break the build outright.
$option = $dlData.ProductDownloadOptions |
          Where-Object { $_.DownloadType -eq 1 } |
          Select-Object -First 1
if (-not $option) {
    $option = $dlData.ProductDownloadOptions | Select-Object -First 1
}

$uri = $option.Uri
if ([string]::IsNullOrWhiteSpace($uri) -or $uri -notmatch '\.iso') {
    throw "Microsoft returned a link that does not look like an ISO: '$uri'"
}

[pscustomobject]@{
    Url               = $uri
    FileName          = ($uri -split '/')[-1].Split('?')[0]
    Language          = $sku.LocalizedLanguage
    SkuId             = $sku.Id
    ProductEditionId  = $ProductEditionId
}
