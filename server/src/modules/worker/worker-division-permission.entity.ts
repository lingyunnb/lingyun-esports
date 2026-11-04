import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 打手 × 分部 接单权限（负责人 2026-10-04）。
 *
 * 语义：一条记录 = 「该打手在该分部有（或曾有）接单权限」。查询一律带 `can_take_order = 1`；
 * `can_take_order = 0` 的行保留撤销留痕，再次授予时复用同一行（唯一键 (worker_id, division_id)）。
 *
 * 与 `worker.can_take_order` 的关系：后者是**派生汇总**（是否存在任一授权），写入时同步维护，
 * 仅供既有查询/展示兜底；**接单判定一律读本表**（docs/04 铁律：接单权限每次请求实时查库）。
 */
@Entity('worker_division_permission')
@Index('UK_wdp_worker_division', ['workerId', 'divisionId'], { unique: true })
@Index('IDX_wdp_division_take', ['divisionId', 'canTakeOrder'])
export class WorkerDivisionPermission {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  @Column({ name: 'division_id', type: 'bigint', unsigned: true })
  divisionId: string;

  /** 1 有接单权限 / 0 无（撤销留痕） */
  @Column({ name: 'can_take_order', type: 'tinyint', default: 1 })
  canTakeOrder: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
