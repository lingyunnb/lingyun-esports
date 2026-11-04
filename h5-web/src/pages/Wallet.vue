<script setup lang="ts">
/**
 * 余额明细（H5）
 * ============================================================================
 * 数据源：`GET /user/wallet/transactions?page=&pageSize=`
 *   → `{ list: [{ id, transactionNo, changeType, amount, balanceBefore, balanceAfter, reason, createdAt }], total, page, pageSize }`
 *   （实测字段来自 `WalletService.userTransactions`；**只有用户自己的流水**，主体 id 取自 JWT）
 *
 * 金额着色：**收入用青瓷 `var(--celadon)`、支出用 `var(--g1)`**，一律带正负号 + `¥`；
 * 类型中文名镜像 App 端 `worker_wallet_page.dart` 的口径（同一份 changeType 词表，不另发明）。
 *
 * 硬约束：白底为主 · 4dp 网格间距（只用 var(--s1..s16)）· 颜色全 token · 零 emoji。
 */
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import PageHead from '@/components/PageHead.vue';
import { ApiError, walletApi } from '@/api';
import { http } from '@/api/client';
import { fmtMoney, fmtTime } from '@/utils/format';

const router = useRouter();
type Any = Record<string, unknown>;

const PAGE_SIZE = 20;

const list = ref<Any[]>([]);
const total = ref(0);
const page = ref(1);
const loading = ref(false);
const firstLoading = ref(true);
const errMsg = ref('');

/** 余额（可选展示，失败不阻塞流水） */
const balance = ref<string | null>(null);

const hasMore = computed(() => list.value.length < total.value);

/** changeType → 中文（与 App 端同词表；未知落「余额变动」，绝不裸显示英文码） */
const TYPE_TEXT: Record<string, string> = {
  order_pay: '订单支出',
  order_refund: '订单退款',
  refund: '退款',
  grant: '平台发放',
  recover: '退回调整',
  order_settlement: '订单结算',
  order_tip_income: '打赏收入',
  settlement_reversal: '结算冲正',
  platform_commission: '平台服务费',
  platform_commission_reversal: '服务费冲正',
  recharge: '充值发放',
  recharge_granted: '充值已发放',
  withdraw: '提现',
  withdraw_refund: '提现退回',
  withdraw_reject: '提现驳回退回',
  withdraw_deduct: '提现扣款',
};

function amountNum(t: Any): number {
  const n = typeof t.amount === 'number' ? t.amount : parseFloat(String(t.amount ?? '0').replace(/[^\d.-]/g, ''));
  return Number.isFinite(n) ? n : 0;
}
function isIncome(t: Any): boolean {
  return amountNum(t) >= 0;
}
function signed(t: Any): string {
  const n = amountNum(t);
  return `${n >= 0 ? '+' : '-'}¥${fmtMoney(Math.abs(n))}`;
}
function typeText(t: Any): string {
  const code = String(t.changeType ?? '');
  return TYPE_TEXT[code] ?? '余额变动';
}
/** 说明：服务端 `reason` 优先；没有就用类型名（不编造） */
function descText(t: Any): string {
  const r = String(t.reason ?? '').trim();
  return r || typeText(t);
}
function balanceAfterText(t: Any): string {
  const v = t.balanceAfter;
  if (v === undefined || v === null || v === '') return '';
  return `余额 ¥${fmtMoney(v)}`;
}

async function load(reset: boolean) {
  if (loading.value) return;
  loading.value = true;
  errMsg.value = '';
  if (reset) {
    page.value = 1;
    firstLoading.value = true;
  }
  try {
    const r = await walletApi.transactions({ page: page.value, pageSize: PAGE_SIZE });
    const items = Array.isArray(r?.list) ? (r.list as Any[]) : [];
    list.value = reset ? items : [...list.value, ...items];
    total.value = Number(r?.total ?? list.value.length);
  } catch (e) {
    errMsg.value = e instanceof ApiError ? e.message : '加载失败，请稍后重试';
  } finally {
    loading.value = false;
    firstLoading.value = false;
  }
}

/** 余额卡：`GET /user/wallet`（失败静默，不影响流水展示） */
async function loadBalance() {
  try {
    const w = await http.get<Record<string, unknown>>('/user/wallet');
    const v = w?.balance;
    balance.value = v === undefined || v === null || v === '' ? null : String(v);
  } catch {
    balance.value = null;
  }
}

