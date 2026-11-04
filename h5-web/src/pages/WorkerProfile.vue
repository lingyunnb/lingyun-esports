<script setup lang="ts">
/**
 * 护航员信息（H5）—— 从「找陪玩」列表点头像进入
 * ============================================================================
 * ## 数据源（契约由后端并行实现，页面严格按契约写）
 *   `GET /public/workers/:id`            → { id, nickname, intro, avatarMediaId,
 *                                            completedOrders, reviewCount, satisfiedRate, reviews[] }
 *   `GET /public/workers/:id/reviews?page&pageSize` → { list, total, page, pageSize }
 *   两个接口都**未封进 `api/index.ts`**（任务约定不动该文件）→ 按约定在本页 `import { http }` 直调。
 *
 * ## 为什么"分页接口优先、详情内嵌 reviews 只作兜底"
 * 详情返回里也带 `reviews`，若无脑两处都渲染，首屏会出现**重复行**（同一条评价出现两次）。
 * 所以：首屏列表**只**从分页接口取；分页接口不可用（后端未就绪 / 抖动）时才退回详情内嵌的
 * `reviews`，并且这种降级态下不显示"加载更多"（没有 total 就没有可信的翻页依据）。
 *
 * ## 「绝对不许编 100%」（负责人硬要求）
 * `satisfiedRate` 为 null / 缺失 / 评价数为 0 → 一律显示 **「暂无评价」**，
 * 绝不用 0% 或 100% 填充；`satisfiedRate` 有两种可能下发口径（0–1 比例 / 0–100 百分数），
 * 这里按 `≤1 → 比例` 归一，并夹到 0–100。
 *
 * ## 好评 / 差评不只靠颜色
 * 四重信号：**图标（对勾 / 警示三角，内联 SVG）+ 形态 class（.stag--ok / .stag--bad-hi）
 * + 字重（700 / 800）+ 文案（满意 / 不满意）**；褪色成黑白后仍能两两分辨。
 *
 * 硬约束：白底为主 · 间距只用 4dp 网格 · 颜色一律 token（零硬编码色值）· 零 emoji。
 */
import { computed, onMounted, ref } from 'vue';
import { useRoute } from 'vue-router';
import { showToast } from 'vant';
import PageHead from '@/components/PageHead.vue';
import { http } from '@/api/client';
import { fmtTime, STATUS_ICON } from '@/utils/format';

type Any = Record<string, unknown>;

/** 分页接口单页条数（与"详情内嵌 reviews 只作兜底"配合：兜底态不翻页） */
const PAGE_SIZE = 10;

interface ReviewRow {
  satisfied: boolean;
  remark: string;
  createdAt: string;
  nicknameMasked: string;
}

const route = useRoute();
const id = computed(() => String(route.params.id ?? ''));

const worker = ref<Any | null>(null);
const loading = ref(true);
const errMsg = ref('');

const reviews = ref<ReviewRow[]>([]);
const reviewsErr = ref('');
const page = ref(1);
const total = ref<number | null>(null);
const moreLoading = ref(false);

/* ---------------- 展示换算（全部来自接口，缺就给"暂无"，**不臆造**） ---------------- */

const nickname = computed(() => String(worker.value?.nickname ?? '').trim() || '护航员');

const intro = computed(() => String(worker.value?.intro ?? '').trim());

const avatarMediaId = computed(() => {
  const v = worker.value?.avatarMediaId;
  return v === null || v === undefined || v === '' ? '' : String(v);
});

/** 无头像 → 字标（首字母），**不用 emoji** */
function initial(name: string): string {
  const s = name.trim();
  return s ? s.slice(0, 1).toUpperCase() : '护';
}

/** 接单次数：接口是数字；缺失就显示 "—"（不拿 0 冒充） */
const orderCountText = computed(() => {
  const raw = worker.value?.completedOrders;
  if (raw === null || raw === undefined || raw === '') return '—';
  const n = Number(raw);
  return Number.isFinite(n) ? n.toLocaleString('zh-CN') : '—';
});

