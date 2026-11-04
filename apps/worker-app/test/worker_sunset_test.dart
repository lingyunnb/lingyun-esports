import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/home_page.dart';
import 'package:worker_app/pages/home_shell.dart';
import 'package:worker_app/pages/login_page.dart';
import 'package:worker_app/pages/orders_page.dart';
import 'package:worker_app/pages/worker_sunset_block_page.dart';
import 'package:worker_app/widgets/migration_notice.dart';
import 'package:worker_app/widgets/worker_sunset.dart';

/// 工作端**完全阻断版（v1.8.2 / 码 60）· 立即生效、无宽限期**（负责人 2026-10-06 拍板）
///
/// 负责人原话：「目前这个 app 还没正式投入使用，所以没用、没迁移的打手」→ 不需要 7 天宽限期。
/// 本文件钉死四条：
/// ① **打开即阻断且不可跳过**：「暂时继续使用」按钮**不渲染**，主界面/登录页不可达；
/// ② **任何时间（过去 / 现在 / 未来）都不可继续使用**（[kWorkerSunsetBlocking] = true 生效），
///    直接调 [WorkerSunsetGate.continueUsing] 也无效；
/// ③ **备用开关为 false 时的到期逻辑仍在**（用**注入参数** `blocking: false` 覆盖两条分支，
///    证明日期判定没被删掉）；
/// ④ **用户可见文案不再有未来时**：不出现「将于 … 停止服务」，也不再出现「10 月 13 日」
///    （立即生效还给日期 = 误导用户以为还有时间）；两处文案仍同一处出处。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
    // 本文件不验服务端时间探测（另有 worker_sunset_deadline_test.dart 逐条覆盖）：
    // 立即阻断版下阻断页根本不再发这次探测，这里显式关掉只是让"页面只做渲染"这件事更明确
    WorkerSunsetProbe.enabled = false;
    AuthStore.instance.debugSetSession(accessToken: 'sunset-token', me: _me());
    // 每条用例都从"冷启动"开始：每次打开 App 都要先出阻断页
    WorkerSunsetGate.instance.debugReset();
  });

  tearDown(() {
    WorkerSunsetProbe.enabled = true;
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession();
    WorkerSunsetGate.instance.debugReset();
  });

  group('完全阻断（打开 App 即出，且无法跳过）', () {
    testWidgets('① 冷启动即出现阻断页：已停止服务 + 下载入口 + 5 步绑定', (tester) async {
      await tester.pumpWidget(_app(WorkerSunsetGateHost(child: HomeShell(api: _api()))));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);

      // —— 页头直接说结果（本版恒为"已停止服务"，不再是"已合并/将于某日停止"）
      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kWorkerSunsetHeadline), findsNothing, reason: '立即阻断下不该再出"已合并到…"这种进行时页头');

      // —— 主说明（与首页引导条共用同一句常量）就在页面上
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
      expect(find.text(kWorkerSunsetServerNote), findsOneWidget, reason: '服务端兜底说明要给（但不给日期）');

      // —— 下载入口：地址明文（运行期下发，不写死域名）+ 一键复制
      expect(find.text(MigrationDownload.siteUrl), findsOneWidget);
      expect(find.text('复制下载地址'), findsWidgets);
      expect(MigrationDownload.siteUrl, contains('/site/'));

      // —— 5 步绑定：用的就是老板端真实控件名（「切换身份」「打手端账号」「绑定并切换为打手」「切回老板」）
      expect(find.text(kWorkerSunsetStepsTitle), findsOneWidget);
      for (final s in kMigrationBindSteps) {
        expect(find.text(s.title), findsOneWidget, reason: '缺步骤：${s.title}');
        expect(find.text(s.detail), findsOneWidget, reason: '缺步骤细节：${s.title}');
      }
      for (final control in ['切换身份', '打手端账号', '绑定并切换为打手', '切回老板']) {
        expect(find.textContaining(control), findsWidgets, reason: '缺老板端真实控件名：$control');
      }

      // —— 只剩「前往下载」：整页只有这一个 AppButton（「暂时继续使用」不在）
      expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);
      expect(find.text(kWorkerSunsetContinueLabel), findsNothing,
          reason: 'kWorkerSunsetBlocking = true → 阻断页不许再出现「暂时继续使用」');
      expect(find.byType(AppButton), findsOneWidget, reason: '底部只该剩「前往下载」一个按钮');

      // —— 阻断期间主界面确实进不去（不是遮罩旁边还能点）
      expect(find.text('我的收益'), findsNothing);
      expect(find.text(kMigrationHeadline), findsNothing);

      await tester.pump(const Duration(milliseconds: 700)); // 排空 ApiClient 重试定时器
    });

    testWidgets('①b 未登录也照样阻断：登录页被挡在提示页后面', (tester) async {
      await tester.pumpWidget(_app(const WorkerSunsetGateHost(child: LoginPage())));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text('工作账号由管理员创建分配'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('①c「前往下载」真的到下载入口：下载与绑定步骤页（含可复制地址）', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(api: _api())));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text(kWorkerSunsetDownloadLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('下载与绑定步骤'), findsOneWidget);
      expect(find.text('官网下载页'), findsWidgets);
      expect(find.text(MigrationDownload.siteUrl), findsWidgets);
      expect(find.text('老板端安装包（直接下载）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('①d 页面全部文案没有未来时：不含「将于」也不含原到期日', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(api: _api())));
      await tester.pump(const Duration(milliseconds: 300));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts, isNotEmpty);
      for (final s in texts) {
        expect(s, isNot(contains('将于')), reason: '出现未来时表述：$s');
        expect(s, isNot(contains(kWorkerSunsetDateText)), reason: '立即生效后不该再出现停止服务日期：$s');
      }

      await tester.pump(const Duration(milliseconds: 700));
    });
  });

  group('任何时间都不可继续（立即阻断，无宽限期）', () {
    test('② 过去 / 现在 / 未来三档：纯函数一律返回"不可继续"', () {
      expect(kWorkerSunsetBlocking, isTrue, reason: '本版唯一开关必须为 true（完全阻断）');
      for (final now in [
        DateTime(2020, 1, 1), // 很久以前
        DateTime(2026, 10, 6), // 立即生效的发布当天
        DateTime(2026, 10, 12, 23, 59, 59, 999), // 旧的宽限期最后一毫秒（曾经"还能点"）
        DateTime(2026, 10, 13), // 旧到期日当天 00:00
        DateTime(2026, 10, 14),
        DateTime(2030, 1, 1), // 很远以后
        DateTime.utc(2026, 10, 20), // 传 UTC 也不放行
      ]) {
        expect(workerSunsetCanContinue(now), isFalse, reason: '$now 不应还能继续使用');
        expect(workerSunsetStopped(now), isTrue, reason: '$now 应判定为已停止服务');
      }
    });

    test('②b 门禁层与纯函数同结论：canContinue 恒 false、stopped 恒 true', () {
      final gate = WorkerSunsetGate.instance;
      for (final now in [DateTime(2026, 10, 6), DateTime(2026, 10, 12, 23, 59), DateTime(2030, 1, 1)]) {
        gate.debugNow = () => now;
        expect(gate.canContinue, isFalse, reason: '$now 门禁层也必须恒 false');
        expect(gate.stopped, isTrue);
        expect(gate.blocking, isTrue, reason: '冷启动默认阻断');
      }
    });

    testWidgets('②c 注入任意时刻建页：都只剩「前往下载」；直接调 continueUsing 也无效', (tester) async {
      _tallViewport(tester);
      final gate = WorkerSunsetGate.instance;
      for (final now in [
        DateTime(2026, 1, 1), // 过去
        DateTime(2026, 10, 12, 23, 59), // 旧宽限期内（曾经还能继续用）
        DateTime(2026, 10, 13), // 旧到期日
        DateTime(2030, 1, 1), // 未来
      ]) {
        await tester.pumpWidget(_app(WorkerSunsetBlockPage(api: _api(), now: now, networkTime: now)));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget, reason: '$now 页头应为已停止服务');
        expect(find.text(kWorkerSunsetContinueLabel), findsNothing, reason: '$now 不该有「暂时继续使用」');
        expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);

        // 绕过 UI 直接放行也无效（改了钟再点一次同样无效）
        gate.debugNow = () => now;
        gate.continueUsing();
        await tester.pump(const Duration(milliseconds: 50));
        expect(gate.blocking, isTrue, reason: '$now 直接调 continueUsing 也必须无效');
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 700));
    });
  });

  group('备用开关为 false 时的到期逻辑仍被覆盖（注入参数，证明逻辑没被删）', () {
    test('③ blocking:false → 到期前 true / 到期当天起 false（两条分支都在）', () {
      // 备用开关（v1.8.0/58、v1.8.1/59 的旧口径）没有被删：注入 blocking:false 后日期判定照常生效
      expect(workerSunsetCanContinue(DateTime(2026, 10, 6), blocking: false), isTrue);
      expect(workerSunsetCanContinue(DateTime(2026, 10, 12, 23, 59), blocking: false), isTrue);
      expect(
        workerSunsetCanContinue(DateTime(2026, 10, 12, 23, 59, 59, 999), blocking: false),
        isTrue,
        reason: '到期前一天最后一毫秒还能点',
      );
      expect(workerSunsetCanContinue(DateTime(2026, 10, 13), blocking: false), isFalse,
          reason: '当天 00:00 就是分界点');
      expect(
        workerSunsetCanContinue(DateTime(2026, 10, 13).add(const Duration(milliseconds: 1)), blocking: false),
        isFalse,
      );
      expect(workerSunsetCanContinue(DateTime(2026, 10, 20), blocking: false), isFalse);
      // 到期日判定本身（workerSunsetEnded）与日期分支同源
      expect(workerSunsetEnded(DateTime(2026, 10, 12, 23, 59, 59, 999)), isFalse);
      expect(workerSunsetEnded(DateTime(2026, 10, 13)), isTrue);
    });

    test('③b 同一时刻两种注入结论相反 → 说明"恒 false"确实来自立即阻断开关', () {
      final DateTime beforeDeadline = DateTime(2026, 10, 12, 12);
      expect(workerSunsetCanContinue(beforeDeadline, blocking: false), isTrue,
          reason: '关掉立即阻断后，到期前本该可以继续 —— 这条分支没被删');
      expect(workerSunsetCanContinue(beforeDeadline), isFalse, reason: '默认（生产）必须恒 false');
      expect(workerSunsetCanContinue(beforeDeadline, blocking: true), isFalse);

      final DateTime afterDeadline = DateTime(2026, 10, 20);
      expect(workerSunsetCanContinue(afterDeadline, blocking: false), isFalse);
      expect(workerSunsetCanContinue(afterDeadline), isFalse, reason: '两条路都不放行');
    });
  });

  group('停止服务常量与文案', () {
    test('④ 常量不变量：release + grace = sunset（备用分支的口径没删，下一版仍只需改常量）', () {
      expect(kWorkerSunsetReleaseDate, DateTime(2026, 10, 6));
      expect(kWorkerSunsetGraceDays, 7);
      expect(kWorkerSunsetDate, DateTime(2026, 10, 13));
      expect(kWorkerSunsetDate.difference(kWorkerSunsetReleaseDate).inDays, kWorkerSunsetGraceDays);
      expect(kWorkerSunsetDateText, '10 月 13 日');
      expect(kWorkerSunsetDate.hour, 0, reason: '备用分支的分界点仍是当天本地 00:00');
      expect(kWorkerSunsetDate.isUtc, isFalse);
    });

    test('④b 用户可见文案是现在时：不含日期、不含「将于 … 停止服务」', () {
      expect(kWorkerSunsetBlockedNote, contains('工作端已停止服务'));
      expect(kWorkerSunsetBlockedNote, contains('祁连山电竞'));
      expect(kWorkerSunsetBlockedNote, contains('我的 → 身份'));
      expect(kWorkerSunsetBlockedNote, contains('绑定打手账号'));
      // 立即生效 → 文案里一个日期都不该有
      expect(kWorkerSunsetBlockedNote, isNot(contains(kWorkerSunsetDateText)));
      expect(kWorkerSunsetBlockedNote, isNot(contains('将于')));
      expect(kWorkerSunsetServerNote, isNot(contains(kWorkerSunsetDateText)),
          reason: '服务端兜底刻意不给日期（给了就等于说"还有几天"）');
      expect(kWorkerSunsetServerNote, isNot(contains('将于')));
      // 引导条正文同源
      final String body = migrationBodyText(DateTime.now());
      expect(body, contains(kWorkerSunsetBlockedNote), reason: '引导条与阻断页共用同一句停止服务说明');
      expect(body, isNot(contains('将于')));
      expect(body, isNot(contains(kWorkerSunsetDateText)));
    });

    testWidgets('④c 阻断页与首页引导条写着同一句话（同一常量出处，不会两套口径）', (tester) async {
      // 阻断页
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(api: _api())));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);

      // 首页引导条（HomePage 直接挂载：本版门禁不会放行到主界面，引导条仍在页面里常驻）
      await tester.pumpWidget(_app(HomePage(api: _api())));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining(kWorkerSunsetBlockedNote), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });
  });

  group('引导条与提示不打架', () {
    testWidgets('⑤ 不同屏重复 + 文案同源 + 无未来时/无日期', (tester) async {
      // 阻断页在场时：首页引导条不在（两处说明不叠着喊）
      await tester.pumpWidget(_app(WorkerSunsetGateHost(child: HomePage(api: _api()))));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kMigrationHeadline), findsNothing);
      expect(find.text(kMigrationEndedHeadline), findsNothing);

      // 引导条单独在时（主界面被门禁挡住，所以直接挂 HomePage）：标题与正文都是"已停止服务"
      await tester.pumpWidget(_app(HomePage(api: _api())));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(kMigrationEndedHeadline), findsOneWidget);
      expect(find.text(kMigrationHeadline), findsNothing, reason: '停用后不该再显示"已合并进…App"这种进行时口径');
      expect(find.text(migrationBodyText(DateTime.now())), findsOneWidget);

      // 全屏所有提到"停止服务"的文案：同一口径 —— 不许有日期、不许有未来时
      final sunsetTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.contains('停止服务'))
          .toList();
      expect(sunsetTexts, isNotEmpty);
      for (final s in sunsetTexts) {
        expect(s, isNot(contains(kWorkerSunsetDateText)), reason: '出现日期口径：$s');
        expect(s, isNot(contains('将于')), reason: '出现未来时：$s');
      }

      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('⑤b 业务链路一行未动：接单大厅照常渲染真实订单（阻断只加在入口）', (tester) async {
      // 工作端主界面进不去了（门禁），但**页面与接单链路本身没被删**：
      // 直接挂载订单页仍按真实接口数据渲染（服务端 worker 模块也一行未动 —— 打手态还靠它）。
      await tester.pumpWidget(_app(OrdersPage(api: _api(hall: _hall()))));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('烽火地带带打 × 2'), findsOneWidget);
      expect(find.textContaining('96'), findsWidgets); // 金额照常展示

      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}

