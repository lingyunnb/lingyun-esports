import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 客服大厅 · **出图**（负责人 2026-10-08：「有客服权限的人用打手端主动接咨询，就像接单大厅那样」）
///
/// 产出 6 张（`apps/boss-app/build/`，随后拷进 `docs/验收素材/2026-10-08-客服大厅/`）：
/// 1. `cs_hall_1_list.png`        —— 客服大厅（有数据：3 条，含 1 条 >5 分钟琥珀金 + 1 条【图片】摘要）
/// 2. `cs_hall_2_empty.png`       —— 大厅空态「当前没有等待接入的咨询」
/// 3. `cs_hall_3_claimed_notice.png` —— 被抢走后：该条淡出 + 顶部一行轻提示「已被 客服XX 接入」
/// 4. `cs_hall_4_nav_4vs3.png`    —— 底部导航 **4 项 vs 3 项**并排对照（同一生产组件、同一份常量）
/// 5. `cs_hall_5_cs_chat.png`     —— 客服视角会话页：顶上是**老板昵称** + 「老板咨询 · 已接入」+ 底部「结束咨询」
/// 6. `cs_hall_6_boss_submitted.png` —— 老板侧未接入态：「已提交，客服会尽快接入」（**不承诺时间**）
///
/// ## 数据全部是注入的（可复跑铁律，2026-10-06 负责人要求）
/// 老板昵称 / 摘要 / 等待秒数 / 消息内容一条都不来自线上 —— 线上客服池随时在变，
/// 任何"抓线上响应再出图"的用例都会**随运营数据变红**（那不是回归信号，是噪声）。
///
/// ## 与既有出图脚本一致的三个坑（别回退）
/// - `toImage` 必须在 `tester.runAsync` 里调；
/// - **不用 `pumpAndSettle()`**（细进度是无限动画）→ 用有界 `settle()`；
/// - 中文字形靠 `FontLoader` 挂系统 `msyh`，图标单独挂 `MaterialIcons`，否则图里全是豆腐块。
void main() {
  const cjk = 'CsHallShotCJK';
  final Key hallShot = const Key('cs-hall-shot');
  final Key navShot = const Key('cs-nav-shot');
  final Key chatShot = const Key('cs-chat-shot');
  final Key bossShot = const Key('cs-boss-shot');

  /// 极简事件总线（把 `RealtimeClient.shared.on` 截下来，投递服务端会推的事件）
  final Map<String, List<void Function(dynamic)>> bus = <String, List<void Function(dynamic)>>{};
  void fire(String event, dynamic data) {
    for (final void Function(dynamic) h in List<void Function(dynamic)>.of(bus[event] ?? const [])) {
      h(data);
    }
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final String path in const <String>[
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      final FontLoader loader = FontLoader(cjk)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final String iconPath in const <String>[
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final File f = File(iconPath);
      if (!f.existsSync()) continue;
      final FontLoader loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    // 出图关缓存：避免"上一条用例留下的缓存"让画面随执行顺序变化
    ApiClient.cacheEnabled = false;
    bus.clear();
    RealtimeClient.shared.debugOnOverride = (String event, void Function(dynamic) handler) {
      (bus[event] ??= <void Function(dynamic)>[]).add(handler);
      return () => bus[event]?.remove(handler);
    };
    _enterWorkerState(canServeCustomer: true);
  });

  tearDown(() {
    AppToast.dismiss();
    RealtimeClient.shared.debugOnOverride = null;
    bus.clear();
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final RenderRepaintBoundary b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final ui.Image image = await b.toImage(pixelRatio: ratio);
      final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// 有界推进（见文件头：不用 pumpAndSettle）
  Future<void> settle(WidgetTester tester, {int frames = 26}) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget frame(Key k, Widget child) => RepaintBoundary(
        key: k,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: cjk,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFF4F6F9),
          ),
          home: child,
        ),
      );

  // ==========================================================================
  // 图 1 客服大厅（有数据）
  // ==========================================================================
  testWidgets('出图①：客服大厅（有数据 · 含 >5 分钟琥珀金 + 【图片】摘要）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      frame(
        hallShot,
        IdentityWorkerShellScaffold(
          canServeCustomer: true,
          currentIndex: 2, // 「客服」
          onTap: (_) {},
          body: IdentityWorkerCsHallPage(api: _api(<String, dynamic>{
            '/worker/cs/hall': _hall(<Map<String, dynamic>>[
              _item(
                id: '9301',
                nickname: '林间有鹿',
                uid: 'B88231',
                preview: '想问下三角洲行动机密档案陪练，我这边晚上九点后有空',
                waitedSeconds: 512,
                msgCount: 3,
              ),
              _item(
                id: '9302',
                nickname: '祁连山下的猫',
                uid: 'B90117',
                preview: '【图片】',
                waitedSeconds: 168,
                msgCount: 2,
              ),
              _item(
                id: '9303',
                nickname: '不接急单的老张',
                uid: '',
                preview: '和平精英手游，星钻段位，想找个固定陪练，长期',
                waitedSeconds: 41,
                msgCount: 1,
              ),
            ], online: 4),
          })),
        ),
      ),
    );
    await settle(tester);
    await shoot(tester, hallShot, 'cs_hall_1_list.png');
  });

  // ==========================================================================
  // 图 2 空态
  // ==========================================================================
  testWidgets('出图②：大厅空态「当前没有等待接入的咨询」', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      frame(
        hallShot,
        IdentityWorkerShellScaffold(
          canServeCustomer: true,
          currentIndex: 2,
          onTap: (_) {},
          body: IdentityWorkerCsHallPage(api: _api(<String, dynamic>{
            '/worker/cs/hall': _hall(const <Map<String, dynamic>>[], online: 3),
          })),
        ),
      ),
    );
    await settle(tester);
    await shoot(tester, hallShot, 'cs_hall_2_empty.png');
  });

  // ==========================================================================
  // 图 3 被抢走（该条淡出 + 一行轻提示）
  // ==========================================================================
  testWidgets('出图③：被抢走后 —— 该条淡出移除 + 顶部一行轻提示（不弹窗）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final ApiClient api = _api(<String, dynamic>{
      '/worker/cs/hall': _hall(<Map<String, dynamic>>[
        _item(
          id: '9301',
          nickname: '林间有鹿',
          uid: 'B88231',
          preview: '想问下三角洲行动机密档案陪练，我这边晚上九点后有空',
          waitedSeconds: 512,
          msgCount: 3,
        ),
        _item(
          id: '9302',
          nickname: '祁连山下的猫',
          uid: 'B90117',
          preview: '【图片】',
          waitedSeconds: 168,
          msgCount: 2,
        ),
      ], online: 4),
    });

    await tester.pumpWidget(
      frame(
        hallShot,
        IdentityWorkerShellScaffold(
          canServeCustomer: true,
          currentIndex: 2,
          onTap: (_) {},
          body: IdentityWorkerCsHallPage(api: api),
        ),
      ),
    );
    await settle(tester);

    // 别人抢走了第 1 条（真实载荷：{conversationId, byUserId, byNickname, byWorkerNo}）
    fire('cs:claimed', <String, dynamic>{
      'conversationId': '9301',
      'byUserId': 'w9',
      'byNickname': '祁连山·阿野',
      'byWorkerNo': 'W20260222',
    });
    // 停在**淡出中**这一刻：轻提示已上屏、被抢的那条还没完全消失（最能说明"发生了什么"）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await shoot(tester, hallShot, 'cs_hall_3_claimed_notice.png');
    await settle(tester, frames: 12);
  });

  // ==========================================================================
  // 图 4 底部 4 项 vs 3 项对照
  // ==========================================================================
  testWidgets('出图④：底部导航 4 项（有客服权限） vs 3 项（无权限 · 与改动前一致）', (tester) async {
    tester.view.physicalSize = const Size(830 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget phone({required bool canServeCustomer, required String caption, required String note, required int index}) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(caption, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
                  const SizedBox(height: 3),
                  Text(note, style: const TextStyle(fontSize: 11, color: Color(0xFF4A5A6E))),
                ],
              ),
            ),
            SizedBox(
              width: 390,
              height: 480,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: IdentityWorkerShellScaffold(
                  canServeCustomer: canServeCustomer,
                  currentIndex: index,
                  onTap: (_) {},
                  body: Container(
                    color: const Color(0xFFF4F6F9),
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 74),
                    child: Text(
                      canServeCustomer ? '底部：接单 · 消息 · 客服 · 我的' : '底部：接单 · 消息 · 我的',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF4A5A6E)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

    await tester.pumpWidget(
      frame(
        navShot,
        Scaffold(
          body: Container(
            color: const Color(0xFFEEF2F8),
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                phone(
                  canServeCustomer: true,
                  caption: '有客服权限（canServeCustomer = true）',
                  note: '4 项 · 第 3 项是新增的「客服」（选中态主色）',
                  index: 2,
                ),
                const SizedBox(width: 18),
                phone(
                  canServeCustomer: false,
                  caption: '没有客服权限（canServeCustomer = false）',
                  note: '仍然 3 项 · 文案/图标/顺序与改动前逐项一致，不留空位',
                  index: 0,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await shoot(tester, navShot, 'cs_hall_4_nav_4vs3.png');
  });

  // ==========================================================================
  // 图 5 客服视角会话页
  // ==========================================================================
  testWidgets('出图⑤：客服视角会话页（顶部老板昵称 + 老板咨询 · 已接入 + 底部结束咨询）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      frame(
        chatShot,
        ChatDetailPage(
          conversationId: '9301',
          title: '林间有鹿',
          csConversation: true,
          peerNickname: '林间有鹿',
          api: _api(<String, dynamic>{
            '/user/conversations/9301/messages': _messages(<Map<String, dynamic>>[
              _msg('m1', 1, 'user', '在吗？想问下三角洲行动机密档案陪练'),
              _msg('m2', 2, 'worker', '在的，机密档案我可以接，先说下你常玩的时间段'),
              _msg('m3', 3, 'user', '晚上九点之后都行，周末全天'),
              _msg('m4', 4, 'worker', '好，那今晚九点我先带你跑两把熟悉一下节奏'),
              _msg('m5', 5, 'user', '行，那我等你'),
            ]),
            '/user/conversations/9301/info': <String, dynamic>{
              'code': 0,
              'message': 'ok',
              'data': <String, dynamic>{
                'id': '9301',
                'type': 'cs',
                'status': 'open',
                'staffNo': 'W20260118',
              },
            },
          }),
        ),
      ),
    );
    await settle(tester, frames: 40);
    await shoot(tester, chatShot, 'cs_hall_5_cs_chat.png');
  });

  // ==========================================================================
  // 图 6 老板侧未接入态
  // ==========================================================================
  testWidgets('出图⑥：老板侧未接入态「已提交，客服会尽快接入」（不承诺时间）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // 老板态（不是打手态）：这句话是给老板看的
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'shot-boss-token',
      me: AuthMe.fromJson(const <String, dynamic>{
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
      }),
    );

    await tester.pumpWidget(
      frame(
        bossShot,
        ChatDetailPage(
          conversationId: '9401',
          title: '联系客服',
          csConversation: true,
          peerNickname: '祁连山客服',
          api: _api(<String, dynamic>{
            '/user/conversations/9401/messages': _messages(<Map<String, dynamic>>[
              _msg('m1', 1, 'user', '你好，我昨天那单打手迟到了四十分钟，想问下能不能退一部分'),
            ]),
            '/user/conversations/9401/info': <String, dynamic>{
              'code': 0,
              'message': 'ok',
              'data': <String, dynamic>{
                'id': '9401',
                'type': 'cs',
                'status': 'open',
                // 尚无客服接入 → 服务端下发空工号 → 客户端才说得出「已提交，客服会尽快接入」
                'staffNo': '',
              },
            },
          }),
        ),
      ),
    );
    await settle(tester, frames: 40);
    await shoot(tester, bossShot, 'cs_hall_6_boss_submitted.png');
  });
}

