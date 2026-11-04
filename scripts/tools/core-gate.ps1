<#
.SYNOPSIS
  core-gate：并行改 `apps/packages/core/**` 时的一键编译门。

.DESCRIPTION
  背景（负责人 2026-10-06）：今天两次并行任务因为 core 的**中间态**（`library` 指令位置错、
  依赖包正在改）互相阻塞 —— 一个任务把 core 改到编译不过，另一个任务跑 `flutter test` 时
  整包加载失败，排查成本全落在"不是我改的那行"上。

  本脚本把"我这次改动有没有把 core 系列包改坏"变成一条命令：依次对
    apps/packages/core · apps/boss-app · apps/worker-app
  跑 `flutter analyze`，**任一失败即以非零退出**，输出精简到"每包一行结论 + 失败时的关键错误行"。

  判定口径：**以 `flutter analyze` 的退出码为准**（有 error → 非 0；只有 warning/info → 仍为 0，
  与开发者手跑 `flutter analyze` 完全一致，不额外加严也不放宽）。

  用法（仓库根）：
    powershell -NoProfile -File scripts/tools/core-gate.ps1
    powershell -NoProfile -File scripts/tools/core-gate.ps1 -NoPub        # 跳过隐式 pub get（离线/最快）
    powershell -NoProfile -File scripts/tools/core-gate.ps1 -Packages apps/packages/core
    powershell -NoProfile -File scripts/tools/core-gate.ps1 -TimeoutSec 900 -MaxErrorLines 20

  退出码：0 = 全部通过；1 = 至少一个包失败（或 flutter 不可用 / 超时 / 包目录缺失）。
  规范依据：docs/12-测试规范.md「改 core 前后必须过 core-gate」。

  实现注记（踩过的两个坑，勿回退）：
  1. **脚本必须存成 UTF-8 with BOM**：Windows PowerShell 5.1 读无 BOM 的 UTF-8 脚本会按 ANSI 解，
     中文注释/字符串被拆坏 → 报一堆"语法错误"（实测）。改动本文件后请确认 BOM 仍在。
  2. **不能用 `Start-Process -PassThru` 取退出码**：本机实测（PS 5.1）它在 `WaitForExit()` 之后
     `ExitCode` 仍为 `$null`，会把 `No issues found!` 误判成失败。改用 .NET `Process` 直接起进程：
     超时可控 + 退出码可靠 + 输出流按 UTF-8 读。
#>
[CmdletBinding()]
param(
  # 要检查的包（默认三包：core + 两端；路径相对仓库根，正斜杠/反斜杠都行）
  [string[]]$Packages = @('apps/packages/core', 'apps/boss-app', 'apps/worker-app'),
  # 每个包的 `flutter analyze` 超时（秒）——防"卡住不动"（不卡死铁律）
  [int]$TimeoutSec = 600,
  # 失败时最多贴多少行关键问题（error/warning/info 行）
  [int]$MaxErrorLines = 12,
  # 加 `--no-pub`：不触发隐式 `pub get`（更快、完全离线；依赖刚变过时建议不加）
  [switch]$NoPub
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

Write-Host '=== core-gate：core 系列包编译门（flutter analyze）==='
Write-Host "仓库根：$repoRoot"
if ($NoPub) { Write-Host '模式：--no-pub（不做隐式 pub get）' }

# flutter 可执行文件（Windows 下通常是 flutter.bat → 必须经 cmd.exe 启动）
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
  Write-Host 'core-gate: FAIL — flutter 不在 PATH（先按 docs/22-开发环境清单.md 配好 Flutter）' -ForegroundColor Red
  exit 1
}
$flutterExe = $flutter.Source

$analyzeArgs = 'analyze'
if ($NoPub) { $analyzeArgs += ' --no-pub' }

