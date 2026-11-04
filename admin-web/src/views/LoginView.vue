<script setup lang="ts">
/**
 * 登录页（2026-10-11 浅色为默认档改版；**登录流程一行未改**）
 * ============================================================================
 * 仍是现有 `POST /api/v1/auth/login`（`role=admin`，见 stores/auth.ts）+
 * 单设备顶号提示（`?reason=` 由 router 守卫 / api client 401 跳转带来）。
 *
 * ## 为什么是「居中卡片」而不是左右分栏
 * 负责人明确否掉了参考视频那种「左大图 + 右登录卡」的形态 → 本页做成：
 *   **淡灰蓝底（纯 CSS 极细网格 + 一处品牌色柔光晕）→ 正中一张 400px 白卡**。
 * 背景**没有任何装饰性大插画**，只有 CSS 画的两层效果：
 *   · 极细网格：两条 1px `linear-gradient` 平铺（40px 一格）
 *   · 光晕：一枚 720px 的径向渐变（冰雪蓝 12% → 青 5% → 透明），压在网格之上
 * 品牌素材只用了**我们自己的**雪山标（`components/BrandMark.vue`，复刻自 Flutter core 的
 * `AppMountainMark`）与品牌色条，未使用任何第三方图片/插画。
 *
 * ## 配色（浅色为默认档）
 * 页面底 **#F5F7FB**（与主区同一档冷灰蓝）+ 卡片 **#FFFFFF** + 发丝描边 #E5E9F2。
 * 网格在浅底上要**压得更淡**（用正文色的极低透明度，而不是白 3% —— 白线在浅底上完全看不见）；
 * 光晕同理换成"极淡品牌色晕染"，否则浅底 + 强光晕会糊成一块脏蓝。
 * 卡片文字色**写死浅色档值**（不跟主题变量走）：登录页是门面，永远是白卡深字。
 * 深色档（右上角切换后进来）由 `html[data-theme='dark']` 的两条规则整页翻成近黑版，
 * 骨架（网格 / 光晕 / 白卡）逐字复用，不做第二套 DOM。
 *
 * ## 登录成功之后
 * 不再直接跳工作台，而是带 `?welcome=1` 跳过去 —— 欢迎序列由 `LayoutView` 作为覆盖层播放
 * （覆盖层必须盖住侧栏/顶栏，放在布局外层才盖得全）。令牌与跳转逻辑本身没动。
 */
