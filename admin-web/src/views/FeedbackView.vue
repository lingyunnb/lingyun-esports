<script setup lang="ts">
// 意见反馈管理（admin:feedback:read）：列表（状态筛选）+ 处理（标记已处理+备注，操作留痕）
import { ApiException, request } from '@/api/client';
import { NButton, NDataTable, NInput, NModal, NSelect, NTag, useMessage } from 'naive-ui';
import { h, onMounted, ref } from 'vue';

interface FeedbackRow {
  id: string;
  userId: string;
  nickname: string;
  uid: string;
  content: string;
  contact: string;
  status: number;
  handlerRemark: string;
  createdAt: string;
}

const message = useMessage();
const rows = ref<FeedbackRow[]>([]);
const total = ref(0);
const page = ref(1);
const status = ref<number | ''>('');
const loading = ref(false);

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: '20' });
    if (status.value !== '') q.set('status', String(status.value));
    const data = await request<{ list: FeedbackRow[]; total: number }>('GET', `/admin/feedback?${q.toString()}`);
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
const handleRow = ref<FeedbackRow | null>(null);
const handleRemark = ref('');
const handling = ref(false);
function openHandle(row: FeedbackRow) {
  handleRow.value = row;
  handleRemark.value = '';
  showHandle.value = true;
}
async function doHandle() {
  const row = handleRow.value;
  if (!row) return;
  handling.value = true;
  try {
    await request('POST', `/admin/feedback/${row.id}/handle`, { remark: handleRemark.value });
    message.success('已标记处理（操作留痕）');
    showHandle.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '处理失败');
  } finally {
    handling.value = false;
  }
}

const columns = [
  { title: 'ID', key: 'id', width: 70 },
  { title: '用户', key: 'nickname', width: 130, render: (row: FeedbackRow) => `${row.nickname}（${row.uid}）` },
  { title: '反馈内容', key: 'content', ellipsis: { tooltip: true } },
  { title: '联系方式', key: 'contact', width: 120 },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: FeedbackRow) => row.status === 2
      ? h(NTag, { size: 'small', type: 'success' }, { default: () => '已处理' })
      : h(NTag, { size: 'small', type: 'warning' }, { default: () => '待处理' }),
  },
  { title: '处理备注', key: 'handlerRemark', width: 140, ellipsis: true },
  { title: '提交时间', key: 'createdAt', width: 170, render: (row: FeedbackRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 70+130+120+90+140+170+90 = 810（+「反馈内容」弹性列 220）→ 模板 :scroll-x = 1030
    // fixed:'right'：横向滚动时「处理」始终完整可见
    title: '操作', key: 'actions', width: 90, fixed: 'right' as const,
    render: (row: FeedbackRow) => row.status === 1
      ? h(NButton, { size: 'small', type: 'primary', onClick: () => openHandle(row) }, { default: () => '处理' })
      : null,
  },
];
</script>

<template>
  <div class="feedback-page">
    <div class="toolbar">
      <n-select v-model:value="status" :options="[
        { label: '全部状态', value: '' },
        { label: '待处理', value: 1 },
        { label: '已处理', value: 2 },
      ]" style="width: 140px" @update:value="page = 1; load()" />
    </div>
    <n-data-table :columns="columns" :data="rows" :loading="loading" :scroll-x="1030"
      :pagination="{ page: page, pageSize: 20, itemCount: total, onChange: (p: number) => { page = p; load(); } }" />

    <n-modal v-model:show="showHandle" preset="dialog" title="处理反馈" positive-text="标记已处理" negative-text="取消" :positive-button-props="{ loading: handling }" @positive-click="doHandle">
      <p class="fb-content">{{ handleRow?.content }}</p>
      <n-input v-model:value="handleRemark" type="textarea" placeholder="处理备注（可选，留痕）" :autosize="{ minRows: 2, maxRows: 4 }" />
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}
.fb-content {
  margin-bottom: 12px;
  padding: 10px 12px;
  background: var(--color-bg-page, #f7f8fa);
  border-radius: 8px;
  font-size: 13px;
  color: var(--color-text-secondary);
}
</style>
