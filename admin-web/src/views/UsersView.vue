<script setup lang="ts">
// 用户管理（负责人需求）：老板端/工作端账号列表、封号（自定义时长/永久）、解封、删除账号
// 权限：查看 admin:user:read；封禁/解封 admin:user:ban；删除 admin:user:delete（后两者默认仅超管）
//
// 身份绑定（负责人 2026-10-06 身份合并方案甲）：本页**不新增后端字段**，绑定关系由只读接口
// GET /admin/identity-bindings 提供 ——
// · 常规浏览：按当前页的 20 个 user id **一次批量**取生效绑定（20 行不发 20 个请求），行内提示「已绑定打手/老板」；
// · 「绑定状态」筛选（运营排查"谁还没绑"）：服务端账号列表接口没有绑定维度，故进入**排查模式**——
//   显式告知后一次性读全量账号（≤500）+ 全量生效绑定，再本地比对与分页（有截断就如实提示）。
import { ApiException, request } from '@/api/client';
import {
  boundUserIdSet,
  fetchActiveBindingNotes,
  fetchAllActiveBindings,
  fetchAllPages,
  type BindingNote,
} from '@/api/identity-binding';
import { useAuthStore } from '@/stores/auth';
import { formatYuanOr } from '@/utils/format';
import {
  NButton,
  NDataTable,
  NForm,
  NFormItem,
  NInput,
  NInputNumber,
  NModal,
  NRadio,
  NRadioGroup,
  NSelect,
  NTag,
  useDialog,
  useMessage,
} from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

interface UserRow {
  id: string;
  username: string;
  uid: string;
  nickname: string;
  role: 'user' | 'worker';
  status: number;
  bannedUntil: string | null;
  level: number;
  balance: string;
  lastLoginAt: string | null;
  createdAt: string;
}

const auth = useAuthStore();
const message = useMessage();
const dialog = useDialog();
const loading = ref(false);
const rows = ref<UserRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const keyword = ref('');
const roleFilter = ref('');
/** 绑定状态筛选：all 全部 / bound 已绑定 / unbound 未绑定（选择后进入排查模式，见文件头注释） */
const bindState = ref<'all' | 'bound' | 'unbound'>('all');

// ---- 身份绑定装饰（当前页行内提示）----
const bindNotes = ref<Map<string, BindingNote>>(new Map());
/** 装饰请求是否成功：失败时列显示「—」而不是谎报「未绑定」 */
const bindReady = ref(false);

// ---- 排查模式（bindState ≠ all）：全量账号 + 全量生效绑定，本地比对 ----
const scanRows = ref<UserRow[]>([]);
const scanBoundIds = ref<Set<string>>(new Set());
const scanPage = ref(1);
const scanTruncated = ref(false);
const scanning = ref(false);
const scanMode = computed(() => bindState.value !== 'all');

const canBan = computed(() => auth.hasPermission('admin:user:ban'));
const canDelete = computed(() => auth.hasPermission('admin:user:delete'));

function fmt(v: string | null | undefined): string {
  if (!v) return '-';
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toLocaleString('zh-CN', { hour12: false });
}

/** 账号列表查询串（服务端分页与排查模式的逐页读取共用，避免两处拼参数走偏） */
function listQuery(p: number, ps: number): string {
  const params = new URLSearchParams({ page: String(p), pageSize: String(ps) });
  if (keyword.value) params.set('keyword', keyword.value);
  if (roleFilter.value) params.set('role', roleFilter.value);
  return params.toString();
}

async function decorate(list: UserRow[]) {
  bindNotes.value = new Map();
  bindReady.value = false;
  if (!list.length) {
    bindReady.value = true;
    return;
  }
  try {
    bindNotes.value = await fetchActiveBindingNotes(list.map((r) => r.id));
    bindReady.value = true;
  } catch {
    // 绑定信息只是"行内提示"：取不到不能拖垮账号列表（列显示「—」，不显示「未绑定」）
    bindReady.value = false;
  }
}

