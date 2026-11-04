<script setup lang="ts">
/**
 * 服务（首页 · 网页版 H5）
 * ============================================================================
 * 数据**全部来自真实接口**，形状以实测返回为准（2026-10-15 实打云端口径）：
 *   · `GET /public/home`         → `{ announcements: [{id,title,summary,pinned,createdAt}] }`（**仅公告**）
 *   · `GET /public/banners`      → `[{id,title,subtitle,imageMediaId,imageUrl,linkType,linkValue,...}]`（当前为空数组）
 *   · `GET /divisions/grouped`   → `[{gameId,gameName,platformCount,divisions:[{id,name,shortName,platform,
 *                                   platformLabel,onlineDesc,priceNote,themeColor,coverMediaId,underConstruction,
 *                                   onlineCount}]}]`
 *   · `GET /public/products?page=1&pageSize=1` → `{list,total}`（事实条「在售服务」用 `total`）
 *   · `GET /public/announcements?page=1&pageSize=3` → 公告数组（品牌区副标 / 铃铛角标）
 *
 * 硬约束逐条落地：
 * - **白底为主**：整页白底，品牌色只出现在在线圆点、链接文字、「进入分部 ›」；
 * - **宣传图通栏 · 直角 · 紧贴上一块 0 间距**（负责人 2026-10-14 定案）：
 *   `.home__banner` 无左右内距、无圆角、与品牌区之间无任何间隙（品牌区底距 = 0）；
 * - **间距只用 4dp 网格**（4/8/12/16/20/24/32/48/64）·**颜色零硬编码**（全 token）；
 * - **事实条只用接口真值**：在线数 = `divisions[].onlineCount` 求和（与 App 服务页 `_headline` 同口径）；
 *   `productsTotal` = `/public/products` 的 `total`；取不到时**整段不渲染**，绝不编数字；
 * - 底部导航由外壳 `App.vue` 提供，本页不画底栏（`meta.tab` 已让外壳显示）。
 */
import { computed, onMounted, reactive, ref } from 'vue';
import { useRouter } from 'vue-router';
import { divisionApi, publicApi } from '@/api';
// 本页额外用到的两条路径不在 `api/index.ts` 里（**不去改那个文件**，避免与并行开发冲突）：
//   · `GET /public/products?page=1&pageSize=1`  —— 取 `total` 作事实条「在售服务」的真值
//   · `GET /public/announcements?page=1&pageSize=3` —— 品牌区副标 / 铃铛角标
import { request } from '@/api/client';
import { fmtTime } from '@/utils/format';

/* ---------------- 接口形状（宽松；以服务端返回为准） ---------------- */

interface HomeAnnouncement {
  id: string;
  title: string;
  summary?: string;
  pinned?: number;
  createdAt?: string;
}

interface BannerItem {
  id: string;
  title?: string;
  subtitle?: string;
  imageMediaId?: string | number | null;
  imageUrl?: string;
  linkType?: string;
  linkValue?: string;
}

interface DivisionItem {
  id: string;
  name: string;
  shortName?: string;
  platform?: string;
  platformLabel?: string;
  onlineDesc?: string;
  priceNote?: string;
  themeColor?: string;
  iconMediaId?: string | number | null;
  coverMediaId?: string | number | null;
  underConstruction?: boolean;
  onlineCount?: number;
}

interface DivisionGroup {
  gameId: string;
  gameName: string;
  platformCount?: number;
  divisions: DivisionItem[];
}

/* ---------------- 状态 ---------------- */

const router = useRouter();

const loading = ref(true);
const errMsg = ref('');
const home = reactive<{ announcements: HomeAnnouncement[] }>({ announcements: [] });
const banners = ref<BannerItem[]>([]);
const groups = ref<DivisionGroup[]>([]);
/** 在售服务总数（取不到保持 null → 事实条该段不渲染） */
const productsTotal = ref<number | null>(null);

