<script setup lang="ts">
/**
 * 我的订单（H5）
 * ============================================================================
 * 数据源：`GET /user/orders?page=&pageSize=&status=`
 *   → `{ list: OrderBrief[], total, page, pageSize }`（实测返回形状见报告）
 *
 * 状态筛选传参（**后端 DTO 白名单**，`OrderPageQueryDto.status`）：
 *   不传 status = 全部；可传 8 个真实取值（`server/src/modules/order/dto/order.dto.ts`）：
 *   pending_take / taken / in_progress / pending_confirm / completed / canceled / abnormal / after_sale
 *   → 胶囊「全部」不传参，其余逐个把该值塞进 `query.status`
 *
 * 状态标签**不只靠颜色**：`statusView()` 给形态 class（底/描边/字重）+ `STATUS_ICON` 给独立图标，
 * 再加 statusName 文字 —— 图标 / 形态 / 字重 / 颜色四信号，去色后仍能两两分辨。
 *
 * 硬约束：白底为主 · 间距只用 4dp 网格 · 颜色一律 token · 金额 ¥+两位小数+千分位 · 零 emoji。
 */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import PageHead from '@/components/PageHead.vue';
import { ApiError, orderApi, type OrderBrief } from '@/api';
import { fmtMoney, fmtTime, statusView, STATUS_ICON } from '@/utils/format';

const router = useRouter();

/** 筛选胶囊：第一项「全部」不传 status（后端不传 = 全量） */
const FILTERS: Array<{ label: string; value: string }> = [
  { label: '全部', value: '' },
  { label: '待接单', value: 'pending_take' },
  { label: '已接单', value: 'taken' },
  { label: '进行中', value: 'in_progress' },
  { label: '待确认', value: 'pending_confirm' },
  { label: '已完成', value: 'completed' },
  { label: '已取消', value: 'canceled' },
  { label: '售后', value: 'after_sale' },
];

const PAGE_SIZE = 10;

const status = ref('');
const list = ref<OrderBrief[]>([]);
const total = ref(0);
const page = ref(1);
const loading = ref(false);
const errMsg = ref('');
/** 首屏骨架（与"加载更多"区分：只有整页空的时候才显示骨架） */
const firstLoading = ref(true);

const hasMore = computed(() => list.value.length < total.value);

function amountOf(o: OrderBrief): string {
  return fmtMoney(o.totalAmount);
}

/** 规格行：数量 × 计价单位（服务端给 quantityText/priceUnit；缺失就不编） */
function specOf(o: OrderBrief): string {
  const q = o.quantityText ?? '';
  const u = o.priceUnit ?? '';
  if (q && u) return `${q} ${u}`;
  return u || '';
}

function tierOf(o: OrderBrief) {
  return statusView(o.status);
}

function iconOf(o: OrderBrief): string {
  return STATUS_ICON[tierOf(o).tier];
}

async function load(reset: boolean) {
  if (loading.value) return;
  loading.value = true;
  errMsg.value = '';
  if (reset) {
    page.value = 1;
    firstLoading.value = true;
  }
  try {
    const r = await orderApi.list({
      page: page.value,
      pageSize: PAGE_SIZE,
      // 空串会被请求层过滤掉（`buildUrl` 跳过空值）→ 「全部」天然不带该参数
      status: status.value,
    });
    const items = Array.isArray(r?.list) ? r.list : [];
    list.value = reset ? items : [...list.value, ...items];
    total.value = Number(r?.total ?? list.value.length);
  } catch (e) {
    errMsg.value = e instanceof ApiError ? e.message : '加载失败，请稍后重试';
  } finally {
    loading.value = false;
    firstLoading.value = false;
    // 首屏若还没铺满一屏，哨兵不会进入视口 → 这里主动补一次（避免"只有 2 单却要手动点"）
    ensureFilled();
  }
}

function pickFilter(v: string) {
  if (status.value === v) return;
  status.value = v;
  list.value = [];
  total.value = 0;
  void load(true);
}

function openOrder(id: string) {
  router.push({ name: 'order', params: { id } }).catch(() => {});
}

/* ---------- 触底加载（哨兵 + IntersectionObserver；不引任何依赖） ---------- */
const sentinel = ref<HTMLElement | null>(null);
let io: IntersectionObserver | null = null;

function onSentinel(entries: IntersectionObserverEntry[]) {
  if (!entries.some((e) => e.isIntersecting)) return;
  if (!loading.value && hasMore.value && !errMsg.value) {
    page.value += 1;
    void load(false);
  }
}

/** 首屏补量：DOM 更新后再看一次哨兵是否已在视口内（只在还有下一页时） */
function ensureFilled() {
  requestAnimationFrame(() => {
    const el = sentinel.value;
    if (!el || !hasMore.value || loading.value || errMsg.value) return;
    const r = el.getBoundingClientRect();
    if (r.top <= window.innerHeight + 4) {
      page.value += 1;
      void load(false);
    }
  });
}

onMounted(() => {
  void load(true);
  io = new IntersectionObserver(onSentinel, { rootMargin: '120px 0px' });
  // 哨兵在列表渲染后才存在：用 nextTick 之外的方式绑定（模板 ref 变化时重绑）
  requestAnimationFrame(() => {
    if (sentinel.value) io?.observe(sentinel.value);
  });
});

onBeforeUnmount(() => {
  io?.disconnect();
  io = null;
});
</script>

