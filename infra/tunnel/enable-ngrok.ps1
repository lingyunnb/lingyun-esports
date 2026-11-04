# enable-ngrok.ps1 - verify the FISH ngrok static domain and switch the apps over to it.
#
# ONE command does the whole switch (idempotent, safe to re-run):
#   1. read ngrok-token.txt + ngrok-domain.txt
#   2. ngrok config add-authtoken <token>
#   3. (re)start pm2 app fish-tunnel-ngrok on  http://localhost:3100
#      (ngrok http <port> --url https://<domain> --log=stdout)
#   4. wait, then ASSERT the tunnel really is OUR backend, and NOT the ngrok
#      free-plan browser warning page:
#        GET https://<domain>/api/v1/health          -> HTTP 200 *and* the body must
#                                                       parse as JSON with code=0 and
#                                                       data.services.database present
#        GET https://<domain>/api/v1/public/games    -> body must parse as JSON and list
#                                                       the 3 FISH games (names from
#                                                       expected-games.json) *and* the
#                                                       3 game codes (peace / delta_mobile
#                                                       / delta_pc) - codes come from the
#                                                       game table, an interstitial cannot
#                                                       fake them
#
#      WHY the body is asserted and not just the status code: the ngrok FREE plan
#      answers a *browser-looking* request with an interstitial HTML page
#      ("You are about to visit <domain>") that carries HTTP **200** and
#      Content-Type text/plain. A status-code-only probe therefore PASSES while the
#      body is not our JSON at all - the exact false positive that made step 5 of
#      this script fail (reproduced 2026-10-04: IWR default UA -> HTTP 200,
#      261 bytes, "You are about to visit ...").
#
#      Two defences, both applied to every probe:
#        (a) the header  ngrok-skip-browser-warning: true  (ngrok then proxies straight
#            to the backend; every other host ignores the unknown header), and
#        (b) a NON-browser User-Agent - curl.exe uses its own "curl/x.y" UA and
#            Invoke-WebRequest is given -UserAgent 'fish-tunnel-check/1.0'.
#      Plus a JSON/contract assertion on the body, so "200 but it is the warning page"
#      can never be reported as a pass again.
#   5. only on success: rewrite config/client-config.json so candidates are
#        [ ngrok https (primary), current Cloudflare https (backup) ]
#      sync site/client-config.json, and publish via scripts/publish-address.ps1
#   6. on failure: change NOTHING and print diagnostics + the one-line rollback
#
# SAFETY / SCOPE
#   - NEVER touches the pm2 app "fish-tunnel" (cloudflared fallback stays up)
#   - NEVER touches the Windows service "FishTunnel" (Sakura, needs Administrator)
#   - NEVER touches any OtherProject-* container / service / port
#   - the authtoken is only ever read and passed as an argument; it is NEVER echoed
#
# ASCII COMMENTS ONLY (Windows PowerShell 5.1 GBK parsing hazard - see
# scripts/publish-address.ps1 for the same rule).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\infra\tunnel\enable-ngrok.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\infra\tunnel\enable-ngrok.ps1 -DryRun
#   powershell ... -File ...\enable-ngrok.ps1 -SkipSwitch     # verify only, change no config

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $SkipSwitch,
    [int]    $Port = 3100,
    [int]    $WaitSeconds = 5
)

$ErrorActionPreference = 'Stop'

$tunnelDir  = $PSScriptRoot
$repoRoot   = Split-Path -Parent (Split-Path -Parent $tunnelDir)
$ngrokDir   = Join-Path $tunnelDir 'ngrok'
$ngrokExe   = Join-Path $ngrokDir  'ngrok.exe'
$tokenFile  = Join-Path $tunnelDir 'ngrok-token.txt'
$domainFile = Join-Path $tunnelDir 'ngrok-domain.txt'
$pm2Name    = 'fish-tunnel-ngrok'
$publishPs1 = Join-Path $repoRoot 'scripts\publish-address.ps1'
$configFile = Join-Path $repoRoot 'config\client-config.json'
$siteConfig = Join-Path $repoRoot 'site\client-config.json'
$urlCache   = Join-Path $repoRoot 'scripts\tmp\.tunnel-url'
$tunnelLog  = Join-Path $repoRoot 'infra\data\logs\fish-tunnel-error.log'
$placeholder = 'PASTE_YOUR_NGROK_AUTHTOKEN_HERE'

