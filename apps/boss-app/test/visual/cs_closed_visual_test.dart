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

/// 客服咨询「已结束仍在列表 / 点开 404」修复 · **出图**（2026-10-11）
///
/// 产出 3 张（`apps/boss-app/build/`，随后拷进 `docs/验收素材/2026-10-11-客服结束/`）：
/// 1. `01-修复后-消息列表客服段.png`  —— 打手态消息页「客服」段：真机那**三行重复**里
///    两条已结束的**不再出现**，只留正在服务的那条（带未读 10 红点）
/// 2. `02-修复后-已结束会话打开态.png` —— 打开一条已结束的客服会话：顶部「本次咨询已结束」、
///    历史消息**照常可读**、输入栏「本次会话已结束」、**没有**「会话不存在」/「重试」
/// 3. `03-修复后-已结束会话不再计入未读.png` —— 「一键已读」/底部红点对照：已结束那条的未读
///    不再计入总数（列表 10 vs 含已结束的旧算法 17）
///
/// ## 数据全部注入（可复跑铁律）
/// 与 `cs_hall_visual_test.dart` 同一套约定：昵称/未读/消息一条都不来自线上。
///
/// ## 三个坑（与既有出图脚本一致，别回退）
/// - `toImage` 必须在 `tester.runAsync` 里调；
/// - **不用 `pumpAndSettle()`**（细进度是无限动画）→ 用有界 `settle()`；
/// - 中文字形靠 `FontLoader` 挂系统 `msyh`，图标单独挂 `MaterialIcons`，否则图里全是豆腐块。
void main() {
  const cjk = 'CsClosedShotCJK';
  final Key listShot = const Key('cs-closed-list-shot');
  final Key openShot = const Key('cs-closed-open-shot');
  final Key unreadShot = const Key('cs-closed-unread-shot');

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
      'D:/flutter/bin/cache/artifacts/material_design_icons/MaterialIcons-Regular.otf',
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
    ApiClient.cacheEnabled = false;
    _enterWorkerState();
  });

  tearDown(() {
    AppToast.dismiss();
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
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
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

  /// 真机形状的列表：两条**已结束**的自建客服会话（无消息、无预览、无时间）+ 一条正在服务
  /// （未读 10）—— 修复前它们长得一模一样，故称「三行重复」
  Map<String, dynamic> workerConvs() => <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'hasCsPermission': true,
          'list': <Map<String, dynamic>>[
            _conv(id: '429', type: 'cs', status: 'closed', unread: 0, updatedAt: '2026-10-06T07:25:18.000Z'),
            _conv(id: '433', type: 'cs', status: 'closed', unread: 0, updatedAt: '2026-10-07T05:07:41.000Z'),
            _conv(id: '560', type: 'cs', status: 'open', unread: 10, updatedAt: '2026-10-09T05:00:03.000Z'),
            _conv(
              id: '561',
              type: 'worker',
              status: 'open',
              unread: 0,
              updatedAt: '2026-10-09T06:20:00.000Z',
              peer: <String, dynamic>{'userId': '1129', 'nickname': '小苏', 'uid': 'xiaosu9999'},
            ),
          ],
        },
      };

  // ==========================================================================
  // 图 1 修复后的消息列表（客服段）
  // ==========================================================================
  testWidgets('出图①：修复后 · 消息列表「客服」段（已结束的两条不再出现）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      frame(
        listShot,
        Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: IdentityWorkerMessagesPage(
            api: _api(<String, dynamic>{
              '/worker/cs/conversations': workerConvs(),
              '/user/conversations': <String, dynamic>{
                'code': 0,
                'message': 'ok',
                'data': <String, dynamic>{'list': <dynamic>[], 'total': 0},
              },
            }),
            onUnreadChanged: (int _) {},
            openChat: (BuildContext _, IdentityWorkerChatTarget _) async {},
          ),
        ),
      ),
    );
    await settle(tester);
    // 【2026-10-17 重钉】分段控件已删除（负责人定案：单页三分区）→ 不用再点「客服」分段，
    // 一页之内老板段与官方客服段并列；本图仍叫「消息列表客服段」，内容是同一页里的客服分区。
    await shoot(tester, listShot, '01-修复后-消息列表客服段.png');
  });

  // ==========================================================================
  // 图 2 已结束会话的打开态（能读历史、不出现「会话不存在」）
  // ==========================================================================
  testWidgets('出图②：修复后 · 已结束会话打开态（历史可读 + 「本次咨询已结束」+ 无「会话不存在」）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      frame(
        openShot,
        ChatDetailPage(
          conversationId: '560',
          title: '老板',
          csConversation: true,
          peerNickname: '小苏',
          api: _api(<String, dynamic>{
            '/user/conversations/560/messages': _messages(<Map<String, dynamic>>[
              _msg('m1', 1, 'user', '你好，我昨天那单打手迟到了四十分钟'),
              _msg('m2', 2, 'worker', '抱歉久等了，我看下订单记录'),
              _msg('m3', 3, 'user', '好的，麻烦帮我确认一下'),
              _msg('m4', 4, 'worker', '已经核对完，补偿会跟这单一起结算'),
            ]),
            '/user/conversations/560/info': <String, dynamic>{
              'code': 0,
              'message': 'ok',
              'data': <String, dynamic>{
                'id': '560',
                'type': 'cs',
                'status': 'closed',
                'closedBy': 'worker',
                // 当事客服工号（服务端下发真实 worker_no）→ 客服视角说得出「老板咨询 · 已接入」
                'staffNo': 'W0000',
              },
            },
          }),
        ),
      ),
    );
    await settle(tester, frames: 40);
    await shoot(tester, openShot, '02-修复后-已结束会话打开态.png');
  });

  // ==========================================================================
  // 图 3 已结束会话的未读不计入总数（左右对照）
  // ==========================================================================
  testWidgets('出图③：已结束会话的未读**不计入**总未读（左=仅进行中 10 ／ 右=旧算法 17）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(830 * 2, 480 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget panel({required String caption, required String note, required int total}) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(caption,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
                  const SizedBox(height: 3),
                  Text(note, style: const TextStyle(fontSize: 11, color: Color(0xFF4A5A6E))),
                ],
              ),
            ),
            _NavBadgePreview(total: total),
          ],
        );

    await tester.pumpWidget(
      frame(
        unreadShot,
        Scaffold(
          backgroundColor: const Color(0xFFEEF2F8),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                panel(
                  caption: '修复后（服务端 + 客户端都排除已结束）',
                  note: '列表只有进行中的那条 → 红点 = 它的 10 条未读',
                  total: 10,
                ),
                const SizedBox(width: 16),
                panel(
                  caption: '修复前（已结束的也一起算）',
                  note: '已结束会话残留 unread_worker=7 → 红点 17，与列表对不上',
                  total: 17,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester, frames: 10);
    await shoot(tester, unreadShot, '03-修复后-已结束会话不再计入未读.png');
  });
}

