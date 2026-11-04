# FISH 平台 · 电脑重启后一键恢复（2026-09-25）
#
# 做四件事：
#   1) 确认 Docker（MySQL/Redis 容器）已就绪
#   2) 恢复 pm2 服务（fish-server / fish-tunnel / fish-admin）
#   3) 等待服务健康
#   4) 打印当前隧道地址 —— **若与上次不同，必须重发双端 App**（地址烘焙在 APK 里）
#
# 用法： powershell -NoProfile -File scripts\recover-after-reboot.ps1

$ErrorActionPreference = 'Continue'
Write-Host '=== FISH 平台重启恢复 ===' -ForegroundColor Cyan

# 1) Docker 容器
Write-Host '[1/4] 检查 Docker 容器…'
$dockerOk = $false
for ($i = 0; $i -lt 30; $i++) {
  $ps = docker ps --format '{{.Names}}' 2>$null
  if ($ps -match 'fish-mysql') { $dockerOk = $true; break }
  Start-Sleep -Seconds 5
}
if ($dockerOk) {
  Write-Host '  ✓ fish-mysql 运行中'
  # Redis 可能稍慢，再等一会
  for ($i = 0; $i -lt 20; $i++) {
    $ps = docker ps --format '{{.Names}}'
    if ($ps -match 'fish-redis') { Write-Host '  ✓ fish-redis 运行中'; break }
    Start-Sleep -Seconds 3
  }
} else {
  Write-Host '  ! Docker 未就绪：请先启动 Docker Desktop，或运行 npm run infra:start' -ForegroundColor Yellow
}

# 2) pm2 服务（先清理重复进程，再按端口/路径重建）
Write-Host '[2/4] 恢复 pm2 服务…'
pm2 delete fish-server fish-tunnel fish-admin 2>$null | Out-Null
Push-Location D:\fish\server
$env:NODE_ENV = 'production'
pm2 start dist/main.js --name fish-server --cwd D:\fish\server `
  --output "D:\fish\data\logs\fish-server-out.log" --error "D:\fish\data\logs\fish-server-err.log" 2>$null | Out-Null
Pop-Location
Push-Location D:\fish\infra\tunnel
pm2 start "D:\fish\infra\tunnel\cloudflared.exe" --name fish-tunnel --cwd "D:\fish\infra\tunnel" `
  -- tunnel --url http://localhost:3100 --no-autoupdate `
  --output "D:\fish\infra\data\logs\fish-tunnel-out.log" 2>$null | Out-Null
Pop-Location
Push-Location D:\fish\admin-web
pm2 start node_modules/vite/bin/vite.js --name fish-admin --cwd D:\fish\admin-web -- --host 2>$null | Out-Null
Pop-Location
pm2 save 2>$null | Out-Null
Write-Host '  ✓ pm2 已恢复并保存'

# 3) 健康检查
Write-Host '[3/4] 等待服务健康…'
$healthy = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/v1/health' -TimeoutSec 5
    if ($r.data.status -eq 'ok') { $healthy = $true; break }
  } catch { }
  Start-Sleep -Seconds 3
}
if ($healthy) { Write-Host '  ✓ 后端健康（数据库/Redis 就绪）' } else { Write-Host '  ! 后端未就绪，请查看 pm2 logs fish-server' -ForegroundColor Yellow }

# 4) 隧道地址（关键：变化则必须重发 App）
Write-Host '[4/4] 当前隧道地址…'
Start-Sleep -Seconds 8
$log = pm2 logs fish-tunnel --lines 300 --nostream 2>$null | Out-String
$urls = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com') | ForEach-Object { $_.Value }
$current = if ($urls.Count -gt 0) { $urls[-1] } else { '' }
if ($current) {
  Write-Host "  当前: $current" -ForegroundColor Green
  $cacheFile = 'D:\fish\scripts\tmp\.tunnel-url'
  $last = if (Test-Path $cacheFile) { (Get-Content $cacheFile -Raw).Trim() } else { '' }
  if ($last -and $last -ne $current) {
    Write-Host '  ⚠ 隧道地址已变化！已安装的 App 全部失联，必须重发双端：' -ForegroundColor Red
    Write-Host '    node scripts/release-boss.js <码> <版本名> "服务器地址更新"' -ForegroundColor Yellow
    Write-Host '    node scripts/release-worker.js <码> <版本名> "服务器地址更新"' -ForegroundColor Yellow
    Write-Host '    （发布脚本会自动读取当前地址，无需手改）' -ForegroundColor Yellow
  }
  Set-Content -Path $cacheFile -Value $current -NoNewline
} else {
  Write-Host '  ! 未解析到隧道地址，请查看 pm2 logs fish-tunnel' -ForegroundColor Yellow
}

Write-Host '=== 恢复完成 ===' -ForegroundColor Cyan
