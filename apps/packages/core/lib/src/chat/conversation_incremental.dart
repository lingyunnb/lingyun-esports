/// **会话列表的增量更新**（2026-10-15 聊天实时接收优化）
///
/// ## 缺陷现场
/// 消息页此前对每条实时事件都是"**全量重拉列表**"：
/// ```dart
/// _realtime.on('msg:new', (_) => _refresh());        // 收一条消息 → GET 整个列表
/// _realtime.on('unread:update', (_) => _refresh());  // 未读变了 → 再 GET 一次
/// ```
/// 对方发一句话，客户端要打 1–2 次全量列表请求、列表被重建 1–2 次。
/// 后果是三类可感问题：**卡顿与闪烁**、**滚动跳位**、**输入框内容抖动**（重建把焦点/滚动带偏）。
///
/// ## 为什么可以增量（数据面的事实，不是猜的）
/// 服务端 `chat.service.ts#messageView` 推的 `msg:new` payload **已经带齐这条消息的全部内容**：
/// ```
/// { msgId, seq, conversationId, senderType, senderId, senderNickname, msgType, content, recalled, createdAt }
/// ```
/// 而会话列表行要显示的"最后一条"正好就是这几个字段（`/user/conversations` 的
/// `lastMessage.{content,msgType,recalled,createdAt}`）。所以本地就能把这行改对，
/// **不需要**为了一个摘要再拉一次整个列表。
///
/// 未读**不自己加**：`unread:update` 带的是服务端权威值（`{conversationId, unread}`），
/// 客户端按它覆盖即可。客户端自增在并发/多端场景下必然与权威值分叉。
///
/// ## 排序口径（与服务端同源）
/// 两个列表接口都是 `ORDER BY c.updated_at DESC`，而收/发消息都会 `save(conversation)`
/// 推动 `updated_at` → **有新消息的会话排到最前**。因此增量更新也必须把它移到列表首位，
/// 否则"增量"与"重拉"的结果不一致（同一份数据两种顺序 = 新的不一致缺陷）。
///
/// ## 返回 null 的语义（**唯一需要回源的情况**）
/// 事件里的 `conversationId` 不在本地列表里 = 这是一条**新会话**（例如打手刚抢到单、
/// 服务端在接单事务里新建了「老板↔打手」直聊）→ 本地没有它的摘要，这时才回源补一条，
/// 且由调用方用 [EventCoalescer] 合并成**一次**请求。
library;

import 'dart:convert';

import '../chat/user_models.dart';

class ConversationIncremental {
  ConversationIncremental._();

  /// `msg:new` → 更新该会话的"最后一条消息"摘要（**不动未读**，未读由 `unread:update` 权威覆盖）。
  ///
  /// 返回更新后的新列表（该会话已移到首位）；返回 `null` = 列表里没有这条会话 → 调用方回源。
  static List<ConversationSummaryModel>? applyMessageEvent(
    List<ConversationSummaryModel> convs,
    dynamic raw,
  ) {
    final m = _eventMap(raw);
    if (m == null) return null;
    final String cid = '${m['conversationId'] ?? ''}'.trim();
    if (cid.isEmpty) return null;
    final int idx = convs.indexWhere((c) => c.id == cid);
    if (idx < 0) return null;

    final ConversationSummaryModel old = convs[idx];
    final String content = '${m['content'] ?? ''}';
    final String msgType = '${m['msgType'] ?? 'text'}'.trim();
    final bool recalled = m['recalled'] == true;
    final DateTime? at = _parseTime(m['createdAt']);
    final int seq = _asInt(m['seq']);

    final ConversationSummaryModel patched = old.copyWith(
      // 最后一条摘要：**原样落地服务端给的内容**（图片/系统消息的展示口径在页面侧，本层不裁剪）
      lastContent: content,
      lastMsgType: msgType.isEmpty ? old.lastMsgType : msgType,
      lastRecalled: recalled,
      lastAt: at ?? old.lastAt,
      // seq 只往前走：乱序到达的旧事件不许把位点回退（否则"已读位点"会算错）
      lastSeq: seq > old.lastSeq ? seq : old.lastSeq,
      updatedAt: at ?? old.updatedAt,
    );

    return <ConversationSummaryModel>[patched, ...convs.where((c) => c.id != cid)];
  }

  /// `unread:update` → 用服务端权威未读覆盖该会话（同样移到首位：未读变化伴随 `updated_at` 变化）。
  static List<ConversationSummaryModel>? applyUnreadEvent(
    List<ConversationSummaryModel> convs,
    dynamic raw,
  ) {
    final m = _eventMap(raw);
    if (m == null) return null;
    final String cid = '${m['conversationId'] ?? ''}'.trim();
    if (cid.isEmpty) return null;
    final int idx = convs.indexWhere((c) => c.id == cid);
    if (idx < 0) return null;
    final Object? rawUnread = m['unread'];
    final int? unread = rawUnread is num ? rawUnread.toInt() : int.tryParse('${rawUnread ?? ''}');
    if (unread == null) return null;

    final ConversationSummaryModel old = convs[idx];
    if (old.unread == unread) return convs; // 已一致：不改数据、也不需要刷新
    final ConversationSummaryModel patched = old.copyWith(unread: unread < 0 ? 0 : unread);
    if (unread <= 0) {
      // 未读清零（一键已读 / 自己读了）不改变"最后一条消息"的排序事实，保持原位更稳
      final List<ConversationSummaryModel> out = List<ConversationSummaryModel>.of(convs);
      out[idx] = patched;
      return out;
    }
    return <ConversationSummaryModel>[patched, ...convs.where((c) => c.id != cid)];
  }

  /// `conv:removed` → 本地先按 id 移除（列表立刻收敛），调用方随后仍可强刷校验。
  static List<ConversationSummaryModel> removeById(List<ConversationSummaryModel> convs, String id) {
    if (id.isEmpty) return convs;
    return convs.where((c) => c.id != id).toList();
  }

  /// 事件 payload 的宽容读取：Socket.IO 正常给 Map，也允许是 JSON 字符串（自建 relay / 回放）。
  /// 坏形状一律 null（**绝不抛**：一条怪事件不该让消息页崩）。
  static Map<String, dynamic>? _eventMap(dynamic raw) {
    if (raw is Map) {
      final out = <String, dynamic>{};
      raw.forEach((Object? k, Object? v) => out['$k'] = v);
      return out;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final dynamic v = jsonDecode(raw);
        if (v is Map) {
          final out = <String, dynamic>{};
          v.forEach((Object? k, Object? vv) => out['$k'] = vv);
          return out;
        }
      } catch (_) {
        // 坏 JSON：当作没有 payload
      }
    }
    return null;
  }

  static int _asInt(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

  static DateTime? _parseTime(Object? v) => DateTime.tryParse('${v ?? ''}');
}
