<script setup lang="ts">
/**
 * 订单详情（H5）
 * ============================================================================
 * 数据源：`GET /user/orders/:id`（字段来自 `OrderService.userOrderDetail` 实测口径）：
 *   订单本体（`orderView`）：id / orderNo / productId / quantity / unitPrice / totalAmount /
 *     status / statusName / workerId / userRemark / createdAt / divisionId / gameId
 *   `snapshot`：productName / gameName / categoryName / unitPrice / quantity / totalAmount /
 *     priceUnit / estimateDurationMin / gameZone / gamePlayerId
 *   `workerInfo`：{ workerNo, nickname }（未接单为 null）
 *   `statusLogs`：`order_status_log` 逐条 { fromStatus, toStatus, createdAt, remark, ... }（按 id ASC）
 *
 * 状态时间线：**有 statusLogs 就画真实流转**；没有（老数据/未落日志）就只画
 * 「当前状态 + 下单创建」两步 —— **绝不猜中间状态**（负责人口径）。
 *
 * 护航员只给**头像 + 名字**（不加等级/评分/标签，结构规则 6）。
 * 硬约束：白底为主 · 4dp 网格间距 · 颜色全 token · 金额 ¥+两位小数+千分位 · 零 emoji。
 *
 * 评价（2026-10-15 负责人：「做评价与评分体系」）—— 契约由后端并行实现：
 *   `POST /user/orders/:id/review` { satisfied, remark? } → { ok, needAfterSale }
 *   `GET  /user/orders/:id/review` → { satisfied, remark, createdAt } | null
 *   · 仅 `status='completed'` 可评；一单一评（重复 → 400「该订单已评价」）
 *   · 形态照竞品研究：**满意 / 不满意二元**（不是 5 星），**不满意 → 引导联系客服 / 申请售后**
 *   · 两个接口未封进 `api/index.ts`（任务约定不动该文件）→ 本页 `import { http }` 直调
 * 读取失败**绝不阻断整页**（评价是附加块）：失败按"未评价"渲染入口；
 * 提交遇 400（已评价/状态不允许）时回读一次，把既有结果原地显示出来。
 */
