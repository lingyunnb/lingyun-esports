/**
 * 打手态「通知栏提醒」· 运行时装配层（在场状态 / 宿主注入 / 订阅与派发）
 * ============================================================================
 *
 * 三块：
 *   1. [WorkerNotifier] —— **平台能力的接口**（core 只描述，boss-app 用
 *      `flutter_local_notifications` 实现；core 里任何地方都不 import 平台插件）。
 *   2. [WorkerNotifyHub] —— 进程级单例：宿主注入的能力 + "点通知要跳到哪" 的待处理请求。
 *   3. [WorkerNotifyService] —— 打手态壳启动时订阅 `order:new` / `msg:new`，
 *      过判定门 → **回源拿真实业务信息** → 交给 [WorkerNotifier] 发。
 *
 * ## 三个"不发"的硬规则（逐条对应验收）
 *   - **只有打手态发**：老板态 / 管理员态不订阅（壳不装），且判定门再看一次身份（老板态不发）；
 *   - **在那一屏不发**：正在接单大厅 → 新单不弹；正在看那条会话 → 消息不弹；
 *   - **拿不到真实信息不发**：单子不在我的大厅里（无权限分部 / 已被抢）、会话不在
 *     【客服 / 老板】两段里 → **静默丢弃**。宁可少一条通知，也不编一条（负责人硬要求）。
 *
 * ⚠️ 后台到达边界见 `worker_notice.dart` 顶部的说明与 `docs/30-打手态通知栏提醒.md`。
 */
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../chat/user_models.dart';
import '../models/order_brief.dart';
import '../realtime/realtime_client.dart';
import 'worker_notice.dart';

/// 发系统通知的**平台能力**（core 只声明；实现见 `apps/boss-app/lib/services/worker_local_notifier.dart`）
///
/// 为什么定义成接口而不是直接调插件：core 同时被**已冻结的工作端**复用，
/// 往 core 引平台插件等于连带改冻结端的依赖树；而且有了这层接口，
/// "该不该发"可以在**纯 Dart 单测**里用假实现逐条钉死（不碰系统 API）。
abstract class WorkerNotifier {
  /// 建渠道（幂等）+ 注册点击回调；返回"本次冷启动是否由点通知拉起"要跳的目标
  ///
  /// **必须幂等**：main 里调一次、show 前再兜一次，重复调用不能重复建渠道/重复注册。
  Future<WorkerNoticeRoute?> init();

  /// **系统层面**是否已允许本 App 发通知（只读查询，**不弹任何窗**）
  ///
  /// Android < 13 恒为 true（那个版本没有运行时通知权限）。
  Future<bool> notificationsAllowed();

  /// 弹出系统授权对话框（Android 13+ POST_NOTIFICATIONS）；不支持/已授权 → true
  Future<bool> requestPermission();

  /// 发一条通知（实现负责按 [WorkerNotice.kind] 选渠道：HIGH + 声音 + 震动）
  Future<void> show(WorkerNotice notice);

  /// 清掉本 App 的全部通知（退出打手态时不该留着打手通知）
  Future<void> cancelAll();
}

/// "用户此刻在打手态的哪一屏"（**免打扰判定的唯一数据源**）
///
/// 谁写它：
///   - `IdentityWorkerShell` 写 [hallVisible]（底栏下标 = 大厅那一项时）；
///   - 宿主 App（老板端 `openWorkerChat`）在**压上聊天页期间**写 [openConversationId]。
///
/// 为什么必须由壳/宿主显式写，而不是页面自己 `initState`：打手态用的是 `IndexedStack`，
/// 三个页面**同时挂载**（只是不可见）—— "mounted" 根本区分不出当前看的是哪一屏。
class WorkerNotifyPresence {
  WorkerNotifyPresence();

  /// 进程级实例（宿主与 core 都往这里写/读）
  static final WorkerNotifyPresence instance = WorkerNotifyPresence();

  /// 接单大厅此刻是当前屏（底部导航停在第 1 项）
  bool hallVisible = false;

  /// 正在看的会话 id（聊天页压在上面期间才有值；'' = 没在看任何会话）
  String openConversationId = '';

  void reset() {
    hallVisible = false;
    openConversationId = '';
  }
}

/// 进程级装配点（宿主注入能力 + 点通知要跳哪）
class WorkerNotifyHub {
  WorkerNotifyHub._();

  static final WorkerNotifyHub instance = WorkerNotifyHub._();

  /// 宿主注入的平台能力；**null = 整个功能静默关闭**（行为与改动前逐字节相同）
  ///
  /// 谁注入：`apps/boss-app/lib/main.dart`（`WorkerLocalNotifier`）。
  WorkerNotifier? notifier;

  /// "点通知要求打开接单大厅 / 消息页"的待处理请求
  ///
  /// 为什么用 ValueNotifier 而不是回调：**冷启动也要能落到位** —— 点通知时壳可能还不存在，
  /// 请求先落在这里，壳一挂载/一切 tab 就消费掉（见 `IdentityWorkerShell._consumeNoticeRoute`）。
  final ValueNotifier<WorkerNoticeRoute?> pendingRoute = ValueNotifier<WorkerNoticeRoute?>(null);

