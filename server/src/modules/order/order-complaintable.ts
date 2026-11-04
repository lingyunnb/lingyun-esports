import { OrderStatus } from './order.entity';

/**
 * 可投诉订单状态（**全站唯一口径**，负责人 2026-10-05 任务②）
 *
 * ## 为什么需要这份常量
 *
 * 投诉页此前把 `GET /user/orders` 的**全部**订单（分页前 20 条）直接当候选，
 * 后果有两个，都是用户可见的错误：
 * 1. 已取消（`canceled`）的单也出现在「选择订单」里 —— 负责人本次明确要求不能显示；
 * 2. 列表口径与服务端校验口径**没有共同定义**：列表给什么就能选什么，服务端此前对订单
 *    状态**一个字都没校验**（只校验"这单是不是你的"），于是"随时能投诉一张早已取消的单"。
 *
 * ## 判定依据（读代码 + docs/05 状态机，不是猜的）
 *
 * - 投诉是「服务已经发生过」之后的追责：必须**存在接单打手**（`order.worker_id` 非空）
 *   才谈得上"投诉这一单的服务"。`pending_take` / `pending_dispatch` 阶段还没有任何人接单
 *   → 没有可追责对象，不列入。
 * - `canceled`：**负责人本次明确要求排除**（已取消的单不再接受投诉）。
 * - `abnormal`：订单被工作端报异常或管理员标记，正处于**平台介入裁决**中
 *   （docs/05：裁决后迁移到 after_sale / canceled / completed）→ 已有独立处置通道，
 *   再开一张投诉工单只会造成两条并行的处置线，不列入。
 * - 其余状态都代表"服务已由某位打手承接"，且尚未进入取消/异常，全部列入：
 *   `taken`（已接单）、`in_progress`（进行中）、`pending_confirm`（待用户确认）、
 *   `completed`（已完成，含结算后仍在追责窗口内的单）、`after_sale`（售后中，
 *   本身就在处理服务纠纷，允许同时留一条投诉记录）。
 *
 * ## 消费方（改这里就同时改三处，不需要再找第二份定义）
 *
 * 1. `OrderService.userOrders` —— `GET /user/orders?status=a,b` 多状态过滤（投诉页列表数据源）
 * 2. `ComplaintService.create` —— `targetType='order'` 时的服务端权威校验（中文 400）
 * 3. `ComplaintService.workerTargets` —— 打手候选的服务关系判定（只认"真接过我单"的单）
 *
 * 客户端（`apps/packages/core/lib/src/complaint/complaint_rules.dart`）持有同一份状态码清单，
 * **只用于拼查询参数**（`?status=taken,in_progress,...`），不承担放行判定 ——
 * 即便客户端被篡改，服务端 `ComplaintService.create` 仍会独立拒绝非法状态。
 */
export const COMPLAINTABLE_ORDER_STATUSES: OrderStatus[] = [
  'taken',
  'in_progress',
  'pending_confirm',
  'completed',
  'after_sale',
];

/** 是否可投诉（服务端权威判定入口） */
export function isComplaintableOrderStatus(status: string): boolean {
  return (COMPLAINTABLE_ORDER_STATUSES as string[]).includes(status);
}

/** 中文拒绝文案（客户端直接展示，故措辞面向用户而不是日志） */
export const ORDER_NOT_COMPLAINTABLE_MESSAGE = '该订单当前状态不可投诉（已取消/待接单/异常处理的订单不能投诉）';