# The three games that prove we reached the FISH backend and not somebody else's tunnel.
# Loaded from a UTF-8 JSON data file, NOT written as literals here: this script must stay
# pure ASCII because Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK and a Chinese literal
# becomes a parse error (reproduced on this machine 2026-10-04).
$gamesFile = Join-Path $tunnelDir 'expected-games.json'
if (-not (Test-Path $gamesFile)) { throw "expected-games.json missing: $gamesFile" }
$expectedGames = @()
$expectedCodes = @()
try {
    $gamesRaw = [System.IO.File]::ReadAllText($gamesFile, [System.Text.Encoding]::UTF8)
    $gamesJson = $gamesRaw | ConvertFrom-Json
    $expectedGames = @($gamesJson.games)
    $expectedCodes = @($gamesJson.codes)
} catch {
    throw ("Could not read the expected game list from " + $gamesFile + ": " + $_.Exception.Message)
}
if ($expectedGames.Count -eq 0) { throw "expected-games.json contains no games." }
$expectedDisplay = ($expectedGames -join ' / ')

function Write-Step($m) { Write-Host $m }
function Write-Cmd($m)  { Write-Host ("  [cmd] " + $m) }

function Mask-Secret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }
    $v = $Value.Trim()
    if ($v.Length -le 6) { return ('*' * $v.Length) }
    return ($v.Substring(0, 3) + ('*' * 8) + $v.Substring($v.Length - 3) + " (len=$($v.Length))")
}

function Test-SkipHttpErrorCheck {
    return ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck'))
}

# ---------------------------------------------------------------- probe headers
# The ngrok free plan serves a browser warning page ("You are about to visit <domain>")
# with HTTP **200** to any request that looks like a browser. That page is NOT our JSON,
# so every probe below must (a) ask ngrok to skip the warning and (b) not announce itself
# as a browser. Both are harmless for Cloudflare / LAN / any other host.
$SkipHeaderName  = 'ngrok-skip-browser-warning'
$SkipHeaderValue = 'true'
$ProbeUserAgent  = 'fish-tunnel-check/1.0'

function Get-CurlExe {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return ''
}

