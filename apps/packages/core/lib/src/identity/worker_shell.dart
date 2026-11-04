import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';
import '../auth/auth_store.dart';
import '../config/app_settings.dart';
import '../notify/worker_notice.dart';
import '../notify/worker_notify.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_nav.dart';
import '../widgets/app_toast.dart';
import '../withdraw/withdraw_media.dart';
import 'identity_widgets.dart';
import 'worker_chat_target.dart';
import 'worker_cs_hall_page.dart';
import 'worker_hall_page.dart';
import 'worker_messages_page.dart';
import 'worker_mine_page.dart';

/// 打手态外壳（合并双端 · 身份切换；A 套骨架 + A+ 稿身份细带）
///
/// ## 骨架（与老板态**物理不同**）
/// - 顶部：**没有**任何全局常驻条 —— 身份细带由**每一页自己的页头下方**渲染
///   （A+ 清单 ID-A：位置 = 页头正下方、滚动内容之上、不随内容滚动；各屏完全一致）
/// - 中部：`IndexedStack`，装 **3 或 4 个页面**（接单 / 消息 / [客服] / 我的）
/// - 底部：`AppPlainBottomNav` **3 或 4 项**、**没有中间凸起位**、总高与老板态一致（不跳高）
///
/// ## 第 4 项「客服」是**权限门控**的（负责人 2026-10-08）
/// 出现条件**只有一个**：账号有客服权限（[AuthStore.canServeCustomer] ←
/// `GET /auth/me` 的 `worker.canServeCustomer`）。没有该权限的账号**仍然是 3 项**，
/// 且那 3 项的文案/图标/顺序/几何与改动前**逐项一致**（负向用例钉死：
/// 见 `IdentityWorkerShell.navItems` 与 `navItemsWithCs` 是**两个独立的常量**，
/// 不是"同一个列表按条件截断"—— 后者很容易不小心改到前 3 项）。
///
/// **不做占位符**：没权限时不是"灰着的第 4 项"，而是**它压根不在列表里**
/// （docs/21「不存在的东西不出现」；留空位会让人一直去点一个点不动的东西）。
///
/// ## 干净度是**结构上**保证的，不是靠隐藏
/// 老板态的页面（服务页 / 订单 / 祁小山 AI / 找陪玩 / 排行榜…）在这个 widget 树里
/// **一个都不存在** —— 于是它们的未读轮询、WS 订阅、缓存刷新自然全部不跑，
/// 红点不可能串到打手态（设计稿风险 ④/R3）。
class IdentityWorkerShell extends StatefulWidget {
  const IdentityWorkerShell({
    super.key,
    this.api,
    this.openChat,
    this.onSwitchBack,
    this.canServeCustomer,
    this.withdrawPicker,
    this.withdrawUploader,
  });

  /// 测试注入（不传 → 各页自建 ApiClient）
  final ApiClient? api;

  /// 聊天页注入（宿主 App 提供；见 [IdentityWorkerChatOpener]）
  final IdentityWorkerChatOpener? openChat;

  /// 细带右侧「切回老板」的行为；不传 → 直接切回老板态 + Toast（A+ 清单 ID-B / TR-A）
  final VoidCallback? onSwitchBack;

  /// 提现链路收款码选图注入（宿主 App 提供；见 `WithdrawMedia`）—— 透传给「我的」页
  final Future<PickedWithdrawImage?> Function()? withdrawPicker;

  /// 提现链路上传注入（测试用；不传 → 既有媒体上传链路 `uploadMedia`）
  final Future<MediaUploadResult> Function({
    required String type,
    required List<int> bytes,
    required String filename,
    required String token,
  })? withdrawUploader;

  /// 客服权限的**注入覆盖**（不传 → 实时读 [AuthStore.canServeCustomer]）
  ///
  /// 生产**永远不传**：权限必须来自服务端下发的 `worker.canServeCustomer`（唯一来源）。
  /// 这个参数只为测试/出图存在 —— 有了它，"有权限 = 4 项 / 无权限 = 3 项"这两条
  /// 才能在**不伪造整个 AuthStore 会话**的前提下各出一张图、各断一次言。
  final bool? canServeCustomer;

