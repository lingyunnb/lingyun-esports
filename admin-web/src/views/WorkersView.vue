<script setup lang="ts">
// 阶段 9：工作端管理（docs/04）
// - 创建工作端账号（默认无接单/客服权限）
// - **接单权限按分部勾选**（负责人 2026-10-04：和平 / 三角洲手游 / 三角洲端游 各自独立；
//   勾选任意一个 → 汇总为「有接单权限」，全不勾 → 无接单权限；服务端每次请求实时校验）
// - 客服权限与接单权限完全独立（高风险操作二次确认；权限点 admin:worker:permission 默认仅超管）
// - 陪玩介绍（负责人 2026-10-03 硬规则）：'找陪玩' 列表只显示 名字 + 介绍，介绍由管理端在此填写
// - 身份绑定（负责人 2026-10-06 身份合并方案甲）：行内显示「被哪个老板绑定 / 未绑定」，
//   数据来自只读接口 GET /admin/identity-bindings（当前页 20 个工号一次批量取，见 src/api/identity-binding.ts）；
//   「绑定状态」筛选走**排查模式**（服务端工作端列表没有绑定维度）：一次性读全量打手 + 全量生效绑定后本地比对。
// - **调整展示数据**（负责人 2026-10-16）：接单次数 + 好评率可由管理端设「展示值」，未设 = 跟随真实；
//   **评价内容一律真实**（本页不提供任何评价编辑入口）。编辑窗是
//   `components/WorkerDisplayStatsModal.vue`（真实值 / 展示值 / 最终生效值三分区）；
//   权限点 `worker:adjust`（服务端只授 super_admin）→ 非超管**按钮禁用 + 页面整行提示**（不是隐藏按钮），
//   接口 403 另有兜底提示（见弹窗内的 loadError 与保存失败分支）。
import { ApiException, request } from '@/api/client';
import {
  boundUserIdSet,
  fetchActiveBindingNotes,
  fetchAllActiveBindings,
  fetchAllPages,
  type BindingNote,
} from '@/api/identity-binding';
import WorkerDisplayStatsModal from '@/components/WorkerDisplayStatsModal.vue';
import WorkerRatingManualModal from '@/components/WorkerRatingManualModal.vue'
import { useAuthStore } from '@/stores/auth';
import {
  NButton,
  NDataTable,
  NForm,
  NFormItem,
  NInput,
  NModal,
  NPopconfirm,
  NSelect,
  NSwitch,
  NTag,
  NTooltip,
  useMessage,
} from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface WorkerRow {
  /** 工作端档案 id（worker.id）—— 权限接口 /admin/workers/:id/permission 用的是它 */
  id: string;
  /**
   * 账号 id（user.id）——**身份绑定用的是它**（worker_identity_binding.worker_user_id 指向 user.id）。
   * 两个 id 不是一回事：早期把 id 当 userId 用会让绑定提示永远显示「未绑定」（实测踩过）。
   */
  userId: string;
  username: string;
  uid: string;
  nickname: string;
  workerNo: string;
  realName: string | null;
  phone: string | null;
  canTakeOrder: number;
  canServeCustomer: number;
  status: number;
  createdAt: string;
  /** 陪玩介绍（客户端「找陪玩」列表正文，管理端填写） */
  intro?: string;
  /** 归属分部 id（展示用；接单范围由 divisionPermissionIds 决定） */
  divisionId?: string | null;
  /** 已授予接单权限的分部 id 列表（服务端返回，写操作后回读刷新） */
  divisionPermissionIds?: string[];
}

const auth = useAuthStore();
const message = useMessage();
const loading = ref(false);
const rows = ref<WorkerRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const keyword = ref('');
/** 绑定状态筛选：all 全部 / bound 已绑定 / unbound 未绑定（选择后进入排查模式） */
const bindState = ref<'all' | 'bound' | 'unbound'>('all');

// ---- 身份绑定装饰（当前页行内提示）----
const bindNotes = ref<Map<string, BindingNote>>(new Map());
/** 装饰请求是否成功：失败时列显示「—」而不是谎报「未绑定」 */
const bindReady = ref(false);

