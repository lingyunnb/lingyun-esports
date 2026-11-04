// 编辑资料 · 方案 G 版面回归（负责人 2026-10-17：「我的 › 编辑资料」太丑 → 纯视觉重构 + 信息分组）
// ============================================================================
//
// 本文件钉两件事，**都不碰功能**：
//   ① 源码级：**注释型浅色小字已删**（`helperText` 归零）、**功能性限制保留**
//      （ID 行右侧 `24h 限 3 次`）、零硬编码色值 / 零阴影 / 零渐变 / 零裸 `Icons.` / 零 emoji；
//   ② 渲染面：页底 `#F6F7F9`、两张分组卡（白底 + 1px `#E8ECF2` + 圆角 12 + 零阴影）、
//      行标签定宽 72、字数计数 `N/上限`（满额转警示色）、底部固定「保存」高 48 + 主色实底 + 白字、
//      校验失败走**行内**红字且**不出现全屏转圈**。
//
// 为什么断言这么写：
//   - 版面数字（52 / 72 / 48 / 12）是**定案常量**，所以既在源码里断言常量本身，
//     也在渲染面用 `getSize` 实测（"常量改了但没生效"和"生效了但不是这个数"都能抓到）；
//   - 既有用例（`upload_progress_test.dart`）按 `find.byIcon(Icons.camera_alt)` 与
//     `find.text('更换个人背景')` 点击，本文件再断言这两处**仍然存在** —— 重构没有换掉交互入口；
//   - 换头像/背景的上传链路（压缩参数、进度、失败重试）由 `upload_progress_test.dart` 全量守着，
//     本文件不重复测（同一规则只有一份用例）。
import 'dart:io';

