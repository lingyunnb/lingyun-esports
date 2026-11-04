import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { Media } from '../media/media.entity';
import { Announcement } from './announcement.entity';
import { UpsertAnnouncementDto, UpsertBannerDto, UpsertModuleDto, UpsertTopWorkerDto } from './dto/home.dto';
import { HomeBanner } from './home-banner.entity';
import { HomeModule } from './home-module.entity';
import { TopWorker } from './top-worker.entity';

/** 宣传图公开视图（客户端轮播消费；字段名与管理端返回保持一致，少一层映射） */
export interface BannerView {
  id: string;
  title: string;
  subtitle: string;
  imageMediaId: string | null;
  imageUrl: string;
  /**
   * 图片**原始**宽 / 高（像素；2026-10-16 新增，取自 `media.width` / `media.height`）
   *
   * 为什么必须下发（负责人 2026-10-16 原话「让图显示全」）：
   * 客户端轮播框体此前是**写死的 156dp**（≈2.5:1），而运营图是 1920×1080（16:9）——
   * 配 `BoxFit.cover` 就会**上下各裁一块**（顶部文字与底部内容一起被切掉）。
   * 修法不是把 cover 换成 contain（通栏图不能留黑边/露底色），而是**让框体高度跟着真实宽高比走**，
   * 而"真实宽高比"只有服务端知道 → 故随宣传图一起下发。
   *
   * **媒体缺失 / 尺寸未登记（任一为空、非数、≤0）时为 `null`**：客户端据此回落既有 156dp，
   * 绝不让老数据或脏数据算出 0 高或异常高的框体。
   */
  imageWidth: number | null;
  imageHeight: number | null;
  linkType: string;
  linkValue: string;
  sortOrder: number;
  /** 仅管理端列表返回：1 显示 / 2 隐藏 */
  visible?: number;
  startAt: Date | null;
  endAt: Date | null;
}

/** 图片尺寸（`media` 侧的两列），[BannerView] 组装用 */
interface BannerImageDims {
  width: number | null;
  height: number | null;
}

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
const BANNER_PUBLIC_PATH = '/api/v1/public/banners';
const ANNOUNCEMENT_PUBLIC_PATH = '/api/v1/public/announcements';
/** 首页聚合 `GET /public/home` 的**唯一内容**就是公告列表（见 [publicHome]）→ 公告写入必须一起失效 */
const HOME_PUBLIC_PATH = '/api/v1/public/home';
/** `home_module` 驱动的公开文案：`GET /public/about`（about_us）与 `GET /public/privacy`（privacy_policy） */
const ABOUT_PUBLIC_PATH = '/api/v1/public/about';
const PRIVACY_PUBLIC_PATH = '/api/v1/public/privacy';

/** 首页内容服务：全部由管理端配置，客户端零硬编码 */
@Injectable()
export class HomeService {
  constructor(
    @InjectRepository(HomeModule) private readonly moduleRepo: Repository<HomeModule>,
    @InjectRepository(HomeBanner) private readonly bannerRepo: Repository<HomeBanner>,
    @InjectRepository(Announcement) private readonly announcementRepo: Repository<Announcement>,
    @InjectRepository(TopWorker) private readonly topWorkerRepo: Repository<TopWorker>,
  ) {}

  /*
   * 【2026-10-05 删除首页内容广播 `home:updated`】
   *
   * 删除依据：全仓 grep `home:updated` 只有两处 —— 本文件的 emit，与
   * `apps/boss-app/lib/pages/home_page.dart` 的 `RealtimeClient.shared.on('home:updated', ...)`。
   * 后者是零 import 的死代码（已删除），因此这条广播**没有任何订阅方**，
   * 每次管理端保存公告/Banner/打手都会向全部在线连接（含工作端 App、admin-web）
   * 发一条无人处理的消息，纯属浪费。
   *
   * 为什么不需要替代方案：公告/文案的可见性由客户端**切回页面时拉取**保证
   * （服务页 `refreshSignal` + `didChangeAppLifecycleState` + 下拉 `force:true`；
   * 公告列表页另有下拉 `forceRefresh` 绕 SWR）。
   * 若日后确需服务端推送公告，应新增**有明确订阅方**的事件，而不是复用这条死事件。
   */