# Find a curl.exe in the usual Windows locations when PATH lookup fails.
function Resolve-CurlFallback {
    foreach ($p in @(
        (Join-Path $env:SystemRoot 'System32\curl.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\curl.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return ''
}

# Invoke-WebRequest with the skip header + a non-browser UA. Returns the same
# @{ Code; Body; Error } shape as Get-Http and never throws on a non-2xx status.
function Invoke-ProbeRequest {
    param([string]$Url, [int]$TimeoutSec = 25)
    $r = [ordered]@{ Code = 0; Body = ''; Error = '' }
    $headers = @{ $SkipHeaderName = $SkipHeaderValue }
    try {
        if (Test-SkipHttpErrorCheck) {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec `
                        -Headers $headers -UserAgent $ProbeUserAgent -SkipHttpErrorCheck
            $r.Code = [int]$resp.StatusCode
            $r.Body = [string]$resp.Content
        } else {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec `
                        -Headers $headers -UserAgent $ProbeUserAgent
            $r.Code = [int]$resp.StatusCode
            $r.Body = [string]$resp.Content
        }
    } catch {
        $r.Error = $_.Exception.Message
        try {
            if ($_.Exception.Response) {
                $r.Code = [int]$_.Exception.Response.StatusCode
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $r.Body = $sr.ReadToEnd()
            }
        } catch { }
    }
    return $r
}

# curl.exe is the most reliable probe on this box: its default UA is non-browser and it
# gives us the body, the status code and the content type separately.
function Invoke-CurlProbe {
    param([string]$Url, [int]$TimeoutSec = 25)
    $r = [ordered]@{ Code = 0; Body = ''; Error = ''; ContentType = '' }
    $exe = Get-CurlExe
    if (-not $exe) { $exe = Resolve-CurlFallback }
    if (-not $exe) { $r.Error = 'curl.exe not found'; return $r }
    $text = ''
    $code = 0
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # curl writes progress/errors to stderr
    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $text = & $exe -s -S -o $tmp -w '%{http_code}|%{content_type}' `
                        -H ($SkipHeaderName + ': ' + $SkipHeaderValue) `
                        -A $ProbeUserAgent --max-time $TimeoutSec $Url 2>&1 | Out-String
            $text = $text.Trim()
            $code = $LASTEXITCODE
            if (Test-Path $tmp) { $r.Body = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) }
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $r.Error = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $saved
    }
    $parts = @($text -split '\|')
    if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') { $r.Code = [int]$parts[0] }
    if ($parts.Count -ge 2) { $r.ContentType = $parts[1].Trim() }
    if ($code -ne 0) { $r.Error = ("curl.exe exit " + $code + " " + $r.Error).Trim() }
    return $r
}

# Single entry point for every HTTP probe in this script.
# Order: curl.exe (authoritative, real transport) -> Invoke-WebRequest with skip header.
# The IWR attempt must never be what decides a PASS while it is actually the warning page:
# the JSON assertions in steps 4/5 below are what make that impossible.
function Get-Http {
    param([string]$Url, [int]$TimeoutSec = 25)
    $r = [ordered]@{ Code = 0; Body = ''; Error = ''; ContentType = '' }
    $nc = Invoke-CurlProbe -Url $Url -TimeoutSec $TimeoutSec
    if ($nc.Code -gt 0) {
        $r.Code = $nc.Code
        $r.Body = $nc.Body
        $r.ContentType = $nc.ContentType
        if ($nc.Error) { $r.Error = $nc.Error }
        return $r
    }
    $i = Invoke-ProbeRequest -Url $Url -TimeoutSec $TimeoutSec
    $r.Code = $i.Code
    $r.Body = $i.Body
    $r.Error = $i.Error
    if ($nc.Error) { $r.Error = ($r.Error + ' | curl: ' + $nc.Error).Trim() }
    return $r
}

# --- JSON contract assertions -------------------------------------------------
# A response only counts as "ours" when it parses as JSON AND carries our own fields.
# This is the guard against the ngrok warning page: it arrives with HTTP 200 but is
# plain text, so ConvertFrom-Json throws and every assertion below returns $false.

# Strict converter: returns $null instead of throwing when the body is not JSON.
function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    # ngrok's warning page is HTML/plain text - reject it before even trying.
    if ($t.StartsWith('<')) { return $null }
    # UTF8 BOM would break ConvertFrom-Json on 5.1
    $t = $t.TrimStart([char]0xFEFF)
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

# Dot-path field lookup that tolerates missing parents (PS 5.1: Set-StrictMode off).
function Get-JsonField {
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}

# Assert /api/v1/health really is the FISH unified response (docs/03).
function Test-HealthBody {
    param([string]$Body, [System.Collections.ArrayList]$Problems)
    $parsed = ConvertFrom-JsonSafe $Body
    if ($null -eq $parsed) {
        [void]$Problems.Add('health body is NOT valid JSON (ngrok browser-warning page?)')
        return $false
    }
    $code = Get-JsonField $parsed 'code'
    if ($code -ne 0 -and "$code" -ne '0') {
        [void]$Problems.Add('health body code is not 0 (got: ' + "$code" + ')')
    }
    $db = Get-JsonField $parsed 'data.services.database'
    if ([string]::IsNullOrWhiteSpace("$db")) {
        [void]$Problems.Add('health body is missing data.services.database')
    }
    $redis = Get-JsonField $parsed 'data.services.redis'
    if ([string]::IsNullOrWhiteSpace("$redis")) {
        [void]$Problems.Add('health body is missing data.services.redis')
    }
    return ($Problems.Count -eq 0)
}

# Assert /api/v1/public/games really lists the 3 FISH games, by NAME and by CODE.
# Codes are the decisive check: an interstitial can echo a hostname, it cannot invent
# 'delta_mobile' from our game table.
function Test-GamesBody {
    param([string]$Body, [System.Collections.ArrayList]$Problems)
    $parsed = ConvertFrom-JsonSafe $Body
    if ($null -eq $parsed) {
        [void]$Problems.Add('games body is NOT valid JSON (ngrok browser-warning page?)')
        return $false
    }
    $arr = @()
    if ($parsed -is [array]) { $arr = @($parsed) }
    elseif ($null -ne (Get-JsonField $parsed 'data')) { $arr = @(Get-JsonField $parsed 'data') }
    $names = @($arr | ForEach-Object { $_.name })
    $codes = @($arr | ForEach-Object { $_.code })
    if ($names.Count -eq 0) { [void]$Problems.Add('games list is empty (data[] missing)') }
    foreach ($g in $expectedGames) {
        if ($names -notcontains $g) { [void]$Problems.Add('missing game name: ' + $g) }
    }
    foreach ($c in $expectedCodes) {
        if ($codes -notcontains $c) { [void]$Problems.Add('missing game code: ' + $c) }
    }
    return ($Problems.Count -eq 0)
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $enc)
}

