import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 商品媒体（docs/02）：多图/视频/视频封面；media 表阶段 13 接入 */
@Entity('product_media')
@Index('IDX_product_media_product', ['productId', 'sortOrder'])
export class ProductMedia {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'product_id', type: 'bigint', unsigned: true })
  productId: string;

  @Column({ name: 'media_id', type: 'bigint', unsigned: true })
  mediaId: string;

  /** image / video */
  @Column({ name: 'media_type', length: 16, default: 'image' })
  mediaType: string;

  @Column({ name: 'is_cover', type: 'tinyint', default: 0 })
  isCover: number;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