/** 排查模式：全量账号（≤500）+ 全量生效绑定 → 本地按绑定状态筛选 */
async function runScan() {
  scanning.value = true;
  try {
    const accounts = await fetchAllPages<UserRow>((p, ps) =>
      request<{ list: UserRow[]; total: number }>('GET', `/admin/users?${listQuery(p, ps)}`),
    );
    const bindings = await fetchAllActiveBindings();
    scanRows.value = accounts.rows;
    scanTruncated.value = accounts.truncated || bindings.truncated;
    scanBoundIds.value = boundUserIdSet(bindings.rows);
    scanPage.value = 1;
  } finally {
    scanning.value = false;
  }
}

async function load() {
  loading.value = true;
  try {
    if (scanMode.value) {
      await runScan();
      return;
    }
    const data = await request<{ list: UserRow[]; total: number }>('GET', `/admin/users?${listQuery(page.value, pageSize)}`);
    rows.value = data.list;
    total.value = data.total;
    await decorate(data.list);
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

// ---- 排查模式的数据源（本地筛选 + 本地分页；常规模式仍走服务端分页）----
const scanFiltered = computed(() =>
  scanRows.value.filter((r) =>
    bindState.value === 'bound' ? scanBoundIds.value.has(r.id) : !scanBoundIds.value.has(r.id),
  ),
);
const scanPageRows = computed(() =>
  scanFiltered.value.slice((scanPage.value - 1) * pageSize, scanPage.value * pageSize),
);
const tableData = computed(() => (scanMode.value ? scanPageRows.value : rows.value));
const tableItemCount = computed(() => (scanMode.value ? scanFiltered.value.length : total.value));
const tablePage = computed(() => (scanMode.value ? scanPage.value : page.value));

function changePage(p: number) {
  if (scanMode.value) {
    scanPage.value = p;
    return;
  }
  page.value = p;
  void load();
}
function search() {
  page.value = 1;
  scanPage.value = 1;
  void load();
}

// ---------- 封号 ----------
const banTarget = ref<UserRow | null>(null);
const showBan = ref(false);
const banMode = ref<'days' | 'permanent'>('days');
const banDays = ref<number | null>(7);
const banning = ref(false);

function openBan(row: UserRow) {
  banTarget.value = row;
  banMode.value = 'days';
  banDays.value = 7;
  showBan.value = true;
}

async function handleBan() {
  if (!banTarget.value) return;
  if (banMode.value === 'days' && (!banDays.value || banDays.value < 1)) {
    message.warning('请填写封禁天数（至少 1 天）');
    return;
  }
  banning.value = true;
  try {
    await request('POST', `/admin/users/${banTarget.value.id}/ban`, {
      days: banMode.value === 'permanent' ? null : banDays.value,
    });
    message.success(banMode.value === 'permanent' ? '已永久封禁' : `已封禁 ${banDays.value} 天`);
    showBan.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  } finally {
    banning.value = false;
  }
}

// ---------- 解封 ----------
async function handleUnban(row: UserRow) {
  try {
    await request('POST', `/admin/users/${row.id}/unban`);
    message.success(`「${row.username}」已解封`);
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

// ---------- 删除账号 ----------
function handleDelete(row: UserRow) {
  dialog.warning({
    title: '删除账号',
    content: `确定删除账号「${row.username}」？将删除其聊天、好友、余额等全部个人数据（历史订单与结算记录保留；玩家圈已于 2026-10-05 下线，其 forum_* 数据不再清理）。此操作不可恢复！`,
    positiveText: '确认删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/users/${row.id}`);
        message.success('账号已删除');
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

const roleOptions = [
  { label: '全部角色', value: '' },
  { label: '老板端', value: 'user' },
  { label: '工作端', value: 'worker' },
];

/** 绑定状态筛选（运营排查"谁还没绑"；选择后进入排查模式，见文件头注释） */
const bindStateOptions = [
  { label: '全部绑定状态', value: 'all' },
  { label: '已绑定', value: 'bound' },
  { label: '未绑定', value: 'unbound' },
];

/**
 * 行内绑定提示：
 * 老板行 → 「已绑定打手：王野（工号 MI109660A）· 绑定于 2026-10-06 14:20」
 * 打手行 → 「已绑定老板：小明（中文 ID 10001）· 绑定于 …」
 * 未绑定 → 「未绑定」；绑定信息读取失败 → 「—」（不谎报未绑定）
 */
function bindingCell(row: UserRow) {
  const note = bindNotes.value.get(row.id);
  if (note) {
    const label = row.role === 'worker' ? '已绑定老板' : '已绑定打手';
    return h('span', { class: 'bind-on' }, [
      `${label}：${note.peerName}（${note.peerSub}）`,
      h('span', { class: 'bind-sub' }, ` · 绑定于 ${fmt(note.boundAt)}`),
    ]);
  }
  if (!bindReady.value) return h('span', { class: 'bind-unknown', title: '绑定信息读取失败' }, '—');
  return h('span', { class: 'bind-off' }, '未绑定');
}

// 列宽和 = 115+130+110+80+240+60+110+170+150+150+150 = 1465
// ⚠️ 模板上的 :scroll-x 必须 ≥ 这个和（Naive UI 用它决定表格最小宽度）——改动任一列宽都要同步改 :scroll-x，
//    否则右侧列（尤其「操作」）会被裁掉（负责人 2026-10-08 反馈的「删除/封号被挤没了」根因）。
//    各列宽不是猜的：用无头 Edge 真量过内容行数（scripts/tools/verify-admin-table-actions.mjs）——
//    ID 列 100 时 "U9292195050" 会折成两行 → 定 115；身份绑定 220 时绑定行折 3 行 → 定 240；
//    余额列 90 放不下折算后的 "¥99,999.90"（元口径两位小数 + 千分位）→ 定 110。
const USER_COLUMNS_WIDTH = 1465;
const columns = computed(() => [
  { title: 'ID', key: 'uid', width: 115 },
  { title: '账号', key: 'username', width: 130 },
  { title: '昵称', key: 'nickname', width: 110 },
  {
    title: '角色', key: 'role', width: 80,
    render: (row: UserRow) =>
      h(NTag, { size: 'small', type: row.role === 'worker' ? 'info' : 'default' }, { default: () => (row.role === 'worker' ? '工作端' : '老板') }),
  },
  {
    // 240：绑定状态 + 打手名 + 工号 + 绑定时间放得下（原 280 偏宽，会挤掉右侧列）
    title: '身份绑定', key: 'binding', minWidth: 240,
    render: (row: UserRow) => bindingCell(row),
  },
  { title: '等级', key: 'level', width: 60, render: (row: UserRow) => (row.role === 'worker' ? '—' : `Lv.${row.level}`) },
  // 金额列：余额（元）→ ¥ + 两位小数；非金额列（等级/状态）不加 ¥
  { title: '余额', key: 'balance', width: 110, render: (row: UserRow) => formatYuanOr(row.balance) },
  {
    title: '状态', key: 'status', width: 170,
    render: (row: UserRow) =>
      row.status === 1
        ? h(NTag, { type: 'success', size: 'small' }, { default: () => '正常' })
        : h(NTag, { type: 'error', size: 'small' }, { default: () => (row.bannedUntil ? `封禁至 ${fmt(row.bannedUntil)}` : '永久封禁') }),
  },
  { title: '最近登录', key: 'lastLoginAt', width: 150, render: (row: UserRow) => fmt(row.lastLoginAt) },
  { title: '注册时间', key: 'createdAt', width: 150, render: (row: UserRow) => fmt(row.createdAt) },
  {
    // fixed:'right'：横向滚动时「封号/解封 + 删除」始终完整可见（负责人 2026-10-08 反馈的核心诉求）
    // 150：真量按钮 48+8+48=104 + 单元格左右内边距 24 = 128 → 150 有余量不折行
    title: '操作', key: 'actions', width: 150, fixed: 'right' as const,
    render: (row: UserRow) =>
      h('div', { style: 'display:flex;gap:8px' }, [
        row.status === 1
          ? h(NButton, { size: 'small', type: 'warning', quaternary: true, disabled: !canBan.value, onClick: () => openBan(row) }, { default: () => '封号' })
          : h(NButton, { size: 'small', type: 'success', quaternary: true, disabled: !canBan.value, onClick: () => handleUnban(row) }, { default: () => '解封' }),
        h(NButton, { size: 'small', type: 'error', quaternary: true, disabled: !canDelete.value, onClick: () => handleDelete(row) }, { default: () => '删除' }),
      ]),
  },
]);
</script>

<template>
  <div class="users-page">
    <div class="toolbar">
      <n-select v-model:value="roleFilter" :options="roleOptions" style="width: 130px" @update:value="search" />
      <n-select v-model:value="bindState" :options="bindStateOptions" style="width: 140px" @update:value="search" />
      <n-input v-model:value="keyword" placeholder="搜索账号/ID/昵称" style="width: 240px" clearable @keyup.enter="search" />
      <n-button @click="search">搜索</n-button>
    </div>

    <p v-if="scanMode" class="hint">
      绑定排查模式：已读取全部
      <strong>{{ scanRows.length }}</strong>
      个账号后按「{{ bindState === 'bound' ? '已绑定' : '未绑定' }}」在本地比对（服务端账号列表没有绑定维度，
      数据来自身份绑定只读接口）。清空该筛选即回到常规分页列表<template v-if="scanTruncated">；
      ⚠️ 账号数超过 500，本次只比对了前 500 个，请改用关键词缩小范围</template>。
    </p>
    <p v-else-if="rows.length && !bindReady" class="hint">身份绑定信息读取失败（不影响账号列表；可稍后刷新当前页重试）</p>

    <n-data-table
      :columns="columns"
      :data="tableData"
      :loading="loading || scanning"
      :scroll-x="USER_COLUMNS_WIDTH"
      :pagination="{
        page: tablePage,
        pageSize: pageSize,
        itemCount: tableItemCount,
        showSizePicker: false,
        onChange: (p: number) => changePage(p),
      }"
    />

    <p v-if="!canBan || !canDelete" class="hint">封号/解封与删除账号仅超级管理员可用</p>

    <n-modal v-model:show="showBan" preset="dialog" title="封禁账号" positive-text="确认封禁" negative-text="取消" :loading="banning" @positive-click="handleBan">
      <n-form label-placement="left" label-width="80">
        <n-form-item label="账号">
          <span>{{ banTarget?.username }}（{{ banTarget?.nickname }}）</span>
        </n-form-item>
        <n-form-item label="封禁方式">
          <n-radio-group v-model:value="banMode">
            <n-radio value="days">按天数封禁</n-radio>
            <n-radio value="permanent">永久封禁</n-radio>
          </n-radio-group>
        </n-form-item>
        <n-form-item v-if="banMode === 'days'" label="封禁天数">
          <n-input-number v-model:value="banDays" :min="1" :max="36500" style="width: 160px" />
        </n-form-item>
      </n-form>
      <p class="hint">封禁后该账号立即被踢下线，登录时弹窗显示封禁结束时间；到期自动解封</p>
      <!-- 与后端实际行为一致（server/src/modules/user/user-admin.service.ts ban()：调 BindingReleaseService.releaseBoth 释放**两侧**，响应回带 releasedBindings / releasedAsWorker / releasedAsBoss） -->
      <p class="hint warn">
        封禁会同时解除该账号<strong>两侧</strong>的身份绑定——不论它此刻是<strong>被老板绑着的打手</strong>，
        还是<strong>绑着打手的老板</strong>，两侧的生效绑定都会一起释放：
        绑定记录保留并置为「已解绑」，这些绑定下的打手态（伴随）会话立即失效；解封不会自动恢复绑定，需老板在老板端重新输入打手账密绑定。
      </p>
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
.hint {
  margin-top: 12px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
/* 封禁弹窗里的绑定后果提示：警示色 + 左竖线（发丝线，不用底色块，避免"整块彩色"的 AI 味） */
.hint.warn {
  padding-left: 10px;
  border-left: 2px solid var(--color-warning, #f59e0b);
  color: var(--color-text-secondary, #666a73);
  line-height: 1.75;
}
.hint strong {
  color: var(--color-text-primary, #17181a);
}
/* 行内绑定提示：已绑定=正文色，未绑定=次要色，读取失败=更淡（三态可区分，不靠彩色小标签） */
.bind-on {
  font-size: 12.5px;
  color: var(--color-text-primary, #17181a);
}
.bind-sub {
  color: var(--color-text-tertiary, #9ca0a8);
}
.bind-off {
  font-size: 12.5px;
  color: var(--color-text-secondary, #666a73);
}
.bind-unknown {
  color: var(--color-text-tertiary, #9ca0a8);
}
</style>