  /** 公开模块内容（关于/隐私政策等设置页模块，管理端可编辑） */
  async publicModule(moduleKey: string) {
    const m = await this.moduleRepo.findOne({ where: { moduleKey, visible: 1 } });
    if (!m) return { title: '', content: '' };
    return { title: m.title, content: m.content ?? '' };
  }

  /**
   * 公开：首页聚合数据。**2026-10-05 起只剩 `announcements`**
   *
   * 为什么删掉另外五个字段（`clubIntro` / `activity` / `orderButton` / `banners` / `topWorkers`）：
   * 它们的唯一读取方是 `apps/boss-app/lib/pages/home_page.dart`（旧首页，全仓零 import = 死代码），
   * 该文件已删除；admin-web 亦无 banner/top-workers 调用方（grep 零命中）。
   * 这几个字段对应的配置入口（首页 Banner / 优秀打手 / 俱乐部介绍 / 活动 / 下单按钮）
   * 在「首页管理」拆分为「公告管理」时已从管理端下架，属于**无写入方、无读取方**的死字段。
   *
   * 同时删掉了 `media.pathsByIds()` 调用（它只为给 banner/topWorkers 拼图片地址而存在）
   * 与 `moduleRepo` 查询 —— 少两次查询、少一次媒体表往返。
   */
  async publicHome() {
    return { announcements: await this.publicAnnouncements(10) };
  }

  /**
   * 公开：公告列表（置顶优先 + 时间倒序，不含正文）
   *
   * `limit` 省略 = 返回全部（公告列表页用）；`publicHome()` 传 10 保持首页聚合原有上限。
   * 排序用 `pinned DESC, createdAt DESC, id DESC`：置顶优先，同组内按发布时间倒序；
   * 末位 `id DESC` 是同秒发布时的稳定兜底（时间戳精度只到毫秒）。
   */
  async publicAnnouncements(limit?: number) {
    const rows = await this.announcementRepo.find({
      where: { visible: 1 },
      order: { pinned: 'DESC', createdAt: 'DESC', id: 'DESC' },
      ...(limit ? { take: limit } : {}),
    });
    return rows.map((a) => ({ id: a.id, title: a.title, summary: a.summary, pinned: a.pinned, createdAt: a.createdAt }));
  }

  async publicAnnouncementDetail(id: string) {
    const a = await this.announcementRepo.findOne({ where: { id, visible: 1 } });
    if (!a) {
      throw new NotFoundException('公告不存在');
    }
    return { id: a.id, title: a.title, summary: a.summary, content: a.content, pinned: a.pinned, createdAt: a.createdAt };
  }

  // ---------- 管理端 ----------

  adminModules() {
    return this.moduleRepo.find({ order: { sortOrder: 'ASC' } });
  }

  async updateModule(moduleKey: string, dto: UpsertModuleDto) {
    let module = await this.moduleRepo.findOne({ where: { moduleKey } });
    if (!module) {
      module = this.moduleRepo.create({ moduleKey, title: dto.title ?? moduleKey });
    }
    Object.assign(module, dto);
    const saved = await this.moduleRepo.save(module);
    // 关于/隐私文案改动立刻可见（两条公开路径一起失效，见 invalidatePublicModuleCache）
    this.invalidatePublicModuleCache();
    return saved;
  }

  // ---------- 宣传图（首页顶部通栏轮播，2026-10-05 任务②） ----------

  /**
   * 宣传图写入后立刻失效公开接口的进程内微缓存
   *
   * `/public/banners` 挂在 `PublicCacheInterceptor` 的 30s 微缓存下（字典类只读、低并发），
   * 而这一层**没有写入侧失效钩子** → 管理端刚改完「上下架 / 时间区间 / 标题」，
   * 公开接口最长 30s 仍是旧值。口径与分部、商品两次修正完全一致：
   * **内容随管理端配置变化的数据，写入时必须配失效钩子**（有明确要求"即时生效"）。
   */
  private invalidatePublicBannerCache(): void {
    PublicCacheInterceptor.invalidate(BANNER_PUBLIC_PATH);
  }

