<script setup lang="ts">
/**
 * 工作台（2026-10-11 深色科技风改版）
 * ============================================================================
 * 结构（负责人定案）：
 *   ① **快捷导航六宫格** —— 六张彩色图标卡 + 一行说明；按权限点过滤，取前 6 个
 *   ② **数据概览卡** —— 小标签「累计 / 今日 / 实时」+ 大数字 + 一行说明
 *
 * ## 数据全部来自**现成接口**（一行后端都没改，也没有新造聚合接口）
 *   · `GET /admin/commission/stats`  → 累计订单数/累计订单金额（并集今日平台抽成，现为 0 也如实显示）
 *   · `GET /admin/users?page=1&pageSize=1`   → `total` = 累计用户数
 *   · `GET /admin/workers?page=1&pageSize=1` → `total` = 打手档案数
 *   · `GET /admin/wallets?page=1&pageSize=1` → `total` = 有余额账户数
 *   · `GET /admin/orders?status=pending_take&pageSize=1` → 待接单（实时）
 *   · `GET /admin/recharge/requests?status=pending&pageSize=1` → `pendingTotal` = 待核对充值（实时）
 *   · `GET /admin/complaints?pageSize=1` → `stat.pending` = 未处理工单（实时）
 *
 * ## 权限
 * 每张卡都先过 `auth.hasPermission(...)`：**没权限就不发那个请求**（避免无谓 403 噪音），
 * 也没权限就不渲染那张卡 —— 与侧栏菜单同一套判定，真正的权威仍是服务端。
 *
 * 原「当前账号权限」卡与退出按钮**已移除**：退出按钮在顶栏（全局唯一），
 * 权限点列表在「管理员与角色」页可查 —— 工作台首页不再堆这些调试信息（docs/21 反 AI 味）。
 */
import { ApiException, request } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { AmountLike, formatYuan } from '@/utils/format';
import { NTag, useMessage } from 'naive-ui';
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';

const auth = useAuthStore();
const router = useRouter();
const message = useMessage();
const loading = ref(true);

