/// 平台共享包：设计 token、API 客户端、统一响应模型
library fish_core;

export 'src/api/api_cache.dart';
export 'src/api/api_client.dart';
export 'src/api/api_response.dart';
export 'src/api/media_uploader.dart';
export 'src/auth/auth_store.dart';
// 邮箱验证码 / 找回密码（2026-10-05 邮箱通道）：规则、文案、错误映射 + 两端共用的找回密码页
export 'src/auth/email_auth.dart';
export 'src/auth/forgot_password_page.dart';
// 邮箱绑定 / 换绑（2026-10-10 邮箱能力）：两态共用的一个页面（**当前密码 + 新邮箱验证码**），
// 老板端设置页进入；工作端账号同属平台账号（服务端 @Roles('user','worker')），将来零改动即可挂上。
export 'src/auth/email_bind_page.dart';
// 合并双端 · 身份切换（方案甲，负责人 2026-10-06 拍板）：身份模型、切换/解绑弹层、
// 打手态三屏（接单大厅 / 消息两段 / 我的）+ 底部导航外壳（3 项；有客服权限时 4 项）。
// 老板态页面一概不在此列。
export 'src/identity/worker_identity_models.dart';
export 'src/identity/identity_widgets.dart';
export 'src/identity/identity_switch_sheet.dart';
export 'src/identity/worker_chat_target.dart';
export 'src/identity/worker_hall_page.dart';
// 客服大厅（负责人 2026-10-08）：有客服权限的打手在打手态**主动接咨询**（抢占式，先到先得）
export 'src/identity/worker_cs_hall_page.dart';
export 'src/identity/worker_messages_page.dart';
export 'src/identity/worker_mine_page.dart';
// 打手简介（陪玩介绍）编辑弹层 —— 负责人 2026-10-17 改定「介绍让打手自己写」：
// 入口只在打手态「我的 › 个人介绍」；服务端 `PUT /worker/profile` 只对 role=worker 放行。
export 'src/identity/worker_intro_sheet.dart';
export 'src/identity/worker_orders_page.dart';
export 'src/identity/worker_wallet_page.dart';
export 'src/identity/worker_shell.dart';
// 打手态「通知栏提醒」（负责人 2026-10-15）：新单 / 客服·老板消息 → 系统通知（横幅+声音+震动）
// - **纯逻辑在 core**（判定门 / 事件解析 / 渠道常量 / 点击落点），平台能力（flutter_local_notifications）
//   由宿主 App 注入（`WorkerNotifier`），core 不依赖任何平台插件；
// - ⚠️ 没有接推送服务 → 只在 App 进程存活期间能到（划掉 App 就收不到），见 docs/30。
export 'src/notify/worker_notice.dart';
export 'src/notify/worker_notify.dart';
// 充值（余额）+ 管理员审核（负责人 2026-10-06 方案①②；2026-10-09 口径：余额，1 元 = 1 元）：
// - 合规铁律写在模型层：不接任何支付通道、收款码是**图片**、绝不出现"支付成功/自动到账"
// - 管理员态 = 受限会话，只做三件事（看待审核列表 / 发放余额 / 驳回），且**无底栏**
export 'src/recharge/recharge_models.dart';
export 'src/recharge/recharge_entry.dart';
export 'src/recharge/recharge_admin_shell.dart';
// 打手提现 + App 内提现审核（负责人 2026-10-11）：
// - 打手态：收款信息绑定/换绑（`withdraw_qr`）、提现申请（余额**立即扣除**）、提现记录三态；
// - 管理员态：与「充值审核」并列的第二段（`/withdraw/*`），收款码走**受保护媒体**取图，
//   打款**必须先上传支付记录截图**（`withdraw_proof`）并二次确认，驳回原因必填；
// - 提现链路禁用词（含旧计价单位「积分」）在 `WorkerWithdrawCopy.forbiddenWords`，测试逐屏扫描。
export 'src/withdraw/withdraw_models.dart';
export 'src/withdraw/withdraw_media.dart';
export 'src/withdraw/worker_withdraw_page.dart';
export 'src/withdraw/worker_withdraw_account_page.dart';
export 'src/withdraw/worker_withdraw_records_page.dart';
export 'src/withdraw/withdraw_review_page.dart';
export 'src/chat/chat_models.dart';
export 'src/chat/user_models.dart';
// 会话列表的**增量更新**（2026-10-15 聊天实时接收优化）：`msg:new` / `unread:update`
// 直接合进本地列表（不再为一条摘要重拉整个列表），未读仍以服务端权威值为准。
export 'src/chat/conversation_incremental.dart';
// 投诉口径（负责人 2026-10-05 任务②③）：可投诉订单状态清单 —— 后端
// server/src/modules/order/order-complaintable.ts 的镜像，仅用于拼查询参数，判定以后端为准
export 'src/complaint/complaint_rules.dart';
export 'src/models/order_brief.dart';
// 打手等级 + 升级进度（2026-10-17）：`/public/players`（三件套）、`/public/workers/:id`
// 与 `/worker/grade`（三件套 + 进度）**同一形状**的唯一解析出口。等级中文名一律由服务端下发，
// 客户端不写死；与老板端「会员」体系无关。
export 'src/models/worker_grade.dart';
export 'src/config/app_config.dart';
export 'src/config/app_config_runtime.dart';
export 'src/config/app_address.dart';
// 地址看门狗（2026-10-06 地址发现韧性）：运行中地址失效 → 自动重取 + 热切换，不需要重启 App
export 'src/config/address_watchdog.dart';
export 'src/config/app_settings.dart';
export 'src/realtime/realtime_client.dart';
export 'src/update/app_updater.dart';
// 分片下载纯逻辑层（分片计算/续传区间/进度速度聚合）——2026-10-06 云更新提速专项
export 'src/update/shard_plan.dart';
export 'src/update/update_center.dart';
export 'src/update/update_dialog.dart';
export 'src/update/update_block_page.dart';
export 'src/theme/app_colors.dart';
export 'src/theme/level_style.dart';
export 'src/theme/app_spacing.dart';
export 'src/theme/app_theme.dart';
export 'src/theme/theme_mode.dart';
export 'src/theme/theme_tokens.dart';
export 'src/theme/theme_controller.dart';
export 'src/theme/nav_style_controller.dart';
export 'src/theme/theme_colors.dart';
export 'src/util/idempotency.dart';
// 实时事件合并窗口（2026-10-15 聊天实时接收优化）：200ms 内的连续事件 → 一次 UI 更新
export 'src/util/event_coalescer.dart';
// 服务端时间探测（2026-10-06 工作端到期自动阻断专项）：读 HTTP Date 头，取不到返回 null
export 'src/util/network_time.dart';
// 页面底渐变（负责人 2026-10-17）：白 + 极浅品牌蓝的自创渐变，**只铺页面底**。
// 全站唯一的 `LinearGradient` 消费点；卡片/按钮/主视觉区仍然一律实色（docs/21）。
export 'src/widgets/app_page_bg.dart';
export 'src/widgets/placeholder_page.dart';
export 'src/widgets/session_kick_listener.dart';
export 'src/widgets/app_avatar.dart';
export 'src/widgets/app_icon.dart';
// 双色实底图标块（方案 F「渐变圆角方块 + 白色镂空图标」）+ 功能区色相绑定：
// `AppIconTile` / `AppTabGlyph` / `AppFeature` / `featureHue|featureGradient|featureOfIcon`。
// 新增于 2026-10-16 配色落地（本轮唯一新增的对外 API），既有导出一个未动。
export 'src/widgets/app_icon_tile.dart';
export 'src/theme/feature_hues.dart';
export 'src/widgets/app_motion.dart';
export 'src/widgets/app_toast.dart';
export 'src/widgets/app_ui.dart';
// 打手等级徽章（2026-10-17）：`gradeBadgeIcon` / `gradeInk` / `WorkerGradeBadge` 三件套的
// **唯一实现** —— 找陪玩列表卡、陪玩主页、打手态「我的」共用，图标跑 `AppIcons.grade1..5`
// （由 `scripts/tmp/gen-app-icons.mjs` 从 `assets/grade/*.svg` 编译，零 flutter_svg）。
export 'src/widgets/grade_badge.dart';
// 通用空态（方案 G 视觉版，负责人 2026-10-17）：新增类 `AppEmptyState`，旧 `AppEmpty`
// 一行未动 —— 既有调用点渲染不变；G 版页面显式改用它即可（参数是 AppEmpty 的严格超集）
export 'src/widgets/app_empty.dart';
// 详情页通用块（负责人 2026-10-05 商品详情页 v2 方案 B）：折叠行 / 三列数据行 / 提示条 /
// 条款列表 / FAQ / 空态主图位 —— 取值与设计稿 b-restrained.html 逐值对齐
export 'src/widgets/app_detail_blocks.dart';
// 商品徽标（「董事长推荐」这类，管理端 badgeText 可配）+ 每周限购提示行（负责人 2026-10-05：
// 徽标文案/限购数/提示文案一律服务端下发，客户端只展示、不硬编码规则）
export 'src/widgets/product_badge.dart';
// 登录/注册改版（方案 B「品牌主视觉」）共用组件：品牌头 / filled 输入框 / 主按钮 / 协议勾选
export 'src/widgets/auth_widgets.dart';
export 'src/widgets/form_errors.dart';
// 上传进度条（2026-10-06 上传体验专项）：百分比 + 速度 + 已传/总大小 + 慢网提示 + 中文可重试
export 'src/widgets/media_upload_tile.dart';
export 'src/widgets/qishan_mark.dart';
// 首页宣传图轮播（负责人 2026-10-05 任务②，方案 C 顶部通栏沉浸）：PageView + 指示器 +
// 空态零占位 + linkType 分发；数据来自 GET /public/banners（visible=1 且落在投放时间区间内）
export 'src/widgets/home_banner_carousel.dart';
export 'src/widgets/cached_image.dart';
export 'src/widgets/game_icon_tile.dart';
export 'src/widgets/app_nav.dart';
export 'src/widgets/glass_surface.dart';
export 'src/widgets/glass_backdrop.dart';
// 品牌装饰系统（负责人 2026-10-15「全平台品牌化」；规范 docs/45，设计稿 site/design/brand-deco/）
//
// 内核：**一套装饰 = 一条 45° 刀口 + 一张 4dp 网格 + 三档尺度的色彩用量**。
// 斜切角尺寸**只由高度推导**（高度÷4 → 最接近的 4/6/8，并列取大），全模块零手挑档位 ——
// 这是让这套语言成体系的不变量：手挑一次，以后每条分支都会挑自己觉得顺眼的那个数。
//
// 导出时机说明：本文件由负责人指派在「入口耦合批次 / 两个页面 A 套 / 装饰地基」三路全部停手后
// 统一添加（并行改同一行会撞车）。装饰地基本身（deco.dart）当时刻意未改本文件。
//
// ⚠️ 含 `AppLevelSlot`（等级预留位）：按负责人 2026-10-15「后期我会给打手加等级，等我想好名称告诉你」，
//    **只锁几何位（高 20 × 最长 72 · 与名字间距 8dp），不画形态、不起名字**。
export 'src/widgets/deco.dart';
export 'src/utils/image_sniff.dart';