  /**
   * 公告写入后立刻失效公开接口的进程内微缓存（**2026-10-08 缺口修复**）
   *
   * 公告同时是两个已登记前缀的数据源，**两个都必须失效**：
   * - `GET /public/announcements`（公告列表页）
   * - `GET /public/home`（首页聚合当前只剩 `announcements`，见 [publicHome]）
   *
   * `home` 模块此前只给宣传图配了失效钩子，公告的新增/编辑/删除/上下架
   * （`visible`）**最长 30s 才在客户端可见** —— 口径与宣传图那次修正完全一致：
   * **内容随管理端配置变化的数据，写入时必须配失效钩子**。
   *
   * ⚠️ **本模块新增任何公告写路径都必须调用本函数**。
   */
  private invalidatePublicAnnouncementCache(): void {
    PublicCacheInterceptor.invalidate(ANNOUNCEMENT_PUBLIC_PATH);
    PublicCacheInterceptor.invalidate(HOME_PUBLIC_PATH);
  }

  /**
   * 通用模块文案（`home_module`）写入后立刻失效公开接口的进程内微缓存（**2026-10-08 缺口修复**）
   *
   * `home_module` 的两行配置就是 `GET /public/about`（`about_us`）与
   * `GET /public/privacy`（`privacy_policy`）的全部内容（见 [publicModule]），
   * 两者都挂在 30s 微缓存下；不失效的话管理端改完文案，设置页最长 30s 还是旧的。
   *
   * 一条 SQL 更新对应两条公开路径，故这里两个前缀一起清（`invalidate` 按前缀删，不会误伤别的键）。
   * ⚠️ **本模块新增任何 `home_module` 写路径都必须调用本函数**。
   */
  private invalidatePublicModuleCache(): void {
    PublicCacheInterceptor.invalidate(ABOUT_PUBLIC_PATH);
    PublicCacheInterceptor.invalidate(PRIVACY_PUBLIC_PATH);
  }

  /**
   * 公开：宣传图轮播列表（**无需登录**）
   *
   * 三个过滤条件，缺一不可：
   * 1. `visible = 1` —— **本表的 visible 是 1 显示 / 2 隐藏，不是 0/1**
   *    （建表时 `default 1`、管理端 DTO `@IsIn([1, 2])` 都是这个口径）。
   *    写成 `visible = 1` 而不是 `visible != 0`：值域里根本没有 0，
   *    用 `!= 0` 会把将来任何写坏的值（如 3）当成"显示"漏出去。
   * 2. 时间区间 —— `startAt` / `endAt` 为 NULL 时**该端不限制**，不是"立即失效"。
   *    所以条件是 `(start_at IS NULL OR start_at <= NOW()) AND (end_at IS NULL OR end_at >= NOW())`，
   *    **绝不能用 BETWEEN**：BETWEEN 遇 NULL 恒为假，会把「只配了结束时间」的活动整条吞掉。
   * 3. 排序 `sortOrder ASC, id ASC` —— 排序相同按 id 升序（先建的在前），
   *    保证多次请求顺序稳定、不会因为排序值相等而每次抖动。
   *
   * 客户端只拿 `imageMediaId` 拼图片地址（走 `/media/public/:id`），
   * `imageUrl` 是历史兼容字段（新数据为空串），一起下发只为兼容未来可能出现的外链图。
   *
   * 【2026-10-16 新增 `imageWidth` / `imageHeight`】**复用这一条查询**（见 [bannerQuery] 的
   * LEFT JOIN），**没有为这两个字段新开任何查询** —— 代价说明写在那里。
   */
  async publicBanners(): Promise<BannerView[]> {
    const now = new Date();
    const { entities, raw } = await this.bannerQuery()
      .where('b.visible = :visible', { visible: 1 })
      // 时间区间：NULL = 该端不限制（**不是**"立即失效"）。
      // 括号必须显式写出来 —— 后面还有可见性条件，靠 SQL 优先级容易写出歧义。
      .andWhere('(b.start_at IS NULL OR b.start_at <= :now)', { now })
      .andWhere('(b.end_at IS NULL OR b.end_at >= :now)', { now })
      .orderBy('b.sort_order', 'ASC')
      .addOrderBy('b.id', 'ASC')
      .getRawAndEntities();
    return this.toBannerViews(entities, raw as Array<Record<string, unknown>>);
  }

