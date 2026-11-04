import 'package:boss_app/pages/notification_page.dart';
import 'package:boss_app/pages/profile_page.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统通知可达性测试（2026-10-05 新增）
///
/// 背景（本轮修掉的真实缺陷）：服务页顶部「公告」原先打开的是 **系统通知**页
/// （`NotificationPage`），而它**唯一**的入口就是那一个按钮。把「公告」修正为真公告列表后，
/// 若不给系统通知另加入口，这个功能就彻底不可达了 —— 所以「我的」页补了一行「系统通知」。
///
/// 本测试锁死两件事：
/// 1. 「我的」页确实有「系统通知」入口（不是只写在注释里）
/// 2. 点它能**真的打开** `NotificationPage`（标题「系统通知」出现 + 有「全部已读」动作）
void main() {
  setUp(() {
    RealtimeClient.shared.debugDisabled = true; // 测试环境不建 WS 连接（与既有测试一致）
    AppSettings.debugStorageDisabled = true;
    // ProfilePage 在 me == null 时只渲染「加载中…」，必须先注入会话
    AuthStore.instance.debugSetSession(
      accessToken: 'test-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'boss01',
        'uid': 'zh10001',
        'nickname': '测试老板',
        'role': 'user',
        'level': 2,
        'totalSpent': 120.5,
      }),
    );
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  testWidgets('我的页：「系统通知」入口存在，且点击能打开通知页', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pumpAndSettle();

    // 2026-10-06（身份合并）：身份分组按 A+ 稿上移到资料头正下方，页面整体更长，
    // 800×600 的测试视口里「常用」区**还没被构建**（ListView 只构建可见子项）→
    // 必须先用 scrollUntilVisible 滚到它出现，再做存在性断言（真机上本来就是滑一下的事）。
    await tester.scrollUntilVisible(
      find.text('系统通知'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 1) 入口存在：标题 + **入口图标** 定位
    //    （2026-10-17 ⑦：这一格原来还有一行副标「好友申请与账号提醒」，
    //      属注释型浅色小字，已按负责人要求删除 → 断言改为按图标锚定，语义不降级）
    expect(find.text('系统通知'), findsOneWidget, reason: '「我的」页必须有系统通知入口，否则公告入口修正后通知功能不可达');
    expect(find.byIcon(AppIcon.bell), findsOneWidget, reason: '系统通知入口图标（服务宫格唯一一枚 bell）');
    expect(find.text('好友申请与账号提醒'), findsNothing, reason: '2026-10-17 ⑦：注释型小字必须已删');

    // 2) 点击后真的进入 NotificationPage：出现页面标题与「全部已读」动作
    await tester.tap(find.text('系统通知'));
    await tester.pumpAndSettle();

    expect(find.byType(NotificationPage), findsOneWidget,
        reason: '点击「系统通知」必须导航到 NotificationPage（而不是别的页）');
    expect(find.text('全部已读'), findsOneWidget);
    expect(find.text('系统通知'), findsOneWidget); // 通知页自己的标题栏
  });
}
