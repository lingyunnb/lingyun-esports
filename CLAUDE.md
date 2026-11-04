# CLAUDE.md — 项目开发指引

## 项目目标

CODM 陪玩/代练平台（第一阶段）。交付**真正可用**的三端软件：

- **老板端**（apps/boss-app，Flutter）：用户浏览游戏/分类/商品并下单、订单、消息、我的。余额只能由超级管理员后台发放，用户不能自行充值/签到/邀请/转账余额；金额一律用 ¥/元展示，钱包叫「余额」。
  **同时承载「打手态」**（负责人 2026-10-06 定案：一 App 双态，见结构规则 11）——老板在同一个 App 内用「绑定打手账号」切换到打手态接单；
  打手态仍是完整的接单能力（接单大厅/消息/我的），但**身份与令牌与老板态严格隔离**。
- **工作端**（apps/worker-app，Flutter）：**已废除并已完全阻断**（版本线：终版 v1.8.0／码58 → 到期自动阻断 v1.8.1／码59 → **完全阻断版 v1.8.2／码60，2026-10-06 已发、立即生效**）——打手态已在老板端「祁连山电竞」App 内（见结构规则 11），
  工作端不再作为打手的主入口。**代码保留但停止更新**（不加功能、不改 UI、不删页面）；云端更新的 `worker` 通道**保留**（这样任何还开着旧版的人一打开就收到这个阻断版），当前 **v1.8.2（码60）**。
  **服务端 worker 模块与打手账号/角色必须保留**（打手态就是靠 companion 会话调 `/worker/*`，一行都不能动）。
  **客户端立即阻断（负责人 2026-10-06 拍板：平台还没正式投用、没有未迁移的打手 → 不给 7 天宽限期）**：
  打开 App 先出阻断页（「工作端已停止服务，请下载「祁连山电竞」App，在「我的 → 身份」里绑定打手账号后继续接单」+ 下载入口 + 5 步绑定），
  **只剩「前往下载」**（`kWorkerSunsetBlocking = true` → 判定短路，「暂时继续使用」永不渲染）；首页/我的引导条与阻断页**同一句常量**，**用户可见文案不再出现任何日期**
  （常量与判定唯一出处：`apps/worker-app/lib/widgets/worker_sunset.dart`；纯函数 `workerSunsetCanContinue(now, {blocking})` 的 `blocking`/`now` 可注入 →
  "开关为 false 时的到期逻辑"仍被单测逐条覆盖）。
  **⚠️ 服务端兜底仍在（本轮未改服务端，也不要改）**：`role=worker` 的 **primary** 会话
  登录 403 / 已登录请求 401 / WS 拒连；**判定只有一份** `server/src/modules/auth/worker-app-sunset.ts`（login + 守卫 + 网关共用）；
  到期时间可配 `system_setting.worker_app_sunset_at`（**默认 `2026-10-13 00:00` Asia/Shanghai**，`is_high_security=1` → 仅超管可改，读侧实时读库无缓存）——
  它是**兜底**（客户端已立即阻断），负责"别处还开着的旧版本"；客户端**刻意不改它**：改早会打断用 worker primary 登录的 10 个回归套件。
  **老板端「打手态」（companion 会话）与老板端/管理端/充值受限会话一律不受影响**（companion 的 role 也是 worker，判定必须先看 `kind`）——见结构规则 11。
- **管理后台**（admin-web，Vue3 + TS）：用户/工作端/游戏/商品/订单/余额/客服/消息/排行榜/统计/管理员/系统设置/操作日志/安全审计。
- **后端**（server，NestJS + MySQL 8 + Redis + Socket.IO）：全部业务权威，客户端数据一律不可信。

优先级铁律：功能正确 > 数据安全 > 系统稳定 > 实际可用 > 性能 > 可维护 > UI。第一阶段只接入 CODM，但游戏/分类/商品/价格/图片视频全部由后台动态配置，新增游戏尽量零客户端改动。

> **质量与美观优先（负责人 2026-10-05，最高优先）**：所有开发以**质量与美观为第一优先级，效率第二**；UI/交互不达标宁可返工，不允许"先凑合上线"；出图/设计稿必须先审批再实施。

## 项目结构

```
docs/       规范文档（00-17 + 待确认事项.md），权威依据，改代码前先读相关规范
开发日志/    每天一个 YYYY-MM-DD.md，AI 每天必须更新
infra/      docker-compose（MySQL 8.4 + Redis 7，compose 项目名 fish）+ PowerShell 一键脚本
server/     NestJS 后端，接口前缀 /api/v1，Swagger 在 /api-docs
admin-web/  管理后台（Vue3 + TS + Vite + Naive UI）
apps/boss-app apps/worker-app  Flutter 双端（当前只做 Android，iOS 暂停但架构不写死）
apps/packages/core           共享 Dart 包（设计 token、API 客户端、AppConfig 环境地址、模型）
data/       D 盘持久化数据（database/redis/uploads/backups/logs/temp/exports），不入 git
```

## 双项目共存铁律（本机同时运行 OtherProject 项目）

- FISH 资源边界：compose 项目 `fish`、容器 fish-mysql/fish-redis、网络 fish_default、端口 3100/3306/6380/5173
- **禁止**停止/删除/修改任何 OtherProject-* 容器、卷、网络、nssm 服务（3000/5432/6379 与 D:\xin qiao、D:\OtherProjectServer 是另一个项目的）
- 一切 compose up/down/restart、migration、Redis 重启、备份恢复只针对 fish 项目；详见 docs/11

## UI 改版定案（负责人 2026-10-03，最高优先）

**方向：按参考 App「东东电竞」的信息架构大改，但视觉与命名全部自研**（负责人提供 47 秒真机录屏逐帧拆解 → docs/19）

- 流程：方案 A（极简留白）作废 → 方案 E（照抄度高）作废 → F/G/H 迭代 → **最终稿 I 系列为准**（`site/design/final-ui.html`，生成器 `scripts/tmp/make-mockups-i.py`；实施 = F 主题视觉 + 后几轮结构修正 + 极简找陪玩）
  - **I = F 的视觉语言**（青蓝渐变主视觉 + 卡片 + 彩色标签胶囊 + 圆形雪山下单浮标 + 底部凸起＋）
    **＋ G 的找陪玩页**（头像 + 名字 + 介绍；介绍由管理端填写，其余字段一律不要）
    **＋ 全部结构修正**（导航去重 / 不存在的不显示 / 消息只留三类 / 只有祁连山官方 / 榜单不写分部与标签）
- 参考的是**信息架构与交易密度**（怎么把陪玩卖清楚）；**禁止复制**参考 App 的图片、插画、吉祥物、文案与独特装饰
- 已确定的设计语言：冰雪蓝 #2563EB → 青 #06B6D4 渐变；琥珀金 #D97706 表价格/等级；冷灰蓝底 #F5F7FB；统一线性图标（**Flutter 内置 Material outlined**，禁拟物/吉祥物/emoji）
### 负责人 7 条要求定案（方案 F 为准，2026-10-03）

