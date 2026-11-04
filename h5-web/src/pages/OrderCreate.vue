<script setup lang="ts">
/**
 * 确认订单
 * ---------------------------------------------------------------------------
 * ## 「填写信息区」100% 由接口下发（**前端零硬编码字段名**）
 * `GET /public/order-form` → `publicApi.orderForm()` 下发：
 *   · `zoneLabel` / `zoneOptions`   区服选择的标题与选项（线上是 `[{label,value}]`）
 *   · `fields[]`                    填写信息区：**顺序 = 数组顺序**，`enabled` 过滤，
 *                                   `required` 决定红星与校验，`label/placeholder/type/maxLength` 全部照用
 *   · `workerLabel...` / `feeTitle` / `totalLabel` / `submitText` / `notice` 文案
 * 渲染一律 `v-for` 遍历 `fields`；提交时也**同一份数组**回填 payload —— 不出现任何字段名字面量。
 *
 * ## ⚠️ 提交形状：真实 DTO 是**扁平的**，不是嵌套 fields（curl + 读码双确认）
 * `server/src/modules/order/dto/order.dto.ts` 的 `CreateOrderDto`：
 *   `productId / quantity / gameZone / gamePlayerId / idempotencyKey / remark / contactPhone`
 *   —— 全部在**顶层**；**没有** `fields` 子对象，**也没有** `divisionId`。
 * 且全局校验是 `whitelist + forbidNonWhitelisted`（`lenient-validation.pipe.ts`），
 * 而 `CreateOrderDto` **不是** `LenientUpdateDto` 的子类 → 多传一个键就是
 * `400 property xxx should not exist`。所以**不能**发 `{ fields: {...} }`，也不能发 `divisionId`
 * （分部由服务端按商品归属决定：`order.service.ts` 里 `divisionId: product.divisionId`）。
 *
 * 拼装方式：字段的 `key` **本身就是 DTO 的顶层属性名**，于是
 *   `payload[field.key] = 用户输入`
 * 既是"接口下发驱动"，又天然产出扁平的合法请求体：管理端加/改/停字段，
 * 前端一行不用改（前提是 key 取真实 DTO 属性名）。
 *
 * ## 余额
 * `/auth/me` 的 `user` 角色返回体里**没有** `balance`（`auth.service.ts` 的 `me()` 只给 base），
 * 所以 `useAuthStore().balance` 恒为 null。这里直连权威接口 `GET /user/wallet` → `{ balance }`
 * （该接口未封装进 `api/index.ts`，按任务约定在本页直调并在报告中列出）。
 *
 * ## 记住游戏 ID（负责人 2026-10-15「记住我的游戏 ID 这个也做」）
 * `GET /user/game-accounts` → `[{ gameId, gameName, gamePlayerId, gameZone, updatedAt }]`：
 *   · **保存由服务端在订单创建成功时自动完成**，本页**只读**（不调 POST）
 *   · 匹配口径：当前商品的 `gameId` **严格等于**（字符串比较）账号行的 `gameId`
 *   · 命中 → 回填 `gamePlayerId`（键与 `GET /public/order-form` 下发的 `fields[].key` 比对）；
 *     `gameZone` **仅当值命中 `zoneOptions[].value`** 时才回填区服
 *   · 接口/字段/匹配任何一环不成立 → **留空静默降级**：不报错、不弹窗、不挡下单、不拖慢首屏
 *   · 该接口同样未封进 `api/index.ts` → 本页直调（报告中列出）
 */
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { showToast } from 'vant';
import { publicApi, orderApi, ApiError, type CreateOrderPayload } from '@/api';
import { http } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { fmtMoney } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

/* ---------------- 接口下发配置的类型 ---------------- */

interface ZoneOption {
  label: string;
  value: string;
}

interface FormField {
  key: string;
  label: string;
  placeholder?: string;
  type?: string;
  required?: boolean;
  enabled?: boolean;
  maxLength?: number;
  [k: string]: unknown;
}

interface ProductLite {
  id: string;
  name: string;
  price: string | number;
  priceUnit?: string | null;
  divisionId?: string | null;
  divisionPlatformLabel?: string | null;
  coverUrl?: string | null;
  effectiveOrderNotice?: string | null;
  estimateDurationMin?: number | null;
  [k: string]: unknown;
}

/* ---------------- 状态 ---------------- */