/** 平铺后的分部（展示顺序与接口一致：`/divisions/grouped` 已按 sortOrder 排好） */
const divisions = computed<DivisionItem[]>(() => groups.value.flatMap((g) => g.divisions ?? []));

/** 真实在线数：与 App 服务页同一口径（各分部 `onlineCount` 求和，建设中不计） */
const onlineCount = computed(() =>
  divisions.value.reduce((sum, d) => sum + (d.underConstruction ? 0 : Number(d.onlineCount) || 0), 0),
);

/** 欢迎语（与 App 服务页逐字一致的原文，负责人 2026-10-04 指定） */
const HEADLINE = '欢迎各位板板来到祁连山电竞 祝各位板板玩的快乐 玩的开心 ——祁连山电竞董事长 凌云';

/** 宣传图高度：16:7 通栏（运营图按横版投放；CSS 定高，`object-fit: cover` 裁切） */
const bannerH = 'calc(100vw * 7 / 16)';

const latestAnnouncement = computed<HomeAnnouncement | null>(() => home.announcements[0] ?? null);

/* ---------------- 宣传图 ---------------- */

/** 图片地址：优先 `imageMediaId`（走公开媒体通道 `/media/public/:id`），其次历史外链 `imageUrl` */
function bannerUrl(b: BannerItem): string {
  const mid = b.imageMediaId;
  if (mid !== null && mid !== undefined && String(mid) !== '') return `/media/public/${mid}`;
  return b.imageUrl || '';
}
const hasImage = (b: BannerItem) => bannerUrl(b) !== '';

/** 图挂了就退回文字块（避免留一条白缝；按索引记，同一张图不会反复触发） */
const imgFailed = reactive(new Set<number>());
function onImgError(i: number) {
  imgFailed.add(i);
}

/* ---------------- 轮播 ---------------- */

const bannerIndex = ref(0);
/** 指示点只在 2 张以上出现（1 张时点没有意义，属"不存在的东西不出现"） */
const showDots = computed(() => banners.value.length > 1);

function onBannerClick(b: BannerItem) {
  const v = String(b.linkValue ?? '');
  switch (b.linkType) {
    case 'product':
      if (v) router.push({ name: 'product', params: { id: v } }).catch(() => {});
      break;
    case 'division':
      if (v) router.push({ name: 'products', query: { divisionId: v } }).catch(() => {});
      break;
    case 'announcement':
      if (v) router.push({ name: 'announcement', params: { id: v } }).catch(() => {});
      break;
    // `none` / `url` / 历史值 `tab`：H5 无历史 tab 体系、外链不在本期 → 与 App 同口径，什么都不做
    default:
      break;
  }
}

/* ---------------- 跳转 ---------------- */

function goAnnouncements() {
  router.push({ name: 'announcements' }).catch(() => {});
}
function goDivision(d: DivisionItem) {
  router.push({ name: 'products', query: { divisionId: d.id } }).catch(() => {});
}

/* ---------------- 取数 ---------------- */

