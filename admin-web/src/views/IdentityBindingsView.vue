<script setup lang="ts">
// 身份绑定（老板 ↔ 打手，负责人 2026-10-06 身份合并方案甲）：管理端**只读**运营排查页。
//
// 为什么单独一页而不是塞进「用户管理」：绑定是**两个账号之间的一等关系**，有状态（已绑定/已解绑）、
// 有历史行（解绑保留，不删除）、有上限配额（一个老板最多绑几个打手）。塞进用户列表后，
// 「同一老板绑了谁、什么时候解的、现在占几个名额」只能靠翻两行拼出来 —— 排查时最费时间的就是这个。
// 账号维度的行内提示留在「用户管理 / 工作端管理」（见两页的「身份绑定」列），本页负责全局检索。
//
// 数据全部来自只读接口 GET /admin/identity-bindings（权限点沿用 admin:user:read），
// 没有任何写操作：绑定/解绑只能由老板自己在老板端做（主体 id 只从 JWT sub 取，服务端权威）。
import { ApiException, request } from '@/api/client';
import {
  NButton,
  NDataTable,
  NDatePicker,
  NInput,
  NSelect,
  NTag,
  useMessage,
} from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

/** 绑定行（与服务端 IdentityBindingRow 一一对应，不造字段） */
interface BindingParty {
  userId: string | null;
  uid: string | null;
  username: string | null;
  nickname: string | null;
  userStatus: number | null;
  workerNo?: string | null;
  workerStatus?: number | null;
}
interface BindingRow {
  id: string;
  status: 'active' | 'unbound';
  slot: number;
  boundAt: string | null;
  unboundAt: string | null;
  bossActiveCount: number;
  boss: BindingParty;
  worker: BindingParty;
}

const message = useMessage();
const loading = ref(false);
const rows = ref<BindingRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const maxPerBoss = ref<number | null>(null);
const summary = ref({ total: 0, active: 0, unbound: 0 });

const statusFilter = ref<'all' | 'active' | 'unbound'>('all');
const keyword = ref('');
/** 时间范围（按**绑定时间**过滤）：n-date-picker 给的是毫秒时间戳区间 */
const range = ref<[number, number] | null>(null);

const statusOptions = [
  { label: '全部状态', value: 'all' },
  { label: '已绑定', value: 'active' },
  { label: '已解绑', value: 'unbound' },
];

/** 是否处于「有筛选」状态（空态文案据此区分"还没有记录"与"筛不出来"） */
const filtered = computed(
  () => statusFilter.value !== 'all' || !!keyword.value.trim() || !!range.value,
);

function fmt(v: string | null | undefined): string {
  if (!v) return '—';
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toLocaleString('zh-CN', { hour12: false });
}

function buildQuery(): string {
  const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
  if (statusFilter.value !== 'all') q.set('status', statusFilter.value);
  if (keyword.value.trim()) q.set('keyword', keyword.value.trim());
  if (range.value) {
    // 起=当日 00:00:00.000，止=当日 23:59:59.999（含当天，避免运营以为"选了今天却没数据"）
    const from = new Date(range.value[0]);
    from.setHours(0, 0, 0, 0);
    const to = new Date(range.value[1]);
    to.setHours(23, 59, 59, 999);
    q.set('boundFrom', from.toISOString());
    q.set('boundTo', to.toISOString());
  }
  return q.toString();
}

