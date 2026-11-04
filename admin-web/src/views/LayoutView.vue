<script setup lang="ts">
/**
 * 后台主布局（2026-10-11 深色科技风外壳 → 2026-10-11 浅色为默认档 + 侧栏分组折叠）
 * ============================================================================
 * 结构照 SoybeanAdmin / zclzone/vue-naive-admin（均 MIT）那一档的做法，**只抄结构不引依赖**：
 *   ① 侧栏（浅色档白底 / 深色档近黑）+ 折叠（宽度 220 ↔ 64）
 *      **菜单从「28 条平铺」改成「8 个顶层项，父项点击展开子项」**（负责人本轮要求）
 *   ② 顶栏：折叠按钮 · 面包屑 · 刷新当前页 · 主题切换 · 账号 · 退出
 *   ③ 标签页（多页签）：点开的页面留在一行里，可单个关闭 / 一键关闭其它；落 localStorage
 *   ④ 内容区：随主题（浅色 #F5F7FB / 深色 #0B1220），保留原有错误边界 + keep-alive
 *
 * ## 业务一行未改（本轮硬约束）
 *   · **路由名 = 菜单 key**：28 条路由、页面组件、接口调用全部原样，跳转仍走 `router.push({ name })`；
 *   · **权限点判断沿用现有逻辑**：每个子项仍带原来的 `perm`，`auth.hasPermission(perm)` 一行没改；
 *     父项**自己不带权限点**，只在其子项"一个都不可见"时整体隐藏（要求 4）；
 *   · 页面缓存 `ALL_PAGES` / 刷新当前页 / 标签页 / 欢迎序列逻辑原样。
 *
 * ## 侧栏交互（本轮新增，逐条对应验收要求）
 *   ① 父项是**真正的 `<button>`**（带右侧 chevron，展开时旋转 90°），`@click` 切换展开/收起；
 *      顶层直接项（工作台 / 排行榜）也是同一形态的按钮，点了直接进页面；
 *   ② **进入页面时自动展开当前路由所在的那一组**（`watch(route.path)` → `expandGroupOf(route.name)`，
 *      `{ immediate: true }` 保证直接访问 /orders 也展开「订单与售后」）。
 *      **不做手风琴**：同时展开多组是允许的（展开态存 sessionStorage，刷新保持）；
 *      初始未手动展开过时，默认前 3 组展开 —— 但只要有当前路由，当前那组一定在里面；
 *   ③ 折叠态（64px 图标条）：父项仍是按钮，**点击 = 展开侧栏 + 展开该组**（"点不到子项"被这条堵死）。
 *      刻意不做浮层弹出菜单：浮层在 `overflow: hidden` 的 sider 里要 teleport、要自己管定位与点击外部
 *      关闭，多出一整套状态；而"点一下先展开侧栏"对管理端（眼睛在鼠标旁边）是一次点击的成本、
 *      零额外状态。**取舍写在`.sider-menu-is-collapsed` 注释里**，不留给后人猜。
 *   ④ 选中态：**浅底 + 主色字**（左侧 3px 主色条两种都给了：条给"当前页所在的分组父项"，
 *      选中子项用浅底 + 主色字 + 更细的 2px 条）—— 见样式块注释里的取值理由。
 *
 * ## 欢迎序列
 * 登录成功会带 `?welcome=1` 过来；本组件作为**布局外层**播放全屏覆盖层
 * （放页面里盖不住侧栏与顶栏），播完 or 跳过后把该参数从地址栏抹掉（避免刷新重播）。
 */
import { useAuthStore } from '@/stores/auth';
import { useThemeStore } from '@/stores/theme';
import PageErrorBoundary from '@/components/PageErrorBoundary.vue';
import BrandMark from '@/components/BrandMark.vue';
import WelcomeSplash from '@/components/WelcomeSplash.vue';
import { NButton, NLayout, NLayoutContent, NLayoutHeader, NLayoutSider, NSpin, NTag, NTooltip, useMessage } from 'naive-ui';
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';

const auth = useAuthStore();
const theme = useThemeStore();
const router = useRouter();
const route = useRoute();
const message = useMessage();
const loading = ref(true);

/** 侧栏折叠（落 localStorage：刷新后保持用户的偏好） */
const collapsed = ref(localStorage.getItem('fish_admin_sider_collapsed') === '1');
watch(collapsed, (v) => localStorage.setItem('fish_admin_sider_collapsed', v ? '1' : '0'));

/**
 * 页面缓存（性能优化）：keep-alive 保留已打开页面组件与数据，切换菜单不再重新下载 chunk / 重发接口。
 * 刷新按钮通过「临时移出缓存 → 恢复」强制重建当前页（保证能拿到最新数据）。
 */
const cachedPages = ref<string[]>([]);
// 路由组件名（SFC 文件名即组件名）列表：出现新页面时在此登记
const ALL_PAGES = [
  'DashboardView', 'WorkersView', 'UsersView', 'IdentityBindingsView', 'WalletsView', 'RechargeView',
  // 提现审核（本轮新增页面）：登记进 keep-alive 列表，「刷新」按钮才重建得到它
  'WithdrawView',
  'CatalogView', 'OrdersView', 'CommissionView',
  'AppealsView', 'ChatView', 'LeaderboardView', 'AuditView', 'FeedbackView',
  'AnnouncementView', 'AdminsView', 'AppUpdateView', 'SettingsView',
  // 本轮**未新增 / 未删改任何页面**。下面 8 个是原先漏登记的（缺了它们 → 这几页点「刷新」只能整页 reload）：
  // 属同一次"只换壳"口径内顺手补齐，不改任何页面逻辑。名字必须与 SFC 文件名（`__name`）逐字一致。
  'DivisionsView', 'ClubsView', 'OrderFormView', 'BannersView', 'SiteManageView',
  'TipsView', 'ComplaintsView', 'RefundsView',
];
function syncCacheList() {
  cachedPages.value = [...ALL_PAGES];
}
const refreshing = ref(false);
async function refreshCurrentPage() {
  const comp = route.matched[route.matched.length - 1]?.components?.default;
  // 通过组件名匹配缓存列表（懒加载组件需 resolve）
  let name = '';
  try {
    const resolved = typeof comp === 'function' ? await (comp as () => Promise<{ default: { __name?: string } }>)() : comp;
    name = (resolved as { default?: { __name?: string } })?.default?.__name ?? '';
  } catch { /* 忽略 */ }
  if (!name) {
    window.location.reload();
    return;
  }
  refreshing.value = true;
  cachedPages.value = cachedPages.value.filter((n) => n !== name);
  await nextTick();
  cachedPages.value = [...cachedPages.value, name];
  refreshing.value = false;
  message.success('已刷新当前页数据');
}
syncCacheList();

