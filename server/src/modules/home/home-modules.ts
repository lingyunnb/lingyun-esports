import { BadRequestException } from '@nestjs/common';

/**
 * 首页三模块配置（负责人 2026-10-18：「热门游戏 / 精选服务 / 人气打手 可以在管理端更改」）
 *
 * ## 要解决的问题
 *
 * 首页这三块的**条数与排序口径原本硬编码在客户端**（`services_page.dart` 里
 * `take(8)` / `_topPlayersOf()` 固定取 4 / 分部按服务端 `sort_order`），
 * 运营想「这周只推 3 个游戏」「精选服务按价格从低到高」就必须发版 —— 与
 * `platform_commission_rate`（CLAUDE.md 结构规则 8：比例/口径类一律后台可配）同一条铁律冲突。
 *
 * 因此给三块各自一个**可控开关 + 条数 + 排序口径**（不是让管理端随便排版：
 * 只开放这三项，页面结构与视觉一律不动，避免"管理端一改首页就散架"）。
 *
 * ## 落库形状（`system_setting` 一行，`is_high_security = 0`）
 *
 * ```json
 * {
 *   "value": {
 *     "hotGames": { "enabled": true, "limit": 3, "order": "onlineCount" },
 *     "products": { "enabled": true, "limit": 8, "order": "sales" },
 *     "players":  { "enabled": true, "limit": 4, "order": "completedOrders" }
 *   }
 * }
 * ```
 *
 * - 外层 `{"value": ...}` 与 `order_notice_default` / `recharge_config` / `withdraw_config`
 *   **逐字同一套约定**（`SystemSettingService` 只认 `cfg_value.value`），不引入第二套。
 * - `is_high_security = 0`：它只决定"首页展示哪些块、几块"，不动钱、不动权限、不动数据可见性
 *   → 普通管理员即可改（与抽成比例/提现门槛那类 `is_high_security = 1` 的**刻意不同**）。
 *
 * ## 读侧（`GET /public/home` 聚合里的 `homeModules`）
 *
 * **每次实时读库、无缓存**（`SystemSettingService.get()` 走 `setting_key` 唯一索引，主键级开销）：
 * 管理端保存完，**下一次首页请求即生效**，不存在"改了要等 TTL"的窗口。
 * 聚合接口本身在 `PublicCacheInterceptor` 里是 `no-store`（见该文件 `/api/v1/public/home` 那段），
 * 所以这条配置**没有需要失效的缓存**。
 *
 * ## 三档校验（读侧宽松、写侧严格，与 `recharge-config` 同姿势）
 *
 * - 写侧 [assertHomeModules]：非法值一律**中文 400**（管理端立刻看到原因，不会"存进去但其实没生效"）；
 * - 读侧 [parseHomeModules]：**永不抛**，逐字段回退默认值 —— 配置行缺失/被手工改坏时
 *   首页必须照常出内容（红线：不许因为拿不到配置就白屏）；
 * - 客户端（`services_page.dart`）还有第三层：字段缺失/类型不对同样回退同一份默认值。
 *
 * 三处默认值必须**逐字一致**（本文件的 `HOME_MODULES_DEFAULT` 是唯一出处）。
 */

/** 配置在 `system_setting` 里的 key */
export const HOME_MODULES_KEY = 'home_modules';

/** 该配置项的 description（写进 system_setting，管理端「全部配置项」表格直接显示） */
export const HOME_MODULES_DESCRIPTION =
  '首页三模块（热门游戏/精选服务/人气打手）：启用开关 + 条数 + 排序口径；普通配置，改完下一次请求即生效';

/** 热门游戏的排序口径：真实在线人数 / 管理端分部排序（`division.sort_order`） */
export type HomeHotGamesOrder = 'onlineCount' | 'sortOrder';
/** 精选服务的排序口径：销量 / 价格（低到高）/ 上架时间（新到旧） */
export type HomeProductsOrder = 'sales' | 'price' | 'createdAt';
/** 人气打手的排序口径：接单数 / 好评率 */
export type HomePlayersOrder = 'completedOrders' | 'satisfiedRate';

/** 单块的配置本体 */
export interface HomeModuleRule<O extends string> {
  /** false → 该块（**含标题**）整块不渲染 */
  enabled: boolean;
  /** 展示条数（含边界，见各块的 MAX 常量） */
  limit: number;
  /** 排序口径 */
  order: O;
}

