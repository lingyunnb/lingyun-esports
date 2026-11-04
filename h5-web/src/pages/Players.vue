<script setup lang="ts">
/**
 * 找陪玩
 * ---------------------------------------------------------------------------
 * 数据：`GET /public/players?page=&pageSize=`（`publicApi.players`）
 * curl 实测返回（/public/players?page=1&pageSize=20）：
 *   { list:[{ workerId, nickname, intro, avatarMediaId, divisionId }], total, page, pageSize }
 *
 * 🔴 结构规则 6（硬规则，覆盖本页一切"想加点东西"的冲动）：
 *    每行**只有 头像 + 名字 + 介绍**。禁止出现：明星陪玩 / 大神 / 单考 / 双考 / 空闲 / 忙碌 /
 *    等级 / 评分 / 单价 / 下单人数 / 语音时长 / 标签胶囊 / 分部副标。
 *    → 本页**刻意不渲染** `divisionId`（服务端只为筛选而返回），行内不加任何角标、胶囊、副标。
 *
 * 介绍来自 `intro`（管理端填写）；头像是**公开**媒体（真实路由 `/media/public/:id`，
 * **不带** `/api/v1`，见 docs/08）；没有头像就落在字标色块上，**不用 emoji**。
 */
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { publicApi } from '@/api';
import PageHead from '@/components/PageHead.vue';

interface PlayerRow {
  workerId: string;
  nickname: string;
  intro: string;
  avatarMediaId: string | null;
}

const PAGE_SIZE = 20;

const router = useRouter();

/**
 * 点头像 → 护航员信息页（本页**唯一**新增的交互）。
 * 加载逻辑（分页/总数/兜底）一行未动；没有 workerId 的脏数据不跳（点了没反应比跳到空页好）。
 */
function openWorker(workerId: string) {
  if (!workerId) return;
  router.push({ name: 'worker', params: { id: workerId } }).catch(() => {});
}

const list = ref<PlayerRow[]>([]);
const total = ref(0);
const page = ref(1);
const loading = ref(false);
const err = ref('');

const hasMore = computed(() => list.value.length < total.value);

function avatarUrl(id: string): string {
  return `/media/public/${id}`;
}

/** 无头像时的字标（首字母），**不用 emoji** */
function initial(name: string): string {
  const s = name.trim();
  return s ? s.slice(0, 1).toUpperCase() : '陪';
}

/** 兼容两种下发形状：`{list,total,...}`（当前）与裸数组（同一后端其它列表接口的习惯） */
function pick(data: unknown): { rows: PlayerRow[]; total: number } {
  const d = (data ?? {}) as Record<string, unknown>;
  const raw = (Array.isArray(d) ? d : (d.list as unknown[] | undefined)) ?? [];
  const rows = (raw as Record<string, unknown>[]).map((r) => ({
    workerId: String(r.workerId ?? ''),
    nickname: String(r.nickname ?? ''),
    intro: String(r.intro ?? ''),
    avatarMediaId: r.avatarMediaId == null || r.avatarMediaId === '' ? null : String(r.avatarMediaId),
  }));
  const t = Number(d.total);
  return { rows, total: Number.isFinite(t) ? t : rows.length };
}

async function load(reset = false) {
  if (loading.value) return;
  loading.value = true;
  err.value = '';
  if (reset) page.value = 1;
  try {
    const res = await publicApi.players({ page: page.value, pageSize: PAGE_SIZE });
    const { rows, total: t } = pick(res);
    list.value = reset ? rows : [...list.value, ...rows];
    total.value = t;
    // 满页才认为还有下一页；不满页直接收口（省掉一次必然为空的请求）
    if (rows.length === PAGE_SIZE) page.value += 1;
    else total.value = list.value.length;
  } catch (e) {
    err.value = e instanceof Error ? e.message : '加载失败';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  void load(true);
});
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="找陪玩" />

    <!-- 加载骨架（shimmer 由 tokens 的 h5pulse 提供） -->
    <ul v-if="loading && !list.length" class="pl-list">
      <li v-for="n in 4" :key="n" class="h5-row">
        <span class="h5-skel pl-av-skel" />
        <div class="h5-row__main">
          <span class="h5-skel pl-bar pl-bar--name" />
          <span class="h5-skel pl-bar pl-bar--intro" />
        </div>
      </li>
    </ul>

    <ul v-else-if="list.length" class="pl-list">
      <li v-for="p in list" :key="p.workerId" class="h5-row">
        <button
          class="pl-av-btn"
          type="button"
          :aria-label="`查看${p.nickname}的信息`"
          @click="openWorker(p.workerId)"
        >
          <img
            v-if="p.avatarMediaId"
            class="pl-av"
            :src="avatarUrl(p.avatarMediaId)"
            :alt="p.nickname"
            loading="lazy"
          />
          <span v-else class="pl-av pl-av--txt" aria-hidden="true">{{ initial(p.nickname) }}</span>
        </button>

        <div class="h5-row__main">
          <div class="pl-name">{{ p.nickname }}</div>
          <p v-if="p.intro" class="pl-intro">{{ p.intro }}</p>
        </div>
      </li>
    </ul>

    <div v-else-if="err" class="pl-state">
      <p class="h5-empty">{{ err }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" @click="load(true)">重试</button>
    </div>

    <div v-else class="h5-empty">暂时没有可接单的陪玩</div>

    <div v-if="hasMore" class="pl-more">
      <button class="h5-btn h5-btn--ghost h5-btn--sm" :disabled="loading" @click="load()">
        {{ loading ? '加载中…' : '加载更多' }}
      </button>
    </div>
  </div>
</template>

<style scoped>
/* 列表用发丝线（tokens 的 .h5-row），不铺卡片、不铺阴影 */
.pl-list {
  margin: 0;
  padding: 0;
  list-style: none;
  background: var(--card);
}

/* 头像 48：与 --h-row 同档，落在 4dp 网格上 */
.pl-av {
  flex: 0 0 auto;
  width: 48px;
  height: 48px;
  border-radius: var(--r-pill);
  object-fit: cover;
  background: var(--g6);
}

/* 头像即入口：按钮重置成"只有头像"的样子（不加边框/底色，不改本页极简形态） */
.pl-av-btn {
  flex: 0 0 auto;
  display: block;
  padding: 0;
  border: 0;
  background: none;
  border-radius: var(--r-pill);
  cursor: pointer;
}

/* 无头像 → 字标色块（浅主色底 + 主色字，仍是"白底为主"的浅底） */
.pl-av--txt {
  display: grid;
  place-items: center;
  background: var(--pri-soft);
  color: var(--pri);
  font-size: var(--f3);
  font-weight: 700;
}

.pl-name {
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
  line-height: 1.4;
}

.pl-intro {
  margin: var(--s1) 0 0;
  font-size: var(--f5);
  color: var(--g2);
  line-height: 1.5;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

/* 骨架 */
.pl-av-skel {
  flex: 0 0 auto;
  width: 48px;
  height: 48px;
  border-radius: var(--r-pill);
}
.pl-bar {
  display: block;
  border-radius: var(--r-sm);
}
.pl-bar--name {
  width: 96px;
  height: 12px;
  margin-bottom: var(--s2);
}
.pl-bar--intro {
  width: 60%;
  height: 8px;
}

.pl-more {
  padding: var(--s4) var(--page-x);
  display: flex;
  justify-content: center;
}

/* 错误态：文字居中 + 重试按钮（按钮宽度由 --sm 收窄） */
.pl-state {
  display: grid;
  justify-items: center;
}
.pl-state .h5-empty {
  padding-bottom: var(--s2);
}
</style>
