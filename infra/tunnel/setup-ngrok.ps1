# setup-ngrok.ps1 - ONE-SHOT setup of the FISH ngrok tunnel (ngrok free plan, static domain).
#
# WHY ngrok (decision 2026-10-04, owner-approved):
#   Cloudflare Quick Tunnel hands out a RANDOM trycloudflare.com subdomain on every
#   restart, so the public FISH address was never stable. SakuraFrp was abandoned:
#   its TCP nodes intercept plaintext HTTP, and TLS there needs a domain or a
#   self-signed cert plus a patched client. The ngrok FREE plan includes exactly
#   ONE permanent static domain (xxxx.ngrok-free.app) with HTTPS, so the public
#   address survives reboots and no domain purchase is required.
#
# WHAT THIS SCRIPT DOES (all local, nothing is uploaded except the ngrok API call
# that registers our authtoken with the local ngrok agent config):
#   1. read the authtoken from D:\fish\infra\tunnel\ngrok-token.txt
#   2. ngrok config add-authtoken <token>   -> writes %LOCALAPPDATA%\ngrok\ngrok.yml
#   3. (only if ngrok-domain.txt already holds a domain) start pm2 app fish-tunnel-ngrok
#      and pm2 save, so the fixed address comes up again after a reboot.
#      Without a claimed static domain the tunnel intentionally stays down: a
#      random ngrok address is no better than the random Cloudflare one.
#
# NOT IN SCOPE / NEVER TOUCHED:
#   - the existing pm2 app "fish-tunnel" (cloudflared) keeps running as fallback
#   - the Windows service "FishTunnel" (Sakura, needs Administrator, NOT ours)
#   - every OtherProject-* container / service / port
#
# ASCII COMMENTS ONLY. Windows PowerShell 5.1 reads .ps1 as ANSI unless a BOM is
# present, and a mis-decoded lead byte can swallow the following newline and break
# parsing (same lesson as scripts/publish-address.ps1). Keep this file ASCII.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\infra\tunnel\setup-ngrok.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\infra\tunnel\setup-ngrok.ps1 -DryRun

[CmdletBinding()]
param(
    [switch] $DryRun,
    [int]    $Port = 3100
)

$ErrorActionPreference = 'Stop'

$tunnelDir   = $PSScriptRoot
$ngrokDir    = Join-Path $tunnelDir 'ngrok'
$ngrokExe    = Join-Path $ngrokDir  'ngrok.exe'
$tokenFile   = Join-Path $tunnelDir 'ngrok-token.txt'
$domainFile  = Join-Path $tunnelDir 'ngrok-domain.txt'
$pm2Name     = 'fish-tunnel-ngrok'
$placeholder = 'PASTE_YOUR_NGROK_AUTHTOKEN_HERE'

function Write-Step($m) { Write-Host $m }
function Write-Cmd($m)  { Write-Host ("  [cmd] " + $m) }

# Run a pm2 command tolerantly: the pm2.ps1 shim converts ANY stderr line into a
# NativeCommandError and $ErrorActionPreference='Stop' would abort the script.
# `pm2 delete <name>` on a not-yet-existing app writes to stderr (reproduced 2026-10-04).
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

# Never print a secret: show only a masked fingerprint so the operator can tell
# two different tokens apart without the value ever landing in a log or a report.
function Mask-Secret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }
    $v = $Value.Trim()
    if ($v.Length -le 6) { return ('*' * $v.Length) }
    return ($v.Substring(0, 3) + ('*' * 8) + $v.Substring($v.Length - 3) + " (len=$($v.Length))")
}

Write-Step "== FISH ngrok setup =="
Write-Step ("  tunnel dir : " + $tunnelDir)
Write-Step ("  ngrok exe  : " + $ngrokExe)
Write-Step ("  token file : " + $tokenFile)
Write-Step ("  domain file: " + $domainFile)
Write-Step ""

# ---------------------------------------------------------------- 0. preflight
if (-not (Test-Path $ngrokExe)) {
    throw "ngrok.exe not found at $ngrokExe - download the official zip into $ngrokDir first (see ngrok\SOURCE.txt)."
}
$ver = (& $ngrokExe --version 2>&1 | Out-String).Trim()
Write-Step ("  ngrok      : " + $ver)

