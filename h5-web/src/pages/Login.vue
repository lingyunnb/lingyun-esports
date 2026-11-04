<script setup lang="ts">
/**
 * 登录（网页版 H5）
 * ============================================================================
 * 硬约束逐条落地：
 * - **白底为主**：整页白底，唯一的大色块是 40×40 墨蓝字标块（金属锚色，仅极小面积）与主按钮；
 *   不做深色/蓝色整屏色块、不做渐变。
 * - **颜色全走 token**（`var(--brand-ink)` / `var(--pri)` / `var(--g1..g6)`），本文件零硬编码色值。
 * - **间距只用 4dp 网格**：4 / 8 / 12 / 16 / 20 / 24 / 32 / 48 / 64。
 *
 * 行为：
 * - 成功后按 `?redirect=` 回原页（路由守卫 `router/index.ts` 会带上 `to.fullPath`；没带就回 `home`）；
 * - 失败**直接显示服务端中文 `message`**（`ApiError.message`），**绝不自己编错误文案**；
 * - 显示 `?reason=`（被顶号时 `main.ts` 的 401 回调传「登录已失效，请重新登录」）。
 *
 * 注册 / 找回：H5 首期只做**提示**（后端接口存在但不在本期范围）——
 * `POST /auth/register`、`POST /auth/email/code`、`POST /auth/password/reset` 均可直接调用，
 * 真要接入按 App 的 `login_page.dart` / `forgot_password_page.dart` 两步式流程搬即可。
 */
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { ApiError } from '@/api';
import { useAuthStore } from '@/stores/auth';

const route = useRoute();
const router = useRouter();
const auth = useAuthStore();

const username = ref('');
const password = ref('');

/** 服务端中文失败原因（**原样展示，前端不加工**） */
const errMsg = ref('');
const loading = ref(false);
/** 被顶号/过期时守卫传的说明（`?reason=`）—— 只在没有具体失败原因时显示 */
const reason = computed(() => String(route.query.reason ?? ''));

const canSubmit = computed(() => username.value.trim().length > 0 && password.value.length > 0);

async function onSubmit() {
  if (loading.value || !canSubmit.value) return;
  loading.value = true;
  errMsg.value = '';
  try {
    await auth.login(username.value.trim(), password.value);
    // 守卫带来的来路优先；没有就回首页（`replace`：登录页不该留在历史里，返回键不该回到它）
    const redirect = String(route.query.redirect ?? '');
    await router.replace(redirect || { name: 'home' });
  } catch (e) {
    errMsg.value = e instanceof ApiError ? e.message : '登录失败，请稍后重试';
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div class="login h5-page h5-page--nobar">
    <!-- 品牌区：40×40 墨蓝字标块（唯一的小面积品牌锚） -->
    <div class="login__brand">
      <div class="login__mark" aria-hidden="true">祁</div>
      <h1 class="login__name">祁连山电竞</h1>
      <p class="login__sub">专业陪玩 · 平台直营 · 先服务后结算</p>
    </div>

    <form class="login__form" @submit.prevent="onSubmit">
      <!-- 失败原因：服务端原文（被顶号/密码错/封禁，都是后端给的中文） -->
      <div v-if="errMsg" class="login__note login__note--bad" role="alert">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <span>{{ errMsg }}</span>
      </div>
      <!-- 被顶号说明：没有更具体的失败原因时才显示 -->
      <div v-else-if="reason" class="login__note login__note--info">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <circle cx="12" cy="12" r="9" /><path d="M12 8h.01M11 12h1v4h1" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <span>{{ reason }}</span>
      </div>

      <div class="login__fields">
        <label class="login__field">
          <span class="login__label">账号</span>
          <input
            v-model="username"
            class="login__input"
            type="text"
            name="username"
            autocomplete="username"
            placeholder="登录名 / 展示 ID"
            maxlength="32"
            @input="errMsg = ''"
          />
        </label>
        <label class="login__field">
          <span class="login__label">密码</span>
          <input
            v-model="password"
            class="login__input"
            type="password"
            name="password"
            autocomplete="current-password"
            placeholder="请输入密码"
            maxlength="64"
            @input="errMsg = ''"
          />
        </label>
      </div>

      <button class="h5-btn login__submit" type="submit" :disabled="loading || !canSubmit">
        {{ loading ? '登录中…' : '登录' }}
      </button>

      <p class="login__tip">注册、找回密码请到「祁连山电竞」App · 我的 → 账号安全</p>
    </form>
  </div>
</template>

<style scoped>
.login {
  background: var(--card);
  padding: var(--s12) var(--s6) var(--s6);
}

/* ---------- 品牌区 ---------- */
.login__brand {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--s2);
  margin-bottom: var(--s8);
}
.login__mark {
  width: 40px;
  height: 40px;
  border-radius: var(--r-ctrl);
  background: var(--brand-ink);
  color: var(--card);
  display: grid;
  place-items: center;
  font-size: var(--f2);
  font-weight: 800;
  line-height: 1;
}
.login__name {
  margin: var(--s2) 0 0;
  font-size: var(--f1);
  font-weight: 800;
  letter-spacing: 1px;
  color: var(--g1);
}
.login__sub {
  margin: 0;
  font-size: var(--f5);
  color: var(--g3);
}

/* ---------- 表单 ---------- */
.login__form {
  display: flex;
  flex-direction: column;
  gap: var(--s4);
}

.login__note {
  display: flex;
  align-items: flex-start;
  gap: var(--s2);
  padding: var(--s3);
  border-radius: var(--r-sm);
  border: 1px solid transparent;
  font-size: var(--f4);
  line-height: 1.5;
}
.login__note--bad {
  background: var(--danger-soft);
  border-color: var(--danger);
  color: var(--danger);
}
.login__note--info {
  background: var(--pri-soft);
  border-color: var(--g4);
  color: var(--g2);
}
.login__note svg { flex: 0 0 auto; margin-top: var(--s1); }

.login__fields {
  display: flex;
  flex-direction: column;
  gap: var(--s3);
}
.login__field {
  display: flex;
  align-items: center;
  gap: var(--s3);
  height: var(--h-btn);
  padding: 0 var(--s3);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
}
.login__field:focus-within { border-color: var(--pri); }
.login__label {
  flex: 0 0 auto;
  width: 32px;
  font-size: var(--f4);
  color: var(--g2);
}
.login__input {
  flex: 1 1 auto;
  min-width: 0;
  height: 100%;
  border: 0;
  padding: 0;
  background: none;
  outline: none;
  font-size: var(--f3);
  color: var(--g1);
}
.login__input::placeholder { color: var(--g3); }

.login__submit { margin-top: var(--s1); }

.login__tip {
  margin: 0;
  text-align: center;
  font-size: var(--f6);
  color: var(--g3);
}
</style>
