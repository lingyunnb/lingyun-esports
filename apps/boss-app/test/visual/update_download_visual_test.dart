import 'dart:io';
import 'dart:ui' as ui;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「云更新下载中」出图（2 张，390×844 @2x）：验证弹窗在**下载中**同时显示
/// 百分比 + 实时速度（MB/s）+ 预计剩余时间 + 「多连接加速」标注。
///
/// 复用既有出图测试的三个坑与解法：
/// 1. 测试环境无 CJK 字形 → `FontLoader` 挂 `C:/Windows/Fonts/msyh.ttc`（放最前，标点覆盖最广）
/// 2. 测试环境无 Material 图标字形 → 另挂 `materialicons-regular.otf`
/// 3. `ThemeData(fontFamily:)` 改不动 `textTheme` → 再 `textTheme.apply(fontFamily:)` 一遍
void main() {
  const cjkFamily = 'UpdateShotCJK';
  const shotKey = Key('update-shot');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final String path in const <String>[
      r'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      r'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      await (FontLoader('MaterialIcons')
            ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync()))))
          .load();
      break;
    }
    // msyh 放最前：中文与 `·`/`…` 这类标点都靠它
    for (final String path in const <String>[
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      await (FontLoader(cjkFamily)
            ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync()))))
          .load();
    }
  });

  Future<void> shoot(WidgetTester tester, String name, Widget child) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          // 用**真实 App 主题**（buildAppTheme）：进度条等 Material 组件取的是
          // colorScheme.primary，不用真主题就会出默认紫，截图与真机不一致
          theme: () {
            final ThemeData base = buildAppTheme();
            return base.copyWith(textTheme: base.textTheme.apply(fontFamily: cjkFamily));
          }(),
          home: Scaffold(backgroundColor: AppColors.bgPage, body: Center(child: child)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final RenderRepaintBoundary b = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final ui.Image img = await b.toImage(pixelRatio: 2);
      final ByteData? bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      img.dispose();
    });
  }

  AppUpdateInfo info() => const AppUpdateInfo(
        hasUpdate: true,
        force: false,
        versionCode: 76,
        versionName: '1.11.19',
        updateDesc: '添加好友界面全新改版（边输边搜、状态一目了然）；投诉只能选接过我单的打手；下线玩家圈',
        fileSize: 27368751,
        fileHash: 'b945830f10c0af47084b17a2afcef9bc00f885d5dc0718ff461d8f7c1fec2ddd',
        downloadUrl: 'http://127.0.0.1:3100/api/v1/public/app-versions/download/99',
      );

  testWidgets('出图 ① 更新弹窗·下载中（百分比 + 实时速度 + 剩余时间 + 多连接加速）', (WidgetTester tester) async {
    UpdateCenter.instance.configure('boss');
    // 用测试专用的"进度注入"把弹窗置成下载中（不打真实网络）
    UpdateCenter.instance.debugSetProgressForShot(
      downloaded: 14 * 1024 * 1024,
      total: 27368751,
      speedBytesPerSecond: 4.1 * 1024 * 1024,
      parallel: true,
    );
    await shoot(tester, 'update_downloading.png', UpdateDialog(info: info()));
    UpdateCenter.instance.reset();
  });

  testWidgets('出图 ② 更新弹窗·下载中（弱网：低速 + 并行回退后单连接）', (WidgetTester tester) async {
    UpdateCenter.instance.configure('boss');
    UpdateCenter.instance.debugSetProgressForShot(
      downloaded: 3 * 1024 * 1024,
      total: 27368751,
      speedBytesPerSecond: 0.42 * 1024 * 1024,
      parallel: false,
    );
    await shoot(tester, 'update_downloading_slow.png', UpdateDialog(info: info()));
    UpdateCenter.instance.reset();
  });
}
