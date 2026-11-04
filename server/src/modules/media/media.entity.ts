import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 媒体资源元数据（docs/08：文件落盘 uploads/YYYY/MM/uuid.ext，本表只存元信息） */
@Entity('media')
export class Media {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 相对 MEDIA_ROOT 的存储路径（服务端生成，杜绝路径穿越） */
  @Column({ name: 'file_key', length: 255 })
  fileKey: string;

  /** avatar/bg/chat_image/product_image/product_video/video_cover/banner/top_worker_avatar/division_icon/division_cover */
  @Column({ name: 'media_type', length: 32 })
  mediaType: string;

  @Column({ name: 'original_name', length: 255, default: '' })
  originalName: string;

  /** 服务端探测的真实 MIME（不信任客户端声明） */
  @Column({ name: 'mime_type', length: 64 })
  mimeType: string;

  @Column({ length: 16 })
  extension: string;

  @Column({ name: 'size_bytes', type: 'bigint', unsigned: true })
  sizeBytes: string;

  @Column({ type: 'int', unsigned: true, nullable: true })
  width: number | null;

  @Column({ type: 'int', unsigned: true, nullable: true })
  height: number | null;

  /** 内容哈希（sha256），相同文件复用记录 */
  @Column({ name: 'sha256', length: 64, unique: true })
  sha256: string;

  @Column({ name: 'uploader_id', type: 'bigint', unsigned: true, nullable: true })
  uploaderId: string | null;

  /** 1 = 受保护资源（聊天图片等，仅归属者/授权客服可读） */
  @Column({ name: 'is_protected', type: 'tinyint', default: 0 })
  isProtected: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