// ============================================================================
// 注入数据（与线上无关，可复跑）
// ============================================================================

void _enterWorkerState({required bool canServeCustomer}) {
  AuthStore.instance.debugSetIdentity(
    identity: AppIdentity.worker,
    companionToken: 'companion-token',
    companionRefreshToken: 'companion-refresh',
    status: IdentityBindingStatus.fromJson(<String, dynamic>{
      'bound': true,
      'activeCount': 1,
      'maxPerBoss': 1,
      'bindings': <Map<String, dynamic>>[
        <String, dynamic>{
          'bindingId': '77',
          'status': 'active',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'nickname': '王野',
            'workerStatus': 1,
            'canServeCustomer': canServeCustomer,
          },
        },
      ],
    }),
    workerMe: AuthMe.fromJson(<String, dynamic>{
      'id': '2',
      'username': 'wangye',
      'uid': 'W20260118',
      'nickname': '王野',
      'role': 'worker',
      'worker': <String, dynamic>{
        'workerNo': 'W20260118',
        'canTakeOrder': true,
        'canServeCustomer': canServeCustomer,
        'divisionPermissions': <Map<String, dynamic>>[
          <String, dynamic>{
            'divisionId': '1',
            'name': '和平精英',
            'shortName': '和平精英',
            'platformLabel': '手游',
            'canTakeOrder': true,
          },
        ],
      },
    }),
  );
  AuthStore.instance.debugSetSession(accessToken: 'companion-token');
}

