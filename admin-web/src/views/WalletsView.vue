<script setup lang="ts">
// 阶段 10：余额管理（docs/06）
// - 钱包列表 + 发放/回收（admin:wallet:grant 默认仅超管；金额服务端校验；幂等键由前端生成、重试复用）
// - 余额流水（分页 + 类型过滤）
//
// 口径（负责人 2026-10-09）：计价单位从「积分（1 元 = 10 积分）」改为「余额（1 元 = 1 元）」，
// 存量金额由服务端按 10:1 折算（API 字段名不变）→ 本页所有金额一律 `¥` + 两位小数（统一走 @/utils/format）。
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr, formatYuanSigned } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import { NButton, NDataTable, NInput, NInputNumber, NModal, NSelect, NTabPane, NTabs, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface WalletRow {
  id: string;
  userId: string;
  balance: number;
  username: string;
  uid: string;
  nickname: string;
  role: string;
  level: number;
  totalSpent: number;
  updatedAt: string;
}

interface TxnRow {
  id: string;
  transactionNo: string;
  userId: string;
  username: string;
  changeType: string;
  amount: number;
  balanceBefore: number;
  balanceAfter: number;
  reason: string | null;
  createdAt: string;
}

const CHANGE_LABEL: Record<string, { label: string; type: 'success' | 'error' | 'default' | 'warning' }> = {
  grant: { label: '发放', type: 'success' },
  recover: { label: '回收', type: 'error' },
  order_pay: { label: '下单扣款', type: 'default' },
  order_refund: { label: '退款', type: 'warning' },
  // 余额差额补记（负责人 2026-10-04 平台账户账本补平；change_type 枚举扩展见 docs/06）
  balance_adjust: { label: '差额补记', type: 'warning' },
};

const auth = useAuthStore();
const message = useMessage();
const loading = ref(false);
const wallets = ref<WalletRow[]>([]);
const wTotal = ref(0);
const wPage = ref(1);
const wKeyword = ref('');
const txns = ref<TxnRow[]>([]);
const tTotal = ref(0);
const tPage = ref(1);
const tType = ref<string | null>(null);

const canGrant = computed(() => auth.hasPermission('admin:wallet:grant'));
const canLevel = computed(() => auth.hasPermission('admin:user:level'));

// 5 级会员视觉体系（需求 #9）：与 App 端配色一致
const LEVELS: Record<number, { label: string; color: string; bg: string; icon: string }> = {
  1: { label: '初识会员', color: '#8A94A6', bg: '#F1F3F7', icon: '☆' },
  2: { label: '知交会员', color: '#3D9BE9', bg: '#EAF5FE', icon: '★' },
  3: { label: '尊享会员', color: '#E8A23A', bg: '#FDF3E3', icon: '★' },
  4: { label: '臻享会员', color: '#8B5CF6', bg: '#F3EEFE', icon: '◆' },
  5: { label: '至尊会员', color: '#E5484D', bg: '#FDECEA', icon: '♛' },
};

// 等级调整（admin:user:level 默认仅超管；后端写 user_level_log + 操作日志）
const showLevel = ref(false);
const levelForm = reactive({ userId: '', username: '', level: 1, reason: '' });
const levelLoading = ref(false);
function openLevel(row: WalletRow) {
  Object.assign(levelForm, { userId: row.userId, username: row.username, level: Math.max(1, row.level || 1), reason: '' });
  showLevel.value = true;
}
async function handleLevel() {
  if (!levelForm.reason.trim()) { message.warning('请填写调整原因（留痕审计）'); return; }
  levelLoading.value = true;
  try {
    await request('POST', `/admin/users/${levelForm.userId}/level`, { level: levelForm.level, reason: levelForm.reason });
    message.success('等级已调整（已写入审计日志）');
    showLevel.value = false;
    await loadWallets();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '调整失败');
  } finally {
    levelLoading.value = false;
  }
}