/** 欢迎序列（登录成功带 ?welcome=1 时播一次） */
const showWelcome = ref(false);
function finishWelcome() {
  showWelcome.value = false;
  // 把 welcome 参数从地址栏抹掉：刷新/回退不再重播，也不污染标签页记录
  if (route.query.welcome) {
    const q = { ...route.query };
    delete q.welcome;
    void router.replace({ path: route.path, query: q });
  }
}

onMounted(async () => {
  try {
    await auth.fetchMe();
  } catch {
    void router.push({ name: 'login' });
    return;
  } finally {
    loading.value = false;
  }
  if (route.query.welcome === '1') showWelcome.value = true;
});

/* ================================================================== 侧栏菜单 */
/**
 * 分组菜单的**唯一数据源**。
 * ---------------------------------------------------------------------------
 * 为什么把 28 条平铺改成"分组表 + 渲染器"，而不是继续喂 `n-menu` 的 `children`：
 *   本轮要求的交互是「**父项是按钮，点击展开/收起**（而不是 hover 弹层）」。naive 的
 *   `n-menu` 在 `mode=vertical` 下父项是 `n-submenu`（点标题展开）+ `n-menu-item` 混排，
 *   要拿到"点击展开 + chevron 旋转 + 折叠态点击展开侧栏"三件事得穿三套内部类名，
 *   反而比直接渲染一组语义化 `<button>` 更难维护（也更容易在 naive 升版时断）。
 *   所以这里**只换渲染层**：数据（label / key / perm）逐条搬过来，一行权限判定都没改。
 *
 * `icon` 是父项专用（折叠成图标条后必须一眼认出是哪一组）。路径取自 `DashboardView.vue`
 * 的 `ICONS`（同一体系、同一批 d，未新造图形）；**刻意不抽公共模块**：导航宫格与侧栏分组
 * 是两套各 8 个图标的小集合，抽出去会让"改一个图标要动公共文件"的耦合大于收益。
 * 子项不配图标（展开态有中文名，收起态本来就不显示）。
 */
interface NavIcon {
  d: string;
}
interface NavChild {
  label: string;
  key: string;
  /** 权限点；缺省 = 不需要权限（工作台）。判定仍是 `auth.hasPermission(...)` */
  perm?: string;
  /**
   * 「任一把钥匙都能进」的权限点集合（与 `perm` 二选一）。
   * 本轮新增的唯一用处 = 提现审核（`withdraw:review` 看 / `withdraw:pay` 打款驳回）：
   * 要求是"**两个都没有才隐藏**"（只有打款权限的账号也该看到入口），单个 `perm` 字段表达不了"或"。
   * 判定仍是同一句 `auth.hasPermission(...)`，没有第二套权限逻辑。
   */
  anyPerm?: string[];
}
interface NavParent {
  label: string;
  icon: NavIcon;
  children: NavChild[];
}
interface NavDirect {
  label: string;
  icon: NavIcon;
  /** 直接跳转的路由名（= 菜单 key） */
  key: string;
  /** 权限点；缺省 = 人人可见（工作台） */
  perm?: string;
}
type NavEntry = NavParent | NavDirect;
/** 运行时判别：带 children 的是父项，带 key 的是直接项 */
function isDirect(e: NavEntry): e is NavDirect {
  return (e as NavDirect).key !== undefined;
}

