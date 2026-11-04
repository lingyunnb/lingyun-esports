/** 权限点全量清单（docs/04 权威定义，种子数据） */
export interface PermissionDef {
  code: string;
  name: string;
  group: string;
}

export const PERMISSIONS: PermissionDef[] = [
  { code: 'admin:user:read', name: '用户查看', group: '用户' },
  { code: 'admin:user:write', name: '用户管理', group: '用户' },
  { code: 'admin:user:level', name: '用户等级调整', group: '用户' },
  { code: 'admin:user:ban', name: '用户封禁/解封', group: '用户' },
  { code: 'admin:user:delete', name: '用户删除', group: '用户' },
  { code: 'admin:worker:read', name: '工作端查看', group: '工作端' },
  { code: 'admin:worker:write', name: '工作端管理', group: '工作端' },
  { code: 'admin:worker:permission', name: '接单/客服权限授予', group: '工作端' },
  { code: 'admin:admin:read', name: '管理员查看', group: '管理员' },
  { code: 'admin:admin:write', name: '管理员管理', group: '管理员' },
  { code: 'admin:role:write', name: '角色与权限配置', group: '管理员' },
  { code: 'admin:game:write', name: '游戏管理', group: '游戏' },
  { code: 'admin:category:write', name: '分类管理', group: '游戏' },
  { code: 'admin:product:write', name: '商品管理', group: '商品' },
  { code: 'admin:order:read', name: '订单查看', group: '订单' },
  { code: 'admin:order:write', name: '订单处理', group: '订单' },
  { code: 'admin:order:dispatch', name: '订单派单', group: '订单' },
  { code: 'admin:order:cancel', name: '订单取消', group: '订单' },
  { code: 'admin:appeal:handle', name: '售后申诉处理', group: '订单' },
  { code: 'admin:wallet:read', name: '余额查看', group: '余额' },
  { code: 'admin:wallet:grant', name: '余额发放与回收', group: '余额' },
  // 负责人 2026-10-04：顶部导航「打赏 / 退款 / 投诉」三入口的管理端权限点
  { code: 'admin:tip:read', name: '打赏记录查看', group: '打赏' },
  { code: 'admin:tip:config', name: '打赏金额配置', group: '打赏' },
  { code: 'admin:refund:read', name: '退款申请查看', group: '退款' },
  { code: 'admin:refund:handle', name: '退款申请审批', group: '退款' },
  { code: 'admin:complaint:read', name: '投诉工单查看', group: '投诉' },
  { code: 'admin:complaint:handle', name: '投诉工单处理', group: '投诉' },
  { code: 'admin:chat:read', name: '聊天记录查看', group: '客服' },
  { code: 'admin:chat:assign', name: '客服会话指派', group: '客服' },
  { code: 'admin:leaderboard:read', name: '排行榜查看', group: '排行榜' },
  { code: 'admin:leaderboard:adjust', name: '排行榜调整', group: '排行榜' },
  { code: 'admin:stat:read', name: '数据统计', group: '统计' },
  { code: 'admin:home:write', name: '首页内容管理', group: '系统' },
  { code: 'admin:app:write', name: '版本更新管理', group: '系统' },
  { code: 'admin:setting:read', name: '系统设置查看', group: '系统' },
  { code: 'admin:setting:write', name: '系统设置修改', group: '系统' },
  { code: 'admin:log:read', name: '操作/登录日志', group: '系统' },
  { code: 'admin:audit:read', name: '安全审计', group: '系统' },
  { code: 'admin:media:write', name: '媒体管理', group: '系统' },
  { code: 'admin:feedback:read', name: '意见反馈查看处理', group: '用户' },
  { code: 'admin:site:edit', name: '官网内容编辑', group: '系统' },
  /**
   * 充值（线下收款 + 人工审核）—— 负责人 2026-10-06：**专用窄权限点，只加这两个**。
   *
   * 刻意**不复用** `admin:wallet:grant` 之类的大权限：那会连带给出余额页/用户页/订单页一族能力，
   * 而"充值审核员"只需要看申请 + 发放/驳回。这两个点让该职责**可被独立授予、独立收回**
   * （迁移 1805000000000 只把它们授予 super_admin，其它既有角色一个都不给）。
   *
   * 受限会话（`auth_token.kind='recharge'`）走的就是这两点：`GET /recharge/requests` 要 `recharge:review`，
   * `grant` / `reject` 要 `recharge:grant`。见 CLAUDE.md 结构规则 12 与 docs/04。
   */
  { code: 'recharge:review', name: '充值申请查看', group: '充值' },
  { code: 'recharge:grant', name: '充值申请发放/驳回', group: '充值' },
  /**
   * 提现（人工打款）—— 负责人 2026-10-11：**与充值完全同口径的两个窄权限点**。
   *
   * `withdraw:review`（看列表/详情/收款码/打款凭证）与 `withdraw:pay`（打款/驳回）
   * 刻意拆开：前者只读（含姓名/电话/微信号等敏感个人信息），后者是**不可逆的资金动作**
   * （打款 = 平台真的把钱转出去了；驳回 = 退回余额）。于是"能看不能打"是一个
   * 可独立授予的形态（例如财务核对信息、另一人执行打款）。
   *
   * 迁移 1810000000000 只把它们授予 super_admin，其余既有角色一个都不给。
   * PC 管理端（`/admin/withdraw/*`，primary 会话）与 App 内「管理员身份」
   * （`/withdraw/*`，受限会话 `kind='recharge'`）**共用这两个点、共用同一服务层**。
   */
  { code: 'withdraw:review', name: '提现申请查看', group: '提现' },
  { code: 'withdraw:pay', name: '提现打款/驳回', group: '提现' },
  /**
   * 评价治理 —— 负责人 2026-10-15：**一个窄权限点，只授予 super_admin**。
   *
   * 与 `recharge:*` / `withdraw:*` 完全同口径：**不复用任何 `admin:*` 大权限**
   * （`admin:order:read` 之类会连带给出订单页/用户页一族能力），
   * 需要时由超管在「角色权限」页显式勾选。
   *
   * 这一个点同时覆盖**读与写**：`GET /admin/reviews`（列表）与
   * `POST /admin/reviews/:id/hide|show`（隐藏/恢复）。理由：评价原文是用户生成内容，
   * "看列表"与"改可见性"是同一个人在同一张列表上的连贯动作；再拆一个只读点，
   * 只会产出"能看到评价但点不动隐藏"的空壳授权形态。
   */
  { code: 'review:moderate', name: '评价治理（查看/隐藏/恢复）', group: '评价' },
  /**
   * 展示值调整 —— 负责人 2026-10-16：**一个窄权限点，只授予 super_admin**。
   *
   * 覆盖 `PUT /admin/workers/:id/display-stats`（设置接单次数 / 好评率的**展示值**）
   * 与 `GET /admin/workers/:id/stats`（真实值 / 展示值 / 生效值三联），读写共用一点，
   * 与 `review:moderate` 同口径（同一张卡片上的"看"与"改"是同一个人完成的连贯动作）。
   *
   * 刻意**不复用** `admin:worker:write` —— 那会连带给出"建号 / 改真实姓名电话 / 改陪玩资料"一族能力，
   * 而负责人给的口径是「数字可调，评价必须真实」：本点**只能改对外展示的两个数字**，
   * 真实战绩（`worker_stats.completed_orders`）与评价数据（`order_review`）一行都改不动
   * （评价可见性治理仍只走 `review:moderate`）。
   *
   * 迁移 1815001000000 只把它授予 super_admin，其余既有角色一个都不给。
   */
  { code: 'worker:adjust', name: '展示值调整（接单次数/好评率）', group: '工作端' },
];

/**
 * 「仅超管 + 所有者」独占的权限点（负责人 2026-10-04 权限收口）
 *
 * 这两点由 migration 1789990000000 从全部非 super_admin 角色收回；
 * 守卫对 `admin.is_owner = 1` 的账号额外放行（所有者与超管同权）。
 * 注意：只收写操作；`admin:refund:read` / `admin:tip:read` 普通运营保留（能看不能批）。
 */
export const SUPER_ONLY_PERMISSIONS: string[] = ['admin:refund:handle', 'admin:tip:config'];