# Run a pm2 command tolerantly.
# WHY: the pm2.ps1 shim turns ANY stderr line into a NativeCommandError, and with
# $ErrorActionPreference='Stop' that aborts the script. `pm2 delete <name>` on a
# not-yet-existing app writes "[PM2][ERROR] Process or Namespace ... not found" to
# stderr, which killed the FIRST run of this script at step 2 (reproduced 2026-10-04).
# Exit codes are routed through a plain variable so $LASTEXITCODE survives the call.
function Invoke-Pm2 {
    param([string]$Command)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $global:LASTEXITCODE = 0
    try {
        $output = & cmd /c "$Command 2>&1"
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Code = $code; Output = @($output) }
}

# Flatten a candidate list and guarantee exactly one /api/v1 suffix per entry.
# Handles the comma-joined-as-one-element case so the fallback cannot be dropped.
function Expand-Candidates {
    param($Value)
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($Value)) {
        foreach ($piece in ([string]$item).Split(',')) {
            $c = $piece.Trim().TrimEnd('/')
            if ($c -eq '') { continue }
            if ($c -notmatch '/api/v1$') { $c = $c + '/api/v1' }
            [void]$out.Add($c)
        }
    }
    return $out.ToArray()
}

# Resolve the CURRENT Cloudflare quick-tunnel address, which becomes the backup
# candidate. Read from the live pm2 log first (authoritative): the cached
# scripts\tmp\.tunnel-url can be stale right after the tunnel restarts, and after
# the switch to ngrok nothing refreshes it, so trusting the cache alone would
# silently drop the fallback. Same regex approach as scripts/publish-address.ps1.
function Resolve-CloudflareUrl {
    $found = ''
    try {
        $log = (Invoke-Pm2 'pm2 logs fish-tunnel --lines 400 --nostream').Output | Out-String
        $m = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($m.Count -gt 0) { $found = $m[$m.Count - 1].Value }
    } catch { }
    if (-not $found -and (Test-Path $tunnelLog)) {
        $m2 = [regex]::Matches((Get-Content $tunnelLog -Raw), 'https://[a-z0-9-]+\.trycloudflare\.com')
        if ($m2.Count -gt 0) { $found = $m2[$m2.Count - 1].Value }
    }
    if (-not $found -and (Test-Path $urlCache)) { $found = (Get-Content $urlCache -Raw).Trim() }
    return $found.TrimEnd('/')
}

$fail = @()
function Add-Fail($m) { $script:fail += $m; Write-Host ("  [FAIL] " + $m) }
function Add-Ok($m)   { Write-Host ("  [ ok ] " + $m) }

Write-Step "== FISH ngrok enable =="
if ($DryRun) { Write-Step "  MODE: DryRun (no local change will be made)" }
Write-Step ("  pm2 app    : " + $pm2Name)
Write-Step ("  port       : " + $Port)
Write-Step ""

# ---------------------------------------------------------------- 0. preflight
if (-not (Test-Path $ngrokExe)) { throw "ngrok.exe missing: $ngrokExe" }
Write-Step ("  ngrok      : " + ((& $ngrokExe --version 2>&1 | Out-String).Trim()))

if (-not (Test-Path $tokenFile)) { throw "token file missing: $tokenFile" }
$token = (Get-Content $tokenFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token) -or $token -eq $placeholder -or $token -match '^PASTE_') {
    throw ("Token file still holds the placeholder. Owner: paste the authtoken into " +
           "$tokenFile and re-run. (ngrok dashboard -> Your Authtoken -> Copy)")
}
Write-Step ("  token      : " + (Mask-Secret $token) + "  <- masked on purpose")

