# 恢复备份：先自动备份当前库（安全网）→ 导入指定备份（.zip 或 .sql）
# 用法：npm run db:restore -- -BackupFile infra/backup/fish_20260920_120000.zip
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupFile
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$infraDir = Split-Path -Parent $PSScriptRoot
$envMap = Read-InfraEnv (Join-Path $infraDir '.env')
Assert-Docker

if (-not (Test-Path $BackupFile)) { throw "备份文件不存在：$BackupFile" }
if ($BackupFile -notmatch '\.zip$' -and $BackupFile -notmatch '\.sql$') { throw '仅支持 .zip 或 .sql 备份文件' }

Write-Host '==> 恢复前先备份当前数据库（安全网）'
& "$PSScriptRoot\backup-db.ps1"

$sqlPath = $BackupFile
$tmpDir = $null
if ($BackupFile -match '\.zip$') {
    $tmpDir = Join-Path $env:TEMP ("fish_restore_" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $BackupFile -DestinationPath $tmpDir
    $sqlPath = Get-ChildItem $tmpDir -Filter '*.sql' | Select-Object -First 1 -ExpandProperty FullName
    if (-not $sqlPath) { throw '压缩包内未找到 .sql 文件' }
}

Write-Host "==> 导入 $sqlPath"
$db = $envMap['MYSQL_DATABASE']
Get-Content $sqlPath -Raw | docker exec -i -e "MYSQL_PWD=$($envMap['MYSQL_PASSWORD'])" fish-mysql mysql -u "$($envMap['MYSQL_USER'])" "$db"
if ($LASTEXITCODE -ne 0) { throw '导入失败，请查看上方错误输出' }

if ($tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host '恢复完成。请执行 npm run infra:status 并抽查核心表（user/wallet/order）数据'