| # | 要求 | 落地 |
|---|---|---|
| 1 | 两个游戏：**和平精英 / 三角洲行动**，各含**端游 + 手游** | **修正（负责人 2026-10-03）：和平精英只有手游** → 共 **3 个分部**：和平精英·手游（通栏主卡）、三角洲行动·手游、三角洲行动·端游。`division` 表含 `platform(mobile/pc)`；平台筛选仅当该游戏有多个平台时显示 |
| 2 | 顶部导航**去掉赛事** | 顶部 = **首页 · 排行榜 · 公告**（+ 搜索）；**不含**底部已有的 服务/订单/消息/我的/找陪玩。**⚠️ 更新（负责人 2026-10-05）：原「玩家圈」入口与页面已整体下线**——见下方结构规则 1 的说明 |
| 3 | 货币统一叫**余额（元）** | 全站「余额」，金额用 ¥/元，不出现"钻石"（**2026-10-09 计价单位变更：1 元 = 1 元，原「1 元 = 10 积分」作废**） |
| 4 | **不要**猫粮/尊享卡/优惠券 | 我的页只留余额卡 + 我的订单 + 服务宫格 + 会员成长进度 |
| 5 | 底部导航**重命名 + 图标重画**，不做「东友圈」 | 底部 = **服务 · 订单 · ＋下单 · 消息 · 我的**；图标走统一线性体系（`lucide_icons` ISC）；**社区/玩家圈已于 2026-10-05 下线**（不占顶部、不占底部，两处都没有它） |
| 6 | **别抄太明显（法律风险）** | 配色改**冰雪蓝 #2563EB → 青 #06B6D4**（弃紫粉）；琥珀金 #D97706 替代亮金；底纹冷灰蓝 #F5F7FB；图标全线性（无拟物/吉祥物/emoji）；角标改细描边小片；命名体系全部自研 |
| 7 | 工作端也要改 | 工作端同步蓝青体系；接单大厅按分部筛选；排行榜加分部榜 |

- 设计稿：`site/design/final-ui.html`（/design/final-ui.html）；**最终版生成器 `scripts/tmp/make-mockups-i.py`**（F/G/H 为迭代过程留档）
- 方案 E（照抄度高）作废；**禁止复制参考 App 的图片、插画、吉祥物、文案与独特装饰**，只学信息架构与交互范式
- **功能缺口一律照抄开源**（→ docs/20-功能与开源选型.md）：骨架 `shimmer`、头像裁剪 `image_cropper`、表情 `emoji_picker_flutter`、图片预览 `photo_view`、图表 `fl_chart`/`echarts`、服务器监控 `systeminformation`、富文本 `@vueup/vue-quill`、导出 `exceljs`、拖拽排序 `vuedraggable`；**AGPL/GPL 只可参考不可引入依赖**（如 AppFlowy AGPL）
  - **图标库结论（实测）**：`lucide_icons`（Dart SDK 锁 <3.0.0）、`phosphor_flutter`、`font_awesome_flutter` 在当前 Flutter 上**均不可用**（后两者继承已 final 的 IconData：装得上、analyze 不报、一编译就炸）→ **统一用 Flutter 内置 Material outlined 图标**（core 的 `AppIcon`）

### 2026-10-06 身份合并定案（方案甲「一 App 双态」，负责人拍板）

> 本轮只定架构与后端地基；**既有定案一条不废**（本条是叠加，不是替换）。数据模型与安全语义见结构规则 11。

| # | 负责人拍板 | 落地口径 |
|---|---|---|
| 1 | **停用工作端 App** | **已废除且已完全阻断（v1.8.2／码60，2026-10-06 已发、立即生效、无宽限期）**：代码与 `worker` 更新通道保留（旧版用户一打开就收到这个阻断版），**服务端 worker 模块与打手账号/角色必须保留**（打手态依赖）；服务端 `worker_app_sunset_at`（默认 2026-10-13）降级为**兜底** |
| 2 | **一个老板账号默认绑 1 个打手账号**（上限可配、可解绑） | `system_setting.worker_binding_max_per_boss`＝1（范围 1–10，**仅超管可改**）；解绑保留历史行 + 立即吊销 companion |
| 3 | **必须做伴随会话** | 绑定打手账密**不顶掉打手原有登录**：companion 只顶 companion、**绝不触碰 primary**；**primary↔primary 仍互斥**（单设备铁律不豁免） |
| 4 | **打手态消息只留【老板】【客服】**（好友段**条件显示**） | 服务端已按此放行（白名单含 `GET /user/friends` + `POST /user/friends/:id/conversation`，用于判定"该账号确有好友会话时才显示"）；**客户端已实现条件显示并随老板端 v1.11.21（码77）发布**：会话列表里存在 `type=friend` 的会话时才追加第三段【好友】，没有就整段不渲染（不是显示空段）；判定口径与测试同源，见 `apps/packages/core/lib/src/identity/worker_messages_page.dart` |

- 打手态**只显示三处**：接单大厅 / 消息 / 我的；身份细带 28dp（`WorkerIdentityBand`），出现即表示"当前在打手态"
- 设计稿：`site/design/merge-identity/index.html`（A / A+ / B / C 四套对比，C4 专画好友段条件显示态）；**定案以 A+ 系列为准**
- **本轮不动 `site/design/**`**；客户端实施**已完成并随老板端 v1.11.21（码77）发布**（打手态已是线上能力）

> **⚠️ 首页「紧贴导航」连接体换位（2026-10-06，负责人认可）**：**10-05 定案的「宣传图通栏紧贴导航」已被 10-06 的充值入口条有意修订** ——
> 「紧贴导航（零底距、同宽）」这个连接体从**宣传图**改为**充值入口条**：**条自身紧贴导航**，**宣传图退到条下方**（10dp 间距挪到条的下面）。
> **入口不出现时（管理端未配收款码）取值与改动前逐字相同**（导航底距仍按有无宣传图取 0/10，宣传图回到紧贴导航的老位置）——见结构规则 12 与 `apps/boss-app/lib/pages/services_page.dart`。

### 结构规则（负责人 2026-10-03；避免入口重复、模块混装、AI 味）

1. **同一入口只出现一次**：底部导航已有「服务 / 订单 / 消息 / 我的」→ 顶部导航**不再出现这几个名字**；顶部只放底部没有的（**排行榜 / 公告** + 搜索）
   - **⚠️ 玩家圈（论坛/社区）已于 2026-10-05 整体下线**（负责人要求"彻底删掉"）：老板端顶部导航入口、论坛三页（列表/详情/发帖）、我的页入口、快捷面板「发帖到玩家圈」、工作端首页「社区」与我的页入口、core 模型与图标、后端 `server/src/modules/forum/**` 与全部 `/forum*`、`/admin/forum*` 路由、管理端「论坛管理」页（页面/路由/菜单/首页宫格）**全部删除**。
   - **数据库表与数据一律保留**：`forum_post` / `forum_comment` / `forum_like`（含 `media` 表里 `forum_image`/`forum_video`/`forum_cover` 类型的历史媒体）**不删表、不删数据**；如需彻底清库须负责人单独批准。
   - 因此**顶部导航只剩 排行榜 · 公告 + 搜索**，原三项之间的 14dp 间距保持不变、左对齐、不留空位。
2. **不存在的东西不出现**：和平精英只有手游 → 其榜下**不显示"端游"选项**；平台筛选仅当该游戏有多个平台时出现
3. **模块不混装**：消息页只有 **好友私聊 / 客服 / 打手** 三类；系统通知与公告归「公告」
   - **群组功能已全部下掉（负责人 2026-10-04）**：不再有订单群 / 群成员 / 群组 tab / 群消息事件
   - **打手分区 = 老板 ↔ 打手一对一直聊**（会话类型 `worker`，走与好友会话相同的读写与未读机制）；工作端对应三类 = **好友私聊 / 客服 / 老板**
   - 接单/派单成功后由 `ensureWorkerDirectTx` 建立一对一会话（原 `ensureOrderGroupTx` 已删除）
4. **只有官方自营**：不出现"推荐俱乐部/关注俱乐部"等多档标签；首页 = 分部卡 + 官方自营馆 + 保障说明
5. **反 AI 味（设计硬要求，逐条依据 docs/21-反AI味设计规范.md）**：
   - **禁**：渐变做主视觉 / 每卡左侧彩色竖条 / 全大圆角（一律 ≥16）/ 阴影铺满卡片 / 顶部并排三个大数字 / 每条信息配彩色小标签 / emoji 当图标 / 纯黑配纯白 / 装饰性插画
   - **要**：实色主色（渐变只做极小面积或不用）；圆角分档 4–6 / 10 / 14 / 胶囊；列表用**发丝线**、阴影只给弹层；左对齐为主；**组内紧（8–10）组间松（20–24）**；标签只给必须区分的项；文案具体可验证；**假数据必须拟真**（非整数、长短不一、带场景，如 `2,847 单`、`9:00-次日 2:00 在线`、`不接急单`）
   - 每个颜色/圆角/间距都要能说出理由；出图与实现前先过 docs/21 第六节 6 条自检