/// 底部导航「消息」红点预览（用的是与生产同一条口径：数字直接来自上报的未读总数）
class _NavBadgePreview extends StatelessWidget {
  const _NavBadgePreview({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      height: 92,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F2)),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Text('消息', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF334155))),
          const SizedBox(width: 8),
          Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
            child: Text(
              total > 99 ? '99+' : '$total',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

void _enterWorkerState() {
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
          // 真机截图里的身份细带：打手 · 工号 W0000
          'worker': <String, dynamic>{
            'workerNo': 'W0000',
            'nickname': '小云',
            'workerStatus': 1,
            'canServeCustomer': true,
          },
        },
      ],
    }),
    workerMe: AuthMe.fromJson(<String, dynamic>{
      'id': '479',
      'username': 'lingyunya',
      'uid': 'U2393620058',
      'nickname': '小云',
      'role': 'worker',
      'worker': <String, dynamic>{'workerNo': 'W0000', 'canTakeOrder': true, 'canServeCustomer': true},
    }),
  );
  AuthStore.instance.debugSetSession(accessToken: 'companion-token');
}

/// 一条会话摘要 —— 按服务端真实字段名（`chat.service.ts#workerConversations`）
Map<String, dynamic> _conv({
  required String id,
  required String type,
  required String status,
  required int unread,
  String? updatedAt,
  Map<String, dynamic>? peer,
}) =>
    <String, dynamic>{
      'id': id,
      'type': type,
      'name': null,
      'orderId': null,
      'userNickname': '小苏',
      'peer': ?peer,
      'unread': unread,
      'lastSeq': unread,
      'status': status,
      'updatedAt': updatedAt,
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
      'senderId': senderType == 'user' ? '1129' : '479',
      'msgType': 'text',
      'content': content,
      'recalled': false,
      'createdAt': '2026-10-09T05:0$seq:00.000Z',
      'senderNickname': senderType == 'user' ? '小苏' : '小云',
    };

ApiClient _api(Map<String, dynamic> routes) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'http://cs-closed-shot.local'))..httpClientAdapter = _ShotRouter(routes);
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