if (-not (Test-Path $domainFile)) {
    throw ("Static domain file missing: $domainFile`n" +
           "  Owner: ngrok dashboard -> Domains -> New Domain (free plan gives 1 permanent`n" +
           "  xxxx.ngrok-free.app). Write the bare host (no https://, no trailing slash)`n" +
           "  into that file, then re-run this script.")
}
$domain = (Get-Content $domainFile -Raw).Trim()
$domain = $domain -replace '^https?://', ''
$domain = $domain.TrimEnd('/')
if ($domain -notmatch '^[A-Za-z0-9.-]+$') { throw "ngrok-domain.txt does not look like a hostname: '$domain'" }
if ($domain -notmatch '\.ngrok(-free)?\.(app|dev|io)$') {
    throw ("ngrok-domain.txt must hold a STATIC ngrok domain like xxxx.ngrok-free.app, got '$domain'." +
           " A random per-session ngrok URL is momentary and must not be published.")
}
$url = 'https://' + $domain
Write-Step ("  domain     : " + $domain)
Write-Step ("  public url : " + $url)
Write-Step ""

# ---------------------------------------------------------------- 1. authtoken
Write-Step "[1/6] register authtoken"
Write-Cmd ("`"$ngrokExe`" config add-authtoken <TOKEN>   (masked)")
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    & $ngrokExe config add-authtoken $token 2>&1 | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "ngrok config add-authtoken failed (exit $LASTEXITCODE)." }
    Add-Ok "authtoken registered in $env:LOCALAPPDATA\ngrok\ngrok.yml"
}

# ---------------------------------------------------------------- 2. (re)start pm2 app
Write-Step "[2/6] start/restart pm2 app '$pm2Name'"
# ngrok 3.39.11 still accepts --domain but prints "Flag --domain has been deprecated,
# use --url instead" (probed 2026-10-04), so prefer the forward-compatible --url form.
$tArgs = @('http', "$Port", "--url=$url", '--log=stdout')
Write-Cmd ("pm2 delete $pm2Name   (idempotent; frees a stale pid/agent lock)")
Write-Cmd ("pm2 start `"$ngrokExe`" --name $pm2Name --cwd `"$ngrokDir`" -- " + ($tArgs -join ' '))
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    # delete is deliberately tolerant: a not-found app is the normal first-run case
    $del = Invoke-Pm2 ('pm2 delete ' + $pm2Name)
    $startCmd = 'pm2 start "' + $ngrokExe + '" --name ' + $pm2Name + ' --cwd "' + $ngrokDir + '" -- ' + ($tArgs -join ' ')
    $st = Invoke-Pm2 $startCmd
    $st.Output | ForEach-Object { "    $_" }
    if ($st.Code -ne 0) { throw "pm2 start $pm2Name failed (exit $($st.Code))." }
    Add-Ok "pm2 app started"
}

# ---------------------------------------------------------------- 3. wait
Write-Step ("[3/6] wait " + $WaitSeconds + "s for the edge to come up")
if (-not $DryRun) { Start-Sleep -Seconds $WaitSeconds } else { Write-Host "  [DryRun] skipped." }

# ---------------------------------------------------------------- 4. assert health 200
Write-Step "[4/6] assert GET $url/api/v1/health -> HTTP 200 + FISH JSON contract"
$healthUrl = $url + '/api/v1/health'
$healthOk = $false
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    $h = Get-Http -Url $healthUrl
    if ($h.Code -eq 200) {
        $hProblems = New-Object System.Collections.ArrayList
        $healthOk = Test-HealthBody -Body $h.Body -Problems $hProblems
        if ($healthOk) {
            $head = if ($h.Body.Length -gt 120) { $h.Body.Substring(0, 120) } else { $h.Body }
            Add-Ok ("HTTP 200 + JSON contract ok  [" + $h.ContentType + "]  " + $head)
        } else {
            Add-Fail ("HTTP 200 but the body is not our health JSON:")
            foreach ($p in $hProblems) { Write-Host ("         - " + $p) }
            $bHead = if ($h.Body.Length -gt 160) { $h.Body.Substring(0, 160) } else { $h.Body }
            Write-Host ("         body[" + $h.ContentType + "]: " + ($bHead -replace "`r?`n", ' '))
            Write-Host "         (this is the ngrok free-plan browser-warning page signature: 200 + text/plain)"
        }
    } else {
        Add-Fail ("health returned HTTP " + $h.Code + " " + $h.Error)
    }
}

