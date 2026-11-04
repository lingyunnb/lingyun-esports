<script setup lang="ts">
// 抽成中心（负责人结算需求）：概览（真实 SQL 统计）+ 收益流水
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（余额口径；API 字段名不变）
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { NButton, NDataTable, NGrid, NGi, NInput, NStatistic, useMessage } from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';

interface Stats {
  totalOrderAmount: number;
  totalWorker: number;
  totalPlatform: number;
  todayPlatform: number;
  monthPlatform: number;
  orderCount: number;
  settledCount: number;
  /** 当前生效抽成比例（百分数整数，读 system_setting；默认 25） */
  commissionRate: number;
  /** 当前生效打手分成比例 = 100 - commissionRate */
  workerPercentage: number;
}

interface SettlementRow {
  id: string;
  settlementNo: string;
  orderId: string;
  orderNo: string;
  orderAmount: number;
  workerId: string;
  workerAmount: number;
  workerPercentage: number;
  platformAmount: number;
  platformPercentage: number;
  createdAt: string;
}

const message = useMessage();
const router = useRouter();
const stats = ref<Stats | null>(null);
const rows = ref<SettlementRow[]>([]);
const total = ref(0);
const page = ref(1);
const orderNo = ref('');

async function loadStats() {
  try {
    stats.value = await request<Stats>('GET', '/admin/commission/stats');
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}
async function loadList() {
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: '20' });
    if (orderNo.value) q.set('orderNo', orderNo.value);
    const data = await request<{ list: SettlementRow[]; total: number }>('GET', `/admin/settlements?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}
onMounted(() => { loadStats(); loadList(); });

// 列头写「当前比例」，比例来自 /admin/commission/stats（**异步**）：
// 必须用 computed —— 写成普通数组时标题字符串在 setup 期就被冻结成「当前 —%」，
// 数据回来也不会更新（2026-10-09 真浏览器核验时量到的就是这个「—」）。
const columns = computed(() => [
  // 列宽和 = 170+170+110+150+140+170 = 910 → 模板 :scroll-x = 910（本页无操作列，但右侧「结算时间」同样会被裁）
  { title: '结算ID', key: 'settlementNo', width: 170 },
  { title: '订单号', key: 'orderNo', width: 170 },
  {
    title: '订单金额', key: 'orderAmount', width: 110,
    render: (row: SettlementRow) => h('strong', {}, formatYuanOr(row.orderAmount)),
  },
  {
    // 列头不写死比例：结算单据各自的落库比例在单元格里展示（历史单据可能是旧比例）
    title: `打手收益（当前 ${stats.value?.workerPercentage ?? '—'}%）`, key: 'workerAmount', width: 150,
    render: (row: SettlementRow) => h('span', { style: 'color: var(--color-success)' }, `${formatYuan(row.workerAmount)}（${row.workerPercentage}%）`),
  },
  {
    title: '平台抽成', key: 'platformAmount', width: 140,
    render: (row: SettlementRow) => h('span', { style: 'color: var(--color-primary)' }, `${formatYuan(row.platformAmount)}（${row.platformPercentage}%）`),
  },
  { title: '结算时间', key: 'createdAt', width: 170, render: (row: SettlementRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
]);
</script>

<template>
  <div class="commission-page">
    <n-grid v-if="stats" :cols="5" :x-gap="12" class="stats">
      <n-gi>
        <n-statistic label="累计订单金额（元）" :value="formatYuan(stats.totalOrderAmount)" />
      </n-gi>
      <n-gi>
        <n-statistic label="累计打手收益（元）" :value="formatYuan(stats.totalWorker)" />
      </n-gi>
      <n-gi>
        <n-statistic label="累计平台抽成（元）" :value="formatYuan(stats.totalPlatform)" />
      </n-gi>
      <n-gi>
        <n-statistic label="今日平台抽成（元）" :value="formatYuan(stats.todayPlatform)" />
      </n-gi>
      <n-gi>
        <n-statistic label="本月平台抽成（元）" :value="formatYuan(stats.monthPlatform)" />
      </n-gi>
    </n-grid>
    <p v-if="stats" class="hint">
      订单总数 {{ stats.orderCount }} · 已结算订单 {{ stats.settledCount }} —— 当前抽成比例
      <strong>平台 {{ stats.commissionRate }}% / 打手 {{ stats.workerPercentage }}%</strong>（服务器按订单快照计算；
      比例在「系统设置」页可改，改后对之后的结算生效，历史结算仍按当时比例留痕）
      <n-button size="tiny" quaternary type="primary" style="margin-left: 8px" @click="router.push('/settings')">去系统设置修改</n-button>
    </p>

    <div class="toolbar">
      <n-input v-model:value="orderNo" placeholder="按订单号筛选" style="width: 220px" @keyup.enter="page = 1; loadList()" />
      <n-button @click="page = 1; loadList()">筛选</n-button>
    </div>
    <n-data-table :columns="columns" :data="rows" :scroll-x="910"
      :pagination="{ page: page, pageSize: 20, itemCount: total, onChange: (p: number) => { page = p; loadList(); } }" />
  </div>
</template>

<style scoped>
.stats {
  margin-bottom: 8px;
}
.toolbar {
  display: flex;
  gap: 12px;
  margin: 16px 0;
}
.hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
</style>