const NAV_ICONS: Record<string, NavIcon> = {
  dashboard: { d: 'M4 12.5 12 4.5l8 8M6.5 10.5V20h11v-9.5M10.5 20v-5h3v5' },
  orders: { d: 'M7 3.5h8.5L19 7v13.5H7zM15 3.5V7h3.5M10 11h6M10 14.5h6M10 18h4' },
  users: { d: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM2.5 20a6.5 6.5 0 0 1 13 0M16.5 5.2a3.5 3.5 0 0 1 0 6.6M18 20a6.6 6.6 0 0 0-1.2-3.8' },
  wallets: { d: 'M3 8.5A2.5 2.5 0 0 1 5.5 6H18a2 2 0 0 1 2 2v1M3 8.5V17a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-2M3 8.5h14M21 12h-3.5a2 2 0 0 0 0 4H21z' },
  catalog: { d: 'M4 8.5 12 4l8 4.5v7L12 20l-8-4.5zM4 8.5 12 13l8-4.5M12 13v7' },
  chat: { d: 'M20 13.5A3.5 3.5 0 0 1 16.5 17H11l-4.5 3.5V17H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h10.5A3.5 3.5 0 0 1 20 8.5z' },
  leaderboard: { d: 'M4 20V11M12 20V5M20 20v-6M3 20h18' },
  settings: { d: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 1.55V21a2 2 0 1 1-4 0v-.07A1.7 1.7 0 0 0 9 19.4a1.7 1.7 0 0 0-1.87.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.55-1H3a2 2 0 1 1 0-4h.07A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.33-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.7 1.7 0 0 0 9 4.6h.08A1.7 1.7 0 0 0 10 3.05V3a2 2 0 1 1 4 0v.07a1.7 1.7 0 0 0 1 1.55 1.7 1.7 0 0 0 1.87-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.7 1.7 0 0 0 19.4 9v.08a1.7 1.7 0 0 0 1.55 1H21a2 2 0 1 1 0 4h-.07a1.7 1.7 0 0 0-1.53 1Z' },
};

/**
 * 8 个顶层项（负责人给定的分组表，逐行对齐）：
 *   **2 个直接项**：工作台 `/dashboard`（无需权限）· 排行榜 `/leaderboard`
 *   **6 个可折叠父项**：订单与售后 · 用户与身份 · 资金与抽成 · 商品与内容 · 客服与消息 · 系统管理
 *   （合计 2 + 6 = **8**；负责人表里"工作台 / 排行榜 / 系统管理…"三行看着像直接项，
 *     实际只有前两行不带子项 —— 验收脚本按 8 个顶层项 + 6 个可折叠父项断。）
 * 权限点与标签**逐条沿用改版前的 `menuOptions`**：一个权限点没换、一个页面没漏
 * （28 条路由里除 `/dashboard` 与 `/login`，其余 26 条都能在下面的 children 里找到）。
 */
const NAV_GROUPS: NavEntry[] = [
  // ① 工作台（无子项，直接进）
  { label: '工作台', icon: NAV_ICONS.dashboard, key: 'dashboard' },
  // ② 订单与售后
  {
    label: '订单与售后',
    icon: NAV_ICONS.orders,
    children: [
      { label: '订单管理', key: 'orders', perm: 'admin:order:read' },
      { label: '售后管理', key: 'appeals', perm: 'admin:appeal:handle' },
      { label: '退款审批', key: 'refunds', perm: 'admin:refund:read' },
      { label: '投诉工单', key: 'complaints', perm: 'admin:complaint:read' },
      { label: '打赏管理', key: 'tips', perm: 'admin:tip:read' },
    ],
  },
  // ③ 用户与身份
  {
    label: '用户与身份',
    icon: NAV_ICONS.users,
    children: [
      { label: '用户管理', key: 'users', perm: 'admin:user:read' },
      // 身份绑定（负责人 2026-10-06 身份合并方案甲）：老板 ↔ 打手 绑定关系（含已解绑历史行、
      // 上限占用）的全局检索。与「用户管理」同一权限点（绑定就是账号之间的关系），
      // 刻意紧挨用户管理排列 —— 运营排查账号时会顺路看这里。
      { label: '身份绑定', key: 'identity-bindings', perm: 'admin:user:read' },
      { label: '工作端管理', key: 'workers', perm: 'admin:worker:read' },
    ],
  },
  // ④ 资金与抽成
  {
    label: '资金与抽成',
    icon: NAV_ICONS.wallets,
    children: [
      // 口径（2026-10-09）：计价单位从「积分」改为「余额」（1 元 = 1 元，¥ 两位小数）
      { label: '余额管理', key: 'wallets', perm: 'admin:wallet:read' },
      // 充值管理（负责人定案）：老板端线下扫码付款 + 上传截图 → 管理员核对后**手工发放**余额。
      // 位置：紧随「余额管理」（发放的产物就是一条余额流水，两页是一次业务动作的上下游）。
      // 权限（与后端 recharge-admin.controller.ts 的映射逐条对应）：
      //   · 申请列表 `recharge:review` / 发放·驳回 `recharge:grant`（**专用窄权限**，刻意不复用 admin:*）；
      //   · 收款码 `admin:setting:read|write`（不限超管）；充值设置保存与白名单增删另有**仅超管**闸门；
      //   · 白名单查看 `admin:admin:read`。
      // 只要这三族里有一项就给入口（页内再按权限点逐块隐藏）；真正的读写权限由服务端 403 兜底。
      { label: '充值管理', key: 'recharge', perm: 'admin:setting:read' },
      // 提现审核（本轮新增）：打手发起提现 → 管理员核对收款信息（完整姓名/电话/微信只在详情给，
      // 列表一律脱敏）→ 线下打款并上传凭证标记「已打款」，或驳回（**余额退回打手**）。
      // 权限：列表/详情/收款码 `withdraw:review`；打款/驳回 `withdraw:pay`。
      // 要求是"**两个都没有才隐藏**" → 用 anyPerm（任一把钥匙都能进；页内再按权限点逐块隐藏）。
      { label: '提现审核', key: 'withdraw', anyPerm: ['withdraw:review', 'withdraw:pay'] },
      { label: '抽成中心', key: 'commission', perm: 'admin:order:read' },
    ],
  },
  // ⑤ 商品与内容
  {
    label: '商品与内容',
    icon: NAV_ICONS.catalog,
    children: [
      { label: '游戏与商品', key: 'catalog', perm: 'admin:product:write' },
      // 分部（游戏 + 平台；负责人 2026-10-03）：客户端首页/筛选、工作端大厅、榜单分部榜的主维度
      { label: '分部管理', key: 'divisions', perm: 'admin:division:read' },
      // 官方馆（负责人 2026-10-04）：首页「祁连山官方」卡片内容与封面图
      { label: '官方馆管理', key: 'clubs', perm: 'admin:club:read' },
      // 下单页配置（负责人 2026-10-04）：字段标签/必填/开关、区服选项、文案全部可改
      { label: '下单页配置', key: 'order-form', perm: 'admin:setting:read' },
      // 公告 + 仍被 App 消费的「关于 / 隐私」文案（原「首页管理」2026-10-05 拆分：
      // 旧首页模块 / Banner / 优秀打手已无人消费，入口一并移除；权限点沿用 admin:home:write）
      { label: '公告管理', key: 'announcements', perm: 'admin:home:write' },
      // 宣传图管理（负责人 2026-10-05 任务② 方案 C）：首页顶部通栏轮播的数据源。
      // 与公告同一把钥匙（都是「首页内容」配置）；此前标废弃是因为无消费方，
      // 现在 App 首页新增 GET /public/banners 消费 → 入口恢复。
      { label: '宣传图', key: 'banners', perm: 'admin:home:write' },
      { label: '官网内容', key: 'site-manage', perm: 'admin:site:edit' },
    ],
  },
  // ⑥ 客服与消息
  {
    label: '客服与消息',
    icon: NAV_ICONS.chat,
    children: [
      { label: '聊天管理', key: 'chat', perm: 'admin:chat:read' },
      { label: '意见反馈', key: 'feedback', perm: 'admin:feedback:read' },
    ],
  },
  // ⑦ 排行榜（无子项，直接进）
  { label: '排行榜', icon: NAV_ICONS.leaderboard, key: 'leaderboard', perm: 'admin:leaderboard:read' },
  // ⑧ 系统管理
  {
    label: '系统管理',
    icon: NAV_ICONS.settings,
    children: [
      // 系统设置（负责人 2026-10-04）：平台抽成比例可视化编辑（0–50 整数，改后立即对新结算生效）
      { label: '系统设置', key: 'settings', perm: 'admin:setting:read' },
      { label: '管理员与角色', key: 'admins', perm: 'admin:admin:read' },
      { label: '操作日志与审计', key: 'audit', perm: 'admin:audit:read' },
      { label: '应用更新', key: 'app-update', perm: 'admin:app:write' },
    ],
  },
];

/**
 * 顶层项可见性（要求 4：**沿用现有权限点判定，一行不改**）
 *   · 直接项（工作台/排行榜）：`hasPermission(perm)`；没写 perm 的（工作台）恒可见；
 *   · 父项：把自己的子项按同一个 `hasPermission` 过滤，**一个子项都不可见 → 整个父项隐藏**。
 * 返回的仍然是一份完整的 `NavEntry[]`，渲染层不必再判权限。
 */
const visibleGroups = computed<NavEntry[]>(() =>
  NAV_GROUPS.map((g) => {
    if (isDirect(g)) {
      if (g.perm && !auth.hasPermission(g.perm)) return null;
      return g;
    }
    const children = g.children.filter((c) => {
      // 「任一把钥匙」优先（提现审核：review / pay 任一即可见）；再退回单权限点；都不写 = 人人可见
      if (c.anyPerm?.length) return c.anyPerm.some((p) => auth.hasPermission(p));
      if (c.perm) return auth.hasPermission(c.perm);
      return true;
    });
    return children.length ? { ...g, children } : null;
  }).filter((g): g is NavEntry => g !== null),
);

/** 当前页的菜单 key（= 路由名），选中态与面包屑共用 */
const activeKey = computed(() => (route.name as string) ?? 'dashboard');

/**
 * 展开态（key = 分组标签）。
 * 落 **sessionStorage**（不是 localStorage）：它是"这次办事要看哪几组"的过程状态，
 * 而不是长期偏好 —— 新开一个窗口应当回到"默认 + 当前路由所在组"。
 */
const EXPAND_KEY = 'fish_admin_nav_expanded';
const expanded = ref<Set<string>>(readExpanded());

function readExpanded(): Set<string> {
  try {
    const raw = JSON.parse(sessionStorage.getItem(EXPAND_KEY) || '[]') as unknown;
    if (Array.isArray(raw) && raw.every((x) => typeof x === 'string')) return new Set(raw as string[]);
  } catch { /* 解析失败就当没存过 */ }
  /*
   * 没存过 → 默认展开**前 3 个可折叠分组**（订单与售后 / 用户与身份 / 资金与抽成）。
   * 为什么不默认全收起：管理端最高频的就是这三组，全收起会让"每次进后台先点两下"。
   * 当前路由所在那组由下面的 watch 兜底展开 —— **一定在**（要求 ② 的硬保证）。
   */
  return new Set(
    NAV_GROUPS.filter((g): g is NavParent => !isDirect(g)).slice(0, 3).map((g) => g.label),
  );
}
watch(expanded, (v) => {
  try {
    sessionStorage.setItem(EXPAND_KEY, JSON.stringify([...v]));
  } catch { /* 隐私模式下退化为"本次会话有效" */ }
}, { deep: true });

/** 当前路由属于哪个分组（直接项 → null） */
function groupOfRoute(routeName: string): NavParent | null {
  for (const g of NAV_GROUPS) {
    if (!isDirect(g) && g.children.some((c) => c.key === routeName)) return g;
  }
  return null;
}

/** 该分组的子项里是否有当前页（父项高亮用） */
function hasActiveChild(g: NavEntry, key: string): boolean {
  return !isDirect(g) && g.children.some((c) => c.key === key);
}

/**
 * 要求 ②：**进入某个页面时自动展开它所在的那一组**。
 * `immediate: true` 是关键 —— 直接访问 `/orders`（首次加载、没有 sessionStorage）时也要展开，
 * 不能等用户去点。**不关闭其它组**（负责人明确：允许同时展开多组，不做手风琴）。
 */
watch(
  () => route.name,
  (name) => {
    if (typeof name !== 'string') return;
    const g = groupOfRoute(name);
    if (g && !expanded.value.has(g.label)) {
      expanded.value = new Set([...expanded.value, g.label]);
    }
  },
  { immediate: true },
);

const menuScroll = ref<HTMLElement | null>(null);

/**
 * 父项点击（要求 ①③）：
 *   · 直接项（工作台 / 排行榜）→ 直接进页面；
 *   · 折叠态（64px 图标条）→ **先展开侧栏再展开该组**：一次点击就能看到子项，
 *     不存在"点不到的子项"（展开侧栏是这个取舍的代价，理由见文件头 ③）；
 *   · 展开态 → 就地切换展开/收起。
 */
function onParentClick(g: NavEntry) {
  if (isDirect(g)) {
    void router.push({ name: g.key });
    return;
  }
  if (collapsed.value) {
    collapsed.value = false;
    // 侧栏宽度有 200ms 过渡，等它铺开再滚动定位，否则 scrollIntoView 算的是旧宽度
    void nextTick(() => scrollActiveIntoView(240));
    if (!expanded.value.has(g.label)) expanded.value = new Set([...expanded.value, g.label]);
    return;
  }
  if (!expanded.value.has(g.label)) {
    expanded.value = new Set([...expanded.value, g.label]);
  } else {
    const next = new Set(expanded.value);
    next.delete(g.label);
    expanded.value = next;
  }
}

/** 把当前选中项滚进可视区（直接访问深层页面时，展开的分组可能在侧栏可视区之外） */
function scrollActiveIntoView(delay = 0) {
  const run = () => menuScroll.value?.querySelector('.nav-child.is-active')?.scrollIntoView({ block: 'nearest' });
  if (delay) setTimeout(run, delay);
  else void nextTick(run);
}
onMounted(() => scrollActiveIntoView(320));

/*
 * 导航模型 → 面包屑 / 标签页标题的唯一出处（原来是 `menuOptions`，现在是分组表拍平）。
 * 拍平后与旧实现等价：路由名 → 中文标题，页面一个不少。
 */
const titleMap = computed<Record<string, string>>(() => {
  const map: Record<string, string> = {};
  for (const g of NAV_GROUPS) {
    if (isDirect(g)) map[g.key] = g.label;
    else for (const c of g.children) map[c.key] = c.label;
  }
  return map;
});

const crumbs = computed(() => {
  const key = activeKey.value;
  const title = titleMap.value[key];
  return title && key !== 'dashboard' ? ['工作台', title] : ['工作台'];
});

/* ------------------------------------------------------------------ 标签页 */
interface PageTab {
  path: string;
  title: string;
}
const DASHBOARD_TAB: PageTab = { path: '/dashboard', title: '工作台' };
const tabs = ref<PageTab[]>(readTabs());

function readTabs(): PageTab[] {
  try {
    const raw = JSON.parse(localStorage.getItem('fish_admin_tabs') || '[]') as PageTab[];
    const ok = raw.filter((t) => t && typeof t.path === 'string' && typeof t.title === 'string');
    return [DASHBOARD_TAB, ...ok.filter((t) => t.path !== DASHBOARD_TAB.path)];
  } catch {
    return [DASHBOARD_TAB];
  }
}
watch(
  tabs,
  (v) => localStorage.setItem('fish_admin_tabs', JSON.stringify(v.filter((t) => t.path !== DASHBOARD_TAB.path))),
  { deep: true },
);

// 路由变化 → 记录到标签页（标题取菜单中文名；未登记的页面不硬塞，避免出现英文 key）
watch(
  () => route.path,
  (p) => {
    if (route.name === 'login') return;
    const title = titleMap.value[route.name as string];
    if (!title) return;
    if (tabs.value.some((t) => t.path === p)) return;
    tabs.value = [...tabs.value, { path: p, title }];
  },
  { immediate: true },
);

function closeTab(path: string) {
  const idx = tabs.value.findIndex((t) => t.path === path);
  if (idx < 0 || path === DASHBOARD_TAB.path) return;
  tabs.value = tabs.value.filter((t) => t.path !== path);
  // 关掉的正是当前页 → 退到左邻（没有就回工作台）
  if (route.path === path) {
    const next = tabs.value[Math.max(0, idx - 1)] ?? DASHBOARD_TAB;
    void router.push(next.path);
  }
}
function closeOthers() {
  const current = tabs.value.find((t) => t.path === route.path) ?? DASHBOARD_TAB;
  tabs.value = [DASHBOARD_TAB, ...(current.path === DASHBOARD_TAB.path ? [] : [current])];
}

async function logout() {
  await auth.logout();
  message.success('已退出登录');
  void router.push({ name: 'login' });
}
</script>

<template>
  <n-layout has-sider class="layout">
    <!-- ============================================================ 侧栏（浅色档白底 / 深色档近黑） -->
    <n-layout-sider
      class="sider"
      bordered
      collapse-mode="width"
      :width="220"
      :collapsed-width="64"
      :collapsed="collapsed"
      :native-scrollbar="false"
      @update:collapsed="(v: boolean) => (collapsed = v)"
    >
      <div class="sider-brand" :class="{ 'is-collapsed': collapsed }">
        <BrandMark :size="26" color="#1D5FA8" snow-color="#0E7C7B" />
        <div v-if="!collapsed" class="sider-brand-text">
          <span class="sider-brand-name">祁连山电竞</span>
          <span class="sider-brand-sub">管理后台</span>
        </div>
      </div>

      <div ref="menuScroll" class="sider-menu" :class="{ 'is-collapsed': collapsed }">
        <div v-for="g in visibleGroups" :key="g.label" class="nav-group">
          <!--
            父项 / 直接项：**真正的 button**（不是 div 挂点击），带右侧 chevron（展开时旋转 90°）。
            折叠态套一层 n-tooltip（只剩图标，靠 tooltip 补名字）；展开态直接渲染，
            两条分支共用同一个 `nav-parent` 按钮标记（只有 tooltip 包不包的区别）。
          -->
          <n-tooltip v-if="collapsed" trigger="hover" placement="right" :delay="120">
            <template #trigger>
              <button
                class="nav-parent"
                :class="{
                  'is-active': hasActiveChild(g, activeKey),
                  'is-direct': isDirect(g),
                  'is-current': isDirect(g) && g.key === activeKey,
                }"
                type="button"
                :data-nav-group="g.label"
                :data-nav-direct="isDirect(g) ? '1' : '0'"
                :aria-expanded="isDirect(g) ? undefined : expanded.has(g.label)"
                @click="onParentClick(g)"
              >
                <span class="nav-icon" aria-hidden="true">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                    <path :d="g.icon.d" />
                  </svg>
                </span>
                <span class="nav-label">{{ g.label }}</span>
              </button>
            </template>
            {{ g.label }}
          </n-tooltip>

          <button
            v-else
            class="nav-parent"
            :class="{
              'is-active': hasActiveChild(g, activeKey),
              'is-direct': isDirect(g),
              'is-current': isDirect(g) && g.key === activeKey,
            }"
            type="button"
            :data-nav-group="g.label"
            :data-nav-direct="isDirect(g) ? '1' : '0'"
            :aria-expanded="isDirect(g) ? undefined : expanded.has(g.label)"
            @click="onParentClick(g)"
          >
            <span class="nav-icon" aria-hidden="true">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                <path :d="g.icon.d" />
              </svg>
            </span>
            <span class="nav-label">{{ g.label }}</span>
            <svg
              v-if="!isDirect(g)"
              class="nav-chevron"
              :class="{ 'is-open': expanded.has(g.label) }"
              width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            >
              <path d="m9 6 6 6-6 6" />
            </svg>
          </button>

          <!-- 子项：只有展开态渲染（折叠态点击父项会先展开侧栏 + 展开该组） -->
          <div v-if="!collapsed && !isDirect(g) && expanded.has(g.label)" class="nav-children" :data-nav-children="g.label">
            <button
              v-for="c in g.children"
              :key="c.key"
              class="nav-child"
              :class="{ 'is-active': c.key === activeKey }"
              type="button"
              :data-nav-item="c.key"
              @click="router.push({ name: c.key })"
            >
              {{ c.label }}
            </button>
          </div>
        </div>
      </div>
    </n-layout-sider>

    <!-- ============================================================ 主区 -->
    <n-layout class="main">
      <n-layout-header class="header" bordered>
        <n-tooltip trigger="hover" placement="bottom">
          <template #trigger>
            <button class="icon-btn" type="button" @click="collapsed = !collapsed">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
                <rect x="3" y="4" width="18" height="16" rx="2.5" />
                <path d="M9 4v16" />
              </svg>
            </button>
          </template>
          {{ collapsed ? '展开侧栏' : '收起侧栏' }}
        </n-tooltip>

        <nav class="crumbs" aria-label="面包屑">
          <template v-for="(c, i) in crumbs" :key="c">
            <span v-if="i > 0" class="crumb-sep">/</span>
            <span class="crumb" :class="{ 'is-current': i === crumbs.length - 1 }">{{ c }}</span>
          </template>
        </nav>

        <div class="header-spacer" />

        <n-tag v-if="auth.isSuperAdmin" size="small" :bordered="false" class="role-tag">超级管理员</n-tag>
        <span v-if="auth.me" class="who">{{ auth.me.nickname }}（{{ auth.me.username }}）</span>

        <n-tooltip trigger="hover" placement="bottom">
          <template #trigger>
            <button class="icon-btn" type="button" @click="theme.toggle()">
              <svg v-if="theme.isDark" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
                <circle cx="12" cy="12" r="4" />
                <path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19" />
              </svg>
              <svg v-else width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                <path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" />
              </svg>
            </button>
          </template>
          {{ theme.isDark ? '切换到浅色' : '切换到深色' }}
        </n-tooltip>

        <n-button size="small" quaternary :loading="refreshing" @click="refreshCurrentPage">刷新</n-button>
        <n-button size="small" quaternary @click="logout">退出登录</n-button>
      </n-layout-header>

      <!-- 标签页（多页签）：当前页高亮 + 底部品牌色指示条；除工作台外可关闭 -->
      <div class="tabbar">
        <div class="tabbar-scroll">
          <button
            v-for="t in tabs"
            :key="t.path"
            class="tab"
            :class="{ 'is-active': t.path === route.path }"
            type="button"
            @click="router.push(t.path)"
          >
            <span class="tab-title">{{ t.title }}</span>
            <span
              v-if="t.path !== '/dashboard'"
              class="tab-close"
              role="button"
              aria-label="关闭标签"
              @click.stop="closeTab(t.path)"
            >×</span>
          </button>
          <button v-if="tabs.length > 2" class="tab tab-action" type="button" @click="closeOthers">关闭其它</button>
        </div>
      </div>

      <n-layout-content class="content" :class="{ 'is-fullbleed': route.meta.fullbleed === true }">
        <n-spin :show="loading">
          <!-- 页面级错误边界 + keep-alive 缓存（切换秒开，不重复请求；刷新按钮可强制重建） -->
          <page-error-boundary>
            <router-view v-slot="{ Component }">
              <keep-alive :include="cachedPages">
                <component :is="Component" />
              </keep-alive>
            </router-view>
          </page-error-boundary>
        </n-spin>
      </n-layout-content>
    </n-layout>

    <!-- 登录成功欢迎序列（全屏覆盖层；点击/任意键立即跳过） -->
    <welcome-splash v-if="showWelcome" :is-owner="auth.isOwner" @done="finishWelcome" />
  </n-layout>
