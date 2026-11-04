import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 工作端档案（docs/02）：接单/客服权限独立，仅超管/授权管理员可改，每次请求实时查库校验 */
@Entity('worker')
@Index('IDX_worker_can_take_order_status', ['canTakeOrder', 'status'])
export class Worker {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true, unique: true })
  userId: string;

  @Column({ name: 'worker_no', length: 20, unique: true })
  workerNo: string;

  @Column({ name: 'real_name', type: 'varchar', length: 32, nullable: true })
  realName: string | null;

  @Column({ type: 'varchar', length: 20, nullable: true })
  phone: string | null;

  /** 接单权限 0/1（服务端实时校验，前端按钮只做展示） */
  @Column({ name: 'can_take_order', type: 'tinyint', default: 0 })
  canTakeOrder: number;

  /** 客服权限 0/1（与接单权限完全独立） */
  @Column({ name: 'can_serve_customer', type: 'tinyint', default: 0 })
  canServeCustomer: number;

  /** 1 在职 / 2 停用 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  /** 主分部（游戏 + 平台；负责人 2026-10-03）：接单大厅按分部筛选的依据，可空=全部分部 */
  @Column({ name: 'division_id', type: 'bigint', unsigned: true, nullable: true })
  divisionId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