# ---------------------------------------------------------------- 5. assert our 3 games
Write-Step "[5/6] assert GET $url/api/v1/public/games -> the 3 FISH games (names + codes)"
$gamesUrl = $url + '/api/v1/public/games'
$gamesOk = $false
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    $g = Get-Http -Url $gamesUrl
    if ($g.Code -eq 200) {
        $gProblems = New-Object System.Collections.ArrayList
        $gamesOk = Test-GamesBody -Body $g.Body -Problems $gProblems
        if ($gamesOk) {
            $parsedG = ConvertFrom-JsonSafe $g.Body
            $arrG = if ($parsedG -is [array]) { @($parsedG) } else { @(Get-JsonField $parsedG 'data') }
            $namesG = @($arrG | ForEach-Object { $_.name })
            $codesG = @($arrG | ForEach-Object { $_.code })
            Add-Ok ("HTTP 200 + all " + $expectedGames.Count + " games: " + ($namesG -join ' / '))
            Add-Ok ("game codes match: " + ($codesG -join ' / '))
        } else {
            Add-Fail "HTTP 200 but the body does not match our games contract:"
            foreach ($p in $gProblems) { Write-Host ("         - " + $p) }
            $bHead = if ($g.Body.Length -gt 160) { $g.Body.Substring(0, 160) } else { $g.Body }
            Write-Host ("         body[" + $g.ContentType + "]: " + ($bHead -replace "`r?`n", ' '))
        }
    } else {
        Add-Fail ("games returned HTTP " + $g.Code + " " + $g.Error)
    }
}