/** 首页三模块配置（`cfg_value.value` 的形状） */
export interface HomeModulesConfig {
  hotGames: HomeModuleRule<HomeHotGamesOrder>;
  products: HomeModuleRule<HomeProductsOrder>;
  players: HomeModuleRule<HomePlayersOrder>;
}

/** 热门游戏条数上限：分部数量本来就少（当前 5 个），给 10 已足够，再多只是把首页拉长 */
export const HOME_HOT_GAMES_LIMIT_MAX = 10;
/** 精选服务 / 人气打手条数上限（横向卡片：超过 20 张没人会滑到底，且陪玩每张都带一张头像图） */
export const HOME_MODULE_LIMIT_MAX = 20;

/** 各块允许的排序口径（写侧枚举校验 + 读侧回退白名单） */
export const HOME_HOT_GAMES_ORDERS: readonly HomeHotGamesOrder[] = ['onlineCount', 'sortOrder'];
export const HOME_PRODUCTS_ORDERS: readonly HomeProductsOrder[] = ['sales', 'price', 'createdAt'];
export const HOME_PLAYERS_ORDERS: readonly HomePlayersOrder[] = ['completedOrders', 'satisfiedRate'];

/**
 * 默认值 = 改动前客户端硬编码的那一套（**行为零变化**）
 *
 * | 块 | 默认条数 | 默认口径 | 改动前客户端 |
 * |---|---|---|---|
 * | 热门游戏 | 3 | `onlineCount` | 分部全量（`/divisions/grouped` 有几条显示几条） |
 * | 精选服务 | 8 | `sales` | `_allProducts.take(8)` |
 * | 人气打手 | 4 | `completedOrders` | `_topPlayersOf()` 按接单量降序取前 4 |
 *
 * ⚠️ 热门游戏默认 3（负责人本次给定）：分部多于 3 个时首页只展示前 3 个，
 * 其余仍可从「全部游戏」进入 —— 这是**有意的**版面收口，不是丢数据。
 */
export const HOME_MODULES_DEFAULT: HomeModulesConfig = {
  hotGames: { enabled: true, limit: 3, order: 'onlineCount' },
  products: { enabled: true, limit: 8, order: 'sales' },
  players: { enabled: true, limit: 4, order: 'completedOrders' },
};

/** 原始值的人读描述（错误提示里带上，便于运营自查；与 recharge-config 同口径） */
function describeRaw(raw: unknown): string {
  if (raw === undefined) return '未填写';
  if (raw === null) return 'null';
  if (typeof raw === 'string') return `"${raw.slice(0, 20)}"`;
  if (typeof raw === 'number' || typeof raw === 'boolean') return String(raw);
  if (Array.isArray(raw)) return '数组';
  if (typeof raw === 'object') return '对象';
  return typeof raw;
}

/** 整数解析（接受 "3" 这类字符串并规整；不合法返回 null） */
function toInt(raw: unknown): number | null {
  if (typeof raw === 'number') return Number.isInteger(raw) ? raw : null;
  if (typeof raw === 'string' && raw.trim() !== '') {
    const n = Number(raw.trim());
    return Number.isInteger(n) ? n : null;
  }
  return null;
}

/** 单块默认值（`HOME_MODULES_DEFAULT` 的对应字段，供读侧逐字段回退） */
const DEFAULTS = {
  hotGames: HOME_MODULES_DEFAULT.hotGames,
  products: HOME_MODULES_DEFAULT.products,
  players: HOME_MODULES_DEFAULT.players,
} as const;

/**
 * 单块宽松解析（**永不抛**）：缺字段 / 类型不对 → 回退默认值
 *
 * `maxLimit` 与 `orders` 由调用方给出，保证"读侧回退"和"写侧校验"用的是同一份上限与枚举。
 */
function parseRule<O extends string>(
  raw: unknown,
  fallback: HomeModuleRule<O>,
  maxLimit: number,
  orders: readonly O[],
): HomeModuleRule<O> {
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const enabledRaw = obj['enabled'];
  const enabled = typeof enabledRaw === 'boolean' ? enabledRaw : fallback.enabled;
  const limitRaw = toInt(obj['limit']);
  const limit = limitRaw !== null && limitRaw >= 1 && limitRaw <= maxLimit ? limitRaw : fallback.limit;
  const orderRaw = obj['order'];
  const order =
    typeof orderRaw === 'string' && (orders as readonly string[]).includes(orderRaw)
      ? (orderRaw as O)
      : fallback.order;
  return { enabled, limit, order };
}

