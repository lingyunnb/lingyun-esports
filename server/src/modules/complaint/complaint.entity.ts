import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 投诉对象类型：order 订单 / worker 打手 / service 客服 */
export type ComplaintTargetType = 'order' | 'worker' | 'service';

/** 投诉类型：attitude 服务态度 / not_agreed 未按约定 / delay 恶意拖延 / other 其它 */
export type ComplaintType = 'attitude' | 'not_agreed' | 'delay' | 'other';

/** 工单状态：pending 待处理 / processing 处理中 / handled 已处理 / rejected 已驳回 */
export type ComplaintStatus = 'pending' | 'processing' | 'handled' | 'rejected';

/**
 * 投诉工单（负责人 2026-10-04：顶部导航「投诉」）
 *
 * 参考通用工单模型（见 docs/20 开源选型）：reporter（user_id）+ target(target_type/target_id)
 * + category(type) + body(content) + attachments(media_ids) + status + handler/handled_at/remark。
 * 客户端不可信：投诉人只从 JWT 取，target_name 由服务端落快照，截图 media id 逐一校验归属。
 */
@Entity('complaint')
@Index('UQ_complaint_no', ['complaintNo'], { unique: true })
@Index('IDX_complaint_status', ['status', 'id'])
@Index('IDX_complaint_user', ['userId', 'id'])
export class Complaint {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'complaint_no', length: 32 })
  complaintNo: string;

  /** 投诉人（取自 JWT，绝不信任请求体） */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @Column({ name: 'target_type', type: 'varchar', length: 16 })
  targetType: ComplaintTargetType;

  @Column({ name: 'target_id', type: 'varchar', length: 64, default: '' })
  targetId: string;

  /** 目标展示名快照（订单号 / 打手昵称 / 客服），服务端写入，避免事后改名导致记录失真 */
  @Column({ name: 'target_name', type: 'varchar', length: 64, default: '' })
  targetName: string;

  @Column({ type: 'varchar', length: 24 })
  type: ComplaintType;

  @Column({ type: 'varchar', length: 1000 })
  content: string;

  /** 截图媒体 id，逗号分隔（最多 6 张；受保护媒体，仅投诉人本人与管理员可读） */
  @Column({ name: 'media_ids', type: 'varchar', length: 500, default: '' })
  mediaIds: string;

  @Column({ type: 'varchar', length: 16, default: 'pending' })
  status: ComplaintStatus;

  @Column({ name: 'handle_remark', type: 'varchar', length: 500, default: '' })
  handleRemark: string;

  @Column({ name: 'handled_by', type: 'bigint', unsigned: true, nullable: true })
  handledBy: string | null;

  @Column({ name: 'handled_at', type: 'datetime', precision: 3, nullable: true })
  handledAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
