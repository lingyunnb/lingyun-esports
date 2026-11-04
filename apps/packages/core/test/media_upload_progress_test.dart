/// 上传进度（2026-10-06 上传体验专项）：节流器纯逻辑 + 进度条 UI + 中文错误文案。
///
/// 要解决的观测问题：弱网（Cloudflare 快速隧道实测上行 16KB/s）下 0.3–1MB 的图要
/// 传 20 秒~1 分钟，原来的界面**只有一个无限转圈** —— 用户无法区分"在传"和"卡死"。
/// 负责人要求：百分比 + 速度 + 已传/总大小 + 慢网提示 + 失败中文可重试。
///
/// 本文件断言三件事：
///   ① [MediaUploadProgresser]：进度回调**单调不减**、节流有效、首帧必发、拿不到总大小
///      时不报假百分比（**纯逻辑，不依赖 Dio 内部回调时序** —— 那种断言很脆）
///   ② [MediaUploadTile]：屏幕上真的出现百分比/速度/已传-总大小/慢网提示/重试按钮
///   ③ [mediaUploadErrorMessage]：失败翻成**中文可上屏**的文案（超时/连不上/401/413/5xx）
library;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ==========================================================================
  // ① 进度节流器（纯逻辑）
  // ==========================================================================
  group('① MediaUploadProgresser 节流与单调性', () {
    test('进度回调被调用，且百分比**单调不减**', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();

      // 模拟 Dio 的分片回调（含重复帧：同一 sent 报告两次）
      for (int i = 0; i <= 800 + 200 + 300; i += 100) {
        p.onSend(i, 1300);
      }
      p.onSend(1300, 1300);

      expect(got, isNotEmpty, reason: '必须真的回调（这就是"真实进度"的来源）');
      int last = -1;
      for (final MediaUploadProgress x in got) {
        expect(x.percent, greaterThanOrEqualTo(last),
            reason: '进度绝不能倒退（界面上的进度条倒退比不显示更糟）');
        last = x.percent;
      }
      expect(got.last.percent, 100);
      expect(got.last.sent, 1300);
      expect(got.last.total, 1300);
      expect(got.last.hasTotal, isTrue);
    });

    test('节流：1000 次分片回调 → 放行次数远少于 1000（不把上传页自己拖慢）', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();
      // 1MB 上传、每 1KB 一帧 = 1024 帧；全部在同一毫秒内（最坏情况）
      for (int i = 1; i <= 1024; i++) {
        p.onSend(i * 1024, 1024 * 1024);
      }
      expect(p.emitted, lessThan(200),
          reason: '节流后放行次数应远小于分片数（1% 一档 ≈ 100 次）');
      expect(p.emitted, greaterThan(50), reason: '但也不能节流到看不见进度');
    });

    test('首帧必发（哪怕 0% 也要给出"已经开始"的信号）', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();
      p.onSend(0, 1000);
      expect(got.length, 1);
      expect(got.first.percent, 0);
    });

    test('**已传字节回退的帧一律丢弃**（重发/多段实现下进度条不倒退）', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();
      p.onSend(500, 1000);
      p.onSend(300, 1000); // 回退帧
      p.onSend(700, 1000);
      final List<int> sents = got.map((MediaUploadProgress x) => x.sent).toList();
      expect(sents, <int>[500, 700]);
    });

    test('拿不到总大小（total<=0）→ 不报假百分比，界面走不确定态', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();
      p.onSend(4096, -1);
      expect(got.single.hasTotal, isFalse);
      expect(got.single.percent, 0);
      expect(got.single.sizeLabel, '4.0 KB', reason: '只显示已传，不显示假的分母');
    });

    test('速度 = 已传 / 耗时（平均值，不是抖动很大的瞬时值）', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final DateTime base = DateTime(2026, 10, 6);
      Duration fake = Duration.zero;
      final MediaUploadProgresser p =
          MediaUploadProgresser(emit: got.add, clock: () => base.add(fake))..start();
      p.onSend(100, 1_000_000); // 首帧（t=0）
      fake = const Duration(seconds: 2);
      p.onSend(2_000_000, 2_000_000); // t=2s，已传 2MB
      expect(got.last.speedBytesPerSecond, 1_000_000, reason: '2MB / 2s = 1MB/s');
      expect(got.last.elapsed, const Duration(seconds: 2));
      expect(MediaUploadProgress.formatSpeed(5_209_716), '5.0 MB/s');
      expect(MediaUploadProgress.formatSpeed(13835), '14 KB/s');
      expect(MediaUploadProgress.formatSpeed(0), '-');
    });

    test('formatBytes：B / KB / MB 三档人话（数字不带多余小数）', () {
      expect(MediaUploadProgress.formatBytes(512), '512 B');
      expect(MediaUploadProgress.formatBytes(1024), '1.0 KB');
      expect(MediaUploadProgress.formatBytes(267670), '261 KB');
      expect(MediaUploadProgress.formatBytes(1024 * 1024), '1.0 MB');
      expect(MediaUploadProgress.formatBytes(-1), '-');
    });

    test('emitted 计数与 start() 重置（换一张图重新开始时状态干净）', () {
      final List<MediaUploadProgress> got = <MediaUploadProgress>[];
      final MediaUploadProgresser p = MediaUploadProgresser(emit: got.add)..start();
      p.onSend(1000, 1000);
      expect(p.emitted, 1);
      p.start();
      expect(p.emitted, 0);
      p.onSend(10, 1000);
      expect(got.last.sent, 10, reason: 'start() 后必须能从头开始报进度');
    });
  });

  // ==========================================================================
  // ② 进度条 UI
  // ==========================================================================
  group('② MediaUploadTile 界面', () {
    Widget host(Widget child) => Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(home: Scaffold(body: child)),
        );

    testWidgets('空闲态：**零占位**（不占高度、不显示任何东西）', (tester) async {
      final MediaUploadState s = MediaUploadState();
      await tester.pumpWidget(host(MediaUploadTile(state: s, label: '背景')));
      expect(tester.getSize(find.byType(MediaUploadTile)).height, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('上传中：出现百分比 + 速度 + 已传/总大小 + 进度条', (tester) async {
      final MediaUploadState s = MediaUploadState()
        ..begin()
        ..update(MediaUploadProgress(
          sent: 267670,
          total: 614400,
          elapsed: const Duration(seconds: 2),
          speedBytesPerSecond: 5_209_716,
        ));
      await tester.pumpWidget(host(MediaUploadTile(state: s, label: '背景')));

      expect(find.text('背景 上传中 44%'), findsOneWidget, reason: '百分比必须在屏幕上（43.563% → 44）');
      expect(find.textContaining('261 KB / 600 KB'), findsOneWidget, reason: '已传/总大小');
      expect(find.textContaining('5.0 MB/s'), findsOneWidget, reason: '速度');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // 两处百分比口径必须同源：进度对象的 percent 与屏上数字一致
      expect(MediaUploadProgress(sent: 267670, total: 614400, elapsed: Duration.zero, speedBytesPerSecond: 0)
          .percent, 44);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已传超过阈值 → 出现「当前网络较慢，正在上传 x%」（**定时器驱动**）', (tester) async {
      // 生产阈值 15s；单测压到 100ms（假时钟能直接推过去）
      MediaUploadSlowHint.debugAfter = const Duration(milliseconds: 100);
      addTearDown(() => MediaUploadSlowHint.debugAfter = null);

      final MediaUploadState s = MediaUploadState();
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) setState) {
          // 页面接线方式：定时器到点 → setState → 提示上屏
          s.onTick = () => setState(() {});
          return MediaUploadTile(state: s, label: '付款截图');
        },
      )));

      s.begin();
      s.update(MediaUploadProgress(
        sent: 130_000,
        total: 1_000_000,
        elapsed: Duration.zero,
        speedBytesPerSecond: 16_000,
      ));
      await tester.pump();
      expect(find.textContaining('网络较慢'), findsNothing, reason: '刚开始不该提示慢网');

      // 推进假时钟越过阈值 → 定时器回调置位并重绘
      await tester.pump(const Duration(milliseconds: 150));
      expect(s.slow, isTrue);
      expect(find.text('当前网络较慢，正在上传 13%'), findsOneWidget,
          reason: '弱网下必须有一行"在传但慢"的明确信号（消灭无限转圈的观感）');
      expect(MediaUploadTile.isSlow(s), isTrue);
      expect(MediaUploadTile.slowHint(13), '当前网络较慢，正在上传 13%');

      // 结束上传 → 定时器取消、提示消失
      // （页面里这一步由 `_doUploadBackground` 的 setState 触发；这里手动重建同一次）
      s.succeed();
      s.onTick!();
      await tester.pump();
      expect(find.textContaining('网络较慢'), findsNothing);
      expect(find.textContaining('上传中'), findsNothing,
          reason: '成功后进度区整块收起（不残留"上传中 100%"）');
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('慢网定时器：上传先结束 → 到点不再重绘（不误报慢网、不悬空）', (tester) async {
      MediaUploadSlowHint.debugAfter = const Duration(milliseconds: 100);
      addTearDown(() => MediaUploadSlowHint.debugAfter = null);

      final MediaUploadState s = MediaUploadState();
      int ticks = 0;
      s.onTick = () => ticks += 1;
      await tester.pumpWidget(host(MediaUploadTile(state: s, label: '背景')));

      s.begin();
      s.succeed(); // 100ms 内就传完了
      await tester.pump(const Duration(milliseconds: 200));
      expect(ticks, 0, reason: '已经传完就不该再报慢网');
      expect(s.slow, isFalse);
    });

    testWidgets('上传 5 秒（还没到阈值）→ **不**提示慢网（不做无病呻吟）', (tester) async {
      final MediaUploadState s = MediaUploadState()
        ..begin(now: DateTime.now().subtract(const Duration(seconds: 5)))
        ..update(MediaUploadProgress(
          sent: 500_000,
          total: 1_000_000,
          elapsed: const Duration(seconds: 5),
          speedBytesPerSecond: 100_000,
        ));
      await tester.pumpWidget(host(MediaUploadTile(state: s, label: '背景')));
      expect(find.textContaining('网络较慢'), findsNothing);
      expect(find.text('背景 上传中 50%'), findsOneWidget);
    });

    testWidgets('失败：中文原因 + 「重新上传背景」按钮可点 → 触发重试', (tester) async {
      int retries = 0;
      final MediaUploadState s = MediaUploadState()..fail('上传超时：当前网络较慢，请切到与电脑同一 WiFi 后重试');
      await tester.pumpWidget(host(MediaUploadTile(
        state: s,
        label: '背景',
        onRetry: () => retries += 1,
      )));

      expect(find.textContaining('上传超时：当前网络较慢'), findsOneWidget, reason: '中文原因必须上屏');
      expect(find.text('重新上传背景'), findsOneWidget);
      await tester.tap(find.text('重新上传背景'));
      await tester.pump();
      expect(retries, 1, reason: '失败必须能重试（不能只留一个死掉的转圈）');
    });

    testWidgets('失败但页面另有重试入口（onRetry=null）→ 只显示原因，不显示按钮', (tester) async {
      final MediaUploadState s = MediaUploadState()..fail('图片太大，服务端拒绝接收，请换一张更小的图');
      await tester.pumpWidget(host(MediaUploadTile(state: s, label: '头像')));
      expect(find.textContaining('图片太大'), findsOneWidget);
      expect(find.textContaining('重新上传'), findsNothing);
    });

    test('MediaUploadState 状态机：begin → update → fail/succeed', () {
      final MediaUploadState s = MediaUploadState();
      expect(s.uploading, isFalse);
      s.begin();
      expect(s.uploading, isTrue);
      expect(s.error, isNull);
      s.update(MediaUploadProgress(sent: 10, total: 100, elapsed: Duration.zero, speedBytesPerSecond: 0));
      s.fail('连不上服务器，请检查网络后重试');
      expect(s.uploading, isFalse);
      expect(s.error, '连不上服务器，请检查网络后重试');
      expect(s.progress?.sent, 10, reason: '失败要保留最后进度（用户能看到"传到 10% 断了"）');
      s.retry();
      expect(s.uploading, isTrue);
      expect(s.error, isNull, reason: '重试要把上一次的错误清掉');
      s.succeed();
      expect(s.error, isNull);
      expect(s.progress, isNull, reason: '成功后不再留进度条');
    });
  });

  // ==========================================================================
  // ③ 中文错误文案
  // ==========================================================================
  group('③ mediaUploadErrorMessage 中文可上屏', () {
    test('服务端中文原文（ApiException）**逐字透传**，不再包一层"上传失败"', () {
      expect(
        mediaUploadErrorMessage(const ApiException(400, '只支持图片类型（jpg/png/webp）', 'r1')),
        '只支持图片类型（jpg/png/webp）',
      );
    });

    test('超时（send/receive/connection）→ 提示切到同一 WiFi', () {
      for (final DioExceptionType t in <DioExceptionType>[
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionTimeout,
      ]) {
        final String msg = mediaUploadErrorMessage(DioException(
          requestOptions: RequestOptions(path: '/media/upload'),
          type: t,
        ));
        expect(msg, contains('超时'));
        expect(msg, contains('WiFi'));
      }
    });

    test('连不上 → 检查网络；5xx → 稍后重试；413 → 图片太大；401 → 重新登录', () {
      String withStatus(int code) => mediaUploadErrorMessage(DioException(
            requestOptions: RequestOptions(path: '/media/upload'),
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: RequestOptions(path: '/media/upload'), statusCode: code),
          ));
      expect(mediaUploadErrorMessage(DioException(
        requestOptions: RequestOptions(path: '/media/upload'),
        type: DioExceptionType.connectionError,
      )), contains('连不上服务器'));
      // 【真实链路】ApiClient 拦截器归一后的形态（见 media_uploader 里的说明）：
      // 它是最先命中的分支，必须还原成"切 WiFi"这种可执行建议
      final String wrapped = mediaUploadErrorMessage(DioException(
        requestOptions: RequestOptions(path: '/media/upload'),
        error: const ApiException(-1, '网络连接失败，请检查网络', ''),
      ));
      expect(wrapped, contains('连不上服务器'));
      expect(wrapped, contains('WiFi'), reason: '弱网下必须给出可执行的动作');
      expect(withStatus(500), contains('服务端暂时不可用'));
      expect(withStatus(413), contains('图片太大'));
      expect(withStatus(401), contains('重新登录'));
      expect(withStatus(403), contains('重新登录'));
      expect(withStatus(418), contains('HTTP 418'));
    });

    test('服务端 body 里带中文 message → 用它的原文（覆盖状态码兜底）', () {
      final String msg = mediaUploadErrorMessage(DioException(
        requestOptions: RequestOptions(path: '/media/upload'),
        type: DioExceptionType.badResponse,
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/media/upload'),
          statusCode: 400,
          data: <String, dynamic>{'message': '图片尺寸超过限制（最大 4096px）'},
        ),
      ));
      expect(msg, '图片尺寸超过限制（最大 4096px）');
    });

    test('完全未知的异常也必须是中文（绝不把英文类名吐给用户）', () {
      final String msg = mediaUploadErrorMessage(StateError('SocketException: failed host lookup'));
      expect(msg, '上传失败，请重试');
      expect(RegExp(r'[\u4e00-\u9fa5]').hasMatch(msg), isTrue);
    });
  });
}
