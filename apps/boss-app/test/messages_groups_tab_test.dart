import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/messages_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端消息页 · **单页三分区**（负责人 2026-10-17 定案）
///
/// 负责人原话：「消息页上方不要有胶囊和一键已读，改成全部集中在一页。例如：联系打手 下方是打手；
/// 好友私聊 下方是好友；官方客服 下方是客服消息」。
///
/// 本文件此前钉的是**上一套结构**（上方三枚胶囊 tab：好友私聊 / 客服 / 打手，逐个点开看一段），
/// 那套结构已被负责人明确废除 → 按授权**整体重钉**（不是放宽：旧断言是"点某枚胶囊后只显示该段"，
/// 新断言是"一页之内三段并列、顺序固定、空段不渲染、全空只给一次空态"，
/// 每一条都比原来更严 —— 原来靠切换隐藏的东西，现在必须靠分区标题与纵向顺序证明各归其位）。
///
/// 结构口径（不变的部分，来自 CLAUDE.md 结构规则 3 + 2026-10-04 群组下掉）：
/// 消息页**只有三类**会话，互不混装；「打手」= 老板与接单打手**一对一**直聊（type=worker），
/// 没有订单群、没有群名、没有群成员。系统通知与公告归「公告」，不在消息页。
void main() {
  final Map<String, dynamic> convs = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {'id': '74', 'type': 'cs', 'unread': 0, 'lastSeq': 23, 'status': 'open', 'updatedAt': '2026-09-24T00:34:00Z'},
        {
          'id': '75',
          'type': 'worker', // 打手直聊（原订单群）
          'unread': 2,
          'lastSeq': 3,
          'status': 'open',
          'updatedAt': '2026-09-24T00:40:00Z',
          'peer': {'id': '31', 'nickname': '麻药'},
          'lastMessage': {'content': '老板消息1', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-09-24T00:34:00.080Z'}
        },
        {
          'id': '76',
          'type': 'friend',
          'unread': 1,
          'lastSeq': 9,
          'status': 'open',
          'updatedAt': '2026-09-24T00:41:00Z',
          'peer': {'id': '9', 'nickname': '雪山'},
          'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-09-24T00:41:00.000Z'}
        },
      ],
    },
  };

  /// 只有好友会话（用来证明「空段整段不渲染」：另外两段的标题一个都不许出现）
  final Map<String, dynamic> onlyFriends = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {
          'id': '76',
          'type': 'friend',
          'unread': 1,
          'lastSeq': 9,
          'status': 'open',
          'updatedAt': '2026-09-24T00:41:00Z',
          'peer': {'id': '9', 'nickname': '雪山'},
          'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-09-24T00:41:00.000Z'}
        },
      ],
    },
  };

  final Map<String, dynamic> emptyList = {
    'code': 0,
    'message': 'ok',
    'data': {'list': [], 'total': 0},
  };

  setUp(() {
    // 【2026-10-17 修复 ⑤⑥ 变红 · 用例隔离，不是放宽断言】
    //
    // 失败现象：⑤（只有好友会话）报「联系打手/官方客服 不该出现却出现了」；
    // ⑥（三段全空）报「AppEmptyState 找不到 / 暂无会话 找不到」。
    // 根因在**用例之间**，不在页面：
    //   本文件所有用例打的是同一个 `http://fixture.local` + 同一个 token，而
    //   `ApiCache` 的键 = 账号维度 + 地址 + 路径，且 `/user/conversations` 落 `ttlChat = 15s`
    //   （没进 `neverCachePrefixes`）→ 前序用例（①②③④ 用的是 3 条会话的同一份夹具）写进去的
    //   响应，在 ⑤⑥ 里仍然是"新鲜的"：
    //     · `_paintFromCache()` 用 `peekCache` 读缓存（**连过期都读**）→ ⑤⑥ 第一帧先画出 3 段；
    //     · 随后的 `request` 命中 15s 内的缓存 → 假服务器那个"只有好友 / 全空"根本没有机会上屏。
    //   于是"空段标题不该出现 / 三段全空才出空态"这两条**必须依赖这一次的假响应**的断言必然对不上。
    // 修法：清空缓存 + 关掉 GET 缓存 → 每个用例只看这一次 `_api()` 给的响应。
    // **断言一条没改**（仍是 findsOneWidget / findsNothing，没有一处改成 findsWidgets）。
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  /// 同一套假服务器：会话列表可换，另外三条固定空
  ApiClient api(Map<String, dynamic> conversations) => _api({
        '/user/conversations': conversations,
        '/user/friends': emptyList,
        '/user/friends/requests/incoming': emptyList,
        '/user/notifications': emptyList,
      });

  testWidgets('① 单页三分区：三段标题一页并存、顺序固定 = 联系打手 → 好友私聊 → 官方客服', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(convs))));
    await tester.pumpAndSettle();

    // 三段标题**同时**在树里（没有胶囊、不需要点开任何一枚）
    expect(find.text(MessagesPage.sectionWorker), findsOneWidget);
    expect(find.text(MessagesPage.sectionFriend), findsOneWidget);
    expect(find.text(MessagesPage.sectionCs), findsOneWidget);

    // 顺序固定（负责人指定）：三者的纵向位置严格递增
    final double workerY = tester.getTopLeft(find.text(MessagesPage.sectionWorker)).dy;
    final double friendY = tester.getTopLeft(find.text(MessagesPage.sectionFriend)).dy;
    final double csY = tester.getTopLeft(find.text(MessagesPage.sectionCs)).dy;
    expect(workerY, lessThan(friendY), reason: '① 联系打手 在最前');
    expect(friendY, lessThan(csY), reason: '② 好友私聊 居中；③ 官方客服 在最后');

    // 旧结构（上方三枚胶囊 + 一键已读）必须**一处都不残留**
    expect(find.text('客服'), findsNothing, reason: '旧胶囊的第二枚已删除（官方客服是分区标题，不是胶囊）');
    expect(find.text('打手'), findsNothing, reason: '旧胶囊的第三枚已删除（联系打手是分区标题，不是胶囊）');
    expect(find.text('一键已读'), findsNothing, reason: '负责人 2026-10-17：一键已读整个移除');
    // 旧结构不得残留（模块不混装 + 群组已下掉）
    expect(find.text('群组'), findsNothing);
  });

  testWidgets('② 联系打手段：渲染打手直聊（昵称 + 最后消息 + 未读红点）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(convs))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('麻药'), findsOneWidget); // 打手昵称（一对一，不再有群名）
    expect(find.text('老板消息1'), findsOneWidget); // 最后消息预览
    expect(find.text('2'), findsOneWidget); // 未读红点（去掉一键已读后它是唯一的未读提示）
    expect(find.textContaining('订单群'), findsNothing); // 群概念不得残留

    // 归位证据：这一行在「联系打手」标题之下、且在「好友私聊」标题之上
    final double headerY = tester.getTopLeft(find.text(MessagesPage.sectionWorker)).dy;
    final double rowY = tester.getTopLeft(find.text('麻药')).dy;
    final double nextHeaderY = tester.getTopLeft(find.text(MessagesPage.sectionFriend)).dy;
    expect(rowY, greaterThan(headerY), reason: '打手会话必须落在「联系打手」段内');
    expect(rowY, lessThan(nextHeaderY));
  });

  testWidgets('③ 好友私聊段：显示好友昵称与最后消息（未读红点保留）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(convs))));
    await tester.pumpAndSettle();

    expect(find.text('雪山'), findsOneWidget);
    expect(find.text('今晚打两把？'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '好友会话未读 1 的红点');

    final double headerY = tester.getTopLeft(find.text(MessagesPage.sectionFriend)).dy;
    final double rowY = tester.getTopLeft(find.text('雪山')).dy;
    final double nextHeaderY = tester.getTopLeft(find.text(MessagesPage.sectionCs)).dy;
    expect(rowY, greaterThan(headerY));
    expect(rowY, lessThan(nextHeaderY), reason: '好友会话必须落在「好友私聊」段内（不串到客服段）');
  });

  testWidgets('④ 官方客服段只显示客服会话：不与打手/好友混装', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(convs))));
    await tester.pumpAndSettle();

    expect(find.text('联系客服'), findsOneWidget);

    // 客服行在「官方客服」标题之下；打手/好友行都在它上面（各归其位）
    final double csHeaderY = tester.getTopLeft(find.text(MessagesPage.sectionCs)).dy;
    final double csRowY = tester.getTopLeft(find.text('联系客服')).dy;
    expect(csRowY, greaterThan(csHeaderY), reason: '客服会话必须落在「官方客服」段内');
    expect(tester.getTopLeft(find.text('麻药')).dy, lessThan(csHeaderY));
    expect(tester.getTopLeft(find.text('雪山')).dy, lessThan(csHeaderY));
  });

  testWidgets('⑤ 空段整段不渲染：只有好友会话时，另两段的标题与空态占位都不出现', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(onlyFriends))));
    await tester.pumpAndSettle();

    expect(find.text(MessagesPage.sectionFriend), findsOneWidget);
    expect(find.text('雪山'), findsOneWidget);
    // 空段：标题不出现（负责人 2026-10-17：不许出现三个空标题）
    expect(find.text(MessagesPage.sectionWorker), findsNothing, reason: '没有打手会话 → 整段不渲染');
    expect(find.text(MessagesPage.sectionCs), findsNothing, reason: '没有客服会话 → 整段不渲染');
    // 也不许拿"空态占位"顶着
    expect(find.text('还没有打手会话'), findsNothing);
    expect(find.text('暂无客服会话'), findsNothing);
    expect(find.textContaining('暂无会话'), findsNothing, reason: '有会话时不该出现全页空态');
  });

  testWidgets('⑥ 三段全空：只给一次全页空态（AppEmptyState），不出现任何分区标题', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(emptyList))));
    await tester.pumpAndSettle();

    expect(find.byType(AppEmptyState), findsOneWidget, reason: '全页空态只给一次');
    expect(find.text('暂无会话'), findsOneWidget);
    expect(find.text(MessagesPage.sectionWorker), findsNothing);
    expect(find.text(MessagesPage.sectionFriend), findsNothing);
    expect(find.text(MessagesPage.sectionCs), findsNothing);
  });

  test('⑦ 三段顺序常量本身（服务端 0 改动：三段都取同一个 /user/conversations 的 type 字段）', () {
    expect(MessagesPage.sectionWorker, '联系打手');
    expect(MessagesPage.sectionFriend, '好友私聊');
    expect(MessagesPage.sectionCs, '官方客服');
  });

  testWidgets('⑧ 点击打手会话：进入一对一聊天页（无「完成咨询」按钮）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api(convs))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('麻药'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('完成咨询'), findsNothing);
  });
}

ApiClient _api(Map<String, dynamic> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, dynamic> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}), 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