/**
 * 读侧解析（**永不抛**）：把 `cfg_value.value` 解析成完整配置
 *
 * 三块各自独立回退 —— 运营只配了 `hotGames` 也不会把 `products` / `players` 打回空。
 */
export function parseHomeModules(raw: unknown): HomeModulesConfig {
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  return {
    hotGames: parseRule(obj['hotGames'], DEFAULTS.hotGames, HOME_HOT_GAMES_LIMIT_MAX, HOME_HOT_GAMES_ORDERS),
    products: parseRule(obj['products'], DEFAULTS.products, HOME_MODULE_LIMIT_MAX, HOME_PRODUCTS_ORDERS),
    players: parseRule(obj['players'], DEFAULTS.players, HOME_MODULE_LIMIT_MAX, HOME_PLAYERS_ORDERS),
  };
}

/** 单块严格校验（写侧）：返回规整后的对象；非法 → 中文 400 */
function assertRule<O extends string>(
  raw: unknown,
  label: string,
  maxLimit: number,
  orders: readonly O[],
  fallback: HomeModuleRule<O>,
): HomeModuleRule<O> {
  // 整块缺失 = 保持默认（管理端只改一块时不必把三块都传上来）
  if (raw === undefined) return { ...fallback };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new BadRequestException(`${label} 配置格式非法：应为 { enabled, limit, order }，当前值 ${describeRaw(raw)}`);
  }
  const obj = raw as Record<string, unknown>;

  const enabledRaw = obj['enabled'];
  if (enabledRaw !== undefined && typeof enabledRaw !== 'boolean') {
    throw new BadRequestException(`${label} 的 enabled 必须是布尔值（true / false），当前值 ${describeRaw(enabledRaw)}`);
  }

  const limitRaw = obj['limit'];
  let limit = fallback.limit;
  if (limitRaw !== undefined) {
    const n = toInt(limitRaw);
    if (n === null) {
      throw new BadRequestException(`${label} 的 limit 必须是整数，当前值 ${describeRaw(limitRaw)}`);
    }
    if (n < 1 || n > maxLimit) {
      throw new BadRequestException(`${label} 的 limit 必须是 1–${maxLimit} 的整数，当前值 ${n}`);
    }
    limit = n;
  }

  const orderRaw = obj['order'];
  let order = fallback.order;
  if (orderRaw !== undefined) {
    if (typeof orderRaw !== 'string' || !(orders as readonly string[]).includes(orderRaw)) {
      throw new BadRequestException(
        `${label} 的 order 只能是 ${orders.join(' / ')}，当前值 ${describeRaw(orderRaw)}`,
      );
    }
    order = orderRaw as O;
  }

  return { enabled: enabledRaw === undefined ? fallback.enabled : (enabledRaw as boolean), limit, order };
}

/**
 * 写侧校验（`SystemSettingService.update()` 的 `validate` 调它）—— **唯一写入口**，通用
 * `PUT /admin/settings/:key` 与专用 `PUT /admin/settings/home_modules` 共用这一份规则，
 * 不存在"两个入口两套校验"。
 *
 * 规整后写回：字符串数字变整数（`"8"` → `8`），缺省块补默认值 → 库里永远是完整形状，
 * 运营读库所见即所得。
 */
export function assertHomeModules(raw: unknown): HomeModulesConfig {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new BadRequestException(
      '首页模块配置格式非法：应为 { hotGames, products, players } 三个对象，当前值 ' + describeRaw(raw),
    );
  }
  const obj = raw as Record<string, unknown>;
  return {
    hotGames: assertRule(obj['hotGames'], '热门游戏', HOME_HOT_GAMES_LIMIT_MAX, HOME_HOT_GAMES_ORDERS, DEFAULTS.hotGames),
    products: assertRule(obj['products'], '精选服务', HOME_MODULE_LIMIT_MAX, HOME_PRODUCTS_ORDERS, DEFAULTS.products),
    players: assertRule(obj['players'], '人气打手', HOME_MODULE_LIMIT_MAX, HOME_PLAYERS_ORDERS, DEFAULTS.players),
  };
}
