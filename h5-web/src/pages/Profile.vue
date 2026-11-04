<script setup lang="ts">
/**
 * 我的（H5）
 * ============================================================================
 * 数据源：
 *   `GET /auth/me`（经 `useAuthStore().me`）→ id / username / uid / nickname / avatarMediaId /
 *     backgroundMediaId / role / status / level / totalSpent（**实测无 balance 字段**）
 *   `GET /user/wallet` → `{ balance }`（页内直接补这一枪，因为 `/auth/me` 不下发余额；失败静默）
 *
 * 页面结构（结构规则 4「我的页只留余额卡 + 我的订单 + 服务宫格」）：
 *   资料卡 → 余额卡（进明细 / 进充值）→ 服务入口（我的订单 / 公告 / 关于我们）→ 退出登录
 *
 * **不编造事实文案**：营业时间之类没有接口的文案一律不写；「关于我们」用公开接口
 *   `/public/about`，取不到就只显示应用名与版本，不补自造简介。
 *
 * 硬约束：白底为主 · 4dp 网格间距 · 颜色全 token · 零 emoji · 内联 SVG 图标。
 */
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ApiError, publicApi } from '@/api';
import { http } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { fmtMoney } from '@/utils/format';

const router = useRouter();
const auth = useAuthStore();

const APP_VERSION = '0.1.0';

const balance = ref<string | null>(null);
const balanceErr = ref('');
const about = ref<Record<string, unknown> | null>(null);

const me = computed<Record<string, unknown>>(() => (auth.me ?? {}) as Record<string, unknown>);
const nickname = computed(() => String(me.value.nickname || me.value.username || '未设置昵称'));
const displayId = computed(() => String(me.value.uid || ''));
const level = computed(() => {
  const n = Number(me.value.level ?? 0);
  return Number.isFinite(n) && n > 0 ? n : 0;
});
const avatarId = computed(() => {
  const v = me.value.avatarMediaId;
  return v === undefined || v === null || v === '' ? '' : String(v);
});