# ---------------------------------------------------------------- outcome
Write-Step ""
if (-not $DryRun -and -not ($healthOk -and $gamesOk)) {
    Write-Step "== VERIFICATION FAILED - NO CONFIG FILE WAS TOUCHED =="
    Write-Step "Diagnostics:"
    Write-Step ("  domain            : " + $domain)

    # Values are computed BEFORE the string concatenation on purpose: a `try`
    # statement is not a valid expression inside a parenthesised string in
    # PowerShell, and doing it inline aborted the diagnostics entirely
    # (reproduced 2026-10-04).
    $dnsText = ''
    try {
        $ips = @(Resolve-DnsName $domain -Type A -ErrorAction Stop |
                 Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($ips.Count -gt 0) { $dnsText = ($ips -join ', ') } else { $dnsText = 'NO A RECORD' }
    } catch { $dnsText = 'RESOLVE FAILED: ' + $_.Exception.Message }
    Write-Step ("  DNS resolves?     : " + $dnsText)

    $tls = Get-Http -Url ('https://' + $domain + '/api/v1/health')
    Write-Step ("  TLS/HTTPS         : HTTP " + $tls.Code + " [" + $tls.ContentType + "] " + $tls.Error)
    # Print what the raw body looks like: if this says "You are about to visit ..." the
    # probe hit the ngrok warning page (200 + text/plain) and the JSON assertion is what
    # caught it. Without the skip header this is exactly what a browser would see.
    if ($tls.Body) {
        $tlsHead = [string]$tls.Body
        if ($tlsHead.Length -gt 120) { $tlsHead = $tlsHead.Substring(0, 120) }
        Write-Step ("  body head         : " + ($tlsHead -replace "`r?`n", ' '))
    }

    $locHealth = Get-Http -Url ('http://localhost:' + $Port + '/api/v1/health')
    Write-Step ("  local backend     : HTTP " + $locHealth.Code + " (must be 200 - if not, the problem is not ngrok)")

    $locGames = Get-Http -Url ('http://localhost:' + $Port + '/api/v1/public/games')
    Write-Step ("  local games       : HTTP " + $locGames.Code)

    $pm2Text = ''
    try {
        $desc = (Invoke-Pm2 ('pm2 describe ' + $pm2Name)).Output
        $lines = @($desc | Select-String -Pattern 'status|restarts|script args' | ForEach-Object { $_.Line.Trim() })
        if ($lines.Count -gt 0) { $pm2Text = ($lines -join ' | ') } else { $pm2Text = 'not running (pm2 describe returned nothing)' }
    } catch { $pm2Text = 'pm2 describe failed' }
    Write-Step ("  pm2 status        : " + $pm2Text)

    # Pull ngrok's own reason straight out of the agent log - this names the exact
    # ngrok error code (ERR_NGROK_xxxx) instead of leaving the operator guessing.
    $agentText = ''
    try {
        $agentLog = (Invoke-Pm2 ('pm2 logs ' + $pm2Name + ' --lines 60 --nostream')).Output | Out-String
        $codeMatch = [regex]::Matches($agentText + $agentLog, 'ERR_NGROK_[0-9]+')
        $errMatch  = @($agentLog -split "`n" | Select-String -Pattern 'lvl=eror|lvl=crit' | ForEach-Object { $_.Line.Trim() })
        if ($codeMatch.Count -gt 0) { $agentText = 'ngrok error code(s): ' + (($codeMatch | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', ') }
        if ($errMatch.Count -gt 0) {
            $firstErr = [string]$errMatch[0]
            if ($firstErr.Length -gt 220) { $firstErr = $firstErr.Substring(0, 220) + '...' }
            $agentText = ($agentText + "`n                        " + $firstErr).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($agentText)) { $agentText = 'no ngrok error lines found in the last 60 log lines' }
    } catch { $agentText = 'could not read pm2 logs' }
    Write-Step "  ngrok agent says  :"
    foreach ($ln in ($agentText -split "`n")) { Write-Step ("      " + $ln.Trim()) }

    Write-Step ("  full agent log    : pm2 logs " + $pm2Name + " --lines 60")
    Write-Step "  Common causes     :"
    Write-Step "    - the domain was not claimed on the free plan (look for ERR_NGROK_8013 / domain not reserved)"
    Write-Step "    - the authtoken belongs to a different account than the domain"
    Write-Step "    - DNS not propagated yet (wait ~1 min and re-run; this script is idempotent)"
    Write-Step "    - 'HTTP 200' in the body head above but not our JSON: that is the ngrok"
    Write-Step "      browser-warning page. This script sends the skip header + a non-browser UA,"
    Write-Step "      so seeing it here means a proxy stripped the header; check with:"
    Write-Step ("        curl.exe -s -H `"" + $SkipHeaderName + ": " + $SkipHeaderValue + "`" " + $healthUrl)
    Write-Step ""
    Write-Step "Nothing was switched. Cloudflare fallback is untouched and still serving."
    Write-Step ("One-line rollback (removes the ngrok tunnel only): pm2 delete " + $pm2Name + " && pm2 save")
    exit 1
}

if ($DryRun) {
    Write-Step "== DryRun complete =="
    Write-Step "Commands that WOULD run:"
    Write-Step ("  `"$ngrokExe`" config add-authtoken <TOKEN>")
    Write-Step ("  pm2 start `"$ngrokExe`" --name $pm2Name --cwd `"$ngrokDir`" -- " + ($tArgs -join ' '))
    Write-Step ("  curl.exe -s -H `"" + $SkipHeaderName + ": " + $SkipHeaderValue + "`" " + $healthUrl + "   (then assert the JSON contract)")
    Write-Step ("  curl.exe -s -H `"" + $SkipHeaderName + ": " + $SkipHeaderValue + "`" " + $gamesUrl + "   (then assert names + codes)")
    Write-Step ("  (no curl.exe? fallback: Invoke-WebRequest -Headers @{" + $SkipHeaderName + "='" + $SkipHeaderValue + "'} -UserAgent '" + $ProbeUserAgent + "')")
    $dryCandidates = @($url + '/api/v1')
    $cfNow = Resolve-CloudflareUrl
    if ($cfNow -and ($cfNow -notmatch [regex]::Escape($domain))) { $dryCandidates += ($cfNow.TrimEnd('/') + '/api/v1') }
    # Belt and braces: publish-address.ps1 takes [string[]], so a caller who writes
    #   -Candidates "https://a","https://b"   (one quoted element) or space-separated
    # would silently publish a single candidate and LOSE the fallback. Splitting any
    # embedded commas keeps the ordering intact either way.
    $dryCandidates = @(Expand-Candidates $dryCandidates)
    Write-Step ("  publish-address.ps1 -Url " + $url + " -Candidates " + ($dryCandidates -join ','))
    Write-Step ("JSON that WOULD be written to " + $configFile + ":")
    $dryPayload = [ordered]@{
        '_comment'   = 'FISH service address dispatch file (single source of truth). Generated by scripts/publish-address.ps1. Never put secrets here.'
        'api'        = $url + '/api/v1'
        'ws'         = $url
        'candidates' = @($dryCandidates)
        'updatedAt'  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        'source'     = 'ngrok-static-domain'
    }
    Write-Step ($dryPayload | ConvertTo-Json -Depth 4)
    Write-Step ""
    Write-Step ("Rollback (one line): pm2 delete " + $pm2Name + " && pm2 save")
    return
}

# ---------------------------------------------------------------- 6. switch config
Write-Step "[6/6] verification PASSED - switch the published address to ngrok"
if ($SkipSwitch) {
    Write-Step "  -SkipSwitch given: config intentionally left unchanged."
    Write-Step "== done (verified, no switch) =="
    return
}

# primary = ngrok, backup = whatever Cloudflare quick tunnel is live right now
$cfNow = Resolve-CloudflareUrl
$candidates = @($url + '/api/v1')
if ($cfNow -and ($cfNow -notmatch [regex]::Escape($domain))) {
    $candidates += ($cfNow.TrimEnd('/') + '/api/v1')
    Write-Step ("  backup candidate kept: " + $cfNow)
} else {
    Write-Step "  no live Cloudflare address found - ngrok will be the only candidate"
}
# Normalise: publish-address.ps1 takes [string[]], and a list that arrives as ONE
# comma-joined string (easy to produce when a human retypes the command, see below)
# must still publish every candidate, otherwise the fallback is silently lost.
$candidates = @(Expand-Candidates $candidates)

Write-Cmd ("powershell -File `"$publishPs1`" -Url $url -Candidates " + ($candidates -join ',') + " -Source ngrok-static-domain")
# Invoked IN-PROCESS on purpose. Going through `powershell -File ... -Candidates a,b`
# collapses the array into a single comma-joined string (verified 2026-10-04), which
# would publish ONE candidate and lose the Cloudflare fallback. Calling the script
# directly keeps real array binding and preserves the intended order.
try {
    & $publishPs1 -Url $url -Candidates $candidates -Source 'ngrok-static-domain'
} catch {
    throw ("publish-address.ps1 failed: " + $_.Exception.Message +
           " - inspect $configFile before trusting it.")
}

# Independently verify what actually landed on disk: api must be our ngrok domain and
# the fallback must still be present. Never report success from the write alone.
if (-not (Test-Path $configFile)) { throw "publish-address.ps1 did not produce $configFile" }
$written = Get-Content $configFile -Raw | ConvertFrom-Json
if ($written.api -notlike ($url + '*')) {
    throw ("config/client-config.json api is '" + $written.api + "' but expected it to start with '" + $url + "'")
}
if (@($written.candidates).Count -lt 2 -and $candidates.Count -ge 2) {
    throw ("fallback lost: candidates on disk = " + (@($written.candidates).Count) + ", expected " + $candidates.Count)
}
Add-Ok ("verified on disk: api=" + $written.api + "  candidates=" + @($written.candidates).Count)

# belt and braces: publish-address.ps1 already syncs site/, re-assert it here so a
# future edit to that script cannot silently break the /site/client-config.json copy
if ((Test-Path $configFile) -and (Test-Path (Split-Path -Parent $siteConfig))) {
    Copy-Item -Path $configFile -Destination $siteConfig -Force
    Add-Ok ("synced " + $siteConfig)
}
Add-Ok ("updated " + $configFile)

# Persist the pm2 process list so the ngrok tunnel (and therefore the SAME fixed
# address) comes back automatically after a reboot. Without this the tunnel would
# only exist until the next restart.
Write-Step "[6b] pm2 save (so the fixed address survives a reboot)"
Write-Cmd "pm2 save"
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    $sv = Invoke-Pm2 'pm2 save'
    $sv.Output | ForEach-Object { "    $_" }
    if ($sv.Code -ne 0) { Write-Warning "pm2 save returned exit $($sv.Code); the tunnel runs now but may not auto-start after a reboot." }
    else { Add-Ok "pm2 process list saved" }
}
Write-Step ""
Write-Step "== SWITCHED =="
Write-Step ("  primary  : " + $url + "/api/v1   (permanent, survives reboot)")
if ($candidates.Count -gt 1) { Write-Step ("  fallback : " + $candidates[1]) }
Write-Step ""
Write-Step "Rollback (one line):"
Write-Step ("  pm2 delete " + $pm2Name + " && pm2 save")
Write-Step "  (apps then fall back to the Cloudflare candidate / their built-in address)"
