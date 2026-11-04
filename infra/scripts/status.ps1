# 服务状态检查：容器健康 / 后端端口 / cloudflared / 后端错误日志尾部
# 用法：npm run infra:status
. "$PSScriptRoot\common.ps1"
$infraDir = Split-Path -Parent $PSScriptRoot

Write-Host '==== 容器状态 ===='
docker ps -a --filter "name=fish-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host 'Docker 未运行，无法检查容器状态' }

Write-Host ''
$serverPort = Get-ServerPort
Write-Host "==== 后端（端口 $serverPort）===="
if (Test-PortListening -Port $serverPort) { Write-Host "运行中（http://localhost:$serverPort/api/v1/health）" } else { Write-Host '未运行' }

Write-Host ''
Write-Host '==== Cloudflare Tunnel ===='
$svc = Get-Service cloudflared -ErrorAction SilentlyContinue
if ($svc) { Write-Host "cloudflared 服务：$($svc.Status)" } else { Write-Host 'cloudflared 服务未安装（M9 部署）' }

Write-Host ''
$errLog = Join-Path (Get-DataDir) 'logs\server.err.log'
if (Test-Path $errLog) {
    Write-Host '==== 后端错误日志（最后 20 行）===='
    Get-Content $errLog -Tail 20
} else {
    Write-Host '==== 后端错误日志 ===='
    Write-Host '暂无 data/logs/server.err.log'
}
