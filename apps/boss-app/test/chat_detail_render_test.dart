import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天详情页真实消息渲染（2026-09-25 排查真机"一坨灰框"）：
/// 真机点进任意会话聊天区灰块 —— 怀疑 flutter_chat_ui 的消息行（ChatMessageInternal）
/// 在历史消息存在时渲染异常。此前 messages_groups_tab_test 只验证了空历史（fixture 返回空列表），
/// 未覆盖到消息行渲染路径。
void main() {
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

  final history = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {
          'msgId': 'm1',
          'seq': 1,
          'senderType': 'user',
          'senderId': 'me',
          'msgType': 'text',
          'content': '你好，帮我打一局',
          'recalled': false,
          'createdAt': '2026-09-25T05:00:00.000Z',
          'senderNickname': '老板',
        },
        {
          'msgId': 'm2',
          'seq': 2,
          'senderType': 'user',
          'senderId': 'other',
          'msgType': 'text',
          'content': '没问题，马上安排',
          'recalled': false,
          'createdAt': '2026-09-25T05:01:00.000Z',
          'senderNickname': '客服',
        },
      ],
      'total': 2,
    },
  };
  final info = {
    'code': 0,
    'message': 'ok',
    'data': {'id': '75', 'type': 'friend', 'status': 'open'},
  };

  ApiClient api() {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter({
      '/user/conversations/75/messages': history,
      '/user/conversations/75/info': info,
    });
    return ApiClient(dio: dio);
  }

  testWidgets('聊天页：历史消息正常渲染（文字气泡+发送者昵称）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ChatDetailPage(conversationId: '75', title: '联系客服', csConversation: true, api: api())));
    await tester.pumpAndSettle();

    final err = tester.takeException();
    expect(err, isNull, reason: '渲染不得抛异常: $err');
    expect(find.text('你好，帮我打一局'), findsOneWidget);
    expect(find.text('没问题，马上安排'), findsOneWidget);
    // 排空 resync 延迟定时器（_setupRealtime 里 500ms 重同步）
    await tester.pump(const Duration(milliseconds: 700));
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);

  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final body = key.isEmpty
        ? jsonEncode({'code': 0, 'message': 'ok', 'data': {'list': <dynamic>[]}})
        : jsonEncode(raw[key]);
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
