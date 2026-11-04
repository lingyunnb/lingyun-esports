import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/home_page.dart';
import 'package:worker_app/pages/migration_guide_page.dart';
import 'package:worker_app/pages/orders_page.dart';
import 'package:worker_app/pages/profile_page.dart';
import 'package:worker_app/widgets/migration_notice.dart';
import 'package:worker_app/widgets/worker_sunset.dart';

/// 工作端退役 · 迁移引导（负责人 2026-10-06）
///
/// 覆盖三件必测的事：
/// ① **引导条存在且文案含关键信息**：合并到哪个 App / 怎么绑定 / 下载入口在哪；
/// ② **不阻塞主要操作**：无弹窗无遮罩、首页仍可滚动、订单相关入口仍可达、接单大厅照旧可用；
/// ③ **复制/下载入口点击有反馈**：剪贴板真的拿到地址 + 品牌提示出现，且不崩。
///
/// 另加两条守门用例：接口失败时引导条照样在（不靠接口成功才出现）、说明页步骤与老板端真实控件名一致。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false; // 每条用例独立，避免公开接口 SWR 缓存串数据
    // 工作端首页/我的页都要登录态资料（与真实登录一致：老板端测的是"已登录打手"）
    AuthStore.instance.debugSetSession(accessToken: 'test-token', me: _me());
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession();
  });

  group('引导条', () {
    testWidgets('① 首页顶部有引导条，文案含「停止服务 / 绑定 / 下载入口」关键信息', (tester) async {
      // 注入固定日期（2026-10-11）：v1.8.2 / 码 60 起引导条**与日期无关**（立即阻断，恒为停止服务口径），
      // 这里仍注入是为了证明"注入哪天都是同一句"（不让用例的真实含义随"今天几号"变化）
      final DateTime now = DateTime(2026, 10, 11, 9);
      await tester.pumpWidget(_app(HomePage(api: _api(), now: now)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // —— 标题：说结果，不只是"已合并"（本版立即阻断）
      expect(find.text('工作端已停止服务，请使用「祁连山电竞」App'), findsOneWidget);
      expect(find.text('工作端已合并进「祁连山电竞」App'), findsNothing,
          reason: '停用后不该再显示"已合并进…App"这种进行时口径');

      // —— 正文：与阻断页同一句（现在时，无日期、无未来时）
      expect(find.textContaining('工作端已合并到「祁连山电竞」App'), findsOneWidget);
      expect(find.textContaining('在同一台手机上绑定你的打手账号'), findsOneWidget);
      expect(find.textContaining('就能在老板端里接单'), findsOneWidget);
      expect(find.text(migrationBodyText(now)), findsOneWidget);
      expect(migrationBodyText(now), contains(kWorkerSunsetBlockedNote));
      expect(migrationBodyText(now), contains('工作端已停止服务'));
      expect(migrationBodyText(now), isNot(contains('将于')), reason: '用户可见文案不许再有未来时');
      expect(migrationBodyText(now), isNot(contains(kWorkerSunsetDateText)), reason: '不再出现停止服务日期');

      // —— 下载入口：地址明文可见 + 一键复制 + 进说明页
      expect(find.text('下载地址'), findsOneWidget);
      expect(find.text(MigrationDownload.siteUrl), findsOneWidget);
      expect(find.text('复制下载地址'), findsOneWidget);
      expect(find.text('查看绑定步骤'), findsOneWidget);
    });

    testWidgets('② 引导条不阻塞：无弹窗无遮罩、首页可滚动、订单入口可达', (tester) async {
      final nav = <int>[];
      await tester.pumpWidget(_app(HomePage(api: _api(), onNavigate: nav.add)));
      await tester.pumpAndSettle();

      // 不是强制弹窗：没有对话框、没有底部弹层、**没有任何可见遮罩**。
      // （说明：Material 的每个页面路由本身都会带一个**全透明**的 ModalBarrier，
      //   所以这里不能简单断言"没有 ModalBarrier"，而是断言"没有带颜色的遮罩"= 没挡东西。）
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      final scrims = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .where((b) => (b.color?.a ?? 0) > 0)
          .toList();
      expect(scrims, isEmpty, reason: '出现了可见遮罩 = 打手被挡住了');
      // 引导条本身不可关闭（没有关闭按钮 = 不可忽略），也没有任何**真正拦截手势**的层
      // （同样注意：路由转场自带 `AbsorbPointer(absorbing: false)`，只有 absorbing=true 才算挡）
      expect(find.byIcon(Icons.close), findsNothing);
      final blockers = tester
          .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
          .where((w) => w.absorbing)
          .toList();
      expect(blockers, isEmpty, reason: '出现了拦截手势的层 = 打手点不动');

      // 首页内容照旧可达：收益概览第一屏就在
      expect(find.text('我的收益'), findsOneWidget);

      // 列表仍可滚动到底部，快捷入口（接单大厅）可点 → 切到订单 tab
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('快捷入口'), findsOneWidget);
      await tester.tap(find.text('接单大厅'));
      await tester.pumpAndSettle();
      expect(nav, [1]);

      // 引导条是常驻的（滚动之后仍在，不是一次性浮层）
      expect(find.text('复制下载地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('②b 接单大厅照旧可用（引导条不改订单链路）', (tester) async {
      final hall = [
        {'id': '901', 'orderNo': 'ORDMIG001', 'quantity': 2, 'totalAmount': 96.5, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-10-06T02:11:00Z', 'productName': '烽火地带带打', 'priceUnit': '局'},
      ];
      await tester.pumpWidget(_app(OrdersPage(api: _api(hall: hall))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('烽火地带带打 × 2'), findsOneWidget);
      expect(find.textContaining('96'), findsWidgets); // 金额照常展示（两位数不会因格式化变样）
    });

    testWidgets('③ 复制下载地址：剪贴板拿到地址 + 品牌提示（不崩）', (tester) async {
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add('${(call.arguments as Map)['text']}');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_app(HomePage(api: _api())));
      await tester.pumpAndSettle();

      await tester.tap(find.text('复制下载地址'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // 提示进场

      expect(copied, [MigrationDownload.siteUrl]); // 真的进了剪贴板，且与页面展示的一致
      // v1.8.2 / 码 60：立即阻断 → 复制成功的提示也带上"已停止服务"口径（不是只报一句"已复制"）
      expect(find.textContaining('地址已复制'), findsOneWidget); // 有反馈
      expect(find.textContaining(kWorkerSunsetBlockedNote), findsWidgets);
      expect(find.textContaining('将于'), findsNothing);
      expect(tester.takeException(), isNull);

      AppToast.dismiss(); // 清掉 2 秒自动消失的定时器，避免测试尾留 pending timer
      await tester.pump();
    });

    testWidgets('④ 接口失败时引导条照样在（不是"请求成功才看得到"）', (tester) async {
      await tester.pumpWidget(_app(HomePage(api: _api(failAll: true))));
      await tester.pumpAndSettle();

      expect(find.text('复制下载地址'), findsOneWidget);
      expect(find.textContaining('工作端已合并到「祁连山电竞」App'), findsOneWidget);
      // 原有错误态与重试按钮逐字未变
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('打手态说明', () {
    testWidgets('⑤「我的」页有打手态说明卡：绑定路径 + 分步骤列清楚', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(MiuixSystemTheme(child: _app(ProfilePage(api: _api()))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(kMigrationWorkerStateEndedTitle), findsOneWidget);
      expect(find.text(kMigrationWorkerStateTitle), findsNothing,
          reason: '停用后「我的」页那条不该再说"打手态…可用"（说的是工作端已停）');
      // 负责人指定的绑定链条，逐字出现
      expect(find.textContaining('绑定路径：老板端 › 我的 › 身份 › 切换身份 › 输入打手账密'), findsOneWidget);
      // 分步骤：5 步全部在页面上（不是折叠成一句"去绑定"）
      for (final s in kMigrationBindSteps) {
        expect(find.text(s.title), findsOneWidget, reason: '缺步骤：${s.title}');
      }
      // 显著位置也有下载入口
      expect(find.text('下载地址'), findsOneWidget);
      expect(find.text('复制下载地址'), findsOneWidget);
    });

    testWidgets('⑥ 迁移说明页：老板端控件名可对照 + 版本/大小来自接口下发的下载地址', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_app(MigrationGuidePage(api: _api())));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('迁移说明'), findsOneWidget);

      // 步骤：标题 + 与老板端真实控件名一致的细节（照着点就能对上）
      for (final s in kMigrationBindSteps) {
        expect(find.text(s.title), findsOneWidget);
        expect(find.text(s.detail), findsOneWidget);
      }
      expect(find.textContaining('打手端账号'), findsOneWidget);
      expect(find.textContaining('登录名 / 展示 ID / 工号'), findsOneWidget);
      expect(find.textContaining('点「绑定并切换为打手」'), findsWidgets);

      // 下载区：官网下载页（双端二维码那页）+ 老板端安装包直链
      expect(find.text('官网下载页'), findsOneWidget);
      expect(find.text(MigrationDownload.siteUrl), findsOneWidget);
      expect(find.text('老板端安装包（直接下载）'), findsOneWidget);
      expect(find.text(AppConfig.resolveMediaUrl('/api/v1/public/app-versions/download/99')), findsOneWidget);
      expect(find.textContaining('当前老板端 v1.11.19 · 26.1 MB'), findsOneWidget);
      expect(find.text('复制下载地址'), findsNWidgets(2));

      // 三个常见问题都在（工作端还能用 / 权限不变 / 订单收益不丢）
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.textContaining('工作端现在还能用吗'), findsOneWidget);
      expect(find.textContaining('接单权限会变吗'), findsOneWidget);
      expect(find.textContaining('订单和收益会丢吗'), findsOneWidget);
      // 第一条问答本版恒为"不能了"口径（与阻断页同一个判定、同一句说明）
      expect(find.textContaining('不能了。$kWorkerSunsetBlockedNote'), findsOneWidget);
      expect(find.textContaining('将于'), findsNothing, reason: '说明页也不许有未来时');
      expect(find.textContaining(kWorkerSunsetDateText), findsNothing, reason: '说明页也不许出现停止服务日期');
    });

    testWidgets('⑦ 说明页复制安装包地址：点击有反馈（不崩）', (tester) async {
      _tallViewport(tester);
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map)['text']}');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_app(MigrationGuidePage(api: _api())));
      await tester.pumpAndSettle();

      // 第二个复制按钮 = 老板端安装包直链
      await tester.tap(find.text('复制下载地址').at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(copied, [AppConfig.resolveMediaUrl('/api/v1/public/app-versions/download/99')]);
      expect(find.textContaining('地址已复制'), findsOneWidget);
      expect(find.textContaining(kWorkerSunsetBlockedNote), findsWidgets);
      expect(tester.takeException(), isNull);

      AppToast.dismiss();
      await tester.pump();
    });
  });
}

// ---------------------------------------------------------------- 测试脚手架

/// 视口调高：说明页/我的页内容较长，ListView 懒构建会让下半部分查不到（不是页面缺内容）
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, home: home);

/// 真实结构的登录资料（工号/昵称/分部权限，取值风格与线上一致）
AuthMe _me() => AuthMe.fromJson({
      'id': '77',
      'username': 'worker_demo',
      'uid': '8842019',
      'nickname': '陈默',
      'role': 'worker',
      'level': 2,
      'avatarMediaId': null,
      'backgroundMediaId': null,
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

ApiClient _api({List<dynamic>? hall, bool failAll = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(failAll: failAll, responses: {
    '/worker/my-stats': _ok({'completedOrders': 128, 'totalAmount': 4210.5}),
    '/worker/my-wallet': _ok({'balance': 308.5, 'totalIncome': 1260, 'totalSpent': 0}),
    '/worker/orders': _ok({'list': const [], 'total': 0, 'page': 1, 'pageSize': 100}),
    '/worker/order-hall': _ok({'list': hall ?? const [], 'total': (hall ?? const []).length, 'page': 1, 'pageSize': 50}),
    // 老板端版本通道（公开接口，与工作端自身更新检查同一个接口，只是 appType=boss）
    '/public/app-versions/latest': _ok({
      'hasUpdate': true,
      'force': false,
      'latest': {
        'versionCode': 76,
        'versionName': '1.11.19',
        'fileSize': 27368751,
        'fileHash': 'b945830f10c0af47084b17a2afcef9bc00f885d5dc0718ff461d8f7c1fec2ddd',
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