6. **陪玩/打手展示极简（负责人 2026-10-03，硬规则，覆盖所有相关页面）**：
   - **允许的字段只有两个**：**名字** + **介绍**
     - ⚠️ **2026-10-17 负责人改定：介绍改成「打手自己写」**（原「介绍由管理端填写」作废）。
       打手态「我的 › 个人介绍」→ `PUT /worker/profile`（2–120 字、最多 1 个换行、禁首尾空白、
       **简介里不许出现手机号 / 微信号 / QQ 号** → 中文「简介里不能留联系方式」，理由是负责人要求「请勿私加打手」）；
       规则唯一实现 `server/src/modules/worker/worker-intro.rules.ts`。
     - **管理端仍可改（兜底）**：`PUT /admin/workers/:id/players-profile`（0–200 字，语义未变）；
       两条路径都写 `user.intro`，均用**定列更新**，互不覆盖；`user.intro_updated_by` 为 NULL = 打手自写。
     - 字段落在 `user.intro varchar(200)`（**不是 `worker` 表**），列宽够用 → 本轮**无需 migration**。
   - **禁止出现**：明星陪玩 / 大神 / 单考 / 双考 / 空闲 / 忙碌 / 等级 / 评分 / 单价 / 下单人数 / 语音时长 / 标签胶囊 / 分部副标
   - 「找陪玩」列表 = 头像（若有） + 名字 + 介绍；**榜单** = 名次 + 头像 + 名字 + 数值（分部不写进每行，由上方胶囊决定）
   - 需要这些属性时，一律进**详情页**，不在列表/榜单里堆
7. **AI 页（祁小山）是底栏第 5 个分支，不是 push**（负责人 2026-10-04 定案）：底部导航中间凸起位就是 AI 自己的位
   （`HomeShell.pageAi = 4`、导航位 `2`），**底栏常驻**、**中间凸起按钮有选中态**（选中主色 / 未选中 `#94A3B8`，与其余四项同规则）；
   页头无返回箭头，系统返回键回**上一个 tab**（不是退出 App）。会话**只在冷启动轮换一次**（`AiColdStart.ensureResetOnce()`），
   同一次运行内切走再切回**对话保留**。找陪玩页「问祁小山」同走这条分支（不 push 第二层）
8. **平台抽成比例由管理端配置，不写死在代码里**（负责人 2026-10-04）：比例存 `system_setting.platform_commission_rate`
   （**当前 25%**，范围 **0–50 整数**，**仅超管可写** `admin:setting:write`）；结算每次读库、按当时比例落库（历史单据可回溯），
   管理端「系统设置」页改完立即生效，三端展示的比例一律用接口下发值（客户端禁写死 70/30）
9. **管理端商品支持多选「移动到分部」**（负责人 2026-10-04）：`POST /admin/products/move` 批量改归属，
   **只改 `division_id/game_id/category_id`，名称/价格等字段一个不碰**；分类未指定时按原分类名在目标游戏下**自动匹配、找不到就新建同名分类**；
   整批校验（目标分部/游戏/商品全部存在才动，缺一个整批回滚）+ 幂等（目标即当前则跳过）+ `operation_log` 审计（谁、哪些 id、从哪到哪、新建了哪些分类）
   —— 管理端「商品」页另有**分部筛选**（`GET /admin/products?divisionId=`，不选=全部）
10. **接单权限按分部授予**（负责人 2026-10-04）：权威表 `worker_division_permission(worker_id, division_id, can_take_order)`
   （唯一键 `worker_id+division_id`，查询恒带 `can_take_order=1`）；`worker.can_take_order` **仅作「是否有任一授权」的派生汇总**（写入时同步，不作判定依据）。
   **抢单大厅 / 抢单 / 确认派单 / 管理端派单 / 指定护航员 / 找陪玩 / AI 推荐候选人 全部按分部实时查库隔离**（无缓存，管理端改完下一次请求即生效）；
   **老板指定护航员只能看到该分部有权限的打手**；无权限一律中文拒绝（抢单 403 / 派单 400 / 指定下单 400），大厅无权限返回空列表 + 中文提示（不是报错页）。
   - **⚠️ 大厅修复（负责人 2026-10-06）**：**无任何分部权限**时 `/worker/order-hall` 由 **403 报错页**改为 **200 + 空列表 + `divisionDenied` + 中文提示**。
     判定只认权威表 `worker_division_permission`，**不再用 `worker.can_take_order` 派生汇总拦截**；仅"无打手档案 / 档案停用"仍 403。
     **指定无权限分部时的既有行为逐字不变**（抢单仍 403）。

