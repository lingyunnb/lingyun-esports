# FishTunnel - install SakuraFrp frpc as a Windows service "FishTunnel" (FISH-owned).
#
# WHY: Cloudflare Quick Tunnel changes its trycloudflare.com subdomain on every
#      restart, so the public address of the FISH backend is never stable.
#      A SakuraFrp TCP tunnel keeps ONE fixed host:port forever.
#
# SCOPE / SAFETY:
#   - Touches ONLY fish resources: nssm service "FishTunnel", D:\fish\infra\tunnel\**.
#   - NEVER stops, restarts or modifies any OtherProject-* service, process or file.
#   - Runs frpc from D:\fish\infra\tunnel\frpc\frpc.exe (our own copy), never OtherProject's.
#
# REQUIRES: an ELEVATED (Administrator) PowerShell. Creating a Windows service
#           needs SC_MANAGER_CREATE_SERVICE, which a normal shell does not have.
#           Without elevation nssm prints:
#             "Administrator access is needed to install a service."
#           (observed 2026-10-04; this script pre-checks and exits with a clear message).
#
# ASCII comments only: Windows PowerShell 5.1 reads .ps1 as ANSI unless a BOM is
# present, and a mis-decoded lead byte can swallow the following newline and break
# parsing (same lesson as scripts/publish-address.ps1 and OtherProject deploy/scripts).
#
# Usage:
#   # install + configure + start (recommended)
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\infra\tunnel\FishTunnel.ps1
#
#   # show what would run, change nothing
#   ... -DryRun
#
#   # stop + remove the service (rollback)
#   ... -Uninstall
#
#   # stopgap: ignore the panel's local_port and point the tunnel at FISH's own
#   # backend port via a local frpc config file (see -LocalPort remarks below)
#   ... -UseLocalConfig -LocalPort 3100
#
# REMARKS on -UseLocalConfig:
#   frpc has NO CLI flag to override a tunnel's local port; with -f it downloads the
#   tunnel definition from Sakura (which for tunnel 29188370 currently says
#   local_port = 3000, i.e. OtherProject's backend). -UseLocalConfig fetches that definition
#   once, rewrites local_port, and then runs frpc from the local file instead.
#   PREFER the panel fix (change the tunnel's local port to 3100) over this: with -f the
#   client also picks up panel changes such as automatic-HTTPS, which a frozen local
#   file will never see.

[CmdletBinding()]
param(
    [string] $TunnelId   = '29188370',
    [string] $ServiceName = 'FishTunnel',
    [string] $Nssm       = '',
    [int]    $LocalPort  = 3100,
    [switch] $UseLocalConfig,
    [switch] $Uninstall,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ paths
$tunnelDir = $PSScriptRoot
$frpcDir   = Join-Path $tunnelDir 'frpc'
$frpcExe   = Join-Path $frpcDir 'frpc.exe'
$tokenFile = Join-Path $tunnelDir 'frpc-token.txt'
$localCfg  = Join-Path $frpcDir 'fish.ini'
$logDir    = Join-Path (Split-Path -Parent (Split-Path -Parent $tunnelDir)) 'infra\data\logs'
$logOut    = Join-Path $logDir 'fish-frpc-out.log'
$logErr    = Join-Path $logDir 'fish-frpc-err.log'

# ------------------------------------------------------------ elevation gate
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host ""
    Write-Host "REFUSING TO RUN: this shell is NOT elevated." -ForegroundColor Red
    Write-Host "Creating/removing a Windows service requires Administrator rights."
    Write-Host "Re-run from an elevated PowerShell (Run as Administrator):"
    Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath)
    exit 1
}

# ----------------------------------------------------------------- nssm exe
# Prefer a standalone nssm; fall back to OtherProject's copy (execute-only, never modified).
$nssmCandidates = @(
    $Nssm,
    'C:\Program Files\nssm\nssm.exe',
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\nssm.exe'),
    'D:\OtherProjectServer\runtime\nssm.exe'
) | Where-Object { $_ -and (Test-Path $_) }
$nssm = $nssmCandidates | Select-Object -First 1
if (-not $nssm -and -not $DryRun) { throw "nssm.exe not found. Pass -Nssm <path>." }

# ------------------------------------------------------------------- token
if (-not (Test-Path $tokenFile)) { throw "token file not found: $tokenFile" }
$token = (Get-Content $tokenFile | Where-Object { $_ -match '^[a-z0-9]{20,}$' } | Select-Object -First 1)
if (-not $token) { throw "no token line (^[a-z0-9]{20,}$) found in $tokenFile" }
$token = $token.Trim()

$redactedArgs = "-f <TOKEN>:$TunnelId"

