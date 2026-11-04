import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务端时间探测（`NetworkTime`）· 纯函数与降级契约（2026-10-06 工作端到期自动阻断专项）
///
/// 只测"不需要网络"的部分：**解析规则**与**取不到就回退**（返回 null，绝不抛异常）。
/// 消费方（工作端阻断页）的"取不到 → 用本地时间"整链路在
/// `apps/worker-app/test/worker_sunset_deadline_test.dart` 断言。
void main() {
  setUp(NetworkTime.resetCache);
  tearDown(NetworkTime.resetCache);

  group('HTTP Date 头解析', () {
    test('标准 RFC 1123 时间 → 设备本地时区（与 DateTime.now() 同口径）', () {
      final DateTime? t = NetworkTime.parseDateHeader('Tue, 13 Oct 2026 00:00:00 GMT');
      expect(t, isNotNull);
      expect(t!.toUtc(), DateTime.utc(2026, 10, 13));
      expect(t.isUtc, isFalse, reason: '必须转本地时区，否则与本地时间比较会差一个时区偏移');
      expect(t, DateTime(2026, 10, 13, 8), reason: 'UTC+8 下 GMT 00:00 == 本地 08:00');
    });

    test('取不到 / 不是 Date → 一律返回 null（调用方据此回退本地时间）', () {
      expect(NetworkTime.parseDateHeader(null), isNull);
      expect(NetworkTime.parseDateHeader(''), isNull);
      expect(NetworkTime.parseDateHeader('   '), isNull);
      expect(NetworkTime.parseDateHeader('not-a-date'), isNull);
      expect(NetworkTime.parseDateHeader('2026-10-13T00:00:00Z'), isNull, reason: 'ISO 格式不是 HTTP Date');
      expect(NetworkTime.parseDateHeader('Mon, 13 Oct 2026 00:00 GMT'), isNull, reason: '缺秒不符合 RFC 1123');
      // 注意（实测）：`HttpDate.parse` 对"日号越界"是**宽容**的 ——
      // 'Mon, 32 Oct 2026 …' 会被它滚成 11-01 而不是抛错。所以这里不拿它当"非法输入"，
      // 只钉住真正解析不了的形状（上面那几种）。该宽容行为不影响本用途：
      // 判断的是"有没有到某个日期"，滚一天的极端输入也不会把已到期的设备放行。
      expect(NetworkTime.parseDateHeader('Mon, 32 Oct 2026 00:00:00 GMT'), isNotNull);
    });
  });

  group('探测开关与缓存（不影响产线口径，只影响"探几次"）', () {
    test('探测路径是公开的 /health（不消耗业务配额、不需要登录态）', () {
      expect(NetworkTime.probePath, '/health');
    });

    test('缓存时长可关（Duration.zero = 每次都真探；测试与将来的实时需求都用得上）', () {
      expect(NetworkTime.cacheTtl, greaterThan(Duration.zero), reason: '默认 10 分钟：判定的是"日期"，够用');
      NetworkTime.cacheTtl = Duration.zero;
      NetworkTime.resetCache();
      expect(NetworkTime.cacheTtl, Duration.zero);
      NetworkTime.cacheTtl = const Duration(minutes: 10);
    });
  });
}