interface IconDef {
  d: string;
}
/** 线性图标（1.8 描边、24 视框，与 Flutter 侧 Material outlined 同一体系；禁拟物/emoji） */
const ICONS: Record<string, IconDef> = {
  workers: { d: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM4.5 20a7.5 7.5 0 0 1 15 0M18.5 8.5 20 10l2.5-2.5' },
  wallets: { d: 'M3 8.5A2.5 2.5 0 0 1 5.5 6H18a2 2 0 0 1 2 2v1M3 8.5V17a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-2M3 8.5h14M21 12h-3.5a2 2 0 0 0 0 4H21z' },
  recharge: { d: 'M4 7.5A2.5 2.5 0 0 1 6.5 5H17a2 2 0 0 1 2 2v1M4 7.5V17a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1.5M4 7.5h13M21 11.5h-4.5a2.25 2.25 0 0 0 0 4.5H21z' },
  catalog: { d: 'M4 8.5 12 4l8 4.5v7L12 20l-8-4.5zM4 8.5 12 13l8-4.5M12 13v7' },
  orders: { d: 'M7 3.5h8.5L19 7v13.5H7zM15 3.5V7h3.5M10 11h6M10 14.5h6M10 18h4' },
  users: { d: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM2.5 20a6.5 6.5 0 0 1 13 0M16.5 5.2a3.5 3.5 0 0 1 0 6.6M18 20a6.6 6.6 0 0 0-1.2-3.8' },
  settings: { d: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 1.55V21a2 2 0 1 1-4 0v-.07A1.7 1.7 0 0 0 9 19.4a1.7 1.7 0 0 0-1.87.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.55-1H3a2 2 0 1 1 0-4h.07A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.33-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.7 1.7 0 0 0 9 4.6h.08A1.7 1.7 0 0 0 10 3.05V3a2 2 0 1 1 4 0v.07a1.7 1.7 0 0 0 1 1.55 1.7 1.7 0 0 0 1.87-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.7 1.7 0 0 0 19.4 9v.08a1.7 1.7 0 0 0 1.55 1H21a2 2 0 1 1 0 4h-.07a1.7 1.7 0 0 0-1.53 1Z' },
  commission: { d: 'M20.5 6.5 14 13l-3.5-3.5L4 16M20.5 6.5h-4.2M20.5 6.5v4.2' },
  chat: { d: 'M20 13.5A3.5 3.5 0 0 1 16.5 17H11l-4.5 3.5V17H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h10.5A3.5 3.5 0 0 1 20 8.5z' },
  leaderboard: { d: 'M4 20V11M12 20V5M20 20v-6M3 20h18' },
  appeals: { d: 'M12 3.5 3.5 19h17zM12 10v4M12 16.5v.01' },
  audit: { d: 'M12 3.5 5 6v6c0 4.2 3 7.4 7 8.5 4-1.1 7-4.3 7-8.5V6zM9 12l2 2 4-4' },
  divisions: { d: 'M12 3.5 20.5 8 12 12.5 3.5 8zM4 12.5 12 17l8-4.5' },
  announcements: { d: 'M4 9.5v5l3 .5 1 4.5h2l-.8-4.3L19 18V4zM7 10h2' },
  refunds: { d: 'M9 14 4 9l5-5M4 9h9a6 6 0 0 1 0 12H8' },
  complaints: { d: 'M8 3.5h8v4H8zM7 7.5h10v13H7zM10 12h4M10 15h4' },
  admins: { d: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM4.5 20a7.5 7.5 0 0 1 15 0M17 3.5l1.2 2.5 2.5 1.2-2.5 1.2-1.2 2.5' },
  feedback: { d: 'M20 12a7.5 7.5 0 0 1-7.5 7.5H8L4 22V12a7.5 7.5 0 0 1 7.5-7.5H12A7.6 7.6 0 0 1 20 12ZM8.5 11h7M8.5 14h4' },
  appUpdate: { d: 'M12 15V4M8 7.5 12 3.5l4 4M4.5 15.5v2A2.5 2.5 0 0 0 7 20h10a2.5 2.5 0 0 0 2.5-2.5v-2' },
  tips: { d: 'M12 4.5v15M8 8.5h6a2.5 2.5 0 0 1 0 5H9a2.5 2.5 0 0 0 0 5h7' },
  identity: { d: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM2.5 20a6.5 6.5 0 0 1 13 0M17 9.5h5M19.5 7v5' },
  clubs: { d: 'M12 3.5 5.5 7v5.5c0 4 2.8 7 6.5 8 3.7-1 6.5-4 6.5-8V7z M9.5 12l1.8 1.8 3.4-3.6' },
  banners: { d: 'M3.5 6.5h17v11h-17zM3.5 11h17M8 15h4' },
  site: { d: 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17ZM3.5 12h17M12 3.5c2.2 2.3 3.4 5.3 3.4 8.5S14.2 18.2 12 20.5c-2.2-2.3-3.4-5.3-3.4-8.5S9.8 5.8 12 3.5Z' },
  orderForm: { d: 'M6 3.5h9l4 4v13H6zM15 3.5v4h4M9.5 12h6M9.5 15.5h4' },
};

/** 快捷导航候选（按顺序取前 6 个有权限的）：彩色图标卡 + 一行说明 */
const NAV_CANDIDATES = [
  { key: 'wallets', title: '余额管理', desc: '发放 / 回收余额，逐笔流水可回溯', perm: 'admin:wallet:read', accent: '#1D5FA8' },
  { key: 'recharge', title: '充值管理', desc: '线下扫码申请的人工核对与发放', perm: 'admin:setting:read', accent: '#0E7C7B' },
  { key: 'orders', title: '订单管理', desc: '全量订单检索、派单与强制完成', perm: 'admin:order:read', accent: '#0E7C7B' },
  { key: 'catalog', title: '游戏与商品', desc: '游戏 / 分部 / 分类 / 商品的上下架', perm: 'admin:product:write', accent: '#D97706' },
  { key: 'users', title: '用户管理', desc: '老板账号检索、封禁与解封', perm: 'admin:user:read', accent: '#0891B2' },
  { key: 'settings', title: '系统设置', desc: '平台抽成比例等全局参数', perm: 'admin:setting:read', accent: '#16A34A' },
  // 备用位（前六个不足时补位，保证"六宫格"在该账号权限下尽量满格）
  { key: 'workers', title: '工作端管理', desc: '打手档案、接单授权与资料', perm: 'admin:worker:read', accent: '#EA580C' },
  { key: 'commission', title: '抽成中心', desc: '结算流水与平台抽成明细', perm: 'admin:order:read', accent: '#DB2777' },
  { key: 'appeals', title: '售后管理', desc: '申诉裁决：退款或驳回', perm: 'admin:appeal:handle', accent: '#DC2626' },
  { key: 'refunds', title: '退款审批', desc: '退款申请审批与冲正', perm: 'admin:refund:read', accent: '#0E7C7B' },
  { key: 'complaints', title: '投诉工单', desc: '用户投诉的分派与处理', perm: 'admin:complaint:read', accent: '#F59E0B' },
  { key: 'chat', title: '聊天管理', desc: '客服会话与聊天记录查阅', perm: 'admin:chat:read', accent: '#0891B2' },
  { key: 'leaderboard', title: '排行榜', desc: '有效金额榜与人工调整', perm: 'admin:leaderboard:read', accent: '#D97706' },
  { key: 'audit', title: '安全审计', desc: '登录日志与异常行为排查', perm: 'admin:audit:read', accent: '#16A34A' },
  { key: 'announcements', title: '公告管理', desc: 'App 公告与关于 / 隐私文案', perm: 'admin:home:write', accent: '#1D5FA8' },
  { key: 'admins', title: '管理员与角色', desc: '后台账号、角色与权限点', perm: 'admin:admin:read', accent: '#475569' },
];

const navCards = computed(() =>
  NAV_CANDIDATES.filter((n) => auth.hasPermission(n.perm)).slice(0, 6),
);

/* ------------------------------------------------------------------ 数据概览 */
interface StatCard {
  tag: '累计' | '今日' | '实时';
  label: string;
  value: string;
  /** 数值与单位分开渲染：¥ 用琥珀金、数字更大（金额清晰可读） */
  prefix?: string;
  desc: string;
  gold?: boolean;
}

const commission = ref<{
  totalOrderAmount: number;
  totalPlatform: number;
  todayPlatform: number;
  orderCount: number;
  settledCount: number;
  commissionRate: number;
} | null>(null);
const userTotal = ref<number | null>(null);
const workerTotal = ref<number | null>(null);
const walletTotal = ref<number | null>(null);
const pendingTake = ref<number | null>(null);
const pendingRecharge = ref<number | null>(null);
const pendingComplaint = ref<number | null>(null);

const nf = (n: number) => n.toLocaleString('zh-CN');
/*
 * 金额显示**必须**走 `@/utils/format.ts`（管理端唯一实现：`¥` + 恒两位小数 + 千分位）。
 * 此前这里自己写了一份 `¥${n.toLocaleString('zh-CN', {...})}`，与全站口径**重复实现** ——
 * 正是 format.ts 文件头点名禁止的写法（"分散实现必然出现三种写法"）。
 * 虽然当前参数恰好等价，但任何一处口径调整（负数写法、千分位、缺失值占位）都会只改一半。
 */
const yuan = (n: AmountLike) => formatYuan(n);

const statCards = computed<StatCard[]>(() => {
  const out: StatCard[] = [];
  if (commission.value) {
    const c = commission.value;
    out.push({
      tag: '累计',
      label: '累计订单数',
      value: nf(c.orderCount),
      desc: `已结算 ${nf(c.settledCount)} 单 · 累计订单金额 ${yuan(c.totalOrderAmount)}`,
    });
    out.push({
      tag: '累计',
      label: '平台累计抽成',
      value: yuan(c.totalPlatform),
      desc: `当前抽成比例 ${c.commissionRate}%（打手 ${100 - c.commissionRate}%）`,
      gold: true,
    });
    out.push({
      tag: '今日',
      label: '今日平台抽成',
      value: yuan(c.todayPlatform),
      desc: c.todayPlatform > 0 ? '按今日结算实时汇总' : '今日暂无结算，故为 ¥0.00',
      gold: true,
    });
  }
  if (userTotal.value !== null || workerTotal.value !== null) {
    out.push({
      tag: '累计',
      label: '账号概览',
      value: nf(userTotal.value ?? 0),
      desc: `老板 / 工作端账号合计${workerTotal.value !== null ? ` · 打手档案 ${nf(workerTotal.value)} 个` : ''}${walletTotal.value !== null ? ` · 有余额账户 ${nf(walletTotal.value)} 个` : ''}`,
    });
  }
  const realtime: string[] = [];
  if (pendingTake.value !== null) realtime.push(`待接单 ${nf(pendingTake.value)} 单`);
  if (pendingRecharge.value !== null) realtime.push(`待核对充值 ${nf(pendingRecharge.value)} 笔`);
  if (pendingComplaint.value !== null) realtime.push(`未处理工单 ${nf(pendingComplaint.value)} 件`);
  if (realtime.length) {
    out.push({
      tag: '实时',
      label: '待处理事项',
      value: nf((pendingTake.value ?? 0) + (pendingRecharge.value ?? 0) + (pendingComplaint.value ?? 0)),
      desc: realtime.join(' · '),
    });
  }
  return out;
});

/** 每个请求都先判权限：没权限就不发（省掉无意义的 403） */
async function loadStats() {
  const jobs: Promise<void>[] = [];
  const has = (p: string) => auth.hasPermission(p);

  if (has('admin:order:read')) {
    jobs.push(
      request<typeof commission.value>('GET', '/admin/commission/stats')
        .then((d) => void (commission.value = d))
        .catch(() => void 0),
    );
  }
  if (has('admin:user:read')) {
    jobs.push(
      request<{ total: number }>('GET', '/admin/users?page=1&pageSize=1')
        .then((d) => void (userTotal.value = d.total))
        .catch(() => void 0),
    );
  }
  if (has('admin:worker:read')) {
    jobs.push(
      request<{ total: number }>('GET', '/admin/workers?page=1&pageSize=1')
        .then((d) => void (workerTotal.value = d.total))
        .catch(() => void 0),
    );
  }
  if (has('admin:wallet:read')) {
    jobs.push(
      request<{ total: number }>('GET', '/admin/wallets?page=1&pageSize=1')
        .then((d) => void (walletTotal.value = d.total))
        .catch(() => void 0),
    );
  }
  if (has('admin:order:read')) {
    jobs.push(
      request<{ total: number }>('GET', '/admin/orders?status=pending_take&page=1&pageSize=1')
        .then((d) => void (pendingTake.value = d.total))
        .catch(() => void 0),
    );
  }
  if (has('recharge:review')) {
    jobs.push(
      request<{ pendingTotal?: number }>('GET', '/admin/recharge/requests?status=pending&page=1&pageSize=1')
        .then((d) => void (pendingRecharge.value = d.pendingTotal ?? 0))
        .catch(() => void 0),
    );
  }
  if (has('admin:complaint:read')) {
    jobs.push(
      request<{ stat?: Record<string, number> }>('GET', '/admin/complaints?page=1&pageSize=1')
        .then((d) => void (pendingComplaint.value = d.stat?.pending ?? 0))
        .catch(() => void 0),
    );
  }
  await Promise.all(jobs);
}

onMounted(async () => {
  try {
    await auth.fetchMe();
  } catch (e) {
    // 会话失效统一由 api client 跳登录页；这里只在"确实拿不到身份"时兜底跳一次
    if (e instanceof ApiException && e.code === 401) return;
    void router.push({ name: 'login' });
    return;
  } finally {
    loading.value = false;
  }
  try {
    await loadStats();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '数据概览加载失败');
  }
});

/** 刷新当前页时由外壳重建组件 → 重新取数（keep-alive 之外的第二次进入也一样） */
defineExpose({ reload: loadStats });
</script>

<template>
  <div class="dashboard">
    <!-- 页头：只有一句问候 + 日期，不放"当前账号权限"这类调试信息 -->
    <header class="dash-head">
      <div>
        <h1 class="dash-title">
          {{ auth.me ? `${auth.me.nickname}，您好` : '工作台' }}
        </h1>
        <p class="dash-sub">
          今天也请按规范操作：金额一律 ¥ 两位小数，管理员动作全部留痕。
        </p>
      </div>
      <n-tag v-if="auth.isSuperAdmin" type="primary" size="small" :bordered="false">超级管理员</n-tag>
    </header>

    <!-- ① 快捷导航六宫格 -->
    <section class="block">
      <div class="block-head">
        <h2 class="block-title">快捷导航</h2>
        <span class="block-hint">按你的权限点显示，最多 6 个</span>
      </div>
      <div class="nav-grid">
        <button
          v-for="n in navCards"
          :key="n.key"
          class="nav-card"
          type="button"
          :data-nav="n.key"
          @click="router.push({ name: n.key })"
        >
          <span class="nav-icon" :style="{ '--accent': n.accent }">
            <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
              <path :d="ICONS[n.key]?.d ?? ICONS.catalog.d" />
            </svg>
          </span>
          <span class="nav-text">
            <span class="nav-title">{{ n.title }}</span>
            <span class="nav-desc">{{ n.desc }}</span>
          </span>
        </button>
      </div>
      <p v-if="!navCards.length" class="nav-empty">
        当前账号还没有任何模块权限 —— 请联系超级管理员在「管理员与角色」里勾选。
      </p>
    </section>

    <!-- ② 数据概览卡 -->
    <section class="block">
      <div class="block-head">
        <h2 class="block-title">数据概览</h2>
        <span class="block-hint">累计 / 今日取统计接口，实时取待处理列表</span>
      </div>
      <div v-if="statCards.length" class="stat-grid">
        <article v-for="s in statCards" :key="s.label" class="stat-card" :data-stat="s.label">
          <span class="stat-tag">{{ s.tag }}</span>
          <div class="stat-value" :class="{ 'is-money': s.gold }">{{ s.value }}</div>
          <div class="stat-label">{{ s.label }}</div>
          <p class="stat-desc">{{ s.desc }}</p>
        </article>
      </div>
      <p v-else-if="!loading" class="stat-empty">
        暂无可展示的统计项（当前角色没有订单 / 用户 / 余额 / 工单的读取权限）。
      </p>
      <div v-else class="stat-grid">
        <div v-for="i in 4" :key="i" class="stat-card is-skeleton" />
      </div>
    </section>
  </div>
</template>

<style scoped>
.dashboard {
  display: flex;
  flex-direction: column;
  /* 组间松（24），组内紧（10）：docs/21 的间距节奏 */
  gap: 24px;
  max-width: 1320px;
}

/* ------------------------------------------------------------------ 页头 */
.dash-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
}
.dash-title {
  margin: 0;
  font-size: 20px;
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--color-text-primary);
}
.dash-sub {
  margin: 6px 0 0;
  font-size: 13px;
  color: var(--color-text-secondary);
}

.block {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.block-head {
  display: flex;
  align-items: baseline;
  gap: 10px;
}
.block-title {
  margin: 0;
  font-size: 15px;
  font-weight: 650;
  color: var(--color-text-primary);
}
.block-hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}

/* ------------------------------------------------------------------ 六宫格 */
.nav-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}
@media (max-width: 1100px) {
  .nav-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

.nav-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px 16px;
  text-align: left;
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
  background: var(--color-bg-card);
  cursor: pointer;
  transition:
    transform var(--dur-fast) var(--ease),
    border-color var(--dur-fast) var(--ease),
    box-shadow var(--dur-fast) var(--ease);
}
.nav-card:hover {
  /* hover 只做 1px 位移 + 描边转主色（不用大阴影，docs/21 反 AI 味） */
  transform: translateY(-1px);
  border-color: color-mix(in srgb, var(--color-primary) 45%, var(--color-divider));
  box-shadow: var(--shadow-card);
}
.nav-card:active {
  transform: none;
}
.nav-card:focus-visible {
  outline: 2px solid var(--color-primary);
  outline-offset: 2px;
}

.nav-icon {
  width: 38px;
  height: 38px;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 10px;
  /* 彩色图标卡：浅底 + 同色线性图标（不是彩色实心块，避免"每条信息配彩色标签"的 AI 味） */
  color: var(--accent);
  background: color-mix(in srgb, var(--accent) 12%, transparent);
  transition: background var(--dur-fast) var(--ease);
}
.nav-card:hover .nav-icon {
  background: color-mix(in srgb, var(--accent) 18%, transparent);
}
.nav-text {
  display: flex;
  flex-direction: column;
  min-width: 0;
  gap: 3px;
}
.nav-title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}
.nav-desc {
  font-size: 12px;
  line-height: 1.45;
  color: var(--color-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.nav-empty,
.stat-empty {
  margin: 0;
  padding: 16px;
  font-size: 13px;
  color: var(--color-text-secondary);
  border: 1px dashed var(--color-divider);
  border-radius: var(--radius-card);
}

/* ------------------------------------------------------------------ 数据概览卡 */
.stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 12px;
}
.stat-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 18px 18px 16px;
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
  background: var(--color-bg-card);
  transition: border-color var(--dur-fast) var(--ease);
}
.stat-card:hover {
  border-color: color-mix(in srgb, var(--color-primary) 30%, var(--color-divider));
}
.stat-card.is-skeleton {
  height: 132px;
  background: var(--color-bg-sunken);
  border-style: dashed;
  animation: pulse 1.4s ease-in-out infinite;
}
@keyframes pulse {
  0%,
  100% {
    opacity: 0.6;
  }
  50% {
    opacity: 1;
  }
}

.stat-tag {
  align-self: flex-start;
  padding: 1px 7px;
  font-size: 11px;
  line-height: 17px;
  /* 倒角标签（小标签「累计 / 今日 / 实时」）：文字读主色文字态，深色档才够 AA */
  border-radius: var(--radius-tag);
  color: var(--color-primary-text);
  background: var(--color-primary-soft);
  letter-spacing: 0.02em;
}
.stat-value {
  font-size: 30px;
  font-weight: 700;
  line-height: 1.15;
  letter-spacing: -0.02em;
  font-variant-numeric: tabular-nums;
  color: var(--color-text-primary);
}
/* 金额：琥珀金（价格/等级唯一色）；深色档自动用提亮版 --color-gold */
.stat-value.is-money {
  color: var(--color-gold);
}
.stat-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-secondary);
}
.stat-desc {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--color-text-tertiary);
}
</style>
