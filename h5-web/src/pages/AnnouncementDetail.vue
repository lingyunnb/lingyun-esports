<script setup lang="ts">
/**
 * 公告详情
 * ---------------------------------------------------------------------------
 * 数据：`GET /public/announcements/:id`（`publicApi.announcement`）
 * curl 实测返回（/public/announcements/136）：
 *   { id, title, summary, content, pinned, createdAt }
 *   `content` 实测是**纯文本**（换行用 `\n\n` 表达段落）→ 走 `white-space: pre-wrap` 分支。
 *
 * 正文形态**不写死**：管理端若改为富文本（含 `<p>` 等标签），这里自动切到 `v-html`。
 * 内容来自自家后端（`/public/announcements` 由管理端维护），可直接渲染。
 */
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { publicApi } from '@/api';
import { fmtTime } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

interface Announcement {
  title: string;
  content: string;
  createdAt: string;
}

const route = useRoute();
const data = ref<Announcement | null>(null);
const loading = ref(true);
const err = ref('');

/** 有真标签才算 HTML：纯文本里的 `<` 或 `a < b` 不会误判 */
const isHtml = computed(() => /<[a-z][a-z0-9]*(\s[^>]*)?>/i.test(data.value?.content ?? ''));

async function load() {
  const id = String(route.params.id ?? '');
  if (!id) {
    err.value = '公告不存在';
    loading.value = false;
    return;
  }
  loading.value = true;
  err.value = '';
  try {
    const res = (await publicApi.announcement(id)) as Record<string, unknown>;
    data.value = {
      title: String(res?.title ?? ''),
      content: String(res?.content ?? ''),
      createdAt: String(res?.createdAt ?? ''),
    };
  } catch (e) {
    data.value = null;
    err.value = e instanceof Error ? e.message : '加载失败';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  void load();
});

// 详情页可能在列表内被反复点开（同一组件复用）→ 跟随 id 变化重新取
watch(() => route.params.id, () => void load());
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="公告" />

    <div v-if="loading" class="h5-card ad-card">
      <span class="h5-skel ad-bar ad-bar--t" />
      <span class="h5-skel ad-bar ad-bar--d" />
      <span v-for="n in 5" :key="n" class="h5-skel ad-bar ad-bar--b" />
    </div>

    <div v-else-if="data" class="h5-card ad-card">
      <h1 class="ad-title">{{ data.title }}</h1>
      <time class="ad-time">{{ fmtTime(data.createdAt) }}</time>

      <!-- 正文：HTML 走 v-html；纯文本走 pre-wrap（保留管理端填写的换行） -->
      <div v-if="isHtml" class="ad-body ad-body--html" v-html="data.content"></div>
      <p v-else class="ad-body">{{ data.content }}</p>
    </div>

    <div v-else class="ad-state">
      <p class="h5-empty">{{ err || '公告不存在' }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" @click="load()">重试</button>
    </div>
  </div>
</template>

<style scoped>
.ad-card {
  margin-top: var(--s3);
}

.ad-title {
  margin: 0;
  font-size: var(--f2);
  font-weight: 800;
  color: var(--g1);
  line-height: 1.45;
}

.ad-time {
  display: block;
  margin-top: var(--s2);
  font-size: var(--f5);
  color: var(--g3);
  font-variant-numeric: tabular-nums;
}

/* 正文：15px / 1.8 行高（长文阅读的下限），段间用 pre-wrap 的换行而非 margin */
.ad-body {
  margin: var(--s4) 0 0;
  padding-top: var(--s4);
  border-top: 1px solid var(--g5);
  font-size: var(--f3);
  color: var(--g1);
  line-height: 1.8;
  white-space: pre-wrap;
  word-break: break-word;
}

/* 富文本分支：恢复常规排版，让标签自己决定换行 */
.ad-body--html {
  white-space: normal;
}
.ad-body--html :deep(p) {
  margin: 0 0 var(--s4);
}
.ad-body--html :deep(img) {
  max-width: 100%;
  border-radius: var(--r-sm);
}
.ad-body--html :deep(a) {
  color: var(--pri);
}
.ad-body--html :deep(h1),
.ad-body--html :deep(h2),
.ad-body--html :deep(h3) {
  margin: var(--s5) 0 var(--s2);
  font-size: var(--f3);
  font-weight: 800;
  color: var(--g1);
}
.ad-body--html :deep(ul),
.ad-body--html :deep(ol) {
  margin: 0 0 var(--s4);
  padding-left: var(--s5);
}

/* 骨架 */
.ad-bar {
  display: block;
  border-radius: var(--r-sm);
}
.ad-bar--t {
  width: 60%;
  height: 16px;
  margin-bottom: var(--s3);
}
.ad-bar--d {
  width: 32%;
  height: 8px;
  margin-bottom: var(--s4);
}
.ad-bar--b {
  width: 100%;
  height: 12px;
  margin-bottom: var(--s2);
}

.ad-state {
  display: grid;
  justify-items: center;
}
.ad-state .h5-empty {
  padding-bottom: var(--s2);
}
</style>
