import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 投诉口径（负责人 2026-10-05 任务②③）
///
/// 这份清单是**后端 `COMPLAINTABLE_ORDER_STATUSES` 的镜像**：
/// `server/src/modules/order/order-complaintable.ts`。两边不一致 = 投诉页会出现
/// "列表里能选、提交被服务端中文 400 拒绝"的割裂，所以这里把口径钉死成用例。
///
/// 用例只做两件事（都是客户端**必须**保证的，服务端权威判定另在后端侧）：
/// 1. 清单内容与顺序 —— 改后端同一个提交里必须改这里，改错立刻红
/// 2. 拼出的查询参数形状 —— 服务端 `OrderService.userOrders` 按逗号分隔解析
void main() {
  group('可投诉订单状态（与后端同源）', () {
    test('清单逐项对齐后端：仅这 5 个状态可投诉', () {
      expect(kComplaintableOrderStatuses, <String>[
        'taken',
        'in_progress',
        'pending_confirm',
        'completed',
        'after_sale',
      ]);
    });

    test('已取消（canceled）必须不在清单里 —— 负责人任务②的硬要求', () {
      expect(kComplaintableOrderStatuses.contains('canceled'), isFalse);
    });

    test('还没人接单（待接单/待确认派单）与平台裁决中（abnormal）也不可投诉', () {
      for (final s in const ['pending_take', 'pending_dispatch', 'abnormal']) {
        expect(kComplaintableOrderStatuses.contains(s), isFalse, reason: '$s 不应可投诉');
      }
    });

    test('已完成与售后中仍可投诉（服务已发生，追责窗口内）', () {
      expect(kComplaintableOrderStatuses.contains('completed'), isTrue);
      expect(kComplaintableOrderStatuses.contains('after_sale'), isTrue);
    });

    test('查询串 = 逗号分隔（服务端 userOrders 的解析格式），无空格、无空项', () {
      final q = complaintableOrderStatusQuery();
      expect(q, 'taken,in_progress,pending_confirm,completed,after_sale');
      expect(q.contains(' '), isFalse);
      expect(q.split(',').where((e) => e.isEmpty), isEmpty);
      expect(q.split(','), kComplaintableOrderStatuses);
    });
  });
}
