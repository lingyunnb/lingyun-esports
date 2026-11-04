<script setup lang="ts">
/**
 * 商品详情
 * ---------------------------------------------------------------------------
 * 数据源：`GET /public/products/:id`（真实返回已 curl 核对）
 *
 * 信息层级（自上而下，读者决策顺序 = 从"这是什么"到"多少钱"到"怎么买"）：
 *   ① 主图（有才显示）
 *   ② 商品名 + 徽标 + 规格元信息（平台 / 预计耗时 / 销量）
 *   ③ 价格 — 规格（数量）— 费用（单价 × 数量 = 合计）
 *   ④ 服务内容（`subtitle` → 退化 `listName`）
 *   ⑤ 下单须知（`effectiveOrderNotice`，服务端下发的权威文案，保留换行）
 *   ⑥ 底部固定操作条（合计 + 下单入口）
 *
 * ## 已核实的字段事实（勿凭想象改）
 * - `description / detail / serviceFlow / serviceRules / attention` 线上**全是 null**
 *   → 正文区只能靠 `effectiveOrderNotice`，不要为这些空字段留位。
 * - `serviceStatus`：**1 上架 / 2 下架**（`product.entity.ts:93`）。公开接口只会返回上架商品，
 *   这里仍做一次兜底判定，避免直接改 URL 进到已下架商品还能点下单。
 * - `divisionId` 只是**回显/透传**用；下单时服务端按商品归属自行决定分部
 *   （`order.service.ts` 里 `divisionId: product.divisionId`，客户端传了也会被 DTO 白名单拒掉）。
 */
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { publicApi, ApiError } from '@/api';
import { fmtMoney } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

interface ProductDetail {
  id: string;
  name: string;
  subtitle?: string | null;
  listName?: string | null;
  badgeText?: string | null;
  divisionId?: string | null;
  divisionPlatformLabel?: string | null;
  price: string | number;
  priceUnit?: string | null;
  estimateDurationMin?: number | null;
  salesCount?: number | null;
  serviceStatus?: number | null;
  coverUrl?: string | null;
  effectiveOrderNotice?: string | null;
  [k: string]: unknown;
}

const route = useRoute();
const router = useRouter();

const productId = String(route.params.id ?? '');

const data = ref<ProductDetail | null>(null);
const loading = ref(true);
const errorMsg = ref('');
const qty = ref(1);

const unit = computed(() => String(data.value?.priceUnit || '单'));
const price = computed(() => Number(data.value?.price ?? 0));
const total = computed(() => price.value * qty.value);

/** 上架才可下单（1 上架 / 2 下架） */
const onSale = computed(() => Number(data.value?.serviceStatus ?? 1) === 1);

/** 服务内容：优先 subtitle，其次 listName；都没有就不渲染该块（不编造文案） */
const serviceText = computed(
  () => String(data.value?.subtitle || '').trim() || String(data.value?.listName || '').trim(),
);

const notice = computed(() => String(data.value?.effectiveOrderNotice || '').trim());

async function fetchDetail() {
  loading.value = true;
  errorMsg.value = '';
  try {
    data.value = (await publicApi.product(productId)) as ProductDetail;
  } catch (e) {
    errorMsg.value = e instanceof ApiError ? e.message : '加载失败，请重试';
  } finally {
    loading.value = false;
  }
}

function step(delta: number) {
  const next = qty.value + delta;
  if (next < 1 || next > 99) return; // DTO 数量上限 99（order.dto.ts）
  qty.value = next;
}

function goOrder() {
  if (!onSale.value) return;
  router.push({
    name: 'orderNew',
    query: { productId, divisionId: String(data.value?.divisionId ?? ''), quantity: String(qty.value) },
  });
}

onMounted(fetchDetail);
</script>

