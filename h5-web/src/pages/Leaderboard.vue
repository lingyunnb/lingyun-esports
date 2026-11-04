<script setup lang="ts">
/**
 * 排行榜（老板端）
 * ---------------------------------------------------------------------------
 * 数据：`GET /public/leaderboard?kind=week|month&divisionId=`
 *   ⚠️ 参数名**以服务端为准**（`public-leaderboard.controller.ts` 实测）：
 *   - `kind=week|month`（不是 `type`；`period` 也可传，缺省=当前周期，见 `currentPeriod()`）
 *   - `divisionId` 传分部 id 取**分部榜**，**不传 = 全站榜**（服务端 `division_id IS NULL`）
 * curl 实测返回（/public/leaderboard?kind=month&divisionId=1）：
 *   { period:"2026-10", divisionId:"1", list:[
 *     { rank:1, nickname:"演示工作端", workerNo:"W001", completedOrders:21, amount:377 }, … ] }
 *   ⚠️ 公开行**只有** rank/nickname/workerNo/completedOrders/amount —— **没有 workerId、没有头像字段**；
 *   服务端注释明确「头像由客户端用昵称首字生成」→ 本页就按首字母字标渲染，**不再跨接口取头像**。
 *   数值取 `amount`（= 服务端 `effectiveAmount`：totalAmount + 人工调整，也是名次依据）。
 *
 * 🔴 硬规则：每行只有 **名次 + 头像 + 名字 + 数值**；
 *    **分部不写进每行**（由上方胶囊决定）；不做奖杯插画、不做并排三个大数字；**没有「我的排名」**。
 */
import { computed, onMounted, ref } from 'vue';
import { divisionApi, publicApi } from '@/api';
import { fmtMoney } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

interface BoardRow {
  rank: number;
  nickname: string;
  amount: number;
}

interface DivisionOpt {
  id: string;
  label: string;
}

const kind = ref<'week' | 'month'>('week');
const divisionId = ref(''); // '' = 全站榜
const divisions = ref<DivisionOpt[]>([]);
const rows = ref<BoardRow[]>([]);
const period = ref('');
const loading = ref(false);
const err = ref('');

const curLabel = computed(() => (kind.value === 'month' ? '月榜' : '周榜'));
const emptyText = computed(() => {
  const scope = divisionId.value
    ? divisions.value.find((d) => d.id === divisionId.value)?.label || '该分部'
    : '全站';
  return `${scope}${kind.value === 'month' ? '本月' : '本周'}还没有接单记录`;
});
const footNote = computed(() =>
  kind.value === 'month' ? '每月 1 日 03:00 重新统计 · 完成订单即可上榜' : '每周一 03:00 重新统计 · 完成订单即可上榜',
);

function initial(name: string): string {
  const s = name.trim();
  return s ? s.slice(0, 1).toUpperCase() : '陪';
}

function rankCls(rank: number): string {
  if (rank === 1) return 'lb-rank--1';
  if (rank === 2) return 'lb-rank--2';
  if (rank === 3) return 'lb-rank--3';
  return 'lb-rank--n';
}

/** 分部选项：`platformCount > 1` 才把平台带进标签（和平精英只有手游 → 不出现"端游"这种不存在的选项） */
async function loadDivisions() {
  try {
    const res = await divisionApi.grouped();
    const groups = ((Array.isArray(res) ? res : (res as Record<string, unknown>)?.list) ?? []) as Record<
      string,
      unknown
    >[];
    const out: DivisionOpt[] = [];
    for (const g of groups) {
      const pc = Number(g.platformCount ?? 1);
      const gameName = String(g.gameName ?? '');
      const ds = (g.divisions as Record<string, unknown>[] | undefined) ?? [];
      for (const d of ds) {
        const platformLabel = String(d.platformLabel ?? '');
        const label =
          pc > 1 && platformLabel ? `${gameName}·${platformLabel}` : String(d.shortName || d.name || '').trim() || gameName;
        out.push({ id: String(d.id), label });
      }
    }
    divisions.value = out;
  } catch {
    /* 分部拉不到不阻塞榜单：只剩「全站」一个选项 */
  }
}

