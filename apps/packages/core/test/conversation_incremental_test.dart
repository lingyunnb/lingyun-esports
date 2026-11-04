/// **会话列表增量更新**的纯逻辑钉死（2026-10-15 聊天实时接收优化）
///
/// 缺陷现场：消息页对每条 `msg:new` / `unread:update` 都做"全量重拉会话列表"
/// （`_realtime.on('msg:new', (_) => _refresh())`）→ 对方发一句话，客户端打 1–2 次
/// 全量列表请求、列表被重建 1–2 次（卡顿、闪烁、滚动跳位、输入框抖动）。
///
/// 本文件钉死替代方案的四条不变量：
///  ① `msg:new` 的 payload **够用** → 一条**新**摘要该更新哪些字段（内容/类型/撤回/时间/seq）；
///  ② **list 里没有这条会话 → 返回 null**（唯一需要回源的场景：新会话）；
///  ③ 排序与服务端同源（`ORDER BY updated_at DESC` → 有新消息的会话排到最前）；
///  ④ 未读**只认服务端权威值**，客户端不自增；清零时保持在原位。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一条会话摘要（形状与服务端 `listUserConversations` 一致）
ConversationSummaryModel conv({
  required String id,
  String type = 'friend',
  int unread = 0,
  int lastSeq = 0,
  String lastContent = '',
  String lastMsgType = 'text',
  bool lastRecalled = false,
  String? lastAt = '2026-10-15T10:00:00.000Z',
}) =>
    ConversationSummaryModel.fromJson(<String, dynamic>{
      'id': id,
      'type': type,
      'unread': unread,
      'lastSeq': lastSeq,
      'lastMessage': <String, dynamic>{
        'content': lastContent,
        'msgType': lastMsgType,
        'recalled': lastRecalled,
        'createdAt': lastAt,
      },
    });

/// `msg:new` 的 payload（服务端 `chat.service.ts#messageView` 的原字段集）
Map<String, dynamic> msgEvent({
  String conversationId = 'c1',
  String msgId = 'm1',
  int seq = 1,
  String senderType = 'worker',
  String msgType = 'text',
  String content = '你好',
  bool recalled = false,
  String createdAt = '2026-10-15T10:01:00.000Z',
}) =>
    <String, dynamic>{
      'msgId': msgId,
      'seq': seq,
      'conversationId': conversationId,
      'senderType': senderType,
      'senderId': 'w1',
      'senderNickname': '打手甲',
      'msgType': msgType,
      'content': content,
      'recalled': recalled,
      'createdAt': createdAt,
    };

