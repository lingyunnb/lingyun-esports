/**
 * 打手态「通知栏提醒」· 纯逻辑层（渠道常量 / 事件解析 / 判定门 / 文案）
 * ============================================================================
 *
 * 负责人 2026-10-15 原话：「在打手端加一个功能：当用户在打手端时有单子和客服要发提醒到
 * 通知栏，就像微信来消息了那样」。
 *
 * ## 为什么"发通知"这件事要拆成两半
 * - **本文件 + `worker_notify.dart`（fish_core）**：纯 Dart —— 该不该发、发什么、点了去哪、
 *   事件 payload 怎么读。可被单测逐条钉死，**不碰任何系统 API**。
 * - **`apps/boss-app/lib/services/worker_local_notifier.dart`**：`flutter_local_notifications`
 *   的具体实现（建渠道 / 要权限 / show / 点击回调）。**平台插件不进 core**：core 同时被
 *   **已冻结**的工作端复用，往 core 塞平台插件会连带改冻结端的依赖树（与 `WithdrawMedia`
 *   把选图能力留给宿主注入是同一条路线）。
 *
 * ## ⚠️ 真实边界（必须让负责人知道，别以为做到了"微信级"）
 * 本项目**没有接任何推送服务**（无 FCM / 无厂商推送通道）。通知里的事件来自
 * `RealtimeClient`（Socket.IO）——**WebSocket 只在 App 进程存活期间在线**：
 *   - App 在前台 / 刚切到后台（进程还在）→ 通知能到；
 *   - 用户**从最近任务里划掉 App**、或被系统回收进程 → WS 断开 → **收不到任何通知**。
 * 详见 `docs/30-打手态通知栏提醒.md`（含"前台服务保活"方案的代价，默认**不做**）。
 */
library;

import 'dart:convert';

import '../identity/worker_identity_models.dart';
// 金额展示唯一出口（`¥38.00`：`¥` + 千分位 + 两位小数）—— 本文件**不自己拼金额**
import '../util/idempotency.dart';

/// 两个通知渠道（Android 8+ 必须分渠道；**渠道一旦创建，声音/震动就锁死在渠道上**）
///
/// 刻意分成两条（微信也是这么做的）：新单和消息是两种完全不同的打扰，
/// 用户在系统设置里能**单独关掉其中一种** —— 合一个渠道就做不到这件事。
///
/// 渠道名/描述是**用户可见文案**（系统设置页里逐字显示），所以是中文、具体、不带夸张。
class WorkerNoticeChannel {
  WorkerNoticeChannel._();

  /// 新订单：importance HIGH（横幅 heads-up）+ 声音 + 震动
  static const String orderId = 'worker_orders';
  static const String orderName = '新订单';
  static const String orderDescription = '有新单进接单大厅时提醒你';

  /// 消息（客服 / 老板）：importance HIGH + 声音 + 震动
  static const String messageId = 'worker_messages';
  static const String messageName = '消息';
  static const String messageDescription = '客服或老板发来消息时提醒你';
}

/// 通知类别（决定渠道、标题样式与点击落点）
enum WorkerNoticeKind {
  /// 新单进大厅 → 点击去**接单大厅**
  order,

  /// 客服 / 老板消息 → 点击去**消息页**
  message;

  /// 稳定标识（进 payload、进日志；**不用 `name`**，避免将来改枚举名把旧通知读废）
  String get key => this == WorkerNoticeKind.order ? 'order' : 'message';

  static WorkerNoticeKind? fromKey(String? key) => switch (key) {
        'order' => WorkerNoticeKind.order,
        'message' => WorkerNoticeKind.message,
        _ => null,
      };
}

/// 点击通知后要落到的位置（**冷启动也要能落到位**，所以它能被序列化进 payload）
class WorkerNoticeRoute {
  const WorkerNoticeRoute({required this.kind, this.conversationId = '', this.createdAt});

  final WorkerNoticeKind kind;

