import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import {
  WORKER_BINDING_MAX_PER_BOSS_KEY,
  assertWorkerBindingMax,
} from '../auth/worker-binding-limit';
import { WORKER_APP_SUNSET_KEY, assertWorkerAppSunsetAt } from '../auth/worker-app-sunset';
import {
  assertCommissionRate,
  parseCommissionRate,
  PLATFORM_COMMISSION_RATE_DEFAULT,
  PLATFORM_COMMISSION_RATE_KEY,
} from './commission-rate';
import { HOME_MODULES_KEY, assertHomeModules, parseHomeModules, type HomeModulesConfig } from '../home/home-modules';
import { RECHARGE_CONFIG_KEY, assertRechargeConfig } from '../recharge/recharge-config';
import { WITHDRAW_CONFIG_KEY, assertWithdrawConfig } from '../withdraw/withdraw-config';
import { OperationLogService } from '../log/operation-log.service';
import { ORDER_NOTICE_DEFAULT_KEY } from './order-notice';
import { PURCHASE_POINTS_HINT_KEY } from './purchase-hint';
import { SystemSetting } from './system-setting.entity';

/**
 * `system_setting` 配置键 → 该配置驱动的**公开接口**路径前缀（**唯一登记处**）
 *
 * ## 为什么必须在这里登记（2026-10-08 缺口修复）
 *
 * `PUT /admin/settings/:key` 是管理端**通用**配置入口，任何 `system_setting` 行都能从它写入；
 * 而各专用入口（`PUT /admin/order-form`、`PUT /admin/purchase-hint`、`PUT /admin/recharge/config`…）
 * 各自在控制器里手写失效调用 —— **通用入口一写就绕过全部失效钩子**，
 * 「管理端改完、App 还看到旧数据」会从这条缝里原样复发。
 *
 * 失效收口在 [SystemSettingService.update]（**全项目唯一配置写入口**）之后，语义与
 * 「白名单默认拒绝」「管理员动作留痕收口在一处」同一种防御姿势：
 * **新增公开配置项默认就有失效**，不依赖调用方自觉。
 *
 * ⚠️ **新增任何"被公开缓存接口读取"的配置键，必须在此表登记**
 * （键 = `system_setting.setting_key`，值 = `PublicCacheInterceptor` 里逐字登记的公开前缀）。
 *
 * 各专用控制器里既有的失效调用**保留不动**（幂等：同前缀再清一次只返回 0），
 * 这里补的是"通用入口 + 新增写路径"这条缝。
 */
const PUBLIC_CACHE_PREFIX_BY_SETTING_KEY: Record<string, string> = {
  // 下单表单配置 → `GET /public/order-form`（`OrderFormPublicController.config`）
  order_form_config: '/api/v1/public/order-form',
  // 等级规则 → `GET /public/levels`（`LevelService.getRules` 读 `cfg_value.rules`）
  level_rules: '/api/v1/public/levels',
  // 购买提示文案 → `GET /public/purchase-hint`（专用入口已失效，此处兜通用入口）
  [PURCHASE_POINTS_HINT_KEY]: '/api/v1/public/purchase-hint',
  // 平台默认下单须知 → `GET /public/products/:id`（专用入口已失效，此处兜通用入口）
  [ORDER_NOTICE_DEFAULT_KEY]: '/api/v1/public/products',
  // 充值配置（档位/换算/文案）→ `GET /public/recharge/config`（专用入口已失效，此处兜通用入口）
  [RECHARGE_CONFIG_KEY]: '/api/v1/public/recharge/config',
};

/**
 * 调用者上下文（**可选**）：拿得到就记「谁在哪个请求里改的」，拿不到就只记「改了什么」。
 *
 * 为什么要可选而不是必填：`update()` 有 6+ 个调用点，其中 `TipService` 三处是
 * 服务层内部路径、没有请求上下文；强制必填会逼着调用方编一个假身份（更糟）。
 */
export interface SettingActor {
  userId: string | null;
  ip?: string | null;
  requestId?: string | null;
  method?: string;
  path?: string;
}

/**
 * 配置值摘要（**不记超长原文**，docs/09：请求体摘要脱敏落库）。
 *
 * 规则：字符串 > 160 字截断并标注原长；数组只记长度与前若干项；对象逐字段递归但限深。
 * 目的：`order_notice_default` 这类长文本配置改一次不该往审计表里灌几 KB 原文，
 * 但又要能看出「改前是什么、改后是什么」（否则审计只剩一条"改了"没有意义）。
 */
