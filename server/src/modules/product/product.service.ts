import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, In, Repository } from 'typeorm';
import { CreateProductDto, UpdateProductDto } from '../game/dto/catalog.dto';
import { Category } from '../game/category.entity';
import { Division } from '../division/division.entity';
import {
  isDivisionPubliclyVisible,
  publicDivisionFindWhere,
} from '../division/public-division-scope';
import { OperationLog } from '../log/operation-log.entity';
import { MediaService } from '../media/media.service';
import { ORDER_NOTICE_DEFAULT_KEY, ORDER_NOTICE_DEFAULT_TEXT, ORDER_PENDING_TAKE_TIMEOUT_HOURS_DEFAULT, ORDER_PENDING_TAKE_TIMEOUT_HOURS_KEY } from '../setting/order-notice';
import { SystemSettingService } from '../setting/system-setting.service';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { Product } from './product.entity';
import { ProductMedia } from './product-media.entity';
import { mapMoney } from '../../common/money.transformer';

/** 单个商品移动后的归属（审计「从哪到哪」用；不含任何业务字段，避免把价格等写进日志） */
interface MoveItemPlan {
  id: string;
  fromDivisionId: string | null;
  fromGameId: string;
  fromCategoryId: string;
  toCategoryId: string;
}

/** 移动结果（对外契约，管理端据此做中文提示） */
export interface MoveProductsResult {
  moved: number;
  skipped: number;
  failed: { id: string; reason: string }[];
  createdCategories: { id: string; name: string }[];
}

/** 写操作的操作者（审计用；adminUserId 只来自 JWT，客户端不可伪造） */
export interface ProductActor {
  adminUserId: string;
  ip?: string | null;
  requestId?: string | null;
  path?: string;
  method?: string;
}

/**
 * 商品审计关注的字段（负责人 2026-10-05 任务④）
 *
 * **顺序 = 日志里的顺序**：`price` 放第一位 —— 本次数据漂移就是价格被改（147 从 158.8 变 100），
 * 事后只能靠备份比对定位，所以"能不能一眼看出改价"是这套审计的第一验收点。
 * 长文本（描述/详情/服务流程…）只记**长度**：审计要的是"有没有改、改了多大"，
 * 把 5000 字正文塞进日志会把真正要紧的 price/name 挤到 4000 字截断之后。
 */
const PRODUCT_AUDIT_FIELDS: Array<{ field: string; kind?: 'money' | 'text' }> = [
  { field: 'price', kind: 'money' },
  { field: 'name' },
  { field: 'listName' },
  { field: 'subtitle' },
  { field: 'badgeText' },
  { field: 'weeklyLimit' },
  { field: 'weeklyLimitByQuantity' },
  { field: 'priceUnit' },
  { field: 'estimateDurationMin' },
  { field: 'serviceStatus' },
  { field: 'status' },
  { field: 'sortOrder' },
  { field: 'gameId' },
  { field: 'categoryId' },
  { field: 'divisionId' },
  { field: 'coverMediaId' },
  { field: 'videoMediaId' },
  { field: 'videoCoverMediaId' },
  { field: 'description', kind: 'text' },
  { field: 'detail', kind: 'text' },
  { field: 'serviceFlow', kind: 'text' },
  { field: 'serviceRules', kind: 'text' },
  { field: 'attention', kind: 'text' },
  // 下单须知（负责人 2026-10-05，迁移 1799000000000）：**交易条款**，改错直接影响退款口径，
  // 与其它长文本一样只记长度（"有没有改、改了多大"），不把正文塞进日志。
  { field: 'orderNotice', kind: 'text' },
];

/** 审计快照（字段 → 字符串值；null 表示空） */
type ProductAuditSnapshot = Record<string, string | null>;

/** 单字段变更（前后值） */
interface ProductAuditChange {
  field: string;
  from: string | null;
  to: string | null;
}

/** 商品服务（docs/02）：价格权威在服务端；下单时服务端重新查库定价（阶段 14） */
@Injectable()
export class ProductService {
  constructor(
    @InjectRepository(Product) private readonly productRepo: Repository<Product>,
    @InjectRepository(ProductMedia) private readonly mediaRepo: Repository<ProductMedia>,
    @InjectRepository(Division) private readonly divisionRepo: Repository<Division>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly mediaService: MediaService,
    private readonly settings: SystemSettingService,
  ) {}

  // ---------- 管理端 ----------

  /**
   * 商品写入后立刻失效公开接口的进程内微缓存（负责人 2026-10-05）
   *
   * `/public/products`（含详情 `/public/products/:id`）挂在 `PublicCacheInterceptor` 的 30s 微缓存下，
   * 而这一层**没有写入侧失效钩子** —— 实测：管理端刚把徽标/限购/价格改完，公开接口最多 30s 还是旧值。
   * 口径与分部那次修正完全一致：**内容随管理端配置变化的数据，写入时必须配失效钩子**
   * （`/public/players` 因权限实时性直接移出微缓存，商品属于"改一次要人工上后台"，保留缓存 + 失效更划算）。
   *
   * 覆盖徽标文案 `badge_text`、每周限购 `weekly_limit`、价格、上下架、归属移动等全部写路径：
   * 管理端保存 → 老板端下一次请求就能看到新徽标/新限购提示，不用等 TTL，也不用重启。
   */
  private invalidatePublicProductCache(): void {
    PublicCacheInterceptor.invalidate('/api/v1/public/products');
  }