/** 关于我们：优先用公开接口文案，取不到就只给应用名（不补自造内容） */
const aboutText = computed(() => {
  const a = about.value;
  if (!a) return '';
  for (const k of ['content', 'intro', 'description', 'summary']) {
    const v = a[k];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return '';
});

async function loadBalance() {
  try {
    const w = await http.get<Record<string, unknown>>('/user/wallet');
    const v = w?.balance;
    balance.value = v === undefined || v === null || v === '' ? null : String(v);
    balanceErr.value = '';
  } catch (e) {
    balance.value = null;
    balanceErr.value = e instanceof ApiError ? e.message : '余额获取失败';
  }
}

async function loadAbout() {
  try {
    about.value = await publicApi.about();
  } catch {
    about.value = null;
  }
}

const showAbout = ref(false);
function toggleAbout() {
  showAbout.value = !showAbout.value;
}

function logout() {
  auth.logout();
  router.replace({ name: 'login' }).catch(() => {});
}

onMounted(() => {
  // `/auth/me` 不含余额 → 页内单独补一枪；同时刷新一次 me（拿到最新的等级/昵称）
  if (!auth.me) void auth.fetchMe();
  void loadBalance();
  void loadAbout();
});
</script>

<template>
  <div class="h5-page">
    <!-- ① 资料卡 -->
    <div class="h5-card pf">
      <div class="pf__av" aria-hidden="true">
        <img v-if="avatarId" class="pf__img" :src="`/api/v1/media/protected/${avatarId}`" alt="" />
        <svg v-else width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <circle cx="12" cy="8.5" r="3.5" /><path d="M5 20c1.3-3.3 3.9-5 7-5s5.7 1.7 7 5" stroke-linecap="round" />
        </svg>
      </div>
      <div class="pf__m">
        <div class="pf__top">
          <h1 class="pf__n">{{ nickname }}</h1>
          <span v-if="level" class="pf__lv">Lv.{{ level }}</span>
        </div>
        <p v-if="displayId" class="pf__id">ID {{ displayId }}</p>
      </div>
    </div>

    <!-- ② 余额卡（进明细 / 进充值） -->
    <div class="h5-card bc">
      <div class="bc__l">
        <span class="bc__k">余额</span>
        <span class="bc__v">{{ balance === null ? (balanceErr || '查询中…') : `¥${fmtMoney(balance)}` }}</span>
      </div>
      <div class="bc__ops">
        <button class="bc__b" type="button" @click="router.push({ name: 'recharge' })">充值</button>
        <button class="h5-btn bc__go" type="button" @click="router.push({ name: 'wallet' })">余额明细</button>
      </div>
    </div>

    <!-- ③ 服务入口（发丝线行，不用宫格大色块） -->
    <div class="h5-sec"><span class="h5-sec__t">我的服务</span></div>
    <div class="h5-card h5-card--flush">
      <button class="row" type="button" @click="router.push({ name: 'orders' })">
        <span class="row__ic" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <rect x="5" y="3" width="14" height="18" rx="2" /><path d="M9 8h6M9 12h6M9 16h4" stroke-linecap="round" />
          </svg>
        </span>
        <span class="row__t">我的订单</span>
        <span class="row__arw" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="m9 5 7 7-7 7" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </span>
      </button>

      <button class="row" type="button" @click="router.push({ name: 'announcements' })">
        <span class="row__ic" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M4 9v6h3l5 4V5L7 9H4Z" /><path d="M17 9a4 4 0 0 1 0 6" stroke-linecap="round" />
          </svg>
        </span>
        <span class="row__t">公告</span>
        <span class="row__arw" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="m9 5 7 7-7 7" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </span>
      </button>

      <button class="row" type="button" @click="toggleAbout">
        <span class="row__ic" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <circle cx="12" cy="12" r="9" /><path d="M12 8h.01M11 12h1v4h1" stroke-linecap="round" />
          </svg>
        </span>
        <span class="row__t">关于我们</span>
        <span class="row__arw" aria-hidden="true">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="m9 5 7 7-7 7" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </span>
      </button>
    </div>

    <!-- 关于我们（接口有文案就展示；没有就只给应用名 + 版本，不编造） -->
    <div v-if="showAbout" class="h5-card ab">
      <p class="ab__t">祁连山电竞</p>
      <p v-if="aboutText" class="ab__x">{{ aboutText }}</p>
      <p class="ab__v">网页版（H5）v{{ APP_VERSION }}</p>
    </div>

    <!-- ④ 退出登录 -->
    <div class="lo">
      <button class="h5-btn h5-btn--ghost" type="button" @click="logout">退出登录</button>
    </div>
  </div>
</template>

<style scoped>
/* ---------- 资料卡 ---------- */
.pf { display: flex; align-items: center; gap: var(--s3); }
.pf__av {
  width: 56px; height: 56px; flex: 0 0 auto;
  border-radius: var(--r-pill);
  background: var(--pri-soft);
  color: var(--pri);
  display: grid; place-items: center;
  overflow: hidden;
}
.pf__img { width: 100%; height: 100%; object-fit: cover; }
.pf__m { flex: 1 1 auto; min-width: 0; }
.pf__top { display: flex; align-items: center; gap: var(--s2); }
.pf__n {
  margin: 0; font-size: var(--f2); font-weight: 800; color: var(--g1);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.pf__lv {
  flex: 0 0 auto;
  height: 20px; padding: 0 var(--s2);
  display: inline-grid; place-items: center;
  border-radius: var(--r-sm);
  background: var(--gold-soft);
  border: 1px solid var(--gold);
  color: var(--gold);
  font-size: var(--f6); font-weight: 700;
}
.pf__id { margin: var(--s1) 0 0; font-size: var(--f5); color: var(--g3); }

/* ---------- 余额卡 ---------- */
.bc { display: flex; align-items: center; gap: var(--s3); flex-wrap: wrap; }
.bc__l { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--s1); }
.bc__k { font-size: var(--f5); color: var(--g3); }
.bc__v { font-size: var(--f1); font-weight: 800; color: var(--g1); font-variant-numeric: tabular-nums; }
.bc__ops { flex: 0 0 auto; display: flex; align-items: center; gap: var(--s2); }
.bc__b {
  height: var(--h-btn-sm); padding: 0 var(--s3);
  background: var(--card); border: 1px solid var(--pri); border-radius: var(--r-ctrl);
  color: var(--pri); font-size: var(--f5); font-weight: 700; cursor: pointer;
}
.bc__go { width: auto; height: var(--h-btn-sm); padding: 0 var(--s3); font-size: var(--f5); }

/* ---------- 服务入口行 ---------- */
.row {
  width: 100%;
  display: flex; align-items: center; gap: var(--s3);
  min-height: var(--h-row);
  padding: var(--s3) var(--card-pad-x);
  background: var(--card);
  border: 0; border-bottom: 1px solid var(--g5);
  cursor: pointer; text-align: left;
}
.row:last-child { border-bottom: 0; }
.row__ic { flex: 0 0 auto; display: grid; place-items: center; color: var(--g2); }
.row__t { flex: 1 1 auto; min-width: 0; font-size: var(--f4); font-weight: 600; color: var(--g1); }
.row__arw { flex: 0 0 auto; color: var(--g3); display: grid; place-items: center; }

/* ---------- 关于我们 ---------- */
.ab__t { margin: 0 0 var(--s2); font-size: var(--f3); font-weight: 700; color: var(--g1); }
.ab__x { margin: 0 0 var(--s2); font-size: var(--f4); color: var(--g2); line-height: 1.6; white-space: pre-wrap; }
.ab__v { margin: 0; font-size: var(--f5); color: var(--g3); }

/* ---------- 退出登录 ---------- */
.lo { margin: var(--s6) var(--page-x) var(--s4); }
</style>