import { computed, onMounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { Field, showConfirmDialog, showToast } from 'vant';
import PageHead from '@/components/PageHead.vue';
import { ApiError, orderApi } from '@/api';
import { http } from '@/api/client';
import { fmtMoney, fmtTime, statusView, STATUS_ICON } from '@/utils/format';

const route = useRoute();

type Any = Record<string, unknown>;

const order = ref<Any | null>(null);
const snapshot = ref<Any | null>(null);
const worker = ref<{ workerNo?: string; nickname?: string } | null>(null);
const logs = ref<Any[]>([]);

const loading = ref(true);
const errMsg = ref('');
const busy = ref(false);
const tips = ref('');

/* ---------- 评价状态 ---------- */
interface ReviewRow {
  satisfied: boolean;
  remark: string;
  createdAt: string;
}

const review = ref<ReviewRow | null>(null);
/** 评价读取是否已收口（未收口先不渲染入口，避免"入口闪一下又变成结果"） */
const reviewReady = ref(false);
const rvChoice = ref<boolean | null>(null);
const rvRemark = ref('');
const rvBusy = ref(false);
const rvTips = ref('');
/** 不满意时后端是否已开启售后通道（POST 响应里的 needAfterSale，原样使用，不猜） */
const needAfterSale = ref(false);
/** 售后申请（不满意 → 下一步）的提交态与错误文案 */
const nxBusy = ref(false);
const nxTips = ref('');

/** 9 种真实状态 → 中文（与服务端 `statusName` 同源；日志条目只有 code，需要本地映射） */
const STATUS_TEXT: Record<string, string> = {
  pending_take: '待接单',
  pending_dispatch: '待确认派单',
  taken: '已接单',
  in_progress: '进行中',
  pending_confirm: '待用户确认',
  completed: '已完成',
  canceled: '已取消',
  abnormal: '异常',
  after_sale: '售后/申诉',
};

const status = computed(() => String(order.value?.status ?? ''));
const tier = computed(() => statusView(status.value));
const iconPath = computed(() => STATUS_ICON[tier.value.tier]);
const statusName = computed(() => String(order.value?.statusName ?? STATUS_TEXT[status.value] ?? '未知状态'));

/** 可取消：未开始的三个阶段（与服务端 cancel 允许集一致） */
const canCancel = computed(() => ['pending_take', 'pending_dispatch', 'taken'].includes(status.value));
/** 确认完成：只有「待用户确认」 */
const canConfirm = computed(() => status.value === 'pending_confirm');
const hasAction = computed(() => canCancel.value || canConfirm.value);

/* ---------- 展示字段（全部来自接口，缺就不显示，不臆造） ---------- */
const quantity = computed(() => Number(snapshot.value?.quantity ?? order.value?.quantity ?? 1));
const unitPrice = computed(() => snapshot.value?.unitPrice ?? order.value?.unitPrice ?? '');
const priceUnit = computed(() => String(snapshot.value?.priceUnit ?? ''));
const totalAmount = computed(() => order.value?.totalAmount ?? snapshot.value?.totalAmount ?? '');
const specText = computed(() => (priceUnit.value ? `${quantity.value} ${priceUnit.value}` : `${quantity.value}`));
const productName = computed(() => String(snapshot.value?.productName ?? '服务订单'));
const zoneRaw = computed(() => String(order.value?.gameZone ?? snapshot.value?.gameZone ?? ''));
const zoneText = computed(() => (zoneRaw.value === 'qq' ? 'QQ区' : zoneRaw.value === 'wechat' ? '微信区' : ''));
const playerId = computed(() => String(order.value?.gamePlayerId ?? snapshot.value?.gamePlayerId ?? ''));
const durationMin = computed(() => Number(snapshot.value?.estimateDurationMin ?? 0));
const remark = computed(() => String(order.value?.userRemark ?? ''));
const gameServer = computed(() => String(snapshot.value?.gameName ?? ''));

/* ---------- 状态时间线 ---------- */
interface TL {
  key: string;
  text: string;
  cls: string;
  icon: string;
  time: string;
  remark: string;
  current: boolean;
}

const timeline = computed<TL[]>(() => {
  const arr = logs.value;
  if (arr.length) {
    // 真实流转：按后端 id ASC 原序逐条画，不重排、不合并、不补中间态
    return arr.map((l, i) => {
      const to = String(l.toStatus ?? '');
      const v = statusView(to);
      return {
        key: `log-${i}-${to}`,
        text: STATUS_TEXT[to] ?? to ?? '状态变更',
        cls: v.cls,
        icon: STATUS_ICON[v.tier],
        time: fmtTime(String(l.createdAt ?? '')),
        remark: String(l.remark ?? ''),
        current: i === arr.length - 1,
      };
    });
  }
  // 无日志：只给两步（当前状态 + 下单创建）
  return [
    {
      key: 'now',
      text: statusName.value,
      cls: tier.value.cls,
      icon: STATUS_ICON[tier.value.tier],
      time: '',
      remark: '',
      current: true,
    },
    {
      key: 'created',
      text: '下单创建',
      cls: 'stag--off',
      icon: STATUS_ICON.off,
      time: fmtTime(String(order.value?.createdAt ?? '')),
      remark: '',
      current: false,
    },
  ];
});

/* ---------- 数据加载 ---------- */
function pickReview(raw: unknown): ReviewRow | null {
  const r = (raw ?? null) as Any | null;
  if (!r || typeof r !== 'object') return null;
  // 服务端未评价时回 null；万一回了空对象，也按"未评价"处理（不臆造结果）
  if (r.satisfied === undefined || r.satisfied === null) return null;
  return {
    satisfied: r.satisfied === true,
    remark: String(r.remark ?? ''),
    createdAt: String(r.createdAt ?? ''),
  };
}

/**
 * 回读评价：**失败不抛、不阻断整页**（评价只是订单详情的一个附加块）。
 * 失败按"未评价"渲染入口 —— 提交时若服务端说「该订单已评价」，
 * `submitReview` 会再回读一次把结果补上（见下方 catch）。
 */
async function loadReview() {
  try {
    const r = await http.get<unknown>(`/user/orders/${route.params.id}/review`);
    review.value = pickReview(r);
  } catch {
    review.value = null;
  } finally {
    reviewReady.value = true;
  }
}

async function load() {
  loading.value = true;
  errMsg.value = '';
  try {
    const d = (await orderApi.detail(String(route.params.id))) as Any;
    order.value = d;
    snapshot.value = (d.snapshot as Any | null) ?? null;
    worker.value = (d.workerInfo as { workerNo?: string; nickname?: string } | null) ?? null;
    logs.value = Array.isArray(d.statusLogs) ? (d.statusLogs as Any[]) : [];
    await loadReview();
  } catch (e) {
    errMsg.value = e instanceof ApiError ? e.message : '加载失败，请稍后重试';
  } finally {
    loading.value = false;
  }
}

/* ---------- 评价 ---------- */

/** 入口条件：已完成 **且** 还没评价（已评过就只显示结果，不再给入口） */
const canReview = computed(() => status.value === 'completed' && !review.value && reviewReady.value);
/** 评价区是否显示：能评（未评）或已有结果（订单后续转售后也仍要能看到自己给过的评价） */
const showReview = computed(() => canReview.value || !!review.value);
/** 可申请售后：仅 completed / abnormal（**与服务端 `userAppeal` 的判定逐字一致**，前端只做渲染收敛） */
const canAppeal = computed(() => ['completed', 'abnormal'].includes(status.value));

function pickSatisfied(v: boolean) {
  rvChoice.value = v;
  rvTips.value = '';
}

async function submitReview() {
  if (rvBusy.value) return;
  if (rvChoice.value === null) {
    rvTips.value = '请先选择「满意」或「不满意」';
    return;
  }
  const satisfied = rvChoice.value;
  const remark = rvRemark.value.trim();
  rvBusy.value = true;
  rvTips.value = '';
  try {
    const res = await http.post<{ ok?: boolean; needAfterSale?: boolean }>(
      `/user/orders/${route.params.id}/review`,
      // remark 为空就不发这个键（契约里它是可选）
      remark ? { satisfied, remark } : { satisfied },
    );
    needAfterSale.value = res?.needAfterSale === true;
    // 先落一份本地态（提交成功的这一刻是真实发生的事实），再回读服务端权威记录覆盖 createdAt
    const local: ReviewRow = { satisfied, remark, createdAt: new Date().toISOString() };
    review.value = local;
    await loadReview();
    if (!review.value) review.value = local;
    rvChoice.value = null;
    rvRemark.value = '';
    showToast(satisfied ? '感谢认可！' : '已记录你的不满意');
  } catch (e) {
    rvTips.value = e instanceof ApiError ? e.message : '提交失败，请稍后重试';
    // 400 = 「该订单已评价」/ 状态不允许 → 回读一次，把既有结果原地显示，别让用户反复点
    if (e instanceof ApiError && e.code === 400) await loadReview();
  } finally {
    rvBusy.value = false;
  }
}

/** execCommand 兜底复制（http://IP 非安全上下文下 Clipboard API 不可用）——只返回成功与否 */
function legacyCopy(text: string): boolean {
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

/** 复制订单号：先 Clipboard API，不可用/被拒再退 execCommand；两种都失败就给可手抄的文案 */
async function copyOrderNo() {
  const no = String(order.value?.orderNo ?? '');
  if (!no) return;
  const text = `订单号 ${no}`;
  let ok = false;
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      ok = true;
    }
  } catch {
    ok = false;
  }
  if (!ok) ok = legacyCopy(text);
  showToast(ok ? '订单号已复制，发给客服即可申请售后' : `复制失败，请手动记录订单号 ${no}`);
}

