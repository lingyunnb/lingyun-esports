import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 管理端操作日志（docs/02）：敏感操作全量留痕（请求体脱敏存储） */
@Entity('operation_log')
@Index('IDX_operation_log_admin_id', ['adminId'])
@Index('IDX_operation_log_action_created', ['action', 'createdAt'])
@Index('IDX_operation_log_request_id', ['requestId'])
export class OperationLog {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'admin_id', type: 'bigint', unsigned: true, nullable: true })
  adminId: string | null;

  @Column({ name: 'admin_name', type: 'varchar', length: 32, nullable: true })
  adminName: string | null;

  @Column({ type: 'varchar', length: 32 })
  module: string;

  @Column({ type: 'varchar', length: 64 })
  action: string;

  @Column({ type: 'varchar', length: 16 })
  method: string;

  @Column({ type: 'varchar', length: 255 })
  path: string;

  /** 脱敏后的请求体摘要（密码/密钥字段不落库，docs/09） */
  @Column({ name: 'request_body', type: 'text', nullable: true })
  requestBody: string | null;

  @Column({ type: 'varchar', length: 64, nullable: true })
  ip: string | null;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @Column({ type: 'varchar', length: 16, default: 'success' })
  result: string;

  @Column({ name: 'error_msg', type: 'varchar', length: 255, nullable: true })
  errorMsg: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
