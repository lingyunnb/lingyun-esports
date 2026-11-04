# FISH 服务一键启动（幂等，docs/11）：Docker(MySQL/Redis) → pm2(后端+隧道) → 健康检查
# 注意：只操作 fish 项目资源，绝不触碰 OtherProject-* 容器/服务
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host "== FISH 服务启动 =="

# 1. Docker 容器（MySQL 8.4 + Redis 7，compose 项目 fish）
Write-Host "[1/4] 检查 Docker 容器…"
$dockerUp = docker ps --filter "name=fish-mysql" --filter "name=fish-redis" --format "{{.Names}}" 2>$null
if ($dockerUp -notcontains 'fish-mysql' -or $dockerUp -notcontains 'fish-redis') {
    Write-Host "  容器未运行，执行 docker compose up -d …"
    Push-Location (Join-Path $root 'infra')
    docker compose up -d
    Pop-Location
} else {
    Write-Host "  容器已运行"
}

# 2. pm2 服务（后端 + Cloudflare 隧道；pm2 未安装时提示）
Write-Host "[2/4] 启动 pm2 服务…"
$pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
if (-not $pm2) {
    Write-Host "  pm2 未安装，请先执行 npm install -g pm2（或以 node dist/main.js 直跑）"
    return
}
Push-Location (Join-Path $root 'server')
pm2 start ecosystem.config.js --only fish-server,fish-tunnel 2>$null | Out-Null
pm2 save 2>$null | Out-Null
Pop-Location
Write-Host "  pm2 已启动（fish-server / fish-tunnel）"

# 3. 健康检查（最多等 30s）
Write-Host "[3/4] 健康检查…"
$ok = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:3100/api/v1/health' -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -eq 200) { $ok = $true; Write-Host "  后端健康: $($resp.Content.Substring(0, [Math]::Min(80, $resp.Content.Length)))"; break }
    } catch {}
}
if (-not $ok) { Write-Host "  后端未就绪，请查看 pm2 logs fish-server" }

# 4. 隧道地址
Write-Host "[4/4] Cloudflare Tunnel 地址："
Start-Sleep -Seconds 3
$tunnelLog = Join-Path $root 'data\logs\fish-tunnel-out.log'
if (Test-Path $tunnelLog) {
    $match = Select-String -Path $tunnelLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches | Select-Object -Last 1
    if ($match) { Write-Host "  外网入口: $($match.Matches[0].Value)" } else { Write-Host "  隧道启动中，稍后执行 pm2 logs fish-tunnel 查看" }
}
Write-Host "== 完成 =="