/**
 * 申请售后（不满意 → 下一步的**真实动作**）
 * ------------------------------------------------------------------
 * 走**既有唯一售后入口** `POST /user/orders/:id/appeal { reason }`（`docs/05`：
 * 仅 `completed` / `abnormal` 可申诉、一单一申诉、提交后订单进入 `after_sale`）——
 * **不新造第二条售后真相**，也不臆造 H5 里并不存在的售后页/客服会话页。
 * 后端评价契约里的 `needAfterSale` 正是"引导客户端走既有申诉通道"的信号（见 migration 注释）。
 * reason 取评价备注；没写备注就给一句可核对的默认原因（管理员裁决时看得到）。
 */
async function applyAfterSale() {
  if (nxBusy.value || !canAppeal.value) return;
  try {
    await showConfirmDialog({
      title: '申请售后',
      message: '申请后订单进入售后状态，由客服核对处理。确定申请吗？',
      confirmButtonText: '确定申请',
      cancelButtonText: '再想想',
    });
  } catch {
    return; // 用户点了「再想想」：showConfirmDialog 以 reject 表示取消，不是错误
  }
  nxBusy.value = true;
  nxTips.value = '';
  try {
    await http.post(`/user/orders/${route.params.id}/appeal`, {
      reason: String(review.value?.remark ?? '').trim() || '对本次服务不满意（来自订单评价）',
    });
    showToast('售后申请已提交，客服会尽快核对');
    await load(); // 订单状态已变为 after_sale：刷新状态区与时间线
  } catch (e) {
    nxTips.value = e instanceof ApiError ? e.message : '提交失败，请稍后重试';
  } finally {
    nxBusy.value = false;
  }
}

