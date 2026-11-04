<template>
  <div class="withdraw-page">
    <!--
      页头口径（与充值页对称，不许放宽）：平台不经手资金。
      提现 = 打手在 App 里发起申请（带收款码）→ 管理员核对收款信息 → **线下打款** →
      上传支付记录截图 → 标记「已打款」；驳回则**把余额退回打手**。没有支付通道、没有自动打款。
    -->
    <header class="page-head">
      <div class="head-line">
        <h1>提现审核</h1>
        <!--
          待处理数量（要求：可点筛选）。
          刻意做成**按钮**而不是一个静态数字：运营进这一页的动作十次有九次是"先看待处理的"，
          点一下就把筛选切到「待处理」（再点一下回到全部），少一次下拉操作。
        -->
        <button
          class="pending-chip"
          :class="{ 'is-on': filter.status === 'pending' }"
          type="button"
          :disabled="!canReview"
          :title="canReview ? '点这里只看待处理的申请' : '需要 withdraw:review 权限'"
          @click="togglePendingOnly"
        >
          <span class="dot" aria-hidden="true" />
          待处理
          <b>{{ pendingCount === null ? '—' : pendingCount }}</b>
          笔
        </button>
      </div>
      <p class="lede">
        打手在 App 里提交提现申请（金额 + <b>收款码</b>），<b>申请时金额已从余额扣除并锁定</b>，
        申请进到这里等人工核对。核对无误后<b>线下微信打款</b>，再上传支付记录截图并标记 <b>已打款</b>；
        收款信息对不上就驳回，<b>驳回会把余额原样退回打手</b>（含反向流水）。
        仍然<b>不接任何代付/支付通道</b>：没有代付 API、没有回调，系统只负责扣款、锁款、记账与留痕。
        列表与详情都给<b>完整</b>收款信息（姓名 · 电话 · 微信号）——能看这一页就是有
        <code>withdraw:review</code> 的审核人本人，核对收款信息不必再点进详情；
        页面外的审计与站内通知口径由服务端另行处理（本页不参与）。
      </p>
    </header>

    <!-- 两个权限点都没有（极端情况）：给一块说明，而不是渲染一个空壳页面 -->
    <div v-if="!canReview && !canPay" class="perm-block">
      <div class="perm-title">没有提现审核的权限</div>
      <div class="perm-sub">
        提现列表/详情/收款码需要窄权限点 <code>withdraw:review</code>；打款与驳回需要 <code>withdraw:pay</code>。<br />
        当前账号两者都没有，因此这一页不给任何入口与数据 —— 请联系超级管理员在「管理员与角色」里给角色勾选后再来。
      </div>
    </div>

    <template v-else>
      <p v-if="!canReview" class="ro-hint">
        当前账号没有提现申请的查看权限（窄权限点 <code>withdraw:review</code>）：列表与收款码会被服务端拒绝。
      </p>
      <p v-else-if="!canPay" class="ro-hint">
        当前账号只有查看权限（缺 <code>withdraw:pay</code>）：可以核对收款信息与收款码大图，
        <b>打款 / 驳回按钮不可用</b>（服务端二次校验，前端只是不渲染）。
      </p>

      <section class="card">
        <div class="filter-bar">
          <n-select
            v-model:value="filter.status"
            :options="statusOptions"
            placeholder="全部状态"
            clearable
            style="width: 148px"
            @update:value="applyFilter"
          />
          <n-button type="primary" ghost @click="applyFilter">查询</n-button>
          <n-button quaternary @click="resetFilter">重置</n-button>
          <div class="spacer" />
          <span class="count">共 {{ total }} 条提现申请</span>
          <n-button quaternary size="small" :loading="reqLoading" @click="refreshAll">刷新</n-button>
        </div>

        <n-data-table
          :columns="columns"
          :data="rows"
          :loading="reqLoading"
          :bordered="false"
          :row-key="(r: WithdrawRequestRow) => r.id"
          :scroll-x="984"
          size="small"
          :pagination="{
            page: page,
            pageSize: pageSize,
            itemCount: total,
            showSizePicker: false,
            onChange: onPageChange,
          }"
        >
          <template #empty>
            <div class="empty">
              <div class="empty-title">还没有提现申请</div>
              <div class="empty-sub">
                打手在 App 里提交提现（金额 + 收款码）后，申请会出现在这里等着核对打款。<br />
                如果刚有人提交却看不到，先点「重置」清掉上面的筛选条件。
              </div>
            </div>
          </template>
        </n-data-table>
      </section>
    </template>

    <!-- ============================================================ 详情抽屉 -->
    <n-drawer v-model:show="drawerOpen" :width="580" placement="right" @after-leave="onDrawerClosed">
      <n-drawer-content closable>
        <template #header>提现详情</template>

        <n-spin :show="detailLoading">
          <div v-if="detailError" class="detail-error">
            <div class="detail-error-title">详情没取到</div>
            <div class="detail-error-sub">{{ detailError }}</div>
            <n-button size="small" :disabled="!activeRow" @click="retryDetail">重试</n-button>
          </div>

          <template v-else>
            <!-- 打手 + 金额 + 状态（列表已知的部分先渲染，详情回来后补全） -->
            <section class="block">
              <div class="who-line">
                <span class="who-name">{{ head.workerNickname || '（无昵称）' }}</span>
                <span class="who-no">工号 {{ head.workerNo || '—' }}</span>
                <n-tag size="small" :type="statusTagType(head.status)">{{ statusLabel(head.status) }}</n-tag>
              </div>
              <div class="amount-line">{{ formatYuanOr(head.amount) }}</div>
              <div class="meta-line">申请时间：{{ fmtTime(head.createdAt) }}</div>
              <div v-if="head.status === 'paid'" class="meta-line">
                打款时间：{{ fmtTime(detail?.payout?.paidAt ?? detail?.reviewedAt ?? null) }}
              </div>
              <div v-if="head.status === 'rejected'" class="meta-line">
                驳回时间：{{ fmtTime(detail?.reviewedAt ?? null) }}
              </div>
            </section>

            <!-- 完整收款信息（**列表与详情同口径**：都给完整值；详情未回来时先用列表行顶上） -->
            <section class="block">
              <div class="block-head"><h2>收款信息</h2><span class="block-sub">已核对姓名与收款码为同一人再打款</span></div>
              <dl class="kv">
                <dt>姓名</dt>
                <dd>{{ payee.realName || '—' }}</dd>
                <dt>电话</dt>
                <dd>{{ payee.phone || '—' }}</dd>
                <dt>微信号</dt>
                <dd>{{ payee.wechatId || '—' }}</dd>
              </dl>
            </section>

            <!-- 收款码大图：受保护图片，必须带令牌取（见 api/withdraw.ts 的 withdrawProofUrl） -->
            <section class="block">
              <div class="block-head">
                <h2>收款码</h2>
                <span class="block-sub">资金凭证：走受保护通道取图，不生成公开直链</span>
              </div>
              <div class="qr-box">
                <n-spin :show="qrLoading" size="small">
                  <n-image
                    v-if="qrUrl"
                    :src="qrUrl"
                    width="240"
                    object-fit="contain"
                    class="qr-img"
                    :alt="`${head.workerNickname || head.id} 的收款码`"
                  />
                  <div v-else class="qr-holder">
                    <span>{{ qrError || '收款码读取中…' }}</span>
                    <n-button v-if="qrError" size="tiny" :disabled="!head.id" @click="loadQr(head.id)">重试</n-button>
                  </div>
                </n-spin>
              </div>
            </section>

            <!-- 打款区：pending 且有 withdraw:pay 才给操作；否则只读展示结果 -->
            <section class="block">
              <div class="block-head">
                <h2>打款</h2>
                <span class="block-sub">线下打款完成后，上传支付记录截图再标记已打款</span>
              </div>

              <template v-if="head.status === 'pending'">
                <template v-if="canPay">
                  <div class="field">
                    <span class="field-label">支付记录截图<b class="req">必填</b></span>
                    <MediaUploadField v-model="proofMediaId" :media-type="WITHDRAW_PROOF_MEDIA_TYPE" :disabled="uploadDisabled" />
                    <span class="mini-hint">打款凭证会留档供审计核对；没有截图不能标记已打款。</span>
                  </div>
                  <div class="field">
                    <span class="field-label">备注<em class="opt">选填</em></span>
                    <n-input
                      v-model:value="payNote"
                      type="textarea"
                      :autosize="{ minRows: 2, maxRows: 4 }"
                      maxlength="200"
                      show-count
                      placeholder="如：已转微信，到账后请打手确认"
                    />
                  </div>
                  <div class="ops">
                    <n-button
                      type="primary"
                      :loading="paySaving"
                      :disabled="!proofMediaId"
                      :title="proofMediaId ? '' : '上传支付记录截图后才能标记已打款'"
                      @click="confirmPay"
                    >
                      已提现
                    </n-button>
                    <span class="mini-hint">
                      {{ proofMediaId ? '点「已提现」会再确认一次，确认后不可撤销' : '上传支付记录截图后才能点「已提现」' }}
                    </span>
                  </div>
                </template>
                <p v-else class="ro-hint">当前账号没有打款权限（缺 <code>withdraw:pay</code>）：按钮已隐藏，服务端同样拒绝。</p>
              </template>

              <!-- 已打款：只读展示打款记录（打款人 / 时间 / 凭证 / 备注） -->
              <div v-else-if="head.status === 'paid'" class="result">
                <n-alert type="success" :bordered="false" class="result-alert">
                  已打款（不可重复打款）。下面这条记录就是审计口径，凭证图可点开核对。
                </n-alert>
                <dl class="kv">
                  <dt>打款人</dt>
                  <dd>{{ detail?.payout?.payerName || '—' }}</dd>
                  <dt>打款时间</dt>
                  <dd>{{ fmtTime(detail?.payout?.paidAt ?? detail?.reviewedAt ?? null) }}</dd>
                  <dt>备注</dt>
                  <dd>{{ detail?.payout?.note || '（无）' }}</dd>
                </dl>
                <div class="qr-box">
                  <n-spin :show="payoutLoading" size="small">
                    <n-image
                      v-if="payoutUrl"
                      :src="payoutUrl"
                      width="220"
                      object-fit="contain"
                      class="qr-img"
                      alt="打款凭证"
                    />
                    <div v-else class="qr-holder">
                      <span>{{ payoutError || (detail?.payout?.proofMediaId ? '打款凭证读取中…' : '这条记录没有凭证图') }}</span>
                      <n-button v-if="payoutError" size="tiny" @click="loadPayoutProof(head.id)">重试</n-button>
                    </div>
                  </n-spin>
                </div>
              </div>

              <!-- 已驳回：只读展示原因 -->
              <div v-else class="result">
                <n-alert type="error" :bordered="false" class="result-alert">
                  已驳回（余额已退回打手，不可重复处理）。
                </n-alert>
                <dl class="kv">
                  <dt>驳回原因</dt>
                  <dd>{{ detail?.rejectReason || '（无原因）' }}</dd>
                  <dt>驳回时间</dt>
                  <dd>{{ fmtTime(detail?.reviewedAt ?? null) }}</dd>
                </dl>
              </div>
            </section>

            <!-- 驳回区：仅 pending + 有打款权限时出现 -->
            <section v-if="head.status === 'pending' && canPay" class="block">
              <div class="block-head">
                <h2>驳回</h2>
                <span class="block-sub">收款信息对不上、或打手重复申请时用</span>
              </div>
              <n-alert type="warning" :bordered="false" class="reject-warn">
                驳回后 <b>这笔金额的余额会退回打手</b>，原因会通知他；请确认打手确实没收到钱再驳回。
              </n-alert>
              <n-input
                v-model:value="rejectReason"
                class="reject-input"
                type="textarea"
                :autosize="{ minRows: 2, maxRows: 4 }"
                maxlength="200"
                show-count
                placeholder="必填：例如「收款码与姓名不一致，请换成本人收款码重新申请」"
              />
              <p v-if="rejectTouched && !rejectReason.trim()" class="err">驳回必须填写原因（打手会看到这句话）</p>
              <div class="ops">
                <n-button type="error" ghost :loading="rejecting" :disabled="!rejectReason.trim()" @click="confirmReject">
                  驳回
                </n-button>
                <span class="mini-hint">驳回前会再确认一次（含「余额将退回打手」）</span>
              </div>
            </section>
          </template>
        </n-spin>
      </n-drawer-content>
    </n-drawer>
  </div>