  /**
   * 宣传图读取的**唯一**查询构造器（LEFT JOIN `media` 取图片尺寸）
   *
   * ## 为什么要联表（以及为什么**不**新开查询）
   * `imageWidth` / `imageHeight` 来自 `media.width` / `media.height`，而 `home_banner`
   * 只有 `image_media_id`。三种取法里选的是**同一条查询里 LEFT JOIN**：
   *   - ✅ **本方案**：`LEFT JOIN media ON media.id = b.image_media_id` + `addSelect` 两列。
   *     代价 = **每个宣传图行一次主键等值查找**（`media.id` 是主键、`home_banner` 只有个位数行），
   *     实测在同一批 2–21ms 的子查询里**不可测量**；数据库往返次数**一次都没多**。
   *   - ❌ 另开一条 `SELECT width,height FROM media WHERE id IN (...) `：多一次往返（跨境 RTT ≈ 245ms 才是真成本），
   *     且要维护"两批数据的对齐"，属于典型的自造 N+1 风险。
   *   - ❌ `leftJoinAndSelect('b.image', ...)`：那会把 `media` 整个实体（含 `fileKey` / `sha256` /
   *     `uploaderId` 等）塞进响应，凭空扩大公开返回面（多余字段 + 泄露面），故只 select 两列。
   *
   * ## 为什么用 LEFT JOIN 而不是 INNER JOIN
   * `image_media_id` 可空（`imageUrl` 老数据 / 只配了标题没配图）；内连接会把这类行**整条丢掉** ——
   * 那是"改一个字段顺手删数据"，比显示不全严重得多。左连接下这两列是 NULL，正是"媒体缺失 → null"的语义。
   *
   * ⚠️ 这是**公开只读**那一发要复用的查询；`getRawAndEntities()` 的 `raw` 与 `entities`
   * 靠 `b_id` 显式对齐（不依赖数组下标），因此将来若有人加了 `leftJoinAndSelect` 导致行数变化也不会错配。
   */
  private bannerQuery() {
    return this.bannerRepo
      .createQueryBuilder('b')
      .leftJoin(Media, 'img', 'img.id = b.image_media_id')
      .addSelect(['img.width', 'img.height']);
  }

  /** 管理端列表：不过滤 visible / 时间（运营要看到全部，包括已过期与隐藏的） */
  async adminBanners(): Promise<BannerView[]> {
    const { entities, raw } = await this.bannerQuery()
      .orderBy('b.sort_order', 'ASC')
      .addOrderBy('b.id', 'DESC')
      .getRawAndEntities();
    return this.toBannerViews(entities, raw as Array<Record<string, unknown>>, { withVisible: true });
  }

  /**
   * 新建宣传图
   *
   * 【坑②】`imageUrl` 必须显式落空串：`home_banner.image_url` 是 `NOT NULL`，
   * 历史上**没有默认值** → 管理端只传 `imageMediaId`（新版上传通道只回填 media id）时，
   * TypeORM 生成的 INSERT 不含该列 → MySQL strict 模式直接
   * `ER_NO_DEFAULT_FOR_FIELD: Field 'image_url' doesn't have a default value` → 新建 500。
   * migration `1798000000000` 已给该列补 `DEFAULT ''`（双保险），这里再显式兜一层：
   * 这样即使有人回滚了迁移、或换了 synchronize 环境的库，新建也不会失败。
   */
  async createBanner(dto: UpsertBannerDto) {
    const created = await this.bannerRepo.save(
      this.bannerRepo.create({
        title: dto.title ?? '宣传图',
        subtitle: dto.subtitle ?? null,
        imageUrl: dto.imageUrl ?? '', // 坑②：NOT NULL 列必须有值
        imageMediaId: dto.imageMediaId == null ? null : String(dto.imageMediaId),
        linkType: dto.linkType ?? 'none',
        linkValue: dto.linkValue ?? null,
        sortOrder: dto.sortOrder ?? 0,
        visible: dto.visible ?? 1,
        startAt: this.parseDate(dto.startAt),
        endAt: this.parseDate(dto.endAt),
      }),
    );
    this.invalidatePublicBannerCache();
    // 回读一次（含 `media` 尺寸）：新建响应里 `imageWidth/imageHeight` 必须与列表一致，
    // 不能因为"刚 save 出来的实体没联表"就恒回 null（那会把有尺寸的图说成没尺寸）
    return (await this.readBannerWithDims(String(created.id))) ?? this.toBannerView(created);
  }

