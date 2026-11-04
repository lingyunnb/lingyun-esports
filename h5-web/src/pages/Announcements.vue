<script setup lang="ts">
/**
 * 消息 · 公告（列表）
 * ---------------------------------------------------------------------------
 * 数据：`GET /public/announcements`（`publicApi.announcements`）
 * curl 实测返回 —— ⚠️ 服务端**忽略分页参数**，`data` 是**裸数组**（不是 `{list,total}`）：
 *   [{ id, title, summary, pinned, createdAt }]   （不含正文）
 * 排序：置顶优先 + 发布时间倒序（服务端已排；这里再排一次做兜底，顺序不吃服务端实现细节）。
 *
 * 本页是底栏「消息」格的落点 → 页头写「消息 · 公告」，行内只给 标题 + 时间 + 摘要。
 */
import { onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { publicApi } from '@/api';
import { fmtTime } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

interface AnnouncementRow {
  id: string;
  title: string;
  summary: string;
  pinned: number;
  createdAt: string;
}

const router = useRouter();
const list = ref<AnnouncementRow[]>([]);
const loading = ref(true);
const err = ref('');

function pick(data: unknown): AnnouncementRow[] {
  const d = (data ?? {}) as Record<string, unknown>;
  const raw = ((Array.isArray(d) ? d : d.list) ?? []) as Record<string, unknown>[];
  const rows = raw.map((r) => ({
    id: String(r.id ?? ''),
    title: String(r.title ?? ''),
    summary: String(r.summary ?? ''),
    pinned: Number(r.pinned ?? 0),
    createdAt: String(r.createdAt ?? ''),
  }));
  // 置顶优先 → 时间倒序（同毫秒用 id 倒序，保证排序稳定）
  return rows.sort(
    (a, b) =>
      b.pinned - a.pinned ||
      new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime() ||
      Number(b.id) - Number(a.id),
  );
}

async function load() {
  loading.value = true;
  err.value = '';
  try {
    list.value = pick(await publicApi.announcements(1, 50));
  } catch (e) {
    err.value = e instanceof Error ? e.message : '加载失败';
  } finally {
    loading.value = false;
  }
}

function open(id: string) {
  void router.push({ name: 'announcement', params: { id } });
}

onMounted(() => {
  void load();
});
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="消息 · 公告" />

    <ul v-if="loading" class="an-list">
      <li v-for="n in 4" :key="n" class="h5-row h5-row--col">
        <span class="h5-skel an-bar an-bar--title" />
        <span class="h5-skel an-bar an-bar--sum" />
      </li>
    </ul>

    <ul v-else-if="list.length" class="an-list">
      <li v-for="a in list" :key="a.id" class="h5-row an-item" @click="open(a.id)">
        <div class="h5-row__main">
          <div class="an-top">
            <h2 class="an-title">{{ a.title }}</h2>
            <time class="an-time">{{ fmtTime(a.createdAt) }}</time>
          </div>
          <p v-if="a.summary" class="an-sum">{{ a.summary }}</p>
        </div>
      </li>
    </ul>

    <div v-else-if="err" class="an-state">
      <p class="h5-empty">{{ err }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" @click="load()">重试</button>
    </div>

    <div v-else class="h5-empty">暂时没有公告</div>
  </div>
</template>

<style scoped>
/* 列表用发丝线（tokens 的 .h5-row），不铺卡片、不铺阴影 */
.an-list {
  margin: 0;
  padding: 0;
  list-style: none;
  background: var(--card);
}

.an-item {
  cursor: pointer;
}
.an-item:active {
  background: var(--g6);
}

.an-top {
  display: flex;
  align-items: baseline;
  gap: var(--s3);
}

.an-title {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
  line-height: 1.45;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.an-time {
  flex: 0 0 auto;
  font-size: var(--f5);
  color: var(--g3);
  font-variant-numeric: tabular-nums;
}

.an-sum {
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
.h5-row--col {
  display: block;
}
.an-bar {
  display: block;
  border-radius: var(--r-sm);
}
.an-bar--title {
  width: 70%;
  height: 12px;
  margin-bottom: var(--s2);
}
.an-bar--sum {
  width: 45%;
  height: 8px;
}

.an-state {
  display: grid;
  justify-items: center;
}
.an-state .h5-empty {
  padding-bottom: var(--s2);
}
</style>