async function loadWallets() {
  loading.value = true;
  try {
    const data = await request<{ list: WalletRow[]; total: number }>(
      'GET',
      `/admin/wallets?page=${wPage.value}&pageSize=20&keyword=${encodeURIComponent(wKeyword.value)}`,
    );
    wallets.value = data.list;
    wTotal.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

async function loadTxns() {
  try {
    const q = new URLSearchParams({ page: String(tPage.value), pageSize: '20' });
    if (tType.value) q.set('changeType', tType.value);
    const data = await request<{ list: TxnRow[]; total: number }>('GET', `/admin/wallet-transactions?${q.toString()}`);
    txns.value = data.list;
    tTotal.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}
onMounted(() => { loadWallets(); loadTxns(); });

// 发放/回收弹窗
const showOp = ref(false);
const opForm = reactive({ userId: '', username: '', action: 'grant' as 'grant' | 'recover', amount: 100, reason: '', idempotencyKey: '' });
const opLoading = ref(false);
function openOp(row: WalletRow, action: 'grant' | 'recover') {
  Object.assign(opForm, { userId: row.userId, username: row.username, action, amount: 100, reason: '', idempotencyKey: crypto.randomUUID() });
  showOp.value = true;
}
async function handleOp() {
  if (!(opForm.amount > 0)) { message.warning('请输入正确金额'); return; }
  opLoading.value = true;
  try {
    const resp = await request<{ duplicated?: boolean; balanceBefore: number; balanceAfter: number }>(
      'POST',
      `/admin/wallets/${opForm.action}`,
      { userId: opForm.userId, amount: opForm.amount, reason: opForm.reason || undefined, idempotencyKey: opForm.idempotencyKey },
    );
    message.success(
      resp.duplicated
        ? '该请求已处理过（幂等），未重复入账'
        : `${opForm.action === 'grant' ? '发放' : '回收'}成功：${formatYuan(resp.balanceBefore)} → ${formatYuan(resp.balanceAfter)}`,
    );
    showOp.value = false;
    await loadWallets();
    await loadTxns();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  } finally {
    opLoading.value = false;
  }
}

const walletColumns = computed(() => [
  { title: '账号', key: 'username', width: 130 },
  { title: 'ID', key: 'uid', width: 120 },
  { title: '昵称', key: 'nickname', width: 120 },
  {
    title: '等级',
    key: 'level',
    width: 110,
    render: (row: WalletRow) => {
      // 工作端无会员体系（负责人指令）：不展示等级徽章
      if (row.role === 'worker') {
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '—');
      }
      const m = LEVELS[row.level] ?? LEVELS[1];
      /**
       * 等级徽章（2026-10-11 深色外壳适配 → 2026-10-11 浅色为默认档）：
       * **等级色与文案一个都没改**，只是把"这一档的底色/字色"换成两个 CSS 变量再给出原值作兜底。
       * 为什么必须在这一层换变量：内联样式优先级高于任何选择器，光加 CSS 规则救不回来。
       *   · 深色档 → `html[data-theme='dark']` 的 `--lvl-bg` / `--lvl-fg`（品牌柔底 + 提亮字色）；
       *   · **浅色档 → `:root` 的 `--lvl-N-bg` / `--lvl-N-fg`**（2026-10-11 实测：5 档里有 4 档
       *     压在白底柔底上不到 AA —— L3 #E8A23A 只有 1.98:1。同色相压深一档后 4.6–6.3:1，
       *     级别用字「★ L3 尊享会员」与五档语义**逐字未动**）。
       */
      const lvl = row.level >= 1 && row.level <= 5 ? row.level : 1;
      return h('span', {
        class: 'lvl-badge',
        style: `display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:10px;background:var(--lvl-bg, var(--lvl-${lvl}-bg, ${m.bg}));color:var(--lvl-fg, var(--lvl-${lvl}-fg, ${m.color}));font-weight:600;font-size:12px`,
      }, `${m.icon} L${row.level} ${m.label}`);
    },
  },
  // 金额列统一 ¥ + 两位小数（余额是「元」口径，不再有「积分」）
  { title: '累计消费', key: 'totalSpent', width: 110, render: (row: WalletRow) => formatYuanOr(row.totalSpent) },
  {
    title: '余额',
    key: 'balance',
    width: 110,
    render: (row: WalletRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.balance)),
  },
  ...(canGrant.value || canLevel.value
    ? [{
        // 列宽和 = 130+120+120+110+110+110+240 = 940（操作列可能整列不渲染，scroll-x 仍按含它取值）
        // 最多同时 3 个按钮（发放/回收/调级，真量 160px）→ 240 放得下不折行；fixed:'right' 保证滚动时可见
        title: '操作',
        key: 'actions',
        width: 240,
        fixed: 'right' as const,
        render: (row: WalletRow) => h('div', { style: 'display:flex;gap:8px' }, [
          ...(canGrant.value ? [
            h(NButton, { size: 'small', type: 'primary', onClick: () => openOp(row, 'grant') }, { default: () => '发放' }),
            h(NButton, { size: 'small', onClick: () => openOp(row, 'recover') }, { default: () => '回收' }),
          ] : []),
          ...(canLevel.value && row.role !== 'worker' ? [
            h(NButton, { size: 'small', type: 'warning', onClick: () => openLevel(row) }, { default: () => '调级' }),
          ] : []),
        ]),
      }]
    : []),
]);

const txnColumns = [
  // 列宽和 = 200+110+100+110+110+110+170 = 910（+「原因」弹性列 200）→ 模板 :scroll-x = 1110
  { title: '流水号', key: 'transactionNo', width: 200 },
  { title: '用户', key: 'username', width: 110 },
  {
    title: '类型',
    key: 'changeType',
    width: 100,
    render: (row: TxnRow) => {
      const m = CHANGE_LABEL[row.changeType] ?? { label: row.changeType, type: 'default' as const };
      return h(NTag, { size: 'small', type: m.type }, { default: () => m.label });
    },
  },
  {
    title: '金额',
    key: 'amount',
    width: 110,
    render: (row: TxnRow) =>
      h('span', { style: `color: ${row.amount > 0 ? 'var(--color-success)' : 'var(--color-error)'}` }, formatYuanSigned(row.amount)),
  },
  { title: '前余额', key: 'balanceBefore', width: 110, render: (row: TxnRow) => formatYuanOr(row.balanceBefore) },
  { title: '后余额', key: 'balanceAfter', width: 110, render: (row: TxnRow) => formatYuanOr(row.balanceAfter) },
  { title: '原因', key: 'reason', ellipsis: true },
  { title: '时间', key: 'createdAt', width: 170, render: (row: TxnRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
];
</script>

<template>
  <div class="wallets-page">
    <n-tabs type="line" @update:value="(v: string) => (v === 'txns' ? loadTxns() : loadWallets())">
      <n-tab-pane name="wallets" tab="钱包">
        <div class="toolbar">
          <n-input v-model:value="wKeyword" placeholder="搜索账号/ID/昵称" style="width: 240px" @keyup.enter="wPage = 1; loadWallets()" />
          <n-button @click="wPage = 1; loadWallets()">搜索</n-button>
        </div>
        <n-data-table
          :columns="walletColumns"
          :data="wallets"
          :loading="loading"
          :pagination="{ page: wPage, pageSize: 20, itemCount: wTotal, onChange: (p: number) => { wPage = p; loadWallets(); } }"
          :scroll-x="940"
        />
        <p v-if="!canGrant" class="hint">发放/回收需要 admin:wallet:grant 权限点（默认仅超级管理员持有）</p>
        <!-- 合规口径（不可放宽）：余额只能平台内消费，不能提现/转让；平台不经手资金 -->
        <p class="hint">余额仅可用于平台内消费，<strong>不可提现、不可转让</strong>；平台不提供在线支付、不经手资金（充值走「线下扫码 + 上传截图 + 人工核对发放」）。</p>
      </n-tab-pane>
      <n-tab-pane name="txns" tab="余额流水">
        <div class="toolbar">
          <n-select v-model:value="tType" :options="[
            { label: '全部类型', value: '' },
            { label: '发放', value: 'grant' },
            { label: '回收', value: 'recover' },
            { label: '下单扣款', value: 'order_pay' },
            { label: '退款', value: 'order_refund' },
          ]" style="width: 160px" @update:value="tPage = 1; loadTxns()" />
        </div>
        <n-data-table
          :columns="txnColumns"
          :data="txns"
          :pagination="{ page: tPage, pageSize: 20, itemCount: tTotal, onChange: (p: number) => { tPage = p; loadTxns(); } }"
          :scroll-x="1110"
        />
      </n-tab-pane>
    </n-tabs>

    <n-modal v-model:show="showOp" preset="dialog" :title="opForm.action === 'grant' ? `发放余额给 ${opForm.username}` : `回收 ${opForm.username} 的余额`" positive-text="确认" negative-text="取消" :loading="opLoading" @positive-click="handleOp">
      <n-input-number v-model:value="opForm.amount" :min="1" :max="10000000" :precision="2" :step="0.01" style="width: 100%" placeholder="金额（元）">
        <template #prefix>¥</template>
      </n-input-number>
      <n-input v-model:value="opForm.reason" placeholder="原因说明（必填建议）" style="margin-top: 12px" />
      <p class="hint">该操作将写入余额流水与操作日志，不可撤销；金额以服务端事务为准（单位：元，最多两位小数）</p>
    </n-modal>

    <n-modal v-model:show="showLevel" preset="dialog" :title="`调整 ${levelForm.username} 的等级`" positive-text="确认调整" negative-text="取消" :loading="levelLoading" @positive-click="handleLevel">
      <n-select v-model:value="levelForm.level" :options="Object.entries(LEVELS).map(([v, m]) => ({ label: `L${v} ${m.label}`, value: Number(v) }))" style="width: 100%" />
      <n-input v-model:value="levelForm.reason" placeholder="调整原因（必填，记录操作人/时间/原等级/新等级/原因）" style="margin-top: 12px" />
      <p class="hint">等级调整写入 user_level_log 与操作日志双重审计；自动升级依据为累计实际消费</p>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}
.hint {
  margin-top: 12px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
</style>
