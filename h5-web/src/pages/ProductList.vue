<script setup lang="ts">
/**
 * 选择服务（商品列表）
 * ---------------------------------------------------------------------------
 * 数据源（**真实接口**，字段名一律以实际返回为准，勿凭想象改）：
 *   · GET /public/products       → { list, total, page, pageSize }
 *   · GET /divisions/grouped     → [{ gameId, gameName, platformCount, divisions: [...] }]
 *   · GET /public/categories     → [{ id, gameId, name, ... }]
 *
 * ## 三件已核实的事（写代码前 curl 过的，别再踩）
 * 1. `/public/products` 的可用查询参数**只有** `gameId / categoryId / divisionId / page / pageSize`
 *    （见 `server/src/modules/product/public-catalog.controller.ts`）。
 *    **没有 `keyword`** —— 服务端不认这个参数，传了会被静默忽略（不报错，但也不生效）。
 *    因此关键词搜索在本页做**客户端过滤**：有词时按最大 `pageSize=50` 拉一页再滤
 *    （上限 50 见 `server/src/common/pagination.ts`）。
 * 2. 列表项**没有 `divisionName`**，只有 `divisionId`；分部名从 `/divisions/grouped` 建映射拿。
 * 3. 线上 `subtitle` 普遍是空串 → 「核心服务内容」优先 `subtitle`，其次 `listName`；
 *    两者都没有时**不编造营销文案**，改由真实字段组成的规格行（耗时/单位）承担信息量。
 *    （业务上这些商品的「核心服务内容」本来就写在 `name` 里，如
 *     「基础保底700w和凌云单挑 打赢加1000w打输不加」。）
 */