</template>

<script setup lang="ts">
/**
 * 提现审核（打手申请提现 → 管理员核对 → 线下打款 / 驳回退余额）
 * ============================================================================
 * ## 放在哪、为什么
 * 侧栏位置：「资金与抽成」组，与「余额管理 / 充值管理 / 抽成中心」并列。
 * 理由与充值同理：这一页的产出直接改余额（`paid` 是资金出账、`rejected` 会把余额退回打手），
 * 与「余额管理」是同一条资金链路的上下游；三页挨着，运营对账不用来回跳。
 *
 * ## 与「充值管理」刻意对齐的三件事（两页是镜像，改一页要看另一页）
 *   ① 版式与语汇：页头（标题 + 说明 + 可点数量）→ 筛选条 → 表格（`:scroll-x` + 操作列 `fixed:'right'`）→ 弹层确认；
 *   ② 受保护图片：**都不直连 URL**，一律 fetch 带 `Authorization` 取 blob（`withdrawProofUrl` / `protectedMediaUrl`）；
 *   ③ 权限：专用窄权限点（`withdraw:review` 看 / `withdraw:pay` 打款·驳回），前端只隐藏，服务端才是权威。
 *
 * ## 状态守卫（硬要求）
 * 只有 `pending` 才出现打款/驳回入口；`paid` / `rejected` 一律**只读展示结果**
 * （行内操作列也不放任何按钮，避免"点进去才发现不能点"）。
 *
 * ## 错误一律透传服务端中文原文（不吞错）
 * 典型：「该申请已打款」「你有一笔提现正在处理中」——直接 `message.error(e.message)`。
 * 前端**不**把服务端错误翻译成自己的话：服务端的这句就是给运营看的。
 *
 * ## 金额
 * 全部走 `@/utils/format.ts`（`¥` + 恒两位小数 + 千分位），页面不出现"积分"字样。
 */
