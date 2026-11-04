import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「我的」页 **方案 B** 出图（真机尺寸 390 × 844，中文 + Material 图标都挂上）
///
/// 产出（`docs/验收素材/2026-10-13-我的页重构/`，**不入 git**）：
/// 1. `profile_1_first_screen.png`  首屏（资料卡 + 资产卡可见）
/// 2. `profile_2_scrolled.png`      滚动后（身份区块 + 服务卡）
/// 3. `profile_3_full_page.png`     整页长图（390 × 1560，一屏看完全部区块与顺序）
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（`flutter test` 自带字体没有 CJK 字形，不挂会变豆腐块）；
/// 同时挂 `MaterialIcons` 让图标正常 —— 两条都是本项目既有出图脚本的既有做法。
void main() {
  const cjk = 'ProfileRedesignCJK';
  const pageKey = Key('profile-redesign-page');
  late final Directory outDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    outDir = Directory('${resolveRepoRoot()}/docs/验收素材/2026-10-13-我的页重构')..createSync(recursive: true);
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
  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${outDir.path}/$name')..writeAsBytesSync(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('SHOT $name -> ${file.absolute.path} (${bytes.lengthInBytes} bytes)');
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

  void screen(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// 有界推进（页面里有 Toast/进度动画的可能，不用 pumpAndSettle）
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
        'level': 2, // 进阶会员（next = 精英会员 ¥2,000 → 64% 进度、差 ¥713.50，与设计稿逐值一致）
        'totalSpent': 1286.5,
      }),
    );
    // 出图要**已绑定**形态（「切换身份」+ 已绑定 · 王野）：直接摆状态最确定
    // （`AuthStore` 内部 ApiClient 在本文件早于 `debugDefaultDio` 构造，走真实 dio → 假接口喂不到它）
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
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://shot.local'))
      ..httpClientAdapter = _Router();
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  testWidgets('出图 1：首屏（资料卡 + 资产卡）', (tester) async {
    screen(tester);
    await tester.pumpWidget(stage(const ProfilePage()));
    await settle(tester);
    expect(find.text('¥248.60'), findsOneWidget);
    await shoot(tester, 'profile_1_first_screen.png');
  });

  testWidgets('出图 2：滚动后（身份区块 + 服务卡）', (tester) async {
    screen(tester);
    await tester.pumpWidget(stage(const ProfilePage()));
    await settle(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await settle(tester);
    expect(find.text('系统通知'), findsOneWidget);
    await shoot(tester, 'profile_2_scrolled.png');
  });

  testWidgets('出图 3：整页长图（区块顺序：资料 → 资产 → 身份 → 服务）', (tester) async {
    screen(tester, height: 1560);
    await tester.pumpWidget(stage(const ProfilePage()));
    await settle(tester);
    expect(find.text('关于祁连山电竞'), findsOneWidget, reason: '整页长图必须一屏装完全部区块');
    await shoot(tester, 'profile_3_full_page.png');
  });
}

/// 假服务器：余额 ¥248.60 + 订单 17 单（待接单 2 / 进行中 1 / 待评价 3）—— 与设计稿 B 同值
class _Router implements HttpClientAdapter {
  static const List<Map<String, dynamic>> _orders = [
    {'id': '1', 'status': 'pending_take'},
    {'id': '2', 'status': 'pending_take'},
    {'id': '3', 'status': 'taken'},
    {'id': '4', 'status': 'pending_confirm'},
    {'id': '5', 'status': 'pending_confirm'},
    {'id': '6', 'status': 'pending_confirm'},
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

    if (key == 'GET /user/wallet') return _body(envelope({'balance': 248.6}));
    if (key == 'GET /user/orders') {
      return _body(envelope({'list': _orders, 'total': 17, 'page': 1, 'pageSize': 50}));
    }
    if (key == 'GET /user/identity') {
      return _body(envelope({
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 2,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {'workerNo': 'W20260118', 'nickname': '王野', 'workerStatus': 1, 'divisionPermissions': const []},
          }
        ],
      }));
    }
    if (key == 'GET /public/levels') return _body(envelope(const []));
    return _body(envelope({'list': const [], 'total': 0}));
  }

  ResponseBody _body(Object body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