11. **一 App 双态（方案甲，负责人 2026-10-06 拍板，后端地基已落地）**：老板端一个 App 内同时承载**老板态**与**打手态**；工作端 App 已决定停用（代码保留，见「项目目标」）
   - **数据模型**：`worker_identity_binding`（`boss_user_id` ↔ `worker_user_id`，`status(active|unbound)` + `slot` + `bound_at/unbound_at`）。
     **解绑保留历史行**（`status=unbound`，不物理删除，可审计）；唯一约束用**生成列**实现（`active_boss_user_id` / `active_worker_user_id`，非 active 时为 NULL → 唯一索引忽略 NULL）：
     `UK_wib_active_worker` = **一个打手账号同时只能被一个老板绑定**（与上限无关的语义硬约束）；`UK_wib_active_boss_slot(boss, slot)` = 老板侧**上限可配且并发安全**。
   - **伴随会话（companion）**——合并的关键，**绝不能顶掉 primary**：`auth_token.kind ∈ {primary, companion}`（存量行默认 primary）+ `binding_id`；
     companion **只顶 companion**、**绝不触碰 primary**；companion TTL **12h（access 与 refresh 同）**，到点须重新输打手账密切换。
     **⚠️ 不等于豁免单设备铁律**：**primary ↔ primary 仍互斥**（同账号再登录依旧 `revoked=2` + 原文案），primary 的吊销语句加了 `kind='primary'` 过滤
     —— 只有 primary 时该条件恒真，单设备语义逐字未变。详见 docs/04「伴随会话」。
   - **打手态只显示三处**：**接单大厅 / 消息 / 我的**（`WorkerShell` 只装这 3 页，底部导航只有三项，无第 4 个 tab）；工作端 App 决定停用后，打手的主入口就是这三处。
   - **白名单默认拒绝**（`jwt-auth.guard.ts` 的 `isCompanionAllowedRoute`）：companion 是**受限会话**，只放行**打手族 `/worker/*` + 消息族 `/user/conversation*`、`/user/conversations*`
     （+ `GET /user/friends`、`POST /user/friends/:id/conversation`）** + `GET /user/profile/*` + `/media/*` + `GET /auth/me`、`POST /auth/logout`、`POST /auth/refresh`**；
     其余一律 403 中文（`/user/orders`、`/user/wallet`、`/user/identity/*`、`/auth/password`、`PUT /user/profile`、`/admin/*` 等）。
     **是允许清单而不是黑名单**：**将来新增接口默认对 companion 关闭**，必须显式加进来才能用（黑名单会在"新接口忘加规则"时静默放开）。
   - **每请求校验（无缓存）**：绑定 `status=active` + 绑定里的打手 = 会话主体 + 打手账号未封禁 + 打手档案在职 + **老板账号未封禁**（`user.status=1`，2026-10-06 缺口 1 双保险，专兜历史悬空 active 行）；**解绑即刻失效**（401 中文，客户端退出打手态）。
     **实现只有一份**：`modules/auth/companion-session.check.ts` 的 `checkCompanionSession()` —— **HTTP 守卫与 WS 网关（握手 + 心跳）共用**
     （安全审计 F1：旧实现只有 HTTP 侧有这套校验，导致「HTTP 已 401，旧 WS 连接仍能 join 房间并继续收到 `msg:new` 全文、同一令牌还能新建连接」；
     **禁止在网关里复制第二份 SQL**）。释放/封禁后：同一令牌**新建 WS 被拒**、**已连接 WS 被主动断开**（`disconnectByJti`，实测 27–28ms），**打手 primary 不受影响**。
   - **封禁/删除即释放绑定（对称）**：`POST /admin/users/:id/ban` 与 `DELETE /admin/users/:id` 都把该账号**两侧**的 active 绑定
     置 `unbound`（`worker_user_id = 该账号` ∪ `boss_user_id = 该账号`，历史行保留 + 写 `unbound_at`），响应回带
     `releasedBindings` / `releasedAsWorker` / `releasedAsBoss`；**解封/重新启用不自动恢复绑定**（须老板重新输打手账密）。
     打手档案停用两个入口沿用同一实现（打手侧，既有行为不变）。
     **⚠️ `auth_token.user_id` 归属（F1-c 纠错）**：companion 行的 `user_id` 是**打手**（不是老板）→ 封老板时 `WHERE user_id=老板` 扫不到它，
     必须靠**按 `binding_id`** 的吊销兜住（已实现）。别再按"companion 同属该 user_id"写代码。
     详见 docs/04「封禁 / 删除即释放绑定」。
   - **释放路径四件事（唯一实现 `worker-binding-release.ts` → `BindingReleaseService`，四条路径共用）**：
     ①绑定置 `unbound` ②按 `binding_id` 吊销 companion 令牌 ③主动断开这些会话的 WS（删除走事务 → 提交后断开）④写 identity 审计。
   - **解绑审计（F4）**：`login_log(user_type='identity')`，`fail_reason` 形如
     `解绑：<来源> | binding=<id> | boss=<id> | worker=<id> | by=<触发者>`，含 IP/UA/时间；来源四种 = 老板主动解绑 / 系统释放（打手档案停用 / 封禁账号 / 删除账号）。
     选 `login_log` 而非 `operation_log` 的理由：后者**没有 UA 列**，且管理员动作已在它里面留痕，身份事件写进去会把绑定生命周期拆到两张表（详见 docs/04）。
   - **上限可配**：`system_setting.worker_binding_max_per_boss`（**默认 1**，范围 **1–10 整数**，`is_high_security=1` → **仅超管可改**，改完立即生效无缓存）。
   - **服务端到期收口（2026-10-06 定案，补掉"改手机时间 + 离线"的绕过缺口）**：工作端 App 的到期阻断原先**只在客户端**（
     `apps/worker-app/lib/widgets/worker_sunset.dart`，判定取「设备本地时间 / 服务端 `Date` 头」中较晚者）——改手机时间 + 离线即可绕过。
     现在**服务端**在到期后拒绝「工作端 App」：
     - **拒绝**：`role=worker` 的 **primary** 会话 —— ① `POST /auth/login`（`role=worker`）→ **403 中文**；
       ② 已登录的 worker primary 令牌打任何 `/worker/*`、`/user/*`（及其余受保护接口）→ **401 中文**；
       ③ WS（`/ws/chat`）worker primary **握手直接拒绝 + 心跳（ping）收到 `auth:expired` 后断开**。
     - **绝不影响**：**老板端「打手态」（`auth_token.kind='companion'`；它的 `role` 也是 `worker`，判定必须先看 kind —— 这是替代品）**、
       老板端（`primary`+`user`）、管理端（`primary`+`admin`）、充值受限会话（`kind='recharge'`）。
     - **配置项**：`system_setting.worker_app_sunset_at`，**默认 `2026-10-13 00:00:00`（Asia/Shanghai 墙钟 = `2026-10-12T16:00:00Z`）**，
       `is_high_security=1` → **仅超管可改**（`PUT /admin/settings/worker_app_sunset_at`），读侧**每次实时读库无缓存**（改完下一次请求即生效）。
       migration `1806000000000`。**不改客户端**。
     - **判定只有一份**：`server/src/modules/auth/worker-app-sunset.ts`（读配置 + 判断 + `isWorkerPrimarySession` 边界 + 文案常量），
       `AuthService.login` / `JwtAuthGuard` / `RealtimeGateway` 三处共用 —— **禁止复制第二份 SQL 或日期比较**（安全审计 F1 同类根因）。
     - **不吊销令牌**：到期只是"多一道 401"，配置改回未来时间后**同一枚令牌立刻恢复可用**（实测 401 → 还原 → 200）。详见 docs/04「工作端到期收口」。
   - **客户端**（老板态「我的」身份分组 + 打手态三屏 + 28dp 身份细带）**已随老板端 v1.11.21（码77）发布**（2026-10-06）。

