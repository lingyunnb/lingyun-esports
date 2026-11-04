import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/friend_requests_page.dart';
import 'package:boss_app/pages/friend_search_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「添加好友」即时搜索页（A 套设计稿 · 负责人 2026-10-05 审批）的行为与视觉契约
///
/// 覆盖设计阶段查清的缺陷（D1–D10）里**可断言**的那些：
/// - D1 输入 ≥2 字防抖 250ms **自动搜**，1 个字**不发请求**
/// - D2 结果行**无玻璃、无阴影**（整页断言找不到 `FishGlass*` / BoxShadow）
/// - D3 `friendStatus` 五态各有**唯一一个**动作（不会同时出现两个按钮）
/// - D5 搜不到 / 格式非法 / 已是好友…**各有独立文案**，且**原文来自服务端**
/// - D6 页头「申请」入口真的能打开申请列表（回归：此前唯一入口是未引用代码）
/// - D7 我的 ID 在底部事实行、可复制（2026-10-17 ⑦ 起该行**只剩** ID + 复制，解释性小字全删）
/// - D8 占位用真实 uid 形态（不再是 `U2741312533`）；示例 ID 示范**行**已删（⑦）
/// - D10 加载中**只动结果区**（输入框与结果区位置不变）
void main() {
  setUp(() {
    ApiClient.cacheEnabled = false; // 搜索/申请列表都是 GET，关缓存避免用例间串数据
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(
      accessToken: 'test-token',
      me: AuthMe.fromJson(const {'id': '9', 'username': 'b', 'uid': 'xiao_bei', 'nickname': '小北', 'role': 'user'}),
    );
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  /// [key] 必传且每个状态不同：同一个 `MaterialApp` 里重复 pumpWidget 同类型页面时，
  /// Flutter 会**复用 State**（旧 api/旧结果会被带进下一个用例）——用 key 强制重建。
  Widget host(_FakeServer server, {Key? key, bool withNavigator = false}) {
    final page = FriendSearchPage(key: key, api: _api(server));
    if (!withNavigator) return MaterialApp(home: page);
    return MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => page)),
              child: const Text('进入'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('D1：输入 1 个字不发请求；≥2 个字防抖 250ms 后只发一次请求', (tester) async {
    final server = _FakeServer()
      ..on('GET', '/user/friends/search', (_) => _ok(_user(uid: 'he_yutong', nickname: '何雨桐')));
    await tester.pumpWidget(host(server));
    await tester.pumpAndSettle();

    // 1 个字：只给提示，不打服务器
    await tester.enterText(find.byType(TextField), '何');
    await tester.pump(const Duration(milliseconds: 600));
    expect(server.searchCalls, isEmpty, reason: '1 个字不该发请求（后端门槛 2-20 位）');
    expect(find.textContaining('再输入 1 个字'), findsOneWidget);

    // 连打 3 次：250ms 防抖窗口内只应产生 1 次请求
    await tester.enterText(find.byType(TextField), '何雨');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.enterText(find.byType(TextField), '何雨桐');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.enterText(find.byType(TextField), '何雨桐a');
    await tester.pump(const Duration(milliseconds: 120));
    expect(server.searchCalls, isEmpty, reason: '防抖窗口内不得发请求');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(server.searchCalls, ['何雨桐a'], reason: '防抖 250ms 后只发最后一次的 1 个请求');
    expect(find.byKey(FriendSearchPage.resultRowKey), findsOneWidget);
    expect(find.descendant(of: find.byKey(FriendSearchPage.resultRowKey), matching: find.text('何雨桐')), findsOneWidget);
  });

  testWidgets('D2：结果行无玻璃、无阴影（整页不出现 FishGlass* / BoxShadow）', (tester) async {
    final server = _FakeServer()
      ..on('GET', '/user/friends/search', (_) => _ok(_user(uid: 'he_yutong', nickname: '何雨桐')));
    await tester.pumpWidget(host(server));
    await tester.enterText(find.byType(TextField), 'he_yutong');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.resultRowKey), findsOneWidget);
    for (final type in const ['FishGlassPage', 'FishGlassCard', 'GlassSurface', 'FishGlassBackdrop']) {
      expect(_countByTypeName(tester, type), 0, reason: '本页不得出现 $type');
    }
    expect(_countBoxShadows(tester), 0, reason: '列表用发丝线；阴影只给弹层（docs/21）');
    // 结果行子树内同样不能有任何阴影（D2 的原缺陷就是 GlassSurface 自带阴影）
    expect(_countBoxShadowsUnder(tester, find.byKey(FriendSearchPage.resultRowKey)), 0);
  });

  testWidgets('D3：friendStatus 五态各只有一个动作，语义互斥', (tester) async {
    Future<void> pumpStatus(String status) async {
      final server = _FakeServer()
        ..on('GET', '/user/friends/search', (_) => _ok(_user(uid: 'he_yutong', nickname: '何雨桐', friendStatus: status)));
      await tester.pumpWidget(host(server, key: ValueKey(status)));
      await tester.enterText(find.byType(TextField), 'he_yutong');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(FriendSearchPage.actionKey), findsOneWidget, reason: '$status 必须有且仅有一个动作');
    }

    await pumpStatus('none');
    expect(find.text('添加'), findsOneWidget);

    await pumpStatus('pending_out');
    expect(find.text('等待验证'), findsOneWidget);
    expect(find.text('添加'), findsNothing);

    await pumpStatus('pending_in');
    expect(find.text('同意'), findsOneWidget);
    expect(find.text('添加'), findsNothing);

    await pumpStatus('accepted');
    expect(find.text('已是好友'), findsOneWidget);
    expect(find.text('添加'), findsNothing);

    await pumpStatus('self');
    expect(find.text('这是我'), findsOneWidget);
    expect(find.text('添加'), findsNothing);
  });

  testWidgets('D5/D6：搜不到＝空态且标题取服务端原文（换掉服务端文案 → 界面跟着换）', (tester) async {
    final server = _FakeServer()
      ..on('GET', '/user/friends/search', (_) => _err(404, '未找到该用户'));
    await tester.pumpWidget(host(server, key: const ValueKey('a')));
    await tester.enterText(find.byType(TextField), 'qing_feng_88');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('未找到该用户'), findsOneWidget);
    // 空态给了下一步动作，不是一行字
    expect(find.text('清空重输'), findsOneWidget);
    expect(find.text('复制我的 ID'), findsWidgets);

    // 服务端换文案 → 页面跟着换（证明不是客户端硬编码）
    final server2 = _FakeServer()
      ..on('GET', '/user/friends/search', (_) => _err(404, '这个 ID 不在服务区'));
    await tester.pumpWidget(host(server2, key: const ValueKey('b')));
    await tester.enterText(find.byType(TextField), 'qing_feng_88');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('这个 ID 不在服务区'), findsOneWidget);
    expect(find.text('未找到该用户'), findsNothing);
  });

  testWidgets('D5：格式非法（400）走错误面板，文案＝服务端原文；加好友被挡回就地出错误条', (tester) async {
    // 搜索 400：错误面板（不是空态、不是整屏一行字）
    final bad = _FakeServer()
      ..on('GET', '/user/friends/search', (_) => _err(400, 'ID 格式非法（2-20 位中文/字母/数字/下划线）'));
    await tester.pumpWidget(host(bad, key: const ValueKey('bad')));
    await tester.enterText(find.byType(TextField), 'a b');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(FriendSearchPage.errorKey), findsOneWidget);
    expect(find.byKey(FriendSearchPage.emptyKey), findsNothing, reason: '格式错 ≠ 搜不到，两个状态必须分开');
    expect(find.text('ID 格式非法（2-20 位中文/字母/数字/下划线）'), findsOneWidget);

    // 加好友被挡回：搜索结果先是可加，点「添加」→ 服务端 400「你们已经是好友」
    var searched = 0;
    final server = _FakeServer()
      ..on('GET', '/user/friends/search', (_) {
        searched += 1;
        return _ok(_user(uid: 'he_yutong', nickname: '何雨桐', friendStatus: searched > 1 ? 'accepted' : 'none'));
      })
      ..on('POST', '/user/friends/requests', (_) => _err(400, '你们已经是好友'));
    await tester.pumpWidget(host(server, key: const ValueKey('post')));
    await tester.enterText(find.byType(TextField), 'he_yutong');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.postErrorKey), findsOneWidget);
    expect(find.text('这次没加成：你们已经是好友'), findsOneWidget, reason: '错误提示＝「这次没加成：」+ 服务端原文');
    expect(find.text('已是好友'), findsOneWidget, reason: '回源后行内状态跟着服务端变');
    expect(find.byType(SnackBar), findsNothing, reason: '就地显示，不弹系统 SnackBar');
    AppToast.dismiss(); // 收掉 toast 定时器（否则测试结束时报 pending timer）
    await tester.pumpAndSettle();
  });

  testWidgets('D6：页头「申请」入口存在、带未处理角标，且能打开申请列表', (tester) async {
    final server = _FakeServer()
      ..on('GET', '/user/friends/requests/incoming', (_) => _ok(_list([
            {'id': '1', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪', 'message': '你好，我是 蒋雪'},
            {'id': '2', 'userId': '32', 'uid': 'mo_li', 'nickname': '莫离'},
          ])))
      ..on('GET', '/user/friends', (_) => _ok(_list(const [])))
      ..on('GET', '/user/friends/requests/outgoing', (_) => _ok(_list(const [])));

    await tester.pumpWidget(host(server, withNavigator: true));
    await tester.tap(find.text('进入'));
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.requestsEntryKey), findsOneWidget);
    expect(find.text('申请'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: '未处理数角标');

    await tester.tap(find.byKey(FriendSearchPage.requestsEntryKey));
    await tester.pumpAndSettle();

    expect(find.byType(FriendRequestsPage), findsOneWidget, reason: 'D6 回归：申请列表真的打得开');
    expect(find.text('新的朋友'), findsOneWidget);
    expect(find.text('蒋雪'), findsOneWidget);
    expect(find.text('同意'), findsNWidgets(2), reason: '两条待处理申请各一个「同意」');
    expect(find.textContaining('暂无待处理的申请'), findsNothing);
  });

  testWidgets('D7/D8：我的 ID 收在底部事实行（**只剩 ID + 复制**，解释性小字已删）；占位用真实格式', (tester) async {
    final server = _FakeServer()..on('GET', '/user/friends', (_) => _ok(_list(const [])));
    await tester.pumpWidget(host(server));
    await tester.pumpAndSettle();

    // 功能保留：ID + 复制按钮（负责人 2026-10-17：「我的 ID + 复制」是功能，留着）
    expect(find.text('我的 ID'), findsOneWidget);
    expect(find.text('xiao_bei'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    // 解释性小字全删（同一批里唯一还留得住的是功能行本身）
    expect(find.textContaining('24 小时内最多修改 3 次'), findsNothing, reason: '2026-10-17 ⑦：注释型小字必须已删');
    expect(find.textContaining('要对方同意'), findsNothing, reason: '2026-10-17 ⑦：注释型小字必须已删');
    expect(find.textContaining('搜昵称'), findsNothing, reason: '2026-10-17 ⑦：注释型小字必须已删');
    expect(find.textContaining('热门搜索'), findsNothing, reason: '2026-10-17 ⑦：「热门搜索」整块已删');
    expect(find.textContaining('不是「加了好友才能聊天'), findsNothing, reason: '2026-10-17 ⑦：整段已删');
    // D8：不得再出现界面上不存在的假 ID 格式；示例 ID 的**示范行**也已删（不再有 he_yutong 那行）
    expect(find.textContaining('U2741312533'), findsNothing, reason: 'D8：不得再出现界面上不存在的假 ID 格式');
    expect(find.text('输入好友 ID 或昵称（支持中文）'), findsOneWidget);
    expect(find.textContaining('he_yutong'), findsNothing, reason: '2026-10-17 ⑦：示例行「如 he_yutong」已随小字删除');
  });

  testWidgets('D10：搜索中只动结果区——输入框与结果区位置前后一致', (tester) async {
    final server = _FakeServer()
      ..searchDelay = const Duration(milliseconds: 400)
      ..on('GET', '/user/friends/search', (_) => _ok(_user(uid: 'he_yutong', nickname: '何雨桐')));
    await tester.pumpWidget(host(server));
    await tester.enterText(find.byType(TextField), 'he_yutong');
    final fieldBefore = tester.getTopLeft(find.byKey(FriendSearchPage.fieldKey));

    await tester.pump(const Duration(milliseconds: 260)); // 请求已发出、还没回来
    expect(find.byKey(FriendSearchPage.loadingKey), findsOneWidget, reason: '加载态＝结果区面板，不是整屏转圈');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(FriendSearchPage.fieldKey)), fieldBefore, reason: '输入框位置不得跳动');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(FriendSearchPage.fieldKey)), fieldBefore);
    expect(find.byKey(FriendSearchPage.resultRowKey), findsOneWidget);
  });

  testWidgets('D6 补充：对方已申请你 → 点「同意」走 accept 接口（拿申请 id，不靠再申请一次）', (tester) async {
    final server = _FakeServer()
      ..on('GET', '/user/friends/requests/incoming', (_) => _ok(_list([
            {'id': '77', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪'},
          ])))
      ..on('GET', '/user/friends', (_) => _ok(_list(const [])))
      ..on('GET', '/user/friends/search', (_) => _ok(_user(uid: 'jiang_xue', nickname: '蒋雪', friendStatus: 'pending_in')))
      ..on('POST', '/user/friends/requests/77/accept', (_) => _ok(const {'ok': true}));

    await tester.pumpWidget(host(server));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'jiang_xue');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /user/friends/requests/77/accept'));
    AppToast.dismiss();
    await tester.pumpAndSettle();
  });
}

