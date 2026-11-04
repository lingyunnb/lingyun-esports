# 07 - WebSocket 协议规范（/ws/chat，Socket.IO）

## 连接与认证

- 握手 auth 携带 JWT：`io('/ws/chat', { auth: { token } })`；服务端 handleConnection 校验 token，失败立即断开并记登录审计
- 内存维护 `Map<主体id, Set<socketId>>`（单实例够用，预留 Redis adapter 扩展位）；同账号多设备各自连接
- 心跳：客户端每 25s 发 `ping`，服务端回 `pong`；60s 无任何帧则服务端断开
- 发送限流：20 条/分/主体（Redis 计数）

## 会话房间与归属校验（join 前服务端强制校验）

- 房间名 `conv:{conversationId}`
- user：`conversation.user_id == uid`（uid 取自 JWT sub）
- worker：实时查库 `can_serve_customer=1` 且 chat_conversation_assign 存在 active 授权
- 越权 join 拒绝并审计；管理员改派后原客服被服务端强制 leave 并推送提示

## 消息帧（JSON envelope）

| 事件 | 方向 | data | 说明 |
|---|---|---|---|
| msg:send | C→S | {conversationId, clientMsgId, msgType, content} | 图片消息 content=已上传 mediaId |
| msg:ack | S→C | {clientMsgId, msgId, seq, createdAt} | 发送成功回执 |
| msg:new | S→C | {msgId, seq, senderType, senderId, msgType, content, createdAt} | 推给会话其他成员 |
| msg:read | C→S | {conversationId, lastSeq} | 标记已读 |
| msg:read | S→C | {conversationId, readerUserId, readerType, lastSeq} | **对端已读位点**推给会话内另一方（2026-10-04：单勾=已送达 / 双勾=已读；客户端按 readerUserId 过滤自己触发的回执） |
| msg:read:ack | S→C | {conversationId, lastSeq, readerType, readerId} | 已读回执给发送方（兼容保留） |
| msg:recall | C→S | {msgId} | 撤回（校验发送者本人+窗口） |
| msg:recalled | S→C | {msgId} | 撤回广播 |
| unread:update | S→C | {conversationId, unread} | 未读数变化 |
| unread:snapshot | S→C | [{conversationId, unread}] | 连接建立时全量未读 |
| sync | C→S | {conversationId, lastSeq} | 重连后增量对齐 |
| ping / pong | 双向 | {} | 心跳 |
| dispatch:new / dispatch:canceled / dispatch:expired | S→C | {orderId, summary, expireAt?} | 派单通知，仅推给目标 worker |

## 去重与顺序

- `msg_id`：服务端生成全局唯一（防重复）
- `seq`：会话内递增序号，服务端**事务内分配**（会话行锁串行化），保证顺序
- 客户端重试带同一 clientMsgId → 服务端唯一冲突时幂等重发原 ACK，不重复落库
- 客户端按 seq 渲染；乱序到达先入缓冲排序；seq 小于已见最大且 msg_id 已存在则丢弃

## 断线重连

- Socket.IO 指数退避自动重连；重连成功后：客户端发 `sync`（或走 HTTP `GET /conversations/:id/messages?afterSeq=` 增量补拉），服务端推 `unread:snapshot`
- seq 连续性检测发现缺口 → 整段重拉兜底
- 客户端发送状态机：pending（本地）→ sent（收 ACK）→ read（收已读回执）；超时未 ACK 或断线标记 failed，同 clientMsgId 可重发

## 撤回窗口

- 默认 120 秒（system_setting 可配，M6 前向负责人确认）；仅发送者本人可撤回
- 消息不物理删除，recalled 为软状态

## 补充（2026-09-21）

- 好友会话：type=friend，共享单行（属主=较小 id，peer=较大 id），双方 seq 同一流；conv:join 校验双成员；未读按侧（unread_user/unread_peer）
- 用户会话列表：GET /user/conversations（CS + 好友，含对方资料/最后一条消息/我的未读）
- 好友事件：`friend:request`（新申请推送给被申请方）、`friend:accepted`（通过推送给申请方）
- 单设备踢出事件：`auth:session-replaced`（被新设备顶掉）、`auth:expired`（会话失效）——心跳校验后由服务端下发
- 客户端 RealtimeClient 为全局单例共享一条连接（心跳单例统一维持），页面只订阅事件，杜绝多 WS 连接

## 补充（2026-10-04：已读位点精确化 + 系统消息）

### 已读位点（单勾 / 双勾）

- `chat_conversation` 新增三方已读位点列：`user_read_seq`（属主/老板）、`peer_read_seq`（好友或打手直聊的对端）、`worker_read_seq`（CS 会话被指派客服）
- 客户端 `msg:read` → 服务端 `markRead`：
  - 清自己一侧未读（原逻辑不变）
  - 位点 = 该会话内「`sender_type <> 'system'` 且非本人发送」的最大 `seq`（读者确实收到的对方消息里最新的一条）；**只前进不回退**
  - 广播 `msg:read`（含 `readerUserId`/`lastSeq`）到 `conv:{id}` 房间 → 对方客户端把「我方消息 seq ≤ lastSeq」渲染成**双勾**，已 ACK 未读 → **单勾**，未 ACK → **时钟**
  - 客户端进页/重连时用 `GET …/conversations/:id/info` 的 `peerReadSeq` 初始化（HTTP 兜底，不依赖当次 WS 是否在线）