<template>
  <div class="h5-page h5-page--nobar detail">
    <PageHead title="商品详情" />

    <div v-if="loading" class="skeletons">
      <div class="h5-skel skel skel--sm" />
      <div class="h5-skel skel" />
      <div class="h5-skel skel" />
    </div>

    <div v-else-if="errorMsg" class="state">
      <p class="state__t">{{ errorMsg }}</p>
      <button class="h5-btn h5-btn--ghost state__btn" type="button" @click="fetchDetail">重新加载</button>
    </div>

    <template v-else-if="data">
      <div v-if="data.coverUrl" class="hero">
        <img :src="String(data.coverUrl)" :alt="data.name" />
      </div>

      <!-- ① 商品名 + 元信息 -->
      <section class="h5-card">
        <div class="title">
          <h1 class="title__t">{{ data.name }}</h1>
          <span v-if="data.badgeText" class="tag-gold">{{ data.badgeText }}</span>
        </div>
        <p class="meta">
          <span v-if="data.divisionPlatformLabel">{{ data.divisionPlatformLabel }}</span>
          <span v-if="data.estimateDurationMin">预计 {{ data.estimateDurationMin }} 分钟</span>
          <span v-if="Number(data.salesCount) > 0">已售 {{ data.salesCount }} 单</span>
          <span v-if="!onSale" class="meta__off">已下架</span>
        </p>
      </section>

      <!-- ② 价格 · 规格 · 费用 -->
      <section class="h5-card">
        <div class="row">
          <span class="row__k">单价</span>
          <span class="row__v">
            <span class="h5-price"><span class="h5-price__sym">¥</span>{{ fmtMoney(price) }}</span>
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
          <span class="row__k row__k--strong">合计</span>
          <span class="row__v">
            <span class="h5-price total-price"><span class="h5-price__sym">¥</span>{{ fmtMoney(total) }}</span>
          </span>
        </div>
      </section>

      <!-- ③ 服务内容 -->
      <section v-if="serviceText" class="h5-card">
        <h2 class="sec__t">服务内容</h2>
        <p class="sec__p">{{ serviceText }}</p>
      </section>

      <!-- ④ 下单须知（服务端权威文案，保留原有换行） -->
      <section v-if="notice" class="h5-card">
        <h2 class="sec__t">下单须知</h2>
        <p class="sec__p sec__p--pre">{{ notice }}</p>
      </section>
    </template>

    <!-- ⑤ 底部固定操作条 -->
    <div v-if="data && !loading && !errorMsg" class="h5-fixedbar">
      <div class="bar__fee">
        <span class="bar__k">合计</span>
        <span class="h5-price bar__v"><span class="h5-price__sym">¥</span>{{ fmtMoney(total) }}</span>
      </div>
      <button class="h5-btn bar__btn" type="button" :disabled="!onSale" @click="goOrder">
        {{ onSale ? '立即下单' : '该商品已下架' }}
      </button>
    </div>
  </div>
</template>

<style scoped>
/* 底部固定条高 44 + 上下各 12 → 给内容留 68，避免最后一块被盖住 */
.detail {
  padding-bottom: calc(var(--h-btn) + var(--s6) + var(--safe-bottom));
}

.skeletons {
  padding: var(--s3) var(--page-x) 0;
}
.skel {
  height: 96px;
  margin-bottom: var(--s3);
}
.skel--sm {
  height: 56px;
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

.hero {
  background: var(--g6);
  border-bottom: 1px solid var(--g5);
}
.hero img {
  width: 100%;
  aspect-ratio: 16 / 9;
  object-fit: cover;
}

.title {
  display: flex;
  align-items: flex-start;
  gap: var(--s2);
}
.title__t {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: var(--f2);
  font-weight: 800;
  line-height: 1.4;
  color: var(--g1);
}
.tag-gold {
  flex: 0 0 auto;
  padding: 0 var(--s2);
  height: 20px;
  line-height: 18px;
  border: 1px solid var(--gold);
  border-radius: var(--r-sm);
  font-size: var(--f6);
  font-weight: 700;
  color: var(--gold);
  white-space: nowrap;
}

.meta {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s3);
  margin: var(--s2) 0 0;
  font-size: var(--f5);
  color: var(--g3);
}
.meta__off {
  color: var(--danger);
  font-weight: 700;
}

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
  /* 无 stepper 时右对齐更整齐；有 stepper 时由 stepper 自身撑开 */
  justify-content: flex-end;
  gap: var(--s1);
}
.row--total {
  padding-top: var(--s3);
}
.row__unit {
  font-size: var(--f6);
  color: var(--g3);
}
.total-price {
  font-size: var(--f2);
}

/* 数量步进：32 高（--h-btn-sm），落在 4dp 网格上 */
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

.sec__t {
  margin: 0 0 var(--s2);
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
}
.sec__p {
  margin: 0;
  font-size: var(--f5);
  line-height: 1.7;
  color: var(--g2);
}
.sec__p--pre {
  white-space: pre-line;
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
