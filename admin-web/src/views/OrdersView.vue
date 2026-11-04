<script setup lang="ts">
// 订单管理（阶段14-16 + 负责人结算需求）：列表/详情（快照+状态日志+结算信息）/管理员取消
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（余额口径，1 元 = 1 元；API 字段名不变）
import { ApiException, request } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { NButton, NDataTable, NDescriptions, NDescriptionsItem, NDrawer, NDrawerContent, NInput, NModal, NSelect, NTag, NTimeline, NTimelineItem, useDialog, useMessage } from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

interface OrderRow {
  id: string;
  orderNo: string;
  username: string;
  totalAmount: number;
  quantity: number;
  status: string;
  workerId: string | null;
  createdAt: string;
}

interface OrderDetail {
  id: string;
  orderNo: string;
  username: string;
  totalAmount: number;
  status: string;
  statusName: string;
  gameZone: string | null;
  gamePlayerId: string | null;
  /**
   * 订单对应的**一对一直聊**会话（原「订单群组」已于 2026-10-04 下掉，见 CLAUDE.md 结构规则 3：
   * 「接单/派单成功后由 ensureWorkerDirectTx 建立一对一会话（原 ensureOrderGroupTx 已删除）」）。
   *
   * ⚠️ 字段名是 `chatDirect`（服务端 `order.service.ts#adminDetail` → `chat.directInfoByOrder()`），
   * **不是** `chatGroup` —— 旧名在服务端已不存在，写错会永远拿到 `undefined`：
   * 已接单的订单详情也会一直显示「未创建（订单尚未被接单）」，把"有会话"谎报成"没会话"。
   */
  chatDirect: { conversationId: string; name: string; createdAt?: string; members: { userId: string; role: string; nickname: string; uid: string; unread?: number }[] } | null;
  snapshot: { productName: string; gameName: string; categoryName: string; unitPrice: number; quantity: number; priceUnit: string } | null;
  // 比例来自后端结算记录（该单结算当时生效的配置，历史单据不随配置变化）
  settlement: { settlementNo: string; orderAmount: number; workerAmount: number; workerPercentage: number; platformAmount: number; platformPercentage: number; createdAt: string } | null;
  workerInfo: { workerNo: string; nickname: string } | null;
  statusLogs: { id: string; fromStatus: string; toStatus: string; operatorType: string; source: string; remark: string | null; createdAt: string }[];
}

const STATUS_MAP: Record<string, { label: string; type: 'default' | 'success' | 'error' | 'warning' | 'info' }> = {
  pending_take: { label: '待接单', type: 'warning' },
  pending_dispatch: { label: '待确认派单', type: 'warning' },
  taken: { label: '已接单', type: 'info' },
  in_progress: { label: '进行中', type: 'info' },
  pending_confirm: { label: '待用户确认', type: 'warning' },
  completed: { label: '已完成', type: 'success' },
  canceled: { label: '已取消', type: 'error' },
  abnormal: { label: '异常', type: 'error' },
  after_sale: { label: '售后/申诉', type: 'error' },
};

const message = useMessage();
const dialog = useDialog();
const auth = useAuthStore();
/*
 * 三个动作各自的权限点（与服务端 `@RequirePermission` 逐一对应）：
 *   · 派单 / 撤销派单 → `admin:order:dispatch`
 *   · 取消（全额退款）→ `admin:order:cancel`（**默认只有超管**：迁移 1789990000000 之外的既有口径）
 * 详情只要能看到列表（admin:order:read）就能点，不额外判。
 */
