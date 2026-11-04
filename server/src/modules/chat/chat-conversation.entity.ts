import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 聊天会话（docs/07）：CS 会话（用户↔客服）与好友会话（用户↔用户）；seq 服务端事务内分配保证顺序 */
@Entity('chat_conversation')
@Index('IDX_conv_status', ['status'])
export class ChatConversation {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 属主（CS=用户；好友会话=双方中 id 较小者，peer_user_id 存较大者） */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** cs 客服会话 / friend 好友会话 */
  @Column({ type: 'varchar', length: 16, default: 'cs' })
  type: string;

  /** 好友会话对方（CS 为 null） */
  @Column({ name: 'peer_user_id', type: 'bigint', unsigned: true, nullable: true })
  peerUserId: string | null;

  /** 订单群关联订单（type=order_group；唯一约束保证一单一群） */
  @Column({ name: 'order_id', type: 'bigint', unsigned: true, nullable: true })
  orderId: string | null;

  /** 群组名称（订单群自动生成"订单群-订单号"） */
  @Column({ name: 'name', type: 'varchar', length: 64, nullable: true })
  name: string | null;

  /** 会话内最大消息 seq（发送时行锁递增，docs/07 顺序保证） */
  @Column({ name: 'last_seq', type: 'bigint', unsigned: true, default: 0 })
  lastSeq: string;

  @Column({ name: 'unread_user', type: 'int', default: 0 })
  unreadUser: number;

  @Column({ name: 'unread_worker', type: 'int', default: 0 })
  unreadWorker: number;

  /** 好友会话对方侧未读 */
  @Column({ name: 'unread_peer', type: 'int', default: 0 })
  unreadPeer: number;

  /**
   * 已读位点（负责人 2026-10-04：单勾=已送达 / 双勾=已读）：
   * 记录每一方「已读到第几条 seq」，发送方用它与自己消息的 seq 比较 → 单勾/双勾。
   * - user_read_seq：属主（老板）
   * - peer_read_seq：对端（好友 / 打手直聊里的打手）
   * - worker_read_seq：CS 会话里被指派客服的位点
   */
  @Column({ name: 'user_read_seq', type: 'bigint', unsigned: true, default: 0 })
  userReadSeq: string;

  @Column({ name: 'peer_read_seq', type: 'bigint', unsigned: true, default: 0 })
  peerReadSeq: string;

  @Column({ name: 'worker_read_seq', type: 'bigint', unsigned: true, default: 0 })
  workerReadSeq: string;

  /** open 进行中 / closed 已结束（客服会话"本次咨询已完成"，需求 #7） */
  @Column({ type: 'varchar', length: 16, default: 'open' })
  status: string;

  @Column({ name: 'closed_at', type: 'datetime', precision: 3, nullable: true })
  closedAt: Date | null;

  /** 结束方：user 老板 / worker 客服 / admin 管理员 */
  @Column({ name: 'closed_by', type: 'varchar', length: 16, nullable: true })
  closedBy: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