  /// 时间源（测试注入）
  DateTime Function() now = DateTime.now;

  /// 登记一条跳转请求（通知被点 / 冷启动拉起都会走这里）
  void requestRoute(WorkerNoticeRoute route) {
    pendingRoute.value = route.stamped(now());
  }

  /// 取走待处理请求（**无论是否过期都取走**：不许留一条永远跳不动的请求）
  ///
  /// 过期（超过 [WorkerNoticeRoute.ttl]）→ 返回 null：用户点完通知过了两分钟才进打手态，
  /// 这时再抢他的视线去跳转是打扰，不是帮忙。
  WorkerNoticeRoute? consumeRoute() {
    final route = pendingRoute.value;
    if (route == null) return null;
    pendingRoute.value = null;
    return route.expiredAt(now()) ? null : route;
  }

  /// 测试用：清空注入与待处理请求（**widget 测试之间必须清**，否则串味）
  @visibleForTesting
  void reset() {
    notifier = null;
    pendingRoute.value = null;
    now = DateTime.now;
  }
}

/// 打手态通知派发服务：订阅两个事件 → 判定 → 回源拿真实信息 → 发通知
class WorkerNotifyService {
  WorkerNotifyService({
    required this.notifier,
    WorkerNotifyPresence? presence,
    ApiClient? api,
    RealtimeClient? realtime,
    bool Function()? workerModeProbe,
    DateTime Function()? now,
  })  : _presence = presence ?? WorkerNotifyPresence.instance,
        _api = api ?? ApiClient(),
        _realtime = realtime ?? RealtimeClient.shared,
        _workerModeProbe = workerModeProbe ?? defaultWorkerModeProbe,
        _now = now ?? DateTime.now;

  /// 生产判定：身份 = 打手态（有 companion 令牌）+ 绑定里确有生效的打手档案
  ///
  /// 口径与验收项一致（负责人指出的 `active?.worker != null`），
  /// 判定函数只有一份：[WorkerNoticeGate.isWorkerMode]。
  static bool defaultWorkerModeProbe() {
    final auth = AuthStore.instance;
    return WorkerNoticeGate.isWorkerMode(
      workerIdentity: auth.workerIdentity,
      bindingWorker: auth.identityStatus?.worker,
    );
  }

  final WorkerNotifier notifier;
  final WorkerNotifyPresence _presence;
  final ApiClient _api;
  final RealtimeClient _realtime;
  final bool Function() _workerModeProbe;
  final DateTime Function() _now;
  final WorkerNoticeIds _ids = WorkerNoticeIds();

  final List<void Function()> _offs = <void Function()>[];
  bool _running = false;

  /// 是否在派发中（壳 dispose 后必须为 false —— 停掉后**一条都不许再发**）
  bool get running => _running;

  /// 打手态壳挂载时调用（幂等）
  Future<void> start() async {
    if (_running) return;
    _running = true;
    final token = AuthStore.instance.activeToken;
    if (token == null) return;
    // 单例 WS：壳里的页面本来就会 connect，这里再 connect 一次是幂等的（同令牌直接跳过）
    _realtime.connect(token: token);
    _offs.add(_realtime.on('order:new', (dynamic d) => unawaited(handleOrder(d))));
    _offs.add(_realtime.on('msg:new', (dynamic d) => unawaited(handleMessage(d))));
  }

  /// 退出打手态 / 壳销毁时调用：退订 + 清在场状态 + 清掉已弹的打手通知
  void stop() {
    for (final off in _offs) {
      off();
    }
    _offs.clear();
    _running = false;
    _presence.reset();
    _ids.clear();
    unawaited(notifier.cancelAll().catchError((_) {}));
  }

  /// `order:new` 事件入口（**测试直接投递事件就调它**；WS 回调也是它）
  Future<void> handleOrder(dynamic raw) async {
    final event = WorkerOrderEvent.parse(raw);
    if (event == null) return;
    // 服务端复用 order:new 广播"被抢 / 取消"——那两种不算新单，弹「有新订单」就是撒谎
    if (!WorkerNoticeGate.isNewOrderEvent(event.status)) return;
    if (!_shouldFire()) return;
    if (_presence.hallVisible) return; // 用户此刻就在大厅 → 列表自己在刷新，不打扰
    final notice = await _buildOrderNotice(event.orderId);
    if (notice == null) return;
    if (!_shouldFire()) return; // 回源期间身份变了/壳已销毁 → 丢弃
    await _show(notice);
  }