if (-not (Test-Path $tokenFile)) {
    throw "Token file missing: $tokenFile - create it and paste the authtoken (one line)."
}
$token = (Get-Content $tokenFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token) -or $token -eq $placeholder -or $token -match '^PASTE_') {
    throw ("Token file still holds the placeholder. Owner: paste the real authtoken into " +
           "$tokenFile (ngrok dashboard -> Your Authtoken) and re-run this script.")
}
Write-Step ("  token      : " + (Mask-Secret $token) + "  <- masked on purpose")
Write-Step ""

# ---------------------------------------------------------------- 1. add-authtoken
Write-Step "[1/3] register authtoken with the local ngrok agent"
Write-Cmd ("`"$ngrokExe`" config add-authtoken <TOKEN>   (value masked, never echoed)")
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    & $ngrokExe config add-authtoken $token 2>&1 | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "ngrok config add-authtoken failed (exit $LASTEXITCODE)." }
    Write-Host "    OK - written to $env:LOCALAPPDATA\ngrok\ngrok.yml"
}
Write-Step ""

# ---------------------------------------------------------------- 2. static domain?
$domain = ''
if (Test-Path $domainFile) { $domain = (Get-Content $domainFile -Raw).Trim() }
$hasDomain = ($domain -ne '' -and $domain -match '^[A-Za-z0-9.-]+$')

if (-not $hasDomain) {
    Write-Step "[2/3] static domain: NOT SET YET - skipping pm2 start on purpose"
    Write-Step "      Owner action (free, ~1 min): ngrok dashboard -> Universal Gateway -> Domains"
    Write-Step "      -> 'New Domain' -> you get one permanent  xxxx.ngrok-free.app  on the free plan."
    Write-Step ("      Then put it (bare host, no https://) into: " + $domainFile)
    Write-Step "      ... and run:  .\enable-ngrok.ps1   which starts + verifies the tunnel."
    Write-Step ""
    Write-Step "[3/3] pm2 save: skipped (nothing new to persist yet)"
    Write-Step "== done (token registered; waiting on static domain) =="
    return
}

Write-Step ("[2/3] static domain detected: " + $domain)
$url = 'https://' + $domain
# ngrok 3.39.11 still accepts --domain but prints "Flag --domain has been deprecated,
# use --url instead" (probed 2026-10-04), so we use the forward-compatible --url form.
$args2 = @('http', "$Port", "--url=$url", '--log=stdout')
Write-Cmd ("pm2 start `"$ngrokExe`" --name $pm2Name --cwd `"$ngrokDir`" -- " + ($args2 -join ' '))
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    # idempotent: drop a previous instance first (also clears a stale pid file).
    # Tolerant on purpose - a not-found app is the normal first-run case.
    $del = Invoke-Pm2 ('pm2 delete ' + $pm2Name)
    $startCmd = 'pm2 start "' + $ngrokExe + '" --name ' + $pm2Name + ' --cwd "' + $ngrokDir + '" -- ' + ($args2 -join ' ')
    $st = Invoke-Pm2 $startCmd
    $st.Output | ForEach-Object { "    $_" }
    if ($st.Code -ne 0) { throw "pm2 start $pm2Name failed (exit $($st.Code))." }
    Write-Host "    started; public address will be $url"
}
Write-Step ""

# ---------------------------------------------------------------- 3. pm2 save
Write-Step "[3/3] pm2 save (persist so the fixed address returns after a reboot)"
Write-Cmd "pm2 save"
if ($DryRun) {
    Write-Host "  [DryRun] skipped."
} else {
    $sv = Invoke-Pm2 'pm2 save'
    $sv.Output | ForEach-Object { "    $_" }
    if ($sv.Code -ne 0) { Write-Warning "pm2 save returned exit $($sv.Code)" }
}
Write-Step ""
Write-Step "== done =="
Write-Step "Next: .\enable-ngrok.ps1   (verifies the domain end to end and switches"
Write-Step "      config/client-config.json over to it; keeps Cloudflare as fallback)"
