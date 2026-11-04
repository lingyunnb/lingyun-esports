import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 首页通用模块（key-value 配置，管理端修改，客户端零硬编码）：
 * - club_intro：俱乐部介绍
 * - activity：活动/重要信息
 * - order_button：立即下单按钮（文字/跳转 tab）
 * - 未来新增模块优先走本表扩展
 */
@Entity('home_module')
export class HomeModule {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'module_key', length: 32, unique: true })
  moduleKey: string;

  @Column({ length: 64 })
  title: string;

  /** 内容（富文本/纯文本由客户端按 key 渲染） */
  @Column({ type: 'text', nullable: true })
  content: string | null;

  /** 扩展配置 JSON（如按钮文字/跳转目标） */
  @Column({ name: 'extra_json', type: 'json', nullable: true })
  extraJson: Record<string, unknown> | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 显示 / 2 隐藏（隐藏后客户端整个模块不渲染） */
  @Column({ type: 'tinyint', default: 1 })
  visible: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