/**
 * 契约字段名：`GET /public/order-form` 下发的 `fields[].key` 里承载"游戏 ID"的那一个。
 * 这里出现的唯一字面量是**契约字段名**（与接口下发比对用），不是写死表单结构 ——
 * 管理端改字段顺序/必填/启停，本页照旧。
 */
const GAME_ID_KEY = 'gamePlayerId';

interface GameAccount {
  gameId?: unknown;
  gameName?: unknown;
  gamePlayerId?: unknown;
  gameZone?: unknown;
  updatedAt?: unknown;
}

const route = useRoute();
const router = useRouter();
const auth = useAuthStore();

const productId = String(route.query.productId ?? '');
/**
 * 详情页会透传一个 `divisionId`，本页**刻意不读、也不发**：
 * 分部由服务端按商品归属自行决定（`order.service.ts` 里 `divisionId: product.divisionId`），
 * 且 `divisionId` 不在 `CreateOrderDto` 白名单里 —— 发过去只会换来 400。
 */

const cfg = ref<Record<string, unknown> | null>(null);
const product = ref<ProductLite | null>(null);
const loading = ref(true);
const loadError = ref('');
const submitting = ref(false);

const zone = ref('');
const qty = ref(Math.min(99, Math.max(1, Number(route.query.quantity) || 1)));
const form = ref<Record<string, string>>({});

/** 提交前先做一次本地校验 */
const missingField = ref('');

/** 权威余额（GET /user/wallet）；null = 没取到，此时不拦提交，交给服务端判定 */
const balance = ref<number | null>(null);

/** 被历史记录回填的字段 key（空 = 没回填）；仅用于给一句"可修改"的提示 */
const autoFilledKey = ref('');
/** 区服是否由历史记录预选（空 = 否） */
const zoneAutoFilled = ref(false);

/* ---------------- 接口下发 → 渲染模型 ---------------- */

/**
 * 区服选项。线上返回 `[{label,value}]`，但 `api/index.ts` 的类型写的是 `string[]`
 * （管理端 `PUT /admin/order-form` 收的是任意 JSON，两种形状都可能被存进去）
 * → 这里两种都兜住，避免哪天后台换个存法就白屏。
 */
const zones = computed<ZoneOption[]>(() => {
  const raw = (cfg.value?.zoneOptions ?? []) as unknown[];
  if (!Array.isArray(raw)) return [];
  return raw
    .map((o): ZoneOption => {
      if (typeof o === 'string') return { label: o, value: o };
      const obj = o as { label?: unknown; value?: unknown };
      return { label: String(obj?.label ?? ''), value: String(obj?.value ?? '') };
    })
    .filter((o) => o.label !== '' && o.value !== '');
});

const zoneLabel = computed(() => String(cfg.value?.zoneLabel ?? '') || '选择区服');

/**
 * 填写信息区字段：**顺序 = 接口数组顺序**，`enabled === false` 的剔除。
 * 说明：`enabled` 缺省时按"显示"处理 —— 服务端默认配置三项都显式带 `enabled: true`，
 * 若某天存进来的字段漏了这个键，隐藏掉比"字段凭空消失"更糟的体验要好。
 */
const fields = computed<FormField[]>(() => {
  const raw = (cfg.value?.fields ?? []) as unknown[];
  if (!Array.isArray(raw)) return [];
  return (raw as FormField[]).filter((f) => f && typeof f.key === 'string' && f.key && f.enabled !== false);
});

const notice = computed(() => String(cfg.value?.notice ?? '').trim());
const orderNotice = computed(() => String(product.value?.effectiveOrderNotice ?? '').trim());
const submitText = computed(() => String(cfg.value?.submitText ?? '').trim() || '提交订单');
const feeTitle = computed(() => String(cfg.value?.feeTitle ?? '').trim() || '商品费用');
const totalLabel = computed(() => String(cfg.value?.totalLabel ?? '').trim() || '合计');

const unit = computed(() => String(product.value?.priceUnit || '单'));
const unitPrice = computed(() => Number(product.value?.price ?? 0));
const total = computed(() => unitPrice.value * qty.value);

/** 余额不足（仅在余额已知时成立；服务端才是权威，这里只做提前拦截） */
const notEnough = computed(() => balance.value !== null && total.value > balance.value + 1e-9);

/** 区服选项为空 → 无法提供必填的 gameZone，按需求给出客服提示并拦住提交 */
const noZone = computed(() => zones.value.length === 0);

const canSubmit = computed(
  () => !submitting.value && !!product.value && !loadError.value && !noZone.value && !notEnough.value,
);

