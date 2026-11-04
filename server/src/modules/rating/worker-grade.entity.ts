import { Column, Entity, PrimaryColumn } from 'typeorm';

/**
 * 打手当前等级（migration `1817000000000`，负责人已审批 2026-10-17）
 *
 * - **一行 = 一个打手**（`worker_id` 主键）。**没有行 = 从未变更过 = 注册默认等级**
 *   （`DEFAULT_WORKER_GRADE`）—— 刻意不"注册时插一行"：
 *   存量打手全都没有行，若要求"必须有行"，所有读路径都得先补行，判级与列表查询就会掺入写操作。
 * - `grade` 只存 1–5 的**数字**；中文名与 `LV` 标签是代码常量
 *   （`modules/worker/worker-grade.constants.ts` 的 `WORKER_GRADES`），**不落库**。
 * - `upgraded_by = NULL` = **系统自动判定**（自动升级归不到具体人）；
 *   非空 = 管理员 `user.id`（`PUT /admin/workers/:id/grade`，仅超管）。
 * - `note`：人工设置时是管理员填的备注；自动升级时写"命中指标摘要"（便于管理端一眼看出凭什么升的）。
 *
 * 写入路径**只有两处**（都在 `WorkerGradeService` 里，且都走 `INSERT … ON DUPLICATE KEY UPDATE`）：
 * ① `evaluate()` 自动升级（只在 `newGrade > current` 时写，**只升不降**）；
 * ② `setManualGrade()` 超管人工设置（1–5 全档，含最高档）。
 */
@Entity('worker_grade')
export class WorkerGrade {
  /** 打手档案 id（`worker.id`；与 `worker_stats.worker_id` 同源，**不是** `user.id`） */
  @PrimaryColumn({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 等级 1–5（只存数字；名字/标签见 `worker-grade.constants.ts`） */
  @Column({ type: 'tinyint', default: 1 })
  grade: number;

  /** 最近一次等级变更时间（NULL = 从未变更） */
  @Column({ name: 'upgraded_at', type: 'datetime', precision: 3, nullable: true })
  upgradedAt: Date | null;

  /** 变更操作人（`user.id`，role=admin）；NULL = 系统自动判定 */
  @Column({ name: 'upgraded_by', type: 'bigint', unsigned: true, nullable: true })
  upgradedBy: string | null;

  /** 备注（人工设置时填写；自动升级写命中指标摘要） */
  @Column({ type: 'varchar', length: 100, nullable: true })
  note: string | null;
}