async function load() {
  loading.value = true;
  try {
    const data = await request<{
      list: BindingRow[];
      total: number;
      maxPerBoss: number;
      summary: { total: number; active: number; unbound: number };
    }>('GET', `/admin/identity-bindings?${buildQuery()}`);
    rows.value = data.list ?? [];
    total.value = data.total ?? 0;
    maxPerBoss.value = data.maxPerBoss ?? null;
    summary.value = data.summary ?? { total: 0, active: 0, unbound: 0 };
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

function search() {
  page.value = 1;
  void load();
}
function reset() {
  statusFilter.value = 'all';
  keyword.value = '';
  range.value = null;
  search();
}

const columns = computed(() => [
  {
    title: '老板',
    key: 'boss',
    minWidth: 240,
    render: (row: BindingRow) =>
      h('div', { class: 'party' }, [
        h('div', { class: 'party-name' }, [
          h('span', { class: 'name' }, row.boss.nickname || row.boss.username || '—'),
          row.boss.userStatus === 2 ? h(NTag, { size: 'small', type: 'warning' }, { default: () => '账号已封禁' }) : null,
        ].filter(Boolean)),
        h('div', { class: 'party-sub' }, `中文 ID ${row.boss.uid || '—'} · 用户 ID ${row.boss.userId || '—'}`),
      ]),
  },
  {
    title: '打手',
    key: 'worker',
    minWidth: 220,
    render: (row: BindingRow) =>
      h('div', { class: 'party' }, [
        h('div', { class: 'party-name' }, [
          h('span', { class: 'name' }, row.worker.nickname || row.worker.username || '—'),
          row.worker.userStatus === 2 ? h(NTag, { size: 'small', type: 'warning' }, { default: () => '账号已封禁' }) : null,
          row.worker.workerStatus === 2 ? h(NTag, { size: 'small' }, { default: () => '档案已停用' }) : null,
        ].filter(Boolean)),
        h('div', { class: 'party-sub' }, `工号 ${row.worker.workerNo || '—'}`),
      ]),
  },
  {
    title: '状态',
    key: 'status',
    width: 100,
    render: (row: BindingRow) =>
      row.status === 'active'
        ? h(NTag, { size: 'small', type: 'success' }, { default: () => '已绑定' })
        : h(NTag, { size: 'small' }, { default: () => '已解绑' }),
  },
  { title: '绑定时间', key: 'boundAt', width: 170, render: (row: BindingRow) => fmt(row.boundAt) },
  { title: '解绑时间', key: 'unboundAt', width: 170, render: (row: BindingRow) => fmt(row.unboundAt) },
  {
    title: '上限占用',
    key: 'quota',
    width: 120,
    // 该老板**当前**生效绑定数 / 平台上限（上限在「系统设置」可改，改完这里立刻反映）
    render: (row: BindingRow) =>
      h(
        'span',
        {
          class: 'quota',
          title: '该老板当前生效的绑定数 / 平台上限（一个老板最多能绑几个打手，可在「系统设置」修改）',
        },
        [
          h('strong', null, String(row.bossActiveCount)),
          h('span', { class: 'quota-sep' }, '/'),
          h('span', null, maxPerBoss.value === null ? '—' : String(maxPerBoss.value)),
        ],
      ),
  },
]);
</script>

<template>
  <div class="bindings-page">
    <div class="toolbar">
      <n-select v-model:value="statusFilter" :options="statusOptions" style="width: 140px" @update:value="search" />
      <n-input
        v-model:value="keyword"
        placeholder="老板中文 ID / 昵称 / 账号，或打手工号 / 昵称"
        style="width: 300px"
        clearable
        @keyup.enter="search"
        @clear="search"
      />
      <n-date-picker v-model:value="range" type="daterange" clearable style="width: 260px" @update:value="search" />
      <n-button @click="search">查询</n-button>
      <n-button quaternary :disabled="!filtered" @click="reset">重置</n-button>
      <div class="spacer" />
      <span class="stat">
        共 <strong>{{ summary.total }}</strong> 条 · 已绑定 <strong>{{ summary.active }}</strong> · 已解绑
        <strong>{{ summary.unbound }}</strong>
      </span>
    </div>

    <p class="hint">
      绑定只能由老板在老板端「我的 → 绑定打手账号」输入打手账密建立，管理端只读；
      解绑后**记录保留**（状态变为已解绑），封禁打手会同时解除绑定并立即吊销其打手态会话。
      当前上限：一个老板最多绑
      <strong>{{ maxPerBoss === null ? '—' : maxPerBoss }}</strong>
      个打手账号（在「系统设置」可改，1–10 整数，仅超管）。
    </p>

    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :bordered="false"
      :scroll-x="1020"
      :pagination="{
        page: page,
        pageSize: pageSize,
        itemCount: total,
        showSizePicker: false,
        onChange: (p: number) => { page = p; load(); },
      }"
    >
      <template #empty>
        <div class="empty">
          <template v-if="filtered">
            <p class="empty-title">没有符合筛选条件的绑定记录</p>
            <p class="empty-desc">
              换个状态或清空关键词试试；只记得工号时可以直接搜工号（如 MI109660A）。
            </p>
            <n-button size="small" @click="reset">重置筛选</n-button>
          </template>
          <template v-else>
            <p class="empty-title">还没有任何绑定记录</p>
            <p class="empty-desc">
              老板在老板端「我的」里绑定打手账号后，这里会出现一条记录：老板、打手、绑定时间与上限占用。
              解绑不会删除记录，只把状态改为「已解绑」，便于回查。
            </p>
          </template>
        </div>
      </template>
    </n-data-table>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 12px;
  flex-wrap: wrap;
}
.spacer {
  flex: 1;
}
.stat {
  font-size: 12.5px;
  color: var(--color-text-secondary, #666a73);
}
.stat strong {
  color: var(--color-primary-text, #5b6cff);
}
.hint {
  margin: 0 0 12px;
  font-size: 12.5px;
  line-height: 1.75;
  color: var(--color-text-secondary, #666a73);
}
.hint strong {
  color: var(--color-text-primary, #17181a);
}
/* 两端身份：名字一行 + 标识一行（组内紧、组间松，避免每格都挂彩色标签） */
.party-name {
  display: flex;
  align-items: center;
  gap: 6px;
}
.party-name .name {
  font-weight: 600;
}
.party-sub {
  margin-top: 2px;
  font-size: 12px;
  color: var(--color-text-tertiary, #9ca0a8);
}
.quota strong {
  color: var(--color-text-primary, #17181a);
}
.quota-sep {
  margin: 0 2px;
  color: var(--color-text-tertiary, #9ca0a8);
}
.empty {
  padding: 32px 16px 36px;
  text-align: center;
}
.empty-title {
  margin: 0 0 6px;
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary, #17181a);
}
.empty-desc {
  max-width: 460px;
  margin: 0 auto 14px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-secondary, #666a73);
}
</style>