# Every command is printed BEFORE it runs, and secrets are never echoed.
function Show-Cmd([string] $c) { Write-Host ("  " + $c) -ForegroundColor DarkGray }
function Invoke-Nssm {
    param([string[]] $Arguments, [string] $Printable)
    Show-Cmd ("`"$nssm`" " + $Printable)
    if ($DryRun) { return }
    $out = & $nssm @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $out.Trim()) { Write-Warning $out.Trim() }
}

$frpcArgs = if ($UseLocalConfig) { "-c `"$localCfg`"" } else { "-f ${token}:${TunnelId}" }
$frpcArgsPrintable = if ($UseLocalConfig) { "-c `"$localCfg`"" } else { $redactedArgs }

# ----------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Host "== FishTunnel: UNINSTALL ==" -ForegroundColor Cyan
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Host "service $ServiceName does not exist - nothing to do"; exit 0 }
    if ($svc.Status -ne 'Stopped') {
        Invoke-Nssm @('stop', $ServiceName) "stop $ServiceName"
        Start-Sleep -Seconds 3
    }
    Invoke-Nssm @('remove', $ServiceName, 'confirm') "remove $ServiceName confirm"
    Write-Host "removed. Cloudflare fallback is unaffected; nothing OtherProject-* was touched."
    exit 0
}

# -------------------------------------------------------------------- checks
if (-not (Test-Path $frpcExe)) { throw "frpc.exe not found: $frpcExe" }
$frpcVer = (& $frpcExe --version 2>&1 | Select-Object -First 1)
Write-Host "== FishTunnel: INSTALL ==" -ForegroundColor Cyan
Write-Host ("  service     : {0}" -f $ServiceName)
Write-Host ("  frpc        : {0}  ({1})" -f $frpcExe, $frpcVer)
Write-Host ("  tunnel id   : {0}" -f $TunnelId)
Write-Host ("  args        : {0}" -f $frpcArgsPrintable)
Write-Host ("  work dir    : {0}" -f $frpcDir)
Write-Host ("  logs        : {0}" -f $logOut)

if ($UseLocalConfig) {
    # One fetch to obtain the server-side tunnel definition, then rewrite local_port.
    Write-Host "  fetching tunnel definition to build the local config..."
    if (-not $DryRun) {
        $p = Start-Process -FilePath $frpcExe `
             -ArgumentList @('-f', "${token}:${TunnelId}", '-c', $localCfg, '-w', '-n') -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 12
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        if (-not (Test-Path $localCfg)) { throw "frpc did not write $localCfg" }
        $ini = Get-Content $localCfg -Raw
        $ini = [regex]::Replace($ini, '(?m)^local_port\s*=.*$', "local_port = $LocalPort")
        [System.IO.File]::WriteAllText($localCfg, $ini, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("  rewrote local_port -> {0} in {1}" -f $LocalPort, $localCfg)
    }
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# --------------------------------------------------- idempotent (re)install
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  service already exists - removing it first (idempotent reinstall)"
    if ($existing.Status -ne 'Stopped') {
        Invoke-Nssm @('stop', $ServiceName) "stop $ServiceName"
        Start-Sleep -Seconds 3
    }
    Invoke-Nssm @('remove', $ServiceName, 'confirm') "remove $ServiceName confirm"
    $waited = 0
    while ((Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) -and $waited -lt 60) {
        Start-Sleep -Seconds 3; $waited += 3
    }
}

Invoke-Nssm @('install', $ServiceName, $frpcExe, $frpcArgs) "install $ServiceName `"$frpcExe`" `"$frpcArgsPrintable`""
Invoke-Nssm @('set', $ServiceName, 'AppDirectory',    $frpcDir) "set $ServiceName AppDirectory `"$frpcDir`""
Invoke-Nssm @('set', $ServiceName, 'DisplayName',     'FISH Tunnel (Sakura Frp)') "set $ServiceName DisplayName `"FISH Tunnel (Sakura Frp)`""
Invoke-Nssm @('set', $ServiceName, 'AppStdout',       $logOut)  "set $ServiceName AppStdout `"$logOut`""
Invoke-Nssm @('set', $ServiceName, 'AppStderr',       $logErr)  "set $ServiceName AppStderr `"$logErr`""
Invoke-Nssm @('set', $ServiceName, 'AppRotateFiles',  '1')      "set $ServiceName AppRotateFiles 1"
Invoke-Nssm @('set', $ServiceName, 'AppRotateOnline', '1')      "set $ServiceName AppRotateOnline 1"
Invoke-Nssm @('set', $ServiceName, 'AppRotateBytes',  '10485760') "set $ServiceName AppRotateBytes 10485760"
Invoke-Nssm @('set', $ServiceName, 'Start',           'SERVICE_AUTO_START') "set $ServiceName Start SERVICE_AUTO_START"
Invoke-Nssm @('set', $ServiceName, 'AppExit', 'Default', 'Restart') "set $ServiceName AppExit Default Restart"
Invoke-Nssm @('set', $ServiceName, 'AppRestartDelay', '10000')  "set $ServiceName AppRestartDelay 10000"

Invoke-Nssm @('start', $ServiceName) "start $ServiceName"
if ($DryRun) { Write-Host "[DryRun] nothing was changed."; exit 0 }

Start-Sleep -Seconds 6
Get-Service -Name $ServiceName | Format-List Name, Status, StartType
if (Test-Path $logOut) { Get-Content $logOut -Tail 15 }

Write-Host ""
Write-Host "Next steps (see the report):"
Write-Host "  1) the tunnel's own local port must point at FISH's backend (3100)."
Write-Host "  2) plaintext HTTP is BLOCKED by the Sakura node (HTTP 501), so the entry"
Write-Host "     must be https:// - either enable automatic HTTPS on the tunnel or serve"
Write-Host "     TLS from the backend, then pin the certificate in the app."
Write-Host "  3) dispatch the fixed address:"
Write-Host "       powershell -File D:\fish\scripts\publish-address.ps1 -Url https://<entry> -Source sakura-fixed"
