import { createApp } from 'vue';
import { createPinia } from 'pinia';
import Vant from 'vant';
import 'vant/lib/index.css';

import App from './App.vue';
import router from './router';
import { setUnauthorizedHandler } from './api/client';
import { useAuthStore } from './stores/auth';
import './styles/tokens.css';

const app = createApp(App);
const pinia = createPinia();

app.use(pinia);
app.use(router);
app.use(Vant);

/**
 * 401 统一处理：清登录态 → 带 reason 回登录页。
 * 用 `router.replace`（不是 push）：被顶掉后用户按返回不应回到那个已经没权限的页面。
 */
setUnauthorizedHandler(() => {
  try {
    useAuthStore().forceLogout();
  } catch {
    /* pinia 尚未就绪时忽略 */
  }
  if (router.currentRoute.value.name !== 'login') {
    router.replace({ name: 'login', query: { reason: '登录已失效，请重新登录' } });
  }
});

/** 启动时若已有令牌，静默拉一次"我是谁"（失败不影响首屏） */
useAuthStore()
  .fetchMe()
  .catch(() => {});

app.mount('#app');
document.getElementById('app-boot')?.remove();
