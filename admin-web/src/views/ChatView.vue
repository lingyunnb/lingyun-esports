<script setup lang="ts">
// 聊天管理（docs/07）：会话列表（未读/指派状态）+ 指派客服（admin:chat:assign）+ 查看消息（admin:chat:read）
import { ApiException, request } from '@/api/client';
import { NButton, NDataTable, NDrawer, NDrawerContent, NModal, NSelect, NTag, useMessage } from 'naive-ui';
import { h, onMounted, ref } from 'vue';

interface ConversationRow {
  id: string;
  userId: string;
  userNickname: string;
  unreadUser: number;
  unreadWorker: number;
  status: string;
  csWorkerUserId: string | null;
  type: 'cs' | 'friend';
  updatedAt: string;
}

interface WorkerRow {
  id: string;
  workerNo: string;
  userId: string;
  nickname: string;
  canServeCustomer: number;
  status: number;
}

interface MsgRow {
  msgId: string;
  seq: number;
  senderType: string;
  msgType: string;
  content: string;
  recalled: boolean;
  createdAt: string;
}

const message = useMessage();
const rows = ref<ConversationRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const loading = ref(false);

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
    const data = await request<{ list: ConversationRow[]; total: number }>('GET', `/admin/chat/conversations?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

// 指派客服
const showAssign = ref(false);
const assignRow = ref<ConversationRow | null>(null);
const csWorkers = ref<WorkerRow[]>([]);
const assignWorkerId = ref<string | null>(null);
const assigning = ref(false);

async function openAssign(row: ConversationRow) {
  assignRow.value = row;
  assignWorkerId.value = row.csWorkerUserId;
  try {
    const data = await request<{ list: WorkerRow[] }>('GET', '/admin/workers?page=1&pageSize=100');
    csWorkers.value = (data.list ?? data ?? []).filter((w) => w.canServeCustomer === 1 && w.status === 1);
    showAssign.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载客服失败');
  }
}

async function doAssign() {
  const row = assignRow.value;
  if (!row || !assignWorkerId.value) return;
  assigning.value = true;
  try {
    await request('POST', `/admin/chat/conversations/${row.id}/assign`, { workerUserId: assignWorkerId.value });
    message.success('已指派客服（原客服已解除）');
    showAssign.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '指派失败');
  } finally {
    assigning.value = false;
  }
}

// 查看消息
const showMsgs = ref(false);
const msgsRow = ref<ConversationRow | null>(null);
const msgs = ref<MsgRow[]>([]);
async function openMsgs(row: ConversationRow) {
  msgsRow.value = row;
  try {
    const data = await request<{ list: MsgRow[] }>('GET', `/admin/chat/conversations/${row.id}/messages?limit=200`);
    msgs.value = data.list;
    showMsgs.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载消息失败');
  }
}

const columns = [
  {
    title: '类型', key: 'type', width: 80,
    render: (row: ConversationRow) => row.type === 'friend'
      ? h(NTag, { size: 'small', type: 'info' }, { default: () => '好友' })
      : h(NTag, { size: 'small', type: 'default' }, { default: () => '客服' }),
  },
  { title: '用户', key: 'userNickname', width: 130 },
  { title: '用户未读', key: 'unreadUser', width: 90, render: (row: ConversationRow) => row.unreadUser > 0 ? h(NTag, { size: 'small', type: 'warning' }, { default: () => String(row.unreadUser) }) : '0' },
  { title: '客服未读', key: 'unreadWorker', width: 90, render: (row: ConversationRow) => row.unreadWorker > 0 ? h(NTag, { size: 'small', type: 'error' }, { default: () => String(row.unreadWorker) }) : '0' },
  {
    title: '指派客服', key: 'csWorkerUserId', width: 130,
    render: (row: ConversationRow) => (row.csWorkerUserId
      ? h(NTag, { size: 'small', type: 'success' }, { default: () => `已指派 #${row.csWorkerUserId}` })
      : h(NTag, { size: 'small', type: 'warning' }, { default: () => '未指派' })),
  },
  { title: '更新时间', key: 'updatedAt', width: 160, render: (row: ConversationRow) => new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 80+130+90+90+130+160+150 = 830 → 模板 :scroll-x = 830
    // fixed:'right'：横向滚动时「消息/指派」始终完整可见
    title: '操作', key: 'actions', width: 150, fixed: 'right' as const,
    render: (row: ConversationRow) => h('div', { style: 'display:flex;gap:8px' }, [
      h(NButton, { size: 'small', onClick: () => openMsgs(row) }, { default: () => '消息' }),
      ...(row.type !== 'friend'
        ? [h(NButton, { size: 'small', type: 'primary', onClick: () => openAssign(row) }, { default: () => '指派' })]
        : []),
    ]),
  },
];
</script>

<template>
  <div class="chat-page">
    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :pagination="{ page, pageSize, itemCount: total, onChange: (p: number) => { page = p; load(); } }"
      :scroll-x="830"
    />
    <p class="hint">会话指派对持客服权限的工作端生效；改派后原客服即时解除并被提示（docs/07）</p>

    <n-modal v-model:show="showAssign" preset="dialog" title="指派客服" positive-text="指派" negative-text="取消" :positive-button-props="{ loading: assigning }" @positive-click="doAssign">
      <p v-if="assignRow" class="assign-info">用户 {{ assignRow.userNickname }} 的会话</p>
      <n-select
        v-model:value="assignWorkerId"
        :options="csWorkers.map((w) => ({ label: `${w.nickname}（工号 ${w.workerNo}）`, value: w.userId }))"
        placeholder="选择客服"
        filterable
      />
    </n-modal>

    <n-drawer v-model:show="showMsgs" :width="480">
      <n-drawer-content :title="`会话消息${msgsRow ? ' · ' + msgsRow.userNickname : ''}`" closable>
        <div v-for="m in msgs" :key="m.msgId" class="msg-row" :class="m.senderType === 'user' ? 'from-user' : 'from-cs'">
          <div class="bubble">
            <span v-if="m.recalled" class="recalled">消息已撤回</span>
            <template v-else-if="m.msgType === 'image'">[图片 #{{ m.content }}]</template>
            <template v-else>{{ m.content }}</template>
          </div>
          <div class="meta">{{ m.senderType === 'user' ? '用户' : '客服' }} · {{ new Date(m.createdAt).toLocaleTimeString('zh-CN', { hour12: false }) }}</div>
        </div>
        <p v-if="!msgs.length" class="empty">暂无消息</p>
      </n-drawer-content>
    </n-drawer>
  </div>
</template>

<style scoped>
.hint {
  margin-top: 12px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.assign-info {
  margin-bottom: 12px;
  font-size: 13px;
  color: var(--color-text-secondary);
}
.msg-row {
  margin-bottom: 12px;
  display: flex;
  flex-direction: column;
}
.from-user {
  align-items: flex-start;
}
.from-cs {
  align-items: flex-end;
}
.bubble {
  max-width: 80%;
  padding: 8px 12px;
  border-radius: 8px;
  font-size: 14px;
  background: var(--color-bg-card);
  border: 1px solid var(--color-divider);
}
.from-cs .bubble {
  background: var(--color-primary);
  color: #fff;
  border: none;
}
.recalled {
  font-style: italic;
  color: var(--color-text-tertiary);
}
.meta {
  margin-top: 4px;
  font-size: 11px;
  color: var(--color-text-tertiary);
}
.empty {
  text-align: center;
  color: var(--color-text-tertiary);
  padding: 40px 0;
}
</style>
