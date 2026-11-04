import { createRouter, createWebHistory } from 'vue-router';
import { getToken } from '@/api/client';

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/dashboard' },
    { path: '/login', name: 'login', component: () => import('../views/LoginView.vue') },
    {
      path: '/',
      component: () => import('../views/LayoutView.vue'),
      children: [
        { path: '/dashboard', name: 'dashboard', component: () => import('../views/DashboardView.vue') },
        // 阶段 9：工作端管理；阶段 10：余额管理；阶段 11/12：游戏与商品；阶段 14-16：订单与抽成
        { path: '/workers', name: 'workers', component: () => import('../views/WorkersView.vue') },
        { path: '/users', name: 'users', component: () => import('../views/UsersView.vue') },
        // 身份绑定（负责人 2026-10-06 身份合并方案甲）：老板 ↔ 打手 绑定关系的全局检索（只读）
        // 权限沿用 admin:user:read —— 与「用户管理」同一把钥匙（绑定就是账号之间的关系）
        { path: '/identity-bindings', name: 'identity-bindings', component: () => import('../views/IdentityBindingsView.vue') },
        { path: '/wallets', name: 'wallets', component: () => import('../views/WalletsView.vue') },
        // 充值管理（负责人定案：老板端线下扫码 + 截图申请 + 管理员手工发放余额）
        // 放在「余额管理」之后：发放这个动作的产出就是一条余额流水，两页是同一业务动作的上下游。
        // 合规口径：不接任何支付通道 —— 收款码只是图片，全站只有「已发放」，没有「支付成功」。
        { path: '/recharge', name: 'recharge', component: () => import('../views/RechargeView.vue') },
        // 提现审核（打手发起提现 → 管理员核对收款信息 → 线下打款上传凭证 / 驳回退余额）
        // 放在「充值管理」之后：充值入账、提现出账，是「资金与抽成」组里同一条资金链路的两个方向。
        // 权限：列表/详情/收款码 withdraw:review；打款/驳回 withdraw:pay（找不到权限即整项隐藏）。
        { path: '/withdraw', name: 'withdraw', component: () => import('../views/WithdrawView.vue') },
        { path: '/catalog', name: 'catalog', component: () => import('../views/CatalogView.vue') },
        { path: '/divisions', name: 'divisions', component: () => import('../views/DivisionsView.vue') },
          { path: '/clubs', name: 'clubs', component: () => import('../views/ClubsView.vue') },
          { path: '/order-form', name: 'order-form', component: () => import('../views/OrderFormView.vue') },
        // 系统设置（负责人 2026-10-04：抽成比例后台自定义）：需要 admin:setting:read
        { path: '/settings', name: 'settings', component: () => import('../views/SettingsView.vue') },
        { path: '/orders', name: 'orders', component: () => import('../views/OrdersView.vue') },
        { path: '/commission', name: 'commission', component: () => import('../views/CommissionView.vue') },
        { path: '/appeals', name: 'appeals', component: () => import('../views/AppealsView.vue') },
        // 顶部导航三入口（负责人 2026-10-04）：打赏记录 / 退款审批 / 投诉工单
        { path: '/tips', name: 'tips', component: () => import('../views/TipsView.vue') },
        { path: '/refunds', name: 'refunds', component: () => import('../views/RefundsView.vue') },
        { path: '/complaints', name: 'complaints', component: () => import('../views/ComplaintsView.vue') },
        { path: '/chat', name: 'chat', component: () => import('../views/ChatView.vue') },
        { path: '/leaderboard', name: 'leaderboard', component: () => import('../views/LeaderboardView.vue') },
        { path: '/audit', name: 'audit', component: () => import('../views/AuditView.vue') },
        // 「论坛管理」(/forum) 已于 2026-10-05 随玩家圈整体下线删除：页面 + 路由 + 菜单三处一并移除
        { path: '/feedback', name: 'feedback', component: () => import('../views/FeedbackView.vue') },
        { path: '/admins', name: 'admins', component: () => import('../views/AdminsView.vue') },
        { path: '/app-update', name: 'app-update', component: () => import('../views/AppUpdateView.vue') },
        // 公告管理（原「首页管理」拆分：旧首页模块/Banner/优秀打手已无人消费 → 移除；
        // 公告 + 仍被 App 消费的「关于 / 隐私」文案保留在此页）
        { path: '/announcements', name: 'announcements', component: () => import('../views/AnnouncementView.vue') },
        // 宣传图管理（负责人 2026-10-05 任务② 方案 C）：复用 home_banner 表，
        // 首页顶部通栏轮播的数据源（公开侧 GET /public/banners）
        { path: '/banners', name: 'banners', component: () => import('../views/BannersView.vue') },
        { path: '/site-manage', name: 'site-manage', component: () => import('../views/SiteManageView.vue') },
      ],
    },
  ],
});

// 登录守卫：未登录一律回登录页（docs/04：前端隐藏只是体验，权限以服务端为准）
router.beforeEach((to) => {
  if (to.name !== 'login' && !getToken()) {
    return { name: 'login', query: { redirect: to.fullPath } };
  }
  if (to.name === 'login' && getToken()) {
    return { name: 'dashboard' };
  }
  return true;
});

/**
 * 路由 chunk 预取（性能优化）：
 * 登录后空闲时后台预下载所有页面组件 chunk，使菜单切换无需等待网络（尤其外网/隧道访问时）。
 * 失败静默（不影响正常按需加载）。
 */
export function prefetchAllRoutes() {
  const run = () => {
    for (const r of router.getRoutes()) {
      const comp = r.components?.default;
      if (typeof comp === 'function') {
        try {
          void (comp as () => Promise<unknown>)();
        } catch {
          /* 忽略 */
        }
      }
    }
  };
  const ric = (window as unknown as { requestIdleCallback?: (cb: () => void) => void }).requestIdleCallback;
  if (typeof ric === 'function') ric(run);
  else setTimeout(run, 1500);
}

export default router;
