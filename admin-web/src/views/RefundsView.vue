<script setup lang="ts">
// 退款审批（权限点 admin:refund:read 查看 / admin:refund:handle 审批）
// 负责人 2026-10-04：老板端顶部导航「退款」提交申请 → 管理端通过=原路退回余额（未结算退订单金额，
// 已结算走既有冲正），驳回=必填理由。退款流水与幂等键与「售后申诉退款」完全同一套（docs/06）。
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（余额口径；API 字段名不变）
// 负责人 2026-10-04 权限收口：admin:refund:handle 从普通运营角色收回，仅超管 + 所有者（前端只隐藏，服务端 403 才是权威）
import { ApiException, request } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import { NButton, NDataTable, NInput, NModal, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface RefundRow {
  id: string;
  requestNo: string;
  orderId: string;
  orderNo: string;
  orderStatus: string;
  userId: string;
  nickname: string;
  uid: string;
  amount: number;
  prevStatus: string;
  reason: string;
  remark: string;
  status: string;
  handlerRemark: string;
  handledAt: string | null;
  createdAt: string;
}

const message = useMessage();
const auth = useAuthStore();
/** 退款审批 = 独占权限点（超管 + 所有者）；普通运营只有 admin:refund:read，能看不能批 */
const canHandle = computed(() => auth.hasExclusivePermission('admin:refund:handle'));
const rows = ref<RefundRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const loading = ref(false);
const statusFilter = ref('');
const stat = reactive({ pending: 0, approved: 0, rejected: 0 });

const ORDER_STATUS: Record<string, string> = {
  pending_take: '待接单',
  pending_dispatch: '待确认派单',
  taken: '已接单',
  in_progress: '进行中',
  pending_confirm: '待确认',
  completed: '已完成',
  canceled: '已取消',
  abnormal: '异常',
  after_sale: '售后中',
};

async function load() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: String(page.value), pageSize: String(pageSize) });
    if (statusFilter.value) q.set('status', statusFilter.value);
    const data = await request<{
      list: RefundRow[];
      total: number;
      stat: { pending: number; approved: number; rejected: number };
    }>('GET', `/admin/refunds?${q.toString()}`);
    rows.value = data.list;
    total.value = data.total;
    stat.pending = data.stat?.pending ?? 0;
    stat.approved = data.stat?.approved ?? 0;
    stat.rejected = data.stat?.rejected ?? 0;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

const showHandle = ref(false);
const handleRow = ref<RefundRow | null>(null);
const form = reactive({ action: 'approve' as 'approve' | 'reject', remark: '' });
const handling = ref(false);

function openHandle(row: RefundRow) {
  handleRow.value = row;
  form.action = 'approve';
  form.remark = '';
  showHandle.value = true;
}

async function doHandle() {
  const row = handleRow.value;
  if (!row) return;
  if (form.action === 'reject' && !form.remark.trim()) {
    message.warning('驳回必须填写理由');
    return;
  }
  handling.value = true;
  try {
    await request('POST', `/admin/refunds/${row.id}/handle`, { action: form.action, remark: form.remark });
    message.success(form.action === 'approve' ? '已通过并原路退回余额' : '已驳回（结果已通知申请人）');
    showHandle.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '处理失败');
  } finally {
    handling.value = false;
  }
}