/** 评价条数：优先 reviewCount；缺了就用详情内嵌 reviews 的长度；都没有 = 未知(null) */
const reviewCount = computed<number | null>(() => {
  const n = Number(worker.value?.reviewCount);
  if (Number.isFinite(n)) return n;
  const inline = worker.value?.reviews;
  if (Array.isArray(inline)) return inline.length;
  return null;
});

/** 好评率文案 —— 无评价一律「暂无评价」，绝不编 100% */
const rateText = computed(() => {
  if (reviewCount.value === 0) return '暂无评价';
  const raw = worker.value?.satisfiedRate;
  if (raw === null || raw === undefined || raw === '') return '暂无评价';
  const n = Number(raw);
  if (!Number.isFinite(n)) return '暂无评价';
  // ⚠️ **服务端契约：`satisfiedRate` 是「百分数字符串」（如 `"98.2"`），不是 0–1 比率。**
  //
  //    这里曾经写过 `n <= 1 ? n * 100 : n` 的"两种口径兼容"，**那是个致命错**：
  //    当 100 条评价里只有 1 条好评时，服务端给的是 `"1.0"`（= 1%），
  //    旧写法会把它渲染成 **100%** —— 等于**把差评显示成满分**，
  //    是评价体系里最不能出的错（用户会照着满分去下单）。
  //    口径由服务端唯一决定（见 docs/03），前端**只做展示、不做猜测**。
  const pct = Math.min(100, Math.max(0, n));
  const r = Math.round(pct * 10) / 10;
  return `${Number.isInteger(r) ? r : r.toFixed(1)}%`;
});

/** 好评率是否处于"暂无评价"（用于把数字档位降级成灰字，视觉上别装成一个成绩） */
const rateNone = computed(() => rateText.value === '暂无评价');

const countText = computed(() => {
  const n = reviewCount.value;
  if (n === null) return '';
  return n > 0 ? `共 ${n.toLocaleString('zh-CN')} 条评价` : '暂无评价';
});

/** 每档一个独立图标（去色后仍可分辨的第一重信号） */
function reviewIcon(satisfied: boolean): string {
  return satisfied ? STATUS_ICON.ok : STATUS_ICON.bad;
}

const hasMore = computed(() => total.value !== null && reviews.value.length < total.value);

/* ---------------- 取数 ---------------- */

function pickReviews(raw: unknown): ReviewRow[] {
  const arr = Array.isArray(raw) ? raw : [];
  return (arr as Any[]).map((r) => ({
    satisfied: r?.satisfied === true,
    remark: String(r?.remark ?? ''),
    createdAt: String(r?.createdAt ?? ''),
    nicknameMasked: String(r?.nicknameMasked ?? ''),
  }));
}

async function loadReviews(reset: boolean) {
  const p = reset ? 1 : page.value;
  try {
    const r = await http.get<Any>(`/public/workers/${id.value}/reviews`, {
      query: { page: p, pageSize: PAGE_SIZE },
      anonymous: true,
    });
    const rows = pickReviews((r as Any)?.list);
    const t = Number((r as Any)?.total);
    if (Number.isFinite(t)) total.value = t;
    reviews.value = reset ? rows : [...reviews.value, ...rows];
    page.value = p + 1;
    reviewsErr.value = '';
  } catch (e) {
    if (!reset) {
      // 翻页失败：退回上一页游标，页面已加载的内容不动
      page.value = Math.max(1, p);
      showToast(e instanceof Error ? e.message : '加载失败，请稍后重试');
      return;
    }
    // 首屏：分页接口不可用 → 退回详情内嵌 reviews；连兜底都没有才算"评价加载失败"
    const inline = pickReviews(worker.value?.reviews);
    reviews.value = inline;
    total.value = null;
    reviewsErr.value = inline.length
      ? ''
      : e instanceof Error
        ? e.message
        : '评价加载失败，请稍后重试';
  }
}