12. **充值（线下收款 + 人工审核，负责人 2026-10-06 定案）**：老板端「充值」= 选金额 → 展示管理端指定的收款码 → 老板**线下扫码付款** → 上传截图提交申请 → 管理员核对后**手工加余额**；「身份」里新增**管理员身份**（**最多 5 个账号**、**权限仅限余额/充值相关**）
   - **⚠️ 合规红线（不可放宽，写代码前先读这条）**：
     - **不接任何支付通道** —— 没有支付 SDK、没有支付回调、没有支付单号、**全站不出现「支付成功」字样**（只有「已发放」= 余额已由管理员手工发放）；
     - 收款码是**一张图片**（`recharge_qr_code.media_id`），**App 只展示**；用户在**平台外**付款 → 上传截图 → **人工核对** → 手工发余额；
     - **平台不经手资金**；**不做自动到账**（`status='granted'` 只能由管理员手工 grant 触发，没有任何定时任务/回调路径）；**用户永远不能自行加分**（老板的余额不可兑回现金）。
        **⚠️ 提现（原「不做提现」铁律已按负责人 2026-10-11 定案改写）**：**提现走人工打款**——平台经手资金，二选一：**分账** 或 **本流程**（当前实现的是本流程，见结构规则 13）。
        打手可以提现，但**路径只有一条**：申请 → 平台**在申请时立即从余额扣款并锁定** → 管理员核对收款信息后**线下微信人工打款** → 回填凭证；打款失败则驳回并**退回余额 + 反向流水**。
        **仍然不接任何代付/支付通道**（没有代付 API、没有回调、没有商户号），也**没有**"老板余额提现"这条路。
     - 这三条**同样适用于接口层面**：不做的能力不留在模型里（表里没有支付单号/商户号/appid/密钥/回调字段），也不留在路由里。
   - **管理员态 = 受限会话**：复用打手态（companion）那套机制 —— `auth_token.kind='recharge'`、**绝不顶掉 primary**（管理员在管理端的登录照常可用）、TTL **12h**（与 companion 一致）、**白名单默认拒绝**。校验实现**只有一份**：`modules/auth/recharge-session.check.ts` 的 `checkRechargeSession()`（HTTP 守卫每请求调用，与 companion 的 `checkCompanionSession` 同构）。
   - **⚠️ 双层口径（负责人 2026-10-06 明确，防后人误读）**：
     - **PC 管理端（admin-web）= primary 会话 + 窄权限点**（`role=admin` 正常登录，走 `/admin/recharge/*`，用 `recharge:review` / `recharge:grant` 做权限渲染与校验）。**管理端不需要、也不应该套受限会话** —— Web 后台本就是管理员终端，再包一层只剩登录流程变复杂，没有额外安全收益。
     - **App 内「管理员身份」= 受限会话**（走 `/recharge/*`，白名单 ≤5、12h、默认拒绝一切其它接口）——它为"手机 App 不该拿到全权 admin 会话"而设计。
     - 两条入口**共用同一个服务层**（`RechargeService.reviewList / grant / reject`）→ 幂等、审计、状态机完全一致，差的只是"用哪种会话进来"。
   - **受限会话白名单**（`isRechargeAdminAllowedRoute`，**允许清单**）：只放行 `/recharge/*` + `GET /auth/me` + `POST /auth/logout` + `POST /auth/refresh`；其余一律 **403 中文**，含 `/admin/*`（**连本功能的 `/admin/recharge/*` 也不放行** —— 改配置/收款码必须走管理端登录）、`/user/orders`、`/user/wallet`、`/user/identity/*`、`PUT /user/profile`、`/auth/password`、`/media/*`。
     - **凭证读取为什么单开 `/recharge/proof/:requestId`**：白名单刻意不含 `/media/*`（该接口对 `role=admin` 放行**任意**受保护媒体，受限会话不该拿到这个面），而"核对转账截图"是链路必要环节 → 收窄到"这张申请的那张图"（详见 docs/待确认事项.md）。
     - **WS**：`RealtimeGateway` **握手阶段直接拒绝** `kind='recharge'`（无实时需求；且其 `role=admin` 会 join 管理端广播房间 = 越权面）。
   - **每请求校验（无缓存）**：仍在 `recharge_admin` 白名单 + 账号未封禁 + 仍是 `role='admin'`；**移出白名单 → 下一次请求立即 401 中文**（同时立即吊销其全部 `kind='recharge'` 会话 + 断开 WS + 站内通知；**绝不动 primary**）。
   - **上限 5 由服务端强制**（硬上限常量 `RECHARGE_ADMIN_LIMIT_MAX=5`，配置 `admin_limit` 只能在其内**收紧** 1–5）；
     **并发安全 = 唯一约束 + 事务 + 行锁**：`recharge_admin.user_id` 主键（唯一）+ 事务内对 `system_setting.recharge_config` 行 `FOR UPDATE` **行锁**把增删串行化（锁各自 user 行防不住"两个不同账号同时加入"越限）。
   - **仅超管可增删/可改配置**：配置行走 `is_high_security=1`（既有机制，`SystemSettingService.update` 与 `PUT /admin/settings/:key` 同一条路径）；白名单增删走 `assertSuperAdmin()`（`super_admin` 或 `is_owner=1`）。
     实测口径：**即便账号有 `admin:admin:write` / `admin:setting:write`，非超管仍被这两道闸门 403**。
   - **专用窄权限点（只加这两个，不复用任何 `admin:*` 大权限）**：`recharge:review`（读待审列表）/ `recharge:grant`（发放/驳回）—— migration `1805000000000` 只授予 `super_admin`，其余既有角色**一个都不给**（需要时由超管在角色页显式勾选）。
   - **幂等 + 审计（一张申请只能发放一次，三层缺一不可）**：①事务内 `SELECT ... FOR UPDATE` 校验 `status='pending'`；②**条件 UPDATE 判 affectedRows**（`WHERE id=? AND status='pending'`）；③幂等键 `wallet_transaction.idempotency_key = 'recharge:' + requestId`（唯一）+ `recharge_request.UK_rqr_wallet_txn`（一笔流水只能对应一张申请）。
     重复调用 → 中文 400「该申请已发放」且**不重复加分**。审计三件套 = `reviewed_by`（谁发的）+ `reviewed_at`（什么时候）+ `wallet_transaction_id`（发的哪一笔，顺流水拿前后余额快照）。
   - **余额逻辑复用，零新增**：发放走 `WalletService.grantInTx()` → 与超管在管理端发余额**同一个函数**（`executeChange`），本模块不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`。
   - **全部可配**（`system_setting.recharge_config`，`is_high_security=1` → **仅超管可写**，读侧**每次实时读库无缓存**）：
     `amountOptions`(默认 `[6,10,20,38,68,98,128,198,328,648]`) · `customEnabled`(true) · `minYuan`(1) · `maxYuan`(10000) · `pointsPerYuan`(**10**) · `pendingLimitPerUser`(3) · `adminLimit`(**5**) · `noticeText`(给老板看的说明)。
     - **为什么配置落 `system_setting` 而不是单开 `recharge_config` 表**：只有它才能真正**复用 `is_high_security` 机制**（"仅超管可写"本身就是 `system_setting` **行**的属性 + `SystemSettingService.update` 的判定）；单开表就得把这条规则**再实现一遍**（与"同一规则只有一份实现"冲突，是安全审计 F1 的同一类根因）。业务数据（收款码/申请/白名单）仍建**真表**（要分页、要唯一约束、要行锁、要审计）。
   - **余额换算（2026-10-09 重写）**：`points = round(amountYuan × pointsPerYuan, 2)` —— **按比例精确换算并保留 2 位小数**；换算结果 ≤0 → 中文 400。
  ⚠️ 旧口径是 `Math.floor`：在 `pointsPerYuan=10` 时无害（整数档位 ×10 永远是整数），**改成 1 之后会直接把用户的分砍掉**（充 6.5 元只到账 6 元，白丢 0.5 元）—— 已修，且 `recharge_request.points` 由 int 改 `decimal(12,2)`。
   - **消息通知复用既有实现**：`user_notification` 表 + `notification:new` 实时事件（不新造通知通道）；文案如「充值申请已到账：+600.00 元」/「你的充值申请（68 元）被驳回：<原因>」。
   - **媒体用途专用（不借用 banner / complaint_image）**：`recharge_qr`（**public**，老板端要能直接展示）+ `recharge_proof`（**protected**，资金凭证**绝不能公开直连**）；两者都进 `MediaService.referenceCount()` 引用计数 → 仍被引用的图**禁止删除**。
   - 表结构见 docs/02；接口与中文错误码、字段别名见 docs/03；会话语义见 docs/04；凭证读取通道的取舍见 docs/待确认事项.md。

13. **打手提现（人工打款，负责人 2026-10-11 定案）**：**打手可提现，但只有一条路径** —— 绑定微信收款信息 → 提交申请（**申请时立即扣款并锁定**）→ 管理员核对后**线下微信人工打款** → 回填凭证；打款失败则**驳回 → 退回余额 + 反向流水**。**平台经手资金**（与充值相反），二选一里的"分账"未做，当前实现的是本流程；**仍然不接任何代付/支付通道**（无代付 API、无回调、无商户号）。
   - **扣款时机 = 申请时立即扣**（同一事务内扣款 + 写流水 + 建 `pending`）：申请期间这笔钱**不可能被再花、不可能重复提现**；驳回退回并写反向流水 `withdraw_reject`。
   - **资金安全三件套（缺一不可，与充值发放同一套姿势，禁止自己发明第二套）**：①事务 + `SELECT … FOR UPDATE` 锁钱包（申请）/锁申请行（pay、reject）；②**条件 UPDATE 判 `affectedRows`**：`UPDATE withdraw_request … WHERE id=? AND status='pending'` —— 这是"能否打款/驳回"的**唯一判定点**（刻意不写成"先读状态再 UPDATE"）；③幂等键 `wallet_transaction.idempotency_key`：扣款 `withdraw:<requestId>`、退回 `withdraw_reject:<requestId>`（唯一约束）。**表结构级兜底**：`UK_wr_pending_worker`（同一打手不可能两笔 pending，并发落败方 → 中文 409）、`UK_wr_wallet_txn`、`UK_wr_idem`。
   - **扣款与退回都走既有 `WalletService`**（`withdrawDeductInTx` / `withdrawRefundInTx` → 同一个 `executeChange`）：提现模块**不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`**；金额一律 `¥`/两位小数，**全模块不出现"积分"**。
   - **权限 = 仅超管**：两个**窄权限点** `withdraw:review`（看列表/详情/收款码/打款凭证）与 `withdraw:pay`（打款/驳回），migration `1810000000000` **只授予 `super_admin`**（与 `recharge:review`/`recharge:grant` 完全同口径）。**"看"与"打款"刻意拆开**：前者只读（含敏感个人信息），后者是**不可逆的资金动作** → "能看不能打"是可独立授予的形态。
   - **双层口径（照抄充值）**：PC 管理端 = primary（`role=admin`）→ `/admin/withdraw/*`；App 内「管理员身份」= 受限会话 `kind='recharge'` → `/withdraw/*`（**白名单显式新增 `/withdraw/*`**，允许清单不加即整族 403；复用**同一个** `RechargeSessionGuard`）。两条入口**共用同一服务层**（`WithdrawService`）→ 幂等/审计/状态机完全一致。**没有**配置接口走受限会话（改门槛只走管理端 primary）。
   - **配置**（`system_setting.withdraw_config`，`is_high_security=1` → **仅超管可写**，读侧**实时读库无缓存**）：`minAmount=10` · `maxAmount=2000` · `dailyLimit=1` · `feeRate=0`（未参与扣款计算）· `noticeText`。**未结清申请数上限 1 写死在代码里**（与唯一键同源，不做成配置）。
   - **媒体用途专用**：`withdraw_qr`（**protected**，收款码绝不公开直连）+ `withdraw_proof`（**protected**，打款凭证），都进 `MediaService.referenceCount()`；取图只走 `GET …/withdraw/proof/:id?kind=qr|payout` 这条按申请收窄的通道（**不放行 `/media/*`**）。
   - **App 内侧的打款凭证走专用上传通道 `POST /withdraw/requests/:id/pay-proof`**（2026-10-11；multipart 字段 `file`，用途固定 `withdraw_proof`/protected，返回 `{mediaId, url}`）：它落在**已被放行的 `/withdraw/*` 前缀内**（白名单一个字没改，**没有**顺手放宽 `/media/*`），只能给**处于 `pending` 的那张申请**传图（已打款 → 中文 400「该申请已打款」；每次上传写 `operation_log`，不落文件内容）；**`pay` 的 `proofMediaId` 因此必填、备注可选**（校验收口在同一处 → PC 与 App 一起以更严的为准）。
   - **收款信息的完整/脱敏口径（2026-10-11 负责人定案）**：**列表与详情均给完整收款信息**（列表行 `account:{realName,phone,wechatId}`，与详情同名同形；**保留** `accountMasked` 做旧客户端兼容）—— 能读列表/详情 = 持有 `withdraw:review`，**读取者本身即审核人**，向他隐藏只会让"核对收款信息"必须点进详情；**权限点一个没加**。**审计日志与站内通知仍只记脱敏/不含完整手机号**（`operation_log.request_body` 摘要含绑定/换绑新旧值、`user_notification` 文案、任何日志、打手侧回显一律脱敏）—— `operation_log` 是比审核列表**更宽**的面（读它由「操作日志」权限决定），PIPL 的合规点是"**不向无关方泄露**"，**这条不许放宽**。
   - **审计/通知**：申请/绑定/换绑（**含新旧值摘要，值一律脱敏**）/打款凭证上传/打款/驳回/改配置全部写 `operation_log`（不记密码/token）；打手侧发 `user_notification` + `notification:new`（「提现申请已提交：¥100.00 已从余额扣除」/「提现已打款：¥100.00」/「提现被驳回：¥100.00 已退回余额，原因：…」）。
   - 表结构见 docs/02；接口与中文错误码见 docs/03；会话语义与两个新权限点见 docs/04；扣款/退回/守恒见 docs/06「提现」一节；e2e `scripts/tools/withdraw-e2e.js`（**114 断言 0 失败 + 四条变异验证**，含 ⑭ 列表完整值 + 非审核面负向断言）。

