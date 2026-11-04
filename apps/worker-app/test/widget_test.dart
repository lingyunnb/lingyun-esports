import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/home_shell.dart';
import 'package:worker_app/pages/login_page.dart';

void main() {
  testWidgets('登录页：账号/密码/登录按钮（工作账号无注册入口）', (tester) async {
    await tester.pumpWidget(const _Wrap(child: LoginPage()));
    expect(find.text('祁连山电竞内部'), findsOneWidget);
    // 2026-10-05 改版（方案 B 品牌主视觉）：品牌区大标题也是「登录」→ 标题 + 按钮共两处
    expect(find.text('登录'), findsNWidgets(2), reason: '品牌区标题 + 主按钮');
    expect(find.byType(AppBrandHeader), findsOneWidget);
    expect(find.byKey(const Key('auth-submit')), findsOneWidget);
    expect(find.text('工作账号由管理员创建分配'), findsWidgets);
    expect(find.textContaining('注册'), findsNothing);
  });

  testWidgets('主框架：五个 tab 正常渲染并可切换', (tester) async {
    await tester.pumpWidget(const _Wrap(child: HomeShell()));
    for (final label in ['首页', '订单', '排行榜', '消息', '我的']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text('排行榜'));
    // 榜单/消息页含加载动画（无限动画），用有界 pump 代替 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('周榜'), findsOneWidget);
    // ApiClient 网络失败自动重试会挂 600ms 重试定时器（测试环境 HTTP 全部 400），收尾前排空
    await tester.pump(const Duration(milliseconds: 700));
  });
}

class _Wrap extends StatelessWidget {
  const _Wrap({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MaterialApp(home: child),
    );
  }
}
