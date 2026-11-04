import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工作端云端更新接入（负责人需求：与老板端同等能力）
///
/// 更新窗口/阻断页来自 fish_core（双端共用），本测试确认工作端能正常接入这层共享实现，
/// 且工作端声明的是 **worker** 通道（不会去装老板端 APK）。
void main() {
  test('工作端配置 worker 通道；非法类型被拒绝', () {
    UpdateCenter.instance.configure('worker');
    expect(UpdateCenter.instance.appType, 'worker');
    expect(() => UpdateCenter.instance.configure('boss_app'), throwsArgumentError);
  });

  testWidgets('更新弹窗在工作端环境下正常渲染', (tester) async {
    UpdateCenter.instance.configure('worker');
    const info = AppUpdateInfo(
      hasUpdate: true,
      force: false,
      versionCode: 11,
      versionName: '1.0.9',
      updateDesc: '打手端支持小数积分（钻皮·刀 5.5）',
      fileSize: 19618949,
      fileHash: 'abc',
      downloadUrl: 'http://example.com/worker.apk',
    );
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateDialog(info: info))));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v1.0.9'), findsOneWidget);
    expect(find.textContaining('5.5'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
  });

  testWidgets('强制更新阻断页在工作端环境下正常渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpdateBlockPage()));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);
  });
}
