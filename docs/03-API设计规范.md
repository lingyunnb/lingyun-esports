# 03 - API 设计规范

## 基础约定

- 前缀：`/api/v1`；WebSocket：`/ws/chat`（协议见 docs/07）
- Swagger：`/api-docs`（仅非 production 环境开启）
- 数据格式 JSON；时间戳毫秒；时间用 ISO 8601
- 资源命名：REST 复数名词（/orders、/products、/conversations）

## 统一响应结构

```json
{
  "code": 0,
  "message": "ok",
  "data": {},
  "requestId": "uuid",
  "timestamp": 1726800000000
}
```

- `code=0` 成功；非 0 为错误码（HTTP 状态码同步返回对应值）
- 错误时 `data` 为 null；业务错误 message 面向用户可读
- 每个响应带 requestId（x-request-id 头同步返回），日志与排查用

## 错误码

| HTTP | 语义 | 示例 |
|---|---|---|
| 400 | 参数错误/业务规则拒绝 | 非法状态跳转、余额不足、商品下架 |
| 401 | 未认证/Token 无效或过期 | |
| 403 | 已认证但无权限/越权 | user token 调 admin 接口、归属不符 |
| 404 | 资源不存在 | |
| 409 | 冲突（幂等键重复返回已有结果走成功码） | |
| 429 | 触发限流 | |
| 500 | 服务器内部错误（不泄露堆栈） | |

登录失败统一返回"账号或密码错误"，不区分账号不存在/密码错误。

## 分页

请求：`page`（默认 1）、`pageSize`（默认 20，上限 50）。响应 data：

```json
{ "list": [], "total": 0, "page": 1, "pageSize": 20 }
```

## 幂等

- 写操作涉及资金的接口（下单、积分发放等）必须要求幂等键：body 字段 `idempotencyKey`（UUID，客户端生成，重试复用）
- 服务端用唯一约束兜底（order.idempotency_key / wallet_transaction.idempotency_key / idempotency_key 表），冲突时返回首次结果，不重复执行

## 安全铁律（每个接口开发时自检）

1. 主体 id 一律取自 JWT `sub`，**绝不信任请求体/路径参数中的 userId/workerId**
2. 资源查询强制拼接归属条件（WHERE user_id = 当前主体），伪造 id 返回 403/404 不泄露存在性
3. 下单接口只接收 `productId` + `quantity` + `remark` + `idempotencyKey`，价格/余额/用户身份全部服务端查库
4. worker 接单/客服权限每次请求实时查库（不缓存）
5. 所有请求体经 ValidationPipe 白名单校验（whitelist + forbidNonWhitelisted），拒绝未知字段
6. 敏感字段（password_hash、密钥等）永不返回

## Swagger 规范

- 每个 DTO 用 @ApiProperty 标注；写接口标注 @ApiBearerAuth
- 权限要求写在接口描述第一行（如 `权限点：admin:wallet:grant`）
- 公共接口（无需认证）显式标注 `公开`

## 补充（2026-09-21 第二批接口）

- 好友：`GET /user/friends`、`GET /user/friends/search?uid=`（中文/数字/英文 ID）、`GET /user/friends/requests/incoming|outgoing`、`POST /user/friends/requests`、`POST /user/friends/requests/:id/accept|reject`、`DELETE /user/friends/:userId`、`POST /user/friends/:userId/conversation`
- 通知：`GET /user/notifications`（含未读数）、`POST /user/notifications/read`
- 资料：`PUT /user/profile`（昵称/头像/背景，媒体归属+类型校验）、`POST /user/profile/uid`（中文 ID，24h 限 3 次）、`GET /user/profile/:uid`（公开资料页）
- 会话：`GET /user/conversations`、`GET/POST /user/conversations/:id/messages`、`GET /user/conversations/:id/sync`、
  **`POST /user/conversations/:id/read`（一键已读，2026-10-06 缺口 3 新增；200 + `{ok:true,unread:0}`，幂等，
  与 WS `msg:read` 走同一个 `ChatService.markRead`；只认当事方，否则 404/403 中文；companion 由消息族白名单放行）**
- 论坛：`GET /forum/feed`、`POST /forum/posts`（幂等键）、`GET /forum/posts/:id`、`GET /forum/posts/:id/comments`、`POST/DELETE /forum/posts/:id/like`、`POST /forum/posts/:id/comments`、`DELETE /forum/posts/:id`、`DELETE /forum/comments/:id`；管理端 `GET /admin/forum/posts`、`POST /admin/forum/posts/:id/moderate`、`POST /admin/forum/comments/:id/remove`
- 等级：`GET /admin/users/:id`、`POST /admin/users/:id/level`（admin:user:level 默认仅超管，双重审计；**仅限老板端账号**，工作端一律 400）；钱包列表含 level/totalSpent
- 用户管理（2026-09-22）：`GET /admin/users`（老板+工作端列表）、`POST /admin/users/:id/ban`（days 空=永久封禁，否则封禁至 now+days 天）、`POST /admin/users/:id/unban`、`DELETE /admin/users/:id`（删个人数据，保留订单/结算/日志）；被封登录 403 + `errorCode=ACCOUNT_BANNED`
- 工作端：`GET /worker/my-wallet`（余额/累计收入/结算次数）

- 版本更新（2026-09-22；2026-09-23 扩至双端）：`POST /admin/app-versions/upload`（multipart APK + appType=boss|worker，admin:app:write，磁盘落盘+sha256）、`GET /admin/app-versions?appType=`（按端查历史版本）、`POST /admin/app-versions/:id/status`（启用/停用）；公开 `GET /public/app-versions/latest?appType=boss|worker&currentVersionCode=N`（服务端版本比较，返回 hasUpdate/force/latest；**两端通道隔离**）、`GET /public/app-versions/download/:id`（仅启用版本可下载，流式返回）

## 金额字段的接口契约（2026-09-23 小数金额）

- 所有金额字段（商品价 `price`、订单/快照 `unitPrice`/`totalAmount`、结算 `workerAmount`/`platformAmount`、钱包 `balance`、流水 `amount`/`balanceBefore`/`balanceAfter`、累计 `totalSpent`、榜单 `totalAmount`/`effectiveAmount`）一律返回 **JSON 数字**：
  整数价目序列化为 `16`，小数价目序列化为 `5.5`（服务端 DECIMAL + `money.transformer` 已保证）
- **客户端铁律：禁止 `json['x'] as int`** —— 遇到小数值 Dart 抛 `TypeError`，导致整页崩溃（老板端/工作端订单页、钱包页曾经因此崩）。
  统一用 core 的 `parsePoints(v)` 解析、`fmtPoints(v)` 展示（整数不带小数点，小数最多两位去尾零）
- 订单列表模型统一走 core 的 `OrderBrief`（双端共用一份解析，避免一端漏改）
- 结算 70/30 四舍五入到 0.01（`Math.round(总价×70)/100`）；客户端展示的预览金额必须用同一算法，实际结算以服务端返回为准
- 客户端解析回归测试：`apps/packages/core/test/`（`live_orders_fixture_test` 用生产真实响应夹具；夹具由 `scripts/tmp/dump-live-payloads.mjs` 生成）

## 订单游戏信息（2026-09-24，负责人需求）

- 下单 `POST /user/orders` 新增**必填**：`gameZone`（`qq`/`wechat`，QQ区/微信区）、`gamePlayerId`（游戏ID，1-64 位，字母/数字/中文/下划线/短横线）；缺失或非法 400
- **可见性铁律（隐私）**：`gameZone/gamePlayerId` 只在以下通道返回 —— 下单创建响应（发给老板本人）、老板订单详情、工作端「我的订单」（已归属本打手）、管理端订单详情、派单 WS 通知（发给派单对象）
- 工作端接单大厅 `/worker/order-hall` **绝不返回**这两个字段；大厅返回 `productName`/`quantity`（多老板同商品 = 各自一条订单，不合并）

## 投诉 / 打赏 / 退款（2026-10-04，顶部导航三入口）

- 打赏（老板端，主体 id 一律取自 JWT）
  - `GET /user/tips/config`：预设金额（6/18/38/88 可改）+ 单次上限 + 同订单累计上限（只读）
  - `GET /user/tips/orders`：**我可打赏的订单**（`in_progress`/`pending_confirm`/`completed` 且已有接单打手），带 `tippedAmount`/`remainingAmount`
  - `POST /user/tips`：`{ orderId, amount, idempotencyKey, remark? }` —— 金额正整数、上限服务端判定；事务 + 条件扣款 + 双份流水（`order_tip_out` / `order_tip_income`）；同键重试返回 `duplicated=true`
  - `GET /user/tips`：我发出的打赏；工作端 `GET /worker/tips`、`GET /worker/tips/summary`
  - 管理端 `GET /admin/tips`（列表 + 累计/今日统计，`admin:tip:read`）、`GET|POST /admin/tips/config`（`admin:tip:config`）
- 退款申请（老板端）
  - `GET /user/refunds/orders`：可申请退款的订单（未开始/进行中/待确认；**已完成不在内**，走申诉）
  - `POST /user/refunds`：`{ orderId, reason, remark?, idempotencyKey }` —— **不可传金额**（服务端按订单快照），同一订单同时只允许一条待处理
  - `GET /user/refunds`：我的申请（`pending`/`approved`/`rejected` + 处理意见）
  - 管理端 `GET /admin/refunds`（`admin:refund:read`）、`POST /admin/refunds/:id/handle`（`{ action: approve|reject, remark }`，`admin:refund:handle`；驳回必填理由；重复审批 400，不二次退款）
- 投诉工单（老板端）
  - `POST /user/complaints`：`{ targetType: order|worker|service, targetId?, type: attitude|not_agreed|delay|other, content(5-1000), mediaIds?[] }`
    —— 订单/打手归属服务端校验；截图必须是**本人上传**的 `complaint_image`（最多 6 张）；目标名落快照
  - `GET /user/complaints`：我的投诉（`pending`/`processing`/`handled`/`rejected` + 处理意见）
  - 管理端 `GET /admin/complaints`（状态/对象筛选 + 统计）、`GET /admin/complaints/:id`（详情含截图媒体）、
    `POST /admin/complaints/:id/handle`（`{ status: processing|handled|rejected, remark }`；结案/驳回必填处理意见；已结案不可再流转）
- 媒体：新增受保护类型 `complaint_image`（≤10MB，重编码；`GET /media/protected/:id` 仅投诉人本人与管理员可读）
- 权限点：`admin:tip:read` / `admin:tip:config` / `admin:refund:read` / `admin:refund:handle` / `admin:complaint:read` / `admin:complaint:handle`
  - **收口（负责人 2026-10-04）**：`admin:refund:handle`（退款审批）与 `admin:tip:config`（打赏金额配置）已从全部非 `super_admin` 角色收回，**仅超级管理员角色 + 所有者（`admin.is_owner=1`）**可用；`admin:refund:read` / `admin:tip:read` 普通运营保留（能看不能批）；`admin:complaint:*` 本次不动。详见 docs/04 与 migration `1789990000000-refund-tip-super-only`

- ⚠️ **已下线（2026-10-05）**：上文「补充（2026-09-21 第二批接口）」里的**论坛/玩家圈接口**（`GET /forum/feed`、`POST /forum/posts`、`GET /forum/posts/:id`、`GET /forum/posts/:id/comments`、`POST|DELETE /forum/posts/:id/like`、`POST /forum/posts/:id/comments`、`DELETE /forum/posts/:id`、`DELETE /forum/comments/:id`、`GET /admin/forum/posts`、`POST /admin/forum/posts/:id/moderate`、`POST /admin/forum/comments/:id/remove`）已随后端 `forum` 模块与 `/forum*`、`/admin/forum*` 路由**一并删除**，实测均返回 **HTTP 404**。保留此行仅为解释历史文档；**`forum_*` 表与数据保留不删**（如需彻底清库须单独批准）。

## 身份绑定 / 伴随会话（2026-10-06，一 App 双态 · 方案甲）

> 认证与安全语义（kind、TTL、每请求校验、白名单默认拒绝）见 **docs/04「伴随会话」**；表结构见 docs/02。Swagger 标签 `user/identity`。