// ---------------- 假服务器 ----------------

class _FakeServer {
  final List<String> calls = [];
  final List<String> searchCalls = [];
  final Map<String, Map<String, dynamic> Function(RequestOptions)> _routes = {};
  Duration searchDelay = Duration.zero;

  void on(String method, String path, Map<String, dynamic> Function(RequestOptions) handler) {
    _routes['$method $path'] = handler;
  }

  Map<String, dynamic> Function(RequestOptions)? _match(String method, String path) {
    final keys = _routes.keys.where((k) => k.startsWith('$method ') && path.startsWith(k.substring(method.length + 1))).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return keys.isEmpty ? null : _routes[keys.first];
  }
}

Map<String, dynamic> _ok(dynamic data) => {'code': 0, 'message': 'ok', 'data': data};
Map<String, dynamic> _err(int code, String message) => {'code': code, 'message': message, 'data': null};
Map<String, dynamic> _list(List<Map<String, dynamic>> items) => {'list': items, 'total': items.length};
Map<String, dynamic> _user({required String uid, required String nickname, String friendStatus = 'none'}) => {
      'userId': '31',
      'uid': uid,
      'nickname': nickname,
      'avatarMediaId': null,
      'level': 2,
      'levelName': '进阶会员',
      'myUid': 'xiao_bei',
      'friendStatus': friendStatus,
    };

