# 初始化数据库：幂等建库（utf8mb4）→ 执行后端 migration
# 用法：npm run db:init
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$infraDir = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $infraDir
$envMap = Read-InfraEnv (Join-Path $infraDir '.env')
Assert-Docker

$db = $envMap['MYSQL_DATABASE']
Write-Host "==> 确保数据库 $db 存在（utf8mb4）"
$sql = "CREATE DATABASE IF NOT EXISTS ``$db`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$sql | docker exec -i -e "MYSQL_PWD=$($envMap['MYSQL_ROOT_PASSWORD'])" fish-mysql mysql -u root
if ($LASTEXITCODE -ne 0) { throw '建库失败' }

$migrationsDir = Join-Path $root 'server\src\migrations'
$hasMigration = $false
if (Test-Path $migrationsDir) {
    $hasMigration = [bool](Get-ChildItem $migrationsDir -Filter '*.ts' -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if ($hasMigration) {
    Write-Host '==> 执行数据库 migration'
    Push-Location (Join-Path $root 'server')
    try {
        npm run migration:run
        if ($LASTEXITCODE -ne 0) { throw 'migration:run 失败' }
    } finally {
        Pop-Location
    }
} else {
    Write-Host '暂无 migration（M1 起随模块添加）'
}
Write-Host '初始化完成'
