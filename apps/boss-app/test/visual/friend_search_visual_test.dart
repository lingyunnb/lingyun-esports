import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/friend_requests_page.dart';
import 'package:boss_app/pages/friend_search_page.dart';
import 'package:boss_app/pages/messages_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「添加好友」A 套设计稿落地的 5 张出图（像素证据，390 × 844 @2x）：
/// ① `build/friend_search_default.png` —— 默认（自动聚焦 + 我的好友 + 页头申请角标）
/// ② `build/friend_search_result.png`  —— 有结果（头像 + 昵称 + 中文 ID + 唯一主操作「添加」）
/// ③ `build/friend_search_empty.png`   —— 搜不到（404 空态，标题取服务端原文）
/// ④ `build/friend_search_error.png`   —— 错误态（加好友被挡回：就地错误条 + 最新状态）
/// ⑤ `build/friend_requests_list.png`  —— 申请列表（收到的 N / 我发出的 N）
/// ⑥ `build/messages_add_friend_entry.png` —— 消息页：搜索框＝搜已有会话 + 「+」＝加好友唯一入口（D9）
///
/// ## 三个既有坑（照既有出图测试的写法绕开）
/// 1. **中文字形**：`flutter test` 自带字体没有 CJK 字形（会渲染成豆腐块）→ `FontLoader` 挂系统字体。
/// 2. **图标字形**：测试环境也不加载 Material 图标字体（不加载就是一个个空方框）→ 一并挂上
///    `<FLUTTER_ROOT>/bin/cache/artifacts/material_fonts/materialicons-regular.otf`。
/// 3. **`ThemeData(fontFamily:)` 改不动 `textTheme`**（页面里的 `Text` 走 DefaultTextStyle ←
///    textTheme.bodyMedium）→ 必须 `textTheme.apply(fontFamily: ...)` 再套一遍。
///
/// 另外：同一族**按顺序注册多份字体**（引擎在缺字时依次回退）——simhei 缺 `›`(U+203A)
/// 这类标点，只挂它出图里就是豆腐块。
void main() {
  const cjkFamily = 'FriendShotCJK';
  const monoFamily = 'monospace';
  const shotKey = Key('shot-page');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      r'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      r'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc', // 标点覆盖最广（`›` U+203A 只有它有）
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final bytes = ByteData.sublistView(f.readAsBytesSync());
      for (final family in const [cjkFamily, monoFamily]) {
        final loader = FontLoader(family)..addFont(Future<ByteData>.value(bytes));
        await loader.load();
      }
    }
  });

  setUp(() {
    ApiClient.cacheEnabled = false;
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(
      accessToken: 'shot-token',
      me: AuthMe.fromJson(const {'id': '9', 'username': 'b', 'uid': 'xiao_bei', 'nickname': '小北', 'role': 'user'}),
    );
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  /// 出图（必须放进 `tester.runAsync`：`toImage()` 要等光栅线程回一帧，假时钟下永远不返回）
  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// 出图要的是「push 进来的页面」（设计稿页头有返回箭头）→ 先落一个空壳再 push
  Widget frame(Widget page) => RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: () {
            final base = ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: AppColors.bgPage);
            return base.copyWith(textTheme: base.textTheme.apply(fontFamily: cjkFamily));
          }(),
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
        ),
      );

  Future<void> enter(WidgetTester tester) async {
    await tester.tap(find.text('进入'));
    await tester.pumpAndSettle();
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('出图 ① 默认（自动聚焦 + 我的好友 + 页头申请角标）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(FriendSearchPage(
      api: _api({
        '/user/friends/requests/incoming': _list([
          {'id': '1', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪（夜场）'},
          {'id': '2', 'userId': '32', 'uid': 'mo_li', 'nickname': '莫离'},
        ]),
        '/user/friends': _list([
          {'userId': '41', 'uid': 'LZB_2049', 'nickname': '林知白'},
          {'userId': '42', 'uid': '徐一鸣', 'nickname': '徐一鸣'},
        ]),
      }),
    )));
    await enter(tester);

    expect(find.text('2'), findsOneWidget, reason: '未处理申请角标');
    expect(find.text('林知白'), findsOneWidget);
    // 聚焦：**方案 G（2026-10-17）**把"主色 10% 外圈环"换成**主色 1.5px 描边**；
    // 外圈 3dp 留白仍恒占位（D10"位置不跳"的前提就是它）
    final ring = tester.widget<Container>(find.byKey(FriendSearchPage.fieldKey));
    expect(ring.padding, const EdgeInsets.all(3), reason: '外圈恒占位 = D10「位置不跳」的前提');
    final box = tester
        .widgetList<Container>(find.descendant(
          of: find.byKey(FriendSearchPage.fieldKey),
          matching: find.byType(Container),
        ))
        .firstWhere((c) => (c.decoration as BoxDecoration?)?.border != null);
    final border = (box.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color, AppColors.primary, reason: '聚焦态 = 主色描边（方案 G）');
    expect(border.top.width, 1.5, reason: '方案 G：聚焦描边 1.5px（未聚焦 1px）');
    expect(tester.takeException(), isNull);
    await shoot(tester, 'friend_search_default.png');
  });

  testWidgets('出图 ② 有结果（头像 + 昵称 + 中文 ID + 唯一主操作「添加」）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(FriendSearchPage(
      api: _api({
        '/user/friends/requests/incoming': _list(const []),
        '/user/friends': _list(const []),
        '/user/friends/search': _ok({
          'userId': '31',
          'uid': 'he_yutong',
          'nickname': '何雨桐',
          'level': 2,
          'levelName': '进阶会员',
          'myUid': 'xiao_bei',
          'friendStatus': 'none',
        }),
      }),
    )));
    await enter(tester);
    await tester.enterText(find.byType(TextField), 'he_yutong');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.resultRowKey), findsOneWidget);
    expect(find.text('添加'), findsOneWidget, reason: '一条结果只有一个主操作');
    expect(find.textContaining('找到 1 个用户'), findsOneWidget);
    await shoot(tester, 'friend_search_result.png');
  });

  testWidgets('出图 ③ 搜不到（404 空态：标题＝服务端原文 + 下一步动作）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(FriendSearchPage(
      api: _api({
        '/user/friends/requests/incoming': _list(const []),
        '/user/friends': _list(const []),
        '/user/friends/search': {'code': 404, 'message': '未找到该用户', 'data': null},
      }),
    )));
    await enter(tester);
    await tester.enterText(find.byType(TextField), 'qing_feng_88');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.emptyKey), findsOneWidget);
    expect(find.text('未找到该用户'), findsOneWidget);
    await shoot(tester, 'friend_search_empty.png');
  });

  testWidgets('出图 ④ 错误态（加好友被挡回：就地错误条 + 行内状态回源）', (tester) async {
    phone(tester);
    var searched = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _ShotAdapter((o) {
      if (o.path.startsWith('/user/friends/search')) {
        searched += 1;
        return _ok({
          'userId': '31',
          'uid': 'he_yutong',
          'nickname': '何雨桐',
          'myUid': 'xiao_bei',
          'friendStatus': searched > 1 ? 'accepted' : 'none',
        });
      }
      if (o.path.startsWith('/user/friends/requests') && o.method == 'POST') {
        return {'code': 400, 'message': '你们已经是好友', 'data': null};
      }
      return _list(const []);
    });

    await tester.pumpWidget(frame(FriendSearchPage(api: ApiClient(dio: dio))));
    await enter(tester);
    await tester.enterText(find.byType(TextField), 'he_yutong');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 错误条是第一现场，出图时把 2s 的 toast 收掉（否则浮层盖住错误条）
    AppToast.dismiss();
    await tester.pumpAndSettle();

    expect(find.byKey(FriendSearchPage.postErrorKey), findsOneWidget);
    expect(find.text('这次没加成：你们已经是好友'), findsOneWidget);
    expect(find.text('已是好友'), findsOneWidget);
    await shoot(tester, 'friend_search_error.png');
  });

  testWidgets('出图 ⑤ 申请列表（收到的 2 / 我发出的 1）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(FriendRequestsPage(
      api: _api({
        '/user/friends/requests/incoming': _list([
          {'id': '1', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪（夜场）', 'message': '你好，我是 蒋雪（夜场）'},
          {'id': '2', 'userId': '32', 'uid': 'mo_li', 'nickname': '莫离', 'message': '请求添加你为好友'},
        ]),
        '/user/friends/requests/outgoing': _list([
          {'id': '3', 'userId': '33', 'uid': 'NC_1024', 'nickname': '宁川'},
        ]),
      }),
    )));
    await enter(tester);

    expect(find.text('新的朋友'), findsOneWidget);
    expect(find.text('蒋雪（夜场）'), findsOneWidget);
    expect(find.text('等待验证'), findsOneWidget);
    expect(find.text('同意'), findsNWidgets(2));
    await shoot(tester, 'friend_requests_list.png');
  });

  testWidgets('出图 ⑥ 消息页入口分工（搜索框＝搜会话，「+」＝加好友唯一入口）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(MessagesPage(
      api: _api({
        '/user/conversations': _ok({
          'list': [
            {
              'id': '76',
              'type': 'friend',
              'unread': 1,
              'lastSeq': 9,
              'status': 'open',
              'updatedAt': '2026-10-05T00:41:00Z',
              'peer': {'id': '9', 'nickname': '雪山'},
              'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-05T00:41:00.000Z'},
            },
            {
              'id': '77',
              'type': 'friend',
              'unread': 0,
              'lastSeq': 3,
              'status': 'open',
              'updatedAt': '2026-10-05T00:20:00Z',
              'peer': {'id': '11', 'nickname': '海风'},
              'lastMessage': {'content': '明天再约', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-05T00:20:00.000Z'},
            },
          ],
        }),
        '/user/friends/requests/incoming': _list([
          {'id': '1', 'userId': '31', 'uid': 'jiang_xue', 'nickname': '蒋雪（夜场）', 'message': '你好，我是 蒋雪（夜场）'},
        ]),
        '/user/notifications': _list(const []),
      }),
    )));
    await enter(tester);

    expect(find.byIcon(AppIcon.plus), findsOneWidget, reason: '「+」＝加好友唯一入口');
    expect(find.text('1'), findsNWidgets(2), reason: '「+」角标 1 + 未读会话角标 1');
    expect(find.text('搜索已有会话'), findsOneWidget, reason: '搜索框语义＝搜已有会话（D9）');
    expect(find.byIcon(AppIcon.search), findsOneWidget);
    await shoot(tester, 'messages_add_friend_entry.png');
  });
}

Map<String, dynamic> _ok(dynamic data) => {'code': 0, 'message': 'ok', 'data': data};
Map<String, dynamic> _list(List<Map<String, dynamic>> items) => _ok({'list': items, 'total': items.length});

ApiClient _api(Map<String, dynamic> fixtures) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _ShotAdapter((o) {
    final keys = fixtures.keys.where(o.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    return keys.isEmpty ? {'code': 404, 'message': '未知路由 ${o.path}', 'data': null} : fixtures[keys.first];
  });
  return ApiClient(dio: dio);
}

class _ShotAdapter implements HttpClientAdapter {
  _ShotAdapter(this.handler);
  final Map<String, dynamic> Function(RequestOptions) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = handler(options);
    final code = (body['code'] as num?)?.toInt() ?? 0;
    return ResponseBody.fromString(
      jsonEncode(body),
      code >= 400 || code < 0 ? code : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
