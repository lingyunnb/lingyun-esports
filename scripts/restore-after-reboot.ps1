# =============================================================================
# fish-platform: restore everything after a Windows reboot
#   一键恢复：Docker 容器 -> 服务端(pm2) -> 新隧道地址 -> 发布地址 -> 二维码
#
# WHY: after a reboot nothing comes back by itself --
#   * pm2 has a saved dump but no Windows service/scheduled task to resurrect it
#   * the Cloudflare Quick Tunnel gets a NEW random trycloudflare.com subdomain
#     on every start, so the address must be re-published afterwards
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\fish\scripts\restore-after-reboot.ps1
#   ... -Check            only inspect, change nothing (safe anytime)
#   ... -SkipTunnel       do not restart the tunnel (keeps the current address)
#
# SAFETY: touches ONLY fish resources (containers fish-mysql/fish-redis,
#   pm2 apps fish-*, D:\fish). NEVER touches OtherProject-* containers, services,
#   ports 3000/5432/6379 or D:\OtherProjectServer.
#
# NOTE: comments are ASCII on purpose. Windows PowerShell 5.1 reads .ps1 as ANSI
#   unless a BOM is present; a mis-decoded lead byte can swallow a newline and
#   break parsing (same lesson as 2026-09-19 nssm-install.ps1). This file is
#   saved as UTF-8 WITH BOM so the Chinese console output renders correctly.
# =============================================================================

param(
  [switch]$Check,
  [switch]$SkipTunnel
)

$ErrorActionPreference = 'Continue'
$root = 'D:\fish'
$api  = 'http://127.0.0.1:3100/api/v1'
$expected = @('fish-server', 'fish-admin', 'fish-tunnel', 'fish-tunnel-ngrok', 'dsh-web')

function Step($n, $t) { Write-Host "`n=== [$n] $t ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  !!   $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  XX   $m" -ForegroundColor Red }
function Info($m) { Write-Host "       $m" -ForegroundColor Gray }

