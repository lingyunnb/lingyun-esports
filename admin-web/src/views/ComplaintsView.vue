<script setup lang="ts">
// 投诉工单（权限点 admin:complaint:read 查看 / admin:complaint:handle 处理）
// 负责人 2026-10-04：老板端顶部导航「投诉」提交（对象/类型/描述/截图）→ 管理端处理 → 结果通知投诉人。
// 截图是受保护媒体（complaint_image）：只有投诉人本人与管理员可读，管理端经带令牌的 blob 预览。
import { ApiException, protectedMediaUrl, request } from '@/api/client';
import { NButton, NDataTable, NInput, NModal, NTag, useMessage } from 'naive-ui';
import { h, onBeforeUnmount, onMounted, reactive, ref } from 'vue';

interface ComplaintRow {
  id: string;
  complaintNo: string;
  userId: string;
  nickname: string;
  uid: string;
  targetType: string;
  targetId: string;
  targetName: string;
  type: string;
  content: string;
  mediaIds: string[];
  status: string;
  handleRemark: string;
  handledAt: string | null;
  createdAt: string;
}

const TARGET_LABEL: Record<string, string> = { order: '订单', worker: '打手', service: '客服' };
const TYPE_LABEL: Record<string, string> = {
  attitude: '服务态度',
  not_agreed: '未按约定',
  delay: '恶意拖延',
  other: '其它',
};
const STATUS_LABEL: Record<string, string> = {
  pending: '待处理',
  processing: '处理中',
  handled: '已处理',
  rejected: '已驳回',
};

