import { Column, Entity, PrimaryColumn, UpdateDateColumn } from 'typeorm';

/** 官网内容（单行 JSON；官网所有展示内容由管理端高度自定义，负责人 2026-09-25） */
@Entity('site_content')
export class SiteContent {
  @PrimaryColumn({ type: 'int' })
  id: number;

  @Column({ type: 'json' })
  content: Record<string, unknown>;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