</template>

<style scoped>
.layout {
  height: 100vh;
}

/* ------------------------------------------------------------------ 侧栏 */
/*
 * 侧栏底色**读 token**（浅色档 #FFFFFF / 深色档 #0B1220）：
 * 上一轮是"恒近黑"写在样式里，本轮浅色为默认档 → 改由 `--sider-bg` 决定，
 * 两档共用一份 DOM 与一份样式，切档只换 `html[data-theme]`。
 */
.sider {
  background: var(--sider-bg);
}
:deep(.n-layout-sider-scroll-container) {
  display: flex;
  flex-direction: column;
}
.sider-brand {
  height: var(--header-height);
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 18px;
  border-bottom: 1px solid var(--sider-divider);
}
.sider-brand.is-collapsed {
  padding: 0;
  justify-content: center;
}
.sider-brand-text {
  display: flex;
  flex-direction: column;
  min-width: 0;
  line-height: 1.25;
}
.sider-brand-name {
  font-size: 14px;
  font-weight: 650;
  color: var(--brand-text);
  letter-spacing: 0.01em;
  white-space: nowrap;
}
.sider-brand-sub {
  font-size: 11px;
  color: var(--sider-text-dim);
  white-space: nowrap;
}

/* 菜单容器：**自带纵向滚动**（分组展开后条目会超过一屏，尤其是 220px 窄侧栏 + 7 个商品子项） */
.sider-menu {
  flex: 1;
  min-height: 0;
  padding: 8px 0 16px;
  overflow-y: auto;
  overflow-x: hidden;
}
.sider-menu::-webkit-scrollbar {
  width: 6px;
}
.sider-menu::-webkit-scrollbar-thumb {
  background: var(--sider-divider);
  border-radius: var(--radius-pill);
}

