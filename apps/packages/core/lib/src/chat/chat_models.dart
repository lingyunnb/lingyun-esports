/// 聊天模型（docs/07）：客户端消息/会话视图模型，与后端 messageView/会话视图字段一一对应

/// 会话消息（msg:new / 历史接口返回结构）
class ChatMessageModel {
  const ChatMessageModel({
    required this.msgId,
    required this.seq,
    required this.senderType,
    required this.senderId,
    required this.msgType,
    required this.content,
    required this.recalled,
    required this.createdAt,
    this.clientMsgId,
    this.senderNickname = '',
    this.pending = false,
    this.failed = false,
  });

  final String msgId;
  final int seq;
  final String senderType; // user / worker
  final String senderId;
  final String msgType; // text / image
  final String content;
  final bool recalled;
  final DateTime createdAt;
  final String? clientMsgId;

  /// 发送者昵称（订单群内展示谁发的）
  final String senderNickname;

  /// 本地待发送状态（未收到 ACK）
  final bool pending;

  /// 发送失败（WS 与 HTTP 兜底均失败，可点击重试）
  final bool failed;

  /// 是否为本地占位消息（msgId 形如 local-xxx，尚未被服务端确认替换）
  bool get isLocal => msgId.startsWith('local-');

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) => ChatMessageModel(
        msgId: '${json['msgId']}',
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        senderType: '${json['senderType'] ?? 'user'}',
        senderId: '${json['senderId'] ?? ''}',
        msgType: '${json['msgType'] ?? 'text'}',
        content: '${json['content'] ?? ''}',
        recalled: json['recalled'] == true,
        createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
        clientMsgId: json['clientMsgId'] as String?,
        senderNickname: '${json['senderNickname'] ?? ''}',
      );

  /// copyWith 支持用服务端 ACK 的 msgId/seq 替换本地占位值（修复「撤回失效/重复气泡」）
  ChatMessageModel copyWith({String? msgId, int? seq, String? clientMsgId, bool? pending, bool? recalled, bool? failed, bool clearClientMsgId = false}) => ChatMessageModel(
        msgId: msgId ?? this.msgId,
        seq: seq ?? this.seq,
        senderType: senderType,
        senderId: senderId,
        msgType: msgType,
        content: content,
        recalled: recalled ?? this.recalled,
        createdAt: createdAt,
        clientMsgId: clearClientMsgId ? null : (clientMsgId ?? this.clientMsgId),
        senderNickname: senderNickname,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );
}

/// 会话摘要（用户会话 / 客服会话 / 订单群列表项）
class ChatConversationModel {
  const ChatConversationModel({
    required this.id,
    required this.unread,
    required this.lastSeq,
    this.userNickname,
    this.name,
    this.orderId,
    this.type,
    this.assigned = false,
  });

  final String id;
  final int unread;
  final int lastSeq;
  final String? userNickname;

  /// 订单群名称（如"订单群-ORDxxxx"）
  final String? name;

  /// 订单群关联订单 id
  final String? orderId;

  /// cs / friend / order_group
  final String? type;
  final bool assigned;

  bool get isWorkerDirect => type == 'worker';

  factory ChatConversationModel.fromJson(Map<String, dynamic> json) => ChatConversationModel(
        id: '${json['id']}',
        unread: (json['unread'] as num?)?.toInt() ?? 0,
        lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
        userNickname: json['userNickname'] as String?,
        name: json['name'] as String?,
        orderId: json['orderId'] as String?,
        type: json['type'] as String?,
        assigned: json['assigned'] == true,
      );
}