## 当前开发阶段

**v0.6.0 一 App 双态（身份合并）后端地基（2026-10-06，方案甲）**：
- **玩家圈已于 2026-10-05 整体下线**（三端删页面/入口/路由/权限，后端 `forum` 模块与 `/forum*`、`/admin/forum*` 路由删除；**`forum_*` 表与数据保留**）
- **新表 `worker_identity_binding`** + `auth_token.kind/binding_id`（migration `1801000000000` / `1802000000000`，均已执行，`No migrations are pending`）
- **伴随会话**：companion 不顶 primary、TTL 12h、每请求实时校验绑定 + 打手未封禁 + 档案在职、**白名单默认拒绝**
- **身份接口 4 个**：`POST /user/identity/bind|unbind`、`GET /user/identity`、`POST /user/identity/refresh`（bind/unbind/status 是老板侧能力，companion 不可用；
  refresh **公开且只吃 companion refreshToken**：primary 的 refreshToken 打进去 **401「该令牌不是伴随身份，请使用 /auth/refresh」**，且不触碰任何 primary 会话 —— 安全审计 F5）
- **独立安全审计（2026-10-06）修复收口**：F1（中危，companion 释放后 WS 仍存活并继续收全文）已按 a/b/c 三条修完并端到端验收 **25/0**；
  F2（绑定接口账号枚举文案）统一为「账号或密码错误」；F3（会话存在性 oracle）非当事方统一 404；F4（解绑无留痕）四类来源全部写 `login_log(identity)`；F5（refresh 未校验 kind）已修。详见 docs/04「其它安全审计修复」
- **大厅修复**：无分部权限 → 200 空列表 + `divisionDenied` + 中文提示（原 403）
- **验证**：`identity-merge-test.js` **76 PASS / 0 FAIL**；`worker-hall-noperm-test.js` **11/0**；`stage14-settlement-test.js` **43/0**；既有 `session-test` 13/0、`security-test` 15/0、`chat-test` 31/0；
  `tsc --noEmit` 与 `npm run build` exit 0；冒烟 `merge-identity-smoke.js` 15/0
- **已发布（2026-10-06 收口）**：老板端 **v1.11.21（码77）**、工作端 **v1.7.9（码56）**（旧版 v76 / v55 已自动停用；
  两端 `[4/4] ✓`，`aapt` 版本码 2077 / 2056 = 码 + 2000；`updateDesc` 与本机 UTF-8 说明文件**逐字节一致**）。
  客户端打手态（老板态「我的」身份分组 + 打手态三屏 + 28dp 身份细带）、`≈ N 元` 换算、云更新多连接分块提速均已随本次发布上线。
- ⚠️ **公网出口事件（2026-10-06 发布当天）**：固定域名 `<your-tunnel-domain>` 返回 **403 `ERR_NGROK_725`**
  （ngrok 账号**月度流量耗尽**，账号级、非仓库问题；额度重置后自动恢复）。**烧录地址与 `config/client-config.json` 未改动**
  （Cloudflare 备选隧道域名每次重启会变，不适合烧进 APK）；`site/download/download-temp-qr.png` 是临时入口二维码
  （指向当前可用的 Cloudflare `/site/` 页，隧道重启后需重生成）。是否升级 ngrok / 换自建入口属**负责人花钱决策**
  → 详见 `site/download/README.txt` 与 `docs/待确认事项.md`

**v0.5.0 UI 大改 + 分部体系（2026-10-04 凌晨，全自动开发模式）**：
- **设计定案 I 系列**（F 主题视觉 + 全部结构修正 + 极简找陪玩）→ `site/design/final-ui.html`
- **设计 token 重写**（core）：青蓝 `#2563EB`/`#06B6D4` 渐变主题、琥珀金 `#D97706`、冷灰蓝底 `#F5F7FB`、圆角分档
- **组件层**（core/widgets）：`AppCard` / `AppTag` / `AppPrice` / `AppButton` / `AppSectionHeader` / `AppEmpty` /
  `AppMountainMark`（雪山标）/ `AppBottomNav`（服务·订单·凸起＋·消息·我的）/ `AppOrderFab` / `AppQuickActionsSheet` / `AppIcon`
- **后端分部体系**：`division` 表（游戏 + 平台）+ 公开接口 `/divisions`、`/divisions/grouped`（含 `onlineCount` 真实在线数、
  `platformCount` 决定客户端是否显示平台筛选）+ 管理端 CRUD（`admin:division:*`）+ 商品/订单/工作端/榜单全部挂 `division_id`