  async updateBanner(id: string, dto: UpsertBannerDto) {
    // 这里用**联表读**替代原先的 `findOne`（**不是新增查询** —— 同一发读，顺带把尺寸取回来）：
    // 下面据此判断"这次到底换没换图"，从而决定要不要回读，公开路径之外不再多打往返。
    const before = await this.bannerQuery().where('b.id = :id', { id }).getRawAndEntities();
    const row = before.entities[0];
    if (!row) throw new NotFoundException('宣传图不存在');
    const beforeMediaId = row.imageMediaId == null ? null : String(row.imageMediaId);
    // 逐字段判定（不用 Object.assign(dto)）：只有**请求里真的出现**的字段才覆盖，
    // 且 `startAt` / `endAt` 传空串等于"清空投放时间"（回到不限制），不是"不改"
    if (dto.title !== undefined) row.title = dto.title;
    if (dto.subtitle !== undefined) row.subtitle = dto.subtitle || null;
    if (dto.imageUrl !== undefined) row.imageUrl = dto.imageUrl || '';
    if (dto.imageMediaId !== undefined) row.imageMediaId = dto.imageMediaId ? String(dto.imageMediaId) : null;
    if (dto.linkType !== undefined) row.linkType = dto.linkType;
    if (dto.linkValue !== undefined) row.linkValue = dto.linkValue || null;
    if (dto.sortOrder !== undefined) row.sortOrder = dto.sortOrder;
    if (dto.visible !== undefined) row.visible = dto.visible;
    if (dto.startAt !== undefined) row.startAt = this.parseDate(dto.startAt);
    if (dto.endAt !== undefined) row.endAt = this.parseDate(dto.endAt);
    if (!row.imageUrl) row.imageUrl = ''; // 坑②兜底：绝不把 NOT NULL 列写成 undefined
    const saved = await this.bannerRepo.save(row);
    this.invalidatePublicBannerCache();
    // 尺寸只跟 `image_media_id` 走：**换了图**才需要重读 `media`（一次主键级联表读）；
    // 没换图就复用上面那次读到的尺寸（`entities[0]` 与 `saved` 是同一个对象，字段已就地更新）。
    if ((saved.imageMediaId == null ? null : String(saved.imageMediaId)) !== beforeMediaId) {
      const fresh = await this.readBannerWithDims(String(saved.id));
      if (fresh) return fresh;
    }
    return this.toBannerViews(before.entities, before.raw as Array<Record<string, unknown>>)[0] ?? this.toBannerView(saved);
  }

  async deleteBanner(id: string) {
    await this.bannerRepo.delete(id);
    this.invalidatePublicBannerCache();
    return { ok: true };
  }

  /**
   * 入参时间解析：`undefined` / `null` / `''` → `null`（= 该端不限制）
   *
   * 为什么不直接用对象展开：`''` 传给 MySQL datetime 会变成 `0000-00-00` 或被 strict 模式拒绝；
   * 这里统一收敛成 NULL，语义与实体注释一致。
   */
  private parseDate(v: string | null | undefined): Date | null {
    if (v === undefined || v === null) return null;
    const s = String(v).trim();
    if (!s) return null;
    const d = new Date(s);
    return Number.isNaN(d.getTime()) ? null : d;
  }

  /** 实体 → 公开视图（字段名统一，`imageUrl` 空串归一成 ''，避免前端拿到 null 显示 "null"） */
  private toBannerView(b: HomeBanner, dims: BannerImageDims | null = null): BannerView {
    return {
      id: String(b.id),
      title: b.title ?? '',
      subtitle: b.subtitle ?? '',
      imageMediaId: b.imageMediaId == null ? null : String(b.imageMediaId),
      imageUrl: b.imageUrl ?? '',
      // 尺寸缺失（LEFT JOIN 未命中 / 该列为 NULL+0+负数）→ null，客户端回落 156dp
      imageWidth: dims?.width ?? null,
      imageHeight: dims?.height ?? null,
      linkType: b.linkType ?? 'none',
      linkValue: b.linkValue ?? '',
      sortOrder: Number(b.sortOrder ?? 0),
      startAt: b.startAt ?? null,
      endAt: b.endAt ?? null,
    };
  }

