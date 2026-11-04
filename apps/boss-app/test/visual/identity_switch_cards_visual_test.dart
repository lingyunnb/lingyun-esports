import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// **身份直切 · 出图**（负责人 2026-10-06 截图要求：
/// 「在这里增加点击切换绑定的打手端和管理端」）
///
/// 产出（`apps/boss-app/build/`，共 4 张）：
/// 1. `identity_switch_1_sheet_boss.png`  弹层 · **当前老板**：两张卡（打手 / 管理员）+ 两颗切换按钮
/// 2. `identity_switch_2_sheet_worker.png` 弹层 · **当前打手**：打手卡「当前」徽标 + 「正在使用」置灰
/// 3. `identity_switch_3_sheet_admin.png`  弹层 · **当前管理员**：管理员卡「当前」+ 「正在使用」，
///    打手卡仍可点「切换为打手」（**直切不需要先切回老板态**）
/// 4. `identity_switch_4_admin_shell.png`  **切到管理员态之后的界面**（受限会话 + 28dp 细带「充值审核」）
///
/// ## 数据来源：**全部注入**（与线上目录/账号数据无关，可离线复跑）
/// 假接口 `_ShotRouter` 只喂这四屏用到的字段；不抓线上 3100、不依赖任何真实商品或账号
/// （负责人当天就会删商品/改名字，抓线上的出图用例必然变红，那是噪声不是回归信号）。
///
/// ## 关键技术点（本项目既有坑，别回退）
/// - 中文字形挂 **msyh 最前**（`flutter test` 自带字体没有 CJK，不挂是豆腐块），
///   并单独挂 `MaterialIcons`（否则图标是空心方框）；
/// - `toImage` 必须在 `tester.runAsync` 里调（假时钟下不会自己回帧）；
/// - **不用 `pumpAndSettle()`**：身份弹层里有 180ms 进场动画 + Toast 的 2s Timer，
///   统一用有界 `settle()`；
/// - 弹层按"底部弹层"的真实几何渲染（`Align.bottomCenter + maxHeight`），
///   而不是拉满整屏 —— 出图要能看出它是弹层。
void main() {
  const cjk = 'IdentityShotCJK';
  final sheetKey = Key('identity-shot-sheet');
  final shellKey = Key('identity-shot-shell');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(iconPath);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'shot-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
      }),
    );
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
    AuthStore.debugStorageDisabled = false;
    AppSettings.debugStorageDisabled = false;
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// **有界**推进（不用 pumpAndSettle：弹层动画 + Toast 定时器会让它永不结束）
  Future<void> settle(WidgetTester tester, {int frames = 24}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = await b.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final out = File('build/$name');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 10000, isTrue, reason: 'PNG 太小说明没渲染出内容');
  }

  ApiClient api(_ShotRouter router) =>
      ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://identity-shot.local'))..httpClientAdapter = router);

  /// 弹层舞台（底部弹层几何：底部对齐 + 最高 760dp）
  Widget sheetStage(Key k, ApiClient client) => RepaintBoundary(
        key: k,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: Scaffold(
            backgroundColor: const Color(0xFFF4F6F9),
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 760),
                child: IdentitySwitchSheet(key: UniqueKey(), api: client),
              ),
            ),
          ),
        ),
      );

  /// **两个受限会话都在内存**（本次功能的前提：点一下就能来回切）
  void bindBoth() {
    AuthStore.instance.debugSetIdentity(
      companionToken: 'companion-token',
      companionRefreshToken: 'companion-refresh',
      status: IdentityBindingStatus.fromJson(const {
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 1,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '小云',
              'workerStatus': 1,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
                {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
              ],
            },
          }
        ],
      }),
      workerMe: AuthMe.fromJson(const {
        'id': '2',
        'username': 'lingyun_go',
        'nickname': '小云',
        'role': 'worker',
        'worker': {
          'workerNo': 'W20260118',
          'canTakeOrder': true,
          'divisionPermissions': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
          ],
        },
      }),
      adminToken: 'recharge-token',
      adminRefreshToken: 'recharge-refresh',
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
  }

  // =====================================================================================
  // 出图 1：弹层 · 当前老板（两张卡 + 两颗切换按钮）
  // =====================================================================================
  testWidgets('出图 1：弹层 · 当前老板 —— 两张卡 + 两颗切换按钮', (tester) async {
    phone(tester);
    bindBoth();
    await tester.pumpWidget(sheetStage(sheetKey, api(_ShotRouter())));
    await settle(tester);

    // 卡面事实（断言是回归，图是证据）
    expect(find.text('小云'), findsOneWidget, reason: '打手卡：昵称');
    expect(find.textContaining('W20260118'), findsOneWidget, reason: '打手卡：工号');
    expect(find.text('周砚'), findsOneWidget, reason: '管理员卡：昵称');
    expect(find.text('recharge_zhou'), findsOneWidget, reason: '管理员卡：账号');
    expect(find.text('切换为打手'), findsOneWidget);
    expect(find.text('切换为管理员'), findsOneWidget);
    expect(find.text('正在使用'), findsNothing, reason: '老板态下两张卡都不是"当前在用"');
    expect(find.text('绑定新的打手账号'), findsOneWidget);
    expect(find.text('解除绑定'), findsOneWidget);

    await shoot(tester, sheetKey, 'identity_switch_1_sheet_boss.png');
    await settle(tester);
    tester.view.reset();
  });

  // =====================================================================================
  // 出图 2：弹层 · 当前打手（打手卡「当前」+「正在使用」置灰）
  // =====================================================================================
  testWidgets('出图 2：弹层 · 当前打手 —— 打手卡「当前」徽标 + 「正在使用」', (tester) async {
    phone(tester);
    bindBoth();
    await AuthStore.instance.switchToWorker();
    await tester.pumpWidget(sheetStage(sheetKey, api(_ShotRouter())));
    await settle(tester);

    expect(find.text('当前'), findsOneWidget, reason: '只有当前身份那张卡带徽标');
    expect(find.text('正在使用'), findsOneWidget);
    expect(find.text('切换为打手'), findsNothing, reason: '已在打手态 → 不再给「切换为打手」');
    expect(find.text('切换为管理员'), findsOneWidget, reason: '另一身份始终可点（**直切**）');

    await shoot(tester, sheetKey, 'identity_switch_2_sheet_worker.png');
    await settle(tester);
    tester.view.reset();
  });

  // =====================================================================================
  // 出图 3：弹层 · 当前管理员
  // =====================================================================================
  testWidgets('出图 3：弹层 · 当前管理员 —— 管理员卡「当前」+ 「正在使用」', (tester) async {
    phone(tester);
    bindBoth();
    await AuthStore.instance.switchToAdmin();
    await tester.pumpWidget(sheetStage(sheetKey, api(_ShotRouter())));
    await settle(tester);

    expect(find.text('当前'), findsOneWidget);
    expect(find.text('正在使用'), findsOneWidget);
    expect(find.text('切换为打手'), findsOneWidget, reason: '管理员态下也能一键切回打手（不必先回老板态）');
    expect(find.text('切换为管理员'), findsNothing);
    expect(find.textContaining('只做充值审核'), findsOneWidget, reason: '管理员卡写清权限边界');

    await shoot(tester, sheetKey, 'identity_switch_3_sheet_admin.png');
    await settle(tester);
    tester.view.reset();
  });

  // =====================================================================================
  // 出图 4：切到管理员态之后的界面（受限会话 + 28dp 细带）
  // =====================================================================================
  testWidgets('出图 4：切到管理员态后的界面（待审核列表 + 细带「充值审核」）', (tester) async {
    phone(tester);
    bindBoth();
    await AuthStore.instance.switchToAdmin();
    final router = _ShotRouter();
    await tester.pumpWidget(RepaintBoundary(
      key: shellKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
        home: RechargeAdminShell(api: api(router)),
      ),
    ));
    await settle(tester);

    expect(find.text('麻药'), findsOneWidget, reason: '待审核列表有数据');
    expect(find.textContaining('充值审核'), findsWidgets, reason: '28dp 细带写明当前身份');
    expect(find.byType(AppBottomNav), findsNothing, reason: '管理员态**无底栏**（受限会话只有审核这一件事）');

    await shoot(tester, shellKey, 'identity_switch_4_admin_shell.png');
    await settle(tester);
    tester.view.reset();
  });
}

