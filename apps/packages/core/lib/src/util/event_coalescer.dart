/// 实时事件的**合并窗口**（2026-10-15 聊天实时接收优化）
///
/// 问题现场：服务端在"一条消息落到会话房间 → 我在房间里"时会同时推 `msg:new`（房间广播）
/// 与 `unread:update`（`uid:` 单播）；再叠上 `msg:acK`/`msg:read` 等事件，
/// 一次"对方发了一句话"在客户端常常是 **2–3 个回调**。此前每个回调各自 `setState`，
/// 于是列表被重建 2–3 次、输入框与滚动位置连续抖动。
///
/// 本类把「200ms 内的连续事件」并成**一次** UI 更新（首次事件起算的固定窗口，不是尾随防抖 ——
/// 尾随防抖在"每 150ms 来一条"的持续流量下会一直不刷新）。
///
/// 语义边界（三条）：
///   1. **纯 Dart**：只依赖 `Timer`，不依赖 Flutter，可单测（见 `event_coalescer_test.dart`）；
///   2. **不吞数据**：合并的是"刷新动作"，事件本身由调用方在 `add()` 之前就合进状态了
///      （所以 3 条消息一条都不会丢，只是共用一帧渲染）；
///   3. **用户主动路径不走它**：下拉刷新、进入页面、事件要求强校验（会话被删/结束）一律
///      `flushNow()` 或直接调用原方法 —— 合并窗口只服务"服务端主动推来的高频事件"。
library;

import 'dart:async';

class EventCoalescer {
  EventCoalescer({
    this.window = const Duration(milliseconds: 200),
    required this.onFlush,
  });

  /// 合并窗口（默认 200ms；测试可注入更短的值）
  final Duration window;

  /// 窗口结束时的回调（页面在这里做唯一那次 `setState`）
  final void Function() onFlush;

  Timer? _timer;
  int _pending = 0;

  /// 已发生的合并刷新次数（自检/测试用）
  int flushCount = 0;

  /// 累计收到的合并请求次数（自检/测试用）
  int addCount = 0;

  /// 是否有一批事件正在等待合并刷新
  bool get hasPending => _pending > 0;

  /// 记一次"需要刷新"；窗口内重复调用只会在窗口结束时触发一次 [onFlush]
  void add() {
    addCount += 1;
    _pending += 1;
    _timer ??= Timer(window, _flush);
  }

  /// 立刻结算（用户主动路径：下拉刷新等，不等窗口）
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    _flush();
  }

  void _flush() {
    _timer = null;
    if (_pending <= 0) return;
    _pending = 0;
    flushCount += 1;
    onFlush();
  }

  /// 丢弃窗口内待处理的动作（页面 dispose）
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = 0;
  }
}
