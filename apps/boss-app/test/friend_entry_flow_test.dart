import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/friend_requests_page.dart';
import 'package:boss_app/pages/friend_search_page.dart';
import 'package:boss_app/pages/messages_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 入口关系（修 D6「申请列表不可达」+ D9「同一入口出现两次」）
///
/// 定案（A 套设计稿）：
/// - **加好友唯一入口** = 消息 › 好友私聊 › 右上「+」（全 App 只出现一次，见静态守卫）
/// - **消息页搜索框** = 搜已有会话（本地过滤，不跳好友搜索）
/// - **申请列表** = 「添加好友」页页头「申请」+ 未处理角标（真的打得开）
/// - 服务页顶部不再有搜索图标（本页没有服务端可搜的内容，不造假入口）
void main() {
  final conversations = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {
          'id': '76',
          'type': 'friend',
          'unread': 0,
          'lastSeq': 9,
          'status': 'open',
          'updatedAt': '2026-09-24T00:41:00Z',
          'peer': {'id': '9', 'nickname': '雪山'},
          'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-09-24T00:41:00.000Z'},
        },
        {
          'id': '77',
          'type': 'friend',
          'unread': 0,
          'lastSeq': 3,
          'status': 'open',
          'updatedAt': '2026-09-24T00:30:00Z',
          'peer': {'id': '11', 'nickname': '海风'},
          'lastMessage': {'content': '明天再约', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-09-24T00:30:00.000Z'},
        },
      ],
    },
  };
  final empty = {
    'code': 0,
    'message': 'ok',
    'data': {'list': [], 'total': 0},
  };
  final oneRequest = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {'id': '1', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪', 'message': '你好，我是 蒋雪'},
      ],
    },
  };

  setUp(() {
    ApiClient.cacheEnabled = false;
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  testWidgets('D9：消息页搜索框＝搜已有会话（本地过滤，不再跳好友搜索）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MessagesPage(api: _api({
        '/user/conversations': conversations,
        '/user/friends/requests/incoming': empty,
        '/user/notifications': empty,
      })),
    ));
    await tester.pumpAndSettle();

    // 两条会话都在
    expect(find.text('雪山'), findsOneWidget);
    expect(find.text('海风'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '海风');
    await tester.pumpAndSettle();

    expect(find.text('海风'), findsWidgets, reason: '命中：按昵称过滤');
    expect(find.text('雪山'), findsNothing, reason: '未命中的会话被过滤掉');
    expect(find.byType(FriendSearchPage), findsNothing, reason: 'D9：搜会话不再跳「添加好友」');

    // 搜的是内容也能命中（最后一条消息）
    await tester.enterText(find.byType(TextField), '打两把');
    await tester.pumpAndSettle();
    expect(find.text('雪山'), findsOneWidget);

    // 搜不到：给"没有匹配的会话"，不是"还没有好友会话"
    await tester.enterText(find.byType(TextField), '不存在的人');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有匹配的会话'), findsOneWidget);
  });

  testWidgets('D9：加好友唯一入口＝消息 › 好友私聊 › 右上「+」，点击进入添加好友页', (tester) async {
    final data = {
      '/user/conversations': conversations,
      '/user/friends/requests/incoming': oneRequest,
      '/user/notifications': empty,
      '/user/friends': empty,
    };
    await tester.pumpWidget(MaterialApp(key: const ValueKey('a'), home: MessagesPage(api: _api(data))));
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcon.plus), findsOneWidget, reason: '好友私聊分区右上「+」');
    expect(find.text('1'), findsOneWidget, reason: '未处理申请角标（真实数据 /user/friends/requests/incoming）');

    await tester.tap(find.byIcon(AppIcon.plus));
    await tester.pumpAndSettle();
    expect(find.byType(FriendSearchPage), findsOneWidget, reason: '「+」= 加好友入口');

    // 另起一棵树（避免 State 复用）：单页三分区（负责人 2026-10-17 定案）之后**不再有分区切换**，
    // 「+」按新口径**全页常驻**、且全页仍然只有一枚 → D9「同一入口只出现一次」照旧成立，
    // 顺带钉住"空段整段不渲染"（本夹具只有好友会话，另两段的标题不该出现）。
    await tester.pumpWidget(MaterialApp(key: const ValueKey('b'), home: MessagesPage(api: _api(data))));
    await tester.pumpAndSettle();
    expect(find.text('好友私聊'), findsOneWidget);
    expect(find.text('联系打手'), findsNothing, reason: '没有打手会话 → 该段整段不渲染');
    expect(find.text('官方客服'), findsNothing, reason: '没有客服会话 → 该段整段不渲染');
    expect(find.byIcon(AppIcon.plus), findsOneWidget, reason: '加好友入口全页只有一枚（不随分区增删）');
  });

  testWidgets('D9：服务页顶部不再有搜索入口（不造假搜索、不重复加好友入口）', (tester) async {
    final grouped = {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'gameId': '35',
          'gameName': '和平精英',
          'platformCount': 1,
          'divisions': [
            {
              'id': '1',
              'code': 'peace_mobile',
              'gameId': '35',
              'gameName': '和平精英',
              'platform': 'mobile',
              'platformLabel': '手游',
              'name': '和平精英 · 手游',
              'shortName': '和平精英',
              'onlineDesc': '平均 3 分钟内接单',
              'themeColor': '#16A34A',
              'sortOrder': 10,
              'onlineCount': 12,
            },
          ],
        },
      ],
    };
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/divisions/grouped': grouped,
        '/public/clubs': {
          'code': 0,
          'message': 'ok',
          'data': [
            {'id': '1', 'name': '祁连山电竞 · 和平精英分部', 'subTitle': '和平精英分部', 'divisionId': '1'},
          ],
        },
        '/public/site': {'code': 0, 'message': 'ok', 'data': {}},
        '/public/banners': empty,
      })),
    ));
    await tester.pumpAndSettle();

    // 顶部仍有 排行榜 / 公告（结构规则：只放底部没有的），但**没有**搜索图标
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('公告'), findsOneWidget);
    expect(find.byIcon(AppIcon.search), findsNothing, reason: '搜索图标已移除（本页无服务端可搜内容）');
    expect(find.byType(FriendSearchPage), findsNothing);
  });

  test('入口唯一性静态守卫：FriendSearchPage 只被「消息页」与「服务页搜索图标」引用', () {
    // 只数**代码**引用（注释里解释历史与理由时会出现类名，不算入口）
    String code(String src) => src
        .split('\n')
        .map((l) {
          final i = l.indexOf('//');
          return i >= 0 ? l.substring(0, i) : l;
        })
        .join('\n');

    final refs = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      if (path.endsWith('pages/friend_search_page.dart')) continue; // 页面自身
      if (code(f.readAsStringSync()).contains('FriendSearchPage')) refs.add(path);
    }
    // 【2026-10-17 方案 G】首页顶栏按负责人定案恢复了**右上角搜索图标**（20dp 墨蓝），
    // 点它进的就是"现有搜索入口"（本项目唯一的搜索页 = `FriendSearchPage`，没有商品搜索接口，
    // 后端 0 改动的约束下不新造）。因此白名单从 1 个文件变成 2 个：
    //   - messages_page.dart：加好友的**主**入口（搜索框右侧「+」，单页三分区后全页常驻）；
    //   - services_page.dart：首页搜索图标（同一页面，位置不同）。
    // 换句话说：仍然只有"一个搜索页"，只是有两个位置能进 —— 这是负责人的明确要求。
    expect(refs, ['lib/pages/messages_page.dart', 'lib/pages/services_page.dart'],
        reason: '搜索页只有 FriendSearchPage 一个；入口 = 消息页「+」+ 首页搜索图标（方案 G 定案）');
  });

  test('D6 静态守卫：申请列表页由「添加好友」页页头入口引用（入口不会被删掉）', () {
    final search = File('lib/pages/friend_search_page.dart').readAsStringSync();
    expect(search.contains('FriendRequestsPage'), isTrue, reason: '页头「申请」入口');
    expect(search.contains('_openRequests'), isTrue);
  });

  testWidgets('⑥⑦ 添加好友页的注释型小字已全删（改为"不存在"断言）；说明色 token 口径不变', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FriendSearchPage(api: _api({
        '/user/friends': {
          'code': 0,
          'message': 'ok',
          'data': {
            'list': [
              {'userId': '9', 'uid': 'lin_zhi_bai', 'nickname': '林知白'},
            ],
          },
        },
        '/user/friends/requests/incoming': empty,
      })),
    ));
    await tester.pumpAndSettle();

    // 负责人 2026-10-17 ⑦：这四句原来逐字断言"用 mutedText"，
    // 现在按新定案**整句删除** → 断言改为「确实不存在」（同一屏、同一语义位置，不降级）。
    expect(find.text('输入 2 个字开始搜；UID 要完整，如 he_yutong'), findsNothing,
        reason: '⑦：输入框下的解释/示例行已删');
    expect(find.text('要对方同意；同意后出现在 消息 › 好友私聊'), findsNothing, reason: '⑦：底部事实行小字已删');
    expect(find.text('对方用 ID 加你；24 小时内最多修改 3 次（在「我的」里改）'), findsNothing,
        reason: '⑦：底部事实行小字已删');
    expect(find.text('来自 消息 › 好友私聊'), findsNothing, reason: '⑦：「我的好友」标题右侧副标已删');
    // 功能保留：我的 ID + 复制 仍在（删的是解释，不是功能）
    expect(find.text('我的 ID'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    // 旧 token 保留、不删（图标/分隔继续用）
    expect(AppColors.textTertiary, isNot(AppColors.mutedText));
  });

  testWidgets('⑥ 申请列表页的说明文字同样用 mutedText', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FriendRequestsPage(api: _api({
        '/user/friends/requests/incoming': oneRequest,
        '/user/friends/requests/outgoing': empty,
      })),
    ));
    await tester.pumpAndSettle();

    final fact = tester.widget<Text>(find.text('直接互为好友，会话出现在 消息 › 好友私聊'));
    expect(fact.style?.color, AppColors.mutedText);
    final msg = tester.widget<Text>(find.text('你好，我是 蒋雪'));
    expect(msg.style?.color, AppColors.mutedText);
  });
}

// ---------------- 假服务器（与 friend_search_page_test 同一形状）----------------

ApiClient _api(Map<String, dynamic> fixtures) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(fixtures);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.fixtures);
  final Map<String, dynamic> fixtures;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = fixtures.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final body = matches.isEmpty ? {'code': 404, 'message': '未知路由 ${options.path}', 'data': null} : fixtures[matches.first];
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
