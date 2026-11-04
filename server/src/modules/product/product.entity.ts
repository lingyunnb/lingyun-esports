import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 商品（docs/02）：价格权威在服务端，前端永远不能决定最终价格 */
@Entity('product')
@Index('IDX_product_game_category_status', ['gameId', 'categoryId', 'status'])
@Index('IDX_product_status_sort', ['status', 'sortOrder'])
/**
 * 公开商品列表的覆盖索引（2026-10-04 性能专项，迁移 1792000000000）。
 *
 * 对应 `GET /public/products?divisionId=N` 的真实 SQL：
 *   WHERE status=1 AND service_status=1 AND division_id=? ORDER BY sort_order ASC, id DESC
 * 在此之前只有 `IDX_product_division(division_id)` 可用，EXPLAIN 显示
 * `rows=1667 / Using filesort` —— 即按分部捞出全部商品再排序。
 * 实测（合成数据 5k/50k/200k 行）中位耗时提升 1.06~1.15x，且 filesort 仍在
 * （详见迁移文件里的完整说明与"为何不加其它 4 个索引"）。
 */
@Index('IDX_product_division_status_sort', ['divisionId', 'status', 'serviceStatus', 'sortOrder'])
export class Product {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 64 })
  name: string;

  @Column({ length: 64, default: '' })
  subtitle: string;

  /**
   * 列表短名（负责人 2026-10-05 任务②；迁移 1797000000000）
   *
   * **只服务客户端商品列表卡**这一次渲染：窄卡（左侧分类栏占位后仅 240dp）放不下超长商品名时，
   * 管理端配一个短名；NULL / 空 = 列表直接用完整 `name`（默认，绝大多数商品都不需要配）。
   *
   * 与 `name` 的分工（硬规则，改动前先读）：
   * - `name`：**权威名称**，会进 `order_price_snapshot.product_name`、订单列表/详情、消息文案；
   * - `listName`：**纯展示层**，只出现在列表卡上；详情页 / 确认订单页 / 订单页一律仍用 `name`。
   */
  @Column({ name: 'list_name', type: 'varchar', length: 64, nullable: true })
  listName: string | null;

  /**
   * 商品徽标文案（负责人 2026-10-05；迁移 1796000000000）
   *
   * 卡片左上角小徽标（如「董事长推荐」）；**通用能力**，任何商品都能配，NULL/空 = 不显示。
   * 上限 32 字与 DDL 一致（徽标是 10px 字的小片，再长必然溢出）。
   */
  @Column({ name: 'badge_text', type: 'varchar', length: 32, nullable: true })
  badgeText: string | null;

  /**
   * 每周限购（单/账号/周；负责人 2026-10-05）
   *
   * NULL / 0 = 不限；> 0 = 服务端在**下单事务内、扣款之前**强制校验（`order.service.ts`）。
   * 客户端只读它做提示，不参与判定（docs/04：客户端数据一律不可信）。
   */
  @Column({ name: 'weekly_limit', type: 'int', nullable: true })
  weeklyLimit: number | null;

  /**
   * 限购口径开关（负责人 2026-10-05 任务③；迁移 1798000000000）
   *
   * `0` = 按**订单条数**（`COUNT(1)`，默认，= 加列前的现状口径）；`1` = 按**件数**
   * （`COALESCE(SUM(quantity),0)`，一次买 2 件占 2 个名额）。
   *
   * 只有 `weeklyLimit > 0`（配了限购）时有意义；判定与配额查询共用
   * `order.service.ts` 的口径函数，客户端不参与计算（docs/04）。
   */
  @Column({ name: 'weekly_limit_by_quantity', type: 'tinyint', default: 0 })
  weeklyLimitByQuantity: number;

  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  /** 分部（游戏 + 平台；负责人 2026-10-03）：商品归属分部，客户端按分部筛选 */
  @Column({ name: 'division_id', type: 'bigint', unsigned: true, nullable: true })
  divisionId: string | null;

  @Column({ name: 'category_id', type: 'bigint', unsigned: true })
  categoryId: string;

  /** 价格（元，服务端权威；改价不影响历史订单快照，docs/06） */
  @Column({ type: 'decimal', precision: 10, scale: 2, transformer: moneyTransformer })
  price: number;

  /** 计价单位：局/小时/段 等（后台可配） */
  @Column({ name: 'price_unit', length: 16, default: '局' })
  priceUnit: string;

  @Column({ name: 'estimate_duration_min', type: 'int', default: 30 })
  estimateDurationMin: number;

  /** 1 上架 / 2 下架（下架不可下单，public 不可见） */
  @Column({ name: 'service_status', type: 'tinyint', default: 2 })
  serviceStatus: number;

  /** 销量：仅完成订单事务内累加（真实统计，docs/待确认事项） */
  @Column({ name: 'sales_count', type: 'int', default: 0 })
  salesCount: number;

  /** 主图媒体 id（阶段 13 启用；管理端上传） */
  @Column({ name: 'cover_media_id', type: 'bigint', unsigned: true, nullable: true })
  coverMediaId: string | null;

  /** 商品视频媒体 id（mp4，阶段 13） */
  @Column({ name: 'video_media_id', type: 'bigint', unsigned: true, nullable: true })
  videoMediaId: string | null;

  /** 视频封面媒体 id（阶段 13） */
  @Column({ name: 'video_cover_media_id', type: 'bigint', unsigned: true, nullable: true })
  videoCoverMediaId: string | null;

  @Column({ type: 'text', nullable: true })
  description: string | null;

  @Column({ type: 'text', nullable: true })
  detail: string | null;

  @Column({ name: 'service_flow', type: 'text', nullable: true })
  serviceFlow: string | null;

  @Column({ name: 'service_rules', type: 'text', nullable: true })
  serviceRules: string | null;

  @Column({ type: 'text', nullable: true })
  attention: string | null;

  /**
   * 商品级「下单须知」（负责人 2026-10-05 商品详情页 v2 方案 B；迁移 1799000000000）
   *
   * **两层取值的上层**：NULL / 空 = 继承平台默认（`system_setting.order_notice_default`）。
   * 详情页下发的 `effectiveOrderNotice` 已经是**解析后的生效值**，客户端不做优先级判断。
   *
   * 与 `attention`（注意事项）的分工：`attention` 是**商品说明类**长文（与描述/服务规则同族，
   * 展示在说明区）；`orderNotice` 是**交易条款**（退款口径/取消规则/账号安全），
   * 详情页独立成「下单须知」折叠块，默认折叠。
   */
  @Column({ name: 'order_notice', type: 'text', nullable: true })
  orderNotice: string | null;

  /** 扩展字段（游戏特有属性，docs/13） */
  @Column({ name: 'extra_json', type: 'json', nullable: true })
  extraJson: Record<string, unknown> | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 启用 / 2 禁用 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