function summarizeForAudit(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === 'string') {
    return value.length > 160 ? `${value.slice(0, 160)}…(共${value.length}字)` : value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) {
    const head = value.slice(0, 10).map((v) => summarizeForAudit(v, depth + 1));
    return value.length > 10 ? { __array: true, length: value.length, head } : head;
  }
  if (typeof value === 'object') {
    if (depth >= 3) return '[深层对象已省略]';
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = summarizeForAudit(v, depth + 1);
    }
    return out;
  }
  return String(value);
}

/** 系统设置服务：按 key 读写；数值型配置统一走 value() 取数 */
@Injectable()
export class SystemSettingService {
  private readonly logger = new Logger('SystemSetting');

  constructor(
    @InjectRepository(SystemSetting) private readonly repo: Repository<SystemSetting>,
    private readonly opLog: OperationLogService,
  ) {}

  async all(): Promise<SystemSetting[]> {
    return this.repo.find({ order: { id: 'ASC' } });
  }

  async get(key: string): Promise<SystemSetting | null> {
    return this.repo.findOne({ where: { settingKey: key } });
  }

  /** 数值配置快捷读取（cfg_value.value），缺省走默认值 */
  async value(key: string, fallback: number): Promise<number> {
    const row = await this.get(key);
    const v = row?.cfgValue?.['value'];
    return typeof v === 'number' ? v : fallback;
  }

