import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合并双端 · 身份切换 —— **出图**（真机尺寸 390 × 844，中文 + Material 图标都挂上）
///
/// 产出（`apps/boss-app/build/`）：
/// 1. `merge_identity_1_boss_mine.png`          老板态「我的」（身份分组 + 两枚「当前身份：老板」标签）
/// 2. `merge_identity_2_sheet_default.png`      切换身份弹层（默认）
/// 3. `merge_identity_3_sheet_error.png`        切换身份弹层（错误态：角色不符，文案来自服务端）
/// 4. `merge_identity_4_worker_hall.png`        打手态 · 接单大厅（28dp 身份细带）
/// 5. `merge_identity_5_worker_messages.png`    打手态 · 消息（老板 · 客服 · 好友条件段）
/// 6. `merge_identity_6_worker_mine.png`        打手态 · 我的（工号/权限/切回老板/解绑）
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（`flutter test` 自带字体没有 CJK 字形，不挂会变豆腐块）；
/// 同时挂 `MaterialIcons` 让图标正常 —— 两条都是本项目既有出图脚本的既有做法。
void main() {
  const cjk = 'MergeIdentityCJK';
  const pageKey = Key('merge-identity-page');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
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

  /// 出图（`toImage` 必须放进 `runAsync`：假时钟下它不会自己回帧）
  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page,
        ),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
        'totalSpent': 1286,
      }),
    );
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  // =====================================================================================
  // 1. 老板态「我的」（身份分组 + 当前身份标签）
  // =====================================================================================
  testWidgets('出图 1：老板态 · 我的（身份区块在资产卡之下 · 方案 B）', (tester) async {
    phone(tester);
    final router = _Router();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://shot.local'))
      ..httpClientAdapter = router;
    // 出图要看到**已绑定**形态（「切换身份」+ 已绑定 · 王野 W20260118）：
    // `AuthStore` 内部的 ApiClient 在本文件里早于 `debugDefaultDio` 构造（走的是真实 dio）→
    // `/user/identity` 在这条出图路径上拿不到假数据，直接把绑定状态摆好最确定（不发请求）。
    AuthStore.instance.debugSetIdentity(
      status: IdentityBindingStatus.fromJson(const {
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 2,
        'message': '可继续绑定',
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {'workerNo': 'W20260118', 'nickname': '王野', 'workerStatus': 1, 'divisionPermissions': []},
          }
        ],
      }),
    );
    await tester.pumpWidget(stage(const ProfilePage()));
    await settle(tester);
    // 方案 B（2026-10-13 负责人批准）：身份区块移到**资产卡（余额）之下**；
    // 已绑定时入口文案仍是「切换身份」（未绑定时不存在这个入口，见 profile_redesign_test）
    expect(find.text('切换身份'), findsOneWidget);
    await shoot(tester, pageKey, 'merge_identity_1_boss_mine.png');
  });

  // =====================================================================================
  // 2–3. 切换身份弹层：默认 / 错误态
  // =====================================================================================
  testWidgets('出图 2：切换身份弹层（默认）', (tester) async {
    phone(tester);
    final router = _Router()..identityBound = false;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: cjk, useMaterial3: true),
      home: RepaintBoundary(
        key: pageKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: Stack(
            children: [
              const ColoredBox(color: Color(0xFFE9EEF6), child: SizedBox.expand()),
              Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 760),
                  child: IdentitySwitchSheet(
                    key: UniqueKey(),
                    api: (Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = router)
                        .let((d) => ApiClient(dio: d)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await settle(tester);
    await shoot(tester, pageKey, 'merge_identity_2_sheet_default.png');
  });

  testWidgets('出图 3：切换身份弹层（错误态 · 文案来自服务端）', (tester) async {
    phone(tester);
    // 未绑定 → 弹层才是「输账密」形态，才造得出账密/角色类错误态
    final router = _Router()
      ..identityBound = false
      ..bindError = (code: 403, message: '该账号不是打手账号，无法绑定', errorCode: '');
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: cjk, useMaterial3: true),
      home: RepaintBoundary(
        key: pageKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 760),
              child: IdentitySwitchSheet(
                key: UniqueKey(),
                api: (Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = router).let((d) => ApiClient(dio: d)),
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'ayuan_2026');
    await tester.enterText(find.byType(TextField).at(1), 'pw123456');
    await tester.tap(find.text('绑定并切换为打手'));
    await settle(tester);
    expect(find.textContaining('不是打手账号'), findsWidgets);
    await shoot(tester, pageKey, 'merge_identity_3_sheet_error.png');
  });

  // =====================================================================================
  // 4–6. 打手态三屏
  // =====================================================================================
  Future<void> enterWorker() async {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-token',
      companionRefreshToken: 'companion-refresh',
      status: IdentityBindingStatus.fromJson({
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 1,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '王野',
              'workerStatus': 1,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
                {
                  'divisionId': '2',
                  'name': '三角洲行动',
                  'shortName': '三角洲行动',
                  'platformLabel': '手游',
                  'canTakeOrder': true
                },
                {
                  'divisionId': '3',
                  'name': '三角洲行动',
                  'shortName': '三角洲行动',
                  'platformLabel': '端游',
                  'canTakeOrder': true
                },
              ],
            },
          }
        ],
      }),
      workerMe: AuthMe.fromJson(const {
        'id': '2',
        'username': 'wangye_go',
        'nickname': '王野',
        'role': 'worker',
        'worker': {
          'workerNo': 'W20260118',
          'canTakeOrder': true,
          'divisionPermissions': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '3', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': true},
          ],
        },
      }),
    );
    await AuthStore.instance.switchToWorker();
  }

  testWidgets('出图 4：打手态 · 接单大厅', (tester) async {
    phone(tester);
    await enterWorker();
    final api = ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = _Router(),
    );
    await tester.pumpWidget(stage(IdentityWorkerShellScaffold(
      currentIndex: 0,
      onTap: (_) {},
      body: IdentityWorkerHallPage(api: api, onSwitchBack: () {}),
    )));
    await settle(tester);
    expect(find.text('接单大厅'), findsWidgets);
    await shoot(tester, pageKey, 'merge_identity_4_worker_hall.png');
  });

  testWidgets('出图 5：打手态 · 消息（老板 · 客服 · 好友）', (tester) async {
    phone(tester);
    await enterWorker();
    final router = _Router()..friendConvs = true;
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = router);
    await tester.pumpWidget(stage(IdentityWorkerShellScaffold(
      currentIndex: 1,
      onTap: (_) {},
      body: IdentityWorkerMessagesPage(api: api, onSwitchBack: () {}),
    )));
    await settle(tester);
    expect(find.text('好友'), findsOneWidget);
    await shoot(tester, pageKey, 'merge_identity_5_worker_messages.png');
  });

  testWidgets('出图 6：打手态 · 我的', (tester) async {
    phone(tester);
    await enterWorker();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = _Router());
    await tester.pumpWidget(stage(IdentityWorkerShellScaffold(
      currentIndex: 2,
      onTap: (_) {},
      body: IdentityWorkerMinePage(api: api, onSwitchBack: () {}),
    )));
    await settle(tester);
    expect(find.text('切换回老板身份'), findsOneWidget);
    await shoot(tester, pageKey, 'merge_identity_6_worker_mine.png');
  });
}