function Test-Health {
  try {
    $r = Invoke-WebRequest -Uri "$api/health" -TimeoutSec 5 -UseBasicParsing
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

Write-Host "祁连山电竞 · 重启后一键恢复" -ForegroundColor White
if ($Check) { Warn "只读检查模式（-Check）：不会启动/重启任何东西" }

# -----------------------------------------------------------------------------
Step 1 "Docker 容器（MySQL / Redis）"
# -----------------------------------------------------------------------------
$dockerOk = $false
try { docker ps --format '{{.Names}}' 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch { $dockerOk = $false }

if (-not $dockerOk) {
  Warn "Docker 引擎没在跑（Docker Desktop 未启动）"
  $dd = @(
    "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
    "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $dd) { Bad "找不到 Docker Desktop.exe，请手动启动 Docker Desktop 后重跑本脚本"; if (-not $Check) { exit 1 } }
  elseif ($Check) { Info "（-Check 不启动）将会启动：$dd" }
  else {
    Info "启动 Docker Desktop：$dd"
    Start-Process -FilePath $dd | Out-Null
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 5
      try { docker ps --format '{{.Names}}' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break } } catch {}
    }
    if ($dockerOk) { Ok "Docker 引擎已就绪" } else { Bad "等 240s 仍未就绪，请手动打开 Docker Desktop 后重跑"; exit 1 }
  }
} else { Ok "Docker 引擎在跑" }

if ($dockerOk) {
  $running = @(docker ps --format '{{.Names}}' 2>$null)
  foreach ($c in @('fish-mysql', 'fish-redis')) {
    if ($running -contains $c) { Ok "$c 运行中" }
    elseif ($Check) { Warn "$c 未运行（-Check 不启动；正式运行会执行 docker start $c）" }
    else {
      Info "启动 $c"
      docker start $c 2>$null | Out-Null
      Start-Sleep -Seconds 3
      if (@(docker ps --format '{{.Names}}') -contains $c) { Ok "$c 已启动" } else { Bad "$c 启动失败（看 docker logs $c）" }
    }
  }
  # wait for MySQL to accept connections
  if (-not $Check) {
    $deadline = (Get-Date).AddSeconds(120)
    $mysqlUp = $false
    while ((Get-Date) -lt $deadline) {
      docker exec fish-mysql sh -c 'mysqladmin ping -h127.0.0.1 --silent' 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { $mysqlUp = $true; break }
      Start-Sleep -Seconds 3
    }
    if ($mysqlUp) { Ok "MySQL 已可连接" } else { Warn "MySQL 120s 内未就绪，服务端可能启动失败" }
  }
}

# -----------------------------------------------------------------------------
Step 2 "服务端与隧道进程（pm2）"
# -----------------------------------------------------------------------------
$pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
if (-not $pm2) { Bad "pm2 不在 PATH，无法自动恢复（可手动：cd $root\server; npm run start:prod）" }
else {
  $list = (& pm2 jlist 2>$null | Out-String)
  $have = @()
  if ($list) { $have = [regex]::Matches($list, '"name":"(fish-[a-z-]+|dsh-web)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique }
  $missing = @($expected | Where-Object { $have -notcontains $_ })

  if ($missing.Count -eq 0) { Ok "pm2 里 5 个应用都在：$($expected -join ', ')" }
  else {
    Warn "pm2 缺少：$($missing -join ', ')"
    if ($Check) { Info "（-Check 不恢复；正式运行会执行 pm2 resurrect）" }
    else {
      Info "pm2 resurrect（恢复上次保存的进程表）"
      & pm2 resurrect 2>$null | Out-Null
      Start-Sleep -Seconds 5
      $list2 = (& pm2 jlist 2>$null | Out-String)
      $have2 = @()
      if ($list2) { $have2 = [regex]::Matches($list2, '"name":"(fish-[a-z-]+|dsh-web)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique }
      $still = @($expected | Where-Object { $have2 -notcontains $_ })
      if ($still.Count -eq 0) { Ok "pm2 已恢复全部应用" }
      else {
        Bad "仍缺：$($still -join ', ')"
        Info "手动补起（示例）："
        Info "  cd $root\server; pm2 start npm --name fish-server -- run start:prod"
        Info "  cd $root;        pm2 start npm --name fish-admin -- run start"
      }
    }
  }
}

# -----------------------------------------------------------------------------
Step 3 "服务端健康检查"
# -----------------------------------------------------------------------------
if (Test-Health) { Ok "$api/health -> 200" }
elseif ($Check) { Warn "健康检查失败（-Check 不修）" }
else {
  Info "等待服务端就绪（最多 90s）"
  $deadline = (Get-Date).AddSeconds(90); $up = $false
  while ((Get-Date) -lt $deadline) { if (Test-Health) { $up = $true; break }; Start-Sleep -Seconds 3 }
  if ($up) { Ok "$api/health -> 200" } else { Bad "服务端仍未就绪：看 pm2 logs fish-server --lines 50" }
}

# -----------------------------------------------------------------------------
Step 4 "公网隧道地址"
# -----------------------------------------------------------------------------
$newUrl = $null
if ($SkipTunnel) { Warn "-SkipTunnel：不动隧道（沿用手上地址，重启后通常已失效）" }
elseif ($Check) {
  Info "（-Check 不重启隧道）"
  $log = (& pm2 logs fish-tunnel --lines 200 --nostream 2>$null | Out-String)
  $m = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
  if ($m.Count -gt 0) { $newUrl = $m[$m.Count - 1].Value }
}
else {
  Info "重启 cloudflared 获取新地址"
  & pm2 restart fish-tunnel 2>$null | Out-Null
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline -and -not $newUrl) {
    Start-Sleep -Seconds 4
    $log = (& pm2 logs fish-tunnel --lines 200 --nostream 2>$null | Out-String)
    $m = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($m.Count -gt 0) { $newUrl = $m[$m.Count - 1].Value }
  }
  if ($newUrl) { Ok "新隧道地址：$newUrl" } else { Bad "90s 内没抓到 trycloudflare 地址：看 pm2 logs fish-tunnel" }
}

# -----------------------------------------------------------------------------
Step 5 "发布地址（config/client-config.json + site 副本）"
# -----------------------------------------------------------------------------
if ($Check) { Info "（-Check 不写入）正式运行会执行 scripts\publish-address.ps1" }
else {
  Push-Location $root
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\publish-address.ps1" 2>&1 |
      Select-Object -Last 12 | ForEach-Object { Info "$_" }
  } finally { Pop-Location }
  if (Test-Path "$root\config\client-config.json") {
    $cfg = Get-Content "$root\config\client-config.json" -Raw | ConvertFrom-Json
    Ok "client-config.json 的 api = $($cfg.api)"
    Info "updatedAt = $($cfg.updatedAt)"
  } else { Bad "client-config.json 缺失" }
}

# -----------------------------------------------------------------------------
Step 5b "同步 Gitee 引导站（App / exe 靠它自动发现新地址）"
# -----------------------------------------------------------------------------
# WHY: the tunnel gets a new domain on every reboot, and the clients discover it
# from the Gitee raw copy of client-config.json. Publishing the local config is
# NOT enough -- the Gitee copy must be refreshed too, or every client silently
# falls back to stale addresses (seen 2026-10-11: Gitee still had the 10-06 domain).
# Credentials come from server/.env (GITEE_OWNER / GITEE_REPO / GITEE_TOKEN).
$gOwner2 = $null; $gRepo2 = $null; $gToken2 = $null
$envFile2 = Join-Path $root 'server\.env'
if (Test-Path $envFile2) {
  $envText2 = Get-Content $envFile2 -Raw
  $gOwner2 = ([regex]::Match($envText2, '(?m)^GITEE_OWNER=(.+)$')).Groups[1].Value.Trim()
  $gRepo2  = ([regex]::Match($envText2, '(?m)^GITEE_REPO=(.+)$')).Groups[1].Value.Trim()
  $gToken2 = ([regex]::Match($envText2, '(?m)^GITEE_TOKEN=(.+)$')).Groups[1].Value.Trim()
}
$giteePublisher = Join-Path $root 'scripts\tmp\publish-bootstrap-gitee.ps1'
if (-not $gOwner2 -or -not $gRepo2 -or -not $gToken2) {
  Warn "server/.env 里缺 GITEE_OWNER/GITEE_REPO/GITEE_TOKEN -> 跳过 Gitee 同步（客户端将只能靠内置候选）"
} elseif (-not (Test-Path $giteePublisher)) {
  Warn "找不到 $giteePublisher -> 跳过"
} elseif ($Check) {
  Info "（-Check 不推送）正式运行会推送到 $gOwner2/$gRepo2"
} else {
  $env:GITEE_TOKEN = $gToken2
  $env:GITEE_OWNER = $gOwner2
  $env:GITEE_REPO  = $gRepo2
  if (-not $env:GITEE_BRANCH) { $env:GITEE_BRANCH = 'main' }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $giteePublisher -Apply 2>&1 |
    Select-String -Pattern 'push result|raw verify|FAILED' | ForEach-Object { Info "$($_.Line.Trim())" }
  if ($LASTEXITCODE -eq 0) { Ok "Gitee 引导已同步" } else { Warn "Gitee 推送返回非零（看上面 raw verify 行）" }
}

# -----------------------------------------------------------------------------
Step 6 "二维码与 App 是否需要重发"
# -----------------------------------------------------------------------------
# 6a: which download id does the QR have to point at?
$dlId = $null
try {
  $env6 = Get-Content "$root\server\.env" -Raw
  $dbUser = ([regex]::Match($env6, '(?m)^DB_USER=(.+)$')).Groups[1].Value.Trim()
  $dbPass = ([regex]::Match($env6, '(?m)^DB_PASSWORD=(.+)$')).Groups[1].Value.Trim()
  $dbName = ([regex]::Match($env6, '(?m)^DB_NAME=(.+)$')).Groups[1].Value.Trim()
  if ($dbUser -and $dbName) {
    $sql = "SELECT id FROM app_version WHERE app_type='boss' AND status=1 ORDER BY version_code DESC LIMIT 1;"
    $out6 = $sql | docker exec -i -e MYSQL_PWD=$dbPass fish-mysql sh -c "mysql --default-character-set=utf8mb4 -u$dbUser -N -B $dbName" 2>$null
    if ($out6) { $dlId = "$out6".Trim() }
  }
} catch {}
if ($dlId) { Ok "当前启用版本的下载 id = $dlId" } else { Warn "取不到启用版本 id（服务端/DB 未就绪？）" }

# 6b: are the app's bootstrap sources alive? (if all dead -> the app cannot
#     discover a changed address by itself -> a new APK is required)
#     Parsed from the app source so this check can never drift from what the
#     shipped APK actually uses (defaults: apps/packages/core/lib/src/config/app_address.dart)
$boots = @()
$addrFile = Join-Path $root 'apps\packages\core\lib\src\config\app_address.dart'
if (Test-Path $addrFile) {
  $src = Get-Content $addrFile -Raw
  $boots = @([regex]::Matches($src, "https://(gitee\.com|cdn\.jsdelivr\.net|raw\.githubusercontent\.com)/[^'""\s]+client-config\.json") |
    ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '[<>]' } | Sort-Object -Unique)
}
if ($boots.Count -eq 0) {
  Warn "没能从 app_address.dart 解析出 bootstrap 地址，退回内置默认"
  $boots = @(
    'https://cdn.jsdelivr.net/gh/kslingyun/fish-endpoint@main/client-config.json',
    'https://raw.githubusercontent.com/kslingyun/fish-endpoint/main/client-config.json'
  )
}
# Gitee raw bootstrap: the URL is injected at BUILD time (--dart-define), so it is
# not a literal in app_address.dart. Derive it from server/.env, which is the same
# source the publisher (scripts/tmp/publish-bootstrap-gitee.ps1) and release-app.js use.
$envFile = Join-Path $root 'server\.env'
if (Test-Path $envFile) {
  $envText = Get-Content $envFile -Raw
  $gOwner = ([regex]::Match($envText, '(?m)^GITEE_OWNER=(.+)$')).Groups[1].Value.Trim()
  $gRepo  = ([regex]::Match($envText, '(?m)^GITEE_REPO=(.+)$')).Groups[1].Value.Trim()
  $gBranch = ([regex]::Match($envText, '(?m)^GITEE_BRANCH=(.+)$')).Groups[1].Value.Trim()
  if (-not $gBranch) { $gBranch = 'main' }
  if ($gOwner -and $gRepo) {
    $gUrl = "https://gitee.com/$gOwner/$gRepo/raw/$gBranch/client-config.json"
    if ($boots -notcontains $gUrl) { $boots = @($gUrl) + $boots }
  }
}
$alive = @()
foreach ($b in $boots) {
  try { $code = (Invoke-WebRequest -Uri $b -TimeoutSec 8 -UseBasicParsing).StatusCode } catch { $code = 0 }
  if ($code -eq 200) { $alive += $b }
  Info "bootstrap [$code] $b"
}
if ($alive.Count -gt 0) {
  Ok "至少一个 bootstrap 源可用 -> 换地址不需要重发 APK"
  Info "（注意：仅对【构建时注入了该引导源】的 APK 成立；1.11.34 及更早版本未注入 Gitee 引导，仍需重发）"
}
else {
  Bad "三个 bootstrap 源都不可用"
  Warn "=> 隧道地址一变，手机上已装的 App 无法自行发现新地址，需要发一版新 APK："
  Info "   node scripts/release-boss.js <下一个码> <下一个版本名> `"服务地址更新`""
}

# 6c: refresh the QR image if a generator exists
$gen = Get-ChildItem "$root\scripts" -Recurse -File -Include *.js, *.mjs, *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'qr' -and $_.Name -notmatch 'decode|read|verify' } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($gen) {
  if ($Check) { Info "（-Check 不生成）二维码生成器：$($gen.FullName.Replace("$root\", ''))" }
  else {
    Info "刷新二维码：$($gen.Name)"
    node $gen.FullName 2>&1 | Select-Object -Last 6 | ForEach-Object { Info "$_" }
    if (Test-Path "$root\site\download\download-temp-apk-boss.png") {
      Ok "二维码已更新：$((Get-Item "$root\site\download\download-temp-apk-boss.png").LastWriteTime)"
    }
  }
} else { Warn "没找到二维码生成脚本，跳过（可手动刷新 site/download/download-temp-apk-boss.png）" }

# -----------------------------------------------------------------------------
Step 7 "汇总"
# -----------------------------------------------------------------------------
$finalHealth = Test-Health
Write-Host ""
Info "服务端健康：$(if ($finalHealth) { '200 OK' } else { '不可用' })"
Info "当前公网地址：$(if ($newUrl) { $newUrl } else { '(未抓到，见上一步)' })"
Info "二维码下载 id：$(if ($dlId) { $dlId } else { '未知' })"
Info "App 是否需重发：$(if ($alive.Count -gt 0) { '不需要（bootstrap 可用）' } else { '需要（bootstrap 全挂）' })"
if (-not $Check) {
  Write-Host ""
  Write-Host "恢复完成。" -ForegroundColor Green
  Info "手机端自检：打开 App -> 我的 -> 关于/更新检查；或直接重装：$root\site\download\download-temp-apk-boss.png"
}
