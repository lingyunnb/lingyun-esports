import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';


import 'home_page.dart';
import 'leaderboard_page.dart';
import 'messages_page.dart';
import 'orders_page.dart';
import 'profile_page.dart';

/// 工作端主框架：首页 / 订单 / 排行榜 / 消息 / 我的（IndexedStack 保留各页状态）
/// 2026-09-25：底部导航与老板端统一 —— 玻璃胶囊 + miuix 导航
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.api});

  /// 接口客户端（缺省 null = 各页自建；测试/出图注入 fixture，与 HomePage/OrdersPage 同一约定）
  final ApiClient? api;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// 首页刷新信号（切回首页 tab 时递增 → 工作台重新拉取）
  final ValueNotifier<int> _homeRefresh = ValueNotifier<int>(0);

  /// 消息未读角标（会话列表未读合计）
  final int _messageBadge = 0;

  late final List<Widget> _pages = [
    HomePage(onNavigate: _switchTab, refreshSignal: _homeRefresh, api: widget.api),
    OrdersPage(api: widget.api),
    const LeaderboardPage(),
    MessagesPage(api: widget.api),
    ProfilePage(onNavigate: _switchTab, api: widget.api),
  ];

  void _switchTab(int i) {
    setState(() => _index = i);
    if (i == 0) _homeRefresh.value++;
  }

  @override
  void dispose() {
    _homeRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: _buildNavBar(),
    );
  }

  /// 底部导航（与老板端统一：标准 Flutter 复刻的玻璃胶囊 + 滑动药丸指示器）
  Widget _buildNavBar() {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => AppPlainBottomNav(
        currentIndex: _index,
        onTap: _switchTab,
        badgeIndex: 3,
        badge: _messageBadge,
        items: const [
          (label: '首页', icon: AppIcon.services, active: AppIcon.servicesFill),
          (label: '订单', icon: AppIcon.orders, active: AppIcon.ordersFill),
          (label: '排行榜', icon: AppIcon.rank, active: AppIcon.rank),
          (label: '消息', icon: AppIcon.messages, active: AppIcon.messagesFill),
          (label: '我的', icon: AppIcon.mine, active: AppIcon.mineFill),
        ],
      ),
    );
  }

}