  /// 打手态底部导航**三项**（无客服权限；顺序 = 接单 / 消息 / 我的）
  ///
  /// 放在 [IdentityWorkerShell] 上（而不是 State 里）是为了让出图用的 [IdentityWorkerShellScaffold]
  /// 与生产走**同一份**常量 —— 验收项"无权限时只有 3 项、无凸起"断言的必须是生产同源的列表。
  ///
  /// ⚠️ **这一行是"无权限 = 改动前逐像素一致"的锚点，不许动**：文案、图标、顺序都保持原样；
  /// 有权限的那 4 项是**另一个常量** [navItemsWithCs]，两者不共享可变状态。
  static const List<({String label, IconData icon, IconData active})> navItems = [
    (label: '接单', icon: AppIconsLegacy.credit_card_outlined, active: AppIconsLegacy.credit_card_rounded),
    (label: '消息', icon: AppIcon.messages, active: AppIcon.messagesFill),
    (label: '我的', icon: AppIcon.mine, active: AppIcon.mineFill),
  ];

  /// 打手态底部导航**四项**（**有**客服权限；顺序 = 接单 / 消息 / **客服** / 我的）
  ///
  /// 前 3 项与 [navItems] 逐项相同，只在「消息」与「我的」之间插入「客服」——
  /// 这样"有权限 / 无权限"的差异**只体现为多一项**，不会让用户重新学习底栏。
  ///
  /// 图标：`AppIconsLegacy.support_agent_outlined`（耳机+话筒，Material 线性）—— 与「联系客服」行
  /// 在打手态其它页用的 [AppIdentityIcons.headset] 同一语义族；未选中 outlined / 选中 rounded，
  /// 与另外三项的规则一致。
  static const List<({String label, IconData icon, IconData active})> navItemsWithCs = [
    (label: '接单', icon: AppIconsLegacy.credit_card_outlined, active: AppIconsLegacy.credit_card_rounded),
    (label: '消息', icon: AppIcon.messages, active: AppIcon.messagesFill),
    (label: '客服', icon: AppIconsLegacy.support_agent_outlined, active: AppIconsLegacy.support_agent_rounded),
    (label: '我的', icon: AppIcon.mine, active: AppIcon.mineFill),
  ];

  /// 按权限取底部导航项（**唯一的门控出口**）
  static List<({String label, IconData icon, IconData active})> navItemsFor({required bool canServeCustomer}) =>
      canServeCustomer ? navItemsWithCs : navItems;

  /// 页面索引 —— **它就是底部导航的下标**（`IndexedStack` 的子顺序与导航项顺序严格一致）
  static const int pageHall = 0;
  static const int pageMessages = 1;

  /// 「客服」页（**仅当有客服权限时存在**）
  static const int pageCs = 2;

  /// 「我的」页：**无客服权限 = 2**（与改动前逐字一致）、有客服权限 = 3
  static const int pageMine = 2;
  static const int pageMineWithCs = 3;

  /// 「我的」页在当前权限下的下标（页面与底部导航共用这一个函数）
  static int mineIndexFor({required bool canServeCustomer}) => canServeCustomer ? pageMineWithCs : pageMine;

  @override
  State<IdentityWorkerShell> createState() => _IdentityWorkerShellState();
}

class _IdentityWorkerShellState extends State<IdentityWorkerShell> {
  int _index = IdentityWorkerShell.pageHall;
  int _unread = 0;

  /// 打手态通知派发（**只在打手态壳活着时存在** —— 退出打手态即退订）
  WorkerNotifyService? _notifyService;

  /// 消息页的 key：shell 用它读未读总数（也用于测试断言"只有两段"）
  final GlobalKey<IdentityWorkerMessagesPageState> _messagesKey = GlobalKey<IdentityWorkerMessagesPageState>();

  /// 是否有客服权限（注入优先；生产读 AuthStore）
  bool get _canServeCs => widget.canServeCustomer ?? AuthStore.instance.canServeCustomer;

  /// 当前底部导航项（3 或 4 项，同源的常量）
  List<({String label, IconData icon, IconData active})> get _navItems =>
      IdentityWorkerShell.navItemsFor(canServeCustomer: _canServeCs);

  @override
  void initState() {
    super.initState();
    _maybeShowNotice();
    /**
     * 权限是**异步**到的（`/auth/me` / `/worker/me` 回来才有 `worker.canServeCustomer`）：
     * 监听 store，权限一到就让第 4 项出现 —— 不需要重登、不需要重进打手态。
     * 反方向同样成立：权限被撤销后刷新到的资料会让第 4 项消失（并把选中的页收回接单大厅）。
     */
    AuthStore.instance.addListener(_onAuthChanged);
    // 打手态「通知栏提醒」（负责人 2026-10-15）：进打手态 = 启动派发 + 请求一次通知权限
    _startWorkerNotice();
    // 点通知冷启动进来的：壳一挂载就消费那条"要跳到哪"的请求（**App 未启动也能落到位**）
    _consumeNoticeRoute();
    WorkerNotifyHub.instance.pendingRoute.addListener(_consumeNoticeRoute);
  }