### 4 个接口

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| POST | `/user/identity/bind` | 老板侧 `@Roles('user')`（**companion 不可用**） | 绑定打手账号：校验打手账密 + 角色/封禁/在职/占用/上限 → 建绑定 → **签发伴随会话**。返回 `bindingId`/`rebound`/`boundAt`/`bossTokenUnchanged`/`companionToken`/`companionRefreshToken`/`companionExpiresIn`/`maxPerBoss`/`worker` 摘要。**老板自己的 token 不变**（`bossTokenUnchanged: true`） |
| POST | `/user/identity/unbind` | 老板侧 `@Roles('user')`（**companion 不可用**） | 解绑：绑定置 `unbound`（**保留历史行**）+ **立即吊销该绑定的全部 companion 会话**。body `bindingId?`（**上限为 1 时可省略**；多条绑定时必填）。返回 `revokedSessions` + 中文提示「已解绑，打手态登录已失效」 |
| GET | `/user/identity` | 老板侧 `@Roles('user')`（**companion 不可用**） | 当前绑定状态：未绑定返回 `bound:false`；已绑定返回打手档案摘要（工号/昵称/接单与客服权限/分部权限）+ 绑定上限。**不含任何敏感字段**（无密码哈希、无手机号） |
| POST | `/user/identity/refresh` | **公开**（只吃 companion `refreshToken`，**不需要老板 token**） | 伴随会话续期：校验绑定仍 `active` → 轮换出新的 companion 令牌，**TTL 仍 12h**（不会续成 30 天） |

**请求体契约**

- `bind`：`{ username?, uid?, workerNo?, password }` —— 前三个**三选一定位**（登录名 / 展示 ID / 工号），都不传 → 400；
  `password` 必填 1–64 位。**主体 id 只从 JWT `sub` 取**：请求体只描述"绑谁"，**绝不接受任何 boss id / userId**（客户端数据一律不可信）。
- `unbind`：`{ bindingId? }`（1–20 位）。
- `refresh`：`{ refreshToken }`（1–512 位）。

### 错误码表（**中文原文**）

| HTTP | errorCode | 中文原文 | 场景 |
|---|---|---|---|
| 400 | — | 请填写打手账号（登录名 / 展示 ID / 工号） | `bind` 三个定位字段都没传 |
| 400 | — | 账号不存在或密码错误 | 定位不到打手账号（**不泄露存在性**） |
| 400 | — | 账号或密码错误 | 密码错（**刻意排在角色/封禁之前**：不知道密码的人得不到任何账号情报） |
| 403 | — | 该账号不是打手账号，无法绑定 | 定位到的账号 role ≠ worker |
| 403 | `ACCOUNT_BANNED` | （复用既有封禁文案，含封禁结束时间） | 打手账号封禁中（**到期自动解封**） |
| 400 | — | 该打手账号已停用，无法绑定 | `worker.status ≠ 1`（档案停用） |
| 400 | — | 该打手账号已被其他老板绑定，请先让对方解绑 | 唯一键 `UK_wib_active_worker` 命中 |
| 400 | — | 绑定数量已达上限（当前上限 N 个）… | 老板侧达 `worker_binding_max_per_boss`（默认 1） |
| 429 | `RATE_LIMITED` | 绑定尝试过于频繁，请稍后再试 | 限流（与 `/auth/login` 同策略 **5 次/分/IP+账号**） |
| 400 | — | 未找到该绑定（可能已解绑或不属于当前账号） | `unbind` 指定了 `bindingId` 但没命中 |
| 400 | — | 当前没有已绑定的打手账号 | `unbind` 未指定却没有任何 active 绑定 |
| 400 | — | 存在多个绑定，请指定要解绑的 bindingId | 上限 >1 且有多个 active 绑定 |
| 401 | — | 伴随身份已失效，请重新绑定打手账号 | **companion 失效**：绑定被解绑（`unbound`）/ 不存在 / `binding_id` 空 / 会话过期（客户端据此退出打手态） |
| 401 | — | 该打手账号已被封禁，伴随身份不可用 | 每请求校验：打手账号封禁 |
| 401 | — | 该打手账号已停用，伴随身份不可用 | 每请求校验：打手档案停用 |
| 401 | — | 伴随身份已失效（该打手账号已在别处登录），请重新绑定 | companion 被同账号的新 companion 顶掉（`revoked=2`） |
| 403 | — | 伴随身份无此操作权限，请切回老板身份后操作 | **companion 访问白名单外接口**（默认拒绝，清单见 docs/04） |

- 限流策略与 `/auth/login` 一致（`BIND_RATE_LIMIT=5` / 60s，键 = `IP + 账号`）；**绑定失败也计入**（防"只试密码"绕过）。
- 绑定/解绑的成功与失败均写**身份事件审计**（`recordIdentityEvent`，含 IP / UA / 失败原因），可追溯。

### 行为变更（既存接口）

- `GET /worker/order-hall`：**无任何分部权限**时由 **403 报错页** → **200 + 空列表 + `divisionDenied` + 中文提示**（CLAUDE.md 结构规则 10）。
  判定只认权威表 `worker_division_permission`，**不再用 `worker.can_take_order` 派生汇总拦截**；仅"无打手档案 / 档案停用"仍 403。**指定无权限分部时的既有行为逐字不变**（抢单仍 403）。

## 4 缺口收尾（2026-10-06，身份合并实测缺口）

| 缺口 | 修复 | 服务端位置 |
|---|---|---|
| 1 封禁老板后其名下 companion 仍可用 | 封禁**对称释放两侧**绑定 + 守卫加**老板账号 `status=1`** 校验（双保险）；解封不自动恢复 | `UserAdminService.ban`、`worker-binding-release.ts`、`jwt-auth.guard.ts` |
| 2 删除账号不释放绑定（悬空 + 名额永久占用） | **既有事务内**释放两侧绑定（历史行保留 `unbound`）→ 名额自动让出、可重新绑定；`GET /user/identity` 不再 400「打手档案不存在」 | `UserAdminService.deleteUser` |
| 3 `POST /user/conversations/:id/read` 不存在（404 → 客户端静默 no-op） | 新增 REST 路由，转发 `ChatService.markRead`（与 WS `msg:read` 同一实现）；**200** + `{ok:true,unread:0}`、幂等、只认当事方 | `chat.controller.ts`（消息族白名单已覆盖） |
| 4 打手态「联系客服」的会话不出现在客服段 | `GET /worker/cs/conversations` 集合 = **被指派的 CS 会话 ∪ 该打手作为发起方的 CS 会话**（严格当事方，不泄漏他人会话）；未读按"我是发起方 / 我是客服"分侧取 | `ChatService.workerConversations` |

**`GET /worker/cs/conversations` 集合口径（缺口 4 后；2026-10-11 加 `status` 过滤）**

- `type='cs'` 且（我是 active 指派客服 **∪** 我是会话发起方 `user_id`）**且 `status='open'`**；
- `type='worker'`（老板↔打手直聊）且我在对端 —— 既有口径**逐字未变**；
- `type='friend'` 且我在任一方；
- 未读：我作为**发起方**的 CS 会话取 `unread_user`（客服回复我的未读），我作为**被指派客服**取 `unread_worker`。
- 反向不泄漏：与该账号无关的 CS 会话（既不是我发起、也没指派给我）永远不会出现在列表里。

**已结束客服会话口径（2026-10-11 真机报障修复；用户侧 `/user/conversations` 与客服侧上面这条同一口径）**

- 咨询结束（`chat_conversation.status='closed'`）后该会话**不再出现在任何会话列表**（两侧查询都加 `c.status='open'`），
  未读快照（WS `unread:snapshot` / `sync:unread`）同样排除它，`closeByUser/closeByWorker/closeConversation`
  把两侧未读一起清零 → **列表未读合计与总未读一致**（真机报障：结束了还挂红点）。
- **历史一行不删**：按 id 直接打开仍可读（不断 404）—— 口径是「不进列表，但可读历史」，
  刻意避免"列表里有、点开 404"的自相矛盾。
- **客服侧打开自己正在服务的会话不再 404**：`resolveUserRouteActor(userId, sessionRole, conversationId)`
  （`chat.controller.ts` 的 `info`/`historyOf`/`syncOf`/`sendTo` 共用）在"我不是用户侧成员、但确是当事客服
  （active 指派）"时按 **worker 侧**处理（复用既有 `isWorkerPartyOf`，无第二份 SQL）；老板态恒为 `user` 侧一行未变，
  非当事方仍旧 404「会话不存在」（安全审计 F3 口径不变）。
- `POST /user/conversation/close` **请求体不带 id**（打手态聊天页沿用老板端页面）：老语义优先（关我自己发起的进行中会话），
  只有"我自己没有、且恰好服务着一条进行中咨询"时才关那一条；服务 2 条以上不猜（仍 404，需带 id 精确关闭）。
- 代码位置：`ChatService.listUserConversations` / `workerConversations` / `closeByUser` / `closeByWorker` /
  `closeConversation` / `resolveUserRouteActor`、`ChatWsGateway.userSnapshot|workerSnapshot`；
  回归套件 `scripts/tmp/cs-closed-e2e.js`（14 断言）。

## 充值（2026-10-06，线下收款 + 人工审核）

> **合规红线（先读这段再看接口）**：本模块**不接任何支付通道** —— 没有支付 SDK、没有支付回调、
> 没有支付单号，**全站不出现「支付成功」字样**（只有「**已发放**」= 积分已由管理员手工发放）。
> 收款码是一张**图片**，App 只展示；老板在**平台外**（微信/支付宝）自行付款 → 上传**转账截图** →
> 管理员**人工核对** → 手工发积分。**平台不经手资金**；**不做自动到账**；**不做提现**。
> 会话语义（`kind='recharge'`、白名单、每请求校验）见 **docs/04「受限充值管理员会话」**；表结构见 docs/02。

### ⚠️ 双层口径（PC 管理端 vs App 管理员态）

| 入口 | 会话 | 接口族 | 权限 |
|---|---|---|---|
| **PC 管理端**（admin-web） | **primary**（正常 `role=admin` 登录） | `/admin/recharge/*` | `recharge:review` / `recharge:grant` |
| **App 内「管理员身份」** | **受限会话** `kind='recharge'` | `/recharge/*` | `recharge:review` / `recharge:grant` |

**管理端不需要、也不应该套受限会话**（Web 后台本就是管理员终端）。两条入口**共用同一个服务层**
（`RechargeService.reviewList / grant / reject`）→ 幂等、审计、状态机完全一致。

### 用户侧（primary 会话）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | `/public/recharge/config` | **匿名** | 充值页首屏：`{amountOptions, customEnabled, minYuan, maxYuan, pointsPerYuan, pendingLimitPerUser, noticeText, qrCodes:[{id,channel,label,url}]}`。**不下发 `adminLimit`**（内部治理参数，与老板无关）。进 `PublicCacheInterceptor`（进程内 30s + `Cache-Control` 60s 档），**所有写路径带失效钩子** → 运营改完下一次请求即生效 |
| POST | `/user/recharge/requests` | `@Roles('user')` | 提交申请：`{amountYuan, qrId?, note?, proofMediaId}` → **201** `{id, points, status:'pending'}`。校验顺序：**金额 → 换算 → 凭证归属 → 收款码 → 待审上限**（顺序即优先级，见下表错误码） |
| GET | `/user/recharge/requests?page=&pageSize=` | `@Roles('user')` | 我的申请（`status` / `rejectReason` / `reviewedAt` / `proofUrl` / `qrLabel`）+ `pendingCount` + `pendingLimitPerUser`（客户端据此禁用提交按钮） |

**积分换算（负责人口径"说明取舍"）**：`points = Math.floor(amountYuan × pointsPerYuan)` —— **向下取整**。
理由：这是"老板付了钱、平台给积分"的单向换算，向下取整保证**平台不会多发**（6.9 元 × 10 = 69 而非 69/70 之争）；
差额最多 1 积分，且金额档位全是整数、比例默认 10，正常路径下根本不触发取整。
换算后 `points < 1` → 中文 400（不产生 0 积分申请）。**如需"向上取整"要负责人单独定案。**

### 身份侧（老板端「身份」新增管理员身份）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| POST | `/user/identity/bind-recharge-admin` | **持有 primary 会话**（`@Roles('user','admin')`） | `{username,password}` → 校验 `role='admin'` **且在 `recharge_admin` 白名单内**、未封禁 → 签发**受限会话**（**不顶 primary**；TTL 与 companion 一致 **12h**）。返回 `{admin:{id,nickname,username}, rechargeToken, rechargeRefreshToken, expiresIn:43200}` |
| POST | `/user/identity/refresh-recharge-admin` | **公开**（只吃 recharge `refreshToken`） | 受限管理会话续期（仍 12h）；kind 闸门：非 recharge 令牌（含 primary/companion）**在任何写操作之前** 401 |