// ---- 排查模式（bindState ≠ all）：全量打手 + 全量生效绑定，本地比对 ----
const scanRows = ref<WorkerRow[]>([]);
const scanBoundIds = ref<Set<string>>(new Set());
const scanPage = ref(1);
const scanTruncated = ref(false);
const scanning = ref(false);
const scanMode = computed(() => bindState.value !== 'all');

const canGrantPermission = computed(() => auth.hasPermission('admin:worker:permission'));

// ---------- 调整展示数据（接单次数 / 好评率；`worker:adjust` 服务端只授 super_admin）----------
/**
 * 只做**前端**判定（超管自动为 true）：真正能不能改由服务端 403 说了算。
 * 无权限时**不隐藏按钮** —— 按钮禁用 + tooltip + 页面整行提示，三处都说清楚"需要超管权限"。
 */
const canAdjustDisplay = computed(() => auth.hasPermission('worker:adjust'));
const showDisplayStats = ref(false);
const displayStatsRow = ref<WorkerRow | null>(null);
function openDisplayStats(row: WorkerRow) {
  displayStatsRow.value = row;
  showDisplayStats.value = true;
}
/** 展示值只影响客户端展示，**列表本身不回显**（否则每行一次请求 = N+1）→ 保存后只给提示 */
function onDisplayStatsSaved() {
  message.success('展示数据已保存（客户端下一次请求即生效，改动已写操作日志）');
}

/** 六维评分手填（只影响展示；权限点复用 worker:write，与打手管理同权限） */
const canEditRating = computed(() => auth.hasPermission('worker:write'))
const showRating = ref(false)
const ratingRow = ref<WorkerRow | null>(null)
function openRating(row: WorkerRow) {
  ratingRow.value = row
  showRating.value = true
}

/** 绑定状态筛选（运营排查"哪些打手还没被绑"；选择后进入排查模式） */
const bindStateOptions = [
  { label: '全部绑定状态', value: 'all' },
  { label: '已绑定', value: 'bound' },
  { label: '未绑定', value: 'unbound' },
];

/** 工作端列表查询串（服务端分页与排查模式逐页读取共用） */
function listQuery(p: number, ps: number): string {
  return `page=${p}&pageSize=${ps}&keyword=${encodeURIComponent(keyword.value)}`;
}

async function decorate(list: WorkerRow[]) {
  bindNotes.value = new Map();
  bindReady.value = false;
  if (!list.length) {
    bindReady.value = true;
    return;
  }
  try {
    bindNotes.value = await fetchActiveBindingNotes(list.map((r) => r.userId));
    bindReady.value = true;
  } catch {
    // 行内提示取不到不影响列表本身（列显示「—」，不显示「未绑定」）
    bindReady.value = false;
  }
}