/// 小工具：`x.let(f)`（避免为了一个表达式引入额外变量）
extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// 出图用的假服务器（只喂这一屏要用的字段）
class _Router implements HttpClientAdapter {
  bool identityBound = true;
  bool friendConvs = true;
  ({int code, String message, String errorCode})? bindError;

  static final List<Map<String, dynamic>> _convs = [
    {
      'id': '75',
      'type': 'worker',
      'unread': 2,
      'lastSeq': 3,
      'status': 'open',
      'updatedAt': '2026-10-06T12:40:00Z',
      'peer': {'id': '31', 'nickname': '麻药'},
      'lastMessage': {'content': '老板：麻烦九点前打完', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:34:00Z'},
    },
    {
      'id': '74',
      'type': 'cs',
      'unread': 0,
      'lastSeq': 23,
      'status': 'open',
      'updatedAt': '2026-10-06T12:30:00Z',
      'lastMessage': {'content': '祁连山客服：结算已到账', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:30:00Z'},
    },
  ];

  static final List<Map<String, dynamic>> _friends = [
    {
      'id': '76',
      'type': 'friend',
      'unread': 1,
      'lastSeq': 9,
      'status': 'open',
      'updatedAt': '2026-10-06T12:41:00Z',
      'peer': {'id': '9', 'nickname': '雪山'},
      'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:41:00Z'},
    },
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

    if (key == 'GET /user/identity') {
      return _body(envelope(identityBound
          ? {
              'bound': true,
              'activeCount': 1,
              'maxPerBoss': 2,
              'message': '可继续绑定',
              'bindings': [
                {
                  'bindingId': '77',
                  'status': 'active',
                  'worker': {
                    'workerNo': 'W20260118',
                    'nickname': '王野',
                    'workerStatus': 1,
                    'divisionPermissions': [
                      {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
                    ],
                  },
                }
              ],
            }
          : {'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': []}));
    }
    if (key == 'POST /user/identity/bind') {
      final e = bindError;
      if (e != null) return _body({'code': e.code, 'message': e.message, 'errorCode': e.errorCode, 'data': null}, status: e.code);
      return _body(envelope({'bindingId': '77', 'companionToken': 'c', 'worker': {'workerNo': 'W20260118'}}));
    }
    if (key == 'POST /user/identity/unbind') return _body(envelope({'ok': true}));
    if (key == 'GET /worker/division-permissions') {
      return _body(envelope({
        'list': [
          {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
          {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
          {'divisionId': '3', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': true},
        ]
      }));
    }
    if (key == 'GET /worker/cs/conversations') return _body(envelope({'list': _convs, 'unread': 2}));
    if (key == 'GET /user/conversations') return _body(envelope({'list': friendConvs ? _friends : const []}));
    if (key == 'GET /worker/my-wallet') {
      return _body(envelope({
        'balance': 268.4,
        'totalIncome': 1847.2,
        'settlementCount': 23,
        'tipIncome': 96.4,
      }));
    }
    if (key == 'GET /worker/orders') return _body(envelope({'list': [], 'total': 0}));
    if (key == 'GET /worker/order-hall') {
      return _body(envelope({
        'total': 6,
        'page': 1,
        'pageSize': 50,
        'list': [
          _order('9', 'ORD2026100600018241', '保2红单48.8', 488, 1, '1', 3),
          _order('10', 'ORD2026100600011190', '68.8清图绝密', 1376, 2, '2', 11),
          _order('11', 'ORD2026100600044473', '25清图机密', 250, 1, '3', 26),
          _order('12', 'ORD2026100600090289', '36.6博弈宝冠单（出返现小金人+金aug）不出保888w', 366, 1, '1', 42),
          _order('13', 'ORD2026100600066155', '49.9包1000万（绝密）', 1497, 3, '3', 60),
        ],
      }));
    }
    if (key == 'GET /divisions') {
      return _body(envelope([
        {'id': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'onlineCount': 3},
        {'id': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'onlineCount': 3},
        {'id': '3', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '端游', 'onlineCount': 3},
      ]));
    }
    if (key == 'GET /public/announcements') {
      return _body(envelope({
        'list': [
          {
            'id': '1',
            'title': '欢迎来到 祁连山电竞',
            'content': '祁连山电竞俱乐部正式上线，快来体验专业陪玩服务。',
          }
        ]
      }));
    }
    if (key == 'GET /auth/me') {
      return _body(envelope({
        'id': '2',
        'username': 'wangye_go',
        'nickname': '王野',
        'role': 'worker',
        'worker': {
          'workerNo': 'W20260118',
          'canTakeOrder': true,
          // 出图要看到「接单权限」区真的列出分部 → 这里必须带上（否则页面按"暂无权限"渲染）
          'divisionPermissions': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '3', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': true},
          ],
        },
      }));
    }
    if (key == 'GET /user/orders') return _body(envelope({'list': [], 'total': 0}));
    if (key == 'GET /user/wallet') return _body(envelope({'balance': 1286}));
    if (key == 'GET /public/levels') return _body(envelope(const []));
    // 其它一律空列表成功，避免任何一屏卡在加载态
    return _body(envelope({'list': [], 'total': 0}));
  }

  static Map<String, dynamic> _order(String id, String no, String name, num amount, int qty, String divisionId, int minutesAgo) => {
        'id': id,
        'orderNo': no,
        'totalAmount': amount,
        'status': 'pending_take',
        'statusName': '待接单',
        'quantity': qty,
        'createdAt': DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String(),
        'productName': name,
        'divisionId': divisionId,
      };

  ResponseBody _body(Object body, {int status = 200}) => ResponseBody.fromString(
        body is String ? body : jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        },
      );

  @override
  void close({bool force = false}) {}
}