ApiClient _api(_FakeServer server) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(server);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.server);
  final _FakeServer server;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    server.calls.add(key);
    if (key.endsWith('/user/friends/search')) {
      server.searchCalls.add('${options.queryParameters['uid'] ?? ''}');
      if (server.searchDelay > Duration.zero) await Future<void>.delayed(server.searchDelay);
    }
    final handler = server._match(options.method, options.path);
    if (handler == null) {
      return _body({'code': 404, 'message': '未知路由 $key', 'data': null}, 404);
    }
    final resp = handler(options);
    final code = (resp['code'] as num?)?.toInt() ?? 0;
    return _body(resp, code >= 400 || code < 0 ? code : 200);
  }

  ResponseBody _body(Map<String, dynamic> json, int status) => ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// 按运行时类型名数一数（避免为断言而 import 私有 widget 文件）
int _countByTypeName(WidgetTester tester, String typeName) {
  var n = 0;
  for (final e in tester.allElements) {
    if (e.widget.runtimeType.toString() == typeName) n += 1;
  }
  return n;
}

/// 数 BoxShadow：任意 BoxDecoration 上带阴影都算（本页必须为 0）
int _countBoxShadows(WidgetTester tester) {
  var n = 0;
  for (final e in tester.allElements) {
    final w = e.widget;
    Decoration? d;
    if (w is Container) {
      d = w.decoration;
    } else if (w is DecoratedBox) {
      d = w.decoration;
    }
    if (d is BoxDecoration && (d.boxShadow?.isNotEmpty ?? false)) n += 1;
  }
  return n;
}

/// 只数某个子树内的阴影（结果行自身的"无阴影"断言）
int _countBoxShadowsUnder(WidgetTester tester, Finder finder) {
  var n = 0;
  void visit(Element e) {
    final w = e.widget;
    Decoration? d;
    if (w is Container) {
      d = w.decoration;
    } else if (w is DecoratedBox) {
      d = w.decoration;
    }
    if (d is BoxDecoration && (d.boxShadow?.isNotEmpty ?? false)) n += 1;
    e.visitChildren(visit);
  }

  for (final root in finder.evaluate()) {
    root.visitChildren(visit);
  }
  return n;
}