import {
  STATUS_FILTERS,
  WITHDRAW_PROOF_MEDIA_TYPE,
  getRequestDetail,
  listRequests,
  payRequest,
  payeeTextOf,
  rejectRequest,
  statusLabel,
  statusTagType,
  withdrawProofUrl,
  type WithdrawRequestDetail,
  type WithdrawRequestRow,
} from '@/api/withdraw';
import { ApiException } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import MediaUploadField from '@/components/MediaUploadField.vue';
import {
  NAlert,
  NButton,
  NDataTable,
  NDrawer,
  NDrawerContent,
  NImage,
  NInput,
  NSelect,
  NSpin,
  NTag,
  useDialog,
  useMessage,
} from 'naive-ui';
import type { DataTableColumns } from 'naive-ui';
import { computed, h, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue';

const message = useMessage();
const dialog = useDialog();
const auth = useAuthStore();

/** 列表/详情/收款码：`withdraw:review`；打款/驳回：`withdraw:pay`（两个都没有 → 整页说明，菜单项也隐藏） */
const canReview = computed(() => auth.hasPermission('withdraw:review'));
const canPay = computed(() => auth.hasPermission('withdraw:pay'));
/** 上传凭证是**另一把钥匙**（`POST /admin/media/upload` = admin:media:write）；未知时不置灰（与充值页同一处坑） */
const canUploadMedia = computed(() => auth.hasPermission('admin:media:write'));
const uploadDisabled = computed(() => !!auth.me && !canUploadMedia.value);

const statusOptions = STATUS_FILTERS.map((o) => ({ label: o.label, value: o.value }));

function fmtTime(v: string | null | undefined): string {
  if (!v) return '—';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '—';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

// ================================================================= 列表

const rows = ref<WithdrawRequestRow[]>([]);
const total = ref(0);
/**
 * 待处理数量：服务端若在列表响应里回 `pendingCount` 就用它；否则用 `pageSize=1` 的探针拿 `total`
 * （见下方 `loadPendingCount()` —— 不自己编数字，取不到就显示「—」）。
 */
const pendingCount = ref<number | null>(null);
const page = ref(1);
const pageSize = 20;
const reqLoading = ref(false);
const submittingId = ref<string | null>(null);

const filter = reactive<{ status: string | null }>({ status: null });

const columns = computed<DataTableColumns<WithdrawRequestRow>>(() => [
  {
    title: '打手',
    key: 'workerNickname',
    minWidth: 150,
    render: (r) => [
      h('div', { style: 'font-weight:600' }, r.workerNickname || '（无昵称）'),
      h('div', { style: 'font-size:12px;color:var(--color-text-tertiary)' }, r.workerNo ? `工号 ${r.workerNo}` : '—'),
    ],
  },
  {
    // 提现金额（元）：¥ + 两位小数 + 千分位 —— 出账金额必须一眼可核对
    title: '金额',
    key: 'amount',
    width: 110,
    render: (r) => h('span', {}, formatYuanOr(r.amount)),
  },
  {
    /*
     * 收款信息（**完整值**）：姓名 · 电话 · 微信号。
     * 口径（负责人 2026-10-11）：能看列表 = 有 withdraw:review = 审核人本人 → 不脱敏，
     * 核对收款信息不用点进详情。字段取值见 api/withdraw.ts 的 `payeeTextOf`：
     * 逐字段优先 `account`（列表新字段），取不到回退 `accountMasked`（服务端未更新也不裂）。
     * 列宽 300 起（完整手机号 11 位 + 姓名 + 微信号一行放得下，不换行挤压相邻列）。
     */
    title: '收款信息',
    key: 'account',
    minWidth: 300,
    render: (r) => {
      const text = payeeTextOf(r);
      return text
        ? h('span', { style: 'font-size:12.5px' }, text)
        : h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '—');
    },
  },
  {
    title: '状态',
    key: 'status',
    width: 96,
    render: (r) => h(NTag, { size: 'small', type: statusTagType(r.status) }, { default: () => statusLabel(r.status) }),
  },
  {
    title: '申请时间',
    key: 'createdAt',
    width: 150,
    render: (r) => h('span', { style: 'font-size:12.5px' }, fmtTime(r.createdAt)),
  },
  {
    // 列宽和（按最小宽）= 150+110+300+96+150+178 = 984 → 模板 :scroll-x = 984
    // fixed:'right'：横向滚动时「处理」始终完整可见（这条链路点错就是资金损失）
    title: '操作',
    key: 'actions',
    width: 178,
    fixed: 'right',
    render: (r) => {
      // 状态守卫：非 pending 一律只读展示结果，**不放任何按钮**
      if (r.status !== 'pending') {
        if (r.status === 'rejected') {
          return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '已驳回（不可重复处理）');
        }
        if (r.status === 'paid') {
          return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '已打款（不可重复打款）');
        }
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, statusLabel(r.status));
      }
      if (!canReview.value) {
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '无查看权限');
      }
      const btns = [
        h(
          NButton,
          {
            size: 'small',
            type: 'primary',
            loading: submittingId.value === r.id,
            onClick: () => void openDetail(r),
          },
          { default: () => '处理' },
        ),
      ];
      // 「驳回」要填原因、且会退余额 → 一键进详情并聚焦驳回区（与详情里那一块共用同一份实现）
      if (canPay.value) {
        btns.push(
          h(
            NButton,
            {
              size: 'small',
              type: 'error',
              quaternary: true,
              disabled: submittingId.value !== null,
              onClick: () => void openDetail(r, { focusReject: true }),
            },
            { default: () => '驳回' },
          ),
        );
      }
      return h('div', { style: 'display:flex;gap:8px' }, btns);
    },
  },
]);