/** 单条失败不拖垮整页：`allSettled` + 记下失败项，页面照常渲染能拿到的部分 */
async function load() {
  loading.value = true;
  errMsg.value = '';
  const results = await Promise.allSettled([
    publicApi.home(),
    publicApi.banners(),
    divisionApi.grouped(),
    request<{ list: unknown[]; total?: number }>('GET', '/public/products', undefined, {
      query: { page: 1, pageSize: 1 },
      anonymous: true,
    }),
    request<HomeAnnouncement[]>('GET', '/public/announcements', undefined, {
      query: { page: 1, pageSize: 3 },
      anonymous: true,
    }),
  ]);

  const [rHome, rBanners, rDiv, rProducts, rAnn] = results;

  if (rHome.status === 'fulfilled') {
    const d = rHome.value as unknown as { announcements?: HomeAnnouncement[] };
    home.announcements = Array.isArray(d?.announcements) ? d.announcements : [];
  }
  if (rBanners.status === 'fulfilled') {
    banners.value = (Array.isArray(rBanners.value) ? rBanners.value : []) as BannerItem[];
    bannerIndex.value = 0;
    imgFailed.clear();
  }
  if (rDiv.status === 'fulfilled') {
    const d = rDiv.value as unknown as DivisionGroup[] | { list?: DivisionGroup[] };
    groups.value = Array.isArray(d) ? d : (d?.list ?? []);
  }
  if (rProducts.status === 'fulfilled') {
    const t = rProducts.value?.total;
    productsTotal.value = typeof t === 'number' ? t : null;
  }
  if (rAnn.status === 'fulfilled' && home.announcements.length === 0) {
    home.announcements = Array.isArray(rAnn.value) ? (rAnn.value as HomeAnnouncement[]) : [];
  }

  // 三块主内容全挂 → 给一条可重试的失败说明（与 App 服务页 `_errorCard` 同语义）
  if (rHome.status === 'rejected' && rDiv.status === 'rejected' && rBanners.status === 'rejected') {
    const e = rDiv.reason as Error | undefined;
    errMsg.value = (e && e.message) || '内容加载失败，请重试';
  }
  loading.value = false;
}

onMounted(load);
</script>

<template>
  <div class="home h5-page">
    <!-- ① 品牌区：字标块 + 昵称/欢迎语 + 公告铃铛。底距 0 → 宣传图紧贴其上 -->
    <header class="home__brand">
      <div class="home__row">
        <div class="home__mark" aria-hidden="true">祁</div>
        <div class="home__id">
          <strong class="home__name">祁连山电竞</strong>
          <span class="home__sub">{{ latestAnnouncement?.title || '官方自营陪玩平台' }}</span>
        </div>
        <button class="home__bell" type="button" aria-label="公告" @click="goAnnouncements">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M18 15v-4a6 6 0 1 0-12 0v4l-2 3h16l-2-3Z" stroke-linecap="round" stroke-linejoin="round" />
            <path d="M10 20a2 2 0 0 0 4 0" stroke-linecap="round" />
          </svg>
          <i v-if="latestAnnouncement" class="home__dot" />
        </button>
      </div>
      <p class="home__headline">{{ HEADLINE }}</p>
    </header>

    <!-- ② 宣传图轮播：通栏 · 直角 · 紧贴品牌区（0 间距）。空数组时不占位 -->
    <section v-if="banners.length" class="home__banner">
      <van-swipe
        :autoplay="banners.length > 1 ? 4000 : 0"
        :loop="banners.length > 1"
        :show-indicators="false"
        :duration="400"
        :height="bannerH"
        @change="(i: number) => (bannerIndex = i)"
      >
        <van-swipe-item v-for="(b, i) in banners" :key="i">
          <button class="home__slide" type="button" @click="onBannerClick(b)">
            <img
              v-if="hasImage(b) && !imgFailed.has(i)"
              :src="bannerUrl(b)"
              :alt="b.title || '宣传图'"
              @error="onImgError(i)"
            />
            <span v-else class="home__slide-fallback">{{ b.title || '祁连山电竞' }}</span>
          </button>
        </van-swipe-item>
      </van-swipe>
      <div v-if="showDots" class="home__dots" aria-hidden="true">
        <i v-for="(b, i) in banners" :key="i" :class="{ 'is-on': i === bannerIndex }" />
      </div>
    </section>

    <!-- ③ 事实条：**只用接口真值**（在线数 / 在售服务 / 分部数）；一个数字都取不到就整条不渲染 -->
    <section v-if="onlineCount > 0 || productsTotal !== null || divisions.length > 0" class="home__facts">
      <span v-if="onlineCount > 0" class="home__fact">{{ onlineCount }} 位在线</span>
      <template v-if="productsTotal !== null">
        <i class="home__sep" />
        <span class="home__fact">{{ productsTotal }} 个在售服务</span>
      </template>
      <template v-if="divisions.length > 0">
        <i class="home__sep" />
        <span class="home__fact">{{ divisions.length }} 个分部</span>
      </template>
    </section>

    <!-- ④ 分部列表 → 点击进商品列表（带 divisionId） -->
    <div class="h5-sec home__sechead">
      <span class="h5-sec__t">选择分部</span>
      <span v-if="loading" class="h5-sec__x">加载中…</span>
    </div>

    <template v-if="loading && divisions.length === 0">
      <div class="home__skel h5-skel" />
      <div class="home__skel h5-skel" />
    </template>

    <div v-else-if="errMsg" class="home__err">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
      <span>{{ errMsg }}</span>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" type="button" @click="load">重试</button>
    </div>

    <div v-else-if="divisions.length === 0" class="h5-empty">暂未开放分部，请稍后再来</div>

    <ul v-else class="home__list">
      <li v-for="d in divisions" :key="d.id">
        <button class="home__div" type="button" @click="goDivision(d)">
          <img
            v-if="d.coverMediaId || d.iconMediaId"
            class="home__divicon"
            :src="`/media/public/${d.coverMediaId || d.iconMediaId}`"
            :alt="(d.shortName || d.name || '').trim()"
          />
          <span v-else class="home__divicon home__divicon--ph">{{ (d.shortName || d.name || '').trim().slice(0, 1) }}</span>

          <span class="home__divmain">
            <span class="home__divtitle">
              <strong>{{ (d.shortName || d.name || '').trim() }}</strong>
              <em v-if="d.platformLabel" class="home__tag">{{ d.platformLabel }}</em>
              <em v-if="d.underConstruction" class="home__tag home__tag--off">建设中</em>
            </span>
            <span v-if="d.underConstruction" class="home__divmeta">敬请期待</span>
            <span v-else class="home__divmeta">
              <i class="home__live" />
              {{ Number(d.onlineCount) || 0 }} 人在线 · {{ d.onlineDesc || '详情见下单页' }}
            </span>
          </span>

          <span class="home__divgo">{{ d.underConstruction ? '查看详情 ›' : '进入分部 ›' }}</span>
        </button>
      </li>
    </ul>

    <!-- ⑤ 保障说明（与 App 服务页逐字一致） -->
    <p class="home__foot">先服务后结算 · 不满意可申诉 · 余额由平台发放</p>
    <p v-if="latestAnnouncement" class="home__foot home__foot--dim">公告更新于 {{ fmtTime(latestAnnouncement.createdAt) }}</p>
  </div>