  /**
   * **长文本**配置快捷读取（`cfg_value.value.text`），缺省走默认值 —— 下单须知专用。
   *
   * 为什么不复用 [value]：那是数值读取（`typeof v === 'number'`），文本进去必然回退默认。
   * 为什么不新开一套 `{ "text": ... }` 顶层约定：`cfg_value` 的既有约定就是
   * `{"value": <配置本体>}`（见 `order_pending_take_timeout_hours` 的 `{"value":24}`），
   * 文本只是把配置本体从数字换成对象 `{"text": "..."}`，管理端读写走同一套 `cfg_value`。
   *
   * 返回的字符串**已 trim**：管理端多敲的空行不会在详情页变成一块空白（空串 → 回退默认）。
   */
  async text(key: string, fallback: string): Promise<string> {
    const row = await this.get(key);
    const v = row?.cfgValue?.['value'];
    const text = v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>)['text'] : undefined;
    if (typeof text !== 'string') return fallback;
    const trimmed = text.trim();
    return trimmed.length ? trimmed : fallback;
  }

  /**
   * 平台抽成比例（百分数整数，如 25）—— **结算与 AI 提示词共用的唯一读取入口**。
   *
   * 缓存取舍：**不缓存，每次结算/每次生成提示词读一次库**。
   * - `setting_key` 有唯一索引，读一行是主键级开销；结算本身还带订单行锁 + 多条流水写入，
   *   这一次 SELECT 占比可忽略（订单结算不是高频热路径）。
   * - 换来的是「管理端改完立即对所有新结算生效」，不存在缓存过期窗口，也不会出现
   *   「库里改了、结算还用旧值」这类最难查的对账问题（历史 70/30 就是硬编码散落导致的）。
   * - 若将来结算量级上来需要缓存，正确做法是在 [update] 里显式失效（写路径唯一，可精确失效），
   *   而不是拍一个 TTL。
   */
  async platformCommissionRate(): Promise<number> {
    const row = await this.get(PLATFORM_COMMISSION_RATE_KEY);
    const parsed = parseCommissionRate(row?.cfgValue?.['value']);
    if (parsed === null) {
      if (row) {
        this.logger.warn(
          `配置 ${PLATFORM_COMMISSION_RATE_KEY} 非法（${JSON.stringify(row.cfgValue)}），本次结算回落默认 ${PLATFORM_COMMISSION_RATE_DEFAULT}%`,
        );
      }
      return PLATFORM_COMMISSION_RATE_DEFAULT;
    }
    return parsed;
  }

  /**
   * 首页三模块配置（负责人 2026-10-18）—— **读侧唯一入口**。
   *
   * 缓存取舍与 [platformCommissionRate] **同一条理由**：**不缓存，每次实时读库**。
   * - `setting_key` 有唯一索引 → 读一行是主键级开销（实测约 2ms）；
   * - 换来「管理端保存完，下一次首页请求即生效」——不存在"改了要等 TTL"的窗口。
   *   这条尤其重要：首页是最显眼的位置，运营调了开关却还看到旧版面会立刻来问。
   * - 承载它的 `GET /public/home` 在 `PublicCacheInterceptor` 里是 `no-store`
   *   （见该文件 `/api/v1/public/home` 那段），因此**没有需要失效的缓存**。
   *
   * 返回值**永不抛**：配置行缺失 / 被手工改坏 → 逐字段回退默认值（`parseHomeModules`），
   * 首页照常出内容（红线：不许因为拿不到配置就白屏）。
   */
  async homeModules(): Promise<HomeModulesConfig> {
    const row = await this.get(HOME_MODULES_KEY);
    return parseHomeModules(row?.cfgValue?.['value']);
  }

  /**
   * 写入配置（**全项目唯一的配置写入口**）。
   *
   * ## 审计留痕（2026-10-06 补，负责人铁律「管理员动作必须留痕」）
   *
   * 原先**所有** `system_setting` 的写入都不写 `operation_log` —— 包括
   * `PUT /admin/recharge/config` 改老板端可见的充值文案、`PUT /admin/settings/:key`
   * 改最高安全配置。事后只能从 `system_setting.updated_at` 看出"某个时刻被改过"，
   * **看不出谁改的、改前是什么**，是真实审计缺口（本次修充值文案时踩到）。
   *
   * 现在收口在**这一个函数**里：`module='setting'`、`action='setting:update:<key>'`、
   * `request_body` 记 `{key, before, after}` 的**摘要**（长文本截断，见 [summarizeForAudit]），
   * 不改任何权限与业务行为。放这里而不是各控制器：写入口只有这一个，
   * 将来新增配置项**默认就有留痕**，不依赖调用方自觉（与「白名单默认拒绝」同一种防御姿势）。
   *
   * 留痕失败不阻断写入：`OperationLogService.log()` 内部异步且自行 catch（既有语义）。
   */
  async update(
    key: string,
    cfgValue: Record<string, unknown>,
    description: string | undefined,
    actorRoleCode: string | null,
    actor?: SettingActor,
  ): Promise<SystemSetting> {
    const row = await this.get(key);
    if (!row) throw new NotFoundException('配置项不存在');
    // 最高安全配置仅超级管理员可改（docs/04：普通管理员默认不能改最高安全配置）
    if (row.isHighSecurity === 1 && actorRoleCode !== 'super_admin') {
      throw new ForbiddenException('最高安全配置仅超级管理员可修改');
    }
    // 已知配置项在**唯一写入口**做取值校验（非法 = 400 + 中文错误，读侧另有回退兜底）
    const next = this.validate(key, cfgValue);
    const before = row.cfgValue;
    row.cfgValue = next;
    if (description !== undefined) row.description = description;
    const saved = await this.repo.save(row);
    this.opLog.log({
      adminUserId: actor?.userId ?? null,
      adminName: '',
      module: 'setting',
      action: `setting:update:${key}`.slice(0, 64),
      method: actor?.method ?? 'SYSTEM',
      path: actor?.path ?? `system_setting:${key}`,
      requestBody: JSON.stringify({
        key,
        description: description ?? row.description ?? null,
        before: summarizeForAudit(before),
        after: summarizeForAudit(next),
      }),
      ip: actor?.ip ?? null,
      requestId: actor?.requestId ?? null,
      result: 'success',
    });
    /**
     * **公开接口微缓存失效**（2026-10-08 缺口修复）—— 见 `PUBLIC_CACHE_PREFIX_BY_SETTING_KEY`。
     *
     * 放在写库成功之后：没写进去就不该清缓存（清了只会让下一次请求白查一次库）。
     * 未登记的键（绝大多数配置）查表为空 → 一次 `invalidate` 都不发，零副作用；
     * 失效是 `Map` 前缀删除（微秒级），不影响写入路径的响应时间。
     * 失败不阻断：`invalidate` 是纯内存操作，不会抛。
     */
    const publicPrefix = PUBLIC_CACHE_PREFIX_BY_SETTING_KEY[key];
    if (publicPrefix) PublicCacheInterceptor.invalidate(publicPrefix);
    return saved;
  }

  /** 按 key 的取值校验：通过则返回规整后的 cfg_value（未知 key 原样放行，保持既有行为） */
  private validate(key: string, cfgValue: Record<string, unknown>): Record<string, unknown> {
    if (key === WORKER_BINDING_MAX_PER_BOSS_KEY) {
      if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
        throw new BadRequestException('配置格式非法：应为 { "value": 绑定上限个数 }');
      }
      // 规整为整数并存回（"1" → 1），避免库里留下字符串导致类型漂移
      return { ...cfgValue, value: assertWorkerBindingMax(cfgValue['value']) };
    }
    /**
     * 充值配置（负责人 2026-10-06）：形状 `{"value": {amountOptions, customEnabled, ...}}`。
     *
     * 这一条是**通用** `PUT /admin/settings/:key` 也走得通的保障 —— 与
     * `PUT /admin/recharge/config`（专用入口）共用同一套校验，两个入口不会有两套规则。
     * 规整后写回：字符串数字变整数、档位升序去重。
     */
    if (key === RECHARGE_CONFIG_KEY) {
      if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
        throw new BadRequestException('配置格式非法：应为 { "value": 充值配置对象 }');
      }
      return { ...cfgValue, value: assertRechargeConfig(cfgValue['value']) };
    }
    /**
     * 提现配置（负责人 2026-10-11）：形状 `{"value": {minAmount, maxAmount, dailyLimit, feeRate, noticeText}}`。
     *
     * 与 `RECHARGE_CONFIG_KEY` 同一条理由：**唯一写入口**（`SystemSettingService.update`）
     * 必须认识这个 key，否则通用入口 `PUT /admin/settings/withdraw_config` 会绕开校验写入
     * 非法值（例如 minAmount > maxAmount、文案里出现"积分"）。
     * 专用入口 `PUT /admin/withdraw/config` 与它共用同一个 `assertWithdrawConfig`。
     */
    if (key === WITHDRAW_CONFIG_KEY) {
      if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
        throw new BadRequestException('配置格式非法：应为 { "value": 提现配置对象 }');
      }
      return { ...cfgValue, value: assertWithdrawConfig(cfgValue['value']) };
    }
    /**
     * 首页三模块（负责人 2026-10-18「热门游戏 精选服务 人气打手 可以在管理端更改」）：
     * 形状 `{"value": {hotGames, products, players}}`，每块 `{enabled, limit, order}`。
     *
     * 与 `RECHARGE_CONFIG_KEY` / `WITHDRAW_CONFIG_KEY` 同一条理由：**唯一写入口**
     * （`SystemSettingService.update`）必须认识这个 key，否则通用入口
     * `PUT /admin/settings/home_modules` 会绕开校验写入非法值（例如 limit=999、
     * order 写成不存在的枚举 —— 客户端会静默回退默认值，运营却以为改生效了）。
     * 专用入口（`PUT /admin/settings/home_modules`）与它共用同一个 `assertHomeModules`。
     *
     * 本行 `is_high_security = 0` → 不走上面的超管闸门（它只决定首页版面，不动钱/权限）。
     */
    if (key === HOME_MODULES_KEY) {
      if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
        throw new BadRequestException('配置格式非法：应为 { "value": 首页模块配置对象 }');
      }
      return { ...cfgValue, value: assertHomeModules(cfgValue['value']) };
    }
    /**
     * 工作端到期时间（负责人 2026-10-06 定案「彻底废除工作端」，服务端收口）：
     * 形状 `{"value": "2026-10-13 00:00:00"}`（Asia/Shanghai 墙钟；也接受带时区的 ISO 8601）。
     *
     * 校验/规整**复用判定模块的同一个 parser**（`worker-app-sunset.ts` 的 `assertWorkerAppSunsetAt`）
     * —— 写侧接受的格式与读侧解释的格式永远同源，不会再出现"管理端存得进、守卫读不懂"
     * （读侧对非法值回退默认时间，属于兜底而非常态）。
     * 规整后落库：`"2026-10-12T16:00:00Z"` → `"2026-10-13 00:00:00"`（运营读库所见即所得）。
     */
    if (key === WORKER_APP_SUNSET_KEY) {
      if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
        throw new BadRequestException('配置格式非法：应为 { "value": "YYYY-MM-DD HH:mm:ss" }');
      }
      return { ...cfgValue, value: assertWorkerAppSunsetAt(cfgValue['value']) };
    }
    if (key !== PLATFORM_COMMISSION_RATE_KEY) return cfgValue;
    if (cfgValue === null || typeof cfgValue !== 'object' || Array.isArray(cfgValue)) {
      throw new BadRequestException('配置格式非法：应为 { "value": 抽成比例 }');
    }
    const rate = assertCommissionRate(cfgValue['value']);
    // 规整为整数并存回（"25" → 25），避免库里留下字符串导致类型漂移
    return { ...cfgValue, value: rate };
  }
}
