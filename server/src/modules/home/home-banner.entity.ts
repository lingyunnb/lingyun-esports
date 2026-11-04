import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 首页宣传图（顶部通栏轮播）：图片/标题/跳转/投放时间，全部由管理端配置
 *
 * 2026-10-05（任务② 方案 C）：本表从"已废弃的旧首页 Banner"重新启用为**首页宣传图轮播**的唯一数据源，
 * 只补 3 个可空列（`subtitle` / `start_at` / `end_at`，见 migration `1798000000000`），
 * **没有新建表**。
 */
@Entity('home_banner')
@Index('IDX_home_banner_visible_sort', ['visible', 'sortOrder'])
export class HomeBanner {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 64 })
  title: string;

  /** 副标题（宣传图第二行文案；NULL/空 = 客户端不显示这一行） */
  @Column({ type: 'varchar', length: 64, nullable: true })
  subtitle: string | null;

  /**
   * 图片 URL（历史兼容字段；新数据一律走 `imageMediaId`，本列留空串）
   *
   * **`default: ''` 不能省**：列是 NOT NULL 且历史上无默认值，管理端只传 `imageMediaId` 时
   * TypeORM 生成的 INSERT 不含该列 → MySQL strict 模式报 `ER_NO_DEFAULT_FOR_FIELD`。
   * 详见 migration `1798000000000` 第 3 条。
   */
  @Column({ name: 'image_url', type: 'varchar', length: 500, default: '' })
  imageUrl: string;

  /** 图片媒体 id（阶段 13 media 模块，优先于 image_url） */
  @Column({ name: 'image_media_id', type: 'bigint', unsigned: true, nullable: true })
  imageMediaId: string | null;

  /**
   * 跳转类型：`none` 无跳转 / `product` 商品详情 / `division` 分部 / `announcement` 公告 / `url` 外链
   *
   * 2026-10-05 扩了 `division` 与 `announcement` 两个值：列本身是 `varchar(16)`
   * （不是 MySQL ENUM），**扩值不需要 DDL**，只改 DTO 白名单与客户端分发。
   * 历史值 `tab`（切底部 tab）保留在白名单里以兼容存量数据，但管理端新页面不再提供该选项
   * —— 首页宣传图跳"某个 tab"没有明确目标，容易配出用户看不懂的跳转。
   */
  @Column({ name: 'link_type', length: 16, default: 'none' })
  linkType: string;

  @Column({ name: 'link_value', type: 'varchar', length: 255, nullable: true })
  linkValue: string | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 显示 / 2 隐藏（**注意不是 0/1**：0 在本表是不存在的非法值，查询恒带 `visible = 1`） */
  @Column({ type: 'tinyint', default: 1 })
  visible: number;

  /**
   * 投放开始 / 结束时间，**NULL = 该端不限制**（不是"立即过期"）
   *
   * 公开接口按 `(start_at IS NULL OR start_at <= NOW()) AND (end_at IS NULL OR end_at >= NOW())` 过滤。
   */
  @Column({ name: 'start_at', type: 'datetime', precision: 3, nullable: true })
  startAt: Date | null;

  @Column({ name: 'end_at', type: 'datetime', precision: 3, nullable: true })
  endAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