  /// 仅消息类有值（本版**不**直接钻进会话，落到消息页即可 —— 见 docs/30 的"做到哪一步"）
  final String conversationId;

  /// 进程内创建时刻（判断"这条跳转还算不算数"）；从通知 payload 解出来时为 null
  final DateTime? createdAt;

  /// 待处理跳转的保鲜期：超过它就不再抢用户的视线（App 冷启动到壳挂载通常 <2s，
  /// 2 分钟已经足够覆盖"点开→闪屏→地址解析失败重试"的最坏路径）
  static const Duration ttl = Duration(seconds: 120);

  WorkerNoticeRoute stamped(DateTime now) =>
      WorkerNoticeRoute(kind: kind, conversationId: conversationId, createdAt: createdAt ?? now);

  /// 是否已过期（[createdAt] 为 null = 由通知 payload 解出，**不判过期**）
  bool expiredAt(DateTime now) {
    final at = createdAt;
    if (at == null) return false;
    return now.difference(at) > ttl;
  }

  /// 编码进通知 payload（点击时原样回传）
  String encode() => jsonEncode(<String, dynamic>{'v': 1, 'k': kind.key, 'c': conversationId});

  /// 解码通知 payload；**任何坏形状都返回 null（绝不抛）** —— 点通知不该让 App 崩
  static WorkerNoticeRoute? decode(String? payload) {
    if (payload == null || payload.trim().isEmpty) return null;
    if (payload.length > 512) return null; // 防御：payload 只可能是一行短 JSON
    try {
      final dynamic raw = jsonDecode(payload);
      if (raw is! Map) return null;
      final kind = WorkerNoticeKind.fromKey('${raw['k'] ?? ''}');
      if (kind == null) return null;
      return WorkerNoticeRoute(kind: kind, conversationId: '${raw['c'] ?? ''}');
    } catch (_) {
      return null;
    }
  }
}

/// 一条要发出去的通知（渠道 + 标题 + 正文 + 点击落点）
class WorkerNotice {
  const WorkerNotice({required this.id, required this.kind, required this.title, required this.body, required this.route});

  /// 通知 id：**同一目标复用同一个 id** → 后到的覆盖先到的（不会堆一屏）
  final int id;
  final WorkerNoticeKind kind;
  final String title;
  final String body;
  final WorkerNoticeRoute route;

  String get payload => route.encode();
}

/// 通知 id 分配：新单固定一个 id（"大厅里最新那一单"），消息按会话各占一槽
///
/// 为什么不用 `conversationId.hashCode`：哈希会撞，撞了两条会话就互相覆盖通知；
/// 这里用一个进程内的小表按需分配，撞不了（槽位用完则回收最早的那个）。
class WorkerNoticeIds {
  WorkerNoticeIds({this.messageSlots = 24});

  /// 新单：始终覆盖上一条
  static const int order = 9001;
  static const int _messageBase = 9100;

  /// 消息槽位数（超过就复用最早的槽 —— 屏幕上不会有 24 条会话通知堆着）
  final int messageSlots;

  final Map<String, int> _messageIds = <String, int>{};

  /// 会话出现顺序（槽位不够时回收最早的那个会话）
  final List<String> _arrival = <String>[];

  /// 会话 → 稳定通知 id（同一会话永远同一个 id → 同一会话的消息互相覆盖，不堆通知）
  int forConversation(String conversationId) {
    final key = conversationId.isEmpty ? '__unknown__' : conversationId;
    final existing = _messageIds[key];
    if (existing != null) return existing;
    if (_messageIds.length >= messageSlots && _arrival.isNotEmpty) {
      _messageIds.remove(_arrival.removeAt(0));
    }
    // 取"当前最小空闲槽位"，避免回收后与在用槽位撞
    var slot = 0;
    while (_messageIds.containsValue(_messageBase + slot)) {
      slot++;
    }
    _messageIds[key] = _messageBase + slot;
    _arrival.add(key);
    return _messageBase + slot;
  }

