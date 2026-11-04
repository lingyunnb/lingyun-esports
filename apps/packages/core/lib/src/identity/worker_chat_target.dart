import 'package:flutter/material.dart';

/// 打手态"打开某个会话"的**目标描述**（合并双端 · 身份切换）
///
/// 为什么不让 core 自己实现聊天页：聊天页（`ChatDetailPage`）本来就在老板端与工作端各有
/// 一份实现，包含 WS 收发、历史分页、图片上传等一大坨与端强相关的逻辑。core 只描述
/// "要打开哪条会话"，具体页面由**宿主 App**（老板端 boss-app）注入 —— 这样：
///   - 不复制第三份聊天实现，不引入新依赖；
///   - 打手态复用老板端那一个聊天页（它对 companion 令牌同样可用，
///     `/user/conversations*` 已在伴随会话白名单里）；
///   - core 的测试可以注入假实现，不必起真 WS。
class IdentityWorkerChatTarget {
  const IdentityWorkerChatTarget({
    required this.conversationId,
    required this.title,
    this.csConversation = false,
    this.workerDirect = false,
    this.csServing = false,
    this.peerNickname,
    this.peerAvatarMediaId,
    this.lastMessage,
    this.lastAt,
    this.lastIsImage = false,
    this.lastRecalled = false,
    this.peerIsMine = false,
  });

  final String conversationId;
  final String title;
  final bool csConversation;
  final bool workerDirect;

  /// 这条客服会话里，我是不是**当事客服**（正在服务的那一侧）—— 2026-10-11 遗留缺陷修复
  ///
  /// 打手态里 `type=cs` 有**两种身份**：长得一模一样，**侧别不同** ——
  /// - `false`（缺省）= 我是**发起方**（「联系客服」建的那条，`chat_conversation.user_id = 我`）
  ///   → 与老板态逐字相同，走 `user` 侧；
  /// - `true` = 我是**被指派的当事客服**（客服大厅接入 / 老板的咨询被指派给我）
  ///   → 走 `worker` 侧 —— 与服务端 `resolveUserRouteActor` 的口径**同一句**
  ///   （「当事客服 → worker 侧」）。
  ///
  /// 为什么必须由调用方给、**不能让服务端猜**：`POST /user/conversation/close` 的请求里
  /// **没有任何 id**，服务端只能在"我自己没有进行中会话、且恰好服务着一条"时推断；
  /// **同时服务 ≥2 条时不猜 → 404**（真机报障：客服点「结束咨询」关不掉当前这条）。
  /// 客户端把 **id + 侧别**明确带下去（见 [sendPath]），结束咨询才精确到**当前这一条**。
  final bool csServing;

  final String? peerNickname;
  final String? peerAvatarMediaId;
  final String? lastMessage;
  final DateTime? lastAt;
  final bool lastIsImage;
  final bool lastRecalled;
  final bool peerIsMine;

  /// 聊天页要用的**发送/历史/状态**路径（`ChatDetailPage.sendPath`）：
  /// `null` = 走老板端 `/user/conversations/<id>/*`（服务端按当事方判定侧别，老板态一行未变）。
  ///
  /// 路径里**带会话 id**（`/worker/cs/conversations/<id>/…`）—— 聊天页的「结束咨询」就是从
  /// 同一条路径推出带 id 的关闭路由（唯一出处 `ChatDetailPage.closeConsultPath`），
  /// 侧别只在这里判定一次，页面内不再有第二处 `if (worker)`。
  String? get sendPath => csServing ? '/worker/cs/conversations/$conversationId/messages' : null;
}

/// 「打开会话」的实现（由宿主 App 注入：老板端 → `ChatDetailPage`）
typedef IdentityWorkerChatOpener = Future<void> Function(BuildContext context, IdentityWorkerChatTarget target);