void main() {
  group('① msg:new 增量合并', () {
    test('命中已知会话 → 只改这一行的摘要，且**移到首位**（与服务端 updated_at DESC 同序）', () {
      final List<ConversationSummaryModel> before = <ConversationSummaryModel>[
        conv(id: 'c1', lastContent: '老内容', lastSeq: 3),
        conv(id: 'c2', lastContent: '别人的'),
      ];

      final List<ConversationSummaryModel>? after =
          ConversationIncremental.applyMessageEvent(before, msgEvent(conversationId: 'c1', seq: 4, content: '新内容'));

      expect(after, isNotNull, reason: '已知会话必须就地更新，不需要回源');
      expect(after!.length, 2, reason: '增量更新不增不减：不许出现重复行');
      expect(after.first.id, 'c1', reason: '有新消息的会话排到最前（与服务端 ORDER BY updated_at DESC 一致）');
      expect(after.first.lastContent, '新内容');
      expect(after.first.lastAt?.toUtc().toIso8601String(), '2026-10-15T10:01:00.000Z');
      expect(after.first.lastSeq, 4);
      expect(after[1].id, 'c2');
      expect(after[1].lastContent, '别人的', reason: '同一批里的其它会话一个字段都不许动');
    });

    test('图片/撤回沿用服务端字段（页面侧才能显示「[图片]」「[消息已撤回]」）', () {
      final List<ConversationSummaryModel>? img = ConversationIncremental.applyMessageEvent(
        <ConversationSummaryModel>[conv(id: 'c1')],
        msgEvent(conversationId: 'c1', msgType: 'image', content: ''),
      );
      expect(img!.first.lastMsgType, 'image');

      final List<ConversationSummaryModel>? recalled = ConversationIncremental.applyMessageEvent(
        <ConversationSummaryModel>[conv(id: 'c1')],
        msgEvent(conversationId: 'c1', recalled: true),
      );
      expect(recalled!.first.lastRecalled, isTrue);
    });

    test('乱序到达的旧事件不许把 seq 位点回退（位点算错 → 已读回执错）', () {
      final List<ConversationSummaryModel>? after = ConversationIncremental.applyMessageEvent(
        <ConversationSummaryModel>[conv(id: 'c1', lastSeq: 9)],
        msgEvent(conversationId: 'c1', seq: 4),
      );
      expect(after!.first.lastSeq, 9);
    });

    test('列表里没有这条会话 → 返回 null（**唯一**需要回源补摘要的场景）', () {
      expect(
        ConversationIncremental.applyMessageEvent(<ConversationSummaryModel>[conv(id: 'c1')], msgEvent(conversationId: 'brand-new')),
        isNull,
        reason: '新会话（如打手刚抢到单）本地没有摘要，必须让调用方回源；但不能靠它去猜',
      );
    });

    test('坏 payload（无 conversationId / 非 Map / 空）→ null，绝不抛', () {
      final List<ConversationSummaryModel> list = <ConversationSummaryModel>[conv(id: 'c1')];
      expect(ConversationIncremental.applyMessageEvent(list, null), isNull);
      expect(ConversationIncremental.applyMessageEvent(list, 'not json'), isNull);
      expect(ConversationIncremental.applyMessageEvent(list, <String, dynamic>{'seq': 3}), isNull);
      expect(ConversationIncremental.applyMessageEvent(list, 42), isNull);
    });

    test('JSON 字符串形态的 payload 同样认（自建 relay / 回放）', () {
      final List<ConversationSummaryModel>? after = ConversationIncremental.applyMessageEvent(
        <ConversationSummaryModel>[conv(id: 'c1')],
        '{"conversationId":"c1","seq":5,"msgType":"text","content":"字符串来的"}',
      );
      expect(after!.first.lastContent, '字符串来的');
      expect(after.first.lastSeq, 5);
    });
  });

  group('② unread:update 增量合并（只认服务端权威值）', () {
    test('未读变化 → 覆盖为服务端给的值并排到首位', () {
      final List<ConversationSummaryModel>? after = ConversationIncremental.applyUnreadEvent(
        <ConversationSummaryModel>[conv(id: 'c1'), conv(id: 'c2')],
        <String, dynamic>{'conversationId': 'c2', 'unread': 7},
      );
      expect(after!.first.id, 'c2');
      expect(after.first.unread, 7);
      expect(after[1].unread, 0, reason: '其它会话未读不许被顺带改动');
    });

    test('清零时**保持在原位**（读了消息不该让会话跳位）', () {
      final List<ConversationSummaryModel>? after = ConversationIncremental.applyUnreadEvent(
        <ConversationSummaryModel>[conv(id: 'c1'), conv(id: 'c2', unread: 5)],
        <String, dynamic>{'conversationId': 'c2', 'unread': 0},
      );
      expect(after!.map((ConversationSummaryModel c) => c.id).toList(), <String>['c1', 'c2']);
      expect(after[1].unread, 0);
    });

    test('未读已经是该值 → 原样返回（不产生无意义的重建）', () {
      final List<ConversationSummaryModel> list = <ConversationSummaryModel>[conv(id: 'c1', unread: 3)];
      expect(
        identical(ConversationIncremental.applyUnreadEvent(list, <String, dynamic>{'conversationId': 'c1', 'unread': 3}), list),
        isTrue,
      );
    });

    test('未读数非数字 → null（不猜、不回源）', () {
      expect(
        ConversationIncremental.applyUnreadEvent(
          <ConversationSummaryModel>[conv(id: 'c1')],
          <String, dynamic>{'conversationId': 'c1', 'unread': null},
        ),
        isNull,
      );
      // 数字字符串（服务端 mysql2 可能给字符串）照认
      expect(
        ConversationIncremental.applyUnreadEvent(
          <ConversationSummaryModel>[conv(id: 'c1')],
          <String, dynamic>{'conversationId': 'c1', 'unread': '4'},
        )!
            .first
            .unread,
        4,
      );
    });
  });

  group('③ 会话被删（conv:removed）', () {
    test('按 id 本地移除；空 id 原样返回', () {
      final List<ConversationSummaryModel> list = <ConversationSummaryModel>[conv(id: 'c1'), conv(id: 'c2')];
      expect(ConversationIncremental.removeById(list, 'c1').map((ConversationSummaryModel c) => c.id).toList(), <String>['c2']);
      expect(ConversationIncremental.removeById(list, '').length, 2);
    });
  });
}