import { ApiException } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { NButton, NInput, useMessage } from 'naive-ui';
import { ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import BrandMark from '@/components/BrandMark.vue';

const router = useRouter();
const route = useRoute();
const message = useMessage();
const auth = useAuthStore();

const username = ref('');
const password = ref('');
const loading = ref(false);

// 被新设备顶掉/会话失效跳回登录页时展示原因（docs/04 单设备登录）
if (typeof route.query.reason === 'string') {
  void message.warning(route.query.reason);
}

async function handleLogin() {
  if (!username.value.trim() || !password.value) {
    message.warning('请输入账号和密码');
    return;
  }
  loading.value = true;
  try {
    await auth.login(username.value.trim(), password.value);
    // 欢迎序列（负责人 2026-10-11 审批）：每次登录都播，播完由 LayoutView 清掉这个参数
    const target = (route.query.redirect as string) || '/dashboard';
    void router.push({ path: target, query: { welcome: '1' } });
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '登录失败，请稍后重试');
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div class="login-page">
    <!-- 背景两层：极细网格 + 品牌色柔光晕（纯 CSS，无图片） -->
    <div class="bg-grid" aria-hidden="true" />
    <div class="bg-glow" aria-hidden="true" />

    <div class="login-card">
      <!-- 顶部 3px 品牌色条（冰雪蓝 → 青；全页唯一一处渐变，且只有 3px 高） -->
      <span class="card-accent" aria-hidden="true" />

      <header class="card-head">
        <div class="brand-row">
          <BrandMark :size="30" color="#1D5FA8" snow-color="#0E7C7B" />
          <div class="brand-text">
            <h1 class="brand-name">祁连山电竞</h1>
            <p class="brand-sub">管理后台</p>
          </div>
        </div>
      </header>

      <form class="card-form" @submit.prevent="handleLogin">
        <label class="field">
          <span class="field-label">账号</span>
          <n-input
            v-model:value="username"
            size="large"
            placeholder="请输入管理员账号"
            :input-props="{ autocomplete: 'username' }"
          />
        </label>

        <label class="field">
          <span class="field-label">密码</span>
          <n-input
            v-model:value="password"
            size="large"
            type="password"
            show-password-on="click"
            placeholder="请输入密码"
            :input-props="{ autocomplete: 'current-password' }"
            @keyup.enter="handleLogin"
          />
        </label>

        <n-button
          class="submit"
          type="primary"
          size="large"
          block
          attr-type="submit"
          :loading="loading"
          @click="handleLogin"
        >
          登录
        </n-button>
      </form>

      <footer class="card-foot">
        <span class="foot-dot" aria-hidden="true" />
        仅供授权管理员使用 · 登录即视为同意平台管理规范
      </footer>
    </div>
  </div>
</template>

<style scoped>
/*
 * 页面底 = **#F5F7FB**（与主区同一档冷灰蓝）。
 * 深色档（右上角切换后再退出登录）由文件末的 `html[data-theme='dark']` 规则整页翻黑。
 */
.login-page {
  position: relative;
  min-height: 100vh;
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f5f7fb;
  overflow: hidden;
  padding: 40px 20px;
}

/* 极细网格：40px 一格。浅底上用**正文色的 4%**（白线在浅底上等于没画） */
.bg-grid {
  position: absolute;
  inset: 0;
  background-image:
    linear-gradient(to right, rgba(31, 41, 55, 0.045) 1px, transparent 1px),
    linear-gradient(to bottom, rgba(31, 41, 55, 0.045) 1px, transparent 1px);
  background-size: 40px 40px;
  pointer-events: none;
}

/* 品牌色柔光晕：一处、居中偏上，冰雪蓝 → 青 → 透明（不是"光斑群发"） */
.bg-glow {
  position: absolute;
  top: 50%;
  left: 50%;
  width: 720px;
  height: 720px;
  transform: translate(-50%, -58%);
  background: radial-gradient(circle, rgba(37, 99, 235, 0.10) 0%, rgba(6, 182, 212, 0.06) 42%, transparent 68%);
  pointer-events: none;
}

/* 居中白卡：400px、圆角 14、白底、1px 发丝描边 + 一层极轻外投影（不铺阴影） */
.login-card {
  position: relative;
  width: 400px;
  max-width: 100%;
  background: #ffffff;
  border: 1px solid #e5e9f2;
  border-radius: 14px;
  padding: 32px 32px 24px;
  box-shadow: 0 12px 32px rgba(15, 23, 42, 0.07);
  overflow: hidden;
}

/* 顶部品牌色条：3px，全页唯一渐变（冰雪蓝 → 青） */
.card-accent {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 3px;
  background: #1d5fa8;
}

.card-head {
  margin-bottom: 26px;
}
.brand-row {
  display: flex;
  align-items: center;
  gap: 12px;
}
.brand-text {
  min-width: 0;
}
.brand-name {
  margin: 0;
  font-size: 17px;
  font-weight: 650;
  letter-spacing: 0.01em;
  /* 正文色 #1F2937 压白卡 = 14.0:1 */
  color: #1f2937;
}
.brand-sub {
  margin: 2px 0 0;
  font-size: 12px;
  /* 次级色 #5B6B82 = 5.3:1 */
  color: #5b6b82;
}

.card-form {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.field-label {
  font-size: 13px;
  font-weight: 500;
  color: #1f2937;
}
.submit {
  margin-top: 4px;
  font-weight: 600;
  letter-spacing: 0.04em;
}

.card-foot {
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid #e5e9f2;
  font-size: 12px;
  /* 三级色 #667792 压白卡 = 4.9:1（原 #94A3B8 只有 2.6:1，本次随浅色档一起修） */
  color: #667792;
  display: flex;
  align-items: center;
  gap: 6px;
}
.foot-dot {
  width: 5px;
  height: 5px;
  border-radius: 999px;
  background: #0e7c7b;
  flex: none;
}

@media (max-width: 480px) {
  .login-card {
    padding: 24px 20px 18px;
  }
}

/*
 * 深色档（顶栏切到深色后再退出登录，或深色偏好下首次打开）：
 * 与浅色档**同一套 DOM / 同一个骨架**，只翻四组颜色（页底 / 网格 / 光晕 / 白卡）。
 * 深色值取自 tokens.css 的深色档（#0B1220 / #111C2E），对比度沿用第一轮实测结论：
 * 品牌名 #EEF4FF on #111C2E = 14.6:1；副标 #8CA3BE = 5.3:1；说明 #8CA3BE = 5.3:1。
 */
html[data-theme='dark'] .login-page {
  background: #0b1220;
}
html[data-theme='dark'] .bg-grid {
  background-image:
    linear-gradient(to right, rgba(255, 255, 255, 0.03) 1px, transparent 1px),
    linear-gradient(to bottom, rgba(255, 255, 255, 0.03) 1px, transparent 1px);
}
html[data-theme='dark'] .bg-glow {
  background: radial-gradient(circle, rgba(37, 99, 235, 0.16) 0%, rgba(6, 182, 212, 0.07) 42%, transparent 68%);
}
html[data-theme='dark'] .login-card {
  background: #111c2e;
  border-color: #22304a;
  box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
}
html[data-theme='dark'] .brand-name {
  color: #eef4ff;
}
html[data-theme='dark'] .brand-sub,
html[data-theme='dark'] .field-label,
html[data-theme='dark'] .card-foot {
  color: #8ca3be;
}
html[data-theme='dark'] .field-label {
  color: #e8eef7;
}
html[data-theme='dark'] .card-foot {
  border-top-color: #1e2c42;
}
</style>