/* ---------- 底部操作 ---------- */
async function onConfirm() {
  if (busy.value) return;
  busy.value = true;
  tips.value = '';
  try {
    await orderApi.confirm(String(route.params.id));
    await load();
  } catch (e) {
    // 原样显示服务端中文（如「订单状态已变更，请刷新后重试」），不自己编文案
    tips.value = e instanceof ApiError ? e.message : '操作失败，请稍后重试';
  } finally {
    busy.value = false;
  }
}

async function onCancel() {
  if (busy.value) return;
  busy.value = true;
  tips.value = '';
  try {
    await orderApi.cancel(String(route.params.id));
    await load();
  } catch (e) {
    tips.value = e instanceof ApiError ? e.message : '操作失败，请稍后重试';
  } finally {
    busy.value = false;
  }
}

onMounted(load);
</script>

<template>
  <div class="h5-page" :class="{ 'h5-page--nobar': !hasAction }">
    <PageHead title="订单详情" />

    <div v-if="loading" class="h5-card sk">
      <div class="h5-skel sk__l sk__l--w40" />
      <div class="h5-skel sk__l sk__l--w70" />
      <div class="h5-skel sk__l sk__l--w30" />
    </div>

    <div v-else-if="errMsg && !order" class="h5-empty">
      <p class="em__t">{{ errMsg }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm em__b" type="button" @click="load">重试</button>
    </div>

    <template v-else-if="order">
      <!-- ① 状态区 -->
      <div class="h5-card st">
        <span class="stag" :class="tier.cls">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
            <path :d="iconPath" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
          {{ statusName }}
        </span>
        <div class="st__no">
          <span>订单号</span>
          <b>No.{{ order.orderNo }}</b>
        </div>
      </div>

      <!-- ② 商品与服务规格 -->
      <div class="h5-card">
        <h2 class="blk__t">服务内容</h2>
        <p class="pd__name">{{ productName }}</p>
        <div class="kv">
          <span class="kv__k">规格</span>
          <span class="kv__v">{{ specText }}</span>
        </div>
        <div v-if="gameServer" class="kv">
          <span class="kv__k">游戏</span>
          <span class="kv__v">{{ gameServer }}</span>
        </div>
        <div v-if="zoneText" class="kv">
          <span class="kv__k">区服</span>
          <span class="kv__v">{{ zoneText }}</span>
        </div>
        <div v-if="playerId" class="kv">
          <span class="kv__k">游戏 ID</span>
          <span class="kv__v">{{ playerId }}</span>
        </div>
        <div v-if="durationMin" class="kv">
          <span class="kv__k">预计时长</span>
          <span class="kv__v">{{ durationMin }} 分钟</span>
        </div>
      </div>

      <!-- ③ 护航员（只有头像 + 名字） -->
      <div class="h5-card">
        <h2 class="blk__t">护航员</h2>
        <div v-if="worker" class="wk">
          <div class="wk__av" aria-hidden="true">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <circle cx="12" cy="8.5" r="3.5" /><path d="M5 20c1.3-3.3 3.9-5 7-5s5.7 1.7 7 5" stroke-linecap="round" />
            </svg>
          </div>
          <span class="wk__n">{{ worker.nickname || '护航员' }}</span>
        </div>
        <p v-else class="wk__none">尚未分配护航员</p>
      </div>

      <!-- ④ 服务评价：completed 且未评价 → 入口；已评价 → 原地显示结果，不再显示入口 -->
      <div v-if="showReview" class="h5-card rv">
        <h2 class="blk__t">服务评价</h2>

        <!-- 已评价：结果原地展示 -->
        <template v-if="review">
          <div class="rv__res">
            <span class="stag" :class="review.satisfied ? 'stag--ok' : 'stag--bad-hi'">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                <path
                  :d="review.satisfied ? STATUS_ICON.ok : STATUS_ICON.bad"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
              {{ review.satisfied ? '满意' : '不满意' }}
            </span>
            <span v-if="review.createdAt" class="rv__time">{{ fmtTime(review.createdAt) }}</span>
          </div>
          <p v-if="review.remark" class="rv__rm">{{ review.remark }}</p>

          <!-- 不满意 → 下一步：申请售后（既有申诉入口）/ 联系客服（复制订单号） -->
          <div v-if="!review.satisfied" class="nx">
            <p class="nx__t">下一步：申请售后 / 联系客服</p>
            <p class="nx__x">
              {{
                canAppeal
                  ? needAfterSale
                    ? '平台已记录这次不满意，客服会介入核对；你也可以立刻申请售后。'
                    : '如需补偿或重做，可以申请售后，或把订单号发给客服。'
                  : '该订单已在售后流程中，客服核对处理后会联系你。'
              }}
            </p>
            <div class="nx__acts">
              <button
                v-if="canAppeal"
                class="h5-btn nx__b"
                type="button"
                :disabled="nxBusy"
                @click="applyAfterSale"
              >
                {{ nxBusy ? '提交中…' : '申请售后' }}
              </button>
              <button class="h5-btn h5-btn--ghost h5-btn--sm nx__b--side" type="button" @click="copyOrderNo">
                复制订单号
              </button>
            </div>
            <p v-if="nxTips" class="nx__tips">{{ nxTips }}</p>
          </div>
        </template>

        <!-- 未评价：二选一 + 可选备注 -->
        <template v-else>
          <p class="rv__ask">这次服务满意吗？评价会展示给其他老板参考。</p>

          <div class="rv__pick" role="radiogroup" aria-label="服务评价">
            <button
              type="button"
              role="radio"
              :aria-checked="rvChoice === true"
              class="rv__opt"
              :class="{ 'rv__opt--on-ok': rvChoice === true }"
              @click="pickSatisfied(true)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                <path :d="STATUS_ICON.ok" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
              满意
            </button>
            <button
              type="button"
              role="radio"
              :aria-checked="rvChoice === false"
              class="rv__opt"
              :class="{ 'rv__opt--on-bad': rvChoice === false }"
              @click="pickSatisfied(false)"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                <path :d="STATUS_ICON.bad" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
              不满意
            </button>
          </div>

          <div class="rv__fld">
            <Field
              v-model="rvRemark"
              type="textarea"
              :rows="3"
              :maxlength="200"
              show-word-limit
              placeholder="补充说明（选填，最多 200 字）"
            />
          </div>

          <p v-if="rvTips" class="rv__tips">{{ rvTips }}</p>

          <button
            class="h5-btn rv__sub"
            type="button"
            :disabled="rvBusy || rvChoice === null"
            @click="submitReview"
          >
            {{ rvBusy ? '提交中…' : '提交评价' }}
          </button>
        </template>
      </div>

      <!-- ⑤ 价格明细（单价 × 数量 = 合计） -->
      <div class="h5-card">
        <h2 class="blk__t">价格明细</h2>
        <div class="kv">
          <span class="kv__k">单价</span>
          <span class="kv__v">¥{{ fmtMoney(unitPrice) }} × {{ quantity }}</span>
        </div>
        <div class="kv kv--total">
          <span class="kv__k">合计</span>
          <span class="h5-price kv__total"><span class="h5-price__sym">¥</span>{{ fmtMoney(totalAmount) }}</span>
        </div>
      </div>

      <!-- ⑥ 备注（没有就不渲染这一块） -->
      <div v-if="remark" class="h5-card">
        <h2 class="blk__t">我的备注</h2>
        <p class="rm">{{ remark }}</p>
      </div>

      <!-- ⑦ 状态时间线 -->
      <div class="h5-card">
        <h2 class="blk__t">状态流转</h2>
        <ul class="tl">
          <li v-for="(t, i) in timeline" :key="t.key" class="tl__i" :class="{ 'tl__i--on': t.current }">
            <div class="tl__rail" aria-hidden="true">
              <span class="tl__dot" />
              <span v-if="i < timeline.length - 1" class="tl__line" />
            </div>
            <div class="tl__body">
              <div class="tl__hd">
                <span class="stag" :class="t.cls">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                    <path :d="t.icon" stroke-linecap="round" stroke-linejoin="round" />
                  </svg>
                  {{ t.text }}
                </span>
                <span v-if="t.time" class="tl__time">{{ t.time }}</span>
              </div>
              <p v-if="t.remark" class="tl__rm">{{ t.remark }}</p>
            </div>
          </li>
        </ul>
      </div>

      <!-- ⑧ 下单时间（兜底展示） -->
      <div class="h5-card">
        <div class="kv">
          <span class="kv__k">下单时间</span>
          <span class="kv__v">{{ fmtTime(String(order.createdAt ?? '')) }}</span>
        </div>
      </div>
    </template>

    <!-- 操作失败：服务端中文原文（普通文档流，不压住底部操作条） -->
    <div v-if="tips" class="tips">{{ tips }}</div>

    <!-- 底部操作条：按状态给动作 -->
    <div v-if="!loading && order && hasAction" class="h5-fixedbar">
      <button v-if="canCancel" class="h5-btn h5-btn--ghost" type="button" :disabled="busy" @click="onCancel">
        取消订单
      </button>
      <button v-if="canConfirm" class="h5-btn" type="button" :disabled="busy" @click="onConfirm">
        {{ busy ? '处理中…' : '确认完成' }}
      </button>
    </div>
  </div>
</template>

<style scoped>
/* ---------- 状态区 ---------- */
.st { display: flex; align-items: center; gap: var(--s3); }
.st__no { margin-left: auto; text-align: right; font-size: var(--f6); color: var(--g3); }
.st__no b { display: block; font-size: var(--f5); color: var(--g2); font-weight: 700; font-variant-numeric: tabular-nums; }

/* ---------- 小标题 ---------- */
.blk__t { margin: 0 0 var(--s3); font-size: var(--f4); font-weight: 700; color: var(--g2); letter-spacing: .2px; }

/* ---------- 键值行 ---------- */
.kv { display: flex; align-items: baseline; gap: var(--s3); padding: var(--s2) 0; font-size: var(--f4); }
.kv__k { flex: 0 0 auto; width: 72px; color: var(--g3); }
.kv__v { flex: 1 1 auto; min-width: 0; color: var(--g1); text-align: right; word-break: break-all; }
.kv--total { margin-top: var(--s1); padding-top: var(--s3); border-top: 1px solid var(--g5); }
.kv__total { margin-left: auto; font-size: var(--f2); }

.pd__name { margin: 0 0 var(--s2); font-size: var(--f3); font-weight: 700; color: var(--g1); line-height: 1.45; }
.rm { margin: 0; font-size: var(--f4); color: var(--g2); line-height: 1.6; white-space: pre-wrap; word-break: break-word; }

/* ---------- 护航员 ---------- */
.wk { display: flex; align-items: center; gap: var(--s3); }
.wk__av {
  width: 40px; height: 40px; flex: 0 0 auto;
  display: grid; place-items: center;
  border-radius: var(--r-pill);
  background: var(--pri-soft);
  color: var(--pri);
}
.wk__n { font-size: var(--f3); font-weight: 700; color: var(--g1); }
.wk__none { margin: 0; font-size: var(--f4); color: var(--g3); }

/* ---------- 服务评价 ---------- */
.rv__ask { margin: 0 0 var(--s3); font-size: var(--f4); color: var(--g2); line-height: 1.6; }

/* 满意 / 不满意：二选一（未选中 = 白底灰线，选中才上色 + 加深字重/描边） */
.rv__pick { display: flex; gap: var(--s3); }
.rv__opt {
  flex: 1 1 0;
  display: flex; align-items: center; justify-content: center; gap: var(--s1);
  height: var(--h-btn);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  background: var(--card);
  color: var(--g2);
  font-size: var(--f3);
  font-weight: 700;
  cursor: pointer;
}
.rv__opt--on-ok { border: 2px solid var(--celadon); background: var(--celadon-soft); color: var(--celadon); }
.rv__opt--on-bad { border: 2px solid var(--danger); background: var(--danger-soft); color: var(--danger); font-weight: 800; }

/* Vant Field（textarea）对齐本页控件形态：白底 + 描边 + 10 圆角 */
.rv__fld { margin-top: var(--s3); }
.rv__fld :deep(.van-field) {
  padding: var(--s2) var(--s3);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  background: var(--card);
}
.rv__fld :deep(.van-field__control) { font-size: var(--f4); line-height: 1.6; color: var(--g1); }
.rv__fld :deep(.van-field__word-limit) { font-size: var(--f6); color: var(--g3); }

.rv__tips { margin: var(--s3) 0 0; font-size: var(--f5); color: var(--danger); }
.rv__sub { margin-top: var(--s3); }

/* 已评价结果 */
.rv__res { display: flex; align-items: center; gap: var(--s2); }
.rv__time { margin-left: auto; font-size: var(--f6); color: var(--g3); font-variant-numeric: tabular-nums; }
.rv__rm {
  margin: var(--s2) 0 0;
  font-size: var(--f4);
  color: var(--g1);
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
}

/* 不满意 → 下一步（白底 + 发丝线，不铺色块） */
.nx { margin-top: var(--s3); padding: var(--s3); border: 1px solid var(--g5); border-radius: var(--r-ctrl); background: var(--card); }
.nx__t { margin: 0 0 var(--s2); font-size: var(--f4); font-weight: 700; color: var(--g1); }
.nx__x { margin: 0; font-size: var(--f5); color: var(--g2); line-height: 1.6; }
.nx__acts { display: flex; align-items: center; gap: var(--s3); margin-top: var(--s3); }
.nx__b { flex: 1 1 auto; }
.nx__b--side { flex: 0 0 auto; width: auto; }
.nx__tips { margin: var(--s3) 0 0; font-size: var(--f5); color: var(--danger); }


/* ---------- 时间线 ---------- */
.tl { list-style: none; margin: 0; padding: 0; }
.tl__i { display: flex; gap: var(--s3); }
.tl__i + .tl__i { margin-top: var(--s3); }
/* 轨道首行高度 = 标签行高，圆点在其中居中 → 与标签首行对齐且零魔数 */
.tl__rail { flex: 0 0 auto; width: 12px; height: 24px; display: flex; flex-direction: column; align-items: center; }
.tl__dot { width: 8px; height: 8px; border-radius: var(--r-pill); background: var(--g4); flex: 0 0 auto; }
.tl__i--on .tl__dot { width: 10px; height: 10px; background: var(--pri); }
.tl__line { flex: 1 1 auto; width: 2px; background: var(--g5); margin: var(--s1) 0; }
.tl__body { flex: 1 1 auto; min-width: 0; padding-bottom: var(--s1); }
.tl__hd { display: flex; align-items: center; gap: var(--s2); flex-wrap: wrap; }
.tl__time { font-size: var(--f5); color: var(--g3); font-variant-numeric: tabular-nums; }
.tl__rm { margin: var(--s1) 0 0; font-size: var(--f5); color: var(--g3); line-height: 1.5; }

/* ---------- 骨架 / 空态 / 提示 ---------- */
.sk { display: flex; flex-direction: column; gap: var(--s3); }
.sk__l { height: 12px; }
.sk__l--w40 { width: 40%; }
.sk__l--w70 { width: 70%; }
.sk__l--w30 { width: 30%; }
.em__t { margin: 0 0 var(--s3); }
.em__b { margin: 0 auto; }

.tips {
  margin: 0 var(--page-x) var(--s3);
  padding: var(--s3) var(--card-pad-x);
  background: var(--danger-soft);
  border: 1px solid var(--danger);
  border-radius: var(--r-ctrl);
  color: var(--danger);
  font-size: var(--f4);
  text-align: center;
}
</style>
