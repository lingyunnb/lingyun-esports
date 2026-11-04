/// 聊天页头两个动作图标：**画出来 24dp、触摸区 48×56**
///
/// ## 依据
/// 负责人 2026-10-18 真机（客服会话页「祁连山客服」）：截图圈出返回箭头 `←` 与右上角
/// `● ● ●`「明显过大，跟标题严重失衡」。
///
/// ## 当时的真实原因（不是"size 传大了"，而是**被触摸盒撑大**）
/// 旧实现是 `SizedBox(44×56, child: AppIcon.of(..., size: 21))`：
/// `SizedBox` 给子节点的是**紧约束**，而 `AppIcon` 内部是
/// `SizedBox.fromSize(Size.square(size))` —— `BoxConstraints.enforce` 会把 21×21
/// 抬成父给的 44×56，于是 `CustomPaint` 画在 44×56 上，`AppIconPainter` 按
/// `shortestSide / viewBox(24)` 缩放 → **实际画出来 ≈ 输入值的 1.83 倍**
/// （返回箭头 ≈26dp、three-dot ≈29dp），而标题只有 15.5。
///
/// ## 本条测试钉住的三件事（顺序即重要性）
/// 1. 图标**自身的盒子**就是 24×24（被撑大时这里是 44×56 → 直接红）
/// 2. 触摸盒 **48×56**（可点范围不缩反扩：原 44 宽 → 48 宽）
/// 3. 在触摸盒**最左 4dp 处**点一下仍然触发返回（证明 48 是**可点**的，不只是画了个框）
library;

import 'package:boss_app/widgets/chat_v4.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHeader(
    WidgetTester tester, {
    VoidCallback? onBack,
    VoidCallback? onMore,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatV4Header(
          nickname: '祁连山客服',
          statusText: '在线客服 · 平均 1 分钟回复',
          onBack: onBack,
          onMore: onMore,
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('图标画出来 24dp（没被 48×56 的触摸盒撑大）', (tester) async {
    await pumpHeader(tester);

    // ① 图标自身尺寸 = 24×24（修前：44×56 —— 就是"明显过大"的根因）
    expect(tester.getSize(find.byKey(ChatV4Metrics.backIconKey)), const Size(24, 24),
        reason: '返回箭头必须按 24dp 画；44×56 说明又被触摸盒撑大了');
    expect(tester.getSize(find.byKey(ChatV4Metrics.moreIconKey)), const Size(24, 24),
        reason: 'three-dot 必须按 24dp 画（与返回箭头同一个数，不许一大一小）');

    // 24 是项目图标四档 {16,20,24,28} 里的一档（docs/32 §五）
    expect(ChatV4Metrics.headerActionIcon, 24);
    expect(ChatV4Metrics.headerActionIcon, greaterThan(15.5),
        reason: '页头动作图标要略大于 15.5 的标题，但不能失控（负责人 2026-10-18）');
  });

  testWidgets('触摸区 48×56：图标变小、可点范围不缩（原 44 宽 → 48 宽）', (tester) async {
    await pumpHeader(tester);

    expect(tester.getSize(find.byKey(ChatV4Metrics.backTouchKey)), const Size(48, 56),
        reason: '可点范围 ≥48（Material 最小可点）；高度吃满页头 56');
    expect(tester.getSize(find.byKey(ChatV4Metrics.moreTouchKey)), const Size(48, 56));
    expect(ChatV4Metrics.headerActionTouch, greaterThanOrEqualTo(48),
        reason: '硬约束：触摸区不许小于 48');
  });

  testWidgets('触摸盒边缘（最左 4dp / 最右 4dp）仍然点得动', (tester) async {
    var back = 0;
    var more = 0;
    await pumpHeader(tester, onBack: () => back++, onMore: () => more++);

    final backBox = tester.getRect(find.byKey(ChatV4Metrics.backTouchKey));
    // 最左 4dp：离图标本体（居中 24，左边界距盒子左边 12）还有 8dp 余量 → 只有触摸面真的占满 48 才会命中
    await tester.tapAt(Offset(backBox.left + 4, backBox.center.dy));
    await tester.pump();
    expect(back, 1, reason: '左侧 4dp 处必须在 48 的触摸面内');

    final moreBox = tester.getRect(find.byKey(ChatV4Metrics.moreTouchKey));
    await tester.tapAt(Offset(moreBox.right - 4, moreBox.center.dy));
    await tester.pump();
    expect(more, 1, reason: '右侧 4dp 处必须在 48 的触摸面内');
  });

  testWidgets('标题不被挤：360 宽下「祁连山客服」完整显示、不省略', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await pumpHeader(tester, onBack: () {}, onMore: () {});

    final title = tester.widget<Text>(find.text('祁连山客服'));
    expect(title.overflow, TextOverflow.ellipsis, reason: '兜底仍是省略号（长名字不溢出）');
    expect(title.maxLines, 1);
    // 名字实际占位必须比可用宽度窄（真的没被两个 48 的触摸盒挤到）
    final titleRect = tester.getRect(find.text('祁连山客服'));
    expect(titleRect.width, lessThan(360 - 48 - 32 - 10 - 48 - 4),
        reason: '标题可用宽度 = 屏宽 − 左 48 − 头像 32 − 间距 10 − 右 48 − 页边 4');
  });
}