async function loadRequests() {
  if (!canReview.value) {
    rows.value = [];
    total.value = 0;
    return; // 无权限时不发请求（发了只会满页红色报错）
  }
  reqLoading.value = true;
  try {
    const res = await listRequests({ status: filter.status ?? undefined, page: page.value, pageSize });
    rows.value = res.list;
    total.value = res.total;
    if (res.pendingCount !== null) pendingCount.value = res.pendingCount;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '提现申请加载失败');
  } finally {
    reqLoading.value = false;
  }
}

/** 待处理数量：优先用列表响应里的 `pendingCount`；没有就单独探一次（pageSize=1 的 total） */
async function loadPendingCount() {
  if (!canReview.value) {
    pendingCount.value = null;
    return;
  }
  try {
    const res = await listRequests({ status: 'pending', page: 1, pageSize: 1 });
    pendingCount.value = res.pendingCount ?? res.total;
  } catch {
    pendingCount.value = null; // 取不到就显示「—」，不编数字
  }
}

function applyFilter() {
  page.value = 1;
  void loadRequests();
}

function resetFilter() {
  filter.status = null;
  applyFilter();
}

/** 页头那枚「待处理 N 笔」：点一下只看待处理，再点回到全部 */
function togglePendingOnly() {
  if (!canReview.value) return;
  filter.status = filter.status === 'pending' ? null : 'pending';
  applyFilter();
}

