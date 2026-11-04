<script setup lang="ts">
// 排行榜管理（M7）：周期榜单/重算/人工调整（admin:leaderboard:adjust，留痕审计）/调整记录
// 口径（2026-10-09）：榜单金额是订单金额的聚合（元）→ 一律 ¥ + 两位小数（API 字段名不变）；
// 「完成单数」是计数，与单位无关，不加 ¥。
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr, formatYuanSigned } from '@/utils/format';
import { NButton, NDataTable, NInput, NInputNumber, NModal, NSelect, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

interface EntryRow {
  rank: number;
  workerId: string;
  nickname: string;
  workerNo: string;
  completedOrders: number;
  totalAmount: number;
  adjustment: number;
  effectiveAmount: number;
}

interface AdjustmentRow {
  id: string;
  workerId: string;
  nickname: string;
  amountDelta: number;
  reason: string;
  createdAt: string;
}

interface WorkerRow {
  id: string;
  nickname: string;
  workerNo: string;
}

const message = useMessage();
const period = ref(currentPeriod('week'));
const rows = ref<EntryRow[]>([]);
const adjustments = ref<AdjustmentRow[]>([]);
const loading = ref(false);
const tab = ref<'board' | 'adjustments'>('board');

function currentPeriod(kind: 'week' | 'month'): string {
  const now = new Date();
  if (kind === 'month') {
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  }
  const d = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((d.getTime() - yearStart.getTime()) / 86400_000 + 1) / 7);
  return `${d.getUTCFullYear()}-W${week}`;
}

async function load() {
  loading.value = true;
  try {
    const [b, a] = await Promise.all([
      request<EntryRow[]>('GET', `/admin/leaderboard?period=${period.value}`),
      request<AdjustmentRow[]>('GET', `/admin/leaderboard/adjustments?period=${period.value}`),
    ]);
    rows.value = b;
    adjustments.value = a;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

async function recalc() {
  try {
    const r = await request<{ entries: number }>('POST', '/admin/leaderboard/recalc', { period: period.value });
    message.success(`重算完成（${r.entries} 名打手）`);
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '重算失败');
  }
}

// 人工调整
const showAdjust = ref(false);
const adjustForm = ref({ workerId: null as string | null, amountDelta: 0, reason: '' });
const workers = ref<WorkerRow[]>([]);
const adjusting = ref(false);

async function openAdjust() {
  adjustForm.value = { workerId: null, amountDelta: 0, reason: '' };
  try {
    const data = await request<{ list: WorkerRow[] }>('GET', '/admin/workers?page=1&pageSize=100');
    workers.value = data.list ?? data ?? [];
    showAdjust.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载打手失败');
  }
}

async function doAdjust() {
  if (!adjustForm.value.workerId || !adjustForm.value.amountDelta) {
    message.warning('请选择打手并填写非零调整金额');
    return;
  }
  adjusting.value = true;
  try {
    await request('POST', '/admin/leaderboard/adjust', {
      period: period.value,
      workerId: adjustForm.value.workerId,
      amountDelta: adjustForm.value.amountDelta,
      reason: adjustForm.value.reason,
    });
    message.success('已调整并重算排名（操作已留痕）');
    showAdjust.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '调整失败');
  } finally {
    adjusting.value = false;
  }
}

const boardColumns = [
  // 列宽和 = 70+160+90+130+120+130 = 700 → 模板 :scroll-x = 700
  { title: '排名', key: 'rank', width: 70, render: (row: EntryRow) => h('strong', { style: row.rank <= 3 ? 'color: var(--color-warning)' : '' }, `#${row.rank}`) },
  { title: '打手', key: 'nickname', width: 160, render: (row: EntryRow) => `${row.nickname}（${row.workerNo}）` },
  { title: '完成单数', key: 'completedOrders', width: 90 },
  { title: '真实金额', key: 'totalAmount', width: 130, render: (row: EntryRow) => h('strong', {}, formatYuanOr(row.totalAmount)) },
  { title: '人工调整', key: 'adjustment', width: 120, render: (row: EntryRow) => (row.adjustment !== 0 ? h(NTag, { size: 'small', type: row.adjustment > 0 ? 'success' : 'error' }, { default: () => formatYuanSigned(row.adjustment) }) : '¥0.00') },
  { title: '有效金额', key: 'effectiveAmount', width: 130, render: (row: EntryRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.effectiveAmount)) },
];

const adjColumns = [
  // 列宽和 = 160+110+170 = 440（+「原因」弹性列 200）→ 模板 :scroll-x = 640
  { title: '打手', key: 'nickname', width: 160 },
  {
    title: '调整', key: 'amountDelta', width: 110,
    render: (row: AdjustmentRow) => h(NTag, { size: 'small', type: row.amountDelta > 0 ? 'success' : 'error' }, { default: () => formatYuanSigned(row.amountDelta) }),
  },
  { title: '原因', key: 'reason', ellipsis: true },
  { title: '时间', key: 'createdAt', width: 170, render: (row: AdjustmentRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
];
</script>

<template>
  <div class="leaderboard-page">
    <div class="toolbar">
      <n-input v-model:value="period" placeholder="周期（2026-W38 / 2026-09）" style="width: 180px" />
      <n-button type="primary" @click="recalc">重算榜单</n-button>
      <n-button @click="openAdjust">人工调整</n-button>
      <div class="spacer" />
      <n-select
        v-model:value="tab"
        :options="[
          { label: '榜单', value: 'board' },
          { label: '调整记录', value: 'adjustments' },
        ]"
        style="width: 130px"
      />
    </div>
    <n-data-table v-if="tab === 'board'" :columns="boardColumns" :data="rows" :loading="loading" :scroll-x="700" />
    <n-data-table v-else :columns="adjColumns" :data="adjustments" :loading="loading" :scroll-x="640" />
    <p class="hint">榜单口径：完成订单数 + 总金额（元；有效金额 = 真实金额 + 人工调整）—— 金额一律 ¥ 两位小数，调整操作留痕可审计（docs/待确认事项）</p>

    <n-modal v-model:show="showAdjust" preset="dialog" title="人工调整榜单" positive-text="确认调整" negative-text="取消" :positive-button-props="{ loading: adjusting }" @positive-click="doAdjust">
      <n-select
        v-model:value="adjustForm.workerId"
        :options="workers.map((w) => ({ label: `${w.nickname}（工号 ${w.workerNo}）`, value: w.id }))"
        placeholder="选择打手"
        filterable
        style="margin-bottom: 12px"
      />
      <n-input-number v-model:value="adjustForm.amountDelta" placeholder="调整金额（元；正数加榜/负数减榜）" style="width: 100%; margin-bottom: 12px">
        <template #prefix>¥</template>
      </n-input-number>
      <n-input v-model:value="adjustForm.reason" placeholder="调整原因（必填，留痕审计）" />
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
  align-items: center;
}
.spacer {
  flex: 1;
}
.hint {
  margin-top: 12px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
</style>