import { computed, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { publicApi, divisionApi, ApiError } from '@/api';
import { fmtMoney } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

/* ---------------- 类型（宽松：与 api/index.ts 的 Profile/OrderBrief 同风格） ---------------- */

interface ProductItem {
  id: string;
  name: string;
  subtitle?: string | null;
  listName?: string | null;
  badgeText?: string | null;
  divisionId?: string | null;
  categoryId?: string | null;
  price: string | number;
  priceUnit?: string | null;
  estimateDurationMin?: number | null;
  salesCount?: number | null;
  coverUrl?: string | null;
  [k: string]: unknown;
}

interface DivisionItem {
  id: string;
  name?: string | null;
  shortName?: string | null;
  gameId?: string | null;
  platformLabel?: string | null;
  [k: string]: unknown;
}

interface CategoryItem {
  id: string;
  name: string;
  gameId?: string | null;
  [k: string]: unknown;
}

type DivisionGroup = { divisions?: DivisionItem[] } & Record<string, unknown>;

/* ---------------- 状态 ---------------- */

/** 普通分页每页 10；搜索时拉满 50（服务端上限）以便客户端过滤覆盖尽可能多 */
const PAGE_SIZE = 10;
const SEARCH_PAGE_SIZE = 50;

const router = useRouter();

const divisions = ref<DivisionItem[]>([]);
const categories = ref<CategoryItem[]>([]);

const divisionId = ref('');
const categoryId = ref('');
const keyword = ref('');

const list = ref<ProductItem[]>([]);
const page = ref(1);
const total = ref(0);
const loading = ref(true);
const loadingMore = ref(false);
const errorMsg = ref('');

const searching = computed(() => keyword.value.trim().length > 0);

/** 展示用列表：搜索词只在**已加载集合**上过滤（服务端无 keyword 参数） */
const shown = computed(() => {
  const kw = keyword.value.trim().toLowerCase();
  if (!kw) return list.value;
  return list.value.filter((p) =>
    `${p.name ?? ''} ${p.subtitle ?? ''} ${p.listName ?? ''}`.toLowerCase().includes(kw),
  );
});

/** 分部名映射（列表只用 divisionId，名字从分区接口补） */
const divisionName = computed<Record<string, string>>(() => {
  const m: Record<string, string> = {};
  for (const d of divisions.value) m[d.id] = String(d.shortName || d.name || '').trim();
  return m;
});

const hasMore = computed(
  () => !searching.value && list.value.length > 0 && list.value.length < total.value,
);

/* ---------------- 取数 ---------------- */

async function fetchDivisions() {
  try {
    const raw: unknown = await divisionApi.grouped();
    const groups = (Array.isArray(raw) ? raw : []) as DivisionGroup[];
    // 展平：分组只是给首页用的层级，这里要的是可筛选的全部分部
    divisions.value = groups.flatMap((g) => (Array.isArray(g.divisions) ? g.divisions : []));
  } catch {
    /* 分部拿不到不影响商品主流程：筛选行隐藏即可，不做报错页 */
    divisions.value = [];
  }
}

/**
 * 分类是**挂在游戏下**的，所以要按「当前分部的 gameId」取。
 * 未选分部时不显示分类行 —— 否则会把别的游戏的分类混进来（当前库里有 3 个游戏共 6 个分类）。
 */
async function fetchCategories() {
  const div = divisions.value.find((d) => d.id === divisionId.value);
  const gameId = div?.gameId ? String(div.gameId) : '';
  if (!gameId) {
    categories.value = [];
    return;
  }
  try {
    const rows = (await publicApi.categories({ gameId })) as CategoryItem[];
    categories.value = rows.filter((c) => c && c.id && c.name);
  } catch {
    categories.value = [];
  }
}

async function fetchList(reset: boolean) {
  if (reset) {
    page.value = 1;
    loading.value = true;
    errorMsg.value = '';
  } else {
    loadingMore.value = true;
    page.value += 1;
  }

  try {
    const res = await publicApi.products({
      divisionId: divisionId.value || undefined,
      categoryId: categoryId.value || undefined,
      page: page.value,
      pageSize: searching.value ? SEARCH_PAGE_SIZE : PAGE_SIZE,
    });
    const items = (res?.list ?? []) as ProductItem[];
    list.value = reset ? items : [...list.value, ...items];
    total.value = Number(res?.total ?? items.length);
  } catch (e) {
    errorMsg.value = e instanceof ApiError ? e.message : '加载失败，请重试';
    // 追加失败要回退页码，否则重试会跳过一整页
    if (!reset) page.value -= 1;
  } finally {
    loading.value = false;
    loadingMore.value = false;
  }
}

/* ---------------- 交互 ---------------- */

function pickDivision(id: string) {
  if (divisionId.value === id) return;
  divisionId.value = id;
  categoryId.value = ''; // 分类属于某个游戏，换分部必须清掉，否则筛出空列表
  fetchCategories();
  fetchList(true);
}

function pickCategory(id: string) {
  if (categoryId.value === id) return;
  categoryId.value = id;
  fetchList(true);
}

function goDetail(id: string) {
  router.push({ name: 'product', params: { id } });
}

/** 卡片「下单」直达下单页：下单页会自己按 productId 拉商品，链路更短 */
function goOrder(id: string) {
  router.push({ name: 'orderNew', query: { productId: id } });
}

/** 卡片上的「核心服务内容」行；没有就不渲染这一行（不编造文案） */
function svcLine(p: ProductItem): string {
  return String(p.subtitle || '').trim() || String(p.listName || '').trim();
}

onMounted(async () => {
  await fetchDivisions();
  await fetchList(true);
});

/**
 * 搜索词只在「有/无」翻转时才需要重新请求（决定 pageSize 与是否分页），
 * 词本身的变化由 computed 客户端过滤承接 —— 避免每敲一个字打一次接口。
 */
let hadKeyword = false;
watch(keyword, () => {
  const has = searching.value;
  if (has !== hadKeyword) {
    hadKeyword = has;
    fetchList(true);
  }
});
</script>

<template>
  <div class="h5-page h5-page--nobar plist">
    <PageHead title="选择服务" />

    <!-- 筛选区：白底 + 发丝线，不做彩色块 -->
    <div class="filters">
      <label class="search">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="6.5" />
          <path d="m16 16 4.5 4.5" stroke-linecap="round" />
        </svg>
        <input v-model="keyword" type="search" placeholder="搜索商品名称" enterkeyhint="search" />
        <button v-if="searching" class="search__clear" type="button" aria-label="清空" @click="keyword = ''">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M6 6l12 12M18 6L6 18" stroke-linecap="round" />
          </svg>
        </button>
      </label>

      <div v-if="divisions.length" class="chips" role="tablist" aria-label="分部筛选">
        <button
          class="chip"
          :class="{ 'chip--on': divisionId === '' }"
          type="button"
          @click="pickDivision('')"
        >
          全部分部
        </button>
        <button
          v-for="d in divisions"
          :key="d.id"
          class="chip"
          :class="{ 'chip--on': divisionId === d.id }"
          type="button"
          @click="pickDivision(d.id)"
        >
          {{ d.shortName || d.name }}
        </button>
      </div>

      <div v-if="categories.length" class="chips" role="tablist" aria-label="分类筛选">
        <button class="chip" :class="{ 'chip--on': categoryId === '' }" type="button" @click="pickCategory('')">
          全部分类
        </button>
        <button
          v-for="c in categories"
          :key="c.id"
          class="chip"
          :class="{ 'chip--on': categoryId === c.id }"
          type="button"
          @click="pickCategory(c.id)"
        >
          {{ c.name }}
        </button>
      </div>
    </div>

    <p v-if="!loading && !errorMsg" class="count">
      共 {{ searching ? shown.length : total }} 件{{ searching ? '（在当前已加载的商品中筛选）' : '' }}
    </p>

    <!-- 骨架：首屏不空屏 -->
    <div v-if="loading" class="skeletons">
      <div v-for="i in 3" :key="i" class="h5-skel skel" />
    </div>

    <div v-else-if="errorMsg" class="state">
      <p class="state__t">{{ errorMsg }}</p>
      <button class="h5-btn h5-btn--ghost state__btn" type="button" @click="fetchList(true)">重新加载</button>
    </div>

    <div v-else-if="!shown.length" class="h5-empty">
      <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4">
        <path d="M4 7h16v13H4z" /><path d="M7 7V5a3 3 0 0 1 6 0v2" />
      </svg>
      <p>{{ searching ? '没有匹配的商品，换个关键词试试' : '该筛选下暂无商品' }}</p>
    </div>

    <template v-else>
      <article v-for="p in shown" :key="p.id" class="pcard" @click="goDetail(p.id)">
        <div class="pcard__thumb">
          <img v-if="p.coverUrl" :src="String(p.coverUrl)" :alt="p.name" loading="lazy" />
          <span v-else class="pcard__ph">{{ (p.name || '服').slice(0, 1) }}</span>
        </div>

        <div class="pcard__body">
          <div class="pcard__top">
            <h2 class="pcard__name">{{ p.name }}</h2>
            <span v-if="divisionName[String(p.divisionId)]" class="pcard__div">
              {{ divisionName[String(p.divisionId)] }}
            </span>
          </div>

          <p v-if="svcLine(p)" class="pcard__svc">{{ svcLine(p) }}</p>

          <div class="pcard__meta">
            <span v-if="p.estimateDurationMin">约 {{ p.estimateDurationMin }} 分钟</span>
            <span v-if="Number(p.salesCount) > 0">已售 {{ p.salesCount }} 单</span>
            <span v-if="p.badgeText" class="pcard__badge">{{ p.badgeText }}</span>
          </div>

          <div class="pcard__foot">
            <span class="h5-price pcard__price">
              <span class="h5-price__sym">¥</span>{{ fmtMoney(p.price) }}
            </span>
            <span class="pcard__unit">/{{ p.priceUnit || '单' }}</span>
            <button class="h5-btn h5-btn--sm pcard__btn" type="button" @click.stop="goOrder(p.id)">
              下单
            </button>
          </div>
        </div>
      </article>

      <div class="more">
        <button v-if="hasMore" class="h5-btn h5-btn--ghost" type="button" :disabled="loadingMore" @click="fetchList(false)">
          {{ loadingMore ? '加载中…' : '加载更多' }}
        </button>
        <p v-else class="more__end">— 没有更多了 —</p>
      </div>
    </template>
  </div>
</template>

<style scoped>
.plist {
  padding-bottom: var(--s6);
}

/* ---- 筛选区 ---- */
.filters {
  position: sticky;
  top: calc(var(--h-bar) + var(--safe-top));
  z-index: 10;
  background: var(--card);
  border-bottom: 1px solid var(--g5);
  padding: var(--s3) var(--page-x) var(--s2);
}

.search {
  display: flex;
  align-items: center;
  gap: var(--s2);
  height: var(--h-btn-sm);
  padding: 0 var(--s3);
  border: 1px solid var(--g4);
  border-radius: var(--r-pill);
  color: var(--g3);
}
.search input {
  flex: 1 1 auto;
  min-width: 0;
  border: 0;
  outline: 0;
  background: none;
  color: var(--g1);
  font-size: var(--f4);
}
.search input::-webkit-search-cancel-button {
  display: none;
}
.search__clear {
  display: grid;
  place-items: center;
  width: 20px;
  height: 20px;
  padding: 0;
  border: 0;
  background: none;
  color: var(--g3);
  cursor: pointer;
}

.chips {
  display: flex;
  gap: var(--s2);
  margin-top: var(--s3);
  overflow-x: auto;
  scrollbar-width: none;
}
.chips::-webkit-scrollbar {
  display: none;
}
.chip {
  flex: 0 0 auto;
  height: 28px;
  padding: 0 var(--s3);
  border: 1px solid var(--g5);
  border-radius: var(--r-pill);
  background: var(--card);
  color: var(--g2);
  font-size: var(--f5);
  cursor: pointer;
  white-space: nowrap;
}
/* 选中档：品牌色只落在「选中态」这一处，不铺大色块 */
.chip--on {
  background: var(--pri-soft);
  border-color: var(--pri);
  color: var(--pri);
  font-weight: 700;
}

.count {
  margin: var(--s3) var(--page-x) var(--s2);
  font-size: var(--f5);
  color: var(--g3);
}

/* ---- 骨架 / 状态 ---- */
.skeletons {
  padding: 0 var(--page-x);
}
.skel {
  height: 96px;
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

.h5-empty svg {
  color: var(--g4);
  margin: 0 auto var(--s3);
}
.h5-empty p {
  margin: 0;
}

/* ---- 商品卡：横向、左图右信息，白底 + 发丝线 ---- */
.pcard {
  display: flex;
  gap: var(--s3);
  margin: 0 var(--page-x) var(--s3);
  padding: var(--s3);
  background: var(--card);
  border: 1px solid var(--g5);
  border-radius: var(--r-card);
  cursor: pointer;
}

.pcard__thumb {
  flex: 0 0 auto;
  width: 80px;
  height: 80px;
  border-radius: var(--r-ctrl);
  overflow: hidden;
  background: var(--g6);
  display: grid;
  place-items: center;
}
.pcard__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.pcard__ph {
  font-size: var(--f2);
  font-weight: 800;
  color: var(--g3);
}

.pcard__body {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.pcard__top {
  display: flex;
  align-items: flex-start;
  gap: var(--s2);
}
.pcard__name {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: var(--f3);
  font-weight: 700;
  line-height: 1.4;
  color: var(--g1);
  /* 名称普遍很长（如「44.6博弈鹰雕单（出反现小金人+金aug或雪隼）不出保1200w…」）→ 折两行 */
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.pcard__div {
  flex: 0 0 auto;
  padding: 0 var(--s1);
  height: 20px;
  line-height: 18px;
  border: 1px solid var(--g4);
  border-radius: var(--r-sm);
  font-size: var(--f6);
  color: var(--g2);
  white-space: nowrap;
}

.pcard__svc {
  margin: var(--s1) 0 0;
  font-size: var(--f5);
  color: var(--g2);
  display: -webkit-box;
  -webkit-line-clamp: 1;
  line-clamp: 1;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.pcard__meta {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--s2);
  margin-top: var(--s2);
  font-size: var(--f6);
  color: var(--g3);
}
.pcard__badge {
  padding: 0 var(--s1);
  height: 20px;
  line-height: 18px;
  border: 1px solid var(--gold);
  border-radius: var(--r-sm);
  color: var(--gold);
  font-weight: 700;
}

.pcard__foot {
  display: flex;
  align-items: baseline;
  gap: var(--s1);
  margin-top: auto;
  padding-top: var(--s2);
}
.pcard__price {
  font-size: var(--f2);
}
.pcard__unit {
  font-size: var(--f6);
  color: var(--g3);
}
.pcard__btn {
  margin-left: auto;
  align-self: center;
}

/* ---- 加载更多 ---- */
.more {
  padding: var(--s3) var(--page-x) 0;
}
.more__end {
  margin: var(--s2) 0;
  text-align: center;
  font-size: var(--f6);
  color: var(--g3);
}
</style>