  @override
  void dispose() {
    WorkerNotifyHub.instance.pendingRoute.removeListener(_consumeNoticeRoute);
    // 退出打手态：退订事件 + 清在场状态 + 清掉已经弹出去的打手通知
    // （老板态不该留着打手态的通知在通知栏里 —— 身份隔离，不只是"不发"）
    _notifyService?.stop();
    _notifyService = null;
    AuthStore.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  // ---------------------------------------------------------------- 通知栏提醒

  /// 启动打手态通知派发（**宿主未注入平台能力 = 整个功能关闭**，行为与改动前逐字节相同）
  void _startWorkerNotice() {
    final notifier = WorkerNotifyHub.instance.notifier;
    if (notifier == null) return;
    _syncNotifyPresence();
    final service = WorkerNotifyService(notifier: notifier, api: widget.api);
    _notifyService = service;
    unawaited(service.start());
    unawaited(_ensureNoticePermission(notifier));
  }

  /// 通知权限（Android 13+ POST_NOTIFICATIONS）：**只问一次**，被拒优雅降级
  ///
  /// 顺序刻意是"先查已授权 → 再查有没有问过 → 才弹窗"：
  ///   1. 已经开着（含 Android <13）→ 什么都不做（**绝不弹空窗**）；
  ///   2. 用户之前拒过 / 已经问过 → **不再反复弹**（落盘记忆，跨启动也记得）；
  ///   3. 第一次且没开着 → 弹一次；被拒 → 给**一条**中文说明，之后静默降级。
  /// 全过程不抛：通知是增强功能，任何一步失败都不该影响接单。
  Future<void> _ensureNoticePermission(WorkerNotifier notifier) async {
    bool allowed;
    try {
      allowed = await notifier.notificationsAllowed();
    } catch (_) {
      return;
    }
    if (allowed) return;
    try {
      if (await AppSettings.instance.workerNoticePermissionAsked()) return;
      await AppSettings.instance.setWorkerNoticePermissionAsked();
    } catch (_) {
      // 存储不可用：仍继续问一次（本轮运行内不会重复问，因为壳只 _startWorkerNotice 一次）
    }
    bool granted;
    try {
      granted = await notifier.requestPermission();
    } catch (_) {
      // 平台侧异常（例如已有一次授权请求在飞）→ **不弹说明**：此刻我们并不知道用户到底允没允许，
      // 说"未开启"可能是假话。（下一轮进打手态时 `notificationsAllowed()` 会给真相。）
      return;
    }
    if (granted || !mounted) return;
    AppToast.info(context, WorkerNoticeText.permissionDenied);
  }

  /// 把"用户此刻在哪一屏"写进在场状态（**免打扰判定的唯一数据源**）
  ///
  /// 为什么必须由壳写而不是页面自己：`IndexedStack` 里三页**同时挂载**，
  /// "页面 mounted" 根本区分不出当前看的是哪一屏。
  void _syncNotifyPresence() {
    if (WorkerNotifyHub.instance.notifier == null) return;
    WorkerNotifyPresence.instance.hallVisible = _index == IdentityWorkerShell.pageHall;
  }

  /// 消费"点通知要跳到哪"（壳挂载时 + 每次请求到来时）
  void _consumeNoticeRoute() {
    if (!mounted) return;
    final route = WorkerNotifyHub.instance.consumeRoute();
    if (route == null) return;
    final target = switch (route.kind) {
      WorkerNoticeKind.order => IdentityWorkerShell.pageHall,
      WorkerNoticeKind.message => IdentityWorkerShell.pageMessages,
    };
    if (_index == target) return;
    setState(() => _index = target);
    _syncNotifyPresence();
  }

  /// 只注入（[IdentityWorkerShell.canServeCustomer] 非 null）时不用监听 —— 测试/出图给的是定值
  void _onAuthChanged() {
    if (!mounted || widget.canServeCustomer != null) return;
    // 第 4 项消失时若正停在「客服」页 → 收回接单大厅，避免停在一个已经不在底栏上的页面
    if (!_canServeCs && _index == IdentityWorkerShell.pageCs) {
      setState(() => _index = IdentityWorkerShell.pageHall);
      _syncNotifyPresence();
      return;
    }
    setState(() {});
  }

  /// 打手态被动失效（被顶下线/解绑）后的提示：到这里说明身份已经自动切回老板态，
  /// 这条提示只是把"刚才发生了什么"说清楚（服务端中文原文）。
  void _maybeShowNotice() {
    final notice = AuthStore.instance.identityNotice;
    if (notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.error(context, notice);
      AuthStore.instance.clearIdentityNotice();
    });
  }

