import { createPinia } from 'pinia';
import { createApp } from 'vue';
import App from './App.vue';
import router, { prefetchAllRoutes } from './router';
import { applyThemeAttr, resolveThemeMode } from './stores/theme';
import './styles/tokens.css';

/**
 * 首屏先定主题（在任何组件挂载之前）：
 * 只读 localStorage + matchMedia，不同步网络 → 不会拖慢首屏；
 * 好处是登录页/外壳第一帧就是正确配色，不会"白底闪一下再变黑"。
 * 判定只有一份（`resolveThemeMode`），store 与本文件共用，禁止在这里复制第二份条件。
 */
applyThemeAttr(resolveThemeMode());

const app = createApp(App);
app.use(createPinia());
app.use(router);
app.mount('#app');

// 首屏渲染完成后空闲预取所有页面 chunk（菜单切换零等待，外网访问体验关键）
router.isReady().then(() => prefetchAllRoutes());