const message = useMessage();
const rows = ref<ComplaintRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const loading = ref(false);
const statusFilter = ref('');
const targetFilter = ref('');
const stat = reactive({ pending: 0, processing: 0, handled: 0, rejected: 0 });

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
    if (statusFilter.value) q.set('status', statusFilter.value);
    if (targetFilter.value) q.set('targetType', targetFilter.value);
    const data = await request<{
      list: ComplaintRow[];
      total: number;
      stat: Record<string, number>;
    }>('GET', `/admin/complaints?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
    stat.pending = data.stat?.pending ?? 0;
    stat.processing = data.stat?.processing ?? 0;
    stat.handled = data.stat?.handled ?? 0;
    stat.rejected = data.stat?.rejected ?? 0;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

// ---- 详情（含截图：受保护媒体 → 带令牌 blob）----
const showDetail = ref(false);
const detail = ref<ComplaintRow | null>(null);
const shotUrls = ref<string[]>([]);
const shotLoading = ref(false);

function revokeShots() {
  for (const u of shotUrls.value) URL.revokeObjectURL(u);
  shotUrls.value = [];
}
onBeforeUnmount(revokeShots);

async function openDetail(row: ComplaintRow) {
  revokeShots();
  detail.value = row;
  form.status = row.status === 'pending' ? 'processing' : 'handled';
  form.remark = row.handleRemark || '';
  showDetail.value = true;
  shotLoading.value = true;
  try {
    const ids = row.mediaIds ?? [];
    const urls: string[] = [];
    for (const id of ids) urls.push(await protectedMediaUrl(id));
    shotUrls.value = urls;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '截图加载失败');
  } finally {
    shotLoading.value = false;
  }
}

const form = reactive({ status: 'processing' as 'processing' | 'handled' | 'rejected', remark: '' });
const handling = ref(false);

async function doHandle() {
  const row = detail.value;
  if (!row) return;
  if ((form.status === 'handled' || form.status === 'rejected') && !form.remark.trim()) {
    message.warning('结案必须填写处理意见');
    return;
  }
  handling.value = true;
  try {
    await request('POST', `/admin/complaints/${row.id}/handle`, { status: form.status, remark: form.remark });
    message.success(form.status === 'processing' ? '已认领（处理中）' : '已处理，结果已通知投诉人');
    showDetail.value = false;
    revokeShots();
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '处理失败');
  } finally {
    handling.value = false;
  }
}

const columns = [
  { title: '工单号', key: 'complaintNo', width: 150 },
  { title: '投诉人', key: 'nickname', width: 130, render: (row: ComplaintRow) => `${row.nickname || '—'}（${row.uid || row.userId}）` },
  {
    title: '对象', key: 'targetType', width: 130,
    render: (row: ComplaintRow) =>
      `${TARGET_LABEL[row.targetType] ?? row.targetType}${row.targetName ? ' · ' + row.targetName : ''}`,
  },
  { title: '类型', key: 'type', width: 100, render: (row: ComplaintRow) => TYPE_LABEL[row.type] ?? row.type },
  { title: '问题描述', key: 'content', ellipsis: { tooltip: true } },
  {
    title: '截图', key: 'mediaIds', width: 70,
    render: (row: ComplaintRow) => ((row.mediaIds ?? []).length ? `${row.mediaIds.length} 张` : '—'),
  },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: ComplaintRow) => {
      const map: Record<string, 'warning' | 'info' | 'success' | 'default'> = {
        pending: 'warning',
        processing: 'info',
        handled: 'success',
        rejected: 'default',
      };
      return h(NTag, { size: 'small', type: map[row.status] ?? 'default' }, { default: () => STATUS_LABEL[row.status] ?? row.status });
    },
  },
  { title: '提交时间', key: 'createdAt', width: 165, render: (row: ComplaintRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 150+130+130+100+70+90+165+100 = 935（+「问题描述」弹性列 220）→ 模板 :scroll-x = 1155
    // fixed:'right'：横向滚动时「处理/查看」始终完整可见
    title: '操作', key: 'actions', width: 100, fixed: 'right' as const,
    render: (row: ComplaintRow) =>
      h(NButton, { size: 'small', type: 'primary', onClick: () => openDetail(row) }, { default: () => (row.status === 'pending' || row.status === 'processing' ? '处理' : '查看') }),
  },
];
</script>

<template>
  <div class="complaints-page">
    <div class="toolbar">
      <n-tag
        v-for="s in [['', '全部'], ['pending', '待处理'], ['processing', '处理中'], ['handled', '已处理'], ['rejected', '已驳回']]"
        :key="s[0]"
        :type="statusFilter === s[0] ? 'primary' : 'default'"
        style="cursor: pointer"
        @click="statusFilter = s[0]; page = 1; load()"
      >
        {{ s[1] }}
      </n-tag>
      <n-tag
        v-for="t in [['', '全部对象'], ['order', '订单'], ['worker', '打手'], ['service', '客服']]"
        :key="t[0]"
        :type="targetFilter === t[0] ? 'primary' : 'default'"
        style="cursor: pointer"
        @click="targetFilter = t[0]; page = 1; load()"
      >
        {{ t[1] }}
      </n-tag>
      <div class="spacer" />
      <span class="stat">
        待处理 <strong>{{ stat.pending }}</strong> · 处理中 <strong>{{ stat.processing }}</strong> · 已处理 <strong>{{ stat.handled }}</strong>
      </span>
    </div>
    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :pagination="{ page, pageSize, itemCount: total, onChange: (p: number) => { page = p; load(); } }"
      :scroll-x="1155"
    />

    <n-modal
      v-model:show="showDetail"
      preset="card"
      title="投诉工单处理"
      style="width: 620px"
      @after-leave="revokeShots"
    >
      <div v-if="detail" class="detail">
        <p class="line"><span>工单号</span>{{ detail.complaintNo }}</p>
        <p class="line"><span>投诉人</span>{{ detail.nickname }}（{{ detail.uid }}）</p>
        <p class="line">
          <span>投诉对象</span>{{ TARGET_LABEL[detail.targetType] ?? detail.targetType }}
          {{ detail.targetName ? '· ' + detail.targetName : '' }}
        </p>
        <p class="line"><span>投诉类型</span>{{ TYPE_LABEL[detail.type] ?? detail.type }}</p>
        <p class="line"><span>当前状态</span>{{ STATUS_LABEL[detail.status] ?? detail.status }}</p>
        <div class="content">{{ detail.content }}</div>
        <div v-if="(detail.mediaIds ?? []).length" class="shots">
          <p v-if="shotLoading" class="loading">截图加载中…</p>
          <img v-for="(u, i) in shotUrls" :key="i" :src="u" alt="投诉截图" />
        </div>
        <p v-if="detail.status === 'handled' || detail.status === 'rejected'" class="done">
          该工单已结案（{{ detail.handleRemark || '无处理意见' }}），不可重复处理。
        </p>
        <template v-else>
          <div class="choice">
            <n-tag :type="form.status === 'processing' ? 'info' : 'default'" style="cursor: pointer" @click="form.status = 'processing'">处理中（认领）</n-tag>
            <n-tag :type="form.status === 'handled' ? 'success' : 'default'" style="cursor: pointer" @click="form.status = 'handled'">已处理（结案）</n-tag>
            <n-tag :type="form.status === 'rejected' ? 'error' : 'default'" style="cursor: pointer" @click="form.status = 'rejected'">驳回</n-tag>
          </div>
          <n-input
            v-model:value="form.remark"
            type="textarea"
            placeholder="处理意见（结案/驳回必填，会随站内通知发给投诉人）"
            :autosize="{ minRows: 2 }"
            style="margin-top: 12px"
          />
        </template>
      </div>
      <template #footer>
        <div class="footer">
          <n-button @click="showDetail = false; revokeShots()">关闭</n-button>
          <n-button
            v-if="detail && detail.status !== 'handled' && detail.status !== 'rejected'"
            type="primary"
            :loading="handling"
            @click="doHandle"
          >
            提交处理
          </n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
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
.detail .line {
  display: flex;
  gap: 10px;
  margin-bottom: 6px;
  font-size: 13px;
  color: var(--color-text-primary, #0b1220);
}
.detail .line > span {
  width: 72px;
  color: var(--color-text-tertiary, #94a3b8);
}
.content {
  margin: 10px 0;
  padding: 10px 12px;
  background: var(--color-bg-page, #f7f8fa);
  border-radius: 8px;
  font-size: 13px;
  line-height: 1.8;
  color: var(--color-text-secondary, #64748b);
  white-space: pre-wrap;
}
.shots {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 10px;
}
.shots img {
  width: 96px;
  height: 96px;
  object-fit: cover;
  border-radius: 6px;
  border: 1px solid var(--color-border, #e5e9f0);
}
.loading {
  font-size: 12px;
  color: var(--color-text-tertiary, #94a3b8);
}
.done {
  font-size: 12.5px;
  color: var(--color-text-tertiary, #94a3b8);
}
.choice {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.footer {
  display: flex;
  justify-content: flex-end;
  gap: 10px;
}
</style>