  /// 细带右侧「切回老板」：**直接切回**（不是打开弹层）+ Toast（A+ 清单 ID-B / TR-A）
  Future<void> _switchBack() async {
    if (widget.onSwitchBack != null) {
      widget.onSwitchBack!();
      return;
    }
    await AuthStore.instance.switchToBoss();
    if (!mounted) return;
    AppToast.success(context, IdentityTransition.toBoss);
  }

  void _onNavTap(int i) {
    // 导航位索引 == 页面索引（底部导航项与 IndexedStack 子项**同序同长**，没有凸起位需要换算）
    final items = _navItems;
    if (i < 0 || i >= items.length) return;
    setState(() => _index = i);
    // 换屏 → 更新"免打扰"判定用的在场状态（新单只在**不在大厅**时才弹通知）
    _syncNotifyPresence();
  }

  @override
  Widget build(BuildContext context) {
    final canCs = _canServeCs;
    // 页面顺序与底部导航顺序**必须严格一致**（`_index` 同时是两者的下标）
    final pages = <Widget>[
      IdentityWorkerHallPage(
        key: const ValueKey('worker-hall'),
        api: widget.api,
        openChat: widget.openChat,
        onSwitchBack: _switchBack,
      ),
      IdentityWorkerMessagesPage(
        key: _messagesKey,
        api: widget.api,
        openChat: widget.openChat,
        onSwitchBack: _switchBack,
        onUnreadChanged: (n) {
          if (!mounted || n == _unread) return;
          setState(() => _unread = n);
        },
      ),
      // 第 3 项**只在有客服权限时存在**（没有它时「我的」就是第 3 项，与改动前逐字一致）
      if (canCs)
        IdentityWorkerCsHallPage(
          key: const ValueKey('worker-cs-hall'),
          api: widget.api,
          openChat: widget.openChat,
          onSwitchBack: _switchBack,
        ),
      IdentityWorkerMinePage(
        key: const ValueKey('worker-mine'),
        api: widget.api,
        openChat: widget.openChat,
        onSwitchBack: _switchBack,
        withdrawPicker: widget.withdrawPicker,
        withdrawUploader: widget.withdrawUploader,
      ),
    ];
    // 防御：权限在两次 build 之间变化可能让 _index 越界（如正停在「我的」而第 4 项消失）
    final index = _index.clamp(0, pages.length - 1);
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: AppPlainBottomNav(
        // 3 项 / 4 项：**等分**（AppPlainBottomNav 用 Expanded，项数变了自然重新等分，不需要额外参数）
        items: IdentityWorkerShell.navItemsFor(canServeCustomer: canCs),
        currentIndex: index,
        onTap: _onNavTap,
        badgeIndex: IdentityWorkerShell.pageMessages,
        badge: _unread,
        // ID-F：与老板态底栏同高 → 切换身份时底栏不跳高（项数 3↔4 也不跳高）
        height: AppPlainBottomNav.identityHeight,
      ),
    );
  }
}

/// 打手态最小骨架（**给测试与出图用**：不要 ApiClient、不要 WS，任何页面都不会发请求）
///
/// 为什么需要它：验收项要断言"打手态底部导航只有 3 项、无凸起、无浮标"，
/// 而真实 [IdentityWorkerShell] 一挂载就会去拉大厅/消息/钱包（测试里得喂一整套假接口）。
/// 这个骨架复用**同一份** [IdentityWorkerShell.navItemsFor] 与 [AppPlainBottomNav]，
/// 因此它断言的几何/项数与生产完全同源（不是另一套抄来的常量）。
///
/// [canServeCustomer] 默认 **false** → 渲染的是**改动前那 3 项**，与存量快照逐像素一致；
/// 出图/测试要 4 项时显式传 true（走同一份 `navItemsWithCs`）。
class IdentityWorkerShellScaffold extends StatelessWidget {
  const IdentityWorkerShellScaffold({
    super.key,
    required this.body,
    required this.currentIndex,
    required this.onTap,
    this.badgeIndex = 1,
    this.badge = 0,
    this.canServeCustomer = false,
  });