  /// `msg:new` 事件入口
  Future<void> handleMessage(dynamic raw) async {
    final event = WorkerMessageEvent.parse(raw);
    if (event == null) return;
    if (!_shouldFire()) return;
    if (!WorkerNoticeGate.shouldNotifyMessage(
      workerMode: true,
      senderType: event.senderType,
      conversationId: event.conversationId,
      openConversationId: _presence.openConversationId,
    )) {
      return;
    }
    final conv = await _findConversation(event.conversationId);
    if (conv == null) return; // 不在【客服/老板】两段里 → 不发（也不猜发送方是谁）
    final body = event.preview.trim();
    if (body.isEmpty) return;
    if (!_shouldFire()) return;
    await _show(WorkerNotice(
      id: _ids.forConversation(event.conversationId),
      kind: WorkerNoticeKind.message,
      title: WorkerNoticeText.messageTitle(
        conversationType: conv.type,
        peerNickname: conv.peer?.nickname ?? '',
      ),
      body: body,
      route: WorkerNoticeRoute(
        kind: WorkerNoticeKind.message,
        conversationId: event.conversationId,
        createdAt: _now(),
      ),
    ));
  }

  /// 这次事件到底该不该处理：在派发中 + 当前确实是打手态
  bool _shouldFire() => _running && _workerModeProbe();

  Future<void> _show(WorkerNotice notice) async {
    // 发通知失败**绝不能**影响 App（渠道被用户关掉、系统限流、插件异常都算）
    try {
      await notifier.show(notice);
    } catch (_) {
      // 静默：通知是增强功能，不是业务链路
    }
  }

  /// 新单：回源拿**真实业务信息**（分部名 / 商品名 / 金额 / 单号）
  ///
  /// 三个来源都在伴随会话白名单内：`/worker/order-hall`（我能不能接这单 + 商品与金额）、
  /// `/worker/division-permissions`（分部中文名；**不下发就少一段，不猜**）。
  /// 单子不在我的大厅列表里（无权限分部 / 刚被抢 / 刚取消）→ 返回 null → 不发。
  Future<WorkerNotice?> _buildOrderNotice(String orderId) async {
    final token = AuthStore.instance.activeToken;
    if (token == null) return null;
    Map<String, dynamic> hall;
    Map<String, dynamic> perms;
    try {
      final results = await Future.wait<Map<String, dynamic>>(<Future<Map<String, dynamic>>>[
        _api.request(
          'GET',
          '/worker/order-hall',
          token: token,
          queryParameters: const <String, dynamic>{'page': 1, 'pageSize': 20},
          forceRefresh: true,
        ),
        _api
            .request('GET', '/worker/division-permissions', token: token, forceRefresh: true)
            .catchError((_) => <String, dynamic>{}),
      ]);
      hall = results[0];
      perms = results[1];
    } catch (_) {
      return null; // 拿不到就不发：宁可少一条通知，也不发一条编出来的
    }
    final data = hall['data'];
    final list = (data is Map ? (data['list'] as List<dynamic>?) : null) ?? const <dynamic>[];
    OrderBrief? order;
    for (final item in list) {
      if (item is Map && '${item['id']}' == orderId) {
        order = OrderBrief.fromJson(item.cast<String, dynamic>());
        break;
      }
    }
    if (order == null) return null;
    final body = WorkerNoticeText.orderBody(
      divisionLabel: _divisionLabel(perms, order.divisionId),
      productName: order.productName,
      totalAmount: order.totalAmount,
      orderNo: order.orderNo,
    );
    if (body.trim().isEmpty) return null; // 一条真话都说不出来 → 不发
    return WorkerNotice(
      id: WorkerNoticeIds.order,
      kind: WorkerNoticeKind.order,
      title: WorkerNoticeText.orderTitle,
      body: body,
      route: WorkerNoticeRoute(kind: WorkerNoticeKind.order, createdAt: _now()),
    );
  }

  /// 分部 id → 中文名（`/worker/division-permissions` 的 `label`）；取不到返回空串
  static String _divisionLabel(Map<String, dynamic> perms, String? divisionId) {
    if (divisionId == null || divisionId.isEmpty) return '';
    final data = perms['data'];
    final list = data is List
        ? data
        : (data is Map ? (data['list'] as List<dynamic>?) : null) ?? const <dynamic>[];
    for (final item in list) {
      if (item is Map && '${item['divisionId'] ?? item['id'] ?? ''}' == divisionId) {
        return '${item['label'] ?? item['name'] ?? ''}';
      }
    }
    return '';
  }

  /// 这条会话在不在【客服 / 老板】两段里（**唯一来源**：`/worker/cs/conversations`）
  ///
  /// 不在（好友会话 / 已结束的客服会话 / 不属于我）→ 返回 null → 不发。
  /// 顺带拿到会话类型与对端昵称：标题要用真的，不编。
  Future<ConversationSummaryModel?> _findConversation(String conversationId) async {
    final token = AuthStore.instance.activeToken;
    if (token == null) return null;
    try {
      final resp = await _api.request('GET', '/worker/cs/conversations', token: token, forceRefresh: true);
      final data = resp['data'];
      final raw = data is List ? data : (data is Map ? data['list'] : null);
      final list = (raw as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((Map e) => ConversationSummaryModel.fromJson(e.cast<String, dynamic>()))
          .where((c) => c.type == 'worker' || c.type == 'cs')
          .toList();
      for (final c in list) {
        if (c.id == conversationId) return c;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