/* ---------------- 取数 ---------------- */

async function fetchAll() {
  loading.value = true;
  loadError.value = '';
  try {
    if (!productId) throw new ApiError(400, '缺少商品参数，请从商品页进入');

    // 三个接口互不依赖 → 并行，首屏更快
    const [formCfg, prod, wallet] = await Promise.all([
      publicApi.orderForm(),
      publicApi.product(productId),
      http.get<{ balance?: string | number }>('/user/wallet').catch(() => null),
    ]);

    cfg.value = formCfg as unknown as Record<string, unknown>;
    product.value = prod as ProductLite;
    if (wallet && wallet.balance !== undefined && wallet.balance !== null) {
      balance.value = Number(wallet.balance);
    }

    // 初始化动态字段表（key 全部来自接口，不写死）
    const next: Record<string, string> = {};
    for (const f of fields.value) next[f.key] = form.value[f.key] ?? '';
    form.value = next;
  } catch (e) {
    loadError.value = e instanceof ApiError ? e.message : '加载失败，请重试';
  } finally {
    loading.value = false;
  }

  // 记住游戏 ID：**独立附加请求，放在 loading 关闭之后** —— 拖慢首屏不值得，失败也不影响下单
  await prefillByHistory();
}

/**
 * 读历史游戏 ID 并回填（`GET /user/game-accounts`，只读；保存由服务端在下单成功时自己做）
 * 兼容两种下发形状：裸数组（契约）与 `{ list: [] }`。
 */
function pickAccounts(raw: unknown): GameAccount[] {
  const d = (raw ?? null) as unknown;
  const arr = Array.isArray(d) ? d : Array.isArray((d as { list?: unknown })?.list) ? ((d as { list: unknown[] }).list) : [];
  return arr as GameAccount[];
}

async function prefillByHistory() {
  const gid = product.value?.gameId;
  if (gid === undefined || gid === null || String(gid) === '') return; // 商品没挂游戏 → 无从匹配

  let rows: GameAccount[];
  try {
    rows = pickAccounts(await http.get<unknown>('/user/game-accounts'));
  } catch {
    return; // 接口未就绪 / 未登录 / 网络失败：静默留空，绝不报错、绝不挡下单
  }

  const hit = rows.find(
    (r) =>
      String(r?.gameId ?? '') === String(gid) && String(r?.gamePlayerId ?? '').trim() !== '',
  );
  if (!hit) return;

  // ① 游戏 ID：字段必须是接口下发的（找不到就说明后台没启用该字段 → 不回填），且当前为空才填
  const fld = fields.value.find((f) => f.key === GAME_ID_KEY);
  if (fld && !String(form.value[fld.key] ?? '').trim()) {
    form.value[fld.key] = String(hit.gamePlayerId ?? '').trim();
    autoFilledKey.value = fld.key;
  }

  // ② 区服：只有值真的命中当前区服选项时才预选（否则留空让用户自己选）
  const z = String(hit.gameZone ?? '').trim();
  if (z && !zone.value && zones.value.some((o) => o.value === z)) {
    zone.value = z;
    zoneAutoFilled.value = true;
  }
}

/** 兜底：`auth.me.balance`（当前服务端 user 角色不给该字段，取到才有值） */
function showBalance(): string {
  if (balance.value !== null) return fmtMoney(balance.value);
  if (auth.balance !== null) return fmtMoney(auth.balance);
  return '—';
}

/* ---------------- 交互 ---------------- */

function pickZone(v: string) {
  zone.value = v;
  missingField.value = '';
}

function step(delta: number) {
  const next = qty.value + delta;
  if (next < 1 || next > 99) return; // DTO 上限 99
  qty.value = next;
}

/** 该字段用什么 input type（真实写法在服务端下发里，这里是通用映射） */
function inputType(t?: string): string {
  if (t === 'phone') return 'tel';
  if (t === 'number') return 'number';
  if (t === 'email') return 'email';
  return 'text';
}