  void clear() {
    _messageIds.clear();
    _arrival.clear();
  }
}

/// `order:new` 的 payload（服务端 `order.service.ts`）
///
/// ⚠️ **这个事件名被复用**：新单是 `{orderId}`，而"被抢"与"取消"也会广播 `order:new`
/// 但带 `status`（`'taken'` / `'canceled'`）。只有新单才该弹「有新订单」——
/// 对"被抢/取消"弹"有新订单"就是**撒谎**（见 [WorkerNoticeGate.isNewOrderEvent]）。
class WorkerOrderEvent {
  const WorkerOrderEvent({required this.orderId, this.status});

  final String orderId;
  final String? status;

  /// 解析；形状不对（无 orderId）→ null
  static WorkerOrderEvent? parse(dynamic raw) {
    final m = _eventMap(raw);
    if (m == null) return null;
    final id = '${m['orderId'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final status = '${m['status'] ?? ''}'.trim();
    return WorkerOrderEvent(orderId: id, status: status.isEmpty ? null : status);
  }
}

/// `msg:new` 的 payload（服务端 `chat.service.ts#messageView`）
class WorkerMessageEvent {
  const WorkerMessageEvent({
    required this.msgId,
    required this.conversationId,
    required this.senderType,
    required this.senderNickname,
    required this.msgType,
    required this.content,
    required this.recalled,
  });

  final String msgId;
  final String conversationId;

  /// `user` = 对方（老板 / 咨询的老板）；`worker` = 我方（自己，或同侧的另一位客服）；`system` = 系统
  final String senderType;
  final String senderNickname;

  /// text / image / system ...
  final String msgType;
  final String content;
  final bool recalled;

  /// 一行摘要（**与消息页同一口径**：撤回 → 已撤回、图片 → 图片；超长截断）
  ///
  /// 为什么要截断：通知栏正文只有一两行，甩 500 字进去等于什么都看不见。
  String get preview {
    if (recalled) return WorkerNoticeText.recalledPreview;
    if (msgType == 'image') return WorkerNoticeText.imagePreview;
    if (msgType != 'text') return WorkerNoticeText.otherPreview;
    return WorkerNoticeText.clip(content.replaceAll(RegExp(r'\s+'), ' ').trim());
  }

  /// 解析；形状不对（无会话 id）→ null
  static WorkerMessageEvent? parse(dynamic raw) {
    final m = _eventMap(raw);
    if (m == null) return null;
    final cid = '${m['conversationId'] ?? ''}'.trim();
    if (cid.isEmpty) return null;
    return WorkerMessageEvent(
      msgId: '${m['msgId'] ?? ''}',
      conversationId: cid,
      senderType: '${m['senderType'] ?? ''}'.trim(),
      senderNickname: '${m['senderNickname'] ?? ''}'.trim(),
      msgType: '${m['msgType'] ?? 'text'}'.trim(),
      content: '${m['content'] ?? ''}',
      recalled: m['recalled'] == true,
    );
  }
}