.nav-group {
  padding: 0 8px;
}

/*
 * 父项 / 直接项按钮
 * ---------------------------------------------------------------------------
 * 高度 34：比子项（30）高一档，形成"组标题—成员"的层级；圆角 8（--radius-control）。
 * 配色三态（浅色档实测对比度写在 tokens.css 末尾的「对比度速查」里）：
 *   · 常态：#1F2937 on #FFFFFF = 14.0:1
 *   · hover：淡蓝底 #F4F7FD，字不变色（hover 不该抢走"当前页"的信息）
 *   · 当前页所在分组：淡蓝底 rgba(37,99,235,.07) + 主色字 #2563EB（5.0:1）+ **左侧 3px 主色条**
 */
.nav-parent {
  position: relative;
  width: 100%;
  height: 34px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 10px;
  border: none;
  border-radius: var(--radius-control);
  background: transparent;
  color: var(--sider-text);
  font-size: 13.5px;
  font-weight: 500;
  text-align: left;
  cursor: pointer;
  transition:
    background var(--dur-fast) var(--ease),
    color var(--dur-fast) var(--ease);
}
.nav-parent:hover {
  background: var(--sider-parent-hover);
}
.nav-parent:focus-visible {
  outline: 2px solid var(--brand-primary);
  outline-offset: -2px;
}
.nav-parent.is-active {
  background: var(--sider-parent-active-bg);
  color: var(--sider-active-text);
  font-weight: 600;
}
/*
 * 直接项（工作台 / 排行榜）的当前态：与分组父项同一套视觉（淡蓝底 + 主色字 + 左侧 3px 主色条），
 * 只是它同时代表"当前页"。`is-active`（分组里有当前页）与 `is-current`（自己就是当前页）
 * 用同一条 `::before` 规则，避免两套色条写法在后续维护里漂移。
 */