### 管理员态（受限会话 `kind='recharge'`，只放行以下接口）

| 方法 | 路径 | 权限点 | 说明 |
|---|---|---|---|
| GET | `/recharge/requests?status=pending\|granted\|rejected\|all&keyword=&page=&pageSize=` | `recharge:review` | 列表：用户昵称 + **中文 ID** + 金额 + 积分 + **凭证媒体 id（`proofMediaId` / 别名 `voucherMediaId`）** + 凭证 url + 提交时间 + 审核人 |
| POST | `/recharge/requests/:id/grant` | `recharge:grant` | **幂等发放**（事务 + 行锁 + 条件 UPDATE + 幂等键唯一约束）：复用**既有超管发积分能力**（`WalletService.grantInTx`）→ 写流水（含前后余额快照）→ 回写 `granted/reviewed_by/reviewed_at/wallet_transaction_id` → 通知用户「充值申请已到账：+N 积分」 |
| POST | `/recharge/requests/:id/reject` | `recharge:grant` | `{reason}` → `rejected` + 原因 + 通知用户（**不触碰积分**：pending 从未加过分） |
| GET | `/recharge/me` | 无（身份信息） | 当前管理员态信息 + 待审核数 |
| GET | `/recharge/proof/:requestId` | `recharge:review` | 转账截图（**受限会话专用窄通道**，只放行"这张申请的那张图"；理由见 docs/04 与待确认事项） |

> **凭证 URL 的两条口径（2026-10-07 修掉"凭证图永久转圈"后的定案，改代码前先读这条）**
>
> 1. **PC 管理端**（primary 会话）走 `GET /api/v1/media/protected/:id` —— 服务端下发的
>    `proofUrl` / `voucherMediaId` 就是这个口径（`MediaService.clientPath()` 对受保护资源
>    **带 `/api/v1` 前缀**；公开媒体 `/media/public/:id` 不带，见 docs/08）。
> 2. **App 管理员态**（`kind='recharge'` 受限会话）**一律**走 `GET /api/v1/recharge/proof/:requestId`
>    —— 白名单刻意不含 `/media/*`，服务端下发的受保护 URL 在 App 里必然 403。
>    core 的 `resolveRechargeProof()` 因此**优先用申请 id**（拿不到才退回服务端给的地址），
>    列表与详情同一份口径；图片请求还必须显式带受限会话令牌（`proofImageHeaders`）。

**受限会话白名单**（`isRechargeAdminAllowedRoute`，**默认拒绝**）：只放行 `/recharge/*` +
`GET /auth/me` + `POST /auth/logout` + `POST /auth/refresh`。其它一律 **403 中文**
「受限管理身份仅可处理充值审核，请用管理端完成其它操作」——含 `/admin/*`（**连本功能的 `/admin/recharge/*` 也不放行**）、
`/user/orders`、`/user/wallet`、`/user/identity/*`、`PUT /user/profile`、`/auth/password`、`/media/*`。

**每请求校验（无缓存，实现只有一份 `checkRechargeSession`）**：仍在 `recharge_admin` 白名单 +
账号未封禁 + 仍是 `role='admin'`；**被移出白名单 → 下一次请求立即 401**。
`/recharge/*` 另由 `RechargeSessionGuard` 要求 `kind='recharge'`（primary 打了 → 403）。

### 管理端（primary 会话 + `admin:*` / 窄权限点）

| 方法 | 路径 | 权限 |
|---|---|---|
| GET | `/admin/recharge/qr-codes?enabled=1\|0` | `admin:setting:read` |
| POST | `/admin/recharge/qr-codes` | `admin:setting:write` |
| PUT | `/admin/recharge/qr-codes/:id` | `admin:setting:write` |
| DELETE | `/admin/recharge/qr-codes/:id` | `admin:setting:write` |
| GET | `/admin/recharge/config` | `admin:setting:read` |
| PUT | `/admin/recharge/config` | `admin:setting:write` + **仅超管**（`is_high_security=1`） |
| GET | `/admin/recharge/requests?status=&keyword=&startTime=&endTime=&page=&pageSize=` | `recharge:review` |
| POST | `/admin/recharge/requests/:id/grant` / `:id/reject` | `recharge:grant` |
| GET | `/admin/recharge/admins` | `admin:admin:read` |
| POST | `/admin/recharge/admins` | `admin:admin:write` + **仅超管**（`assertSuperAdmin`） |
| DELETE | `/admin/recharge/admins/:id` | `admin:admin:write` + **仅超管** |

**字段别名（前后端同名收敛，避免"各叫一个名字"变成线上 400）**：

- 收款码图片：写侧同时接受 `imageMediaId`（管理端 `api/recharge.ts` 契约名）与 `mediaId`（后端列名）；读侧两者都回。
- 申请行：同时回 `amountYuan` 与 `amount`、`proofMediaId` 与 `voucherMediaId`（同值），并补 `reviewerName`（审核人昵称）。
- 白名单：写侧同时接受 `adminUserId` / `targetUserId` / `userId`；读侧回 `id` / `adminUserId` / `userId`（三者同值，`recharge_admin` 无代理主键）。

### 错误码表（**中文原文**）

| HTTP | 中文原文 | 场景 |
|---|---|---|
| 400 | 充值金额不正确 | 金额非正/非数字 |
| 400 | 充值金额最多保留 2 位小数 | 超出 DECIMAL(10,2) 精度（避免静默改写） |
| 400 | 请从金额档位中选择：6 / 10 / 20 / … 元 | 非档位 **且** `customEnabled=false` |
| 400 | 充值金额不能低于 N 元 | 非档位且低于 `minYuan` |
| 400 | 充值金额不能高于 N 元 | 非档位且高于 `maxYuan` |
| 400 | 金额过小，换算后积分为 0，请提高金额或联系管理员 | `floor(金额 × 比例) < 1` |
| 400 | 请上传转账截图 / 转账截图必须是你本人上传的图片 / 转账截图不存在，请重新上传 / 转账截图必须是图片 | 凭证缺失、**非本人**、不存在、非图片 |
| 400 | 收款码不存在，请刷新后重试 / 该收款码已停用，请刷新后重新选择 | `qrId` 非法（可空，故仅传了才校验） |
| 400 | 你还有 N 笔充值申请待审核（最多 M 笔），请等待管理员处理后再次提交 | **待审核数 ≥ `pendingLimitPerUser`**（默认 3，第 4 张即此错） |
| 400 | **该申请已发放** | **重复发放**（幂等：不重复加分） |
| 400 | 该申请已驳回，不能再次发放 / 该申请已处理，不能重复操作 | 对已驳回申请再发放 / 重复驳回 |
| 400 | 请填写驳回原因 / 驳回原因最多 200 字 | 驳回原因必填与长度 |
| 400 | 状态筛选值不合法（pending/granted/rejected/all） | 列表 `status` 非法 |
| 404 | 充值申请不存在 / 转账截图不存在 / 收款码不存在 | 目标不存在 |
| 401 | 受限管理身份已失效，请联系超级管理员重新授权 | **被移出白名单**（下一次请求即失效） |
| 401 | 该管理员账号已被封禁，受限管理身份不可用 / 该账号已不是管理员，受限管理身份不可用 | 每请求校验：封禁 / 角色被改 |
| 401 | 受限管理身份已失效（该管理员账号已在别处登录），请重新绑定 | 被同账号的新 recharge 会话顶掉（`revoked=2`） |
| 401 | 该令牌不是受限管理身份，请重新绑定管理员账号 | `refresh-recharge-admin` 收到非 recharge 令牌（**写操作之前**即拒） |
| 403 | 受限管理身份仅可处理充值审核，请用管理端完成其它操作 | **受限会话访问白名单外接口** |
| 403 | 该接口仅限「管理员身份」受限会话调用，请先在身份里绑定管理员账号 | primary 会话打 `/recharge/*`（双层口径） |
| 403 | 该账号不是管理员账号，无法进入管理员态 / 该账号未获授权进行充值审核，请联系超级管理员 | 绑定管理员态：角色不符 / 不在白名单 |
| 400 | 账号或密码错误 | 绑定管理员态：账号不存在与密码错**逐字同一句**（防账号枚举，与 `/auth/login`、`/user/identity/bind` 同口径） |
| 403 | 最高安全配置仅超级管理员可修改 | `PUT /admin/recharge/config` 非超管（`is_high_security` 机制，与 `PUT /admin/settings/:key` 同一条路径） |
| 403 | 充值审核管理员白名单仅超级管理员可维护 | `POST/DELETE /admin/recharge/admins` 非超管（**即便它有 `admin:admin:write`**） |
| 400 | 该账号不是管理员账号，无法授权充值审核 / 该管理员账号已停用，请先启用 / 该账号没有管理员档案，无法授权充值审核 / 该账号已在充值审核白名单中 | 白名单增：目标非法 / 停用 / 无档案 / 重复 |
| 400 | 充值审核管理员已达上限（N 个，最多 5 个），请先移除后再添加 | **上限 5**（硬上限常量，配置只能在其内收紧；**并发安全**） |
| 400 | 金额档位必须是 1–1000000 的整数（元）… / 金额档位至少保留 1 个 / 金额档位最多 20 个 / 金额档位 N 元超出自定义区间（A–B 元）… | 配置写入口校验（档位） |
| 400 | 自定义金额下限（X 元）不能大于上限（Y 元） / 1 元对应积分必须是 1–1000 的整数 / 每人待审核上限必须是 1–20 的整数 / **受限管理员上限必须是 1–5 的整数（最多 5 个账号）** / 说明文案最多 500 字 | 配置写入口校验（其余项） |
| 429 | 尝试过于频繁，请稍后再试（`errorCode=RATE_LIMITED`） | 绑定管理员态限流（**5 次/分/IP+账号**，与 `/auth/login` 同策略） |

### 不做的能力（接口层面同样"存在即风险"，故一个都没有）

- **没有**下单/收款/查询支付状态的接口，**没有**支付回调地址，**没有**支付单号字段；
- **没有**任何"自动到账"的接口或定时任务（`granted` 只能由人工 grant 触发）；
- **充值没有**提现接口（老板的余额不可兑回现金；**打手的提现是另一条链路**，见下节，
  与本节"平台不经手资金的充值"是两回事：提现是**平台经手资金的人工打款**，负责人 2026-10-11 定案）。

## 打手提现（2026-10-11，人工打款）

> **语义**：打手提交申请 → **同一事务内立即从余额扣除并锁定** → 管理员核对收款信息后**线下微信打款**
> → 回填凭证记 `paid`；打款失败则**驳回 → 退回余额 + 反向流水**（`withdraw_reject`）。
> **平台经手资金**（与充值相反）；**仍然没有任何代付/通道/回调接口** —— 打款动作在微信里人工完成，系统只负责扣款、锁款、记账、留痕。
> 数据模型见 docs/02；账务见 docs/06「提现」；会话语义见 docs/04。

### 三组入口（**同一服务层**：`WithdrawService`）

| 入口 | 会话 | 路径前缀 | 权限点 |
|---|---|---|---|
| 打手端 | `role=worker`（primary 或 companion 打手态） | `/worker/withdraw/*` | 无（本人能力；主体只取 JWT sub） |
| PC 管理端 | **primary**（正常 `role=admin` 登录） | `/admin/withdraw/*` | `withdraw:review` / `withdraw:pay` |
| App 内「管理员身份」 | **受限会话** `kind='recharge'`（12h、白名单） | `/withdraw/*` | 同上两点 |

后两者**共用同一个服务层**（`reviewList` / `detail` / `proofMedia` / `pay` / `reject`）→
幂等、审计、状态机完全一致，差的只是"用哪种会话进来"。

