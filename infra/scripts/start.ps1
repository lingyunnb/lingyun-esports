# 一键启动：MySQL/Redis 容器 → 等待就绪 → 启动后端（已构建时）
# 用法：npm run infra:start（或 powershell -File infra/scripts/start.ps1）
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$infraDir = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $infraDir
$composeFile = Join-Path $infraDir 'docker-compose.yml'
$envFile = Join-Path $infraDir '.env'
$logDir = Join-Path (Get-DataDir) 'logs'

if (-not (Test-Path $envFile)) { throw "缺少 $envFile，请从 infra/.env.example 复制并配置" }
Assert-Docker

Write-Host '==> 启动 MySQL / Redis 容器'
docker compose -f $composeFile --env-file $envFile up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose up 失败' }

Write-Host '==> 等待容器就绪（首次拉取镜像可能较久）'
Wait-ContainerHealthy -Name 'fish-mysql' | Out-Null
Wait-ContainerHealthy -Name 'fish-redis' | Out-Null
Write-Host '数据库与 Redis 已就绪'

# 后端：已构建且端口空闲时自动启动
$serverPort = Get-ServerPort
$serverDist = Join-Path $root 'server\dist\main.js'
if (Test-Path $serverDist) {
    if (Test-PortListening -Port $serverPort) {
        Write-Host "后端已在运行（端口 $serverPort）"
    } else {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        Write-Host '==> 启动后端'
        Start-Process -FilePath 'node' -ArgumentList 'dist/main.js' -WorkingDirectory (Join-Path $root 'server') `
            -RedirectStandardOutput (Join-Path $logDir 'server.out.log') `
            -RedirectStandardError (Join-Path $logDir 'server.err.log') -WindowStyle Hidden
        Start-Sleep -Seconds 3
        if (Test-PortListening -Port $serverPort) { Write-Host "后端已启动（http://localhost:$serverPort/api/v1/health）" }
        else { Write-Host '后端进程已拉起但端口未监听，请查看 infra/logs/server.err.log' }
    }
} else {
    Write-Host "后端未构建（$serverDist 不存在），请 cd server && npm run start:dev 手动启动"
}

Write-Host ''
Write-Host '==> 启动完成。状态检查：npm run infra:status'
