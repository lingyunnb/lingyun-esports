import 'dart:convert';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天模型回归（打手直聊 + 实时同步修复 2026-09-24）：
/// ACK 替换 msgId/seq（撤回锚点）、打手直聊会话解析、消息去重锚点
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  test('ChatMessageModel：ACK 用服务端 msgId/seq 替换本地占位值（修复撤回失效）', () {
    final m = ChatMessageModel(
      msgId: 'local-abc',
      seq: 5,
      senderType: 'user',
      senderId: '147',
      msgType: 'text',
      content: '你好',
      recalled: false,
      createdAt: DateTime(2026, 9, 24),
      clientMsgId: 'abc',
      pending: true,
    );
    final acked = m.copyWith(msgId: 'real-uuid', seq: 42, pending: false, clearClientMsgId: true);
    expect(acked.msgId, 'real-uuid');
    expect(acked.isLocal, isFalse);
    expect(acked.seq, 42);
    expect(acked.clientMsgId, isNull); // 清掉 clientMsgId 防止与回播 msg:new 的锚点混淆
    expect(acked.pending, isFalse);
  });

  test('ChatMessageModel.fromJson：senderNickname 解析（打手直聊昵称）', () {
    final m = ChatMessageModel.fromJson(jsonDecode(
        '{"msgId":"u1","seq":3,"senderType":"user","senderId":"147","senderNickname":"演示老板","msgType":"text","content":"老板消息1","recalled":false,"createdAt":"2026-09-24T00:34:00.080Z"}') as Map<String, dynamic>);
    expect(m.senderNickname, '演示老板');
    expect(m.isLocal, isFalse);
  });

  test('ConversationSummaryModel：打手直聊解析（type=worker 一对一）', () {
    // 群组已下掉：一对一会话不带群名/订单号，靠对端资料展示（此处仅断言类型与未读/预览）
    final c = ConversationSummaryModel.fromJson(jsonDecode(
        '{"id":"75","type":"worker","unread":2,"lastSeq":3,"status":"open","peer":{"id":"31","nickname":"麻药"},"lastMessage":{"content":"老板消息1","msgType":"text","recalled":false,"createdAt":"2026-09-24T00:34:00.080Z"},"updatedAt":"2026-09-24T00:34:00.080Z"}') as Map<String, dynamic>);
    expect(c.isWorkerDirect, isTrue);
    expect(c.unread, 2);
    expect(c.lastContent, '老板消息1');
  });

  test('ChatConversationModel：打手直聊 type/isWorkerDirect', () {
    final c = ChatConversationModel.fromJson(const {'id': '75', 'unread': 1, 'lastSeq': 3, 'type': 'worker'});
    expect(c.isWorkerDirect, isTrue);
  });
}