/// 服务端真实字段名（`chat.service.ts#csHall`）
Map<String, dynamic> _item({
  required String id,
  required String nickname,
  required String uid,
  required String preview,
  required int waitedSeconds,
  required int msgCount,
}) =>
    <String, dynamic>{
      'conversationId': id,
      'userNickname': nickname,
      'userUid': uid,
      'preview': preview,
      'waitedSeconds': waitedSeconds,
      'msgCount': msgCount,
    };

Map<String, dynamic> _hall(List<Map<String, dynamic>> list, {required int online}) => <String, dynamic>{
      'code': 0,
      'message': 'ok',
      'data': <String, dynamic>{
        'list': list,
        'total': list.length,
        'page': 1,
        'pageSize': 20,
        'waitingTotal': list.length,
        'onlineCsCount': online,
      },
    };

Map<String, dynamic> _messages(List<Map<String, dynamic>> list) => <String, dynamic>{
      'code': 0,
      'message': 'ok',
      'data': <String, dynamic>{'list': list, 'total': list.length},
    };

Map<String, dynamic> _msg(String id, int seq, String senderType, String content) => <String, dynamic>{
      'msgId': id,
      'seq': seq,
      'senderType': senderType,
      'senderId': senderType == 'user' ? '9301' : '2',
      'msgType': 'text',
      'content': content,
      'recalled': false,
      'createdAt': '2026-10-08T13:0$seq:00.000Z',
      'senderNickname': senderType == 'user' ? '林间有鹿' : '王野',
    };

ApiClient _api(Map<String, dynamic> routes) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'http://cs-shot.local'))..httpClientAdapter = _ShotRouter(routes);
  return ApiClient(dio: dio);
}

/// 按路径前缀匹配的假适配器（前缀长的优先，避免 `/x/1` 抢了 `/x/1/info`）
class _ShotRouter implements HttpClientAdapter {
  _ShotRouter(this.routes);

  final Map<String, dynamic> routes;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final List<String> keys = routes.keys.where(options.path.startsWith).toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    final dynamic body = keys.isEmpty
        ? <String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <dynamic>[]}}
        : routes[keys.first];
    return ResponseBody.fromString(jsonEncode(body), 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
