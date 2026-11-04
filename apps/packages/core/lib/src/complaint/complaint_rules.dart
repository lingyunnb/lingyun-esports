/// 投诉口径（与后端**同一份定义**，负责人 2026-10-05 任务②③）
///
/// ## 为什么放在 core
///
/// 「哪些订单能投诉」「哪些打手能投诉」是**业务口径**，不是某个页面的排版细节：
/// 老板端投诉页要用它拼查询参数。放在 core 是为了让两端/多页共用一份，禁止在各页面里
/// 各写一份字面量数组（那样改后端就会漏改前端，出现"列表能选、提交被拒"的割裂）。
///
/// ## 与后端的关系（谁说了算）
///
/// - **后端是唯一权威**：`server/src/modules/order/order-complaintable.ts` 的
///   `COMPLAINTABLE_ORDER_STATUSES` + `ComplaintService.create` 里的中文 400 校验，
///   才是有权放行/拒绝的地方。
/// - 这里的清单**只用于拼 `GET /user/orders?status=...` 的查询参数**（让列表本身就不下发
///   不可投诉的单，避免"看得到却点不动"）。即便客户端被改坏，服务端仍会拒绝非法提交。
/// - 两边状态码必须逐字一致：改后端那个文件时，**同一个提交里**也要改这里。
library;

/// 可投诉订单状态（后端 `COMPLAINTABLE_ORDER_STATUSES` 的镜像）
///
/// - 列入：`taken` 已接单 / `in_progress` 进行中 / `pending_confirm` 待用户确认 /
///   `completed` 已完成 / `after_sale` 售后中 —— 都是"服务已由某位打手承接"的状态
/// - 排除：`pending_take`、`pending_dispatch`（还没人接单，没有可追责对象）、
///   `canceled`（**负责人明确要求：已取消的单不显示、不能投诉**）、
///   `abnormal`（平台裁决中，另有处置通道）
const List<String> kComplaintableOrderStatuses = <String>[
  'taken',
  'in_progress',
  'pending_confirm',
  'completed',
  'after_sale',
];

/// 拼给 `GET /user/orders?status=` 的逗号分隔串（服务端支持多状态过滤）
String complaintableOrderStatusQuery() => kComplaintableOrderStatuses.join(',');
