import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 绑定状态：active 生效 / unbound 已解绑（历史行保留，不删除） */
export type WorkerBindingStatus = 'active' | 'unbound';

/**
 * 老板账号 ↔ 打手账号 绑定（合并双端·身份切换，方案甲；migration 1801000000000）。
 *
 * 约束（**都在数据库层**，服务层只做前置校验与中文报错）：
 * - `UK_wib_active_worker`：一个打手账号同时只能被**一个**老板绑定（active 行唯一）；
 * - `UK_wib_active_boss_slot`：同一老板同一**槽位**只能有一条 active → 配合 `system_setting.worker_binding_max_per_boss`
 *   实现「上限可配」且并发安全。
 * 两个唯一键都建在**生成列**（`active_boss_user_id` / `active_worker_user_id`，status≠active 时为 NULL）上，
 * MySQL 唯一索引忽略 NULL → 解绑行自动释放名额、历史行可无限保留。生成列不在实体里映射（写入永不涉及）。
 */
@Entity('worker_identity_binding')
@Index('IDX_wib_boss_status', ['bossUserId', 'status'])
@Index('IDX_wib_worker_status', ['workerUserId', 'status'])
export class WorkerIdentityBinding {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 老板账号 id（user.id，role=user）—— 主体 id 只来自 JWT sub */
  @Column({ name: 'boss_user_id', type: 'bigint', unsigned: true })
  bossUserId: string;

  /** 打手账号 id（user.id，role=worker） */
  @Column({ name: 'worker_user_id', type: 'bigint', unsigned: true })
  workerUserId: string;

  @Column({ type: 'varchar', length: 16, default: 'active' })
  status: WorkerBindingStatus;

  /** 老板侧配额槽位（1..上限）：取最小空闲槽，唯一键保证并发不越限 */
  @Column({ type: 'tinyint', unsigned: true, default: 1 })
  slot: number;

  @Column({ name: 'bound_at', type: 'datetime', precision: 3 })
  boundAt: Date;

  @Column({ name: 'unbound_at', type: 'datetime', precision: 3, nullable: true })
  unboundAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
