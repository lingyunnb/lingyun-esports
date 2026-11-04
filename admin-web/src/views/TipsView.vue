<script setup lang="ts">
// 打赏管理（权限点 admin:tip:read 查看 / admin:tip:config 改金额配置）
// 负责人 2026-10-04：老板端顶部导航「打赏」用余额打赏，打赏金额 100% 给打手（平台不抽成）
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（余额口径；API 字段名不变）
// 负责人 2026-10-04 权限收口：admin:tip:config 从普通运营角色收回，仅超管 + 所有者（前端只隐藏，服务端 403 才是权威）
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import { NButton, NDataTable, NInput, NInputNumber, NModal, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface TipRow {
  id: string;
  orderId: string;
  orderNo: string;
  fromUserId: string;
  fromNickname: string;
  fromUid: string;
  toUserId: string;
  toNickname: string;
  toUid: string;
  toWorkerId: string;
  amount: number;
  status: string;
  remark: string;
  createdAt: string;
}

const message = useMessage();
const auth = useAuthStore();
/** 打赏金额配置 = 独占权限点（超管 + 所有者）；普通运营只有 admin:tip:read，能看不能改 */
const canConfig = computed(() => auth.hasExclusivePermission('admin:tip:config'));
const rows = ref<TipRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const keyword = ref('');
const loading = ref(false);
const stat = reactive({ totalAmount: 0, todayAmount: 0 });

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
    if (keyword.value.trim()) q.set('keyword', keyword.value.trim());
    const data = await request<{ list: TipRow[]; total: number; stat: { totalAmount: number; todayAmount: number } }>(
      'GET',
      `/admin/tips?${q.toString()}`,
    );
    rows.value = data.list;
    total.value = data.total;
    stat.totalAmount = data.stat?.totalAmount ?? 0;
    stat.todayAmount = data.stat?.todayAmount ?? 0;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

// ---- 金额配置（预设 / 单次上限 / 同订单累计上限）----
const showConfig = ref(false);
const saving = ref(false);
const cfg = reactive({ presets: '6,18,38,88', maxPerTip: 500, maxPerOrder: 1000 });

async function openConfig() {
  try {
    const data = await request<{ presets: number[]; maxPerTip: number; maxPerOrder: number }>('GET', '/admin/tips/config');
    cfg.presets = (data.presets ?? []).join(',');
    cfg.maxPerTip = data.maxPerTip;
    cfg.maxPerOrder = data.maxPerOrder;
    showConfig.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '配置读取失败');
  }
}

async function saveConfig() {
  // 口径（2026-10-09）：打赏是「元」且允许两位小数 —— 服务端迁移把预设按 10:1 折算成 0.6/1.8/3.8/8.8，
  // 因此这里**不能**再按整数过滤（旧实现 `Number.isInteger` 会把 0.6 这类档位静默丢掉，
  // 运营只是打开弹窗点了保存就把档位改没了）。去重 + 保留两位小数 + 最多 8 个，与弹窗提示一致。
  const presets = Array.from(
    new Set(
      cfg.presets
        .split(/[,，\s]+/)
        .map((v) => Number(v))
        .filter((v) => Number.isFinite(v) && v > 0)
        .map((v) => Math.round(v * 100) / 100),
    ),
  ).slice(0, 8);
  saving.value = true;
  try {
    await request('POST', '/admin/tips/config', { presets, maxPerTip: cfg.maxPerTip, maxPerOrder: cfg.maxPerOrder });
    message.success('打赏金额配置已保存（客户端下次进入打赏页生效）');
    showConfig.value = false;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

const columns = [
  // 列宽和 = 70+170+150+150+120+90+140+170 = 1060 → 模板 :scroll-x = 1060（本页无操作列，右侧「时间」同样会被裁）
  { title: 'ID', key: 'id', width: 70 },
  { title: '订单号', key: 'orderNo', width: 170 },
  {
    title: '打赏老板', key: 'fromNickname', width: 150,
    render: (row: TipRow) => `${row.fromNickname || '—'}（${row.fromUid || row.fromUserId}）`,
  },
  {
    title: '收款打手', key: 'toNickname', width: 150,
    render: (row: TipRow) => `${row.toNickname || '—'}（${row.toUid || row.toUserId}）`,
  },
  {
    // 金额列：打赏金额（元）→ ¥ + 两位小数
    title: '打赏金额', key: 'amount', width: 120,
    render: (row: TipRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.amount)),
  },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: TipRow) =>
      row.status === 'success'
        ? h(NTag, { size: 'small', type: 'success' }, { default: () => '已到账' })
        : h(NTag, { size: 'small' }, { default: () => row.status }),
  },
  { title: '备注', key: 'remark', width: 140, ellipsis: { tooltip: true } },
  {
    title: '时间', key: 'createdAt', width: 170,
    render: (row: TipRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }),
  },
];
</script>

<template>
  <div class="tips-page">
    <div class="toolbar">
      <n-input v-model:value="keyword" placeholder="订单号 / 昵称" style="width: 200px" @keyup.enter="page = 1; load()" />
      <n-button @click="page = 1; load()">查询</n-button>
      <n-button v-if="canConfig" type="primary" @click="openConfig">金额配置</n-button>
      <div class="spacer" />
      <span class="stat">累计打赏 <strong>{{ formatYuan(stat.totalAmount) }}</strong> · 今日 <strong>{{ formatYuan(stat.todayAmount) }}</strong></span>
    </div>
    <p v-if="!canConfig" class="hint">金额配置需要 <code>admin:tip:config</code> 权限点（已收口为超级管理员与所有者独占；普通运营可查看打赏记录，但不能改配置）。</p>
    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :pagination="{ page, pageSize, itemCount: total, onChange: (p: number) => { page = p; load(); } }"
      :scroll-x="1060"
    />

    <n-modal
      v-model:show="showConfig"
      preset="dialog"
      title="打赏金额配置"
      positive-text="保存"
      negative-text="取消"
      :positive-button-props="{ loading: saving }"
      @positive-click="saveConfig"
    >
      <p class="hint">预设金额（逗号分隔，最多 8 个，单位：元，最多两位小数）／单次上限／同一订单累计上限（均按余额口径，元）。服务端按此判定，客户端只做展示。</p>
      <div class="field"><span>预设金额(元)</span><n-input v-model:value="cfg.presets" placeholder="0.6,1.8,3.8,8.8" /></div>
      <div class="field"><span>单次上限(元)</span><n-input-number v-model:value="cfg.maxPerTip" :min="0.01" :precision="2" /></div>
      <div class="field"><span>单订单累计上限(元)</span><n-input-number v-model:value="cfg.maxPerOrder" :min="0.01" :precision="2" /></div>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 16px;
}
.spacer {
  flex: 1;
}
.stat {
  font-size: 12.5px;
  color: var(--color-text-secondary, #64748b);
}
.stat strong {
  color: var(--color-primary-text, #1d5fa8);
}
.hint {
  margin-bottom: 12px;
  font-size: 12.5px;
  color: var(--color-text-secondary, #64748b);
  line-height: 1.7;
}
.field {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
}
.field > span {
  width: 110px;
  font-size: 13px;
  color: var(--color-text-secondary, #64748b);
}
</style>