- **REST 兜底（2026-10-06 缺口 3）**：`POST /user/conversations/:id/read` 走**同一个** `ChatService.markRead`
  —— 同样的未读清零、同样的位点前进、同样广播 `msg:read` / `msg:read:ack`，因此「一键已读」按钮与 WS 路径**语义完全一致**；
  只是「我是会话哪一侧」按**会话归属**判定（WS 按连接角色）：我是用户侧成员取 `user` 侧，否则会话角色为 worker 时取 `worker` 侧
  （打手态 companion 对自己发起的客服会话因此也能一键已读）。返回 `{ok:true, unread:0}`（HTTP 200，幂等）。
- 语义为**近似已读**：位点是"客户端触发 msg:read 时服务端能确认的对方最新消息"，不做逐条阅读确认

### 系统消息（订单关键节点）

- 复用既有 `chat_message` 表，**不新增表/列**：`sender_type='system'` + `sender_id=0` + `msg_type='system'` + `content` 为文案
- 写入点（与订单状态流转同事务、同一 seq 流）：`taken` 已接单 / `in_progress` 已开始服务 / `pending_confirm` 已提交待确认 / `completed` 已完成结算
- 只写入「老板 ↔ 打手」直聊（`type='worker'`），**不计未读**；广播 `msg:new` 到会话房间
- 客户端：`msgType` 非 `text`/`image` → 居中中性灰 chip（底 `#E7EBF2` / 字 10.5 `#556070` / 圆角 6）

## 补充（2026-10-08：客服大厅 · 抢占式接入）

> 配套接口见 docs/03「补充（2026-10-08）：客服大厅」。**全部复用既有网关机制**
> （`RealtimeGateway.emitToUser` 推 `uid:{id}` 房间），**没有**新建房间、没有新建广播通道、
> 没有第二条 WS 连接。

### 新增事件

| 事件 | 方向 | 载荷 | 发给谁 | 用途 |
|---|---|---|---|---|
| `cs:new` | S→C | `{conversationId, reason, userNickname}` | **有客服权限且在线**的打手（`emitToUser` 逐人；**排除**触发者） | 大厅自动刷新（新咨询进池 / 退回池子重新出现） |
| `cs:claimed` | S→C | `{conversationId, byUserId, byNickname, byWorkerNo}` | 同上（**排除**抢到的那个人） | 该条从大厅列表移除 + 「已被 X 接入」提示 |

`cs:new.reason` 三值：`created`（老板新建客服会话）/ `first-message`（该会话**第一条**老板消息，
会话此前 0 条消息）/ `released`（接入客服退回池子 → 重新可接）。

> ⚠️ **`reason` 只说明"为什么刷新"，不等于"池子里一定有它"（2026-10-08 晚口径修正）**：
> 池子已收紧为"**老板至少发过一条消息**"才进池（见 docs/03「池子从哪来」），所以
> **`created` 那一刻该会话还没进池** —— 客户端收到后刷新大厅，列表里**不会**出现它；
> **真正进池的推送是 `first-message`**（每个会话只推一次）。客户端一律把 `cs:new` 当"该刷新了"的信号即可
> （触发时机本身按任务口径未改，语义差别只靠 `reason` 字段表达，e2e ⑦-a/⑦-a2 钉死这两条）。

- **受众是"有客服权限且在线"而不是 `emitToAll`**：`cs:new` / `cs:claimed` 用
  `onlineCsWorkerIds()`（= `worker.status=1 AND can_serve_customer=1` ∩ `RealtimeGateway.isOnline()`）
  逐个 `emitToUser`。**老板端与无客服权限的在线打手都收不到**（e2e ⑦-b/⑦-c 钉死）——
  用 `emitToAll`（如 `order:new`）会把"平台上有人申请客服"推给全体在线连接，这是没必要的面。
- **权限实时**：判定与大厅列表同源同函数（同一份 SQL），管理端刚授/刚撤客服权限，下一次广播即按新权限发。
- 触发点（都在既有业务路径上，**`void` 不 await**，广播失败不阻断老板侧请求）：
  - `ChatService.getUserConversation` 新建会话那一刻（`created`）；
  - `ChatService.sendMessage` 里被**行锁串行化**后确认 `last_seq=0` 的那条老板消息（`first-message`）；
  - `ChatService.releaseCsConversation` 退回成功（`released`）。

### 既有事件在大厅路径下的用法（**事件名沿用，不改名、不新增同义事件**）

| 事件 | 谁收 | 载荷 | 说明 |
|---|---|---|---|
| `chat:assigned` | ① **抢到的人** ② **老板侧** | `{conversationId, workerUserId, workerNickname, workerNo}` | ① 与既有"被指派"语义一致（打手态消息页已监听 → 自动刷新会话列表）；② **本次扩展**：同一个事件也推给老板，老板端据此显示「客服 X 已接入」（载荷已带昵称/工号，无需再拉接口；也可用 `GET …/conversations/:id/info` 的 `staffNo` 兜底） |
| `chat:unassigned` | ① 退回池子的客服本人 ② 老板侧 | `{conversationId, by:'worker'}` | 既有事件（管理端改派时推给原客服）；release 时推给本人 + 老板 |
| `chat:closed` | 既有行为**未改**（老板/客服结束咨询时照旧推给被指派客服） | — | — |

- **老板端收 `chat:assigned` / `chat:unassigned` 是唯一的新增投递**：既有客户端对未知事件零影响
  （socket.io 按事件名注册回调），客户端那批只需加两个监听即可显示「客服 X 已接入 / 已退出」。
- **管理端改派的 WS 行为一个字未改**（`chat:unassigned` → 原客服、`chat:assigned` → 新客服）。