const columns = [
  { title: '申请单号', key: 'requestNo', width: 150 },
  { title: '订单号', key: 'orderNo', width: 170 },
  {
    title: '订单状态', key: 'orderStatus', width: 100,
    render: (row: RefundRow) => ORDER_STATUS[row.orderStatus] ?? row.orderStatus,
  },
  { title: '申请人', key: 'nickname', width: 130, render: (row: RefundRow) => `${row.nickname || '—'}（${row.uid || row.userId}）` },
  {
    title: '退款金额', key: 'amount', width: 120,
    render: (row: RefundRow) => h('strong', { style: 'color: var(--color-primary)' }, formatYuanOr(row.amount)),
  },
  { title: '退款原因', key: 'reason', ellipsis: { tooltip: true } },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: RefundRow) => {
      if (row.status === 'pending') return h(NTag, { size: 'small', type: 'warning' }, { default: () => '待处理' });
      if (row.status === 'approved') return h(NTag, { size: 'small', type: 'success' }, { default: () => '已通过' });
      return h(NTag, { size: 'small' }, { default: () => '已驳回' });
    },
  },
  { title: '申请时间', key: 'createdAt', width: 165, render: (row: RefundRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 150+170+100+130+120+90+165+110 = 1035（+「退款原因」弹性列 200）→ 模板 :scroll-x = 1235
    // fixed:'right'：横向滚动时「审批」始终完整可见
    title: '操作', key: 'actions', width: 110, fixed: 'right' as const,
    render: (row: RefundRow) => {
      if (row.status !== 'pending') {
        return h('span', { style: 'color: var(--color-text-tertiary);font-size:12px' }, row.handlerRemark || '已处理');
      }
      if (!canHandle.value) {
        return h('span', { style: 'color: var(--color-text-tertiary);font-size:12px' }, '无审批权限');
      }
      return h(NButton, { size: 'small', type: 'primary', onClick: () => openHandle(row) }, { default: () => '审批' });
    },
  },
];
</script>

<template>
  <div class="refunds-page">
    <div class="toolbar">
      <n-tag
        v-for="s in [['', '全部'], ['pending', '待处理'], ['approved', '已通过'], ['rejected', '已驳回']]"
        :key="s[0]"
        :type="statusFilter === s[0] ? 'primary' : 'default'"
        style="cursor: pointer"
        @click="statusFilter = s[0]; page = 1; load()"
      >
        {{ s[1] }}
      </n-tag>
      <div class="spacer" />
      <span class="stat">
        待处理 <strong>{{ stat.pending }}</strong> · 已通过 <strong>{{ stat.approved }}</strong> · 已驳回 <strong>{{ stat.rejected }}</strong>
      </span>
    </div>
    <p v-if="!canHandle" class="warn">审批需要 <code>admin:refund:handle</code> 权限点（已收口为超级管理员与所有者独占；普通运营可查看退款申请，但不能通过/驳回）。</p>
    <n-data-table
      :columns="columns"
      :data="rows"
      :loading="loading"
      :pagination="{ page, pageSize, itemCount: total, onChange: (p: number) => { page = p; load(); } }"
      :scroll-x="1235"
    />

    <n-modal
      v-model:show="showHandle"
      preset="dialog"
      title="退款审批"
      positive-text="确认"
      negative-text="取消"
      :positive-button-props="{ loading: handling }"
      @positive-click="doHandle"
    >
      <p v-if="handleRow" class="info">
        订单 {{ handleRow.orderNo }}（{{ ORDER_STATUS[handleRow.orderStatus] ?? handleRow.orderStatus }}）<br />
        {{ handleRow.nickname }} 申请退回 <strong>{{ formatYuan(handleRow.amount) }}</strong> 余额：{{ handleRow.reason }}
        <template v-if="handleRow.remark"><br />补充说明：{{ handleRow.remark }}</template>
      </p>
      <div class="choice">
        <n-tag
          :type="form.action === 'approve' ? 'success' : 'default'"
          style="cursor: pointer"
          @click="form.action = 'approve'"
        >
          同意退款（原路退回老板余额；已结算订单按该单结算记录自动冲正）
        </n-tag>
        <n-tag
          :type="form.action === 'reject' ? 'error' : 'default'"
          style="cursor: pointer"
          @click="form.action = 'reject'"
        >
          驳回（必填理由）
        </n-tag>
      </div>
      <n-input
        v-model:value="form.remark"
        type="textarea"
        placeholder="处理意见（驳回时必须填写，会通知申请人）"
        :autosize="{ minRows: 2 }"
        style="margin-top: 12px"
      />
      <p class="warn">重复审批会被服务端拒绝，不会二次退款。</p>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
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
.info {
  margin-bottom: 12px;
  font-size: 13px;
  color: var(--color-text-secondary, #64748b);
  line-height: 1.8;
}
.choice {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.warn {
  margin-top: 10px;
  font-size: 12px;
  color: var(--color-text-tertiary, #94a3b8);
}
</style>