function onPageChange(p: number) {
  page.value = p;
  void loadRequests();
}

async function refreshAll() {
  await loadRequests();
  await loadPendingCount();
}

// ================================================================= 详情抽屉

const drawerOpen = ref(false);
const activeRow = ref<WithdrawRequestRow | null>(null);
const detail = ref<WithdrawRequestDetail | null>(null);
const detailLoading = ref(false);
const detailError = ref('');
const focusReject = ref(false);

const proofMediaId = ref<string | null>(null);
const payNote = ref('');
const rejectReason = ref('');
const rejectTouched = ref(false);
const paySaving = ref(false);
const rejecting = ref(false);

/** 抽屉头部用：详情没回来时先拿列表行顶上（不白屏） */
const head = computed<WithdrawRequestRow>(
  () =>
    detail.value ??
    activeRow.value ?? {
      id: '',
      workerNickname: '',
      workerNo: '',
      amount: 0,
      status: 'pending',
      account: null,
      accountMasked: null,
      payeeMasked: '',
      createdAt: null,
    },
);

/**
 * 抽屉「收款信息」三格：详情（完整值）优先；详情还没回来时**用列表行的完整值先顶上**
 * （列表现在就有完整姓名/电话/微信号 → 不必等详情；两边都没有才显示「—」）。
 */