/// 出图用的假服务器（**只喂这四屏要用的字段**；与线上数据无关）
class _ShotRouter implements HttpClientAdapter {
  static const List<Map<String, dynamic>> _pending = [
    {
      'id': '9',
      'nickname': '麻药',
      'uid': 'U8471209365',
      'amountYuan': 68,
      'points': 68,
      'proofMediaId': 'proof-9',
      'note': '微信转账，付款人昵称与账号一致',
      'createdAt': '2026-10-06T12:34:00Z',
      'status': 'pending',
    },
    {
      'id': '10',
      'nickname': '雪山',
      'uid': 'U10086',
      'amountYuan': 128,
      'points': 128,
      'proofMediaId': 'proof-10',
      'createdAt': '2026-10-06T12:51:00Z',
      'status': 'pending',
    },
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

    if (key == 'GET /user/identity') {
      return _body(envelope(const {
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 1,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '小云',
              'workerStatus': 1,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
                {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
              ],
            },
          }
        ],
      }));
    }
    if (key == 'GET /recharge/requests') {
      return _body(envelope(const {'list': _pending, 'total': 2, 'pendingCount': 2}));
    }
    if (key == 'GET /recharge/me') {
      return _body(envelope(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }));
    }
    return _body(envelope(const {'list': [], 'total': 0}));
  }

  ResponseBody _body(Object body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