- **老板端**：服务页（新首页，按分部）/ 找陪玩（**只有 头像 + 名字 + 介绍**，介绍由管理端填）/ 排行榜（分部榜、周月榜）/
  消息页三类分区（好友私聊·客服·打手）/ 下单页平台选择（多平台才显示）
- **工作端**：接单大厅分部筛选；配色随 token 全局生效
- **管理端**：新增「分部管理」页（`/divisions`）
- **目录已重新上架**：7 分类 / 10 商品（按分部），下单链路端到端可用
- **已发布**：老板端 **v1.8.3（码36）**、工作端 **v1.5.1（码28）**（旧版自动停用；签名与存量用户一致可原位升级）
- **验证**：三端 `flutter analyze` 0 issue；core 32/32、老板端 19/19、工作端 13/13 测试通过；管理端构建通过；
  管理端接口冒烟 16/16；后端全量回归 14 套件 310 项断言 0 失败；端到端下单链路 9/9 步通过
- **验收材料**：`docs/23-验收报告.md`
- **遗留**：我的/工作端消息页视觉未替换（功能完整）；管理端既有页面 token 未对齐；手机推装待插线
  （`powershell -File scripts/install-apps.ps1`）；语聊房/频道社区按负责人要求暂停
  （原「玩家圈视觉未替换」一条已随 2026-10-05 玩家圈整体下线而失效）

**v0.4.0 品牌与数据重置（2026-10-03）**：
- **俱乐部更名**：FISH 电竞 → **祁连山电竞**（老板端/官网/管理端/后端文案；工作端 App 名「祁连山电竞内部」）。内部标识（`fish_core` / `FishGlass*` / 包名 `com.fish.*`）保持不变
- **新品牌图标**：祁连山雪山意象（老板端暖金晨光 / 工作端冷蓝夜色+「内」徽章），含自适应图标与启动图；生成器 `scripts/tmp/make-icons.py`
- **下单模块清空**：游戏 1 / 分类 4 / 商品 15 / 订单 75 / 快照 75 / 状态日志 270 / 结算 20 / 申诉 6 全部归零；订单类资金流水一并清理（保留管理员发放/回收），钱包余额按剩余流水重算；订单群会话解散
- **工作端排行榜清空**：leaderboard_entry 6→0、worker_stats 2→0（榜单接口自动重算后返回空榜）
- 清空前全库备份：`data/backups/fish_pre_rebrand_20261003_213602.sql`
- 已发布：老板端 v1.7.0（码32）、工作端 v1.4.0（码26）；三包测试 core 32/32、老板端 14/14、工作端 13/13
- **待办**：新俱乐部需在管理端重新配置「游戏 → 分类 → 商品」后才能下单；手机插线后跑 `scripts/install-apps.ps1` 推装

**v0.1.0 主要功能全部落地**（2026-09-21，连续自主开发模式完成）：
- 阶段 1-13 ✅：环境/隔离/D盘/API配置 → Android 工程 → 双端框架 → 登录 → 权限 → 积分 → 游戏商品 → 媒体系统
- 订单体系 ✅：下单/抢单/70-30 结算/派单/超时/售后申诉
- 聊天系统 ✅：WS 全套（docs/07）+ 客服授权 + 三端 UI
- 排行榜与统计 ✅、安全加固与审计 ✅、部署（pm2/Tunnel/备份）✅
- 待办：真机统一测试（需 USB 授权）、pm2 开机自启/防火墙规则/域名（管理员权限）、TOTP（默认未做）、iOS（暂停）
- 每个阶段：运行验证 → 开发日志 → git commit；全量回归 run-all-tests.js（8 套件 190 项）

**v0.2.0 第二批需求（BUG修复+功能补全+UI升级）**（2026-09-21）：
- 修复：聊天管理 500/打手列表 400（pageSize）/排行榜空榜自动重算/消息历史 beforeSeq=0
- 单设备登录 ✅：后端强制（revoked=2 顶号/守卫/refresh 竞态/WS 握手+心跳校验）、三端全局踢出提示
- 等级系统 ✅：累计消费 5 级自动升级（只升不降）+ 管理端手动调级双重审计（admin:user:level）
- 好友系统 ✅：申请/同意/拒绝/删除/反向自动通过/搜索（中文 ID）/系统通知/WS 实时
- 中文 ID ✅：注册/修改（24h 限 3 次）/搜索/展示，后端统一校验
- 个人资料 ✅：头像/背景真实上传（归属+类型校验）/昵称/公开资料页
- 消息三栏 ✅：聊天（CS+好友会话列表）/好友/群组（预留空态）；好友会话共享 seq 流
- 论坛/社区 ✅ → **已于 2026-10-05 整体下线**（负责人要求"彻底删掉"）：动态/点赞/评论/管理端下架恢复等能力随
  后端 `forum` 模块、`/forum*` 与 `/admin/forum*` 路由、老板端/工作端论坛页、管理端「论坛管理」页一并删除；
  **数据库 `forum_*` 表与数据保留不删**（如需彻底清库须单独批准）
- 工作端收益 ✅：my-wallet（余额/累计收入/结算次数，流水聚合）
- 双端 UI 升级 ✅：首页参考图3（个人展示区/权益/功能入口）、我的页重构、我的订单/联系客服按钮修复、订单详情底卡（打手/结算信息）
- 性能 ✅：WS 全局单例、商品分页加载、图片缩略解码（cacheWidth）、接口并行化
- 全量回归：run-all-tests.js（11 套件）

**v0.3.0 批次（2026-09-22~23）**：
- 管理端治理 ✅：可注销/封号（自定义时长）/删除账号、商品删除无限制、超管所有者（is_owner）独占管理端账号管控
- 主题系统 ✅（仅老板端）：初始主题 + 液态玻璃，按账号持久化
- 小数金额 ✅：16 个金额字段 DECIMAL + 双端解析/展示（`parsePoints`/`fmtPoints`/`OrderBrief`），修复「小数金额导致订单页/钱包页整页崩溃」
- **云端更新（双端）✅**：启动自动检测 → 弹窗（普通可稍后/强制阻断）→ 下载进度 → sha256 校验 → 系统安装；能力在 `apps/packages/core/lib/src/update/`，两端各自 configure 通道（boss/worker），管理端按端上传与启停，发布走 `scripts/release-boss.js` / `release-worker.js`

## 规范位置（AI 每次开始工作前必须阅读相关规范）

- 数据库设计：docs/02-数据库设计.md；API：docs/03-API设计规范.md
- 认证与权限：docs/04-认证与授权规范.md；订单状态机：docs/05-订单状态机规范.md
- 积分账务：docs/06-积分账务规范.md；WebSocket：docs/07-WebSocket协议规范.md
- 媒体资源：docs/08-媒体资源规范.md；安全：docs/09-安全规范.md
- 迁移与备份：docs/10-数据库迁移与备份规范.md；部署：docs/11-部署与运维手册.md
- 测试：docs/12-测试规范.md；游戏扩展：docs/13-游戏扩展配置规范.md
- UI：docs/14-UI设计规范.md；组件与动画：docs/15-组件与动画规范.md
- 版本发布：docs/16-版本发布规范.md；故障处理：docs/17-故障处理规范.md
- UI 改版：docs/18-UI改版设计方案-v1.md、docs/19-东东电竞设计拆解.md（含分部定案）
- 功能选型与开源：docs/20-功能与开源选型.md（**图标库结论：第三方包普遍不可用，已改用 Flutter 内置 Material 图标**）
- 反 AI 味硬规范：docs/21-反AI味设计规范.md（禁止清单 + 6 条验收自检）
- 开发环境清单与恢复顺序：docs/22-开发环境清单.md（含 Gradle 缓存必设项）
- **验收报告（每次大改后更新）**：docs/23-验收报告.md
- 未决问题：docs/待确认事项.md（进入相关阶段前必须向负责人确认）

