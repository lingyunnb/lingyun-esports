/// 「结束咨询」在**客服同时服务 ≥2 条**时必须精确关掉**当前这一条**（2026-10-11 遗留缺陷修复）
///
/// ## 缺陷（真机报障的遗留，服务端已在 `2241595` 里点明"属老板端待发版的改动"）
/// 打手态进聊天页走 `home_shell.openWorkerChat`，原来**不传 worker 侧路径/id**：
/// 「结束咨询」打的是 `POST /user/conversation/close`（**请求里没有任何 id**）。
/// 服务端 `closeByUser` 的兼容分支只在"我自己没有进行中会话、且**恰好服务一条**"时推断，
/// **同时服务 ≥2 条时不做任何猜测 → 404**（点「确认完成」后弹「没有进行中的客服会话」，
/// 那一条咨询照旧挂在列表上带红点）。
///
/// ## 修法（客户端把 id 明确传下去，服务端一行未改）
/// 侧别 → 路径 → 带 id 的关闭路由，**一条链**：
/// `IdentityWorkerChatTarget.csServing`（当事客服）
/// → `sendPath = /worker/cs/conversations/<id>/messages`
/// → `ChatDetailPage.closeConsultPath()` = `/worker/cs/conversations/<id>/close`。
///
/// ## 本文件钉的就是**请求形状**
/// 用假 `ApiClient`（dio 适配器）跑**生产链路**（消息页 → `workerChatPage`（生产映射）→ 聊天页
/// → [结束咨询] → 确认），断言：
///  ① 只有一条关闭请求，且路径**带这一条的会话 id**（`/worker/cs/conversations/560/close`）；
///  ② 绝不出现不带 id 的 `/user/conversation/close`；
///  ③ 另一条（561）**一个关闭请求都没有**（同时服务多条时不许关错/连坐）。
///
/// ## 变异验证（报告里贴红/绿）
/// 把 `closeConsultPath` 的 worker 分支去掉（即恢复"永远 `/user/conversation/close`"）
/// → ① 立刻变红（实测：请求路径里没有 560）。还原 → 绿。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 "METHOD /path" 精确回包 + **记录全部请求**的假服务器
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  int calls(String key) => requests.where((String r) => r == key).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 404, 'message': '请求的资源不存在', 'data': null}),
        404,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeServer server;
  int seq = 0;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    final String base = 'http://cs-close-side-${seq++}.local';
    server = _FakeServer();
    final Dio dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = dio;
    // 打手态（companion）：聊天页与列表用的都是这枚令牌
    AuthStore.instance.debugSetSession(accessToken: 'companion-worker-token');
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-worker-token',
      workerMe: AuthMe.fromJson(<String, dynamic>{
        'id': '479',
        'nickname': '小云',
        'uid': 'U2393620058',
        'role': 'worker',
        'worker': <String, dynamic>{'workerNo': 'W0000', 'canTakeOrder': true, 'canServeCustomer': true},
      }),
    );
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  Map<String, dynamic> csRow({required String id, required int unread}) => <String, dynamic>{
        'id': id,
        'type': 'cs',
        'name': null,
        'orderId': null,
        'userNickname': '小苏',
        'unread': unread,
        'lastSeq': unread,
        'status': 'open',
      };

  Map<String, dynamic> messages(List<Map<String, dynamic>> list) =>
      <String, dynamic>{'list': list, 'total': list.length};

  Map<String, dynamic> msg(String id, int seqNo, String senderType, String content) => <String, dynamic>{
        'msgId': id,
        'seq': seqNo,
        'senderType': senderType,
        'senderId': senderType == 'user' ? '1129' : '479',
        'msgType': 'text',
        'content': content,
        'recalled': false,
        'createdAt': '2026-10-09T05:0$seqNo:00.000Z',
        'senderNickname': senderType == 'user' ? '小苏' : '小云',
      };

  /// 摆一屏：**客服同时服务两条**（560 未读 10 / 561 未读 3），点开指定那条 →
  /// 走**生产映射** `workerChatPage` 进聊天页 → 点「结束咨询」→ 确认
  Future<void> openAndFinish(WidgetTester tester, {required String unreadOfTarget}) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[csRow(id: '560', unread: 10), csRow(id: '561', unread: 3)],
    });
    // 我作为发起方的客服会话：一条都没有 → 两条**都是我在服务的**
    server.ok('GET /user/conversations', <String, dynamic>{'list': <dynamic>[], 'total': 0});
    for (final String id in <String>['560', '561']) {
      server.ok('GET /worker/cs/conversations/$id/messages',
          messages(<Map<String, dynamic>>[msg('m$id', 1, 'user', '你好，我昨天那单打手迟到了四十分钟')]));
      server.ok('GET /worker/cs/conversations/$id/info', <String, dynamic>{
        'id': id,
        'type': 'cs',
        'status': 'open',
        'staffNo': 'W0000',
        'peerReadSeq': 0,
        'myReadSeq': 1,
        'lastSeq': 1,
      });
      server.ok('POST /worker/cs/conversations/$id/close',
          <String, dynamic>{'ok': true, 'conversationId': id});
    }
    // 故意准备"老板侧老路由"的成功回包：万一客户端还在打它，本测试必须能分辨出来
    server.ok('POST /user/conversation/close', <String, dynamic>{'ok': true, 'conversationId': '999'});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          // 与生产同一条映射（`home_shell.openWorkerChat` → `workerChatPage`）
          openChat: (BuildContext ctx, IdentityWorkerChatTarget t) async {
            await Navigator.of(ctx).push(
              MaterialPageRoute<void>(builder: (_) => workerChatPage(t)),
            );
          },
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 【2026-10-17 重钉】负责人定案「消息页去掉上方胶囊，改为单页三分区」→ 不再有「客服」分段可点：
    // 客服会话与老板段一页并列。本用例关心的东西没变（点哪一条、就关哪一条）。
    // 点开**指定**那一条（未读角标是两条之间唯一的可视化差异）
    await tester.tap(find.text(unreadOfTarget));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // 聊天页底部「结束咨询」→ 确认弹窗「确认完成」
    expect(find.text('结束咨询'), findsOneWidget, reason: '客服侧会话页必须有「结束咨询」');
    await tester.tap(find.text('结束咨询'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('本次咨询已完成？'), findsOneWidget);
    await tester.tap(find.text('确认完成'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('① 服务 ≥2 条时点开其中一条并结束咨询 → 只有**带这条 id** 的关闭请求（不猜、不连坐）',
      (WidgetTester tester) async {
    await openAndFinish(tester, unreadOfTarget: '10'); // 未读 10 = 会话 560

    final List<String> closes =
        server.requests.where((String r) => r.startsWith('POST ') && r.endsWith('/close')).toList();

    expect(closes, <String>['POST /worker/cs/conversations/560/close'],
        reason: '请求形状必须带**这一条**的会话 id（同时服务 561 时也能精确定位 560）');
    expect(server.calls('POST /user/conversation/close'), 0,
        reason: '再打不带 id 的老路由 = 又让服务端猜（≥2 条时 404）');
    expect(server.calls('POST /worker/cs/conversations/561/close'), 0,
        reason: '另一条咨询一个关闭请求都不许有（不许连坐）');
  });

  testWidgets('② 点开另一条（561）→ 关闭请求带的是 561 的 id（不是"上一次点的那条"）',
      (WidgetTester tester) async {
    await openAndFinish(tester, unreadOfTarget: '3'); // 未读 3 = 会话 561

    final List<String> closes =
        server.requests.where((String r) => r.startsWith('POST ') && r.endsWith('/close')).toList();

    expect(closes, <String>['POST /worker/cs/conversations/561/close']);
    expect(server.calls('POST /worker/cs/conversations/560/close'), 0);
    expect(server.calls('POST /user/conversation/close'), 0);
  });

  testWidgets('③ 老板态（我发起的那条）→ 仍旧走老路由 `/user/conversation/close`（侧别不许串）',
      (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[csRow(id: '433', unread: 4)],
    });
    server.ok('GET /user/conversations', <String, dynamic>{
      'list': <Map<String, dynamic>>[<String, dynamic>{'id': '433', 'type': 'cs', 'status': 'open'}],
      'total': 1,
    });
    server.ok('GET /user/conversations/433/messages',
        messages(<Map<String, dynamic>>[msg('m433', 1, 'worker', '您好，我是人工客服，请讲')]));
    server.ok('GET /user/conversations/433/info', <String, dynamic>{
      'id': '433',
      'type': 'cs',
      'status': 'open',
      'staffNo': 'W0009',
      'peerReadSeq': 0,
      'myReadSeq': 1,
      'lastSeq': 1,
    });
    server.ok('POST /user/conversation/close', <String, dynamic>{'ok': true, 'conversationId': '433'});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          openChat: (BuildContext ctx, IdentityWorkerChatTarget t) async {
            await Navigator.of(ctx).push(
              MaterialPageRoute<void>(builder: (_) => workerChatPage(t)),
            );
          },
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 【2026-10-17 重钉】分段控件已删除（单页三分区）→ 直接点那条客服会话的未读角标
    await tester.tap(find.text('4'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    await tester.tap(find.text('结束咨询'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tap(find.text('确认完成'));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(server.calls('POST /user/conversation/close'), 1, reason: '我发起的咨询 = 老板态那条路（属主至多一条进行中）');
    expect(server.calls('POST /worker/cs/conversations/433/close'), 0,
        reason: '不许把"我发起的"误推上客服路由（会被 assertWorkerCs 判 403）');
  });

  test('④ 路径判据本身（唯一出处）：侧别 → 带 id / 不带 id', () {
    expect(ChatDetailPage.closeConsultPath(conversationId: '560', sendPath: '/worker/cs/conversations/560/messages'),
        '/worker/cs/conversations/560/close');
    expect(ChatDetailPage.closeConsultPath(conversationId: '560', sendPath: null), '/user/conversation/close');
    expect(ChatDetailPage.closeConsultPath(conversationId: '560', sendPath: '/user/conversations/560/messages'),
        '/user/conversation/close');
  });
}
