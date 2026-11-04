import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 分部（负责人 2026-10-03 定案）：**游戏 + 平台** 的组合，是客户端一切筛选与展示的主维度。
 *
 * 当前 5 个分部：
 *   和平精英 · 手游 / 三角洲行动 · 手游 / 三角洲行动 · 端游（正常）
 *   无畏契约 · 端游 / 无畏契约 · 手游（**建设中**，负责人 2026-10-05 新增，暂无商品+招人文案）
 * 规则：同一游戏平台数 = 1 时，客户端**不显示平台筛选**（如和平精英没有端游）。
 * 建设中分部：`under_construction = 1`，客户端分部卡显示「建设中」标识、点击进建设中页；
 * 改成 0 即自动恢复正常进入商品列表（**客户端零改动**）。
 */
@Entity('division')
@Index('IDX_division_status_sort', ['status', 'sortOrder'])
@Index('IDX_division_game_platform', ['gameId', 'platform'])
export class Division {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  /** mobile 手游 / pc 端游 */
  @Column({ type: 'varchar', length: 8, default: 'mobile' })
  platform: string;

  /** 唯一标识，如 peace_mobile / delta_pc */
  @Column({ length: 48, unique: true })
  code: string;

  /** 展示名，如「和平精英 · 手游」 */
  @Column({ length: 40 })
  name: string;

  /** 分部卡主标题，如「和平精英」 */
  @Column({ name: 'short_name', length: 24, default: '' })
  shortName: string;

  /** 平台标签，如「手游」「端游」 */
  @Column({ name: 'platform_label', length: 8, default: '' })
  platformLabel: string;

  /** 首页在线说明，如「平均 3 分钟内接单」 */
  @Column({ name: 'online_desc', length: 64, default: '' })
  onlineDesc: string;

  /** 价格说明（管理端可改） */
  @Column({ name: 'price_note', length: 64, default: '' })
  priceNote: string;

  /** 主题色 #RRGGBB；空则客户端按排序取默认品类色 */
  @Column({ name: 'theme_color', length: 16, default: '' })
  themeColor: string;

  /** 专区圆形图（负责人 2026-10-04：首页圈出的图要能在管理端换）—— 客户端优先显示图，无图回退渐变色块+图标 */
  @Column({ name: 'icon_media_id', type: 'bigint', unsigned: true, nullable: true })
  iconMediaId: string | null;

  /** 分部卡封面图（同上，管理端可换；无图回退渐变色块） */
  @Column({ name: 'cover_media_id', type: 'bigint', unsigned: true, nullable: true })
  coverMediaId: string | null;

  /** 列表副文案（管理端可改，如「平均 3 分钟内接单」之上的一句） */
  @Column({ name: 'sub_title', length: 64, default: '' })
  subTitle: string;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 状态：1 上架 / 0 下架（下架后 public 接口不可见，客户端不显示；DTO 已按 @IsIn([0,1]) 校验） */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  /**
   * 是否建设中（负责人 2026-10-05：瓦端 / 瓦手 先上「建设中」页）
   *
   * 1 = 建设中：客户端分部卡显示细描边「建设中」小片，**点击进建设中页而不是商品列表**；
   * 0 = 正常分部（默认，既有 3 个分部行为零变化）。改成 0 后客户端**无需改代码**自动恢复正常进入商品页。
   */
  @Column({ name: 'under_construction', type: 'tinyint', default: 0 })
  underConstruction: number;

  /**
   * 建设中页提示文案（**服务端下发，客户端零硬编码**，可含换行与 QQ 号）
   *
   * public 接口统一转成字符串下发（NULL → ''），避免客户端出现 null 分支。
   */
  @Column({ name: 'notice_text', type: 'varchar', length: 255, nullable: true })
  noticeText: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
