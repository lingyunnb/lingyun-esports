# 一键停止：后端进程 → 停止容器（保留数据卷）
# 用法：npm run infra:stop
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$infraDir = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $infraDir 'docker-compose.yml'
$envFile = Join-Path $infraDir '.env'

Write-Host '==> 停止后端'
Stop-ProcessByPort -Port (Get-ServerPort)

Write-Host '==> 停止容器（数据卷保留）'
if (Test-Path $envFile) {
    docker compose -f $composeFile --env-file $envFile down
    if ($LASTEXITCODE -ne 0) { throw 'docker compose down 失败' }
} else {
    Write-Host '未找到 infra/.env，跳过容器停止'
}
Write-Host '已停止。重新启动：npm run infra:start'
