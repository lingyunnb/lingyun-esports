import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 收款账号状态：active 生效 / unbound 已解绑（历史行保留，可审计） */
export type WorkerWithdrawAccountStatus = 'active' | 'unbound';

/**
 * 打手收款信息（微信收款码 + 微信号 + 姓名 + 电话）—— migration `1810000000000`。
 *
 * ## 为什么必须"同一打手只有一行 active"
 *
 * 收款信息是**打款的唯一去向**。若同一打手存在两行 active，"这次打给谁"就有了歧义
 * —— 资金去向不能有歧义。落地方式照抄 `worker_identity_binding`（结构规则 11）：
 * **生成列 + 唯一键**
 *
 *   `active_worker_id` = CASE WHEN status='active' THEN worker_id ELSE NULL END  (STORED)
 *   `UNIQUE KEY UK_wwa_active_worker (active_worker_id)`
 *
 * MySQL 唯一索引**忽略含 NULL 的键** → 只有 active 行参与约束：
 * 一个打手同时只能有一行 active，而"换绑历史"仍可另存多行 unbound（将来要留档时不用改表）。
 *
 * ## 换绑 = 更新同一行（不是插入新行）
 *
 * 负责人定案："换绑=更新同一行，**旧值写进审计**"。因此 `POST /worker/withdraw/account`
 * 走的是 `UPDATE`（同事务内先读旧值 → 写 `operation_log` 的新旧值摘要 → 再更新），
 * 数据库里**永远只有一行**，不需要"先失效旧的、再插新的"这种两步状态机（那会留出一个
 * "没有任何 active 行"的窗口，打款侧读不到收款信息）。
 *
 * ## 合规
 *
 * - `qr_media_id` 指向 `media` 表且**用途必须是 `withdraw_qr`（protected）** ——
 *   收款码绝不公开直连（服务层校验用途，不信任客户端声明的类型）；
 * - 姓名/手机号/微信号属**敏感个人信息**：列表脱敏、详情给完整（审核必需），见 docs/09。
 */
@Entity('worker_withdraw_account')
@Index('IDX_wwa_worker_status', ['workerId', 'status'])
export class WorkerWithdrawAccount {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 打手档案 id（`worker.id`）；**不是** user.id（user.id 另存申请表的 user_id） */
  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 真实姓名（varchar 32；打款核对用，列表脱敏） */
  @Column({ name: 'real_name', type: 'varchar', length: 32 })
  realName: string;

  /** 手机号（varchar 20；打款联系用，列表脱敏） */
  @Column({ type: 'varchar', length: 20 })
  phone: string;

  /** 微信号（varchar 64；**只做微信**，不做支付宝） */
  @Column({ name: 'wechat_id', type: 'varchar', length: 64 })
  wechatId: string;

  /** 微信收款码 media.id（用途 `withdraw_qr`，protected：只走受保护通道） */
  @Column({ name: 'qr_media_id', type: 'bigint', unsigned: true })
  qrMediaId: string;

  @Column({ type: 'varchar', length: 16, default: 'active' })
  status: WorkerWithdrawAccountStatus;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