const payee = computed(() => {
  const d = detail.value;
  const a = head.value.account;
  const m = head.value.accountMasked;
  return {
    realName: d?.payeeName || a?.realName || m?.realName || '',
    phone: d?.payeePhone || a?.phone || m?.phone || '',
    wechatId: d?.payeeWechat || a?.wechatId || m?.wechatId || '',
  };
});

/** blob 地址集中在抽屉生命周期里管：关闭时统一 revoke（否则每开一次漏一个对象 URL） */
const blobUrls: string[] = [];
function revokeAll() {
  while (blobUrls.length) {
    const u = blobUrls.pop();
    if (u) URL.revokeObjectURL(u);
  }
}
onBeforeUnmount(revokeAll);

const qrUrl = ref('');
const qrLoading = ref(false);
const qrError = ref('');
const payoutUrl = ref('');
const payoutLoading = ref(false);
const payoutError = ref('');

/**
 * 取收款码大图：**必须走受保护通道**（带 Authorization 取 blob）。
 * 失败时把服务端中文原文显示在图位里并给「重试」——不静默留白（运营会以为没有收款码）。
 */
async function loadQr(id: string) {
  if (!id || !canReview.value) return;
  qrLoading.value = true;
  qrError.value = '';
  try {
    const url = await withdrawProofUrl(id, 'qr');
    blobUrls.push(url);
    qrUrl.value = url;
  } catch (e) {
    qrError.value = e instanceof ApiException ? e.message : '收款码读取失败';
  } finally {
    qrLoading.value = false;
  }
}

async function loadPayoutProof(id: string) {
  if (!id || !canReview.value) return;
  payoutLoading.value = true;
  payoutError.value = '';
  try {
    const url = await withdrawProofUrl(id, 'payout');
    blobUrls.push(url);
    payoutUrl.value = url;
  } catch (e) {
    payoutError.value = e instanceof ApiException ? e.message : '打款凭证读取失败';
  } finally {
    payoutLoading.value = false;
  }
}

async function openDetail(r: WithdrawRequestRow, opts: { focusReject?: boolean } = {}) {
  activeRow.value = r;
  detail.value = null;
  detailError.value = '';
  drawerOpen.value = true;
  focusReject.value = opts.focusReject === true;
  // 每次打开都清空上一单的输入与图片（否则会把上一单的凭证提交到这一单上）
  revokeAll();
  qrUrl.value = '';
  qrError.value = '';
  payoutUrl.value = '';
  payoutError.value = '';
  proofMediaId.value = null;
  payNote.value = '';
  rejectReason.value = '';
  rejectTouched.value = false;

  if (!canReview.value) {
    detailError.value = '当前账号没有 withdraw:review 权限：详情与收款码会被服务端拒绝。';
    return;
  }
  detailLoading.value = true;
  try {
    const d = await getRequestDetail(r.id);
    detail.value = d;
    void loadQr(d.id || r.id);
    // 已打款的记录：把打款凭证也取出来（有凭证才取，避免无谓的 404 噪声）
    if (d.status === 'paid' && d.payout?.proofMediaId) void loadPayoutProof(d.id || r.id);
  } catch (e) {
    detailError.value = e instanceof ApiException ? e.message : '详情加载失败';
    message.error(detailError.value); // 服务端中文原文不吞
  } finally {
    detailLoading.value = false;
  }
}

/** 详情没取到时的「重试」（把当前这单重新拉一次，输入与图片一并重置） */
function retryDetail() {
  const r = activeRow.value;
  if (r) void openDetail(r);
}

function onDrawerClosed() {
  revokeAll();
  qrUrl.value = '';
  payoutUrl.value = '';
  activeRow.value = null;
  detail.value = null;
  detailError.value = '';
  focusReject.value = false;
}

// ================================================================= 打款

