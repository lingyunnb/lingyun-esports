import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 云端更新 UI（双端共用）：更新弹窗与强制更新阻断页的渲染契约
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  const info = AppUpdateInfo(
    hasUpdate: true,
    force: false,
    versionCode: 11,
    versionName: '1.0.9',
    updateDesc: '打手端支持小数积分；修复订单页闪退',
    fileSize: 19618949,
    fileHash: 'abc',
    downloadUrl: 'http://example.com/app.apk',
  );

  setUp(() => UpdateCenter.instance.configure('worker'));

  testWidgets('更新弹窗：展示版本号/更新说明/安装包大小 + 普通更新可稍后', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateDialog(info: info))));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v1.0.9'), findsOneWidget);
    expect(find.textContaining('打手端支持小数积分'), findsOneWidget);
    expect(find.text('安装包大小 18.7 MB'), findsOneWidget);
    expect(find.text('稍后更新'), findsOneWidget); // 普通更新可关闭
    expect(find.text('立即更新'), findsOneWidget);
  });

  testWidgets('强制更新弹窗：显示重要更新提示、无「稍后更新」', (tester) async {
    const forced = AppUpdateInfo(
      hasUpdate: true,
      force: true,
      versionCode: 12,
      versionName: '1.1.0',
      updateDesc: '重要修复',
      fileSize: 19618949,
      fileHash: 'abc',
      downloadUrl: 'http://example.com/app.apk',
    );
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateDialog(info: forced))));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v1.1.0'), findsOneWidget);
    expect(find.textContaining('需完成更新后才能继续使用'), findsOneWidget);
    expect(find.text('稍后更新'), findsNothing);
    expect(find.text('立即更新'), findsOneWidget);
  });

  testWidgets('强制更新阻断页：版本号/说明/立即更新/退出应用', (tester) async {
    UpdateCenter.instance.forceBlocked = true;
    // 阻断页读取 latest（未检测时为空，页面仍需可渲染）
    await tester.pumpWidget(const MaterialApp(home: UpdateBlockPage()));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);
    UpdateCenter.instance.forceBlocked = false;
  });

  testWidgets('下载失败态（停滞判死后）：明确文案 + 「重试下载」，不再停在「计算中…」', (tester) async {
    // 2026-10-17 线上故障：下载卡在 75%、0.00 MB/s、永不结束、也永不失败 ——
    // 用户只能看着「计算中…」干等。落地停滞看门狗后，卡死到上限一定会变成这个失败态：
    // ① 说清楚发生了什么；② 说明进度已保留；③ 给一个点得动的重试入口。
    final center = UpdateCenter.instance;
    center.debugSetFailureForShot(AppUpdater.stalledMessage, downloaded: 16609443, total: 23158740);
    addTearDown(center.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateDialog(info: info))));
    await tester.pumpAndSettle();

    expect(find.text('更新失败'), findsOneWidget);
    expect(find.text(AppUpdater.stalledMessage), findsOneWidget, reason: '失败文案必须具体（含"已保留进度，点击重试"）');
    expect(find.text('重试下载'), findsOneWidget, reason: '必须有重试入口（重试会接着已下部分续传）');
    expect(find.text('计算中…'), findsNothing, reason: '绝不允许停在「计算中…」');
    expect(find.textContaining('正在下载安装包'), findsNothing);
  });

  testWidgets('停滞重试期间：显示重试计数 + 已保留进度（进度条不回退）', (tester) async {
    // 停滞时"没有错误、速度 0.00 MB/s"，最坏 ~3 分钟才出失败态 —— 这段窗口必须明确说
    // "正在重试"，否则用户看到的就是卡死（负责人原话："网没问题但卡住不下了"）。
    final center = UpdateCenter.instance;
    const int downloaded = 16609443; // ≈ 75% of 22.1MB
    const int total = 23158740;
    center.debugSetProgressForShot(
      downloaded: downloaded,
      total: total,
      speedBytesPerSecond: 0,
      parallel: true,
      stallAttempt: 1,
      stallMax: 3,
    );
    addTearDown(center.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateDialog(info: info))));
    await tester.pumpAndSettle();

    // ① 重试计数可见（第 1 次重试）+ 说明"只补未完成的部分"（重试是按片重取，不是整包重下）
    expect(find.text('网络缓慢，正在重试（1/3），只补未完成的部分…'), findsOneWidget);
    // ② 速度那一行不再说「计算中…」（那会让人以为还在正常算剩余时间）
    expect(find.text('0.00 MB/s · 正在重试'), findsOneWidget);
    expect(find.textContaining('计算中'), findsNothing);
    // ③ 进度不回退：百分比与"已下/总量"都还是原来那份
    expect(find.text('72%'), findsOneWidget);
    expect(find.text('15.8 MB / 22.1 MB'), findsOneWidget, reason: '已保留的进度必须照旧显示，不许看起来归零');
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.717, 0.01),
        reason: '进度条不许归零');

    // ④ 退到最后一轮时给更明确的预期（不是无限等）
    center.debugSetProgressForShot(
      downloaded: downloaded,
      total: total,
      speedBytesPerSecond: 0,
      parallel: false,
      stallAttempt: 3,
      stallMax: 3,
    );
    await tester.pumpAndSettle();
    expect(find.text('网络缓慢，最后一次重试（3/3），仍无进展将中断下载…'), findsOneWidget);
    expect(find.text('15.8 MB / 22.1 MB'), findsOneWidget, reason: '最后一轮同样不许动进度');
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.717, 0.01));
    expect(find.textContaining('计算中'), findsNothing, reason: '重试期间不能只留"计算中…"');
  });
}