/** UUID（DTO 要求 8~64 位）。非安全上下文（http://IP）没有 randomUUID，必须判能力 —— 同 api/client.ts */
function newIdemKey(): string {
  const c = globalThis.crypto as Crypto | undefined;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    const v = ch === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

/**
 * 幂等键：**每次进入本页生成一次**，重试复用同一个 key。
 * 这样"请求已到服务端但响应丢了"的情况下重试不会重复扣款
 * （服务端 `order.service.ts` 撞唯一键会回查并返回同一张订单）。
 */
const idemKey = newIdemKey();

/** 校验：全部依赖接口下发的 required / label，不写死任何字段名 */
function validate(): string {
  if (!product.value) return '商品信息未加载完成';
  if (noZone.value) return '该商品暂未开放区服选择，请联系客服';
  if (!zone.value) return `请${zoneLabel.value}`;
  for (const f of fields.value) {
    if (f.required === true && !String(form.value[f.key] ?? '').trim()) {
      return `请填写${f.label}`;
    }
  }
  if (qty.value < 1 || qty.value > 99) return '数量需在 1 - 99 之间';
  if (notEnough.value) return '余额不足，请先充值';
  return '';
}

async function submit() {
  if (submitting.value) return;
  const err = validate();
  if (err) {
    missingField.value = err;
    showToast(err);
    return;
  }
  missingField.value = '';

  // 扁平请求体：结构字段用字面量（DTO 协议名），填写信息区**全部**来自接口下发的 key
  const payload: CreateOrderPayload = {
    productId,
    quantity: qty.value,
    gameZone: zone.value,
    idempotencyKey: idemKey,
  };
  for (const f of fields.value) {
    const v = String(form.value[f.key] ?? '').trim();
    if (v) payload[f.key] = v; // key === DTO 顶层属性名
  }

  submitting.value = true;
  try {
    const res = await orderApi.create(payload);
    showToast(res?.orderNo ? `下单成功 ${res.orderNo}` : '下单成功');
    router.replace({ name: 'orders' });
  } catch (e) {
    showToast(e instanceof ApiError ? e.message : '下单失败，请重试');
  } finally {
    submitting.value = false;
  }
}

function goRecharge() {
  router.push({ name: 'recharge' });
}

onMounted(fetchAll);
</script>

<template>
  <div class="h5-page h5-page--nobar order">
    <PageHead title="确认订单" />

    <div v-if="loading" class="skeletons">
      <div class="h5-skel skel" />
      <div class="h5-skel skel" />
      <div class="h5-skel skel" />
    </div>

    <div v-else-if="loadError" class="state">
      <p class="state__t">{{ loadError }}</p>
      <button class="h5-btn h5-btn--ghost state__btn" type="button" @click="fetchAll">重新加载</button>
    </div>

    <template v-else>
      <!-- 服务端下发的页头提示（可为空 → 整条不渲染） -->
      <p v-if="notice" class="notice">{{ notice }}</p>

      <!-- ① 商品摘要 -->
      <section class="h5-card sum">
        <div v-if="product?.coverUrl" class="sum__thumb">
          <img :src="String(product?.coverUrl)" :alt="product?.name" />
        </div>
        <div class="sum__body">
          <h1 class="sum__name">{{ product?.name }}</h1>
          <p class="sum__meta">
            <span v-if="product?.divisionPlatformLabel">{{ product?.divisionPlatformLabel }}</span>
            <span v-if="product?.estimateDurationMin">预计 {{ product?.estimateDurationMin }} 分钟</span>
          </p>
          <p class="sum__price">
            <span class="h5-price"><span class="h5-price__sym">¥</span>{{ fmtMoney(unitPrice) }}</span>
            <span class="sum__unit">/{{ unit }}</span>
          </p>
        </div>
      </section>

      <!-- ② 区服选择：label 与选项全部来自接口 -->
      <section class="h5-card">
        <h2 class="card__t">
          {{ zoneLabel }}
          <em class="req">*</em>
        </h2>
        <div v-if="zones.length" class="chips">
          <button
            v-for="z in zones"
            :key="z.value"
            type="button"
            class="chip"
            :class="{ 'chip--on': zone === z.value }"
            @click="pickZone(z.value)"
          >
            {{ z.label }}
          </button>
        </div>
        <p v-else class="hint">该商品暂未开放区服选择，请联系客服</p>
        <p v-if="zoneAutoFilled" class="auto">已按历史记录预选区服，可直接改</p>
      </section>

      <!-- ③ 填写信息区：v-for 遍历接口下发 fields（顺序 / 必填 / 启停 / 占位 / 长度全部照用） -->
      <section class="h5-card">
        <h2 class="card__t">填写信息</h2>

        <template v-if="fields.length">
          <div v-for="f in fields" :key="f.key" class="field">
            <label class="field__lb" :for="`fld-${f.key}`">
              {{ f.label }}
              <em v-if="f.required === true" class="req">*</em>
            </label>

            <textarea
              v-if="f.type === 'textarea'"
              :id="`fld-${f.key}`"
              v-model="form[f.key]"
              class="field__ctl field__ctl--area"
              :placeholder="f.placeholder || ''"
              :maxlength="f.maxLength"
              rows="3"
            />
            <input
              v-else
              :id="`fld-${f.key}`"
              v-model="form[f.key]"
              class="field__ctl"
              :type="inputType(f.type)"
              :placeholder="f.placeholder || ''"
              :maxlength="f.maxLength"
            />
            <!-- 记住游戏 ID：只在真回填了该字段时出现一句提示，用户可改（不拦、不校验） -->
            <p v-if="autoFilledKey === f.key" class="auto">已按历史记录回填，可直接修改</p>
          </div>
        </template>
        <p v-else class="hint">该商品下单暂无需补充信息</p>
      </section>

      <!-- ④ 数量 / 费用 / 余额 -->
      <section class="h5-card">
        <h2 class="card__t">{{ feeTitle }}</h2>

        <div class="row">
          <span class="row__k">单价</span>
          <span class="row__v">
            <span class="h5-price"><span class="h5-price__sym">¥</span>{{ fmtMoney(unitPrice) }}</span>
            <span class="row__unit">/{{ unit }}</span>
          </span>
        </div>

        <div class="row">
          <span class="row__k">数量</span>
          <span class="row__v">
            <span class="stepper">
              <button type="button" class="stepper__b" :disabled="qty <= 1" aria-label="减少" @click="step(-1)">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">
                  <path d="M6 12h12" stroke-linecap="round" />
                </svg>
              </button>
              <b class="stepper__n">{{ qty }}</b>
              <button type="button" class="stepper__b" :disabled="qty >= 99" aria-label="增加" @click="step(1)">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">
                  <path d="M12 6v12M6 12h12" stroke-linecap="round" />
                </svg>
              </button>
            </span>
          </span>
        </div>

        <div class="row row--total">
          <span class="row__k row__k--strong">{{ totalLabel }}</span>
          <span class="row__v">
            <span class="h5-price total-price"><span class="h5-price__sym">¥</span>{{ fmtMoney(total) }}</span>
          </span>
        </div>

        <div class="row row--bal">
          <span class="row__k">余额</span>
          <span class="row__v">
            <span class="bal">{{ showBalance() }}</span>
            <button v-if="notEnough" type="button" class="bal__link" @click="goRecharge">余额不足，去充值</button>
          </span>
        </div>
      </section>

      <!-- ⑤ 下单须知（服务端权威文案；直接进本页的用户也得看得到） -->
      <section v-if="orderNotice" class="h5-card">
        <h2 class="card__t">下单须知</h2>
        <p class="text">{{ orderNotice }}</p>
      </section>
    </template>

    <!-- ⑥ 底部固定操作条 -->
    <div v-if="!loading && !loadError" class="h5-fixedbar">
      <div class="bar__fee">
        <span class="bar__k">{{ totalLabel }}</span>
        <span class="h5-price bar__v"><span class="h5-price__sym">¥</span>{{ fmtMoney(total) }}</span>
      </div>
      <button class="h5-btn bar__btn" type="button" :disabled="!canSubmit" @click="submit">
        {{ submitting ? '提交中…' : submitText }}
      </button>
    </div>
  </div>
</template>

<style scoped>
/* 底部固定条 44 + 上下各 12 → 留 68 给内容 */
.order {
  padding-bottom: calc(var(--h-btn) + var(--s6) + var(--safe-bottom));
}

.skeletons {
  padding: var(--s3) var(--page-x) 0;
}
.skel {
  height: 88px;
  margin-bottom: var(--s3);
}

.state {
  padding: var(--s12) var(--page-x);
  text-align: center;
}
.state__t {
  margin: 0 0 var(--s4);
  font-size: var(--f4);
  color: var(--g2);
}
.state__btn {
  width: auto;
  padding: 0 var(--s5);
  margin: 0 auto;
}

.notice {
  margin: var(--s3) var(--page-x);
  padding: var(--s2) var(--s3);
  background: var(--pri-soft);
  border-radius: var(--r-ctrl);
  font-size: var(--f5);
  color: var(--pri);
}

.card__t {
  display: flex;
  align-items: center;
  gap: var(--s1);
  margin: 0 0 var(--s3);
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
}
/* 必填红星：**只看 required** —— 接口说必填才亮 */
.req {
  color: var(--danger);
  font-style: normal;
  font-weight: 700;
}

.hint {
  margin: 0;
  font-size: var(--f5);
  color: var(--g3);
}
.text {
  margin: 0;
  font-size: var(--f5);
  line-height: 1.7;
  color: var(--g2);
  white-space: pre-line;
}

/* ---- 商品摘要 ---- */
.sum {
  display: flex;
  gap: var(--s3);
}
.sum__thumb {
  flex: 0 0 auto;
  width: 64px;
  height: 64px;
  border-radius: var(--r-ctrl);
  overflow: hidden;
  background: var(--g6);
}
.sum__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.sum__body {
  flex: 1 1 auto;
  min-width: 0;
}
.sum__name {
  margin: 0;
  font-size: var(--f4);
  font-weight: 700;
  line-height: 1.45;
  color: var(--g1);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.sum__meta {
  display: flex;
  gap: var(--s3);
  margin: var(--s1) 0 0;
  font-size: var(--f6);
  color: var(--g3);
}
.sum__price {
  display: flex;
  align-items: baseline;
  gap: var(--s1);
  margin: var(--s2) 0 0;
  font-size: var(--f3);
}
.sum__unit {
  font-size: var(--f6);
  color: var(--g3);
}

/* ---- 区服胶囊 ---- */
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s2);
}
.chip {
  min-width: 88px;
  height: var(--h-btn-sm);
  padding: 0 var(--s4);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  background: var(--card);
  color: var(--g1);
  font-size: var(--f4);
  cursor: pointer;
}
.chip--on {
  background: var(--pri-soft);
  border-color: var(--pri);
  color: var(--pri);
  font-weight: 700;
}