  /**
   * `getRawAndEntities()` 的 raw 行 → `bannerId → 尺寸`（按 `b_id` 对齐，不依赖数组下标）
   *
   * 尺寸的**清洗口径只有这一处**：`media.width/height` 是可空 int unsigned 列，
   * 但"能查出来"不等于"能用" —— `null`、`NaN`、`0`、负数一律归成 `null`（= 客户端回落固定高度）。
   * 为什么连 0 都要挡：客户端会拿 `w / h` 定高，`h = 0` 会算出 `Infinity`（框体高度异常），
   * 这类脏数据必须在**服务端**就收敛成"没有尺寸"，而不是指望每个客户端各自防一遍。
   */
  private dimsByBannerId(raw: Array<Record<string, unknown>>): Map<string, BannerImageDims> {
    const dims = new Map<string, BannerImageDims>();
    for (const r of raw) {
      const id = r?.['b_id'] == null ? '' : String(r['b_id']);
      if (!id) continue;
      dims.set(id, { width: this.positiveNumberOrNull(r['img_width']), height: this.positiveNumberOrNull(r['img_height']) });
    }
    return dims;
  }

  /** 正数才保留，其余（null / undefined / NaN / ≤0）→ null */
  private positiveNumberOrNull(v: unknown): number | null {
    if (v === null || v === undefined) return null;
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  /** 实体 + raw → 视图列表（`withVisible` 只有管理端列表传 true，公开视图不含该字段） */
  private toBannerViews(
    entities: HomeBanner[],
    raw: Array<Record<string, unknown>>,
    opts: { withVisible?: boolean } = {},
  ): BannerView[] {
    const dims = this.dimsByBannerId(raw);
    return entities.map((b) => {
      const view = this.toBannerView(b, dims.get(String(b.id)) ?? null);
      return opts.withVisible ? { ...view, visible: Number(b.visible) } : view;
    });
  }

  /**
   * 写路径回读一行（含图片尺寸），用于让 `POST/PUT/PATCH` 的响应与列表口径一致
   *
   * 代价说清：管理端**写操作**（非热路径）多一次**主键级联表读**（`LEFT JOIN media ON media.id`）。
   * 为什么值得：不读的话新建/编辑响应里 `imageWidth`/`imageHeight` 恒为 `null`，
   * 而"这条记录到底有没有尺寸"只有 `media` 知道 —— 返回假 null 就是**错数据**（比慢 2ms 糟得多）。
   * 公开读路径（`/public/banners`、`/public/home`）**一次查询都没多**，见 [bannerQuery]。
   */
  private async readBannerWithDims(id: string): Promise<BannerView | null> {
    const { entities, raw } = await this.bannerQuery()
      .where('b.id = :id', { id })
      .getRawAndEntities();
    if (!entities.length) return null;
    return this.toBannerViews(entities, raw as Array<Record<string, unknown>>)[0] ?? null;
  }

  adminAnnouncements() {
    return this.announcementRepo.find({ order: { pinned: 'DESC', sortOrder: 'ASC', id: 'DESC' } });
  }

  async createAnnouncement(dto: UpsertAnnouncementDto) {
    const created = await this.announcementRepo.save(this.announcementRepo.create(dto));
    // 新增公告后 `/public/announcements` 与 `/public/home` 立刻可见
    this.invalidatePublicAnnouncementCache();
    return created;
  }

  async updateAnnouncement(id: string, dto: UpsertAnnouncementDto) {
    const row = await this.announcementRepo.findOne({ where: { id } });
    if (!row) throw new NotFoundException('公告不存在');
    Object.assign(row, dto);
    const saved = await this.announcementRepo.save(row);
    // 编辑（含置顶 / 排序 / visible 上下架）后立刻可见
    this.invalidatePublicAnnouncementCache();
    return saved;
  }

  async deleteAnnouncement(id: string) {
    await this.announcementRepo.delete(id);
    // 删除后立刻消失
    this.invalidatePublicAnnouncementCache();
    return { ok: true };
  }

  adminTopWorkers() {
    return this.topWorkerRepo.find({ order: { sortOrder: 'ASC', id: 'DESC' } });
  }

  async createTopWorker(dto: UpsertTopWorkerDto) {
    const exists = await this.topWorkerRepo.findOne({ where: { workerId: dto.workerId } });
    if (exists) throw new NotFoundException('该工作端已在展示列表');
    const created = await this.topWorkerRepo.save(this.topWorkerRepo.create(dto));
    return created;
  }

  async updateTopWorker(id: string, dto: UpsertTopWorkerDto) {
    const row = await this.topWorkerRepo.findOne({ where: { id } });
    if (!row) throw new NotFoundException('记录不存在');
    Object.assign(row, dto);
    const saved = await this.topWorkerRepo.save(row);
    return saved;
  }

  async deleteTopWorker(id: string) {
    await this.topWorkerRepo.delete(id);
    return { ok: true };
  }
}