/** 排查模式：全量打手（≤500）+ 全量生效绑定 → 本地按绑定状态筛选 */
async function runScan() {
  scanning.value = true;
  try {
    const workers = await fetchAllPages<WorkerRow>((p, ps) =>
      request<{ list: WorkerRow[]; total: number }>('GET', `/admin/workers?${listQuery(p, ps)}`),
    );
    const bindings = await fetchAllActiveBindings();
    scanRows.value = workers.rows;
    scanTruncated.value = workers.truncated || bindings.truncated;
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
    const data = await request<{ list: WorkerRow[]; total: number }>('GET', `/admin/workers?${listQuery(page.value, pageSize)}`);
    rows.value = data.list;
    total.value = data.total;
    await decorate(data.list);
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(async () => {
  await Promise.all([load(), loadDivisions()]);
});

// ---- 排查模式的数据源（本地筛选 + 本地分页；常规模式仍走服务端分页）----
const scanFiltered = computed(() =>
  scanRows.value.filter((r) =>
    bindState.value === 'bound' ? scanBoundIds.value.has(r.userId) : !scanBoundIds.value.has(r.userId),
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

/**
 * 行内绑定提示：打手行 = 被哪个老板绑定
 * 「已绑定老板：小明（中文 ID 10001）· 绑定于 2026-10-06 14:20」/「未绑定」/「—」（读取失败）
 */
function bindingCell(row: WorkerRow) {
  // 绑定备注按 **user.id** 建索引（worker_identity_binding.worker_user_id 指向 user.id，不是 worker.id）
  const note = bindNotes.value.get(row.userId);
  if (note) {
    return h('span', { class: 'bind-on' }, [
      `已绑定老板：${note.peerName}（${note.peerSub}）`,
      h('span', { class: 'bind-sub' }, ` · 绑定于 ${fmt(note.boundAt)}`),
    ]);
  }
  if (!bindReady.value) return h('span', { class: 'bind-unknown', title: '绑定信息读取失败' }, '—');
  return h('span', { class: 'bind-off' }, '未绑定');
}

function fmt(v: string | null | undefined): string {
  if (!v) return '-';
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toLocaleString('zh-CN', { hour12: false });
}

// 新建工作端
const showCreate = ref(false);
const createForm = reactive({ username: '', password: '', workerNo: '', nickname: '', phone: '' });
const creating = ref(false);
async function handleCreate() {
  if (!createForm.username || createForm.password.length < 8 || !createForm.workerNo) {
    message.warning('请填写账号（密码至少 8 位）与工号');
    return;
  }
  creating.value = true;
  try {
    await request('POST', '/admin/workers', { ...createForm });
    message.success('工作端账号已创建（默认无接单/客服权限）');
    showCreate.value = false;
    Object.assign(createForm, { username: '', password: '', workerNo: '', nickname: '', phone: '' });
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '创建失败');
  } finally {
    creating.value = false;
  }
}

/**
 * 权限开关（独立、二次确认、操作留痕在服务端）
 *
 * - 客服权限：全局开关，不区分分部
 * - 接单权限：**按分部**（divisionId）；勾选任意一个 → 服务端把汇总位 canTakeOrder 置 1，全不勾 → 0
 */
async function togglePermission(
  row: WorkerRow,
  type: 'take_order' | 'customer',
  value: boolean,
  divisionId?: string,
) {
  const divName = divisionOptions.value.find((d) => d.value === divisionId)?.label ?? '';
  try {
    await request('POST', `/admin/workers/${row.id}/permission`, {
      type,
      value,
      ...(type === 'take_order' && divisionId ? { divisionId } : {}),
    });
    message.success(
      type === 'take_order'
        ? `「${divName || '该分部'}」接单权限已${value ? '授予' : '取消'}（立即生效）`
        : `客服权限已${value ? '授予' : '取消'}`,
    );
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

/** 接单权限汇总文案（服务端派生值 canTakeOrder 的口语化展示） */
function takeOrderSummary(row: WorkerRow): string {
  const n = (row.divisionPermissionIds ?? []).length;
  if (n === 0) return row.canTakeOrder === 1 ? '已授权（汇总位 1，但无分部明细）' : '无接单权限（大厅不可见）';
  return `已授权 ${n} 个分部`;
}

// ---------- 陪玩介绍（客户端「找陪玩」列表的正文；介绍写 user.intro） ----------
const showIntro = ref(false);
const introSaving = ref(false);
const introRow = ref<WorkerRow | null>(null);
const introForm = reactive({ intro: '', divisionId: '' as string | null });
/** 分部选项：label 用完整名（下拉选择），short 用「简称 · 平台」（表格里的分部开关用） */
const divisionOptions = ref<{ label: string; value: string; short: string }[]>([]);
const canEditIntro = computed(() => auth.hasPermission('admin:worker:write'));

async function loadDivisions() {
  try {
    // 公开分部接口（上架分部）即可满足选择需要，无需额外权限点
    const list = await request<{ id: string; name: string; shortName: string; platformLabel: string }[]>('GET', '/divisions');
    divisionOptions.value = (list ?? []).map((d) => ({
      label: d.name,
      value: d.id,
      short: `${d.shortName || d.name}${d.platformLabel ? ` · ${d.platformLabel}` : ''}`,
    }));
  } catch {
    divisionOptions.value = [];
  }
}

function openIntro(row: WorkerRow) {
  introRow.value = row;
  // 只带入展示用字段；提交时显式构造 payload（绝不回传整行对象）
  Object.assign(introForm, { intro: row.intro ?? '', divisionId: row.divisionId ?? null });
  showIntro.value = true;
}

async function saveIntro() {
  const row = introRow.value;
  if (!row) return;
  introSaving.value = true;
  try {
    // 只提交该接口声明过的字段：介绍 + 归属分部
    await request('PUT', `/admin/workers/${row.id}/players-profile`, {
      intro: introForm.intro,
      divisionId: introForm.divisionId ?? '',
    });
    message.success('介绍已保存（客户端「找陪玩」刷新后更新）');
    showIntro.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    introSaving.value = false;
  }
}

const columns = computed(() => [
  // 列宽和 = 90+130+120+240+250+110+250 = 1280，再加本轮新增的「展示数据」120 = **1400**
  // ⚠️ 模板 :scroll-x 必须 ≥ 这个和（原 1320 是按「陪玩介绍」弹性列 250 估的，改成定宽 250 后精确定为 1280）。
  //    身份绑定 280 → 240 与「用户管理」页同口径（原 280 偏宽会挤掉右侧列）。
  { title: '工号', key: 'workerNo', width: 90 },
  { title: '账号', key: 'username', width: 130 },
  { title: '昵称', key: 'nickname', width: 120 },
  {
    title: '身份绑定', key: 'binding', minWidth: 240,
    render: (row: WorkerRow) => bindingCell(row),
  },
  {
    title: '接单权限（按分部）',
    key: 'canTakeOrder',
    width: 250,
    render: (row: WorkerRow) =>
      h('div', { style: 'display:flex;flex-direction:column;gap:2px;padding:4px 0' }, [
        ...divisionOptions.value.map((d) =>
          h(
            'label',
            {
              style: 'display:flex;align-items:center;gap:6px;font-size:12px;color:#475569;cursor:pointer',
            },
            [
              h(NSwitch, {
                size: 'small',
                value: (row.divisionPermissionIds ?? []).includes(d.value),
                disabled: !canGrantPermission.value,
                onUpdateValue: (v: boolean) => togglePermission(row, 'take_order', v, d.value),
              }),
              h('span', null, d.short),
            ],
          ),
        ),
        h('span', { style: 'font-size:11px;color:#94a3b8' }, takeOrderSummary(row)),
      ]),
  },
  {
    title: '客服权限',
    key: 'canServeCustomer',
    width: 110,
    render: (row: WorkerRow) =>
      h(NSwitch, {
        value: row.canServeCustomer === 1,
        disabled: !canGrantPermission.value,
        onUpdateValue: (v: boolean) => togglePermission(row, 'customer', v),
      }),
  },
  {
    // 「调整展示数据」（负责人 2026-10-16）：接单次数 / 好评率的**展示值**由管理端设置
    // （评价内容一律真实，本列不涉及评价）。紧挨「陪玩介绍」放在 fixed:'right' 一侧：
    // 两块操作按钮在横向滚动时都完整可见。
    // 无权限（非超管）→ **按钮禁用 + tooltip 说明**（不隐藏：页面上另有一整行提示）。
    title: '展示数据',
    key: 'displayStats',
    width: 120,
    fixed: 'right' as const,
    render: (row: WorkerRow) =>
      h(
        NTooltip,
        { trigger: 'hover', delay: 120 },
        {
          // 触发器套一层 span：禁用的按钮在部分浏览器里收不到 hover，套 span 才保证 tooltip 出得来。
          // 用**内联样式**（不是 scoped 类名）：这段 vnode 是 n-data-table 渲染期才创建的，
          // 拿不到本组件的 scopeId，类名会静默失效（同一列里其它样式也都用内联，就是这个原因）。
          trigger: () => h('span', { style: 'display:inline-flex' }, [
            h(
              NButton,
              {
                size: 'tiny',
                disabled: !canAdjustDisplay.value,
                onClick: () => openDisplayStats(row),
              },
              { default: () => '调整展示数据' },
            ),
          ]),
          default: () =>
            canAdjustDisplay.value
              ? '设置接单次数与好评率的对外展示值（未设 = 跟随真实）'
              : '需要超管权限（worker:adjust）',
        },
      ),
  },
  {
    // 「六维评分」（负责人 2026-10-18）：老板评价是自愿的，无评价时陪玩主页六轴全 `--`，
    // 运营需要一个只影响展示的手填通道。紧挨「展示数据」放 fixed:'right' 一侧。
    // ⚠️ 等级判定只读真实聚合数据，手填值不参与升级（弹窗内也有同样的说明）。
    title: '六维评分',
    key: 'ratingManual',
    width: 110,
    fixed: 'right' as const,
    render: (row: WorkerRow) =>
      h(
        NTooltip,
        { trigger: 'hover', delay: 120 },
        {
          trigger: () => h('span', { style: 'display:inline-flex' }, [
            h(
              NButton,
              { size: 'tiny', disabled: !canEditRating.value, onClick: () => openRating(row) },
              { default: () => '编辑六维' },
            ),
          ]),
          default: () =>
            canEditRating.value ? '手填六维评分（只影响展示，不影响等级）' : '需要 worker:write 权限',
        },
      ),
  },
  {
    // 「陪玩介绍」是本页唯一带操作按钮（编辑介绍）的列 → 定宽 250 + fixed:'right'：
    // 横向滚动时按钮始终完整可见（原先它是弹性列，窄屏下按钮会跑到视野外）
    title: '陪玩介绍',
    key: 'intro',
    width: 250,
    fixed: 'right' as const,
    render: (row: WorkerRow) =>
      h(
        'div',
        { style: 'display:flex;align-items:center;gap:8px' },
        [
          h(
            'span',
            { style: 'font-size:12px;color:#64748b;max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap' },
            row.intro ? row.intro : '未填写',
          ),
          canEditIntro.value
            ? h(NButton, { size: 'tiny', onClick: () => openIntro(row) }, { default: () => '编辑介绍' })
            : null,
        ].filter(Boolean),
      ),
  },
  {
    title: '状态',
    key: 'status',
    width: 90,
    render: (row: WorkerRow) =>
      row.status === 1 ? h(NTag, { type: 'success', size: 'small' }, { default: () => '在职' }) : h(NTag, { type: 'default', size: 'small' }, { default: () => '停用' }),
  },
]);
</script>

<template>
  <div class="workers-page">
    <div class="toolbar">
      <n-select v-model:value="bindState" :options="bindStateOptions" style="width: 140px" @update:value="search" />
      <n-input v-model:value="keyword" placeholder="搜索账号/昵称/工号" style="width: 240px" clearable @keyup.enter="search" />
      <n-button @click="search">搜索</n-button>
      <div class="spacer" />
      <n-button v-if="auth.hasPermission('admin:worker:write')" type="primary" @click="showCreate = true">新建工作端</n-button>
    </div>

    <p v-if="scanMode" class="hint">
      绑定排查模式：已读取全部
      <strong>{{ scanRows.length }}</strong>
      个打手账号后按「{{ bindState === 'bound' ? '已绑定' : '未绑定' }}」在本地比对（数据来自身份绑定只读接口）。
      清空该筛选即回到常规分页列表<template v-if="scanTruncated">；⚠️ 账号数超过 500，本次只比对了前 500 个</template>。
    </p>
    <p v-else-if="rows.length && !bindReady" class="hint">身份绑定信息读取失败（不影响打手列表；可稍后刷新当前页重试）</p>

    <n-data-table
      :columns="columns"
      :data="tableData"
      :loading="loading || scanning"
      :scroll-x="1400"
      :pagination="{
        page: tablePage,
        pageSize: pageSize,
        itemCount: tableItemCount,
        showSizePicker: false,
        onChange: (p: number) => changePage(p),
      }"
    />

    <p v-if="!canAdjustDisplay" class="adjust-perm-note">
      调整展示数据需要<b>超管权限</b>（权限点 <code>worker:adjust</code>）：当前账号不能改这两个对外数字，
      列表里的「调整展示数据」按钮已<b>禁用</b>（不是隐藏）。即便绕过前端，服务端也会以 403 拒绝该接口
      —— 前端只做提示，权限以服务端为准。
    </p>
    <p class="hint">
      展示数据口径：只有<b>接单次数</b>与<b>好评率</b>可由管理端设「展示值」，<b>未设 = 跟随真实</b>（不是 0）；
      <b>评价内容一律真实</b>，管理端不提供任何评价编辑入口。
    </p>

    <p v-if="!canGrantPermission" class="hint">权限开关需要 admin:worker:permission 权限点（默认仅超级管理员持有）</p>
    <p v-else class="hint">
      接单权限按分部授予：勾选任意一个分部即为「有接单权限」（汇总位自动置 1），全不勾即为无接单权限；
      改动立即生效（服务端每次请求实时查库），并写操作日志留痕。
    </p>

    <n-modal v-model:show="showCreate" preset="dialog" title="新建工作端账号" positive-text="创建" negative-text="取消" :loading="creating" @positive-click="handleCreate">
      <n-form label-placement="left" label-width="80">
        <n-form-item label="账号"><n-input v-model:value="createForm.username" placeholder="登录账号（字母数字下划线）" /></n-form-item>
        <n-form-item label="密码"><n-input v-model:value="createForm.password" type="password" placeholder="至少 8 位" /></n-form-item>
        <n-form-item label="工号"><n-input v-model:value="createForm.workerNo" placeholder="唯一工号" /></n-form-item>
        <n-form-item label="昵称"><n-input v-model:value="createForm.nickname" placeholder="可选" /></n-form-item>
        <n-form-item label="电话"><n-input v-model:value="createForm.phone" placeholder="可选" /></n-form-item>
      </n-form>
      <p class="hint">创建后默认无接单与客服权限，由超级管理员在列表中授予</p>
    </n-modal>

    <n-modal
      v-model:show="showIntro"
      preset="card"
      style="width: 560px"
      :title="`陪玩介绍 · ${introRow?.nickname ?? introRow?.username ?? ''}`"
    >
      <n-form label-placement="left" label-width="90">
        <n-form-item label="介绍">
          <n-input
            v-model:value="introForm.intro"
            type="textarea"
            :rows="4"
            maxlength="200"
            show-count
            placeholder="客户端「找陪玩」列表正文，例如：三角洲行动端游护航，22:00-次日 3:00 在线，不接急单"
          />
        </n-form-item>
        <n-form-item label="归属分部">
          <n-select v-model:value="introForm.divisionId" :options="divisionOptions" clearable placeholder="可不填" />
        </n-form-item>
      </n-form>
      <p class="hint">
        归属分部只用于展示与「找陪玩」归属；能否接某个分部的单由上面「接单权限（按分部）」决定，
        两者互不联动（避免误授权）。
      </p>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:10px">
          <n-button @click="showIntro = false">取消</n-button>
          <n-button type="primary" :loading="introSaving" @click="saveIntro">保存</n-button>
        </div>
      </template>
    </n-modal>

    <!-- 调整展示数据（接单次数 / 好评率；评价内容一律真实，本窗不含评价编辑） -->
    <worker-display-stats-modal
      v-model:show="showDisplayStats"
      :worker-id="displayStatsRow?.id ?? null"
      :worker-label="displayStatsRow ? `${displayStatsRow.nickname || displayStatsRow.username}（工号 ${displayStatsRow.workerNo}）` : ''"
      @saved="onDisplayStatsSaved"
    />
  <!-- 六维评分（手填；只影响展示，不影响等级判定） -->
  <worker-rating-manual-modal
    v-model:show="showRating"
    :worker-id="ratingRow?.id ?? ''"
    :worker-name="ratingRow?.nickname ?? ''"
    @saved="() => message.success('六维评分已保存')"
  />
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
/*
 * 缺权限说明（本轮新增）：接单/好评率的展示值只有超管能改。
 * 用**浅琥珀底一行说明**而不是"把按钮藏起来" —— 能力不可用就要在界面上说清楚（与充值页同姿势）。
 * 色值读 token（`--color-gold-soft`，深浅两档都有值），不写死十六进制。
 */
.adjust-perm-note {
  margin: 12px 0 0;
  padding: 8px 12px;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--color-text-secondary);
  background: var(--color-gold-soft);
  border-radius: var(--radius-tag);
}
.adjust-perm-note code {
  font-size: 12px;
  color: var(--color-text-primary);
}
</style>