<template>
  <div class="h5-page">
    <PageHead title="我的订单" :back="false" />

    <!-- 状态筛选胶囊：横向滚动，选中 = 主色浅底 + 主色描边 + 加粗（白底上不做实色块） -->
    <div class="fl">
      <button
        v-for="f in FILTERS"
        :key="f.value || 'all'"
        class="fl__i"
        :class="{ 'fl__i--on': status === f.value }"
        type="button"
        @click="pickFilter(f.value)"
      >
        {{ f.label }}
      </button>
    </div>

    <!-- 首屏骨架 -->
    <div v-if="firstLoading" class="sk">
      <div v-for="i in 3" :key="i" class="h5-card sk__card">
        <div class="h5-skel sk__l sk__l--w40" />
        <div class="h5-skel sk__l sk__l--w70" />
        <div class="h5-skel sk__l sk__l--w30" />
      </div>
    </div>

    <!-- 失败（原样显示服务端中文 message） -->
    <div v-else-if="errMsg && !list.length" class="h5-empty">
      <p class="em__t">{{ errMsg }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm em__b" type="button" @click="load(true)">重试</button>
    </div>

    <!-- 空态 -->
    <div v-else-if="!list.length" class="h5-empty">
      <p class="em__t">这里还没有订单</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm em__b" type="button" @click="router.push({ name: 'products' })">
        去看看服务
      </button>
    </div>

    <!-- 订单卡：白底 + 发丝线 + 14 圆角（无阴影，列表用发丝线） -->
    <template v-else>
      <div
        v-for="o in list"
        :key="o.id"
        class="h5-card oc"
        role="button"
        tabindex="0"
        @click="openOrder(o.id)"
        @keydown.enter="openOrder(o.id)"
      >
        <div class="oc__top">
          <!-- 状态标签：图标 + 形态 + 字重 + 颜色（四信号） -->
          <span class="stag" :class="tierOf(o).cls">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
              <path :d="iconOf(o)" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
            {{ o.statusName || '未知状态' }}
          </span>
          <span class="oc__no">No.{{ o.orderNo }}</span>
        </div>

        <h2 class="oc__name">{{ o.productName || '服务订单' }}</h2>

        <div class="oc__meta">
          <span v-if="specOf(o)">{{ specOf(o) }}</span>
          <span v-if="o.divisionName">{{ o.divisionName }}</span>
          <span v-if="o.workerNickname">护航 {{ o.workerNickname }}</span>
        </div>

        <div class="oc__bot">
          <span class="oc__time">{{ fmtTime(o.createdAt) }}</span>
          <span class="h5-price oc__amt"><span class="h5-price__sym">¥</span>{{ amountOf(o) }}</span>
        </div>
      </div>

      <!-- 触底哨兵 / 加载更多 -->
      <div ref="sentinel" class="more">
        <button v-if="hasMore" class="more__b" type="button" :disabled="loading" @click="page += 1, load(false)">
          {{ loading ? '加载中…' : '加载更多' }}
        </button>
        <p v-else class="more__end">共 {{ total }} 单 · 已到底</p>
      </div>
    </template>
  </div>
</template>

<style scoped>
/* ---------- 筛选胶囊 ---------- */
.fl {
  display: flex;
  gap: var(--s2);
  overflow-x: auto;
  padding: var(--s3) var(--page-x);
  background: var(--card);
  border-bottom: 1px solid var(--g5);
  -webkit-overflow-scrolling: touch;
  scrollbar-width: none;
}
.fl::-webkit-scrollbar { display: none; }
.fl__i {
  flex: 0 0 auto;
  height: var(--h-btn-sm);
  padding: 0 var(--s3);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-pill);
  color: var(--g2);
  font-size: var(--f4);
  font-weight: 600;
  cursor: pointer;
  white-space: nowrap;
}
.fl__i--on {
  background: var(--pri-soft);
  border-color: var(--pri);
  color: var(--pri);
  font-weight: 700;
}

/* ---------- 订单卡 ---------- */
.oc { cursor: pointer; }
.oc:active { background: var(--g6); }
.oc__top { display: flex; align-items: center; gap: var(--s2); }
.oc__no {
  margin-left: auto;
  font-size: var(--f6);
  color: var(--g3);
  font-variant-numeric: tabular-nums;
}
.oc__name {
  margin: var(--s3) 0 var(--s2);
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
  line-height: 1.45;
}
.oc__meta {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s1) var(--s3);
  font-size: var(--f5);
  color: var(--g3);
}
.oc__bot {
  display: flex;
  align-items: baseline;
  gap: var(--s3);
  margin-top: var(--s3);
  padding-top: var(--s3);
  border-top: 1px solid var(--g5);
}
.oc__time { font-size: var(--f5); color: var(--g3); font-variant-numeric: tabular-nums; }
.oc__amt { margin-left: auto; font-size: var(--f2); }

/* ---------- 骨架 ---------- */
.sk__card { display: flex; flex-direction: column; gap: var(--s3); }
.sk__l { height: 12px; }
.sk__l--w40 { width: 40%; }
.sk__l--w70 { width: 70%; }
.sk__l--w30 { width: 30%; }

/* ---------- 空态 / 更多 ---------- */
.em__t { margin: 0 0 var(--s3); }
.em__b { margin: 0 auto; }
.more { padding: var(--s3) var(--page-x) var(--s5); text-align: center; }
.more__b {
  height: var(--h-btn-sm);
  padding: 0 var(--s4);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  color: var(--g2);
  font-size: var(--f5);
  cursor: pointer;
}
.more__end { margin: 0; font-size: var(--f6); color: var(--g3); }
</style>