# 单个包跑 analyze：超时可控 + 退出码可靠 + 输出按 UTF-8 读（见文件头注记 2）
function Invoke-Analyze {
  param([string]$PkgPath, [string]$AnalyzeArgs)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  if ($flutterExe -match '\.(bat|cmd)$') {
    $psi.FileName = $env:ComSpec
    $psi.Arguments = "/c `"`"$flutterExe`" $AnalyzeArgs`""
  }
  else {
    $psi.FileName = $flutterExe
    $psi.Arguments = $AnalyzeArgs
  }
  $psi.WorkingDirectory = $PkgPath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.CreateNoWindow = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  # 先异步读干两条流，再 WaitForExit：避免管道写满造成死锁（analyze 输出可能很长）
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { $proc.Kill() } catch { }
    try { [void]$proc.WaitForExit(5000) } catch { }
  }
  $stdout = ''
  $stderr = ''
  try { $stdout = $outTask.GetAwaiter().GetResult() } catch { }
  try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
  $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
  $proc.Dispose()

  $lines = @()
  if ($stdout) { $lines += ($stdout -split "`r?`n") }
  if ($stderr) { $lines += ($stderr -split "`r?`n") }
  $lines = @($lines | Where-Object { $_ -ne '' })

  $summary = ($lines | Where-Object { $_ -match 'issues? found|No issues found' } | Select-Object -Last 1)
  # flutter analyze 的问题行格式：`error - <说明> - <文件:行:列> - <code>`（warning/info 同构）
  $problemLines = @($lines | Where-Object { $_ -match '^\s*(error|warning|info)\s*[-•]' } | Select-Object -First $MaxErrorLines)

  return [pscustomobject]@{
    TimedOut = $timedOut
    ExitCode = $exitCode
    Summary  = if ($summary) { $summary.Trim() } else { '' }
    Problems = $problemLines
    Tail     = @($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 5)
  }
}

$results = @()
$idx = 0
foreach ($pkg in $Packages) {
  $idx += 1
  $pkgPath = Join-Path $repoRoot $pkg
  $name = $pkg -replace '\\', '/'
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  if (-not (Test-Path (Join-Path $pkgPath 'pubspec.yaml'))) {
    Write-Host ("[{0}] {1}  ... FAIL（找不到 pubspec.yaml）" -f $idx, $name) -ForegroundColor Red
    $results += [pscustomobject]@{ Package = $name; Ok = $false; Detail = '找不到 pubspec.yaml' }
    continue
  }

  try {
    $r = Invoke-Analyze -PkgPath $pkgPath -AnalyzeArgs $analyzeArgs
  }
  catch {
    Write-Host ("[{0}] {1}  ... FAIL（启动 flutter 失败：{2}）" -f $idx, $name, $_.Exception.Message) -ForegroundColor Red
    $results += [pscustomobject]@{ Package = $name; Ok = $false; Detail = "启动失败：$($_.Exception.Message)" }
    continue
  }
  $sw.Stop()
  $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

  $passed = (-not $r.TimedOut) -and ([int]$r.ExitCode -eq 0)
  $detail = if ($r.TimedOut) { "超时 > ${TimeoutSec}s（已强杀）" }
  elseif ($r.Summary) { $r.Summary }
  else { "exit=$($r.ExitCode)" }

  if ($passed) {
    Write-Host ("[{0}] {1}  ... OK（{2}，{3}s）" -f $idx, $name, $detail, $secs) -ForegroundColor Green
  }
  else {
    Write-Host ("[{0}] {1}  ... FAIL（{2}，exit={3}，{4}s）" -f $idx, $name, $detail, $r.ExitCode, $secs) -ForegroundColor Red
    if ($r.Problems.Count -gt 0) {
      foreach ($l in $r.Problems) { Write-Host ('        ' + $l.Trim()) -ForegroundColor DarkYellow }
    }
    else {
      # 没有标准问题行（如 pub get 失败 / 包加载失败）→ 贴最后几行，避免"失败但看不到原因"
      foreach ($l in $r.Tail) { Write-Host ('        ' + $l.Trim()) -ForegroundColor DarkYellow }
    }
  }
  $results += [pscustomobject]@{ Package = $name; Ok = $passed; Detail = $detail }
}

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host ''
if ($failed.Count -eq 0) {
  Write-Host ("core-gate: PASS — {0}/{0} 包 analyze 通过（可以安全地继续改 core 或跑测试）" -f $results.Count) -ForegroundColor Green
  exit 0
}
Write-Host ("core-gate: FAIL — {0}/{1} 包未通过：{2}" -f $failed.Count, $results.Count, (($failed | ForEach-Object { $_.Package }) -join ', ')) -ForegroundColor Red
Write-Host '（core 处于中间态时，先修到门通过再让别的任务跑测试 —— docs/12-测试规范.md）' -ForegroundColor Red
exit 1
