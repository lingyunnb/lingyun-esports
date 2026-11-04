import { createRouter, createWebHistory } from 'vue-router';
import { useAuthStore } from '@/stores/auth';

/**
 * 路由表（**全部页面在此一次性声明**，便于并行开发时各页只管自己的文件）
 * ============================================================================
 * 底部导航五格 = 服务 · 订单 · ＋下单 · 消息 · 我的（结构规则 3）。
 * `meta.tab` 标记该页属于哪一格（用于底栏高亮）；`meta.needLogin` 标记需登录。
 * `meta.headless` = 该页自己画页头（如首页品牌区），不由外壳统一加标题栏。
 */
const router = createRouter({
  history: createWebHistory('/h5/'),
  routes: [
    { path: '/', redirect: '/home' },

    { path: '/login', name: 'login', component: () => import('@/pages/Login.vue'), meta: { headless: true } },

    { path: '/home', name: 'home', component: () => import('@/pages/Home.vue'), meta: { tab: 'home', headless: true } },
    { path: '/players', name: 'players', component: () => import('@/pages/Players.vue'), meta: { headless: true } },
    { path: '/leaderboard', name: 'leaderboard', component: () => import('@/pages/Leaderboard.vue'), meta: { headless: true } },
    { path: '/announcements', name: 'announcements', component: () => import('@/pages/Announcements.vue'), meta: { tab: 'msg', headless: true } },
    { path: '/announcements/:id', name: 'announcement', component: () => import('@/pages/AnnouncementDetail.vue'), meta: { headless: true } },

    { path: '/products', name: 'products', component: () => import('@/pages/ProductList.vue'), meta: { headless: true } },
    { path: '/products/:id', name: 'product', component: () => import('@/pages/ProductDetail.vue'), meta: { headless: true } },

    { path: '/order/new', name: 'orderNew', component: () => import('@/pages/OrderCreate.vue'), meta: { headless: true, needLogin: true } },
    { path: '/orders', name: 'orders', component: () => import('@/pages/Orders.vue'), meta: { tab: 'orders', headless: true, needLogin: true } },
    { path: '/orders/:id', name: 'order', component: () => import('@/pages/OrderDetail.vue'), meta: { headless: true, needLogin: true } },

    /** 护航员信息（公开接口 → 不要求登录）；入口 = 找陪玩列表点头像 */
    { path: '/workers/:id', name: 'worker', component: () => import('@/pages/WorkerProfile.vue'), meta: { headless: true } },

    { path: '/profile', name: 'profile', component: () => import('@/pages/Profile.vue'), meta: { tab: 'mine', headless: true, needLogin: true } },
    { path: '/wallet', name: 'wallet', component: () => import('@/pages/Wallet.vue'), meta: { headless: true, needLogin: true } },
    { path: '/recharge', name: 'recharge', component: () => import('@/pages/Recharge.vue'), meta: { headless: true, needLogin: true } },

    // 兜底
    { path: '/:pathMatch(.*)*', redirect: '/home' },
  ],
  scrollBehavior(to, from, saved) {
    if (saved) return saved;
    return { top: 0 };
  },
});

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (to.meta.needLogin && !auth.isLogin) {
    // 记住来路，登录后原地返回（比"一律回首页"少一次操作）
    return { name: 'login', query: { redirect: to.fullPath } };
  }
  return true;
});

export default router;