## 开发流程铁律（每次任务的标准执行顺序）

1. 读取相关 docs 规范与最近开发日志，确认当前阶段与影响范围
2. 制定最小计划，只做本阶段内容，禁止一次性铺开多个模块
3. 运行 + 测试 + 查日志/数据库 + 回归旧功能，确认未破坏之前功能
4. 更新 docs 与当日开发日志（完成内容/测试结果/问题/下一步/涉及文件/数据库与接口变化）
5. 汇报实际完成内容、测试结果、剩余问题；未运行不得说"测试通过"，未检查不得说"没有 Bug"

## 不卡死铁律（负责人 2026-10-03，最高优先，覆盖一切"等待/重试"习惯）

**任何环节一旦卡住（无输出、无响应、超时、等待被中断、命令挂起、端口无响应、构建/下载停住），禁止继续干等、禁止反复对同一个东西做同样的等待。立刻按顺序换路：**

1. **先判定**：卡住的是「工具等待」还是「真要长时间跑」。前者立即放弃等待；后者（构建/回归/下载）转后台任务，用**读文件/读日志**推进，不阻塞。
2. **换方案**：同一条路失败 ≤ 2 次就换手段 —— 换命令、换工具（grep/read/glob 替代 shell 管道）、换入口（HTTP 换 curl、直连换本地、本地换隧道）、换数据源（接口换数据库、日志换文件）。
3. **缩短等待**：任何命令显式给超时（默认 ≤ 120s，长任务才给 300s+）；禁止无超时命令、禁止 `| Tee-Object` 这类"等进程退出才收尾"的管道包长任务。
4. **后台任务只用非阻塞读取**：`job_output` 只在真正被阻塞时才 `wait`，且最长 60s；被中断即视为"没结果"，立即改读落盘日志文件或改用前台小命令推进，不再等同一个任务。
5. **降级交付**：一条路超过约 5 分钟仍无实质进展，先做能确定完成的部分，把卡点如实报给负责人，绝不为一个卡点停住整体进度。
6. 每次卡住都要在当日开发日志写一行：卡点、换的方案、结果（避免下次重复踩）。

## 不可违反的规则

- **开源照抄许可（负责人 2026-10-03，最高授权）**：本项目 UI/交互开发**允许完全照抄优秀开源项目**（布局、组件、动效、配色、结构均可直接借鉴或抄用），只需遵守其开源许可（MIT/Apache-2.0/BSD 可直接用；GPL 类仅可用于内部参考、不引入依赖）。遇到优秀实现优先"抄"，不要求自研，不为"看起来不像抄"而做无意义改造。
  - 已选型的开源方案：`flutter_miuix`（HyperOS 风格组件库，Apache-2.0）、`flutter_chat_ui`（聊天界面）、`liquid_glass_widgets`（曾因真机着色器问题弃用）
  - 照抄时仍需遵守：客户端数据不可信、三端设计语言统一（docs/14）、改完必须真机/真跑验证

- **发布铁律（负责人 2026-09-23，2026-09-23 扩至双端）**：每次**老板端或工作端** App 更新完，必须执行对应发布脚本把新版本推到它自己的云端更新通道——两端所有旧版用户打开 App 自动收到更新提示：
  - 老板端：`node scripts/release-boss.js <版本码> <版本名> "<更新说明>" [--force] [--install]`
  - 工作端：`node scripts/release-worker.js <版本码> <版本名> "<更新说明>" [--force] [--install]`
  - 两端通道相互独立（工作端只会收到工作端安装包）；同一端内版本码必须单调递增；忘记发布 = 视为未完成。

- 客户端数据全部不可信：价格/余额/身份/状态一律以服务器为准；主体 id 只从 JWT sub 取，绝不信任请求体/路径参数中的用户标识
- 余额变化必须写流水（前后余额快照）；扣款用事务 + 条件更新防负余额/防并发；幂等键唯一约束防重复提交
- 订单状态只能走 docs/05 合法迁移表，每次变化写 order_status_log；抢单/派单/超时回退用条件 UPDATE 判 affectedRows，禁 Redis 锁双源
- **管理员动作必须留痕**：管理端任何"会改变库内容"的接口，成功后必须写一条 `operation_log`（`admin_id`/`admin_name`/`module`/`action`/`method`/`path`/`request_body` 摘要/`request_id`/`result`），**只加留痕、不改权限与业务行为**；`request_body` 只记关键字段与变更前后摘要（**不记密码/token/密钥/超长原文**）。配置写入收口在 `SystemSettingService.update()` 一处（调用方传 `actor` 才有"谁改的"）→ 详见 docs/03「管理端写接口必须写 operation_log」
- **退款时战绩与钱包必须同步回退**：已结算订单退款（售后裁决 / 退款审批，同一实现 `adminRefundOrderTx`）在同一事务内既要冲正钱包（`settlement_reversal`/`platform_commission_reversal`/`order_refund`），也要把 `worker_stats` 退回（-1 单 / -1 完成 / - 原结算额）；榜单 `recalc` 必须排除已冲正结算 —— **只退钱不退战绩 = 打手战绩与名次永久虚高**（2026-10-06 真 bug）。详见 docs/06 第 7 条
- worker 接单/客服权限每次请求实时查库；权限用后端 RBAC，不能只靠前端隐藏
- 敏感信息（密码/密钥/Token）一律环境变量（server/.env.example、infra/.env.example），禁止硬编码
- 遇到影响架构/业务/安全/数据结构的不确定问题，先问项目负责人，可扩展方案先行并记录到待确认事项.md
- 修改代码前先了解现有实现，优先最小修改；无意义重构禁止

## 常用命令

- 一键启动：`npm run infra:start`；状态检查：`npm run infra:status`；停止：`npm run infra:stop`
- 数据库备份：`npm run db:backup`；恢复：`npm run db:restore`
- 提交（信息写文件避免中文损坏；多任务并行时用 `-Paths` 只提交指定路径，避免卷进无关产物）：`powershell -File scripts/tmp/commit.ps1 -MessageFile msg.txt [-Paths server/src/a.ts,CLAUDE.md]`
- 后端开发：`cd server && npm run start:dev`（Swagger http://localhost:3100/api-docs，端口见 server/.env）
- 管理后台：`cd admin-web && npm run dev`（http://localhost:5173）
- 客户端（模拟器）：`cd apps/boss-app && flutter run`
- 客户端（Android 真机，与电脑同一局域网）：`flutter run --dart-define=API_BASE_URL=http://<电脑局域网IP>:3100/api/v1 --dart-define=WS_BASE_URL=http://<电脑局域网IP>:3100`
- 公网地址（M9 隧道后）同样经 --dart-define 注入，禁止在代码中写死 localhost

## 发布三件套（缺一无法出包，2026-10-03 事故教训）

| 资产 | 位置 | 丢失后果 |
|---|---|---|
| Android SDK | `D:\Android\sdk`（JAVA_HOME 用 Android Studio 自带 `jbr`） | 构建直接失败 `No Android SDK found` |
| Dart/Flutter 依赖缓存 | `%LOCALAPPDATA%\Pub\Cache`（走 pub.flutter-io.cn 镜像） | 构建报 `Error when reading .../flutter_miuix-1.2.0/lib/miuix.dart`，`flutter pub get` 可重拉 |
| Android 签名密钥 | `%USERPROFILE%\.android\debug.keystore`，备份在 `data/backups/keys/fish-android-debug.keystore` | **已安装用户无法原位升级**（签名不符，只能卸载重装、丢本地数据） |

- 发布命令（铁律）：`node scripts/release-boss.js <码> <名> "说明" [--force] [--install]`；构建前需注入 `ANDROID_HOME=D:\Android\sdk`、`JAVA_HOME=C:\Program Files\Android\Android Studio\jbr`
- `--install` 的推装判定在部分 adb 版本下失效（`device\t` 匹配不到），必要时手动 `adb install -r -t <apk>`