async function load() {
  loading.value = true;
  errMsg.value = '';
  reviewsErr.value = '';
  try {
    worker.value = await http.get<Any>(`/public/workers/${id.value}`, { anonymous: true });
  } catch (e) {
    errMsg.value = e instanceof Error ? e.message : '加载失败，请稍后重试';
    worker.value = null;
    loading.value = false;
    return;
  }
  loading.value = false;
  await loadReviews(true);
}

async function more() {
  if (moreLoading.value || !hasMore.value) return;
  moreLoading.value = true;
  await loadReviews(false);
  moreLoading.value = false;
}

onMounted(load);
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="护航员信息" />

    <!-- 骨架 -->
    <div v-if="loading" class="h5-card wp__sk">
      <span class="h5-skel wp__sk-av" />
      <div class="wp__sk-body">
        <span class="h5-skel wp__sk-l wp__sk-l--name" />
        <span class="h5-skel wp__sk-l wp__sk-l--intro" />
      </div>
    </div>

    <div v-else-if="errMsg && !worker" class="wp__state">
      <p class="h5-empty">{{ errMsg }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" type="button" @click="load">重试</button>
    </div>

    <template v-else-if="worker">
      <!-- ① 资料：头像 + 名字 + 介绍 -->
      <div class="h5-card wp">
        <img v-if="avatarMediaId" class="wp__av" :src="`/media/public/${avatarMediaId}`" :alt="nickname" />
        <span v-else class="wp__av wp__av--txt" aria-hidden="true">{{ initial(nickname) }}</span>
        <h1 class="wp__n">{{ nickname }}</h1>
        <p v-if="intro" class="wp__intro">{{ intro }}</p>
        <p v-else class="wp__intro wp__intro--none">暂无介绍</p>
      </div>

      <!-- ② 接单次数 + 好评率（无评价 → 「暂无评价」，不编 100%） -->
      <div class="h5-card st">
        <div class="st__i">
          <b class="st__v">{{ orderCountText }}</b>
          <span class="st__k">接单次数</span>
        </div>
        <span class="st__line" aria-hidden="true" />
        <div class="st__i">
          <b class="st__v" :class="{ 'st__v--none': rateNone }">{{ rateText }}</b>
          <span class="st__k">好评率</span>
        </div>
      </div>

      <!-- ③ 最近评价 -->
      <div class="h5-card rv">
        <div class="rv__head">
          <h2 class="rv__t">最近评价</h2>
          <span v-if="countText" class="rv__c">{{ countText }}</span>
        </div>

        <div v-if="reviewsErr" class="rv__state">
          <p class="rv__state-t">{{ reviewsErr }}</p>
          <button class="h5-btn h5-btn--ghost h5-btn--sm" type="button" @click="loadReviews(true)">重试</button>
        </div>

        <p v-else-if="!reviews.length" class="rv__none">暂无评价</p>

        <ul v-else class="rv__list">
          <li v-for="(r, i) in reviews" :key="`${r.createdAt}-${i}`" class="rv__i">
            <div class="rv__hd">
              <!-- 图标 + 形态 + 字重 + 文案：四重信号，不只靠颜色 -->
              <span class="stag" :class="r.satisfied ? 'stag--ok' : 'stag--bad-hi'">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                  <path :d="reviewIcon(r.satisfied)" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
                {{ r.satisfied ? '满意' : '不满意' }}
              </span>
              <span v-if="r.createdAt" class="rv__time">{{ fmtTime(r.createdAt) }}</span>
            </div>
            <p v-if="r.remark" class="rv__rm">{{ r.remark }}</p>
            <p class="rv__by">{{ r.nicknameMasked || '匿名用户' }}</p>
          </li>
        </ul>

        <div v-if="hasMore" class="rv__more">
          <button class="h5-btn h5-btn--ghost h5-btn--sm" type="button" :disabled="moreLoading" @click="more">
            {{ moreLoading ? '加载中…' : '加载更多' }}
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
/* ---------- ① 资料 ---------- */
.wp {
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
}
.wp__av {
  width: 64px;
  height: 64px;
  border-radius: var(--r-pill);
  object-fit: cover;
  background: var(--g6);
}
.wp__av--txt {
  display: grid;
  place-items: center;
  background: var(--pri-soft);
  color: var(--pri);
  font-size: var(--f2);
  font-weight: 700;
}
.wp__n {
  margin: var(--s3) 0 0;
  font-size: var(--f2);
  font-weight: 800;
  color: var(--g1);
  line-height: 1.3;
}
.wp__intro {
  margin: var(--s2) 0 0;
  font-size: var(--f4);
  color: var(--g2);
  line-height: 1.6;
  word-break: break-word;
}
.wp__intro--none {
  color: var(--g3);
}

/* ---------- ② 两个统计档 ---------- */
.st {
  display: flex;
  align-items: center;
}
.st__i {
  flex: 1 1 0;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--s1);
}
.st__v {
  font-size: var(--f2);
  font-weight: 800;
  color: var(--g1);
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
/* 无评价：降级成灰字 + 常规字号感（不把一个"没有成绩"渲染成成绩） */
.st__v--none {
  font-size: var(--f4);
  font-weight: 700;
  color: var(--g3);
}
.st__k {
  font-size: var(--f6);
  color: var(--g3);
}
.st__line {
  flex: 0 0 auto;
  width: 1px;
  height: 32px;
  background: var(--g5);
}

/* ---------- ③ 评价列表 ---------- */
.rv__head {
  display: flex;
  align-items: baseline;
  gap: var(--s2);
  margin-bottom: var(--s3);
}
.rv__t {
  margin: 0;
  font-size: var(--f4);
  font-weight: 700;
  color: var(--g2);
}
.rv__c {
  margin-left: auto;
  font-size: var(--f6);
  color: var(--g3);
}
.rv__none {
  margin: 0;
  padding: var(--s6) 0;
  text-align: center;
  font-size: var(--f5);
  color: var(--g3);
}
.rv__state {
  display: grid;
  justify-items: center;
  gap: var(--s3);
  padding: var(--s5) 0;
}
.rv__state-t {
  margin: 0;
  font-size: var(--f5);
  color: var(--g3);
}
.rv__list {
  list-style: none;
  margin: 0;
  padding: 0;
}
.rv__i {
  padding: var(--s3) 0;
}
.rv__i + .rv__i {
  border-top: 1px solid var(--g5);
}
.rv__hd {
  display: flex;
  align-items: center;
  gap: var(--s2);
}
.rv__time {
  margin-left: auto;
  font-size: var(--f6);
  color: var(--g3);
  font-variant-numeric: tabular-nums;
}
.rv__rm {
  margin: var(--s2) 0 0;
  font-size: var(--f4);
  color: var(--g1);
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
}
.rv__by {
  margin: var(--s2) 0 0;
  font-size: var(--f6);
  color: var(--g3);
}
.rv__more {
  display: flex;
  justify-content: center;
  padding-top: var(--s3);
  border-top: 1px solid var(--g5);
}

/* ---------- 骨架 ---------- */
.wp__sk {
  display: flex;
  align-items: center;
  gap: var(--s3);
}
.wp__sk-av {
  flex: 0 0 auto;
  width: 64px;
  height: 64px;
  border-radius: var(--r-pill);
}
.wp__sk-body {
  flex: 1 1 auto;
  min-width: 0;
}
.wp__sk-l {
  display: block;
  border-radius: var(--r-sm);
}
.wp__sk-l--name {
  width: 96px;
  height: 12px;
  margin-bottom: var(--s2);
}
.wp__sk-l--intro {
  width: 60%;
  height: 8px;
}

/* ---------- 错误态 ---------- */
.wp__state {
  display: grid;
  justify-items: center;
}
.wp__state .h5-empty {
  padding-bottom: var(--s2);
}
</style>