  async adminList(q: { gameId?: string; categoryId?: string; divisionId?: string; keyword?: string; page: number; pageSize: number }) {
    const qb = this.dataSource
      .createQueryBuilder(Product, 'p')
      // 分部（负责人 2026-10-04 缺口修复）：列表原本漏了 division_id，管理端无法回显「商品挂在哪个分部」；
      // 顺带 join 出分部展示名（只读字段，改不动任何数据）
      .leftJoin('division', 'd', 'd.id = p.division_id')
      .select([
        'p.id AS id', 'p.name AS name', 'p.subtitle AS subtitle', 'p.game_id AS gameId', 'p.category_id AS categoryId',
        'p.division_id AS divisionId', 'd.name AS divisionName',
        'p.price AS price', 'p.price_unit AS priceUnit', 'p.estimate_duration_min AS estimateDurationMin',
        'p.service_status AS serviceStatus', 'p.sales_count AS salesCount', 'p.sort_order AS sortOrder',
        // 徽标 / 每周限购（负责人 2026-10-05）：管理端编辑弹窗要回显这两列，漏了就变成「保存后徽标不见了」
        'p.badge_text AS badgeText', 'p.weekly_limit AS weeklyLimit',
        // 列表短名 / 限购口径（负责人 2026-10-05 任务②③）：同上，管理端编辑弹窗必须能回显，
        // 否则「打开弹窗直接保存」会把管理员配好的短名与口径开关静默清掉
        'p.list_name AS listName', 'p.weekly_limit_by_quantity AS weeklyLimitByQuantity',
        // 下单须知（负责人 2026-10-05，迁移 1799000000000）：管理端编辑弹窗要显示「继承/覆盖」两态，
        // 不回显就会出现与徽标/短名同一类事故 —— 打开弹窗直接保存 → 已配好的须知被静默清回继承。
        // 代价：TEXT 进管理端列表（公开列表接口**没有**这一列，见 publicList 的列裁剪）。
        // 管理端列表是低频人工操作、单页 20 条，且绝大多数商品该列为 NULL，可接受。
        'p.order_notice AS orderNotice',
        'p.status AS status', 'p.cover_media_id AS coverMediaId', 'p.video_media_id AS videoMediaId', 'p.created_at AS createdAt',
      ]);
    if (q.gameId) qb.andWhere('p.game_id = :gameId', { gameId: q.gameId });
    if (q.categoryId) qb.andWhere('p.category_id = :categoryId', { categoryId: q.categoryId });
    /**
     * 分部筛选（负责人 2026-10-05 报障修复）
     *
     * 管理端 `GET /admin/products?divisionId=N` 此前**完全不生效**，根因在两处（都已修）：
     * 1) `ProductAdminController.list()` 只往下传 gameId/categoryId/keyword；
     * 2) 本方法也没有 division 条件。
     * 于是传了 divisionId 仍然返回全部分部的商品（实测 total=22 = 11 + 11）。
     *
     * 口径与公开侧 `publicList()` 的 `where.divisionId` 一致：**同字段、同语义**（等于筛选，不做空值兜底）。
     * 公开侧行为未改动。
     */
    if (q.divisionId) qb.andWhere('p.division_id = :divisionId', { divisionId: q.divisionId });
    if (q.keyword) qb.andWhere('(p.name LIKE :kw OR p.subtitle LIKE :kw)', { kw: `%${q.keyword}%` });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('p.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['price'])), total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize };
  }

  /**
   * 商品写操作的审计（负责人 2026-10-05 任务④）
   *
   * ## 为什么写在这里，而不是控制器里 `opLog.log(...)`
   *
   * 既有口径有两套，本项目都在用：
   * - `division:update` / `order:dispatch`：**控制器**里调 `OperationLogService.log()`，
   *   fire-and-forget（`void (async …)`），审计写失败只告警、不阻断业务；
   * - `product:move`（本 service 的 `moveProducts`）：**service 内 + 与数据变更同事务**。
   *
   * 本任务选**同事务**（与 `product:move` 一致，把商品写路径统一到这一套），理由是本次要解决的
   * 问题本身就是「事后定位不了漂移」：同事务保证**只要数据变了就一定有日志**，进程在提交后被 kill、
   * 审计表写入失败都不会出现"改了没记"。代价是 `operation_log` 插入失败会连带回滚业务写入 ——
   * 对"管理端改商品"这种低频人工操作，宁可报错重试，也不要静默改完没痕迹（反例正是这次的价格漂移）。
   * `division`/`order` 两侧保持原样**未改动**（硬约束：不动其它模块）。
   *
   * ## 记什么
   * - `module='product'`、`action`：`product:create|update|status|delete|move`
   * - `adminId`/`adminName`：操作者（adminId 只来自 JWT，客户端伪造不了）
   * - `requestBody`：`summary`（人类可读的「price 100.00 → 158.80」）+ `changes`（结构化前后值）
   *   + `before`/`after` 快照（update/status 两者都有；create 只有 after；delete 只有 before）
   * - 关键字段排前面：`request_body` 是 TEXT 且按 4000 字截断，截断不能把价格截没了。
   */
  private async writeProductAudit(
    em: EntityManager,
    actor: ProductActor,
    input: {
      action: 'product:create' | 'product:update' | 'product:status' | 'product:delete';
      productId: string;
      name: string;
      before?: ProductAuditSnapshot | null;
      after?: ProductAuditSnapshot | null;
      summary?: string;
      extra?: Record<string, unknown>;
    },
  ): Promise<void> {
    const changes: ProductAuditChange[] = [];
    if (input.before && input.after) {
      for (const key of Object.keys(input.after)) {
        const from = input.before[key] ?? null;
        const to = input.after[key] ?? null;
        if (from !== to) changes.push({ field: key, from, to });
      }
    }
    // summary：人类可读的「字段 旧值 → 新值」（SQL 里直接 LIKE '%price 100.00 → 158.80%' 就能定位）
    const summary =
      input.summary ??
      (changes.length
        ? changes.map((c) => `${c.field} ${c.from ?? 'null'} → ${c.to ?? 'null'}`).join('；')
        : input.action === 'product:create'
          ? '创建商品（初始快照）'
          : '提交内容与当前值一致（无字段变化）');

    let adminName: string | null = null;
    if (actor.adminUserId) {
      const rows = await em.query<Array<{ nickname?: string }>>('SELECT nickname FROM user WHERE id = ? LIMIT 1', [
        actor.adminUserId,
      ]);
      adminName = rows[0]?.nickname?.slice(0, 32) ?? null;
    }

    const body = JSON.stringify({
      productId: input.productId,
      name: input.name,
      action: input.action,
      adminId: actor.adminUserId,
      summary,
      changes,
      ...(input.before ? { before: input.before } : {}),
      ...(input.after ? { after: input.after } : {}),
      ...(input.extra ?? {}),
    });

    await em.getRepository(OperationLog).save(
      em.getRepository(OperationLog).create({
        adminId: actor.adminUserId || null,
        adminName,
        module: 'product',
        action: input.action,
        method: actor.method ?? 'POST',
        path: (actor.path ?? '').slice(0, 255),
        requestBody: body.length > 4000 ? `${body.slice(0, 3999)}…` : body,
        ip: actor.ip ?? null,
        requestId: actor.requestId ?? null,
        result: 'success',
      }),
    );
  }

  /** 商品 → 审计快照（价格固定两位小数，长文本只记长度；与 PRODUCT_AUDIT_FIELDS 一一对应） */
  private static snapshotForAudit(p: Product): ProductAuditSnapshot {
    const raw = p as unknown as Record<string, unknown>;
    const out: ProductAuditSnapshot = {};
    for (const item of PRODUCT_AUDIT_FIELDS) {
      const value = raw[item.field];
      if (item.kind === 'money') {
        out[item.field] = value === null || value === undefined ? null : Number(value).toFixed(2);
      } else if (item.kind === 'text') {
        out[item.field] = value === null || value === undefined ? null : `${String(value).length} 字`;
      } else {
        out[item.field] = value === null || value === undefined ? null : String(value);
      }
    }
    return out;
  }

  /** 校验 media id 存在（防伪造引用） */
  private async assertMediaExists(ids: Array<string | null | undefined>): Promise<void> {
    const clean = ids.filter((v): v is string => !!v);
    if (!clean.length) return;
    const rows = await this.mediaService.findByIds(clean);
    if (rows.length !== clean.length) throw new BadRequestException('引用的媒体不存在');
  }

  async create(dto: CreateProductDto, actor: ProductActor) {
    await this.assertMediaExists([dto.coverMediaId, dto.videoMediaId, dto.videoCoverMediaId]);
    // 同事务：商品行 + operation_log 一起提交（审计缺失正是这次数据漂移查不动的根因）
    const saved = await this.dataSource.transaction(async (em) => {
      const row = await em.save(
        em.create(Product, {
          ...dto,
          serviceStatus: 2, // 新建默认下架，由管理员确认后上架（防误上架）
        }),
      );
      // 同事务重读：`after` 必须是**库里真实落下的值**（含 DB 默认值），
      // 而不是内存里那份可能缺字段的对象（见下面 update 里的详细说明）
      const fresh = (await em.findOne(Product, { where: { id: row.id } })) ?? row;
      await this.writeProductAudit(em, actor, {
        action: 'product:create',
        productId: String(fresh.id),
        name: fresh.name,
        after: ProductService.snapshotForAudit(fresh),
      });
      return fresh;
    });
    this.invalidatePublicProductCache();
    return saved;
  }

  async update(id: string, dto: UpdateProductDto, actor: ProductActor) {
    const existing = await this.productRepo.findOne({ where: { id } });
    if (!existing) {
      throw new NotFoundException('商品不存在');
    }
    if (dto.coverMediaId !== undefined || dto.videoMediaId !== undefined || dto.videoCoverMediaId !== undefined) {
      await this.assertMediaExists([dto.coverMediaId ?? existing.coverMediaId, dto.videoMediaId ?? existing.videoMediaId, dto.videoCoverMediaId ?? existing.videoCoverMediaId]);
    }
    const saved = await this.dataSource.transaction(async (em) => {
      // 行锁取最新值：审计的 before 必须是**本次改动的真实起点**
      // （并发两次保存时，普通 SELECT 可能读到旧快照，日志里就会出现"from 值对不上"）
      const product = await em.findOne(Product, { where: { id }, lock: { mode: 'pessimistic_write' } });
      if (!product) throw new NotFoundException('商品不存在');
      const before = ProductService.snapshotForAudit(product);
      Object.assign(product, dto);
      const row = await em.save(product);
      /**
       * 同事务重读拿 `after`（**必须**，不能用 save 的返回值）：
       *
       * `UpdateProductDto` 是 class-transformer 实例，本项目 target ES2023 → class field 语义下
       * **DTO 声明但请求里没传的字段在实例上是 `undefined`**；`Object.assign` 会把它们覆盖到实体上。
       * TypeORM 的 UPDATE 会跳过 undefined（所以**库里没变**），但"保存后的实体"会带着 undefined，
       * 直接拿它做快照就会出现**假 null**（实测：只改价格时日志写成「name XXX → null」，
       * 看起来像被清空了名字 —— 审计最忌讳这种似是而非的记录）。
       * 重读一次库里的真实值：既让审计写的是"改完到底是什么"，也让 PUT 的响应不再缺字段。
       */
      const fresh = (await em.findOne(Product, { where: { id } })) ?? row;
      await this.writeProductAudit(em, actor, {
        action: 'product:update',
        productId: String(fresh.id),
        name: fresh.name,
        before,
        after: ProductService.snapshotForAudit(fresh),
      });
      return fresh;
    });
    this.invalidatePublicProductCache();
    return saved;
  }

  async updateStatus(id: string, serviceStatus: number, actor: ProductActor) {
    const saved = await this.dataSource.transaction(async (em) => {
      const product = await em.findOne(Product, { where: { id }, lock: { mode: 'pessimistic_write' } });
      if (!product) throw new NotFoundException('商品不存在');
      const before = ProductService.snapshotForAudit(product);
      product.serviceStatus = serviceStatus;
      const row = await em.save(product);
      const fresh = (await em.findOne(Product, { where: { id } })) ?? row;
      await this.writeProductAudit(em, actor, {
        action: 'product:status',
        productId: String(fresh.id),
        name: fresh.name,
        before,
        after: ProductService.snapshotForAudit(fresh),
      });
      return fresh;
    });
    this.invalidatePublicProductCache();
    return saved;
  }

  /** 删除商品（负责人需求：无任何限制，无论有无订单记录直接删除；仅清理媒体挂载关联，历史订单快照不受影响） */
  async deleteProduct(id: string, actor: ProductActor) {
    const product = await this.productRepo.findOne({ where: { id } });
    if (!product) throw new NotFoundException('商品不存在');
    await this.dataSource.transaction(async (em) => {
      await em.delete(ProductMedia, { productId: id });
      await em.delete(Product, { id });
      // 删除也要留痕：记下**删除前的完整快照**（否则商品没了就再也说不清当时是什么价、什么名）
      await this.writeProductAudit(em, actor, {
        action: 'product:delete',
        productId: String(product.id),
        name: product.name,
        before: ProductService.snapshotForAudit(product),
        summary: `删除商品「${product.name}」（价格 ${Number(product.price).toFixed(2)}）`,
      });
    });
    this.invalidatePublicProductCache();
    return { ok: true };
  }

  /**
   * 批量移动商品到另一个分部（负责人 2026-10-05）
   *
   * 产品语义：把一个（或一批）**已存在**的商品从当前分部移到目标分部 ——
   * 名称、价格、单价单位、时长、图片、上下架状态等**一律保持原样**，只改归属。
   *
   * 为什么必须同时改 gameId 与 categoryId：本项目「游戏 ↔ 分部」是 1:1
   * （game46 ↔ division2、game47 ↔ division3），只改 division_id 会让商品
   * 挂在「目标分部 + 原游戏/原分类」下 —— 公开接口按 categoryId 过滤时查不到、
   * 管理端分类树里也自相矛盾。所以三个字段一起调，且目标分类必须属于目标游戏。
   *
   * 全流程一个事务：
   *   1) ids 去重 + 非空/上限校验（DTO 已校验，service 再兜一层，防内部调用绕过）
   *   2) 目标分部存在且上架 → 得到 targetGameId（不存在/已下架 → 中文 400）
   *   3) 指定的 targetCategoryId 必须属于目标游戏；不指定则按「原分类名」在目标游戏下
   *      自动匹配同名分类，匹配不到就在目标游戏下新建同名分类（用原分类的名字/图标/排序）
   *   4) 商品必须全部存在，缺一个 → 中文 400 **整批回滚**（不做部分成功）
   *   5) 逐条 UPDATE 只写 division_id / game_id / category_id
   *   6) operation_log 与数据变更**同事务**写入（谁、哪些 id、从哪到哪、新建了哪些分类）
   *
   * 幂等：已在目标分部的条目直接跳过并计数（skipped），不重复写、不报错。
   */
  async moveProducts(
    dto: { ids: string[]; targetDivisionId: string; targetCategoryId?: string },
    actor: { adminUserId: string; ip?: string | null; requestId?: string | null; path?: string; method?: string },
  ): Promise<MoveProductsResult> {
    const ids = [...new Set((dto.ids ?? []).map((v) => String(v)))];
    if (!ids.length) throw new BadRequestException('请选择要移动的商品');
    if (ids.length > 200) throw new BadRequestException('单次最多移动 200 个商品，请分批操作');

    const targetDivisionId = String(dto.targetDivisionId);

    return this.dataSource.transaction(async (em) => {
      // ---- 1) 目标分部（游戏 ↔ 分部 1:1，目标游戏由分部带出）----
      const divisionRows = await em.query<Array<{ id: string; game_id: string; name: string; status: number }>>(
        'SELECT id, game_id, name, status FROM division WHERE id = ? LIMIT 1',
        [targetDivisionId],
      );
      const targetDivision = divisionRows[0];
      if (!targetDivision) throw new BadRequestException('目标分部不存在，请重新选择');
      if (Number(targetDivision.status) !== 1) {
        throw new BadRequestException(`目标分部「${targetDivision.name}」已下架，请先上架该分部或改选其它分部`);
      }
      const targetGameId = String(targetDivision.game_id);

      // ---- 2) 商品必须全部存在（缺一个整批回滚，绝不部分成功）----
      const products = await em.getRepository(Product).find({ where: { id: In(ids) } });
      const foundIds = new Set(products.map((p) => String(p.id)));
      const missing = ids.filter((id) => !foundIds.has(id));
      if (missing.length) {
        throw new BadRequestException(`商品不存在（编号 ${missing.join('、')}），本次移动已整批取消，未改动任何数据`);
      }

      // ---- 3) 目标分类：显式指定 → 校验归属游戏；未指定 → 按原分类名匹配/新建 ----
      let fixedCategoryId: string | null = null;
      if (dto.targetCategoryId) {
        const cat = await em.getRepository(Category).findOne({ where: { id: String(dto.targetCategoryId) } });
        if (!cat) throw new BadRequestException('目标分类不存在，请重新选择');
        if (String(cat.gameId) !== targetGameId) {
          throw new BadRequestException(`分类「${cat.name}」不属于目标分部所在游戏，请重新选择`);
        }
        fixedCategoryId = String(cat.id);
      }

      const failed: { id: string; reason: string }[] = [];
      const createdCategories: { id: string; name: string }[] = [];
      const plans: MoveItemPlan[] = [];
      /** 原分类 id → 分类实体（同一批商品常来自同一分类，避免重复查库） */
      const sourceCategoryCache = new Map<string, Category | null>();
      /** 原分类名 → 目标游戏下的分类 id（同一批里同名只解析一次） */
      const resolvedByName = new Map<string, string>();
      let skipped = 0;

      for (const p of products) {
        const currentDivisionId = p.divisionId == null ? null : String(p.divisionId);
        // 幂等：已在目标分部 → 跳过并计数
        if (currentDivisionId === targetDivisionId) {
          skipped += 1;
          continue;
        }

        let toCategoryId: string;
        if (fixedCategoryId) {
          toCategoryId = fixedCategoryId;
        } else {
          const sourceCategoryId = String(p.categoryId);
          if (!sourceCategoryCache.has(sourceCategoryId)) {
            sourceCategoryCache.set(sourceCategoryId, await em.getRepository(Category).findOne({ where: { id: sourceCategoryId } }));
          }
          const sourceCategory = sourceCategoryCache.get(sourceCategoryId) ?? null;
          if (!sourceCategory) {
            // 数据异常（原分类被删）：给该条明确原因，其余条目照常移动
            failed.push({ id: String(p.id), reason: '原分类已不存在，无法自动匹配同名分类，请手动指定目标分类' });
            continue;
          }
          const matched = resolvedByName.get(sourceCategory.name);
          if (matched) {
            toCategoryId = matched;
          } else {
            // status ASC → 1（启用）优先；同状态取最小 id，保证多次移动落到同一分类
            const hit = await em.getRepository(Category).find({
              where: { gameId: targetGameId, name: sourceCategory.name },
              order: { status: 'ASC', id: 'ASC' },
            });
            if (hit.length) {
              toCategoryId = String(hit[0].id);
            } else {
              // 目标游戏下没有同名分类 → 自动新建（沿用原分类的名字/图标/排序，客户端展示一致）
              const created = await em.getRepository(Category).save(
                em.getRepository(Category).create({
                  gameId: targetGameId,
                  parentId: null,
                  name: sourceCategory.name,
                  iconMediaId: sourceCategory.iconMediaId,
                  sortOrder: sourceCategory.sortOrder,
                  status: 1,
                }),
              );
              toCategoryId = String(created.id);
              createdCategories.push({ id: toCategoryId, name: sourceCategory.name });
            }
            resolvedByName.set(sourceCategory.name, toCategoryId);
          }
        }

        plans.push({
          id: String(p.id),
          fromDivisionId: currentDivisionId,
          fromGameId: String(p.gameId),
          fromCategoryId: String(p.categoryId),
          toCategoryId,
        });
      }

      if (!plans.length) {
        if (failed.length) throw new BadRequestException(failed[0].reason);
        // 全部条目都已在目标分部：幂等成功（moved=0 / skipped=N），仍写一条审计
        return this.commitMoveAudit(em, actor, {
          ids, targetDivisionId, targetDivisionName: targetDivision.name, targetGameId,
          plans: [], skipped, failed, createdCategories,
        });
      }

      // ---- 4) 逐条更新：只写归属三字段，其它字段（price/name/priceUnit/coverMediaId/serviceStatus…）一个不碰 ----
      for (const plan of plans) {
        await em.update(
          Product,
          { id: plan.id },
          { divisionId: targetDivisionId, gameId: targetGameId, categoryId: plan.toCategoryId },
        );
      }

      // ---- 5) 审计（与数据变更同事务：要么都有，要么都没有）----
      const moved = await this.commitMoveAudit(em, actor, {
        ids, targetDivisionId, targetDivisionName: targetDivision.name, targetGameId,
        plans, skipped, failed, createdCategories,
      });
      return moved;
    }).then((result) => {
      // 归属变了 → 公开侧「按分部取商品」的缓存必须立刻失效（否则新分部最长 30s 看不到这些商品）
      this.invalidatePublicProductCache();
      /**
       * 批量移动可能**在目标游戏下自动新建同名分类**（见上方 `createdCategories`）——
       * `GET /public/categories` 同样挂在 30s 微缓存下，不失效的话客户端最长 30s
       * 看不到新分类（2026-10-08 补齐：与 `GameService.invalidatePublicCatalogCache` 同一口径）。
       */
      PublicCacheInterceptor.invalidate('/api/v1/public/categories');
      return result;
    });
  }

  /**
   * 写 operation_log（同事务）+ 返回移动结果
   *
   * requestBody 里放「谁、哪些 id、从哪到哪、新建了哪些分类」——
   * **只记归属字段**，不记价格/名称等业务字段（审计够用且日志体积可控）。
   * 关键字段排在前面的原因：requestBody 超长时会截断（operation_log.request_body 为 TEXT，
   * 与 OperationLogService 一致按 4000 字截断），截断不能把「移动到哪」截没了。
   */
  private async commitMoveAudit(
    em: EntityManager,
    actor: { adminUserId: string; ip?: string | null; requestId?: string | null; path?: string; method?: string },
    ctx: {
      ids: string[];
      targetDivisionId: string;
      targetDivisionName: string;
      targetGameId: string;
      plans: MoveItemPlan[];
      skipped: number;
      failed: { id: string; reason: string }[];
      createdCategories: { id: string; name: string }[];
    },
  ): Promise<MoveProductsResult> {
    const result: MoveProductsResult = {
      moved: ctx.plans.length,
      skipped: ctx.skipped,
      failed: ctx.failed,
      createdCategories: ctx.createdCategories,
    };

    let adminName: string | null = null;
    if (actor.adminUserId) {
      const rows = await em.query<Array<{ nickname?: string }>>('SELECT nickname FROM user WHERE id = ? LIMIT 1', [actor.adminUserId]);
      adminName = rows[0]?.nickname?.slice(0, 32) ?? null;
    }

    const summary = JSON.stringify({
      ids: ctx.ids,
      targetDivisionId: ctx.targetDivisionId,
      targetDivisionName: ctx.targetDivisionName,
      targetGameId: ctx.targetGameId,
      moved: result.moved,
      skipped: result.skipped,
      createdCategories: result.createdCategories,
      failed: result.failed,
      // 逐条「从哪到哪」（id 级可追溯；已跳过/失败的条目不在 plans 里）
      from: ctx.plans.map((p) => ({
        id: p.id,
        divisionId: p.fromDivisionId,
        gameId: p.fromGameId,
        categoryId: p.fromCategoryId,
        toCategoryId: p.toCategoryId,
      })),
    });

    await em.getRepository(OperationLog).save(
      em.getRepository(OperationLog).create({
        adminId: actor.adminUserId || null,
        adminName,
        module: 'product',
        action: 'product:move',
        method: actor.method ?? 'POST',
        path: actor.path ?? '/admin/products/move',
        requestBody: summary.length > 4000 ? `${summary.slice(0, 3999)}…` : summary,
        ip: actor.ip ?? null,
        requestId: actor.requestId ?? null,
        result: 'success',
      }),
    );

    return result;
  }

  // ---------- 商品媒体挂载（多图/视频，阶段 13） ----------

  async addMedia(productId: string, dto: { mediaId: string; mediaType?: string; isCover?: number; sortOrder?: number }) {
    const product = await this.productRepo.findOne({ where: { id: productId } });
    if (!product) throw new NotFoundException('商品不存在');
    await this.assertMediaExists([dto.mediaId]);
    try {
      await this.mediaRepo.save(
        this.mediaRepo.create({
          productId,
          mediaId: dto.mediaId,
          mediaType: dto.mediaType === 'video' ? 'video' : 'image',
          isCover: dto.isCover ? 1 : 0,
          sortOrder: dto.sortOrder ?? 0,
        }),
      );
    } catch (e) {
      // 重复挂载幂等（唯一约束 product_media.UQ_product_media）：返回现有列表，不报 500
      const err = e as { driverError?: { code?: string } };
      if (err.driverError?.code !== 'ER_DUP_ENTRY') throw e;
    }
    return this.mediaRepo.find({ where: { productId }, order: { sortOrder: 'ASC' } });
  }

  async removeMedia(productId: string, mediaRowId: string) {
    const row = await this.mediaRepo.findOne({ where: { id: mediaRowId, productId } });
    if (!row) throw new NotFoundException('媒体关联不存在');
    await this.mediaRepo.remove(row);
    return { ok: true };
  }

  // ---------- 公开接口（仅上架且启用，docs/03） ----------

  async publicList(q: { gameId?: string; categoryId?: string; divisionId?: string; page: number; pageSize: number }) {
    const where: Record<string, unknown> = { status: 1, serviceStatus: 1 };
    if (q.gameId) where.gameId = q.gameId;
    if (q.categoryId) where.categoryId = q.categoryId;
    /**
     * 分部筛选 + **「分部下架 = 其商品不再公开」**（2026-10-08）
     *
     * 原实现只写 `where.divisionId = q.divisionId`：不传分部时**完全不过滤分部状态** →
     * 负责人下架 4 个分部后，公开列表仍返回 26 条属于已下架分部（2/3/6）的商品
     * （实测：div1=9 条上架，div2/3/6 共 26 条挂在 status=0 的分部下）。
     *
     * 条件本体收口在 **唯一一处** `division/public-division-scope.ts`
     * （`publicDivisionFindWhere`：未挂分部的商品不受约束、显式请求的分部必须已上架）。
     * ⚠️ 若要恢复「分部下架但商品仍公开」，**改的就是下面这一行**（本文件），
     * 不需要动任何其它调用点。
     */
    where.divisionId = publicDivisionFindWhere(q.divisionId);

    /**
     * 【2026-10-04 性能专项】两处针对性改动：
     *
     * 1) **列裁剪**：原实现 `findAndCount` 走 `SELECT *`，把 `description` / `detail` /
     *    `service_flow` / `service_rules` / `attention` / `extra_json` 六个大字段全捞回来
     *    （前五个是 TEXT、extra_json 是 JSON），而列表响应只用到 10 个字段。
     *    商品详情页才需要那些文本，列表页捞它们纯属浪费 I/O 与 JSON 反序列化开销；
     *    数据量小的时候看不出来，但**响应体体积**是实打实的（这里直接决定弱网首屏）。
     * 2) **并行取图**：列表查完后还要查一次 media 路径。改成"列表查完 → 并行发起
     *    [总数查询, 媒体路径查询]"：总数与列表互不依赖，媒体路径只依赖列表结果，
     *    原来的 (列表) → (媒体) 串行会把两个 RTT 叠起来。
     */
    const list = await this.productRepo.find({
      where,
      // 只取列表真正要用的列（与下方 map 一一对应，不多取一个字节）
      select: {
        id: true,
        name: true,
        subtitle: true,
        gameId: true,
        categoryId: true,
        divisionId: true,
        price: true,
        priceUnit: true,
        estimateDurationMin: true,
        salesCount: true,
        coverMediaId: true,
        // 徽标文案 + 每周限购（负责人 2026-10-05）：列表卡要画徽标、下单页要提示限购，
        // 都属于「规则由服务端下发、客户端只展示」，必须出现在列表响应里（详情接口由实体整体带出）
        badgeText: true,
        weeklyLimit: true,
        // 列表短名（任务②，**列表专用**，详情/订单仍用完整 name）
        // + 限购口径（任务③：客户端只展示服务端文案，带上它只为"先渲染正确口径"，判定仍在服务端）
        listName: true,
        weeklyLimitByQuantity: true,
      },
      order: { sortOrder: 'ASC', id: 'DESC' },
      skip: (q.page - 1) * q.pageSize,
      take: q.pageSize,
    });

    const coverIds = list.map((p) => p.coverMediaId).filter((v): v is string => !!v);
    const [total, paths] = await Promise.all([
      this.productRepo.count({ where }),
      this.mediaService.pathsByIds(coverIds),
    ]);

    return {
      list: list.map((p) => ({
        id: p.id,
        name: p.name,
        subtitle: p.subtitle,
        gameId: p.gameId,
        categoryId: p.categoryId,
        divisionId: p.divisionId,
        price: p.price,
        priceUnit: p.priceUnit,
        estimateDurationMin: p.estimateDurationMin,
        salesCount: p.salesCount,
        coverMediaId: p.coverMediaId,
        // 徽标 / 每周限购（NULL = 不显示徽标 / 不限购；客户端按「非空才渲染」处理）
        badgeText: p.badgeText ?? null,
        weeklyLimit: p.weeklyLimit ?? null,
        // 列表短名（任务②）：**只给列表卡用**，NULL/空 → 客户端回退完整 name。
        // 顺带把限购口径 `weeklyLimitByQuantity` 一起下发（任务③）：客户端不做判定，
        // 只是让"刚进页面还没拿到 weekly-quota"的那一瞬间也按正确口径渲染。
        listName: p.listName ?? null,
        weeklyLimitByQuantity: Number(p.weeklyLimitByQuantity ?? 0) === 1 ? 1 : 0,
        coverUrl: (p.coverMediaId && paths.get(p.coverMediaId)) || null,
      })),
      total,
      page: q.page,
      pageSize: q.pageSize,
    };
  }

  /**
   * 公开商品详情（docs/03）：在商品行之外补齐**客户端详情页要用、但列表接口刻意不带的字段**
   *
   * 本轮（负责人 2026-10-05 商品详情页 v2 方案 B）新增三项，全部**只走详情接口**：
   *
   * | 字段 | 来源 | 为什么不在列表接口 |
   * |---|---|---|
   * | `effectiveOrderNotice` | `product.order_notice` → 否则 `system_setting.order_notice_default` | TEXT，列表已做列裁剪（迁移 1792000000000） |
   * | `orderNotice` | 商品级原始值（NULL = 继承） | 只给管理端/联调看"是否覆盖"，客户端一律用 effective |
   * | `orderPendingTakeTimeoutHours` | `system_setting.order_pending_take_timeout_hours`（默认 24） | 详情页提示条要拼「超 N 小时」，**客户端不许写死 24** |
   * | `divisionPlatformLabel` | `division.platform_label`（如「手游」） | 详情页三列「服务方式」= 平台 + 平台标签 |
   *
   * `orderPendingTakeTimeoutHours` 与 `effectiveOrderNotice` 并行取（互不依赖），不叠加 RTT。
   */
  async publicDetail(id: string) {
    const product = await this.productRepo.findOne({ where: { id, status: 1, serviceStatus: 1 } });
    if (!product) {
      throw new NotFoundException('商品不存在或已下架');
    }
    const media = await this.mediaRepo.find({ where: { productId: id }, order: { sortOrder: 'ASC' } });
    const mediaIds = [product.coverMediaId, product.videoMediaId, product.videoCoverMediaId, ...media.map((m) => m.mediaId)].filter((v): v is string => !!v);

    const [paths, defaultNotice, timeoutHours, division] = await Promise.all([
      this.mediaService.pathsByIds(mediaIds),
      // 平台默认须知：库里读不到（迁移没跑 / 被删）时回退代码常量，**绝不返回空**——
      // 返回空会让详情页的「下单须知」整块消失，看起来像功能坏了
      this.settings.text(ORDER_NOTICE_DEFAULT_KEY, ORDER_NOTICE_DEFAULT_TEXT),
      this.settings.value(ORDER_PENDING_TAKE_TIMEOUT_HOURS_KEY, ORDER_PENDING_TAKE_TIMEOUT_HOURS_DEFAULT),
      product.divisionId ? this.divisionRepo.findOne({ where: { id: product.divisionId } }) : Promise.resolve(null),
    ]);

    /**
     * 「分部下架 = 其商品不再公开」也要管**详情**（2026-10-08）
     *
     * 列表收口后，已经进过详情页/被客户端缓存住的深链仍能拿到已下架分部的商品；
     * 判定与列表**同一个口径**（`division/public-division-scope.ts` 的 `isDivisionPubliclyVisible`）：
     * 商品未挂分部 = 不受约束；挂了分部则以 `division.status = 1` 为准。
     * 错误文案与既有"不存在或已下架"逐字一致（客户端已有分支，不新增分支、不改返回结构）。
     */
    if (!isDivisionPubliclyVisible(division)) {
      throw new NotFoundException('商品不存在或已下架');
    }

    // 商品级优先（trim 后非空才算覆盖）；空串 / 纯空白 = 继承平台默认
    const ownNotice = (product.orderNotice ?? '').trim();
    return {
      ...product,
      coverUrl: (product.coverMediaId && paths.get(product.coverMediaId)) || null,
      videoUrl: (product.videoMediaId && paths.get(product.videoMediaId)) || null,
      videoCoverUrl: (product.videoCoverMediaId && paths.get(product.videoCoverMediaId)) || null,
      media: media.map((m) => ({
        id: m.id,
        mediaId: m.mediaId,
        mediaType: m.mediaType,
        isCover: m.isCover,
        url: paths.get(m.mediaId) ?? null,
      })),
      // 商品级原始值（null = 继承）；客户端/管理端判断"是否覆盖"用
      orderNotice: product.orderNotice ?? null,
      // 生效须知（已解析优先级，**客户端不做判断**）：详情页「下单须知」直接渲染这个
      effectiveOrderNotice: ownNotice.length ? ownNotice : defaultNotice,
      // 是否来自商品级覆盖（管理端/联调便于一眼看出继承还是覆盖）
      orderNoticeInherited: ownNotice.length === 0,
      // 超时小时数：提示条「超 N 小时无人接单」用，客户端不许写死
      orderPendingTakeTimeoutHours: timeoutHours,
      // 「服务方式」用的分部平台标签（如「手游」）；商品未挂分部 = ''
      divisionPlatformLabel: division?.platformLabel ?? '',
    };
  }
}
