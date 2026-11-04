# 数据库备份：mysqldump 一致性快照 → zip 归档 → 自动清理 14 天前的备份
# 用法：npm run db:backup（备份到 infra/backup/）
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$infraDir = Split-Path -Parent $PSScriptRoot
$envMap = Read-InfraEnv (Join-Path $infraDir '.env')

Assert-Docker
$backupDir = Join-Path (Get-DataDir) 'backups'
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$sqlFile = Join-Path $backupDir "fish_$stamp.sql"
$zipFile = Join-Path $backupDir "fish_$stamp.zip"
$db = $envMap['MYSQL_DATABASE']

Write-Host "==> 备份数据库 $db"
# MYSQL_PWD 通过容器环境变量传递，避免密码出现在命令行
# 注意：PS 5.1 参数模式必须用 "$(...)" 子表达式传 envMap 值，直接 $map['key'] 会被错误展开
docker exec -e "MYSQL_PWD=$($envMap['MYSQL_PASSWORD'])" fish-mysql mysqldump -u "$($envMap['MYSQL_USER'])" --single-transaction --routines --triggers --no-tablespaces "$db" | Set-Content -Encoding utf8 -Path $sqlFile
if ($LASTEXITCODE -ne 0) { throw 'mysqldump 失败' }

# 校验 dump 完成标记（文件尾部）
$tail = Get-Content $sqlFile -Tail 1
if ($tail -notmatch 'Dump completed') { throw "备份不完整（尾部：$tail）" }

Compress-Archive -Path $sqlFile -DestinationPath $zipFile
Remove-Item $sqlFile
Write-Host "备份完成：$zipFile（$([math]::Round((Get-Item $zipFile).Length / 1KB, 1)) KB）"

# 清理 14 天前的备份
$old = Get-ChildItem $backupDir -Filter 'fish_*.zip' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) }
foreach ($f in $old) { Remove-Item $f.FullName; Write-Host "已清理过期备份：$($f.Name)" }
Write-Host '备份完成'
