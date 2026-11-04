# 手机插上后一键推装最新双端 APK（幂等，可反复执行）
$ErrorActionPreference = 'Continue'
$adb = 'D:\Android\sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }

Write-Output ('=== 推装双端 ' + (Get-Date -Format 'HH:mm:ss') + ' ===')
$devices = (& $adb devices) -join "`n"
Write-Output $devices
if ($devices -notmatch 'device\s') {
    Write-Output '✗ 未检测到手机：请用 USB 连接并在手机上允许 USB 调试后重跑本脚本'
    exit 1
}

$apks = @(
    @{ name = '老板端 祁连山电竞'; path = 'D:\fish\apps\boss-app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'; pkg = 'com.fish.boss_app' },
    @{ name = '工作端 祁连山电竞内部'; path = 'D:\fish\apps\worker-app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'; pkg = 'com.fish.worker_app' }
)

foreach ($a in $apks) {
    if (-not (Test-Path $a.path)) { Write-Output ('✗ 缺少安装包：' + $a.path); continue }
    $size = [math]::Round((Get-Item $a.path).Length / 1MB, 1)
    Write-Output ('--- 安装 ' + $a.name + " (${size}MB) ---")
    & $adb install -r -t $a.path 2>&1 | Select-Object -Last 3 | Out-String
}

Write-Output '--- 手机当前版本 ---'
& $adb shell dumpsys package com.fish.boss_app 2>&1 | Select-String 'versionName' | Select-Object -First 1 | ForEach-Object { '老板端: ' + $_.Line.Trim() }
& $adb shell dumpsys package com.fish.worker_app 2>&1 | Select-String 'versionName' | Select-Object -First 1 | ForEach-Object { '工作端: ' + $_.Line.Trim() }
Write-Output '=== 完成（若手机提示「不允许安装」，请在手机上允许 USB 安装后重跑）==='