### A. 打手端 `/worker/withdraw/*`（`@Roles('worker')`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/worker/withdraw/account` | 我的收款信息：`{bound, realName(脱敏), phone(脱敏), wechatId, qrUrl, updatedAt}`；未绑定 `bound:false`（**不是 404**，客户端直接渲染引导态） |
| POST | `/worker/withdraw/account` | `{realName, phone, wechatId, qrMediaId}` → 绑定/**换绑**（覆盖同一行，旧值进 `operation_log`）；`qrMediaId` **必须是本人上传的 `withdraw_qr` 图片** |
| GET | `/worker/withdraw/config` | `{minAmount, maxAmount, dailyLimit, feeRate, noticeText, balance, todayUsed, pendingCount, pendingLimit}`（**客户端只用它做提示，服务端仍是权威**） |
| POST | `/worker/withdraw/requests` | `{amount}`（幂等键走请求头 `Idempotency-Key` 或 body `idempotencyKey`）→ **事务**：锁钱包 → 校验（已绑定 / ≥min / ≤max / ≤**全部余额** / 今日次数 / 未结清上限 1）→ **立即扣减 + 写流水**（`change_type='withdraw'`）→ 建 `pending` → `{id, amount, status, balanceAfter, appliedAt}` |
| GET | `/worker/withdraw/requests?page=&pageSize=` | 我的提现记录（金额/状态/申请时间/打款时间/驳回原因/打款凭证） |

### B. 管理端 PC `/admin/withdraw/*`（`@Roles('admin')` + 权限点）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | `/admin/withdraw/requests?status=&keyword=&startTime=&endTime=&page=&pageSize=` | `withdraw:review` | 列表：打手昵称/工号/金额/状态/申请时间 + **完整收款信息** `account:{realName,phone,wechatId}`（与详情**同名同形**）+ **兼容保留** `accountMasked`（同一行的脱敏值，旧客户端仍只认它） |
| GET | `/admin/withdraw/requests/:id` | `withdraw:review` | 详情：**完整**姓名/电话/微信号 + 收款码链接 + 打款记录 + 退款反向流水 |
| GET | `/admin/withdraw/proof/:id?kind=qr\|payout` | `withdraw:review` | **受保护取图通道**（`kind` 缺省 = `qr`）：收款码 / 打款凭证；`Cache-Control: no-store` |
| POST | `/admin/withdraw/requests/:id/pay` | `withdraw:pay` | `{proofMediaId, note?}`（**凭证必填**，备注可选；2026-10-11 起）→ **条件 UPDATE（`WHERE id=? AND status='pending'`）判 affectedRows** → `paid`；重复调用 **400 中文「该申请已打款」**且不重复生效 |
| POST | `/admin/withdraw/requests/:id/reject` | `withdraw:pay` | `{reason}`（必填）→ 条件 UPDATE → `rejected` + **退回余额 + 反向流水**（`withdraw_reject`）；重复调用 400 |
| GET | `/admin/withdraw/config` | `admin:setting:read` | 提现配置（平铺 + `defaultConfig` + `pendingLimit`） |
| PUT | `/admin/withdraw/config` | `admin:setting:write` + **仅超管**（`is_high_security=1`） | 保存门槛/次数/费率/文案（局部提交，未传的字段沿用当前库值）；读侧无缓存 → 保存即生效 |

### C. App 内「管理员身份」`/withdraw/*`（受限会话 `kind='recharge'`）

| 方法 | 路径 | 权限 |
|---|---|---|
| GET | `/withdraw/requests?status=&keyword=&page=&pageSize=` | `withdraw:review` |
| GET | `/withdraw/requests/:id` | `withdraw:review` |
| GET | `/withdraw/proof/:id?kind=qr\|payout` | `withdraw:review` |
| POST | `/withdraw/requests/:id/pay-proof` | `withdraw:pay` |
| POST | `/withdraw/requests/:id/pay` / `:id/reject` | `withdraw:pay` |

- **打款凭证上传（2026-10-11 新增）**：`POST /withdraw/requests/:id/pay-proof`（multipart，字段 `file`，
  **不接受 `type`**——用途由服务端固定为 `withdraw_proof`/protected）→ `{ mediaId, url }`
  （`url` = 既有受保护取图约定 `/api/v1/media/protected/:id`，**不返回磁盘路径**）。
  校验：① 受限管理会话（`RechargeSessionGuard` + `@Roles('admin')` + `withdraw:pay`）；
  ② 该申请**必须存在**（否则 404 中文，不泄漏存在性）且处于 `pending`（已打款 → 400 中文「该申请已打款」）；
  ③ 文件沿用 `MediaService` 既有校验（用途白名单 → 大小 10MB → 魔数 → 重编码剥离负载）；
  ④ 每次上传写 `operation_log`（谁传的 / 哪张申请 / media id），**不落文件内容**。
  **同一申请重复上传 → 允许**（后传的成为新凭证，每次留痕）；写库用**条件 UPDATE 判 `affectedRows`**
  （`WHERE id=? AND status='pending'`）——与 pay/reject 同一条姿势。
- **白名单要显式加**：`isRechargeAdminAllowedRoute` 新增 `/withdraw/*`（**允许清单**：不加则整族 403 中文）。
  上面的 `pay-proof` **落在同一条前缀内 → 白名单一个字都不用改**（**也没有**顺手放宽 `/media/*`：
  受限会话直传 `/media/upload` 仍 403 中文）。
- **没有配置接口**：改门槛是治理动作，只走管理端 primary 会话（与"改充值配置/收款码必须走管理端"同口径）。
- `/admin/withdraw/*` 对受限会话**不放行**（403 中文），PC 与 App 两条入口因此语义清晰、不分叉。
- **`pay` 的凭证必填对两条入口一致**（校验收口在 `WithdrawService.pay` 唯一一处 → 以更严的为准）：
  备注是**可选补充**，不再是凭证的替代品。

### 错误码表（**中文原文**）

| HTTP | 中文原文 | 场景 |
|---|---|---|
| 400 | **请先绑定收款信息** | 未绑定就申请（打款去向未知，绝不放行） |
| 400 | 请填写真实姓名 / 真实姓名最多 32 字 / 请填写手机号 / 手机号格式不正确（请填写 11 位手机号） / 请填写微信号 / 微信号最多 64 字 / 请上传微信收款码 | 绑定收款信息的字段校验 |
| 400 | 收款码图片不存在，请重新上传 / **收款码必须是你本人上传的图片** / 收款码必须是图片 / 收款码请使用提现收款码上传（type=withdraw_qr） | 收款码媒体校验（归属 + 用途白名单） |
| 400 | 提现金额不正确 / 提现金额最多保留 2 位小数 | 金额非法 / 超 DECIMAL(12,2) 精度 |
| 400 | **单笔提现不能低于 ¥10.00** / **单笔提现不能高于 ¥2000.00** | 低于 `minAmount` / 高于 `maxAmount`（金额按配置实时读库） |
| 400 | **提现金额不能超过当前余额（¥N.NN）** | 金额 > 全部余额（锁内读到的权威余额） |
| 400 | **今日提现申请次数已用完（每日最多 N 次），请明天再试** | 北京时间当日申请数 ≥ `dailyLimit` |
| 409 | **你有一笔提现正在处理中，请等待管理员处理后再提交** | 已有 `pending` 申请（并发两笔时落败方看到的就是这一条；唯一键兜底撞键也翻译成它） |
| 400 | **请上传打款凭证** | `pay` 的 `proofMediaId` 为空（2026-10-11 起：**凭证必填**，备注可选；PC 与 App 同一处校验） |
| 400 | 打款凭证不存在，请重新上传 / 打款凭证必须是图片 / 打款凭证请使用提现打款凭证上传（type=withdraw_proof） | 打款凭证校验 |
| 400 | 请选择要上传的打款凭证图片 | `POST /withdraw/requests/:id/pay-proof` 未带 multipart 字段 `file`（或空文件） |
| 400 | **该申请已打款** / 该申请已驳回，不能上传打款凭证 / 该申请状态异常，无法上传打款凭证 | 上传打款凭证时该申请已不在 `pending`（条件 UPDATE 命中 0 行） |
| 400 | 无法识别的文件类型（仅支持 JPG、PNG、GIF、WebP 图片与 MP4 视频）/ 文件超出大小限制（最大 10MB）/ 该用途仅支持图片文件 | 上传打款凭证的文件校验（沿用 `MediaService` 既有实现） |
| 400 | **该申请已打款** | 重复 pay（幂等：不重复生效） |
| 400 | 该申请已驳回，不能打款 / 该申请已驳回，不能重复操作 / 该申请已打款，不能驳回 | 状态机单向：已被处理过的单据不能反向操作 |
| 400 | 请填写驳回原因 / 驳回原因最多 200 字 | 驳回原因必填与长度 |
| 400 | 状态筛选值不合法（pending/paid/rejected/all） | 列表 `status` 非法 |
| 400 | 开始时间格式不正确 / 结束时间格式不正确 | 时间筛选项非法（不静默忽略） |
| 400 | 取图类型不合法（kind=qr\|payout） | `proof` 的 `kind` 非法 |
| 404 | 提现申请不存在 / 该打手尚未绑定收款信息 / 收款码不存在 / 该申请还没有打款凭证 / 打款凭证不存在 | 目标不存在（凭证未打款时也是 404） |
| 403 | 工作端不存在，无法提现 / 工作端已停用，无法提现 | `role=worker` 但无打手档案 / 档案停用 |
| 403 | 无权限 | 缺 `withdraw:review` / `withdraw:pay`（`PermissionsGuard` 实时查库） |
| 403 | 受限管理身份仅可处理充值审核，请用管理端完成其它操作 | 受限会话访问白名单外接口（含 `/admin/withdraw/*`） |
| 403 | 该接口仅限「管理员身份」受限会话调用，请先在身份里绑定管理员账号 | primary 会话打 `/withdraw/*`（双层口径） |
| 403 | 最高安全配置仅超级管理员可修改 | `PUT /admin/withdraw/config` 非超管（`is_high_security` 机制） |

### 幂等（三层，缺一不可）+ 表结构级兜底

| # | 手段 | 落点 |
|---|---|---|
| ① | **事务 + `SELECT … FOR UPDATE` 锁钱包** | 申请：`SELECT id,balance FROM wallet WHERE user_id=? FOR UPDATE`（同一打手的申请在此排队）；pay/reject：`SELECT … FROM withdraw_request WHERE id=? FOR UPDATE` |
| ② | **条件 UPDATE 判 `affectedRows`** | `UPDATE withdraw_request SET … WHERE id=? AND status='pending'` —— **"能否打款/驳回/贴凭证"的唯一判定点**（刻意不写成"先读状态再 UPDATE"：那样把条件 UPDATE 变异成无条件也测不出来） |
| ③ | **幂等键唯一约束** | `wallet_transaction.idempotency_key`：扣款 `withdraw:<id>`、退回 `withdraw_reject:<id>`（`UQ_wallet_txn_idem`） |
| 兜底 | **表结构** | `UK_wr_pending_worker`（同一打手不可能两笔 pending，并发撞键 → 中文 409）、`UK_wr_wallet_txn`（一笔流水只能对应一张申请）、`UK_wr_idem`（客户端重试幂等） |

> 扣款与退回**都走既有 `WalletService`**（`withdrawDeductInTx` / `withdrawRefundInTx` → 内部是同一个
> `executeChange`）：本模块**不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`**。
> 金额一律 `¥`/两位小数，**全模块不出现"积分"**。

### 审计与通知

- **`operation_log`**：`withdraw:apply`（申请，`admin_id=NULL` 但照样留痕）/ `withdraw:account:bind` /
  `withdraw:account:rebind`（**含新旧值摘要**）/ `withdraw:pay-proof`（打款凭证上传：**哪张申请 + media id**，
  每次成功上传一条，**不落文件内容**）/ `withdraw:pay` / `withdraw:reject` / `withdraw:config:update`；
  `requestBody` 只记关键字段与前后值摘要，**不记密码/token**。
- **`user_notification` + `notification:new`**：「提现申请已提交：¥100.00 已从余额扣除…」/
  「提现已打款：¥100.00…」/「提现被驳回：¥100.00 已退回余额，原因：…」。

### 个人信息合规（docs/09）

**列表与详情都给完整收款信息**（2026-10-11 负责人定案）：两条入口的列表行下发
`account:{realName,phone,wechatId}`（与详情同名同形），**同时保留** `accountMasked`（脱敏值）做兼容
—— 理由：能读到它们的只有 `withdraw:review` 持有者，**读取者本身就是审核人**，向他隐藏只会迫使
"核对收款信息"必须点进详情（**权限点一个没加**，明细行为不变）。

**脱敏仅用于审计/通知面**（这条**不许放宽**）：`operation_log.request_body` 摘要（含绑定/换绑的
新旧值摘要）、`user_notification` 文案、任何服务端日志与打手侧回显（`GET /worker/withdraw/account`）
**一律只出现脱敏值**，不得出现完整手机号/微信号 —— `operation_log` 是比审核列表**更宽**的面
（能读它的人由「操作日志」权限决定，不一定是审核人）；PIPL 的合规点是"**不向无关方泄露**"，
不是"向审核人隐藏"。

姓名 / 手机号 / 微信号属敏感个人信息：接口**不返回给非授权方**（打手只看得见自己的，且是脱敏回显）；
收款码与打款凭证都是 **protected 媒体**，
只走 `GET …/withdraw/proof/:id?kind=qr|payout` 这条按申请收窄的通道（**不放行 `/media/*`**）；
**写入侧同样收窄**（2026-10-11）：打款凭证只能通过 `POST /withdraw/requests/:id/pay-proof` 贴到
**处于 `pending` 的那一张申请**上，`operation_log` 只记 media id 与元信息、**不落文件内容**。


## 补充（2026-10-06）：**管理端写接口必须写 `operation_log`**（不可违反）

> 口径一句话：**管理端任何"会改变库内容"的接口，必须在成功后写一条 `operation_log`**；
> 只加留痕，**不改权限、不改业务行为**。

### 为什么写进规范（真实缺口，2026-10-06 实测踩到）

`PUT /admin/recharge/config`（老板端可见的充值文案）、收款码增删改、充值审核白名单增删、
以及 `SystemSettingService.update()`（**全项目唯一的配置写入口**）原先**全都不写 `operation_log`** ——
事后只能从 `system_setting.updated_at` 看出"某个时刻被改过"，**看不出谁改的、改前是什么**。
将来新增配置项若还靠调用方自觉，缺口会一次次复发（与安全审计 F1「同一规则多处实现」同类根因）。

### 落库口径（`operation_log` 列）

| 列 | 口径 |
|---|---|
| `admin_id` / `admin_name` | 操作者；`admin_name` 由 `OperationLogService` 按 `admin_id` 回查补全。**`admin_id` 允许 NULL**（服务层内部路径拿不到请求上下文时，宁可不写「谁」也要写下「改了什么」；**传 `null`，不要传空串**——空串会让 bigint 列插入失败并被 catch 静默吞掉） |
| `module` | `recharge`（充值域写接口）/ `setting`（配置写入，`SystemSettingService.update` 唯一入口）/ 各业务模块自己的取值 |
| `action` | 领域:动作[:键]，≤64 字。例：`recharge:qrcode:create`、`recharge:qrcode:update`、`recharge:qrcode:delete`、`recharge:admin:add`、`recharge:admin:remove`、`recharge:config:update`、`setting:update:<key>` |
| `method` / `path` | 真实请求方法与路径（`req.method` / `req.path`，含 `/api/v1` 前缀）；服务层内部路径写 `SYSTEM` + `system_setting:<key>` |
| `request_body` | **脱敏 + 摘要**（见下），≤4000 字 |
| `result` | `success`（写接口在业务成功后写）；失败路径由调用方按需写 `fail` + `error_msg` |
| `request_id` | 必须带上 `req.requestId` —— 这是"审计那一行 ↔ 那一次请求日志"的唯一关联键 |

### `request_body` 只记关键字段与变更前后摘要（**不记敏感/超长原文**）

- 收款码：只记 `id` / `channel` / `label` / `sort` / `enabled`（**不记图片地址**）；
  编辑只记 `changed: [改了哪些字段名]`。
- 白名单：只记 `targetUserId`（**不记账号、密码、令牌**）。
- 配置：只记 `changedKeys: [改动过的顶层字段名]`；
  文案类字段额外记 `noticeTextBefore` / `noticeTextAfter`（各截断 200 字）；
  **整包配置本体不进审计表**（动辄几 KB，既噪音又不利于查）。
- 服务层配置写入（`module='setting'`）记 `{key, description, before, after}` 的**摘要**：
  字符串 >160 字截断并标注 `…(共N字)`，数组只记长度与前 10 项，对象限深 3 层。
- 反面清单（扫描即失败）：`password` / `token` / `secret` / `mediaId` / `jwt` / `Authorization` 等字样，
  以及任何 >200 字**未标注截断**的字段。

### 实现姿势（沿用既有，不引入第二种）

- 各模块自己 `providers: [OperationLogService]` + `TypeOrmModule.forFeature([OperationLog])`
  （见 `order.module` / `tip.module` / `recharge.module` / `setting.module`），**不把 log 模块做成全局单例**。
- 配置写入收口在 `SystemSettingService.update()` **一处**（将来新增配置项**默认就有留痕**）；
  调用方通过第 5 个可选参数 `actor` 传身份与来源请求，不传则只记「改了什么」。
- `OperationLogService.log()` 是**异步不阻塞**（内部自行 catch，失败只告警）→ **留痕失败不阻断业务**；
  故脚本/测试回读审计行前需等一拍。

### 自证脚本

`scripts/tmp/verify-admin-audit-log.js`：逐个打 7 个写接口（`PUT /admin/recharge/config` ·
`POST/PUT/DELETE /admin/recharge/qr-codes` · `POST/DELETE /admin/recharge/admins` ·
`PUT /admin/settings/:key`）→ 回读 `operation_log` 新增行原文 → 断言"有留痕 + 记下操作者 + request_id 非空"，
并对 `request_body` 逐行做敏感/超长扫描；跑完把改过的配置与白名单**还原**（收尾逐项核对）。

### 媒体：**只补 `DELETE`，`upload` 刻意不留痕**（2026-10-13 定案）

> `DELETE /admin/media/:id`：`module='media'` / `action='media:delete'`，
> `request_body` 只记 `{mediaId, mediaType, isProtected, sizeBytes, sha256, fileKey}`（**不落文件内容**）。
> `POST /admin/media/upload`：**刻意不写** `operation_log`。

**为什么破例**（本条是全规范里**唯一**明确"允许不留痕"的写接口，理由必须写清，避免后人当遗漏补上）：

- 改前实测真库 `operation_log` 里 `module='media'` 或 `path LIKE '%media%'` = **0 行**（上传、删除都没有）。
- **上传是高频动作**：管理端配商品图/Banner/分部图标时连续传很多张，逐张留痕会让 `operation_log`
  被"上传"淹没 —— 而审计的价值在**异常动作可回溯**，噪音会把真正要看的那几条挤下去。
- **删除是低频 + 不可逆 + 破坏性**（删库行 + 物理删文件）：删错了必须有据可查。
- 若将来确需给上传留痕，请先解决日志膨胀（例如按批次聚合），**不要**直接在控制器里加一行 `opLog.log`。

⚠️ **实现必须两件一起做**（本项目已踩过一次，`UnknownDependenciesException` 崩溃循环 46 次）：
`TypeOrmModule.forFeature([... , OperationLog])` **与** `providers: [..., OperationLogService]`
缺一即启动崩溃 —— 只 provide service 而不注册 `OperationLog` 实体，
`OperationLogService` 构造里的 `@InjectRepository(OperationLog)` 解析不到。

⚠️ **另一个实测踩到的坑**：`MediaService.deleteById()` 若返回 `Media` 实体，审计会写成
`"mediaId":"undefined"` —— 因为 TypeORM 的 `repo.remove()` 成功后**会把实体主键清成 `undefined`**。
必须在 `remove()` **之前**摘出快照（`DeletedMediaSnapshot`）再返回。
验收口径用「操作前 `MAX(id)` → 发一次请求 → 数新增行数」：删除 **恰好 +1 行**、上传 **+0 行**
（`scripts/tmp/verify-media-delete-audit.js`，12 断言）。

## 补充（2026-10-08）：**客服大厅**（有客服权限的打手主动接咨询）

> 负责人原话：「客服那里改成有人申请客服 **有客服权限的人用打手端主动接**，就像接单大厅那样」。
> **拍板口径**：**抢占式**（谁先点谁得，同一会话同时只能被一个客服接入）
> **+ 管理端保留强制改派兜底**。

### 池子从哪来（**没有新建任何"池子"表**）

老板发起咨询时 `ChatService.getUserConversation` 建的是 `chat_conversation(type='cs', status='open')`
且**不指派任何人** —— 所以「待接入池」本来就存在，只是以前没有列表接口：

```
待接入 = chat_conversation.type='cs' AND status='open'
         AND EXISTS (该会话至少一条 sender_type='user' 的消息)          -- 2026-10-08 晚新增
         AND NOT EXISTS (chat_conversation_assign 里该会话的 status='active' 行)
```

唯一出处是 `chat.service.ts` 的模块级常量 `CS_POOL_SQL`。**"三处共用"的复核证据（2026-10-08 晚实测）**：

| 用它的地方 | 代码位置 | 与常量的关系 |
|---|---|---|
| 大厅列表 | `csHall()` 的列表 SQL `WHERE ${CS_POOL_SQL}` | 直接内插同一常量 |
| 总数 | `csHall()` 的 `SELECT COUNT(*) … WHERE ${CS_POOL_SQL}` | 直接内插同一常量 |
| `waitingTotal` | `csHall()` 返回体 `waitingTotal: total` | **就是 `total` 这同一个变量**（不重算） |
| 广播**受众**（`cs:new` / `cs:claimed` 推给谁） | `emitToOnlineCs()` → `onlineCsWorkerIds()` | **另一份共享判定**（不是这段 SQL）：管"推给谁"、不管"哪些会话在池里"；`csHall.onlineCsCount` 与广播共用它，同样只有一份实现 |

`grep -c CS_POOL_SQL chat.service.ts` = **2 处 SQL 内插**（列表 + 总数）+ 1 处 `waitingTotal: total`
—— 所以"改一处 = 三处同时改"成立；任何将来的改动都只允许改这个常量（禁止第二份 SQL）。

> ⚠️ **2026-10-08 晚口径修正（产品）**：进池前提从"会话存在"收紧为"**老板已经发过至少一条消息**"。
> 老板打开客服页就会建会话（建会话行为一行未改、也**不**进池），所以旧口径会让大厅里出现一排
> `（暂无消息）` 的空条目（客服点进去没人说话）—— 那不是"有人申请客服"，是噪音。
> 用 `sender_type='user'` 而不是"会话里有任意一条消息"：管理端可以把**空会话**直接指派给客服，
> 客服回复后退回池子时，那条**不是老板在等**，不该进池（等价写法 `EXISTS(chat_message)` 会漏进这一种）。
> **等待时长起点**随之统一为**首条老板消息时刻**（`COALESCE` 到创建时刻的兜底保留为纯防御）。

### 会话状态与指派的既有语义（**未改一个字**）

| 状态 | 含义 | 谁写的 |
|---|---|---|
| `chat_conversation_assign.status='active'` | 此刻由该客服接待 | 管理端改派 / **客服大厅主动接入** |
| `inactive` | 管理员改派后原客服被解除（`chat:unassigned`） | 管理端改派 |
| `released` | 客服**主动退回池子**（历史保留，会话重新可被接入） | `POST …/release`（开关控制） |

### 接口清单（全部 `@Roles('worker')` + **每请求实时查库** `worker.can_serve_customer=1`）

| 方法 | 路径 | 入参 | 出参（`data`） | 说明 |
|---|---|---|---|---|
| GET | `/worker/cs/hall` | `page`（默认 1）`pageSize`（默认 20 / **硬上限 50**） | `{list[], total, page, pageSize, waitingTotal, onlineCsCount}` | 待接入列表，**等待最久在前** |
| POST | `/worker/cs/hall/:conversationId/claim` | 无 body | `{ok, conversationId, alreadyClaimed, workerUserId, workerNo}` | **抢占式接入**（**HTTP 200**，见下） |
| POST | `/worker/cs/hall/:conversationId/release` | 无 body | `{ok, conversationId, alreadyReleased}` | 退回池子（**开关控制**，HTTP 200） |

`list[]` 每项：`conversationId` · `userNickname`（发起方昵称）· `userUid`（中文 ID）·
`preview`（首条咨询摘要，超长截断 40 字 + `…`；首条是图片给 `【图片】`）·
`msgCount` · `waitedSeconds` · `waitedText`（`刚刚` / `N 分钟` / `N 小时 M 分钟` / `N 天 M 小时`）·
`waitingSince` · `createdAt`。

- **等待起点** = **首条老板消息的发出时刻**（2026-10-08 晚起恒为该值：进池就要求已经有老板消息；
  `COALESCE` 到会话创建时刻只作防御）。`waitingSince` 即该值，也是排序键。
  两个时刻都由**数据库时钟**（`TIMESTAMPDIFF(..., NOW())`）计算 —— 本机实测宿主与 MySQL 容器存在时钟差，
  用应用进程时钟减会把"刚刚"算成几小时，故口径写死在 SQL 里。
- **不泄露敏感字段**：只回 `nickname` + `uid`。**不回** `username`（登录名，回了等于把所有客服能看到的
  一列账号名摊开）、不回 `phone` / `email` / 钱包 / 订单信息（与 `GET /worker/cs/conversations` 的既有口径一致）。
- **字段 `userNickname` 是"发起方"**：老板端发起的是老板；**打手态账号「联系客服」**发起的会话
  `user_id` 是打手账号（见 docs/03「4 缺口收尾」缺口 4），同样进池、同样能被接入。
- **空会话不进池**（2026-10-08 晚修正，旧稿"空会话也进池"作废）：老板打开客服页即建会话，
  但**发第一条消息**才进池 —— 大厅里不会再有 `（暂无消息）` 的条目
  （`（暂无消息）` 这个占位值保留为防御，见 `cs-hall.ts#CS_HALL_PREVIEW_NONE`）。
  图片消息**也算"有消息"** → 同样进池，摘要给 `【图片】`。
- **不泄露敏感字段**：只回 `nickname` + `uid`。**不回** `username`（登录名，回了等于把所有客服能看到的
  一列账号名摊开）、不回 `phone` / `email` / 钱包 / 订单信息（与 `GET /worker/cs/conversations` 的既有口径一致）。
- **字段 `userNickname` 是"发起方"**：老板端发起的是老板；**打手态账号「联系客服」**发起的会话
  `user_id` 是打手账号（见 docs/03「4 缺口收尾」缺口 4），同样进池、同样能被接入。

### 为什么 `claim` / `release` 是 **HTTP 200** 而不是 POST 默认的 201

两者都是**幂等的"状态变更"**，不创建任何面向客户端的资源：重复 `claim` 回 `alreadyClaimed: true`、
重复 `release` 回 `alreadyReleased: true`，**都返回 200**。与既有口径一致：
`POST /user/conversations/:id/read`（幂等标记已读）是 200，`/auth/login`、`/user/identity/bind|unbind`
同属"非创建型 POST"。**客户端按 2xx 处理即可**（Dio 默认 `validateStatus` 收 200–299）。

### 错误码表（**中文原文**）

| 场景 | 状态码 | 文案 |
|---|---|---|
| 无客服权限 / 档案停用（hall、claim、release 都查） | 403 | `无客服权限` |
| `release` 而开关为 0 | 403 | `客服退回功能未开放` |
| 会话不存在 **或存在但不是客服会话** | 404 | `会话不存在` |
| 会话已结束（`status<>'open'`） | 400 | `该咨询已结束，无法接入` |
| 会话已结束（release 路径） | 400 | `该咨询已结束，无需退回` |
| **已被别人接走（并发抢占失败）** | **409** | `该咨询已被其他客服接入` |
| **管理端改派与大厅 claim 撞车（`admin/chat/…/assign`，2026-10-08 晚补）** | **409** | `该咨询已被其他客服接入` |
| release 但自己不是接入客服（也没退回过） | 400 | `你不是该咨询的接入客服，无法退回` |

**"不存在"与"不是客服会话"合并为同一条 404** 是刻意的（安全审计 F3 的既有教训）：不向客服泄漏
平台上还存在哪些别的类型的会话。管理端 `POST /admin/chat/conversations/:id/assign` 的
`会话不存在` / `仅客服会话可指派客服` 两条文案**一个字未改**；2026-10-08 晚只新增了上表那条
**409**（并发撞车），把原来的 `500 服务器内部错误` 换成了明确的中文冲突语义 —— 见下节。

### 与既有管理端改派（`assignCs`）的关系：**兜底 + 主路径**，同一张表、同一份判据

| | 管理端改派 | 客服大厅主动接入 |
|---|---|---|
| 入口 | `POST /admin/chat/conversations/:id/assign`（`admin:chat:assign`） | `POST /worker/cs/hall/:id/claim` |
| 语义 | **无条件**改派（抢占式之外的兜底：没人接、接错人、要换人） | **抢占式**，已有人接则 409 |
| 并发 | **同一把会话行锁**（2026-10-08 晚补）；与 claim 撞车时落败一方 **409 中文** | 同一把会话行锁；条件写判 `affectedRows` |
| `assigned_by` | 管理员 user id | **接入者自己的 user id**（= 自主接入） |
| 留痕 | `operation_log(module='chat', action='chat:assign')` | `operation_log(module='chat', action='chat:claim' / 'chat:release')` |
| 原客服 | 收到 `chat:unassigned`（既有行为） | 收到 `chat:unassigned`（release 时通知本人） |

**`operation_log.admin_id` 存的是操作者**：管理端路径存管理员，大厅路径存**打手（客服）**的 user id ——
该列自 2026-10-06 起允许为 NULL，这里刻意存操作者，否则"谁接的"就丢了。三种动作落在同一张表、
同一套字段，**一个会话的接入史（改派 / 自主接入 / 退回）永远能在一处回看**。
幂等重复调用**不改库、也不留痕**（只有真正写入的那次才有审计行）。

### 并发安全（与"抢单"同一铁律，但锁的位置不同）

`chat_conversation_assign` 原本**没有**"同一会话只能一行 active"的数据库约束，因此做了两层：

1. **服务层**：事务内 `SELECT … FOR UPDATE` **锁会话行**（与 `sendMessage` 抢的是同一张表的同一行）
   → 锁内复核「仍 `cs` + `open` + 无 active 指派」→ **条件写 `INSERT` 判 `affectedRows === 1`**
   → 0 行/冲突一律 **409 中文，绝不静默成功**；
2. **数据库层**：生成列 `active_conversation_id`（仅 `active` 行非 NULL）+ 唯一键 `UK_cca_active`
   （migration `1807000000000`）→ 即使有写入路径绕过行锁（管理端改派、运维 SQL、将来的新接口）
   也插不进第二行，`ER_DUP_ENTRY` 同样映射为 **409 中文**（而不是 500）。

**禁 Redis 锁双源**：全程只用数据库（行锁 + 条件写 affectedRows + 唯一键），没有第二把锁、没有缓存判据。
生成列**不在实体里映射**（与 `worker_identity_binding` 逐字同口径）→ 任何 `save()` 都不会碰到它。

> **⚠️ 管理端改派也进同一把锁（2026-10-08 晚补）**：`ChatService.assignConversation` 原先**不加行锁** ——
> 它读到的"没有 active 行"若在读完之后被大厅 claim 插了一行，那次 `INSERT` 就撞唯一键
> → `ER_DUP_ENTRY` 未捕获 → 前端看到 **500 服务器内部错误**（旧行为更糟：两行 active 数据损坏）。
> 现在它与 claim / sendMessage **抢同一张表的同一行、同一写法**：
> ①请求开始先观测一次 active 指派（= 管理员点"改派"时看到的状态）；②事务内 `SELECT … FOR UPDATE` 锁会话行；
> ③锁内用 **`FOR UPDATE` 读**复核（拿最新已提交版本，不吃本事务快照）：**"我观测时没人接、此刻已经有人接"**
> → **中文 409**；④复核通过才在同一事务内"原 active 置 inactive + 插新 active"；唯一键冲突再兜一层 → 同样 409；
> ⑤广播（原客服 `chat:unassigned` + 新客服 `chat:assigned`）移到**事务提交之后**。
> **强制改派语义一字未改**（已有人接时照旧可直接换人；409 只针对"从无到有"这一种并发变化）。

### 统计字段 `onlineCsCount` 的口径（**沿用既有在线机制，无第二套**）

`当前有客服权限且在线` = `worker.status=1 AND worker.can_serve_customer=1`（实时查库）
∩ `RealtimeGateway.isOnline(userId)`（`/ws/chat` 命名空间里 `uid:{userId}` 房间有连接）。

- **没有**新造心跳表、**没有**"近 N 分钟活跃"这类新口径：项目里唯一的"在线"就是"此刻 WS 连着"
  （好友在线状态、分部在线数用的都是同一个方法）；`pingInterval 25s / pingTimeout 20s`
  负责摘掉死连接 → 最坏滞后约 45s，与好友在线状态精度一致。
- 打手规模下一次遍历只是内存 Map 查询，故**每次 hall 请求实时算**，不缓存。

### 自证脚本

`node scripts/tools/cs-hall-e2e.js` —— 自建自清（**跑前**先清掉两个测试老板的 `type='cs'` 会话/消息/指派
并断言清零，**跑后**再清一次并把 `worker_test2` 的客服权限与 release 开关还原到夹具基线）：
**81 pass / 0 fail（连跑两次均全绿）**，覆盖
①权限（无客服权限 403 中文）②池子口径（**空会话不进池** / 发首条后进池 / 摘要 = 服务端口径 /
图片占位 / 条数与库里对齐 / 等待时长 / 排序 / 敏感字段 / 已指派不出现）
③**并发抢占**（两个客服同时 claim → 恰好一个成功、另一个 409 中文、库里 active **恰好 1 行**，附 SQL 证据）
④幂等 ⑤release（含开关 0/1）⑥管理端改派回归 ⑦WS 事件（含"无客服权限的在线打手与老板端都收不到 `cs:new`"的受众过滤）
⑧**打手态（companion）真机路径**：老板绑定打手账号 → companion 令牌 → `GET /worker/cs/hall` **200** →
`claim` **200**（打手态确实能主动接，不只是能看列表）→ companion 打老板侧接口仍 **403**（受限会话边界没被新接口带松）
→ 解绑后 companion 打 hall **401 中文**；
⑨**并发：大厅 claim ↔ 管理端 assign**（⑨-1 用一条独立 MySQL 事务在该会话的指派区间上持 gap lock，
把两个请求**确定性地**卡在同一窗口里；⑨-2 再跑一轮"裸并发"）——
断言"先到者 claim 200、后到的管理端中文 409、库里 active 恰好 1 行"（附 SQL 证据）。

**变异验证（2026-10-08 晚实测，红/绿都留痕）**：

| 变异 | 结果 |
|---|---|
| 把 `CS_POOL_SQL` 的消息条件去掉 | **77 pass / 3 fail** —— ①-d、①-e、⑦-a2 三条"空会话不进池"用例立刻变红 |
| 把 `assignConversation` 的会话行锁去掉（保留锁内复核） | **79 pass / 2 fail** —— ⑨-a/⑨-d 变红：管理端不再排队，用过期状态抢在 claim 前面落库（201 而不是 409） |
| 把 `assignConversation` 退回修复前实现（无事务 / 无行锁 / 复核用普通读 / 无 dup 兜底） | **78 pass / 3 fail** —— ⑨-a/⑨-b/⑨-e 变红，复现的正是本次要修的 **`500 服务器内部错误`** |

**为什么"只去掉行锁"红在⑨-a 而不是 500**：修复后的锁内复核本身是 `FOR UPDATE` 读，它会持有该区间上的
gap lock；InnoDB 的插入意向锁与本事务自己的 gap lock 不冲突 → 变异体反而"抢赢"了 claim。
这是实测结论（`scripts/tmp` 曾用两连接探针逐毫秒验证过锁队列顺序），**不是猜的** ——
所以"去掉行锁"的变异特征是**顺序被抢**（⑨-a 红），而 500 出现在**连复核也不加锁**的旧实现里。

## 2026-10-09 计价单位变更（积分 → 余额，1:1）登记

**API 字段名一律不改**（`points` / `price` / `balance` / `totalAmount` 等契约不变），
本批只变**数值口径**与**单位文案**。下游（管理端 / 客户端）为后续批次。

### 一、响应里数值口径变化的接口

| 接口 | 字段 | 变化 |
|---|---|---|
| `GET /public/products`、`GET /public/products/:id` | `price` | 88.00 → **8.80**（÷10） |
| `GET /user/wallet`、`GET /worker/wallet` | `balance` | ÷10（且改为由流水重算，见 docs/06 第四节） |
| `GET /user/wallet/transactions`、`GET /admin/wallet/transactions` | `amount` / `balanceBefore` / `balanceAfter` | ÷10 |
| `GET /user/orders`、`/user/orders/:id`、`/worker/orders*`、`/admin/orders*` | `unitPrice` / `totalAmount` | ÷10 |
| 结算/榜单/统计族 | `orderAmount` / `workerAmount` / `platformAmount` / `totalAmount` / `totalSpent` | ÷10 |
| `GET /user/level/rules`、`/public/level-rules` | `rules[].minSpent` | 500/2000/10000/50000 → **50/200/1000/5000** |
| `GET /public/recharge/config` | `pointsPerYuan` | **10 → 1** |
| `GET /public/recharge/config` | `noticeText` | 去「1 元 = 10 积分」，改「按付款金额 1:1 到账余额」+ 保留「不可提现/不可转让/平台不经手资金」 |
| `GET /public/purchase-hint` | `text` | 改「下单均使用余额（元），余额仅可用于平台内消费、不可提现；如需充值请联系小云」 |
| `GET /public/products/:id`（`effectiveOrderNotice`）、订单须知族 | 默认须知文案 | 「扣积分 / 退回积分」→「扣余额 / 退回余额」 |
| `GET /user/tip/config`（打赏配置） | `presets` / `maxPerTip` / `maxPerOrder` | `[0.6,1.8,3.8,8.8]` / 50 / 100（元） |
| `GET /user/ai/*`（祁小山） | 开场白 / 快捷问题 | 「积分」→「余额」 |

### 二、字段类型变化（影响 `recharge_request` 与 `order_tip`）

- `recharge_request.points`：`int` → **`decimal(12,2)`**（1:1 后允许「分」，否则 6.5 元被截断成 6）；
- `order_tip.amount`：`int` → **`decimal(12,2)`**（打赏预设折算后含 0.6/1.8/3.8/8.8）。
- `POST /user/recharge/requests`：请求体 `amountYuan` 语义不变（仍是元），
  但**响应 `points` 现在保留 2 位小数**（如 `6.5`）；超过 2 位小数 → 中文 400「充值金额最多保留 2 位小数」；
  换算后 ≤0 → 中文 400。
- `POST /user/tips`（打赏）：请求体 `amount` 由「正整数」放宽为「>0 且最多 2 位小数」；
  超 2 位 → 中文 400「打赏金额最多保留 2 位小数」。

### 三、中文错误文案（单位口径）

| 旧 | 新 |
|---|---|
| 积分余额不足 | **余额不足** |
| 积分余额不足，无法打赏 | **余额不足，无法打赏** |
| 打赏积分为正整数 | **打赏金额必须大于 0** / **打赏金额最多保留 2 位小数** |
| 单次打赏不能超过 {N} 积分 | **单次打赏不能超过 {N} 元** |
| 该订单累计打赏上限 {N} 积分 | **该订单累计打赏上限 {N} 元** |
| 金额过小，换算后积分为 0，请提高金额或联系管理员 | **换算后到账金额为 0，请提高充值金额或联系管理员** |
| 积分流水写入失败，请重试 | **余额流水写入失败，请重试** |
| 1 元对应积分必须是 1–1000 的整数 | **1 元到账比例必须是 1–1000 的整数** |
| 订单 {no} 退款申请已通过，{N} 积分已原路退回 | **订单 {no} 退款申请已通过，{N} 元已原路退回** |
| 充值申请已到账：+{N} 积分 | **充值申请已到账：+{N} 元**（保留 2 位小数，如 `+68.00 元`） |
| 老板打赏你 {N} 积分（订单 {no}） | **老板打赏你 {N} 元（订单 {no}）** |

### 四、RBAC 权限名/分组（管理端「角色」页展示值）

- `admin:wallet:read`：**积分查看 → 余额查看**（分组 `积分` → `余额`）
- `admin:wallet:grant`：**积分发放与回收 → 余额发放与回收**（同上）

> 权限**编码**（`admin:wallet:*`）刻意不改 —— 改名会同时打断服务端守卫、迁移与已发放的角色数据。

---

## 补充（2026-10-10）：**邮箱绑定/换绑 + 邮箱验证码登录 + QQ 登录（服务端）**

> 交付范围：服务端全部完成；**客户端（`apps/**`）与 QQ APP ID/Key 由后续批次跟进**。
> 本次**没有新增第三方依赖**（QQ 走 Node 内置 `fetch` + `AbortController`，不引腾讯 SDK）。
> 涉及文件：`modules/auth/{auth.controller,auth.service,email-binding.service,user-email.controller,qq-oauth.client,user-oauth.entity,email-code.service,dto/auth.dto}.ts`、
> `migrations/1809000000000-user-oauth.ts`、`scripts/tools/email-auth-e2e.js`。

### 一、接口清单

| 方法 | 路径 | 会话/角色 | 入参 | 说明 |
|---|---|---|---|---|
| POST | `/auth/email/code` | 公开 | `email`、`scene`（**register / reset / bind / login**） | 发邮箱验证码。限流三档不变（同邮箱 60s / 同邮箱 5 次·小时 / 同 IP 10 次·小时）。响应**永不回显验证码** |
| POST | `/user/email/bind` | 需登录，`role ∈ {user, worker}`（primary） | `email`、`emailCode`、`password` | **绑定与换绑同一接口**；换绑 = 覆盖；校验顺序 格式 → 当前密码 → 邮箱唯一 → 验证码 |
| GET | `/user/email` | 需登录，`role ∈ {user, worker}` | — | 当前账号邮箱状态：`{ bound, email(脱敏), verified, verifiedAt }`。**不下发完整邮箱** |
| POST | `/auth/login` | 公开 | 旧：`username`+`password`+`role`；新：**`email`+`emailCode`+`role`** | 传了 `email` 即走**邮箱验证码登录**（忽略 `username/password`）；旧路径逐字节兼容 |
| POST | `/auth/qq/login` | 公开 | `accessToken`（别名 `access_token`）、`openid`（仅比对） | 服务端用 `access_token` 调腾讯复核 openid：已绑定→登录该账号；未绑定→**建新老板账号** |
| POST | `/auth/qq/bind` | 需登录，`role = user` | 同上 | 把 QQ 绑到**当前账号**（主体只取 JWT `sub`）；重复绑自己幂等成功 |

**字段别名（QQ）**：`accessToken` 是仓库既有驼峰口径；腾讯文档里的 `access_token` **一并接受**（两者都给时以 `accessToken` 为准）——
这样未来的客户端按腾讯文档原样传参不会被 `forbidNonWhitelisted` 判 400。

**响应形态**：全部沿用统一信封 `{ code, message, data, requestId, timestamp }`（成功 `code=0`）。
- `/auth/login` 与 `/auth/qq/login` 的 `data` 都是令牌对 `{ accessToken, refreshToken, expiresIn }`；
  QQ 登录**额外**带 `isNewUser`（本次是否新建账号）与 `user` 摘要 `{ id, username, uid, nickname }`（纯增量字段，旧客户端可忽略）。
- `/user/email/bind` 的 `data`：`{ ok, email(脱敏), emailVerified, rebound, message }`（换绑时 `rebound=true`）。
- `/user/email` 的 `data`：`{ bound, email(脱敏｜null), verified, verifiedAt }`。
- `/auth/qq/bind` 的 `data`：`{ ok, bound, alreadyBound, openid(脱敏), message }`。

### 二、中文错误码表（**原文，客户端直接展示**）

| 场景 | HTTP | 中文原文 |
|---|---|---|
| 邮箱格式非法（`email`） | 400 | `格式不正确`（字段级；管道拼成「邮箱 格式不正确」） |
| 验证码格式非法（`emailCode`） | 400 | `须为 6 位数字`（字段级） |
| 绑定邮箱：当前密码错 | 400 | **密码错误** |
| 绑定邮箱：邮箱已被别的账号占用 | **409** | **该邮箱已被其他账号绑定** |
| 绑定邮箱：验证码错 | 400 | **验证码错误** |
| 绑定邮箱：验证码不存在/过期 | 400 | **验证码已过期，请重新获取** |
| 绑定邮箱：验证码错满 5 次作废 | 400 | **验证码错误次数过多，请重新获取** |
| 绑定邮箱：邮箱字段为空 | 400 | 邮箱格式不正确 |
| 邮箱码登录：**未绑定 / 码不对 / 码过期 / 错满作废**（四种情况**同一句话**） | 400 | **邮箱或验证码错误** |
| 邮箱码登录：`role` 与账号实际角色不符 | 403 | 账号角色不符 |
| 邮箱码登录：账号被封禁 | 403 | 您的账号已被封禁，结束时间：… / 您的账号已被永久封禁（附 `errorCode=ACCOUNT_BANNED`） |
| 邮箱码登录：被新登录顶掉（单设备） | 401 | 账号已在其他设备登录 |
| 密码登录：账号不存在/密码错 | 401 | 账号或密码错误（**逐字未变**） |
| 取码：邮箱已被注册（`scene=register`） | 400 | 该邮箱已被注册，请直接登录或使用找回密码（**逐字未变**） |
| 取码：同邮箱 60s 内重发 | 429 | 请求过于频繁，请 N 秒后再试 |
| 取码：同邮箱超 5 次·小时 | 429 | 该邮箱今日获取验证码次数过多，请 1 小时后再试 |
| 取码：同 IP 超 10 次·小时 | 429 | 当前网络获取验证码次数过多，请 1 小时后再试 |
| 取码/发信：SMTP 失败 | 400 | 邮件发送失败，请稍后重试 |
| 未登录 / 令牌失效 | 401 | 未登录 ／ 登录已失效，请重新登录 |
| 角色不允许（如 admin 调 `/user/email/*`） | 403 | 无权限访问 |
| **QQ 登录未配置**（`QQ_APP_ID`/`QQ_APP_KEY` 缺任一） | **503** | **QQ 登录未配置** |
| QQ 凭证无效/过期、别家应用 token（`client_id` 不匹配）、返回体无法解析 | 400 | QQ 授权已失效，请重新授权后登录 |
| QQ 上游超时（10s）/ 网络失败 | 503 | QQ 登录服务暂时不可用，请稍后重试 |
| QQ 入参缺 `accessToken` | 400 | 缺少 QQ 授权凭证 |
| QQ 入参 `openid` ≠ 服务端复核结果 | **403** | **QQ 授权校验失败：openid 与服务端复核结果不一致** |
| QQ 已绑到别的账号 | **409** | **该 QQ 已被其他账号绑定** |
| QQ 命中的账号不是老板账号（`role≠user`） | 403 | 该 QQ 未绑定老板账号 |
| 登录/绑定 QQ 触发限流（5 次/分/IP） | **429** | 登录尝试过于频繁，请稍后再试 |

> **⚠️ 限流 = 429，越权 = 403（2026-10-13 统一，别混）**
>
> 本节此前**自相矛盾**：第 35 行的状态码总表已写「**429 = 触发限流**」，而本行原先把 QQ 登录限流
> 写成 **403**。现已统一为 **429**，与同平台其余限流点（邮箱取码 `email-code.service.ts`、
> 打手绑定 `worker-identity.service.ts`、充值管理员绑定 `recharge.service.ts`）**同一语义**。
>
> 服务端改动只有两处：`auth.service.ts` 的 `login()`（密码/邮箱码登录限流）与 `loginByQq()`。
> **同一文件里另有两处语义完全不同的 403 必须保持 403**：`login()` 与 `loginByEmailCode()` 里的
> `账号角色不符`（上表第 806 行）—— 那是**越权判定**，改成 429 会让客户端把它当"稍后重试"。
> 两者**只靠中文文案区分**：「登录尝试过于频繁，请稍后再试」= 429 限流／「账号角色不符」= 403 越权。
> 回归断言同时覆盖两条（`scripts/tmp/security-test.js` 第 7 与 7b 条），防止将来再被混改。

### 三、审计与脱敏口径（与「邮箱注册 / 找回密码」**同表同字段**）

- `operation_log`：`module='auth'`，`action ∈ {email_bind, email_rebind, login_by_email_code, login_by_qq, qq_bind}`，
  `request_body` 只记 **`userId` + 脱敏邮箱（新旧对比）/ 脱敏 openid + `via`**；
  `via` 取值：`password+email_code`（绑定）/ `email_code`（邮箱码登录）/ `qq`（QQ 登录与绑定）。
- `login_log`：`user_type='user'`；成功时 `fail_reason` 写明动作（`邮箱绑定（ab***@x.com）`、
  `邮箱换绑（旧 → 新）`、`邮箱验证码登录（via=email_code）`、`QQ 登录（via=qq）`、`QQ 绑定（via=qq）`），
  失败时写具体原因（如 `绑定邮箱失败：密码错误`）。
- **明文验证码、明文密码、`QQ_APP_KEY`、完整 `access_token` 一律不落任何一张表、不进日志**（e2e 有逐码扫描断言）。
- ⚠️ `login_log.username` 只有 **varchar(32)**：邮箱路径往这一列写的是邮箱（最长 120），
  因此 `AuthService.writeLoginLog` **统一按 32 位截断**（与同行 `ip`/`userAgent` 的 slice 同一写法）。
  2026-10-10 实测：修复前一个 35 字符的邮箱会把 INSERT 撑爆 → **登录接口 500**（该缺陷同时存在于既有的找回密码路径）。

### 四、与既有约定的关系

- **场景枚举只增不改**：`EmailScene = 'register' | 'reset' | 'bind' | 'login'`，Redis 键含 scene
  （`email:code:{scene}:{email}`）→ **注册与找回的键名、文案、行为逐字未变**。
- **`POST /auth/login` 的旧路径逐字节兼容**：DTO 用 `@ValidateIf((o) => !o.email)`，
  未传 `email` 时 `username/password` 的必填与长度校验**照旧生效**；传了 `email` 才走新分支。
- **限流键空间不交叉**：老路径 `login:{ip}:{username}`（逐字未变）；邮箱路径 `login:{ip}:{email}`；
  QQ 登录 `login:{ip}:qq`；QQ 绑定 `qqbind:{ip}`。username 的字符集 `[a-zA-Z0-9_]` 不可能等于含 `@` 的邮箱。
- **一个邮箱只能绑一个账号**：服务层先查后写 + **数据库 `UQ_user_email` 唯一索引兜底**
  （并发撞键 → 中文 409，不是 500）；一条实测证据见 e2e 的「DB 权威约束」用例。
- **`user_oauth`**：唯一键 `UK_user_oauth_provider_openid(provider, openid)` + 索引 `IDX_user_oauth_user_id(user_id)`；
  `provider` 预留 `wechat`；`unionid` 只存不判。表结构见 docs/02 对应迁移 `1809000000000`。
- **不做**：解绑邮箱（邮箱已是登录凭据，本轮不开放）；QQ 头像落库（本站头像是 media 体系，无外链头像列，
  仅随 `get_user_info` 返回值带出不入库）。

## 评价体系 + 记住游戏 ID（2026-10-15，负责人定案）

> **语义**：竞品（东东电竞 4.6.0）用**二值评价**（满意/不满意）+ **接单次数/好评率**展示，
> **差评转售后**而不是留在页面上。我们采用它的**信息架构**（`docs/38` 的边界：只学结构，**不用它的文案与视觉**）：
> - 打手卡与打手公开信息只显示 **接单次数 + 好评率**（竞品原文 `string/home_skill_order_desc = "接单%1$s次  好评率%2$s"`）；
> - 评价只有 **满意 / 不满意** 两种；不满意 → `needAfterSale=true`，客户端引导走
>   **既有的** `POST /user/orders/:id/appeal`（唯一售后入口）；
> - **一单一评**（表级唯一约束），**只有 `completed` 可评**。
>
> 数据模型见 docs/02；权限点与会话见 docs/04；订单状态机见 docs/05（**本次未改状态机一个字**）。

### A. 评价接口（3 个）

| 方法 | 路径 | 会话/角色 | 说明 |
|---|---|---|---|
| POST | `/user/orders/:id/review` | primary `role=user` | body `{satisfied: boolean, remark?: string(≤200)}` → `{ok:true, needAfterSale:boolean}` |
| GET | `/user/orders/:id/review` | primary `role=user` | → `{satisfied, remark, createdAt}`；**未评价返回 `null`**（不是 404，客户端据此回显"已评价"） |
| GET | `/public/workers/:id` | **公开（无需登录）** | 打手公开信息（见 C） |
| GET | `/public/workers/:id/reviews` | **公开（无需登录）** | 评价分页（见 C） |

**提交评价的口径（逐条）**
- `satisfied` 只认真布尔（DTO 层把 `"true"/"false"/"1"/"0"` 归一后再校验，其余 400）——
  ⚠️ 刻意**不让全局隐式转换**碰它：`Boolean("false") === true`，若交给框架隐式转，
  **一条差评会被静默记成好评**（好评率虚高 + 售后提示不出现）；
- `remark` 可选：`strip()` 后**空串按未填处理 = NULL**（库里不出现 `''` 与 `NULL` 两种"空"）；
- 订单**必须属于本人**（`user_id` 只取 JWT sub）且 `status='completed'`，否则 400 中文；
- **一单一评**，重复提交 400「该订单已评价」；
- 成功后给**打手**写一条 `user_notification`（复用既有通道 + `notification:new`）：
  「收到一条好评」/「收到一条差评，平台客服会跟进」（**best-effort**：通知失败只告警，评价已落库不回滚）；
- 响应 `needAfterSale = !satisfied`；**服务端不改订单状态、不落售后单**（差评 = 引导走既有申诉，不做第二条售后链路）。

### B. 管理端评价治理（3 个，全部要 **窄权限点 `review:moderate`**）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/admin/reviews?page=&pageSize=&satisfied=&hidden=&workerId=` | 列表（含 `hidden` 状态）→ `{list:[{id,orderId,orderNo,workerNickname,userName,satisfied,remark,hidden,hiddenReason,createdAt}], total, page, pageSize}` |
| POST | `/admin/reviews/:id/hide` | body `{reason}`（必填 1–200 字）→ **条件 UPDATE `WHERE id=? AND hidden=0` 判 affectedRows** |
| POST | `/admin/reviews/:id/show` | 恢复可见（`WHERE id=? AND hidden=1`），同时**清空 `hidden_reason`** |

- 筛选值**严格校验**（`satisfied`/`hidden` 只认 0/1，其余 400 中文）：筛选条件被静默忽略比报错更危险；
- **每个写接口都写 `operation_log`**（docs/03 铁律）：`module='review'`、
  `action='review:hide' | 'review:show'`，`request_body` 只记
  `{reviewId, orderId, workerId, hiddenBefore, hiddenAfter, reason(或 reasonBefore)}`
  —— **不记评价原文**、不记 token/超长原文；重复调用（affected=0）**中文 400 且不重复留痕**；
- `reason` 只在"隐藏"时必填；**恢复时的历史原因已被清空**，所以把它作为 `reasonBefore` 记进审计
  （`hidden_reason` 列的语义是"**当前的**隐藏原因"，历史原因的唯一出处是 `operation_log`）。

### C. 打手公开信息（**无需登录**）

`GET /public/workers/:id` →
```json
{ "id":"12", "nickname":"阿远", "intro":"只打手游，不接急单", "avatarMediaId":"88",
  "completedOrders": 128,          // worker_stats.completed_orders（与榜单同源）
  "reviewCount": 57,               // 只算 hidden=0
  "satisfiedRate": "98.2",         // 字符串保留 1 位小数；**无评价时 null**（前端显示「暂无评价」）
  "reviews": [ {"satisfied":true,"remark":"稳","createdAt":"…","nicknameMasked":"李**"} ]   // 最近 20 条
}
```
`GET /public/workers/:id/reviews?page=&pageSize=`（`pageSize ≤ 50`）→ `{list, total, page, pageSize}`

**契约要点（不可放宽）**
- **只下发 `hidden=0`** 的评价；
- **脱敏口径（docs/09）**：评价人只给 `nicknameMasked`（**首字 + `**`**，如「李**」）——
  手机号 / `uid` / 真实用户名 / `user.id` **一个字段都不出现**；昵称为空回「匿名用户」，
  **绝不用 `uid` 兜底**（`uid` 可被搜索关联到本人）；
- **`satisfiedRate` 无评价时为 `null`**：不给新打手编一个 `100.0`（误导老板），也不回 `0.0`（读起来像全差评）；
- **实时算、不缓存**：好评率/条数每次现算（`COUNT/SUM … WHERE worker_id=? AND hidden=0`，
  冗余列 = 第二条真相）。因此 `/api/v1/public/workers*` 在 `PublicCacheInterceptor` 里
  **显式登记 `no-store`**、不进进程内微缓存（与 `/public/players` 同档，理由同类）；
- 打手**不存在 / 档案停用（`worker.status≠1`）/ 账号封禁（`user.status≠1`）→ 404 中文「打手不存在或已停用」**
  （三者在对外表现上**一致**，不泄漏"存在但停用"；非数字 id 同样 404，不区分 400）。

### D. 记住游戏 ID（2 个 + 下单自动 upsert）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/user/game-accounts` | → `[{gameId, gameName, gamePlayerId, gameZone, updatedAt}]`（按最近使用倒序） |
| POST | `/user/game-accounts` | body `{gameId, gamePlayerId, gameZone?}` → upsert（`UNIQUE(user_id, game_id)`） |

> **⚠️ 客户端不需要调 POST 来"保存"**：**下单成功时服务端已经自动 upsert 一条**
> （`OrderService.createOrder` → `rememberGameAccountBestEffort`，取值就是订单本身的
> `gameId/gamePlayerId/gameZone`）。客户端只需在**进下单页时调一次 GET 做回填**。
> POST 保留给"想提前存号 / 想改号"的场景。

**失败隔离（这是本条的硬要求）**：自动 upsert 在**下单事务提交之后**执行
（不是事务内 —— 结构上排除"连带回滚已提交订单"的可能），内部再包 try/catch + `logger.warn`；
唯一键 + `ON DUPLICATE KEY UPDATE` 保证重复执行不产生第二行（幂等自愈）。
→ **下单主链路的成功率一个字未变**。

**校验**：`gamePlayerId` 与下单页**同一正则/同一长度**（`^[A-Za-z0-9一-龥_-]+$`，1–64），
`gameZone` ≤32；`gameId` 必须存在于 `game` 表（手工保存时校验；下单自动写入跳过该查询 ——
值刚从订单来）；`user_id` **只取 JWT sub**。打手态（companion）默认被守卫挡掉（`/user/*` 不在其允许清单）。

### E. 中文错误码表（**原文，客户端直接展示**）

| HTTP | 中文原文 | 场景 |
|---|---|---|
| 400 | 订单完成后才能评价 | 订单状态 ≠ `completed`（含未接单/已取消/售后中） |
| 400 | **该订单已评价** | 一单一评（事务内查重命中，或并发撞 `UK_review_order`） |
| 400 | 评价内容最多 200 字 | `remark` 超长 |
| 400 | 请选择满意或不满意 | `satisfied` 缺失或不是布尔 |
| 404 | 订单不存在或不属于你 | 订单不存在 / 不是本人的（**不区分**，防枚举） |
| 400 | 请填写隐藏原因 / 隐藏原因最多 200 字 / 隐藏原因需为 1-200 字 | 管理端隐藏原因校验（服务层与 DTO 两道） |
| 400 | 该评价已隐藏 / 该评价未被隐藏 | 条件 UPDATE `affectedRows=0`（重复点按/状态不符） |
| 400 | 筛选值不合法（satisfied 只能是 0 或 1）/（hidden 只能是 0 或 1）/ 打手参数不合法 | 管理端列表筛选项非法（**不静默忽略**） |
| 404 | 评价不存在 | 管理端目标评价不存在 |
| 404 | 打手不存在或已停用 | 公开接口：不存在 / 档案停用 / 账号封禁（**同一句**） |
| 403 | 无权限 | 缺 `review:moderate`（`PermissionsGuard` 实时查库） |
| 400 | 请填写游戏 ID / 游戏 ID 最多 64 个字符 / 游戏ID仅支持字母/数字/中文/下划线/短横线 | 保存游戏账号校验（与下单页同一份正则） |
| 400 | 游戏参数不合法 / 游戏不存在 | `gameId` 非数字 / `game` 表里没有 |
| 400 | 游戏分区最多 32 个字符 | `gameZone` 超长 |

### F. 「一单一评」的三层保证（照 CLAUDE.md 充值与提现那套姿势）

| # | 手段 | 落点 |
|---|---|---|
| ① | **事务 + `SELECT … FOR UPDATE` 锁订单行** | `ReviewService.submit()`：锁住这一单 → 同单并发评价在此排队 → 事务内查重 → 已存在中文 400 |
| ② | **表级唯一约束** | `UK_review_order (order_id)`：绕过 ① 的并发（多实例）第二个 INSERT 撞 `ER_DUP_ENTRY` → **翻译成同一句中文 400**（不是 500） |
| ③ | **条件 UPDATE 判 `affectedRows`** | 隐藏/恢复：`WHERE id=? AND hidden=<旧值>` —— **"能否隐藏/恢复"的唯一判定点**（刻意不写成"先读状态再 UPDATE"） |
| 兜底 | 同一句文案 | ①与②**共用** `REVIEW_DUPLICATE_MESSAGE`，用户看到的现象恒等（重试永远不会变成"成功两次"） |