/// 事件 payload 的宽容读取：Socket.IO 正常给 Map，但允许是 JSON 字符串（自建 relay / 回放）
Map<String, dynamic>? _eventMap(dynamic raw) {
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

/// 全部"该不该发 / 发什么"的判定（**纯函数，单独可测**）
class WorkerNoticeGate {
  WorkerNoticeGate._();

  /// 打手态判定（**唯一出口**）
  ///
  /// 两个条件缺一不可：
  ///   - `workerIdentity`（= 身份标记为打手态 **且** 本地确有 companion 令牌）→ 老板态/管理员态天然为 false；
  ///   - 绑定里确有生效的打手档案（`active?.worker`，负责人口径）→ 绑定已释放/档案停用时不发。
  ///
  /// `bindingWorker == null`（绑定状态**还没加载到**）**不拦**：身份本身已经证明"在打手态"，
  /// 因为"没加载到绑定状态"而静默丢通知，用户会觉得这功能时灵时不灵。
  static bool isWorkerMode({required bool workerIdentity, required IdentityWorkerProfile? bindingWorker}) =>
      workerIdentity && (bindingWorker == null || bindingWorker.active);

  /// 新单：**用户此刻就在接单大厅那一屏 → 不弹**
  ///
  /// 这就是"像微信却不烦人"的关键：那一刻列表正在自己刷新，横幅只是盖住用户正在看的东西。
  static bool shouldNotifyOrder({required bool workerMode, required bool hallVisible}) =>
      workerMode && !hallVisible;

  /// `order:new` 是不是**真的新单**（服务端复用该事件广播"被抢/取消"）
  ///
  /// 判据取"没有 status"或 `pending_take`（服务端新单那条广播**不带 status**）——
  /// 反过来放行 `taken`/`canceled` 就是**对用户撒谎**："有新订单"点进去却没有单。
  static bool isNewOrderEvent(String? status) {
    final s = status?.trim() ?? '';
    return s.isEmpty || s == 'pending_take';
  }

  /// 消息：只发【客服 / 老板】发来的；正在看那条会话 → 不弹
  ///
  /// `senderType != 'user'` 一律不发：`worker` = 我方（自己发的消息也会从这个房间推回来，
  /// 弹给自己等于每次打字都自问自答）；`system` = 系统消息（居中灰条，不是"有人找你"）。
  static bool shouldNotifyMessage({
    required bool workerMode,
    required String senderType,
    required String conversationId,
    required String openConversationId,
  }) {
    if (!workerMode) return false;
    if (senderType != 'user') return false;
    if (conversationId.isEmpty) return false;
    return conversationId != openConversationId;
  }
}

/// 通知文案（**唯一出口**；测试直接引用这些常量/函数，避免"文案改了测试没跟上"）
class WorkerNoticeText {
  WorkerNoticeText._();

  static const String orderTitle = '有新订单';
  static const String messageTitleCs = '祁连山客服';
  static const String messageTitleBossFallback = '老板';

  static const String recalledPreview = '[消息已撤回]';
  static const String imagePreview = '[图片]';
  static const String otherPreview = '[新消息]';

  /// 正文摘要上限（通知栏一两行；超出截断加省略号）
  static const int previewMax = 60;

  /// 权限被拒时的一次性说明（用户可见文案；**不用"管理端/超管"这类内部称呼**，护栏测试盯着）
  static const String permissionDenied = '未开启通知权限：新单和消息不会提醒，可在系统设置里打开';

  static String clip(String text, {int max = previewMax}) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// 新单正文：**只用服务端真的给了的字段**（分部名 / 商品名 / 金额 / 单号）
  ///
  /// 任何一段拿不到就**不写那一段**（不占位、不猜、不编）——例如分部标签没取到就少一段，
  /// 而不是显示一个 UUID。全空 → 返回空串，调用方据此**不发这条通知**。
  static String orderBody({
    required String divisionLabel,
    required String productName,
    required double totalAmount,
    required String orderNo,
  }) {
    final line1 = <String>[
      if (divisionLabel.trim().isNotEmpty) divisionLabel.trim(),
      if (productName.trim().isNotEmpty) clip(productName.trim(), max: 40),
      if (totalAmount > 0) fmtMoney(totalAmount),
    ].join(' · ');
    final line2 = orderNo.trim().isEmpty ? '' : '单号 ${orderNo.trim()}';
    return <String>[if (line1.isNotEmpty) line1, if (line2.isNotEmpty) line2].join('\n');
  }

  /// 消息标题：客服会话固定「祁连山客服」（与消息页同源，不把个人昵称当客服名）；
  /// 老板直聊用老板昵称，昵称缺失才退回「老板」。
  static String messageTitle({required String conversationType, required String peerNickname}) {
    if (conversationType == 'cs') return messageTitleCs;
    final n = peerNickname.trim();
    return n.isEmpty ? messageTitleBossFallback : n;
  }
}