.nav-parent.is-active::before,
.nav-parent.is-current::before {
  content: '';
  position: absolute;
  left: -8px;
  top: 6px;
  bottom: 6px;
  width: 3px;
  border-radius: 0 3px 3px 0;
  background: var(--brand-primary);
}
.nav-parent.is-current {
  background: var(--sider-active-bg);
  color: var(--sider-active-text);
  font-weight: 600;
}
.nav-icon {
  width: 18px;
  height: 18px;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--sider-text-muted);
}
.nav-parent.is-active .nav-icon,
.nav-parent.is-current .nav-icon {
  color: var(--sider-active-text);
}
.nav-label {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* chevron：收起时朝右，展开时旋转 90° 朝下（200ms，克制） */
.nav-chevron {
  flex: none;
  color: var(--sider-text-dim);
  transition: transform var(--dur) var(--ease);
}
.nav-chevron.is-open {
  transform: rotate(90deg);
}
/* 当前页所在分组：chevron 同步转成主色（与父项文字/图标同一套"当前"语义） */
.nav-parent.is-active .nav-chevron,
.nav-parent.is-current .nav-chevron {
  color: var(--sider-active-text);
}

/*
 * 子项列表：纯 CSS 展开（不做过渡动画 —— 高度过渡要 JS 量高，收益不抵复杂度）。
 * 左内边距 20 让子项文字**与父项文字左缘不对齐**（父项文字在 38，子项在 28+10=38 减去缩进）：
 * 这里取 28，子项文字落在 38 → 与父项标题**同一条竖线**，缩进靠左侧留白表达。
 */
.nav-children {
  display: flex;
  flex-direction: column;
  gap: 1px;
  padding: 2px 0 6px;
}
.nav-child {
  position: relative;
  height: 30px;
  display: flex;
  align-items: center;
  padding: 0 10px 0 28px;
  border: none;
  border-radius: var(--radius-control);
  background: transparent;
  color: var(--sider-text-muted);
  font-size: 13px;
  text-align: left;
  cursor: pointer;
  transition:
    background var(--dur-fast) var(--ease),
    color var(--dur-fast) var(--ease);
}
.nav-child:hover {
  background: var(--sider-hover);
  color: var(--sider-text);
}
/*
 * 选中子项：**浅底 + 主色字 + 左侧 3px 主色条**（两种方案都用了 ——
 * 条同时出现在"当前页所在分组父项"与"当前子项"上，视觉上是一根连续的层级线；
 * 只给父项加条会让"到底选的哪一项"在长列表里变得含糊）。
 */
.nav-child.is-active {
  background: var(--sider-active-bg);
  color: var(--sider-active-text);
  font-weight: 600;
}
.nav-child.is-active::before {
  content: '';
  position: absolute;
  left: -8px;
  top: 5px;
  bottom: 5px;
  width: 3px;
  border-radius: 0 3px 3px 0;
  background: var(--brand-primary);
}

/*
 * 折叠态（64px 图标条）：只留图标，**文字必须整条移除**。
 * ⚠️ 2026-10-11 实测踩过的坑：只在模板里不渲染 label 是不够的（折叠态走的是 n-tooltip 那条分支，
 * 里面仍然渲染了 `.nav-label`），64px 装不下中文标签时会漏出半个字（截图里是「工.」「订.」）。
 * 正确做法是**在这个状态下把标签和 chevron 一起 display:none**，图标居中；
 * 分组名由 n-tooltip 补（`trigger="hover"`）。
 */
.sider-menu.is-collapsed .nav-group {
  padding: 0 8px;
}
.sider-menu.is-collapsed .nav-parent {
  justify-content: center;
  padding: 0;
  gap: 0;
}
.sider-menu.is-collapsed .nav-label,
.sider-menu.is-collapsed .nav-chevron {
  display: none;
}
/* 折叠态左侧没有 3px 主色条的空间，改成"整块淡蓝底"表达当前项 */
.sider-menu.is-collapsed .nav-parent.is-active::before,
.sider-menu.is-collapsed .nav-parent.is-current::before {
  display: none;
}
.sider-menu.is-collapsed .nav-parent.is-active,
.sider-menu.is-collapsed .nav-parent.is-current {
  background: var(--sider-active-bg);
}

/* ------------------------------------------------------------------ 顶栏 */
.main {
  background: var(--color-bg-page);
}
.header {
  height: var(--header-height);
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 18px;
  background: var(--color-bg-card);
  border-bottom: 1px solid var(--color-divider);
}
.header-spacer {
  flex: 1;
}
.icon-btn {
  width: 30px;
  height: 30px;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: var(--color-text-secondary);
  cursor: pointer;
  transition:
    background var(--dur-fast) var(--ease),
    color var(--dur-fast) var(--ease);
}
.icon-btn:hover {
  background: var(--color-primary-soft);
  /* 图标色 = 主色文字态（深色档自动提亮；纯主色压在深底上只有 3.6:1） */
  color: var(--color-primary-text);
}
.crumbs {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  min-width: 0;
}
.crumb {
  color: var(--color-text-tertiary);
  white-space: nowrap;
}
.crumb.is-current {
  color: var(--color-text-primary);
  font-weight: 600;
}
.crumb-sep {
  color: var(--color-text-tertiary);
  opacity: 0.6;
}
.who {
  color: var(--color-text-secondary);
  font-size: 13px;
  white-space: nowrap;
}
.role-tag {
  font-weight: 500;
}

/* ------------------------------------------------------------------ 标签页 */
.tabbar {
  flex: none;
  height: var(--tabbar-height);
  background: var(--color-bg-card);
  border-bottom: 1px solid var(--color-divider);
  padding: 0 12px;
  display: flex;
  align-items: flex-end;
}
.tabbar-scroll {
  display: flex;
  align-items: flex-end;
  gap: 4px;
  overflow-x: auto;
  scrollbar-width: none;
  height: 100%;
  padding-top: 6px;
}
.tabbar-scroll::-webkit-scrollbar {
  display: none;
}
.tab {
  height: 30px;
  flex: none;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 0 10px;
  border: 1px solid var(--color-divider);
  border-bottom: none;
  border-radius: 8px 8px 0 0;
  background: transparent;
  color: var(--color-text-secondary);
  font-size: 13px;
  cursor: pointer;
  white-space: nowrap;
  position: relative;
  transition:
    background var(--dur-fast) var(--ease),
    color var(--dur-fast) var(--ease);
}
.tab:hover {
  color: var(--color-text-primary);
  background: var(--color-bg-sunken);
}
.tab.is-active {
  background: var(--color-bg-page);
  color: var(--color-text-primary);
  font-weight: 600;
}
/* 选中标签底部 2px 品牌色指示条（装饰色块 → 读恒定值，不被深色档的文字态重映射影响） */
.tab.is-active::after {
  content: '';
  position: absolute;
  left: 8px;
  right: 8px;
  bottom: -1px;
  height: 2px;
  border-radius: 2px 2px 0 0;
  background: var(--brand-primary);
}
.tab-close {
  width: 16px;
  height: 16px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  font-size: 14px;
  line-height: 1;
  color: var(--color-text-tertiary);
}
.tab-close:hover {
  background: var(--color-error);
  color: #fff;
}
.tab-action {
  border-bottom: 1px solid var(--color-divider);
  border-radius: 8px;
  height: 24px;
  margin-bottom: 3px;
  color: var(--color-text-tertiary);
  font-size: 12px;
}

/* ------------------------------------------------------------------ 内容区 */
.content {
  padding: 20px 22px 28px;
  background: var(--color-bg-page);
}
/* 自带整屏背景的页面（登录页等）不套通用内边距 */
.content.is-fullbleed {
  padding: 0;
  background: transparent;
}
.content.is-fullbleed :deep(.n-spin-container),
.content.is-fullbleed :deep(.n-spin-content) {
  min-height: 100%;
}
</style>
