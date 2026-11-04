# FISH service address dispatch (single source of truth) - 2026-10-04 / 2026-10-06
#
# WHY: Cloudflare Quick Tunnel gives a RANDOM trycloudflare.com subdomain on every
#      reboot. That address used to be baked into the APK, so every reboot broke all
#      installed apps and forced a new release.
# HOW: this script writes the CURRENT public address into config/client-config.json
#      (the single source of truth) and mirrors it into site/client-config.json.
#      Apps fetch that file from a list of FIXED bootstrap sources (see below) at
#      startup, so a tunnel address change needs NO new APK.
#
# 2026-10-06 changes (address discovery resilience):
#   * `candidates` now ALWAYS lists the ngrok fixed domain plus the current tunnel,
#     so a client never loses the other one when the first one dies.
#   * new optional field `preferred` = the address that must win WHENEVER it probes OK.
#     Quick-tunnel domains change on every reboot; the ngrok fixed domain does not.
#     Pure "fastest wins" would promote today's temporary tunnel to the main entrance
#     and lose it again on the next restart. So: preferred (ngrok) while it is alive,
#     otherwise fastest-of-the-rest.
#   * bootstrap is no longer a single URL: the app tries, in order,
#     1) Gitee raw  2) <candidate>/site/client-config.json (self-hosted, no 3rd party)
#     3) jsDelivr mirror  4) GitHub raw. This script is what feeds source (2).
#   * self check now also verifies the self-hosted copy at <url>/site/client-config.json.
#
# Touches ONLY fish resources (config/client-config.json / D:\fish\site / scripts/tmp).
# NEVER touches OtherProject-* containers, services or ports (3000/5432/6379).
#
# ASCII comments only: Windows PowerShell 5.1 reads .ps1 as ANSI unless a BOM is
# present, and a mis-decoded lead byte can swallow the following newline and break
# parsing (same lesson as OtherProject deploy/scripts/nssm-install.ps1, 2026-09-19).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\scripts\publish-address.ps1
#   ... -Url https://api-fish.example.com                # future fixed domain / Frp tunnel
#   ... -Candidates "https://a.example.com","http://192.168.1.145:3100"
#   ... -Preferred https://<your-tunnel-domain>
#   ... -NoNgrok                                         # do not add the ngrok candidate
#   ... -DryRun                                          # print commands, write nothing
#
# After a successful run: nothing manual is required any more (the old "paste the JSON
# into GitHub" step is kept only as an optional extra mirror, see footer).

[CmdletBinding()]
param(
    [string]   $Url = '',
    [string[]] $Candidates = @(),
    [string]   $Source = '',
    # Address that wins whenever it probes OK. Defaults to the ngrok fixed domain when
    # the current public url is a Cloudflare quick tunnel (the usual situation).
    [string]   $Preferred = '',
    # Extra candidates appended verbatim (e.g. a LAN address for on-site debugging).
    [string[]] $ExtraCandidates = @(),
    # The ngrok fixed domain. Empty string = do not add it to candidates.
    [string]   $NgrokDomain = 'https://<your-tunnel-domain>',
    [switch]   $NoNgrok,
    [string]   $BootstrapUrl = 'https://raw.githubusercontent.com/kslingyun/fish-endpoint/main/client-config.json',
    [switch]   $DryRun,
    [switch]   $Quiet
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$configDir  = Join-Path $repoRoot 'config'
$configFile = Join-Path $configDir 'client-config.json'
$siteDir    = Join-Path $repoRoot 'site'
$siteFile   = Join-Path $siteDir 'client-config.json'
$tunnelLog  = Join-Path $repoRoot 'infra\data\logs\fish-tunnel-error.log'
$urlCache   = Join-Path $PSScriptRoot 'tmp\.tunnel-url'

function Write-Step($msg) { if (-not $Quiet) { Write-Host $msg } }

# Write UTF-8 WITHOUT BOM, on both Windows PowerShell 5.1 and PowerShell 7.
# (-Encoding utf8NoBOM exists only in 7; 5.1's "UTF8" adds a BOM, and a BOM makes
#  jsonDecode / strict JSON parsers unhappy.)
function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $enc)
}

# Normalise any input to "<scheme>://<host>[/api/v1]" form used inside the JSON.
function Normalize-ApiBase {
    param([string]$Raw)
    $c = $Raw.Trim().TrimEnd('/')
    if (-not $c) { return '' }
    if ($c -match '/api/v1$') { return $c } else { return $c + '/api/v1' }
}

# Bare origin (no /api/v1) - used when comparing "is this the ngrok domain?".
function Get-Origin {
    param([string]$ApiBase)
    return ($ApiBase -replace '/api/v1$', '')
}