import 'package:boss_app/pages/edit_profile_page.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const String relPath = 'apps/boss-app/lib/pages/edit_profile_page.dart';

  /// 方案 G 卡片/主按钮圆角（与「我的」页 `_cardRadius` 同源）
  const double cardRadius = 12;

  // ==========================================================================
  // ① 源码级
  // ==========================================================================
  group('源码级：小字已删 · 限制保留 · 零硬编码', () {
    late String src;

    /// **代码面**（剥掉 `//` 注释）：反向断言一律看这里 ——
    /// 文件头的说明里会写「原来那三处 helperText 已删」，注释里出现这个词是**记录**，
    /// 不是"还在用小字"，所以不能拿整份源码当判据。
    late String code;
    setUpAll(() {
      src = File('${resolveRepoRoot()}/$relPath').readAsStringSync();
      code = _stripComments(src);
    });

    test('注释型浅色小字 0：代码面不再有 helperText', () {
      expect(code.contains('helperText'), isFalse,
          reason: '字段下方的解释性小字已按负责人要求删除（只留 token 与功能性读数）');
    });

    test('功能性限制保留：ID 行的「24h 限 3 次」是一条真实限制，不是注释小字', () {
      expect(src.contains('_uidQuotaHint'), isTrue, reason: '限制文案收敛成一个常量（只有一份）');
      expect(src.contains('24h 限 3 次'), isTrue, reason: '24 小时内最多改 3 次必须仍然可见');
    });

    test('零硬编码色值 · 零阴影 · 零渐变 · 零裸 Icons.', () {
      expect(RegExp(r'Color\(0x').hasMatch(code), isFalse, reason: '颜色一律走 token');
      expect(code.contains('BoxShadow'), isFalse, reason: '方案 G：卡片零阴影（阴影只给弹层）');
      expect(code.contains('LinearGradient'), isFalse, reason: '方案 G：零渐变');
      expect(RegExp(r'(?<![A-Za-z0-9_])Icons\.').hasMatch(code), isFalse, reason: '图标一律 AppIcon 体系');
    });

    test('emoji 0（含注释）', () {
      final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]', unicode: true);
      expect(emoji.hasMatch(src), isFalse, reason: '图标一律线性 AppIcon，注释里也不带 emoji');
    });

    test('页底 / 卡片描边 / 行高 / 标签宽 走方案 G 定案常量', () {
      expect(src.contains('AppColors.bgPageG'), isTrue, reason: '页底 #F6F7F9 走 token（不写字面量）');
      expect(src.contains('AppColors.strokeSoft'), isTrue, reason: '卡片 1px 描边 #E8ECF2 走 token');
      expect(src.contains('static const double _rowHeight = 52;'), isTrue, reason: '行高 52');
      expect(src.contains('static const double _labelWidth = 72;'), isTrue, reason: '左标签定宽 72');
    });
  });

  // ==========================================================================
  // ② 渲染面
  // ==========================================================================
  group('渲染面：方案 G 版面骨架', () {
    setUp(() {
      AppSettings.debugStorageDisabled = true;
      AuthStore.debugStorageDisabled = true;
      RealtimeClient.shared.debugDisabled = true;
      AppToast.dismiss();
      AuthStore.instance.debugClearIdentity();
      AuthStore.instance.debugSetSession(
        accessToken: 'primary-token',
        me: AuthMe.fromJson(const <String, dynamic>{
          'id': '1',
          'username': 'ayuan',
          'uid': 'U8471209365',
          'nickname': '阿远',
          'role': 'user',
          'level': 1,
        }),
      );
    });

    tearDown(() {
      AppToast.dismiss();
      AuthStore.instance.debugClearIdentity();
      AuthStore.instance.debugSetSession();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: EditProfilePage()));
      await tester.pump(const Duration(milliseconds: 40));
    }

    testWidgets('页底 = AppColors.bgPageG（#F6F7F9，白卡才浮得起来）', (tester) async {
      await pumpPage(tester);
      expect(
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == AppColors.bgPageG),
        findsOneWidget,
      );
    });

    testWidgets('按语义分 2 张卡：白底 + 1px strokeSoft 描边 + 圆角 12 + 零阴影', (tester) async {
      await pumpPage(tester);
      final cards = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final d = c.decoration;
            return d is BoxDecoration && d.borderRadius == BorderRadius.circular(cardRadius);
          })
          .toList();
      expect(cards, hasLength(2), reason: '卡 1 资料（昵称 + 展示 ID）· 卡 2 图片（个人背景），不堆成一张大表');
      for (final card in cards) {
        final d = card.decoration! as BoxDecoration;
        expect(d.color, AppColors.bgCard, reason: '白底');
        expect(d.boxShadow, isNull, reason: '方案 G：卡片零阴影');
        final border = d.border! as Border;
        expect(border.top.color, AppColors.strokeSoft, reason: '1px #E8ECF2 描边');
        expect(border.top.width, 1);
      }
    });

    testWidgets('三个行标签都定宽 72（左缘与输入起点对齐）', (tester) async {
      await pumpPage(tester);
      for (final label in <String>['昵称', '展示 ID', '个人背景']) {
        expect(find.text(label), findsOneWidget, reason: '「$label」行必须存在');
        expect(tester.getSize(find.text(label)).width, 72, reason: '「$label」标签定宽 72');
      }
    });

    testWidgets('字数计数 N/上限（11px 弱色）+ ID 行右侧「24h 限 3 次」', (tester) async {
      await pumpPage(tester);
      expect(find.text('2/32'), findsOneWidget, reason: '昵称「阿远」= 2 字');
      expect(find.text('11/20'), findsOneWidget, reason: '展示 ID `U8471209365` = 11 位');
      expect(find.text('24h 限 3 次'), findsOneWidget, reason: '真实限制只作为该行右侧读数');

      final counter = tester.widget<Text>(find.text('2/32'));
      expect(counter.style!.fontSize, 11, reason: '计数 11px');
      expect(counter.style!.color, AppColors.mutedText, reason: '未满额 = 弱色（不是警示色）');
    });

    testWidgets('计数满额转警示色', (tester) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField).first, List<String>.filled(32, '字').join());
      await tester.pump();
      final full = tester.widget<Text>(find.text('32/32'));
      expect(full.style!.color, AppColors.warning, reason: '满额 = 警示色');
    });

    testWidgets('渲染面零注释型小字（原三处 helperText 一句都不再出现）', (tester) async {
      await pumpPage(tester);
      for (final gone in <String>[
        '1-32 字',
        '2-20 位中文/字母/数字/下划线',
        '其他用户通过此 ID 搜索你；24 小时内最多修改 3 次',
      ]) {
        expect(find.textContaining(gone), findsNothing, reason: '「$gone」是注释型小字，已删');
      }
    });

    testWidgets('底部固定「保存」：高 48 + 主色实底 + 白字', (tester) async {
      await pumpPage(tester);
      final label = find.text('保存');
      expect(label, findsOneWidget);
      expect(tester.getSize(label).height, lessThanOrEqualTo(48));

      final outer = tester.getSize(find.ancestor(of: label, matching: find.byType(SizedBox)).first);
      expect(outer.height, 48, reason: '按钮高 48（离底 16 安全区）');

      final button = tester
          .widgetList<Material>(find.ancestor(of: label, matching: find.byType(Material)))
          .firstWhere((m) => m.color == AppColors.primary);
      expect(button.color, AppColors.primary, reason: '主色实底（不做渐变）');
      expect(button.borderRadius, BorderRadius.circular(cardRadius), reason: '圆角 12，与卡片同档');

      expect(tester.widget<Text>(label).style!.color, Colors.white, reason: '白字');
    });

    testWidgets('校验失败：行内警示色红字（不弹浮层、不出现全屏转圈）', (tester) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(find.text('0/32'), findsOneWidget, reason: '清空后计数归零');

      await tester.tap(find.text('保存'));
      await tester.pump();

      final error = tester.widget<Text>(find.text('昵称不能为空'));
      expect(error.style!.color, AppColors.error, reason: '行内 11px 警示色');
      expect(error.style!.fontSize, 11.5);
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '保存失败/校验阶段都不许转圈');
    });

    testWidgets('换头像入口未动：72dp 头像 + 22dp 主色相机角标（既有用例的点击目标仍在）', (tester) async {
      await pumpPage(tester);
      expect(tester.getSize(find.byType(AppAvatar)), const Size(72, 72), reason: '头像 72dp 圆形');

      final badge = tester.widgetList<Container>(find.byType(Container)).firstWhere((c) {
        final d = c.decoration;
        return d is BoxDecoration && d.shape == BoxShape.circle && d.color == AppColors.primary;
      });
      expect(tester.getSize(find.byWidget(badge)), const Size(22, 22), reason: '角标 22dp 主色圆');

      // 既有用例（upload_progress_test ① / ③）就是按这两处点击的：断言它们仍在
      expect(find.byIcon(Icons.camera_alt), findsOneWidget, reason: '相机角标 = 换头像入口');
      expect(find.text('更换个人背景'), findsOneWidget, reason: '背景动作行文案与改版前逐字相同');
    });
  });
}

/// 剥掉行注释（`//`；不含 `://`）—— 反向断言只看**代码面**（与 `page_deco_*` 同一套做法：
/// 注释里允许记录"某写法已删"，那不是违规）。
String _stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    final match = RegExp(r'(^|\s)//').firstMatch(raw);
    if (match == null) {
      out.add(raw);
    } else {
      final cut = raw[match.start] == '/' ? match.start : match.start + 1;
      out.add(raw.substring(0, cut));
    }
  }
  return out.join('\n');
}
