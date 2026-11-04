<script setup lang="ts">
// 售后申诉管理（权限点 admin:appeal:handle，docs/05）：列表 + 裁决（退款含结算冲正 / 驳回）
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（余额口径；API 字段名不变）
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { NButton, NDataTable, NInput, NModal, NTag, useMessage } from 'naive-ui';
import { h, onMounted, reactive, ref } from 'vue';

interface AppealRow {
  id: string;
  orderId: string;
  orderNo: string;
  nickname: string;
  totalAmount: number;
  prevStatus: string;
  reason: string;
  status: string;
  result: string | null;
  handlerRemark: string | null;
  createdAt: string;
}

const message = useMessage();
const rows = ref<AppealRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const loading = ref(false);
const statusFilter = ref('');

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
    if (statusFilter.value) q.set('status', statusFilter.value);
    const data = await request<{ list: AppealRow[]; total: number }>('GET', `/admin/appeals?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

const showHandle = ref(false);
const handleRow = ref<AppealRow | null>(null);
const handleForm = reactive({ action: 'refund' as 'refund' | 'dismiss', remark: '' });
const handling = ref(false);

function openHandle(row: AppealRow) {
  handleRow.value = row;
  handleForm.action = 'refund';
  handleForm.remark = '';
  showHandle.value = true;
}

async function doHandle() {
  const row = handleRow.value;
  if (!row || !handleForm.action) return;
  handling.value = true;
  try {
    await request('POST', `/admin/appeals/${row.id}/handle`, { action: handleForm.action, remark: handleForm.remark });
    message.success(handleForm.action === 'refund' ? '已退款（含结算冲正）' : '已驳回');
    showHandle.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '处理失败');
  } finally {
    handling.value = false;
  }
}

const columns = [
  { title: '订单号', key: 'orderNo', width: 170 },
  { title: '用户', key: 'nickname', width: 110 },
  { title: '金额', key: 'totalAmount', width: 110, render: (row: AppealRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.totalAmount)) },
  { title: '申诉原因', key: 'reason', ellipsis: { tooltip: true } },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: AppealRow) => row.status === 'open'
      ? h(NTag, { size: 'small', type: 'warning' }, { default: () => '待处理' })
      : h(NTag, { size: 'small', type: row.result === 'refund' ? 'success' : 'default' }, { default: () => (row.result === 'refund' ? '已退款' : '已驳回') }),
  },
  { title: '申诉时间', key: 'createdAt', width: 160, render: (row: AppealRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 170+110+110+90+160+130 = 770（+「申诉原因」弹性列 200）→ 模板 :scroll-x = 970
    // fixed:'right'：横向滚动时「裁决」始终完整可见
    title: '操作', key: 'actions', width: 130, fixed: 'right' as const,
    render: (row: AppealRow) => (row.status === 'open'
      ? h(NButton, { size: 'small', type: 'primary', onClick: () => openHandle(row) }, { default: () => '裁决' })
      : h('span', { style: 'color: var(--color-text-tertiary);font-size:12px' }, row.handlerRemark ?? '已处理')),
  },
];
</script>

<template>
  <div class="appeals-page">
    <div class="toolbar">
      <n-tag
        v-for="s in [['', '全部'], ['open', '待处理'], ['handled', '已处理']]"
        :key="s[0]"
        :type="statusFilter === s[0] ? 'primary' : 'default'"
        style="cursor: pointer; margin-right: 8px"
        @click="statusFilter = s[0]; page = 1; load()"
      >
        {{ s[1] }}
      </n-tag>
      <div class="spacer" />
    </div>
    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :pagination="{ page, pageSize, itemCount: total, onChange: (p: number) => { page = p; load(); } }"
      :scroll-x="970"
    />
    <n-modal v-model:show="showHandle" preset="dialog" title="售后裁决" positive-text="确认" negative-text="取消" :positive-button-props="{ loading: handling }" @positive-click="doHandle">
      <p v-if="handleRow" class="appeal-info">
        订单 {{ handleRow.orderNo }}（{{ formatYuan(handleRow.totalAmount) }}）<br />
        用户 {{ handleRow.nickname }} 申诉：{{ handleRow.reason }}
      </p>
      <div class="action-choice">
        <n-tag
          :type="handleForm.action === 'refund' ? 'success' : 'default'"
          style="cursor: pointer; margin-right: 8px"
          @click="handleForm.action = 'refund'"
        >
          同意退款（已结算订单按该单结算记录自动冲正打手与平台）
        </n-tag>
        <n-tag
          :type="handleForm.action === 'dismiss' ? 'error' : 'default'"
          style="cursor: pointer"
          @click="handleForm.action = 'dismiss'"
        >
          驳回申诉
        </n-tag>
      </div>
      <n-input v-model:value="handleForm.remark" type="textarea" placeholder="处理备注（驳回时建议填写原因）" :autosize="{ minRows: 2 }" style="margin-top: 12px" />
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  margin-bottom: 16px;
}
.spacer {
  flex: 1;
}
.appeal-info {
  margin-bottom: 12px;
  font-size: 13px;
  color: var(--color-text-secondary);
  line-height: 1.7;
}
.action-choice {
  display: flex;
  align-items: center;
}
</style>
