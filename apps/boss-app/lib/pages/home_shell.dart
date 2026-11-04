import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../services/ai_chat_service.dart';
import '../services/ai_cold_start.dart';
import 'ai_chat_page.dart';
import 'chat_detail_page.dart';
import 'product_list_page.dart';
import 'orders_page.dart';
import 'messages_page.dart';
import 'players_page.dart';
import 'profile_page.dart';
import 'services_page.dart';

/// 老板端主框架（最终设计稿 I 系列 + AI 入口改版 ai-entry-v3 · 2026-10-04 tab 化）
///
/// 底部导航（**2026-10-17 六项等宽平铺**）：**服务 · 下单 · 订单 · 祁小山 · 消息 · 我的**
/// 结构规则（CLAUDE.md）：
/// - 同一入口只出现一次：底部已有 服务/下单/订单/消息/我的 → 顶部不再出现
/// - **祁小山 = 底栏第 4 格（导航位 3）+ 页面分支（[pageAi]=4）**，**底栏常驻、不是 push 二级页**
///   → 它有选中态（选中主色 / 未选中 `#94A3B8`，与其余五项同规则）
/// - **长按祁小山 = 快捷入口面板**（找陪玩 / 聊天记录 / 联系客服 / 直接去下单），
///   避免「找陪玩」这类只在面板里的入口随改版消失（原「发帖到玩家圈」随玩家圈下线一并移除）
/// - 下单入口：**底栏第 2 格（导航位 1）→ push 选择服务页**（另见服务页右下角浮标）
///
/// ## 2026-10-17 负责人当面作废「凸起几何不许动」
/// 六项平铺后中间凸起位不再成立（6 格等分，没有"中间"）→
/// **取消凸起**，祁小山降为普通项；**交互架构一条没改**（仍是分支、仍常驻、长按仍出面板、
/// 系统返回键仍回上一个 tab），变的只是几何与图标风格。
///
/// ## AI 分支的三条规则（2026-10-04）
/// 1. **不是 push**：切分支用 `setState` 改 index，底栏常驻（此前 push 一层会把底栏整个盖住）
/// 2. **懒挂载 + 常驻**：第一次切到 AI 才把 [AiChatPage] 挂进 `IndexedStack`（冷启动不为它拉历史/建 WS 订阅），
///    挂上之后一直留在树上 —— 切走再切回来是**同一段对话**（消息、滚动、输入都是页面自己的状态，
///    shell 不做任何缓存，也不重新加载）
/// 3. **系统返回键**：AI 分支激活时回**上一个 tab**（不是退出 App）；其余分支维持系统默认（退出 App）
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.aiApi, this.aiSource, this.aiRealtime, this.identityApi});

  /// AI 分支的依赖注入（测试用；不传则各页自建 HTTP / WS 实现）
  final ApiClient? aiApi;
  final AiChatSource? aiSource;
  final AiRealtime? aiRealtime;

  /// 打手态（身份切换）的依赖注入（测试用；不传则各页自建 ApiClient）
  final ApiClient? identityApi;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = pageServices;

  /// 系统返回键从 AI 分支退回的那个 tab（AI 之前所在的分支）
  int _lastNonAiPage = pageServices;

  /// AI 分支是否已经挂载过（懒挂载：冷启动不替用户拉一次历史）
  bool _aiMounted = false;

  /// AI 分支激活信号（[AiChatPage] 用它判断"用户是否看得见我"：切走时停生成、收键盘）
  final ValueNotifier<bool> _aiActive = ValueNotifier<bool>(false);

  /// 切回本 tab 时的刷新信号（首页重新拉分部/俱乐部，管理端改动立即同步）
  final ValueNotifier<int> _homeRefresh = ValueNotifier<int>(0);

  /// 页面索引（0 服务 / 1 订单 / 2 消息 / 3 我的 / **4 祁小山 AI**）
  ///
  /// 注意：底部导航有 **6 个位**，**页面索引 ≠ 导航位索引**，
  /// 必须经 [_pageToNav] / [_navToPage] 换算，否则高亮与点击都会错位（2026-10-04 真机截图发现的缺陷）。
  /// 2026-10-17 六项平铺后：
  /// 导航位 `0 服务 / 1 下单 / 2 订单 / 3 祁小山 / 4 消息 / 5 我的`，
  /// 其中**导航位 1（下单）不是页面分支**（点它 push 选择服务页），所以它没有对应的 page 常量。
  static const int pageServices = 0;
  static const int pageOrders = 1;
  static const int pageMessages = 2;
  static const int pageProfile = 3;
  static const int pageAi = 4;

  static int _pageToNav(int page) => switch (page) {
        pageServices => AppBottomNav.servicesNavIndex,
        pageOrders => AppBottomNav.ordersNavIndex,
        pageMessages => AppBottomNav.messagesNavIndex,
        pageProfile => AppBottomNav.mineNavIndex,
        pageAi => AppBottomNav.aiNavIndex, // 3 = 祁小山那一格（选中态按 currentIndex==3 判）
        _ => AppBottomNav.servicesNavIndex,
      };

  static int _navToPage(int nav) => switch (nav) {
        AppBottomNav.servicesNavIndex => pageServices,
        // 下单：由 [AppBottomNav.onCreateOrder] 拦下 push，不会走到这里
        AppBottomNav.orderCreateNavIndex => pageServices,
        AppBottomNav.ordersNavIndex => pageOrders,
        AppBottomNav.aiNavIndex => pageAi,
        AppBottomNav.messagesNavIndex => pageMessages,
        AppBottomNav.mineNavIndex => pageProfile,
        _ => pageServices,
      };

  late final List<Widget> _pages = [
    ServicesPage(
      onGoOrder: _openOrderCreate,
      onNavigate: _switchTab,
      refreshSignal: _homeRefresh,
      // 选择陪玩（2026-10-15；同日二次定案）：服务页**顶部导航第一项** → 复用同一处 `_openPlayers`。
      // 入口由顶部导航**单一承担**：快捷面板里那条已按甲方案移除（负责人定案，见 [_openQuickActions]），
      // 所以全 App 只有这一份"怎么进选择陪玩页"的逻辑，不存在第二条隐藏路径。
      onFindPlayers: _openPlayers,
    ),
    const OrdersPage(),
    const MessagesPage(),
    ProfilePage(onNavigate: _switchTab),
  ];

  /// AI 分支（懒挂载后常驻；activeSignal 让页面知道自己是第 5 个 tab 而不是 push 页）
  late final Widget _aiPage = AiChatPage(
    api: widget.aiApi,
    source: widget.aiSource,
    realtime: widget.aiRealtime,
    activeSignal: _aiActive,
  );

  /// 底栏外观变化 → 重建（切玻璃/实色）
  void _onNavStyleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // 底栏玻璃外观（用户可在「我的 → 外观」切换）
    NavStyleController.instance.addListener(_onNavStyleChanged);
    // **点身份细带 → 打开同一个「切换身份」弹层**（负责人 2026-10-06 截图反馈）
    //
    // 细带只有 28dp，再加一枚可见按钮会破坏它的极简（A+ 清单 ID-A）；改成"点主体"后
    // 零新增像素，却把"打手态/管理员态 → 另一个身份"从"先切回老板态再进弹层"缩成一次点击。
    // 用静态注册而不是让 core 的细带直接 import 弹层：避免 identity_widgets ←→
    // identity_switch_sheet 循环 import；未注册时细带不可点（既有测试行为不变）。
    AppIdentityBar.onBandTap ??= () {
      if (!mounted) return;
      IdentitySwitchSheet.show(
        context,
        api: widget.identityApi,
        onSwitched: (identity) {
          if (!mounted) return;
          /**
           * **只有"切换真的落地了"才报成功**（2026-10-06 身份直切专项）。
           *
           * 直切是"点一下立刻换壳"，失败只可能在**切过去之后的第一条请求**上暴露
           * （目标令牌已被移出白名单 / 12h 到点）：那种情况下 `AuthStore` 会立刻回退到
           * **切换前的身份**，并把中文原因写进 `identityNotice`（由当前 shell 消费成提示）。
           * 若这里照旧弹「已切换到…」，用户会先看到"成功"再看到"失效"，且
           * **成功那句会把失效提示盖掉**（同一个 Toast 位）—— 实测就是这样丢掉提示的。
           */
          if (AuthStore.instance.identity != identity) return;
          AppToast.success(
            context,
            identity == AppIdentity.admin ? IdentityTransition.toAdmin : IdentityTransition.toWorker,
          );
        },
      );
    };
    // **冷启动初始化**（负责人 2026-10-04：会话轮换只在"大退后重新打开"时做一次）：
    // 进程内只发一次 POST /user/ai/reset；失败静默、不阻塞启动。
    // 未登录时它不会消耗这次机会 —— 等登录后 HomeShell 首次挂载（下一次 initState）再补。
    unawaited(AiColdStart.ensureResetOnce(source: widget.aiSource));
    // 打手态恢复（合并双端）：冷启动若上次停在打手态，这里把绑定状态与打手资料补齐。
    // 未处于打手态时它是空操作（不产生任何请求）。
    unawaited(prepareWorkerIdentity(api: widget.identityApi));
    // 打手态被动失效提示（被顶下线/解绑）：身份已自动切回老板态，这里只说清发生了什么
    _showIdentityNotice();
  }

  /// 打手态被动失效提示（只消费一次；不弹"重新登录"，因为老板态会话仍然有效）
  void _showIdentityNotice() {
    final notice = AuthStore.instance.identityNotice;
    if (notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.error(context, notice);
      AuthStore.instance.clearIdentityNotice();
    });
  }

  /// 打手态聊天页出口（宿主 App 提供：复用老板端同一个 `ChatDetailPage`）
  ///
  /// 为什么由老板端注入：聊天页涉及 WS 收发/历史分页/图片上传，两端本来就各有一份实现，
  /// core 只描述"打开哪条会话"。`/user/conversations*` 已在伴随会话白名单里，
  /// 因此同一个页面在打手态只要**换成 companion 令牌**就能照常工作（见 ChatDetailPage 的 activeToken）。
  ///
  /// 【2026-10-11 遗留缺陷修复】**侧别与会话 id 必须带下去**：原来这里**不传 `sendPath`**，
  /// 于是打手态的历史/状态/结束全走老板侧路由，而「结束咨询」打的是**不带 id** 的
  /// `/user/conversation/close` —— 客服同时服务 ≥2 条咨询时服务端不猜 → 404（关不掉那一条）。
  /// 现在映射收口在 [workerChatPage]（`t.sendPath` 带 id 与侧别，见 `IdentityWorkerChatTarget.csServing`）。
  Future<void> openWorkerChat(BuildContext context, IdentityWorkerChatTarget t) async {
    /**
     * 【2026-10-15 打手态通知栏提醒 · 免打扰】聊天页压在上面期间，**这条会话**的消息不再弹通知。
     *
     * 判定的数据源在 core 的 `WorkerNotifyPresence`（core 拿不到宿主 push 的聊天页，
     * 所以由这里写）：`openConversationId` 非空且等于来消息的会话 → 通知被抑制。
     * 这就是"像微信却不烦人"——你正看着这条会话，铃声不该同时响。
     */
    WorkerNotifyPresence.instance.openConversationId = t.conversationId;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => workerChatPage(t)),
      );
    } finally {
      // 只在"还是我这条"时清（防止快切两条会话时把新的那条误清）
      if (WorkerNotifyPresence.instance.openConversationId == t.conversationId) {
        WorkerNotifyPresence.instance.openConversationId = '';
      }
    }
  }

  /// 切换页面（参数为**页面索引**：0 服务 / 1 订单 / 2 消息 / 3 我的 / 4 祁小山）
  void _switchTab(int pageIndex) {
    final next = pageIndex.clamp(pageServices, pageAi);
    if (next == pageAi) _aiMounted = true; // 首次切到 AI 才挂载（之后常驻）
    setState(() {
      _index = next;
      if (next != pageAi) _lastNonAiPage = next;
    });
    // 分支激活信号（值没变时 ValueNotifier 不会通知 → 连点当前 tab 不会被当成一次"重新进入"）
    _aiActive.value = next == pageAi;
    if (next == pageServices) _homeRefresh.value++;
  }

  /// 系统返回键（Android 物理/手势返回）
  ///
  /// AI 分支激活时 `canPop=false`（见 build 里的 PopScope）→ 这里把它当成"返回上一个 tab"；
  /// 其余分支 canPop=true → 走系统默认（根路由 = 退出 App）。
  void _onSystemBack(bool didPop, Object? result) {
    if (didPop) return;
    if (_index == pageAi) _switchTab(_lastNonAiPage);
  }

  /// 去下单（浮标 / 快捷面板底部主行动 / 分部卡）
  Future<void> _openOrderCreate(String? divisionId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ProductListPage(initialDivisionId: divisionId)),
    );
    if (mounted) _homeRefresh.value++;
  }

  /// 快捷入口面板（中间按钮**长按**）
  ///
  /// **面板 = 快捷方式**（去别处也能做的事的捷径），不计入「同一入口只出现一次」的判定
  /// （结构规则 1 的注解，见 `docs/14`）。
  ///
  /// 【2026-10-15 甲方案】第一项「找陪玩」已移除，`onFindPlayers` 参数也从 core 的
  /// `AppQuickActionsSheet` **整个删掉**（不留"永远没人传"的死参数）。
  /// 选 a 之前先 grep 过全部调用方：只有本文件与 `test/ai_entry_nav_test.dart`，两处均已同步。
  void _openQuickActions() {
    AppQuickActionsSheet.show(
      context,
      onMessages: () => _switchTab(pageMessages),
      onSupport: _openCustomerService,
      onOrder: () => _openOrderCreate(null),
    );
  }

  /// 找陪玩（负责人硬规则：只显示 名字 + 介绍；介绍由管理端填写）
  ///
  /// 页面里的「问祁小山」不再 push 一层 AI 页（那样底栏会被盖住）→ 把 [_switchTab] 当回调递下去，
  /// 由本页 pop 回 shell 后切到 AI 分支（底栏常驻）。
  Future<void> _openPlayers() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlayersPage()),
    );
  }

  Future<void> _openCustomerService() async {
    // 复用消息页内的客服会话（消息页负责拉取与创建会话），此处直接切到消息页
    _switchTab(pageMessages);
  }

  @override
  void dispose() {
    _aiActive.dispose();
    _homeRefresh.dispose();
    NavStyleController.instance.removeListener(_onNavStyleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([ThemeController.instance, AuthStore.instance]),
      builder: (context, _) {
        /**
         * 身份分支（合并双端 · 身份切换，方案甲；A+ 清单 TR-B/TR-C）：
         *
         * 打手态 **不是**"把老板页面藏起来"，而是**换掉整棵子树** —— 下面这段
         * `IdentityWorkerShell` 里根本没有服务页/订单页/AI/找陪玩/排行榜，
         * 于是老板态的未读轮询、WS 订阅、缓存刷新自然全部不跑（设计稿风险 ④/R3）。
         *
         * `AuthStore.workerIdentity` 只有在"身份标记 = worker **且** 本地确有 companion 令牌"
         * 时才为 true，因此老板态用户（从未绑定过）走的分支与改动前一模一样。
         *
         * 【2026-10-06 方案②】管理员态（充值审核）走同一条结构路线：
         * `RechargeAdminShell` 里**只有充值审核这一处**（+ 详情页），没有底栏、没有别的管理能力，
         * 老板端页面一个都不在这棵树里 —— 干净度是结构上保证的，不靠隐藏。
         *
         * 骨架替换动效（TR-B）：**淡入 260ms**（`Motion.itemEnter` 同档），
         * 不做横向滑动 —— 左右滑会给人"换了一个 App"的错觉，而这里只是同一 App 换了形态。
         * 底栏（5 项 ↔ 3 项 ↔ 无）随骨架一起淡化：项目数与位置同时变化，逐项动画反而显得乱。
         */
        final auth = AuthStore.instance;
        final Widget shell = auth.adminIdentity
            ? RechargeAdminShell(
                key: const ValueKey('recharge-admin-shell'),
                api: widget.identityApi,
              )
            : auth.workerIdentity
                ? IdentityWorkerShell(
                    key: const ValueKey('worker-shell'),
                    api: widget.identityApi,
                    openChat: openWorkerChat,
                  )
                : PopScope(
                    // AI 分支激活时拦下返回键（回上一个 tab）；其余分支放开（系统默认 = 退出 App）
                    canPop: _index != pageAi,
                    onPopInvokedWithResult: _onSystemBack,
                    child: Scaffold(
                      backgroundColor: T.scaffoldColor,
              // 玻璃底栏要能采样到身后内容 → 让 body 延伸到导航栏下方
              extendBody: NavStyleController.instance.glass,
                      body: IndexedStack(
                        index: _index,
                        children: [
                          ..._pages,
                          // 懒挂载占位：没进过 AI 分支时这里什么都还没有（不拉历史、不建实时订阅）
                          _aiMounted ? _aiPage : const SizedBox.shrink(),
                        ],
                      ),
                      bottomNavigationBar: AppBottomNav(
                        // 导航位索引（6 项平铺）与页面索引不同，必须换算；AI 分支 → 3
                        currentIndex: _pageToNav(_index),
                        onTap: (navIndex) => _switchTab(_navToPage(navIndex)),
                        // 导航位 1「下单」：push 既有「选择服务」页（带左侧导航栏的那个页面）
                        onCreateOrder: () => _openOrderCreate(null),
                        onCenterTap: () => _switchTab(pageAi),
                        onCenterLongPress: _openQuickActions,
                // 液态玻璃悬浮（用户可在「我的 → 外观」开关，默认关）
                glass: NavStyleController.instance.glass,
                      ),
                    ),
                  );
        return AnimatedSwitcher(
          duration: Motion.itemEnter,
          switchInCurve: Motion.emphasized,
          switchOutCurve: Motion.emphasized,
          transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
          child: shell,
        );
      },
    );
  }
}