async function load() {
  loading.value = true;
  err.value = '';
  try {
    const res = await publicApi.leaderboard({
      kind: kind.value,
      ...(divisionId.value ? { divisionId: divisionId.value } : {}),
    });
    const d = (res ?? {}) as Record<string, unknown>;
    period.value = String(d.period ?? '');
    const raw = ((Array.isArray(d) ? d : d.list) ?? []) as Record<string, unknown>[];
    rows.value = raw.map((r) => ({
      rank: Number(r.rank ?? 0),
      nickname: String(r.nickname ?? ''),
      // 名次依据 = amount（服务端 effectiveAmount：totalAmount + 人工调整）
      amount: Number(r.amount ?? 0),
    }));
  } catch (e) {
    err.value = e instanceof Error ? e.message : '加载失败';
  } finally {
    loading.value = false;
  }
}

function setKind(k: 'week' | 'month') {
  if (kind.value === k) return;
  kind.value = k;
  void load();
}

function setDivision(id: string) {
  if (divisionId.value === id) return;
  divisionId.value = id;
  void load();
}

onMounted(() => {
  void loadDivisions();
  void load();
});
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="排行榜" />

    <!-- 周期分段控件（周榜 / 月榜）-->
    <div class="lb-seg">
      <button class="lb-seg__i" :class="{ 'lb-seg__i--on': kind === 'week' }" @click="setKind('week')">周榜</button>
      <button class="lb-seg__i" :class="{ 'lb-seg__i--on': kind === 'month' }" @click="setKind('month')">月榜</button>
    </div>

    <!-- 分部胶囊（「全站」+ 各分部；分部的归属只在**这里**决定，不写进任何一行） -->
    <div class="lb-chips">
      <button class="lb-chip" :class="{ 'lb-chip--on': divisionId === '' }" @click="setDivision('')">全站</button>
      <button
        v-for="d in divisions"
        :key="d.id"
        class="lb-chip"
        :class="{ 'lb-chip--on': divisionId === d.id }"
        @click="setDivision(d.id)"
      >
        {{ d.label }}
      </button>
    </div>

    <div class="lb-cap">
      <span>按已完成订单金额（{{ curLabel }}）</span>
      <span v-if="period" class="lb-cap__p">{{ period }}</span>
    </div>

    <ul v-if="loading && !rows.length" class="lb-list">
      <li v-for="n in 4" :key="n" class="h5-row">
        <span class="h5-skel lb-rank-skel" />
        <span class="h5-skel lb-av-skel" />
        <div class="h5-row__main"><span class="h5-skel lb-bar" /></div>
      </li>
    </ul>

    <ul v-else-if="rows.length" class="lb-list">
      <li v-for="r in rows" :key="r.rank" class="h5-row">
        <span class="lb-rank" :class="rankCls(r.rank)">{{ r.rank }}</span>

        <span class="lb-av lb-av--txt" aria-hidden="true">{{ initial(r.nickname) }}</span>

        <div class="h5-row__main">
          <span class="lb-name">{{ r.nickname }}</span>
        </div>

        <span class="h5-price lb-val"><span class="h5-price__sym">¥</span>{{ fmtMoney(r.amount) }}</span>
      </li>
    </ul>

    <div v-else-if="err" class="lb-state">
      <p class="h5-empty">{{ err }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm" @click="load()">重试</button>
    </div>

    <div v-else class="h5-empty">{{ emptyText }}</div>

    <p class="lb-foot">{{ footNote }}</p>
    <p v-if="period && rows.length" class="lb-foot">统计周期 {{ period }}</p>
  </div>
</template>

<style scoped>
/* 分段控件：浅灰底槽 + 白底选中（选中态用主色字，不铺大色块） */
.lb-seg {
  display: flex;
  gap: var(--s1);
  margin: var(--s3) var(--page-x) 0;
  padding: var(--s1);
  background: var(--g6);
  border: 1px solid var(--g5);
  border-radius: var(--r-ctrl);
}
.lb-seg__i {
  flex: 1 1 0;
  height: 32px;
  border: 1px solid transparent;
  border-radius: var(--r-sm);
  background: transparent;
  color: var(--g2);
  font-size: var(--f4);
  font-weight: 600;
  cursor: pointer;
}
.lb-seg__i--on {
  background: var(--card);
  border-color: var(--g4);
  color: var(--pri);
  font-weight: 800;
}

/* 分部胶囊：横向滚动，只放得下就一行 */
.lb-chips {
  display: flex;
  gap: var(--s2);
  margin-top: var(--s3);
  padding: 0 var(--page-x);
  overflow-x: auto;
  scrollbar-width: none;
}
.lb-chips::-webkit-scrollbar {
  display: none;
}
.lb-chip {
  flex: 0 0 auto;
  height: 32px;
  padding: 0 var(--s3);
  border: 1px solid var(--g4);
  border-radius: var(--r-pill);
  background: var(--card);
  color: var(--g2);
  font-size: var(--f5);
  font-weight: 600;
  white-space: nowrap;
  cursor: pointer;
}
.lb-chip--on {
  background: var(--pri-soft);
  border-color: var(--pri);
  color: var(--pri);
  font-weight: 800;
}

/* 口径说明行（轻，不抢列表） */
.lb-cap {
  display: flex;
  align-items: center;
  gap: var(--s2);
  margin: var(--s4) var(--page-x) var(--s2);
  font-size: var(--f5);
  color: var(--g3);
}
.lb-cap__p {
  margin-left: auto;
  font-variant-numeric: tabular-nums;
}

.lb-list {
  margin: 0;
  padding: 0;
  list-style: none;
  background: var(--card);
}

/* 名次徽章：前三名实色（1 金 / 2 灰 / 3 琥珀），其余只留序号 */
.lb-rank {
  flex: 0 0 auto;
  width: 24px;
  height: 24px;
  display: grid;
  place-items: center;
  border-radius: var(--r-sm);
  font-size: var(--f5);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  color: var(--g3);
}
.lb-rank--1 {
  background: var(--gold);
  color: var(--card);
}
.lb-rank--2 {
  background: var(--g3);
  color: var(--card);
}
.lb-rank--3 {
  background: var(--warn);
  color: var(--card);
}

.lb-av {
  flex: 0 0 auto;
  width: 32px;
  height: 32px;
  border-radius: var(--r-pill);
  object-fit: cover;
  background: var(--g6);
}
.lb-av--txt {
  display: grid;
  place-items: center;
  background: var(--pri-soft);
  color: var(--pri);
  font-size: var(--f5);
  font-weight: 700;
}

.lb-name {
  font-size: var(--f3);
  font-weight: 700;
  color: var(--g1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  display: block;
}

.lb-val {
  flex: 0 0 auto;
  font-size: var(--f3);
}

/* 骨架 */
.lb-rank-skel {
  flex: 0 0 auto;
  width: 24px;
  height: 24px;
  border-radius: var(--r-sm);
}
.lb-av-skel {
  flex: 0 0 auto;
  width: 32px;
  height: 32px;
  border-radius: var(--r-pill);
}
.lb-bar {
  display: block;
  width: 96px;
  height: 12px;
  border-radius: var(--r-sm);
}

.lb-state {
  display: grid;
  justify-items: center;
}
.lb-state .h5-empty {
  padding-bottom: var(--s2);
}

.lb-foot {
  margin: var(--s4) var(--page-x) 0;
  font-size: var(--f5);
  color: var(--g3);
  text-align: center;
}
</style>
