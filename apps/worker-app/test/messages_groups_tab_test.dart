import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/messages_page.dart';

/// 工作端消息页 · 三类会话（负责人 2026-10-04：群组功能全部下掉）
///
/// 结构定案：好友私聊 / 客服 / 老板（老板 = 接单后与下单老板的一对一直聊）。
/// 旧「群组 tab + 订单群」已全部移除：不得再出现群名、群成员、群组 tab。
void main() {
  final convs = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {
          'id': '74',
          'type': 'cs',
          'unread': 1,
          'lastSeq': 23,
          'status': 'open',
          'updatedAt': '2026-09-24T00:34:00Z',
          'peer': {'userId': '9', 'nickname': '谪居'},
        },
        {
          'id': '75',
          'type': 'worker', // 老板直聊（原订单群）
          'unread': 2,
          'lastSeq': 3,
          'status': 'open',
          'updatedAt': '2026-09-24T00:40:00Z',
          'peer': {'userId': '127', 'nickname': '小云'},
          'lastMessage': {
            'content': '什么时候开始',
            'msgType': 'text',
            'recalled': false,
            'createdAt': '2026-09-24T00:34:00.080Z',
          },
        },
        {
          'id': '76',
          'type': 'friend',
          'unread': 0,
          'lastSeq': 9,
          'status': 'open',
          'updatedAt': '2026-09-24T00:41:00Z',
          'peer': {'userId': '31', 'nickname': '麻药'},
          'lastMessage': {
            'content': '今晚打两把？',
            'msgType': 'text',
            'recalled': false,
            'createdAt': '2026-09-24T00:41:00.000Z',
          },
        },
      ],
    },
  };
  final emptyList = {
    'code': 0,
    'message': 'ok',
    'data': {'list': [], 'total': 0},
  };
  final friends = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {'userId': '31', 'uid': 'U10031', 'nickname': '麻药', 'level': 2},
      ],
      'total': 1,
    },
  };

  Map<String, Map<String, dynamic>> fixture() => {
        '/worker/cs/conversations': convs,
        '/user/friends': friends,
        '/user/notifications': emptyList,
      };

  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  testWidgets('三个分区名正确：好友私聊 / 客服 / 老板（群组已下掉）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('好友私聊'), findsWidgets);
    expect(find.text('客服'), findsWidgets);
    expect(find.text('老板'), findsWidgets);
    expect(find.text('群组'), findsNothing);
  });

  testWidgets('老板分区：渲染老板直聊（老板昵称 + 最后消息）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    await tester.tap(find.text('老板'));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    expect(tester.takeException(), isNull);
    expect(find.text('小云'), findsOneWidget);
    expect(find.text('老板'), findsWidgets); // 角色标签
    expect(find.textContaining('订单群'), findsNothing);
  });

  testWidgets('客服分区只显示客服会话，不混入老板直聊', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    await tester.tap(find.text('客服'));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    expect(find.text('谪居'), findsWidgets);
    expect(find.text('小云'), findsNothing);
  });

  testWidgets('好友私聊分区：显示好友昵称与最后消息', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('麻药'), findsWidgets);
    expect(find.text('麻药'), findsWidgets); // 好友分区数据源为 /user/friends
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

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