// ---------------------------------------------------------------- 测试脚手架

void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home) => MiuixSystemTheme(
      child: MaterialApp(debugShowCheckedModeBanner: false, home: home),
    );

/// 已登录的打手（与线上结构一致）
AuthMe _me() => AuthMe.fromJson({
      'id': '77',
      'username': 'worker_demo',
      'uid': '8842019',
      'nickname': '陈默',
      'role': 'worker',
      'level': 2,
      'worker': {
        'workerNo': 'W-1042',
        'canTakeOrder': true,
        'canServeCustomer': false,
        'divisionPermissions': [
          {'divisionId': 1, 'name': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
          {'divisionId': 2, 'name': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
        ],
      },
    });

/// 接单大厅一条真实结构的订单（非整数金额，docs/21 假数据要拟真）
List<dynamic> _hall() => [
      {
        'id': '901',
        'orderNo': 'ORDMIG001',
        'quantity': 2,
        'totalAmount': 96.5,
        'status': 'pending_take',
        'statusName': '待接单',
        'createdAt': '2026-10-06T02:11:00Z',
        'productName': '烽火地带带打',
        'priceUnit': '局',
      },
    ];

ApiClient _api({List<dynamic>? hall, bool failAll = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(failAll: failAll, responses: {
    '/worker/my-stats': _ok({'completedOrders': 128, 'totalAmount': 4210.5}),
    '/worker/my-wallet': _ok({'balance': 308.5, 'totalIncome': 1260, 'totalSpent': 0}),
    '/worker/orders': _ok({'list': const [], 'total': 0, 'page': 1, 'pageSize': 100}),
    '/worker/order-hall': _ok({'list': hall ?? const [], 'total': (hall ?? const []).length, 'page': 1, 'pageSize': 50}),
    '/public/app-versions/latest': _ok({
      'hasUpdate': true,
      'force': false,
      'latest': {
        'versionCode': 78,
        'versionName': '1.11.22',
        'fileSize': 27368751,
        'downloadUrl': '/api/v1/public/app-versions/download/99',
      },
    }),
  });
  return ApiClient(dio: dio);
}

Map<String, dynamic> _ok(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter({required this.responses, this.failAll = false});

  final Map<String, Map<String, dynamic>> responses;
  final bool failAll;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (failAll) {
      return ResponseBody.fromString(
        jsonEncode({'code': 500, 'message': '服务器开小差了'}),
        500,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );
    }
    final matches = responses.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final body = key.isEmpty ? {'code': 404, 'message': 'Not Found', 'data': null} : responses[key]!;
    return ResponseBody.fromString(
      jsonEncode(body),
      key.isEmpty ? 404 : 200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