const canDispatch = computed(() => auth.hasPermission('admin:order:dispatch'));
const canCancel = computed(() => auth.hasPermission('admin:order:cancel'));
const rows = ref<OrderRow[]>([]);
const total = ref(0);
const page = ref(1);
const status = ref<string | null>(null);
const keyword = ref('');
const loading = ref(false);

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: '20' });
    if (status.value) q.set('status', status.value);
    if (keyword.value) q.set('keyword', keyword.value);
    const data = await request<{ list: OrderRow[]; total: number }>('GET', `/admin/orders?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

const showDetail = ref(false);
const detail = ref<OrderDetail | null>(null);
async function openDetail(row: OrderRow) {
  try {
    detail.value = await request<OrderDetail>('GET', `/admin/orders/${row.id}`);
    showDetail.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}

/**
 * 管理员取消订单 —— **会真实退款**（服务端 `cancelByAdmin`：全额退回老板余额 + 冲正结算）。
 *
 * 为什么必须二次确认：这是**不可逆的资金动作**，且按钮就在列表操作列里、和「详情」相邻，
 * 误点一次就是真金白银。此前是**直接发请求**（无任何确认），属写操作缺陷。
 * 文案按「谁的单、多少钱、什么后果」写清；取消原因也在这里收集（服务端 `dto.reason` 会进
 * operation_log 与状态流转日志，写清原因才查得回是谁为什么取消的）。
 */
function cancelOrder(row: OrderRow) {
  // 用普通变量 + NInput 的 defaultValue/onUpdate:value 收集原因：
  // 不把「输入框的值」绑成响应式依赖，content 渲染函数就不必因每次按键重渲染（更稳）。
  let reason = '';
  dialog.warning({
    title: '取消订单（全额退款）',
    content: () =>
      h('div', [
        h('p', { style: 'margin:0 0 8px' }, [
          `订单 ${row.orderNo}（${formatYuan(row.totalAmount)}）将被取消，`,
          h('b', {}, '款项全额退回老板余额'),
          '；已结算的订单会同时冲正打手收益与平台抽成。',
        ]),
        h('p', { style: 'margin:0 0 10px;color:var(--color-text-secondary);font-size:12.5px' }, '此操作不可撤销，请填写取消原因（会写入操作日志与订单状态流转日志）。'),
        h(NInput, {
          defaultValue: '',
          'onUpdate:value': (v: string) => (reason = v),
          placeholder: '例：老板申请取消 / 打手无法履约 / 重复下单',
          maxlength: 100,
        }),
      ]),
    positiveText: '确认取消并退款',
    negativeText: '再想想',
    onPositiveClick: async () => {
      if (!reason.trim()) {
        message.warning('请填写取消原因');
        return false; // 阻止弹窗关闭，留在原地补填
      }
      try {
        await request('POST', `/admin/orders/${row.id}/cancel`, { reason: reason.trim() });
        message.success('已取消并全额退款');
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '操作失败');
        return false;
      }
      return true;
    },
  });
}

// ---------- 派单（阶段16补） ----------
interface WorkerRow {
  id: string;
  workerNo: string;
  userId: string;
  nickname: string;
  canTakeOrder: number;
  status: number;
}
const showDispatch = ref(false);
const dispatchOrder = ref<OrderRow | null>(null);
const dispatchWorkers = ref<WorkerRow[]>([]);
const dispatchWorkerId = ref<string | null>(null);
const dispatching = ref(false);

async function openDispatch(row: OrderRow) {
  dispatchOrder.value = row;
  dispatchWorkerId.value = null;
  try {
    const data = await request<{ list: WorkerRow[] }>('GET', '/admin/workers?page=1&pageSize=100');
    dispatchWorkers.value = (data.list ?? data ?? []).filter((w) => w.canTakeOrder === 1 && w.status === 1);
    if (!dispatchWorkers.value.length) {
      message.warning('暂无可用打手（需启用且持有接单权限）');
      return;
    }
    showDispatch.value = true;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载打手失败');
  }
}

async function doDispatch() {
  const order = dispatchOrder.value;
  if (!order || !dispatchWorkerId.value) {
    message.warning('请选择打手');
    return;
  }
  dispatching.value = true;
  try {
    await request('POST', `/admin/orders/${order.id}/dispatch`, { workerId: dispatchWorkerId.value });
    message.success('已派单，等待打手确认（超时自动回大厅）');
    showDispatch.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '派单失败');
  } finally {
    dispatching.value = false;
  }
}

/**
 * 撤销派单 —— 订单**回到接单大厅**（打手此前的派单被撤回）。
 * 与「派单」相对，属会改变订单归属的写操作：补二次确认，避免在操作列里误点。
 */
function revokeDispatch(row: OrderRow) {
  dialog.warning({
    title: '撤销派单',
    content: `确定撤销订单 ${row.orderNo} 的派单？该订单将回到接单大厅，等待其他打手接单（原被派打手会收到通知）。`,
    positiveText: '确认撤销',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('POST', `/admin/orders/${row.id}/revoke-dispatch`);
        message.success('已撤销派单，订单回到大厅');
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '操作失败');
        return false;
      }
      return true;
    },
  });
}

const columns = [
  { title: '订单号', key: 'orderNo', width: 170 },
  { title: '用户', key: 'username', width: 110 },
  {
    title: '金额', key: 'totalAmount', width: 110,
    render: (row: OrderRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.totalAmount)),
  },
  {
    title: '状态', key: 'status', width: 110,
    render: (row: OrderRow) => {
      const m = STATUS_MAP[row.status] ?? { label: row.status, type: 'default' as const };
      return h(NTag, { size: 'small', type: m.type }, { default: () => m.label });
    },
  },
  { title: '创建时间', key: 'createdAt', width: 160, render: (row: OrderRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 170+110+110+110+160+240 = 900 → 模板 :scroll-x = 900
    // 最多同时出现 3 个按钮（详情 + 派单/撤销派单 + 取消，真量 ≤186px），240 放得下不折行；
    // fixed:'right'：横向滚动时操作按钮始终完整可见
    title: '操作', key: 'actions', width: 240, fixed: 'right' as const,
    render: (row: OrderRow) => {
      /*
       * 权限渲染（docs/04：前端隐藏只是体验，服务端 403 才是权威）——
       * 三个动作是**三个不同的权限点**，此前一个都没判，于是没有权限的账号会看到可点的按钮、
       * 点下去只吃 403。实测 `operator` 角色：有 admin:order:read / dispatch / write，
       * **没有 admin:order:cancel** → 「取消」按钮对它就是纯误导。
       */
      const btns = [h(NButton, { size: 'small', onClick: () => openDetail(row) }, { default: () => '详情' })];
      if (row.status === 'pending_take' && canDispatch.value) {
        btns.push(h(NButton, { size: 'small', type: 'primary', onClick: () => openDispatch(row) }, { default: () => '派单' }));
      }
      if (row.status === 'pending_dispatch' && canDispatch.value) {
        btns.push(h(NButton, { size: 'small', type: 'warning', quaternary: true, onClick: () => revokeDispatch(row) }, { default: () => '撤销派单' }));
      }
      if (canCancel.value && ['pending_take', 'taken', 'in_progress', 'pending_confirm'].includes(row.status)) {
        btns.push(h(NButton, { size: 'small', type: 'error', quaternary: true, onClick: () => cancelOrder(row) }, { default: () => '取消' }));
      }
      return h('div', { style: 'display:flex;gap:8px;flex-wrap:wrap' }, btns);
    },
  },
];
</script>

<template>
  <div class="orders-page">
    <div class="toolbar">
      <n-select v-model:value="status" :options="[
        { label: '全部状态', value: '' },
        ...Object.entries(STATUS_MAP).map(([k, v]) => ({ label: v.label, value: k })),
      ]" style="width: 150px" @update:value="page = 1; load()" />
      <n-input v-model:value="keyword" placeholder="搜索订单号/用户" style="width: 200px" @keyup.enter="page = 1; load()" />
      <n-button @click="page = 1; load()">搜索</n-button>
    </div>
    <n-data-table :columns="columns" :data="rows" :loading="loading" :scroll-x="900"
      :pagination="{ page: page, pageSize: 20, itemCount: total, onChange: (p: number) => { page = p; load(); } }" />

    <n-drawer v-model:show="showDetail" :width="520">
      <n-drawer-content title="订单详情" closable>
        <n-descriptions v-if="detail" :column="1" bordered size="small">
          <n-descriptions-item label="订单号">{{ detail.orderNo }}</n-descriptions-item>
          <n-descriptions-item label="用户">{{ detail.username }}</n-descriptions-item>
          <n-descriptions-item label="商品">{{ detail.snapshot?.productName }}（{{ detail.snapshot?.gameName }} / {{ detail.snapshot?.categoryName }}）</n-descriptions-item>
          <n-descriptions-item label="订单金额">{{ formatYuan(detail.totalAmount) }}（{{ formatYuan(detail.snapshot?.unitPrice) }}/{{ detail.snapshot?.priceUnit }} × {{ detail.snapshot?.quantity }}）</n-descriptions-item>
          <n-descriptions-item label="游戏分区">{{ detail.gameZone === 'qq' ? 'QQ区' : detail.gameZone === 'wechat' ? '微信区' : '-' }}</n-descriptions-item>
          <n-descriptions-item label="游戏ID">{{ detail.gamePlayerId || '-' }}</n-descriptions-item>
          <n-descriptions-item label="订单会话">
            <span v-if="detail.chatDirect">{{ detail.chatDirect.name }}（{{ detail.chatDirect.members.map((m: any) => `${m.nickname}·${m.role === 'boss' ? '老板' : m.role === 'worker' ? '打手' : '管理员'}`).join('、') }}）</span>
            <span v-else>未创建（订单尚未被接单）</span>
          </n-descriptions-item>
          <n-descriptions-item label="订单状态">{{ detail.statusName }}</n-descriptions-item>
          <n-descriptions-item label="打手">{{ detail.workerInfo ? `${detail.workerInfo.nickname}（${detail.workerInfo.workerNo}）` : '未接单' }}</n-descriptions-item>
          <template v-if="detail.settlement">
            <n-descriptions-item label="结算状态"><n-tag type="success" size="small">已结算</n-tag></n-descriptions-item>
            <n-descriptions-item label="结算ID">{{ detail.settlement.settlementNo }}</n-descriptions-item>
            <n-descriptions-item label="结算时间">{{ new Date(detail.settlement.createdAt).toLocaleString('zh-CN', { hour12: false }) }}</n-descriptions-item>
            <n-descriptions-item :label="`打手收益（${detail.settlement.workerPercentage}%）`">{{ formatYuan(detail.settlement.workerAmount) }}</n-descriptions-item>
            <n-descriptions-item :label="`平台抽成（${detail.settlement.platformPercentage}%）`">{{ formatYuan(detail.settlement.platformAmount) }}</n-descriptions-item>
          </template>
          <n-descriptions-item v-else label="结算状态"><n-tag type="default" size="small">未结算</n-tag></n-descriptions-item>
        </n-descriptions>

        <h4 style="margin: 16px 0 8px">状态流转日志</h4>
        <n-timeline v-if="detail">
          <n-timeline-item v-for="l in [...detail.statusLogs].reverse()" :key="l.id"
            :type="l.toStatus === 'completed' ? 'success' : l.toStatus === 'canceled' ? 'error' : 'info'"
            :title="`${l.fromStatus || '创建'} → ${l.toStatus}`"
            :content="`${l.operatorType} · ${l.source}${l.remark ? ' · ' + l.remark : ''}`"
            :time="new Date(l.createdAt).toLocaleTimeString('zh-CN', { hour12: false })" />
        </n-timeline>
      </n-drawer-content>
    </n-drawer>

    <n-modal v-model:show="showDispatch" preset="dialog" title="订单派单" positive-text="派单" negative-text="取消" :positive-button-props="{ loading: dispatching }" @positive-click="doDispatch">
      <p v-if="dispatchOrder" class="dispatch-order">
        订单 {{ dispatchOrder.orderNo }} · {{ formatYuan(dispatchOrder.totalAmount) }}
      </p>
      <n-select
        v-model:value="dispatchWorkerId"
        :options="dispatchWorkers.map((w) => ({ label: `${w.nickname}（工号 ${w.workerNo}）`, value: w.id }))"
        placeholder="选择打手（5 分钟内未确认自动回大厅）"
        filterable
      />
    </n-modal>
  </div>
</template>

<style scoped>
.dispatch-order {
  margin-bottom: 12px;
  font-size: 13px;
  color: var(--color-text-secondary);
}
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}
</style>
