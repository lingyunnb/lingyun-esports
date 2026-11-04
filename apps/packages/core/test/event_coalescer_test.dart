/// **事件合并窗口**钉死（2026-10-15 聊天实时接收优化）
///
/// 硬要求：**200ms 内的连续多条事件 → 只触发 1 次 UI 更新**。
///
/// 为什么是"首次事件起算的固定窗口"而不是尾随防抖：微信式连发（每 150ms 一条）在尾随防抖下
/// 会一直不刷新（每次新事件都把定时器往后推）→ 列表长时间不动。固定窗口保证"最坏 200ms 一定刷"。
///
/// 时钟口径：用 `testWidgets` 的**假时钟**（`tester.pump(Duration)` 推进定时器），
/// 不用真实等待 —— 200ms 的窗口在真时钟下既慢又易抖。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('200ms 内的连续 3 次 add → 只回调 1 次（且不是 3 次）', (WidgetTester tester) async {
    int flushed = 0;
    final EventCoalescer c = EventCoalescer(onFlush: () => flushed += 1);
    addTearDown(c.dispose);

    c.add();
    await tester.pump(const Duration(milliseconds: 60));
    c.add();
    await tester.pump(const Duration(milliseconds: 60));
    c.add();
    expect(flushed, 0, reason: '窗口没到之前一次都不许刷（这就是"合并"）');

    await tester.pump(const Duration(milliseconds: 100));
    expect(flushed, 1, reason: '200ms 窗口结束时**恰好一次** UI 更新');
    expect(c.addCount, 3);
    expect(c.flushCount, 1);
  });

  testWidgets('跨越窗口的两批事件 → 各刷一次（不吞事件）', (WidgetTester tester) async {
    int flushed = 0;
    final EventCoalescer c = EventCoalescer(onFlush: () => flushed += 1);
    addTearDown(c.dispose);

    c.add();
    c.add();
    await tester.pump(const Duration(milliseconds: 250));
    expect(flushed, 1);

    c.add();
    await tester.pump(const Duration(milliseconds: 250));
    expect(flushed, 2);
  });

  testWidgets('flushNow（用户主动路径）立刻结算，不等窗口', (WidgetTester tester) async {
    int flushed = 0;
    final EventCoalescer c = EventCoalescer(onFlush: () => flushed += 1);
    addTearDown(c.dispose);

    c.add();
    c.flushNow();
    expect(flushed, 1, reason: '下拉刷新这类主动动作必须立刻生效');
    await tester.pump(const Duration(milliseconds: 500));
    expect(flushed, 1, reason: '结算过的窗口不许再补一次');
  });

  testWidgets('空窗口不回调；dispose 后不再回调（页面销毁不残留定时器）', (WidgetTester tester) async {
    int flushed = 0;
    final EventCoalescer c = EventCoalescer(onFlush: () => flushed += 1);

    await tester.pump(const Duration(milliseconds: 500));
    expect(flushed, 0);

    c.add();
    expect(c.hasPending, isTrue);
    c.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(flushed, 0, reason: 'dispose 之后不许再碰 setState');
  });
}