onMounted(() => {
  void load(true);
  void loadBalance();
});
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="余额明细" />

    <!-- 余额卡：白底，唯一色块是主色链接 -->
    <div class="h5-card bl">
      <div class="bl__l">
        <span class="bl__k">当前余额</span>
        <span class="bt">{{ balance === null ? '查询中…' : `¥${fmtMoney(balance)}` }}</span>
      </div>
      <button class="bl__a" type="button" @click="router.push({ name: 'recharge' })">去充值</button>
    </div>

    <div class="h5-sec">
      <span class="h5-sec__t">全部流水</span>
      <span v-if="total" class="h5-sec__x">{{ total }} 笔</span>
    </div>

    <div v-if="firstLoading" class="h5-card--flush h5-card">
      <div v-for="i in 4" :key="i" class="rw">
        <div class="rw__m">
          <div class="h5-skel sk__l sk__l--w50" />
          <div class="h5-skel sk__l sk__l--w30" />
        </div>
      </div>
    </div>

    <div v-else-if="errMsg && !list.length" class="h5-empty">
      <p class="em__t">{{ errMsg }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm em__b" type="button" @click="load(true)">重试</button>
    </div>

    <div v-else-if="!list.length" class="h5-empty">还没有余额流水</div>

    <!-- 流水行：发丝线分隔（列表不用卡片） -->
    <template v-else>
      <div class="h5-card h5-card--flush">
        <div v-for="t in list" :key="String(t.id)" class="rw">
          <div class="rw__m">
            <div class="rw__t">
              <span class="rw__ty">{{ typeText(t) }}</span>
              <span class="rw__time">{{ fmtTime(String(t.createdAt ?? '')) }}</span>
            </div>
            <div class="rw__d">{{ descText(t) }}</div>
            <div v-if="balanceAfterText(t)" class="rw__b">{{ balanceAfterText(t) }}</div>
          </div>
          <span class="rw__a" :class="isIncome(t) ? 'rw__a--in' : 'rw__a--out'">{{ signed(t) }}</span>
        </div>
      </div>

      <div class="more">
        <button v-if="hasMore" class="more__b" type="button" :disabled="loading" @click="page += 1, load(false)">
          {{ loading ? '加载中…' : '加载更多' }}
        </button>
        <p v-else class="more__end">共 {{ total }} 笔 · 已到底</p>
      </div>
    </template>
  </div>
</template>

<style scoped>
/* ---------- 余额卡 ---------- */
.bl { display: flex; align-items: center; gap: var(--s3); }
.bl__l { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--s1); }
.bl__k { font-size: var(--f5); color: var(--g3); }
.bt { font-size: var(--f1); font-weight: 800; color: var(--g1); font-variant-numeric: tabular-nums; }
.bl__a {
  flex: 0 0 auto;
  height: var(--h-btn-sm);
  padding: 0 var(--s3);
  background: var(--card);
  border: 1px solid var(--pri);
  border-radius: var(--r-ctrl);
  color: var(--pri);
  font-size: var(--f5);
  font-weight: 700;
  cursor: pointer;
}

/* ---------- 流水行 ---------- */
.rw {
  display: flex;
  align-items: flex-start;
  gap: var(--s3);
  padding: var(--s3) var(--card-pad-x);
  border-bottom: 1px solid var(--g5);
}
.rw:last-child { border-bottom: 0; }
.rw__m { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--s1); }
.rw__t { display: flex; align-items: baseline; gap: var(--s2); flex-wrap: wrap; }
.rw__ty { font-size: var(--f3); font-weight: 700; color: var(--g1); }
.rw__time { font-size: var(--f6); color: var(--g3); font-variant-numeric: tabular-nums; }
.rw__d { font-size: var(--f5); color: var(--g2); line-height: 1.5; word-break: break-word; }
.rw__b { font-size: var(--f6); color: var(--g3); font-variant-numeric: tabular-nums; }
.rw__a {
  flex: 0 0 auto;
  font-size: var(--f3);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
/* 收入 = 青瓷；支出 = 正文灰阶（`--g1`），金额不靠"红绿"区分 */
.rw__a--in { color: var(--celadon); }
.rw__a--out { color: var(--g1); }

/* ---------- 骨架 / 空态 / 更多 ---------- */
.sk__l { height: 12px; }
.sk__l--w50 { width: 50%; }
.sk__l--w30 { width: 30%; }
.rw__m .sk__l + .sk__l { margin-top: var(--s2); }
.em__t { margin: 0 0 var(--s3); }
.em__b { margin: 0 auto; }
.more { padding: var(--s3) var(--page-x) var(--s5); text-align: center; }
.more__b {
  height: var(--h-btn-sm);
  padding: 0 var(--s4);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  color: var(--g2);
  font-size: var(--f5);
  cursor: pointer;
}
.more__end { margin: 0; font-size: var(--f6); color: var(--g3); }
</style>