# ---------------------------------------------------------------- 1. resolve current address
function Resolve-CurrentUrl {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit.Trim().TrimEnd('/') }

    # (a) pm2 log: authoritative, the tunnel process prints its own address
    $found = ''
    try {
        $log = & pm2 logs fish-tunnel --lines 400 --nostream 2>$null | Out-String
        $m = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($m.Count -gt 0) { $found = $m[$m.Count - 1].Value }
    } catch { $found = '' }

    # (b) cloudflared log file (fallback when pm2 is unavailable)
    if (-not $found -and (Test-Path $tunnelLog)) {
        $m = [regex]::Matches((Get-Content $tunnelLog -Raw), 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($m.Count -gt 0) { $found = $m[$m.Count - 1].Value }
    }

    # (c) cached address file
    if (-not $found -and (Test-Path $urlCache)) { $found = (Get-Content $urlCache -Raw).Trim() }

    if (-not $found) {
        throw "Cannot determine current public address: pass -Url explicitly, or check that fish-tunnel is running (pm2 logs fish-tunnel)"
    }
    return $found.TrimEnd('/')
}

$publicUrl = Resolve-CurrentUrl -Explicit $Url
$apiBase   = Normalize-ApiBase $publicUrl
$wsBase    = $publicUrl
$isQuickTunnel = $publicUrl -match 'trycloudflare\.com'

# ---------------------------------------------------------------- 2. build the candidate list
# Order expresses preference for TIES only; the real preference knob is `preferred`.
$candidateList = New-Object System.Collections.Generic.List[string]
function Add-Candidate([string]$c) {
    $n = Normalize-ApiBase $c
    if ($n -and -not $candidateList.Contains($n)) { [void]$candidateList.Add($n) }
}

# (1) current live tunnel first (so a "dumb" consumer that only reads candidates[0] still works)
Add-Candidate $apiBase
# (2) the ngrok fixed domain - stable identity of the service
if (-not $NoNgrok -and $NgrokDomain) { Add-Candidate $NgrokDomain }
# (3) caller supplied candidates
foreach ($c in $Candidates) { Add-Candidate $c }
# (4) extra candidates (LAN etc.)
foreach ($c in $ExtraCandidates) { Add-Candidate $c }

# preferred = the address that must win whenever it probes OK.
if (-not $Preferred) {
    if ($isQuickTunnel -and -not $NoNgrok -and $NgrokDomain) {
        $Preferred = $NgrokDomain
    } else {
        $Preferred = $publicUrl
    }
}
$preferredBase = Normalize-ApiBase $Preferred
# preferred MUST be inside candidates, otherwise clients ignore it (see AddressBootstrap.preferred)
Add-Candidate $preferredBase

if (-not $Source) {
    if ($isQuickTunnel) { $Source = 'cloudflare-quick-tunnel+ngrok-fixed' }
    elseif ($publicUrl -match '^http://192\.168\.') { $Source = 'lan' }
    else { $Source = 'fixed-endpoint' }
}

# ---------------------------------------------------------------- 3. build the JSON payload
$comment = 'FISH service address dispatch file (single source of truth). Fields: ' +
           'api = current API base (/api/v1) - the safe single answer; ' +
           'ws = Socket.IO base; ' +
           'candidates = probed in parallel; ' +
           'preferred = wins whenever it probes OK (ngrok fixed domain while alive, ' +
           'because quick-tunnel domains change on every reboot); ' +
           'updatedAt = dispatch time; source = origin. ' +
           'Generated by scripts/publish-address.ps1. Never put secrets here.'
$payload = [ordered]@{
    '_comment'   = $comment
    'api'        = $apiBase
    'ws'         = $wsBase
    'preferred'  = $preferredBase
    'candidates' = @($candidateList)
    'updatedAt'  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    'source'     = $Source
}
$json = $payload | ConvertTo-Json -Depth 4

Write-Step "== FISH address dispatch =="
Write-Step ("  public url    : " + $publicUrl)
Write-Step ("  api base      : " + $apiBase)
Write-Step ("  preferred     : " + $preferredBase + $(if ($isQuickTunnel) { "  (quick tunnel is live -> ngrok stays preferred for when its quota resets)" } else { "" }))
Write-Step ("  candidates    : " + ($candidateList -join ' , '))
Write-Step ("  config file   : " + $configFile)
Write-Step ("  site mirror   : " + $siteFile + "  (served at /site/client-config.json)")
Write-Step ("  bootstrap url : " + $BootstrapUrl + "  (one of 4 sources now; see app_address.dart)")

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] commands that WOULD run (nothing written):"
    Write-Host ("  Set-Content -Path '" + $configFile + "' -Value <JSON> -Encoding utf8NoBOM")
    Write-Host ("  Copy-Item   -Path '" + $configFile + "' -Destination '" + $siteFile + "' -Force")
    Write-Host ("  Set-Content -Path '" + $urlCache + "' -Value '" + $publicUrl + "' -Encoding utf8NoBOM")
    Write-Host ("  GET " + $apiBase + "/health  (must be HTTP 200 + FISH unified response)")
    Write-Host ("  GET " + $publicUrl + "/site/client-config.json  (must be HTTP 200 + this JSON)")
    Write-Host ""
    Write-Host "[DryRun] JSON that WOULD be written:"
    Write-Host $json
    return
}