</template>

<style scoped>
.home { background: var(--card); }

/* ---------- ① 品牌区 ---------- */
.home__brand {
  padding: var(--s3) var(--page-x) 0;
  padding-top: calc(var(--s3) + var(--safe-top));
}
.home__row { display: flex; align-items: center; gap: var(--s3); }
.home__mark {
  flex: 0 0 auto; width: 40px; height: 40px;
  border-radius: var(--r-ctrl);
  background: var(--brand-ink); color: var(--card);
  display: grid; place-items: center;
  font-size: var(--f2); font-weight: 800; line-height: 1;
}
.home__id { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--s1); }
.home__name { font-size: var(--f3); font-weight: 800; color: var(--g1); }
.home__sub {
  font-size: var(--f6); color: var(--g3);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.home__bell {
  position: relative; flex: 0 0 auto;
  width: 40px; height: 40px; display: grid; place-items: center;
  background: none; border: 0; padding: 0; color: var(--g2); cursor: pointer;
}
.home__dot {
  position: absolute; top: 8px; right: 8px;
  width: 6px; height: 6px; border-radius: var(--r-pill); background: var(--danger);
}
.home__headline {
  margin: var(--s2) 0 0;
  font-size: var(--f6); line-height: 1.6;
  color: var(--g3); text-align: left;
}

/* ---------- ② 宣传图：通栏 · 直角 · 紧贴上一块（0 间距：无 margin、无 padding、无圆角） ---------- */
.home__banner { position: relative; margin: 0; padding: 0; }
.home__slide {
  display: block; width: 100%; height: 100%;
  padding: 0; border: 0; background: var(--g6); cursor: pointer;
}
.home__slide img { width: 100%; height: 100%; object-fit: cover; }
.home__slide-fallback {
  display: grid; place-items: center; width: 100%; height: 100%;
  font-size: var(--f3); font-weight: 700; color: var(--g2);
}
.home__dots {
  position: absolute; left: 0; right: 0; bottom: var(--s2);
  display: flex; justify-content: center; gap: var(--s1);
}
.home__dots i {
  width: 6px; height: 6px; border-radius: var(--r-pill);
  background: var(--g4); opacity: .9;
}
.home__dots i.is-on { background: var(--pri); width: 16px; }

/* ---------- ③ 事实条 ---------- */
.home__facts {
  display: flex; align-items: center; flex-wrap: wrap; gap: var(--s2);
  padding: var(--s3) var(--page-x) 0;
}
.home__fact { font-size: var(--f5); color: var(--g2); font-variant-numeric: tabular-nums; }
.home__sep { width: 1px; height: 12px; background: var(--g4); }

/* ---------- ④ 分部列表 ---------- */
.home__sechead { margin-top: var(--s5); margin-bottom: var(--s2); }
.home__list { list-style: none; margin: 0; padding: 0 var(--page-x); display: flex; flex-direction: column; gap: var(--s3); }
.home__div {
  display: flex; align-items: center; gap: var(--s3); width: 100%; text-align: left;
  padding: var(--s3); background: var(--card);
  border: 1px solid var(--g4); border-radius: var(--r-card);
  cursor: pointer;
}
.home__div:active { background: var(--g6); }
.home__divicon {
  flex: 0 0 auto; width: 40px; height: 40px;
  border-radius: var(--r-ctrl); object-fit: cover; background: var(--g5);
}
.home__divicon--ph {
  display: grid; place-items: center;
  font-size: var(--f3); font-weight: 800; color: var(--g2);
}
.home__divmain { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--s1); }
.home__divtitle { display: flex; align-items: center; gap: var(--s2); min-width: 0; }
.home__divtitle strong {
  font-size: var(--f3); font-weight: 800; color: var(--g1);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.home__tag {
  flex: 0 0 auto; font-style: normal; font-size: var(--f6); font-weight: 600;
  padding: 0 var(--s1); height: 20px; line-height: 20px;
  border-radius: var(--r-sm); border: 1px solid var(--g4);
  color: var(--g2); background: var(--card);
}
.home__tag--off { color: var(--g3); }
.home__divmeta {
  display: flex; align-items: center; gap: var(--s1);
  font-size: var(--f6); color: var(--g3);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.home__live { width: 6px; height: 6px; border-radius: var(--r-pill); background: var(--celadon); flex: 0 0 auto; }
.home__divgo { flex: 0 0 auto; font-size: var(--f5); font-weight: 700; color: var(--pri); }

/* ---------- 失败 / 骨架 ---------- */
.home__skel { height: 72px; margin: 0 var(--page-x) var(--s3); }
.home__err {
  display: flex; align-items: center; gap: var(--s2);
  margin: 0 var(--page-x); padding: var(--s3);
  border: 1px solid var(--g4); border-radius: var(--r-card);
  font-size: var(--f4); color: var(--g2);
}
.home__err svg { flex: 0 0 auto; color: var(--warn); }
.home__err span { flex: 1 1 auto; min-width: 0; }

/* ---------- ⑤ 保障说明 ---------- */
.home__foot {
  margin: var(--s5) var(--page-x) 0;
  font-size: var(--f6); color: var(--g3);
}
.home__foot--dim { margin-top: var(--s1); }
</style>