/**
 * 二次确认（硬要求）：确认文案必须写明**不可撤销**，并把打给谁、多少钱写清楚
 * （打款打错人是不可挽回的资金损失，确认框是最后一道人工闸门）。
 */
function confirmPay() {
  const d = detail.value;
  if (!d) return;
  if (!canPay.value) {
    message.warning('当前账号没有打款权限（需要 withdraw:pay）');
    return;
  }
  if (!proofMediaId.value) {
    message.warning('请先上传支付记录截图');
    return;
  }
  const who = `${d.workerNickname || '（无昵称）'}${d.workerNo ? `（工号 ${d.workerNo}）` : ''}`;
  dialog.warning({
    title: '确认已打款',
    content: `确认已向 ${who} 打款 ${formatYuan(d.amount)}？\n\n确认后将标记为已打款，此操作不可撤销；请确保上传的支付记录截图与这笔打款一致（凭证会留档供审计核对）。`,
    positiveText: `确认已打款 ${formatYuan(d.amount)}`,
    negativeText: '取消',
    onPositiveClick: async () => {
      if (paySaving.value) return;
      paySaving.value = true;
      submittingId.value = d.id;
      try {
        await payRequest(d.id, proofMediaId.value as string, payNote.value);
        message.success(`已标记打款：${who} ${formatYuan(d.amount)}`);
        drawerOpen.value = false;
        await refreshAll();
      } catch (e) {
        // 服务端中文原文（如「该申请已打款」）直接展示，不翻译、不吞
        message.error(e instanceof ApiException ? e.message : '标记打款失败');
      } finally {
        paySaving.value = false;
        submittingId.value = null;
      }
    },
  });
}

// ================================================================= 驳回

/** 驳回二次确认：必须提示**余额将退回打手**（这是与充值侧最大的一处语义差别） */
function confirmReject() {
  const d = detail.value;
  rejectTouched.value = true;
  if (!d) return;
  if (!canPay.value) {
    message.warning('当前账号没有驳回权限（需要 withdraw:pay）');
    return;
  }
  const reason = rejectReason.value.trim();
  if (!reason) {
    message.warning('驳回必须填写原因');
    return;
  }
  const who = `${d.workerNickname || '（无昵称）'}${d.workerNo ? `（工号 ${d.workerNo}）` : ''}`;
  dialog.warning({
    title: '确认驳回提现申请',
    content: `驳回 ${who} 的 ${formatYuan(d.amount)} 提现申请？\n\n驳回后余额将退回打手，原因会通知他；请确认这笔钱确实没有打出去，重复处理会被服务端拒绝。`,
    positiveText: '确认驳回（退回余额）',
    negativeText: '取消',
    onPositiveClick: async () => {
      if (rejecting.value) return;
      rejecting.value = true;
      submittingId.value = d.id;
      try {
        await rejectRequest(d.id, reason);
        message.success(`已驳回：${who} 的 ${formatYuan(d.amount)}，余额已退回打手`);
        drawerOpen.value = false;
        await refreshAll();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '驳回失败');
      } finally {
        rejecting.value = false;
        submittingId.value = null;
      }
    },
  });
}

// ================================================================= 首屏

/**
 * 首屏加载：**必须等 `auth.me` 就绪**（权限点来自 /auth/me）。
 * 与充值页同一个坑：子页面 `onMounted` 会先于 LayoutView 的 `auth.fetchMe()` 完成，
 * 此时权限为空数组 → 按权限分派的数据加载会直接 return（页面看着正常其实是空的）。
 */
const inited = ref(false);
async function init() {
  if (inited.value || !auth.me) return;
  inited.value = true;
  if (!canReview.value) return;
  await loadRequests();
  await loadPendingCount();
}
onMounted(() => void init());
watch(
  () => auth.me,
  () => void init(),
);

/** 从列表点「驳回」进来时，把焦点落到驳回原因输入框（一次点击直达要填的那一格） */
watch(focusReject, (v) => {
  if (!v || !drawerOpen.value) return;
  window.setTimeout(() => {
    // ⚠️ 选择器**不能**带 `.withdraw-page` 前缀：n-drawer 的默认 teleport 目标是 body，
    // 抽屉 DOM 不在 `.withdraw-page` 里面（实测会永远 focus 不到）。
    const el = document.querySelector<HTMLTextAreaElement>('.reject-input textarea');
    el?.focus();
  }, 260);
});
</script>

