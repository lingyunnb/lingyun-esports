import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 客户端安装包版本记录（云端更新，负责人需求） */
@Entity('app_version')
@Index('IDX_app_version_type_status', ['appType', 'status'])
@Index('IDX_app_version_type_code', ['appType', 'versionCode'])
export class AppVersion {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 更新通道：boss 老板端 / worker 工作端（两条通道相互独立，各自版本码单调递增、互不串包） */
  @Column({ name: 'app_type', length: 16, default: 'boss' })
  appType: string;

  /** 数字版本号（版本比较唯一依据） */
  @Column({ name: 'version_code', type: 'int' })
  versionCode: number;

  @Column({ name: 'version_name', length: 32 })
  versionName: string;

  @Column({ name: 'update_desc', type: 'text' })
  updateDesc: string;

  @Column({ name: 'force_update', type: 'tinyint', default: 0 })
  forceUpdate: number;

  @Column({ name: 'min_supported_version', type: 'int', default: 1 })
  minSupportedVersion: number;

  @Column({ name: 'file_name', length: 255 })
  fileName: string;

  @Column({ name: 'file_size', type: 'bigint' })
  fileSize: string;

  @Column({ name: 'file_hash', length: 64 })
  fileHash: string;

  @Column({ name: 'file_path', length: 512 })
  filePath: string;

  /**
   * 可选镜像/CDN **绝对**下载地址（2026-10-06 云更新提速）。
   *
   * - `NULL` = 用服务端默认下载接口（相对路径 `/api/v1/public/app-versions/download/:id`）
   * - 有值 = 直接下发该绝对地址；客户端 `AppConfig.resolveMediaUrl` 对
   *   `http(s)://` 原样透传，因此换源**不需要改客户端**
   *
   * 语义约束：镜像内容必须与主包逐字节一致（sha256 校验兜底：不一致就拒绝安装），
   * 且建议支持 Range（不支持时客户端自动退回单连接）。
   */
  // 注意 `type: 'varchar'` 必须显式写出：`string | null` 让 TS 元数据退化成 Object，
  // TypeORM 会报 DataTypeNotSupportedError（2026-10-06 实测）
  @Column({ name: 'mirror_url', type: 'varchar', length: 512, nullable: true })
  mirrorUrl: string | null;

  /** 1 启用 / 2 停用 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @Column({ name: 'uploaded_by', type: 'bigint', unsigned: true, nullable: true })
  uploadedBy: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