# ---------------------------------------------------------------- 4. write + sync to site
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
Write-Utf8NoBom -Path $configFile -Value $json

# site is hosted by the same origin as the backend: dropping the same JSON into site/
# makes it readable at /site/client-config.json with ZERO backend change.
# THIS is the "self-hosted bootstrap" leg: it needs no third-party account at all.
if (Test-Path $siteDir) {
    Copy-Item -Path $configFile -Destination $siteFile -Force
    Write-Step ("  synced        : " + $siteFile + " (served at /site/client-config.json)")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $urlCache) | Out-Null
Write-Utf8NoBom -Path $urlCache -Value $publicUrl

# ---------------------------------------------------------------- 5. self check
# MUST carry the ngrok skip header + a non-browser UA (reproduced 2026-10-04):
# the ngrok free plan answers a browser-looking request with an interstitial page
# ("You are about to visit <domain>") that is **HTTP 200** with Content-Type
# text/plain - the body is not our JSON at all. The old check only looked at the
# status code, so it printed a whole line of interstitial text and still counted as
# a PASS. That is the classic false positive this block now rules out.
$skipHeaders = @{ 'ngrok-skip-browser-warning' = 'true' }
$probeUa = 'fish-tunnel-check/1.0'
$ok = $false
try {
    $r = Invoke-WebRequest -Uri ($apiBase + '/health') -UseBasicParsing -TimeoutSec 10 `
            -Headers $skipHeaders -UserAgent $probeUa
    $bodyText = [string]$r.Content
    # Two criteria: status code AND the body really is the FISH unified response
    # (code=0 and data.services.database present).
    $isOurs = $false
    try {
        $parsed = $bodyText.Trim().TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ("$($parsed.code)" -eq '0' -and "$($parsed.data.services.database)" -ne '') { $isOurs = $true }
    } catch { $isOurs = $false }
    if ($r.StatusCode -eq 200 -and $isOurs) {
        $ok = $true
        $head = [Math]::Min(90, $bodyText.Length)
        Write-Step ("  health check  : HTTP 200 OK  " + $bodyText.Substring(0, $head))
    } elseif ($r.StatusCode -eq 200) {
        $head = $bodyText.Trim() -replace "`r?`n", ' '
        if ($head.Length -gt 90) { $head = $head.Substring(0, 90) }
        Write-Step ("  health check  : HTTP 200 BUT THE BODY IS NOT OUR JSON (ngrok warning page?) -> " + $head)
        Write-Step "                  probe with: curl.exe -s -H ""ngrok-skip-browser-warning: true"" <api>/health"
    } else {
        Write-Step ("  health check  : HTTP " + [int]$r.StatusCode)
    }
} catch {
    Write-Step ("  health check  : FAILED (" + $_.Exception.Message + ") - dispatched address is unreachable right now, fix the tunnel first")
}
if (-not $ok) { Write-Warning "Dispatched address failed the health check but was still written (apps keep a built-in fallback)." }

# self-hosted bootstrap copy must be readable at <origin>/site/client-config.json
# (this is the leg that needs NO third-party account: any live candidate can serve it)
try {
    $s = Invoke-WebRequest -Uri ($publicUrl + '/site/client-config.json') -UseBasicParsing -TimeoutSec 10 `
            -Headers $skipHeaders -UserAgent $probeUa
    $sJson = $null
    try { $sJson = ([string]$s.Content).Trim().TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $sJson = $null }
    if ($s.StatusCode -eq 200 -and $sJson -and $sJson.api) {
        Write-Step ("  self-hosted   : HTTP 200 OK  /site/client-config.json  api=" + $sJson.api +
                    "  candidates=" + @($sJson.candidates).Count)
    } else {
        Write-Step "  self-hosted   : HTTP 200 but content is not the dispatch JSON"
    }
} catch {
    Write-Step ("  self-hosted   : FAILED (" + $_.Exception.Message + ") - /site/client-config.json is not reachable through this address")
}

Write-Step "== done =="
Write-Host ""
Write-Host "Optional extra mirror (NOT required any more):"
Write-Host ("  1) open the file behind: " + $BootstrapUrl)
Write-Host "  2) overwrite its content with the JSON printed above (plain static file, no backend, no cost)"
Write-Host "  3) keep that URL unchanged - apps embed the URL, not the address"
Write-Host "  Bootstrap source order in the app (core/lib/src/config/app_address.dart):"
Write-Host "    (1) Gitee raw  (2) <candidate>/site/client-config.json  [this script feeds it]"
Write-Host "    (3) jsDelivr mirror  (4) GitHub raw  -> then built-in candidates -> built-in address."
