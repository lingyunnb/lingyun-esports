# 公共函数：infra 各脚本共享
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# 用法：. "$PSScriptRoot\common.ps1"

# 读取 infra/.env（KEY=VALUE 格式，忽略注释与空行）
function Read-InfraEnv {
    param([string]$EnvPath)
    if (-not (Test-Path $EnvPath)) { throw "缺少环境配置 $EnvPath，请从 .env.example 复制一份并修改密码" }
    $envMap = @{}
    foreach ($line in Get-Content $EnvPath) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) {
            $idx = $t.IndexOf('=')
            if ($idx -gt 0) { $envMap[$t.Substring(0, $idx).Trim()] = $t.Substring($idx + 1).Trim() }
        }
    }
    return $envMap
}

# 检查 Docker 是否可用（不可用则给出明确原因）
function Assert-Docker {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw "Docker 未运行。请先启动 Docker Desktop，再执行 npm run infra:start" }
}

# 等待容器健康（$Name 容器名，$Seconds 最长等待秒数）
function Wait-ContainerHealthy {
    param([string]$Name, [int]$Seconds = 120)
    for ($i = 0; $i -lt $Seconds; $i += 3) {
        $state = docker inspect --format '{{.State.Health.Status}}' $Name 2>$null
        if ($state -eq 'healthy') { return $true }
        Start-Sleep -Seconds 3
    }
    $state = docker inspect --format '{{.State.Health.Status}}' $Name 2>$null
    throw "容器 $Name 未在 $Seconds 秒内就绪（当前状态：$state）。请 docker logs $Name 查看原因"
}

# 数据目录：<仓库根>\data（D 盘数据规划：数据库/Redis bind mount、备份、日志、上传文件均在此）
function Get-DataDir {
    return Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data'
}

# 后端端口：优先读 server/.env 的 PORT（默认 3100）
function Get-ServerPort {
    $serverEnv = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'server\.env'
    if (Test-Path $serverEnv) {
        $map = Read-InfraEnv $serverEnv
        if ($map.ContainsKey('PORT') -and $map['PORT'] -match '^\d+$') { return [int]$map['PORT'] }
    }
    return 3100
}

# 检查本机端口是否被监听
function Test-PortListening {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

# 停止监听指定端口的进程（用于停止后端）
function Stop-ProcessByPort {
    param([int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        Write-Host "停止占用端口 $Port 的进程 PID=$($c.OwningProcess)"
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
    }
}
