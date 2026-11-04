/// 用户与会话视图模型（好友系统/会话列表/系统通知，与后端返回结构一一对应）
///
/// 原「论坛动态 / 论坛评论」模型随玩家圈 2026-10-05 下线一并删除（后端 forum 模块与
/// `/forum*` 路由已移除，模型留在包里只会成为无人引用的死代码）。
/// 数据库表 `forum_post` / `forum_comment` / `forum_like` 保留，数据不删。

/// 用户资料摘要（好友/搜索/公开资料共用）
class UserBriefModel {
  const UserBriefModel({
    required this.userId,
    required this.uid,
    required this.nickname,
    this.avatarMediaId,
    this.level = 1,
    this.levelName = '',
    this.friendStatus = 'none',
    this.online = false,
  });

  final String userId;
  final String uid;
  final String nickname;
  final String? avatarMediaId;
  final int level;
  final String levelName;
  final String friendStatus; // self/accepted/pending_in/pending_out/none

  /// 在线状态（2026-09-25：好友列表在线点，服务端 WS 连接实时判断）
  final bool online;

  factory UserBriefModel.fromJson(Map<String, dynamic> json) => UserBriefModel(
        userId: '${json['userId'] ?? json['id'] ?? ''}',
        uid: '${json['uid'] ?? ''}',
        nickname: '${json['nickname'] ?? ''}',
        avatarMediaId: json['avatarMediaId'] as String?,
        level: (json['level'] as num?)?.toInt() ?? 1,
        levelName: '${json['levelName'] ?? ''}',
        friendStatus: '${json['friendStatus'] ?? 'none'}',
        online: json['online'] == true,
      );
}

/// 会话列表项（/user/conversations）
class ConversationSummaryModel {
  const ConversationSummaryModel({
    required this.id,
    required this.type,
    required this.unread,
    required this.lastSeq,
    this.peer,
    this.name,
    this.orderId,
    this.lastContent = '',
    this.lastMsgType = 'text',
    this.lastRecalled = false,
    this.lastAt,
    this.updatedAt,
    this.status = 'open',
    this.closedBy,
  });

  final String id;
  final String type; // cs / friend / order_group
  final int unread;
  final int lastSeq;
  final UserBriefModel? peer;

  /// 订单群名称与关联订单（type=order_group）
  final String? name;
  final String? orderId;
  final String lastContent;
  final String lastMsgType;
  final bool lastRecalled;
  final DateTime? lastAt;
  final DateTime? updatedAt;

  /// 客服会话状态（需求 #7）：open 进行中 / closed 已结束
  final String status;
  final String? closedBy;

  bool get isWorkerDirect => type == 'worker';

  /// 派生一份（**实时增量更新专用**，2026-10-15 聊天实时接收优化）。
  ///
  /// 为什么必须走 copyWith 而不是"改字段"：本模型是 `const` 构造的不可变值对象，
  /// 会话列表靠"换一个新对象"来驱动重建（`SetState` → 列表整体替换）。
  /// 与 `ChatMessageModel` 家族同一范式：`x ?? this.x`（**不能置空**；实时事件也不会置空任何字段）。
  ConversationSummaryModel copyWith({
    String? id,
    String? type,
    int? unread,
    int? lastSeq,
    UserBriefModel? peer,
    String? name,
    String? orderId,
    String? lastContent,
    String? lastMsgType,
    bool? lastRecalled,
    DateTime? lastAt,
    DateTime? updatedAt,
    String? status,
    String? closedBy,
  }) =>
      ConversationSummaryModel(
        id: id ?? this.id,
        type: type ?? this.type,
        unread: unread ?? this.unread,
        lastSeq: lastSeq ?? this.lastSeq,
        peer: peer ?? this.peer,
        name: name ?? this.name,
        orderId: orderId ?? this.orderId,
        lastContent: lastContent ?? this.lastContent,
        lastMsgType: lastMsgType ?? this.lastMsgType,
        lastRecalled: lastRecalled ?? this.lastRecalled,
        lastAt: lastAt ?? this.lastAt,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        closedBy: closedBy ?? this.closedBy,
      );

  factory ConversationSummaryModel.fromJson(Map<String, dynamic> json) => ConversationSummaryModel(
        id: '${json['id']}',
        type: '${json['type'] ?? 'cs'}',
        unread: (json['unread'] as num?)?.toInt() ?? 0,
        lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
        peer: json['peer'] is Map<String, dynamic> ? UserBriefModel.fromJson(Map<String, dynamic>.from(json['peer'] as Map)) : null,
        name: json['name'] as String?,
        orderId: json['orderId'] as String?,
        lastContent: '${json['lastMessage']?['content'] ?? ''}',
        lastMsgType: '${json['lastMessage']?['msgType'] ?? 'text'}',
        lastRecalled: json['lastMessage']?['recalled'] == true,
        lastAt: DateTime.tryParse('${json['lastMessage']?['createdAt'] ?? ''}'),
        updatedAt: DateTime.tryParse('${json['updatedAt'] ?? ''}'),
        status: '${json['status'] ?? 'open'}',
        closedBy: json['closedBy'] as String?,
      );
}

/// 好友申请（incoming/outgoing 共用）
class FriendRequestModel {
  const FriendRequestModel({
    required this.id,
    required this.userId,
    required this.uid,
    required this.nickname,
    this.avatarMediaId,
    this.message = '',
    this.createdAt,
  });

  final String id;
  final String userId;
  final String uid;
  final String nickname;
  final String? avatarMediaId;
  final String message;
  final DateTime? createdAt;

  factory FriendRequestModel.fromJson(Map<String, dynamic> json) => FriendRequestModel(
        id: '${json['id']}',
        userId: '${json['userId']}',
        uid: '${json['uid'] ?? ''}',
        nickname: '${json['nickname'] ?? ''}',
        avatarMediaId: json['avatarMediaId'] as String?,
        message: '${json['message'] ?? ''}',
        createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      );
}

/// 系统通知
class NotificationModel {
  const NotificationModel({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    this.isRead = false,
    this.createdAt,
  });

  final String id;
  final String type;
  final String title;
  final String content;
  final bool isRead;
  final DateTime? createdAt;

  factory NotificationModel.fromJson(Map<String, dynamic> json) => NotificationModel(
        id: '${json['id']}',
        type: '${json['type'] ?? ''}',
        title: '${json['title'] ?? ''}',
        content: '${json['content'] ?? ''}',
        isRead: json['isRead'] == true,
        createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      );
}