/* ---- 动态字段 ---- */
.field + .field {
  margin-top: var(--s4);
}
.field__lb {
  display: block;
  margin-bottom: var(--s2);
  font-size: var(--f4);
  color: var(--g2);
}
.field__ctl {
  display: block;
  width: 100%;
  min-height: var(--h-btn);
  padding: var(--s2) var(--s3);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  background: var(--card);
  color: var(--g1);
  font-size: var(--f4);
  font-family: inherit;
  outline: 0;
}
.field__ctl:focus {
  border-color: var(--pri);
}
.field__ctl--area {
  min-height: 80px;
  resize: vertical;
}

/* 历史回填提示（4dp 网格 · 只用 token 色） */
.auto {
  margin: var(--s2) 0 0;
  font-size: var(--f6);
  font-weight: 600;
  color: var(--pri);
}

/* ---- 费用行 ---- */
.row {
  display: flex;
  align-items: center;
  gap: var(--s3);
  min-height: 32px;
  padding: var(--s2) 0;
}
.row + .row {
  border-top: 1px solid var(--g5);
}
.row__k {
  flex: 0 0 auto;
  width: 48px;
  font-size: var(--f4);
  color: var(--g2);
}
.row__k--strong {
  color: var(--g1);
  font-weight: 700;
}
.row__v {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  align-items: baseline;
  justify-content: flex-end;
  gap: var(--s1);
}
.row--total {
  padding-top: var(--s3);
}
.row--bal {
  padding-bottom: 0;
}
.row__unit {
  font-size: var(--f6);
  color: var(--g3);
}
.total-price {
  font-size: var(--f2);
}
.bal {
  font-size: var(--f4);
  color: var(--g1);
  font-variant-numeric: tabular-nums;
}
.bal__link {
  border: 0;
  background: none;
  padding: 0;
  margin-left: var(--s2);
  font-size: var(--f5);
  font-weight: 700;
  color: var(--pri);
  cursor: pointer;
}

.stepper {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  overflow: hidden;
}
.stepper__b {
  width: var(--h-btn-sm);
  height: var(--h-btn-sm);
  display: grid;
  place-items: center;
  border: 0;
  background: var(--card);
  color: var(--g1);
  cursor: pointer;
}
.stepper__b:disabled {
  color: var(--g4);
  cursor: not-allowed;
}
.stepper__n {
  min-width: 40px;
  text-align: center;
  font-size: var(--f4);
  font-weight: 700;
  color: var(--g1);
  font-variant-numeric: tabular-nums;
}

.bar__fee {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  align-items: baseline;
  gap: var(--s1);
}
.bar__k {
  font-size: var(--f5);
  color: var(--g2);
}
.bar__v {
  font-size: var(--f1);
}
.bar__btn {
  flex: 0 0 auto;
  width: 140px;
}
</style>
