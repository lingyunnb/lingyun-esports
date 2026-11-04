import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 收款码渠道：微信 / 支付宝 / 其它（负责人定案：可多张，排序 + 停用） */
export type RechargeQrChannel = 'wechat' | 'alipay' | 'other';

/**
 * 收款码（migration 1804000000000）—— **合规红线：这只是"一张图片"**。
 *
 * 表里刻意**没有**任何支付通道字段（无商户号、无 appid、无密钥、无支付单号），
 * 因为平台不接任何支付通道：图片由管理员在后台上传，App 只负责展示，老板扫的是
 * 自己微信/支付宝里的收款码 —— 平台不经手资金（CLAUDE.md 结构规则 12）。
 *
 * `media_id` 指向 `media` 表（public 通道，老板端要能直接取图；走既有媒体上传接口）。
 * `enabled=0` 只表示"不再展示给老板"，**不删行**（历史申请仍要能回溯当时扫的是哪张码）。
 */
@Entity('recharge_qr_code')
@Index('IDX_rqc_enabled_sort', ['enabled', 'sort'])
export class RechargeQrCode {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** media.id（图片；public 通道，老板端展示用） */
  @Column({ name: 'media_id', type: 'bigint', unsigned: true })
  mediaId: string;

  @Column({ type: 'varchar', length: 16, default: 'other' })
  channel: RechargeQrChannel;

  /** 展示名（如「微信收款码 · 小云」）；老板端列表里就是这一行字 */
  @Column({ type: 'varchar', length: 64, default: '' })
  label: string;

  /** 排序（升序展示；同值按 id 兜底） */
  @Column({ type: 'int', default: 0 })
  sort: number;

  /** 1 启用（展示）/ 0 停用（不展示，行保留） */
  @Column({ type: 'tinyint', default: 1 })
  enabled: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