<style scoped>
.withdraw-page {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

/* 页头：左对齐、组内紧（标题与说明 6px）、组间松（与列表 16px）—— docs/21 的节奏要求 */
.head-line {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}
.page-head h1 {
  margin: 0;
  font-size: 17px;
  font-weight: 600;
}
.lede {
  margin: 6px 0 0;
  font-size: 12.5px;
  line-height: 1.75;
  color: var(--color-text-secondary);
  max-width: 900px;
}

/* 待处理数量：胶囊按钮（浅底 + 主色字 + 3px 小圆点），点一下切筛选 */
.pending-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 26px;
  padding: 0 10px;
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-pill);
  background: var(--color-bg-card);
  color: var(--color-text-secondary);
  font-size: 12.5px;
  cursor: pointer;
  transition: border-color var(--dur-fast) var(--ease), color var(--dur-fast) var(--ease);
}
.pending-chip:hover {
  border-color: var(--color-primary);
  color: var(--color-primary-text);
}
.pending-chip.is-on {
  border-color: var(--color-primary);
  color: var(--color-primary-text);
  background: var(--color-primary-soft);
}
.pending-chip b {
  font-weight: 650;
}
.pending-chip:disabled {
  cursor: not-allowed;
  opacity: 0.6;
}
.dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--color-warning);
}

.card {
  background: var(--color-bg-card);
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
  padding: 14px 16px 8px;
}

.filter-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 14px;
}
.spacer {
  flex: 1;
}
.count {
  font-size: 12.5px;
  color: var(--color-text-secondary);
}
.ro-hint {
  margin: 0;
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-warning);
}
.perm-block {
  padding: 28px 16px 30px;
  text-align: center;
  background: var(--color-bg-card);
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
}
.perm-title {
  font-size: 14px;
  font-weight: 600;
}
.perm-sub {
  margin-top: 6px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-tertiary);
}

/* 空态：说清"为什么空 + 下一步做什么"（docs/21 要求必须设计空态） */
.empty {
  padding: 28px 16px 30px;
  text-align: center;
}
.empty-title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}
.empty-sub {
  margin-top: 6px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-tertiary);
}

/* ---------------- 抽屉内 ---------------- */
/* 分区之间用发丝线，不堆卡片（docs/21：阴影只给弹层） */
.block {
  padding: 14px 0;
  border-top: 1px solid var(--color-divider);
}
.block:first-child {
  border-top: none;
  padding-top: 0;
}
.block-head {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex-wrap: wrap;
  margin-bottom: 10px;
}
.block-head h2 {
  margin: 0;
  font-size: 14px;
  font-weight: 600;
}
.block-sub {
  font-size: 12px;
  color: var(--color-text-tertiary);
  line-height: 1.6;
}

.who-line {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.who-name {
  font-size: 15px;
  font-weight: 650;
}
.who-no {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.amount-line {
  margin-top: 8px;
  font-size: 24px;
  font-weight: 650;
  color: var(--color-gold);
  letter-spacing: -0.01em;
}
.meta-line {
  margin-top: 4px;
  font-size: 12.5px;
  color: var(--color-text-secondary);
}

.kv {
  display: grid;
  grid-template-columns: 76px 1fr;
  row-gap: 8px;
  column-gap: 10px;
  margin: 0;
  font-size: 13px;
}
.kv dt {
  color: var(--color-text-tertiary);
  font-size: 12.5px;
}
.kv dd {
  margin: 0;
  color: var(--color-text-primary);
  word-break: break-all;
}
.kv dd.dim {
  color: var(--color-text-tertiary);
}

.qr-box {
  margin-top: 10px;
  min-height: 120px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 10px;
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-control);
  background: var(--color-bg-sunken);
}
.qr-img {
  border-radius: 4px;
  overflow: hidden;
}
.qr-holder {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  font-size: 12.5px;
  color: var(--color-text-tertiary);
  text-align: center;
  line-height: 1.7;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 12px;
}
.field-label {
  font-size: 13px;
  color: var(--color-text-secondary);
}
.req {
  margin-left: 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--color-error);
}
.opt {
  margin-left: 6px;
  font-size: 12px;
  font-style: normal;
  color: var(--color-text-tertiary);
}
.mini-hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.ops {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  margin-top: 10px;
}
.err {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--color-error);
}
.result-alert {
  margin-bottom: 10px;
}
.reject-warn {
  margin-bottom: 10px;
}

.detail-error {
  padding: 24px 8px;
  text-align: center;
}
.detail-error-title {
  font-size: 14px;
  font-weight: 600;
}
.detail-error-sub {
  margin: 6px 0 12px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-secondary);
}
</style>