  final Widget body;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final int badgeIndex;
  final int badge;

  /// 与 [IdentityWorkerShell.canServeCustomer] 同义（这里是定值注入，不走 AuthStore）
  final bool canServeCustomer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: body,
      bottomNavigationBar: AppPlainBottomNav(
        items: IdentityWorkerShell.navItemsFor(canServeCustomer: canServeCustomer),
        currentIndex: currentIndex,
        onTap: onTap,
        badgeIndex: badgeIndex,
        badge: badge,
        height: AppPlainBottomNav.identityHeight,
      ),
    );
  }
}

/// 打手态的黑名单核验工具（设计稿 §7：**打手态屏内不得出现任何老板端词**）
///
/// 词表取设计稿 `screens.json` 的 `bossOnlyWords`（**22 个**；任务书里写的"18 词"是
/// 该表的早期版本，本实现以设计稿实际 22 词为准，只多不少）。
/// 用途：测试对打手态每屏的**可见文本**逐屏断言，命中任意一个 → FAIL。
class IdentityWorkerCleanliness {
  IdentityWorkerCleanliness._();

  /// 老板端专属词（打手态一个都不许出现）
  static const List<String> bossOnlyWords = [
    '下单',
    '找陪玩',
    '快速下单',
    '祁小山',
    '排行榜',
    '玩家圈',
    '社区',
    '发帖',
    '会员',
    'VIP',
    '积分卡',
    '开通会员',
    '我的积分卡',
    '优惠券',
    '猫粮',
    '尊享',
    '赛事',
    '俱乐部招募',
    '陪玩列表',
    '商品',
    '购物车',
    '积分商城',
  ];

  /// 在 [texts] 里找出命中的老板端词（空列表 = 干净）
  ///
  /// **逐条文本比对**（不是拼成一个大字符串再 contains）：拼接会在两条文本的边界上
  /// 造出"下"+"单"="下单"这类假命中，把干净页面判成 FAIL。
  static List<String> violations(Iterable<String> texts) {
    final hit = <String>{};
    for (final t in texts) {
      for (final w in bossOnlyWords) {
        if (t.contains(w)) hit.add(w);
      }
    }
    return bossOnlyWords.where(hit.contains).toList();
  }
}

/// 打手态启动前的一次性准备：拉绑定状态 + 打手资料（失败静默，不挡界面）
///
/// 宿主 App 在切到打手态时调用；不做任何权限判定（服务端每次请求实时查库）。
Future<void> prepareWorkerIdentity({ApiClient? api}) async {
  final auth = AuthStore.instance;
  if (!auth.workerIdentity) return;
  try {
    await auth.fetchIdentityStatus(api: api, forceRefresh: true);
  } catch (_) {
    // 静默
  }
  try {
    await auth.fetchWorkerMe(api: api);
  } catch (_) {
    // 静默：「我的」页会用绑定摘要兜底
  }
}

/// 身份元数据（供宿主 App 与测试引用同一份常量）
class IdentityWorkerMeta {
  IdentityWorkerMeta._();

  /// 打手态底部导航的**项数**（**无客服权限 = 3**；验收项②的基线）
  static int get navItemCount => IdentityWorkerShell.navItems.length;

  /// 按权限取项数（**有客服权限 = 4**；验收项①）
  static int navItemCountFor({required bool canServeCustomer}) =>
      IdentityWorkerShell.navItemsFor(canServeCustomer: canServeCustomer).length;

  /// 打手态底部导航文案（**无客服权限 = 接单/消息/我的**；验收项②的基线）
  static List<String> get navLabels => IdentityWorkerShell.navItems.map((e) => e.label).toList();

  /// 按权限取文案（有客服权限 = 接单/消息/**客服**/我的）
  static List<String> navLabelsFor({required bool canServeCustomer}) =>
      IdentityWorkerShell.navItemsFor(canServeCustomer: canServeCustomer).map((e) => e.label).toList();

  /// 打手态身份标识条的文案规则
  static String identityLabel({required String workerNo, String nickname = ''}) =>
      AppIdentityBar.labelOf(workerNo: workerNo, nickname: nickname);
}
