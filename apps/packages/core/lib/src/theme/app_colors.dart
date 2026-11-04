import 'package:flutter/material.dart';

/// 设计 Token 色板（docs/14 + docs/21）
///
/// ## 2026-10-16「方案 F · 潮玩」配色落地（负责人定案：**只改配色，不动布局/结构**）
///
/// 品牌色族整体换成 `site/design/color-graphics/planF.html`（16 屏出图稿）的**实测色值**：
/// 主渐变 `#2563EB → #06B6D4` · 紫 `#8B5CF6` · 橙金 `#F59E0B` · 粉 `#F472B6` ·
/// 绿 `#10B981` · 青 `#06B6D4` · 页底白 · 分区浅底 `#EFF6FF` / `#ECFEFF` · 描边 `#E9EEF5`。
///
/// **既有 token 名一个不删**（全仓调用点太多，删名会连锁断裂）；
/// 语义不变的正文/描边/底保留原值或按 F 表微调。
///
/// ### 强调色是**语义绑定**的（F 稿实测，实施时一律按下表取色，不许随机用色）
/// | 语义 | token | F 实测值 |
/// |---|---|---|
/// | **资金 / 价格 / 余额** | [gold]（大字 ≥19px）· [goldText]（小字） | `#F59E0B` / `#935F06` |
/// | **客服** | [accentSupport] | `#06B6D4` |
/// | **AI（祁小山）** | [accentAi] | `#8B5CF6` |
/// | **安全 / 担保 / 在线** | [accentSafe] · [success] | `#10B981` |
/// | **活动 / 榜单热度** | [accentPink] | `#F472B6` |
/// | **品牌主色 / 可操作** | [primary] | `#2563EB` |
///
/// 规则：
/// - 主色用**实色** `primary`；渐变 [brandGradient] 只用于有限的强调场景（主按钮/浮标/横幅）
/// - 价格与等级用**橙金** [gold]
/// - **每枚 token 上方都有一行理由注释**（本仓库规范：每个颜色都要能说出理由）
class AppColors {
  AppColors._();

  // ============ 基础（保留旧命名，值按方案 F 更新）============

  /// 主色（实色，用于按钮/选中/强调）
  ///
  /// `#2563EB`：方案 F 主色（planF.html 实测出现 **130 次**，全稿最高频），
  /// 也是主渐变 `#2563EB → #06B6D4` 的起点；白底对比度 **5.17:1**（≥ WCAG AA 正文 4.5:1），
  /// 按钮上的白字同样 **5.17:1**。
  static const Color primary = Color(0xFF2563EB);

  /// 品牌锚（墨蓝）—— **只给极小面积**用：字标底 / 等级徽章边 / 5% 水印。
  ///
  /// 方案 F 稿**没有定义墨色**（F 是亮色潮玩体系），故本值**保留**：
  /// 它只出现在品牌水印（5% 不透明度）与字标头像（占壳 ≤1.5%）两处，
  /// 不参与主视觉，改动收益为零、风险（出图/像素用例）为正。
  static const Color brandInk = Color(0xFF0F2440);

  /// 辅助主色 / **客服青**（次级强调；主渐变的另一端）
  ///
  /// `#06B6D4`：方案 F 青（62 次）。**语义 = 客服 / 在线服务**（F 稿「客服 24h」胶囊即
  /// `#ECFEFF` 底 + `#0891B2` 字 + 本色的 `ic-headset`），与「客服=青」绑定，不得挪作他用。
  static const Color primarySecondary = Color(0xFF06B6D4);

  /// 页面背景
  ///
  /// `#FFFFFF`：方案 F **页底就是纯白**（`.phone{background:#fff}`），卡片靠
  /// 1px 描边 [divider] `#E9EEF5` + 轻阴影区分（`.card{background:#fff;border:1px solid #E9EEF5}`），
  /// 不再用深一档的页底衬托白卡 —— 因此本值由 `#F4F6F9` 改为白。
  /// 分区浅底另见 [ice] `#EFF6FF` 与 [accentSupportSoft] `#ECFEFF`。
  static const Color bgPage = Color(0xFFFFFFFF);

  /// 卡片/表面
  ///
  /// F 的卡片也是纯白，与页底同色、由描边分界 —— 保持 `#FFFFFF`。
  static const Color bgCard = Color(0xFFFFFFFF);

  // ============ 页面底渐变三档（负责人 2026-10-17 定案）============
  //
  // 负责人原话：「背景的渐变色呢咋没做……白色 + 另一种，主题还是白，另一种要浅，看上去总体要顺眼」。
  // 参考的是**渐变的方向感与层次感**（左上亮、右下微微着一层色），配色自创 —— 不复用参考 App 的任何色值。
  //
  // 为什么只有三档、且只到 `#EFF6FE`：
  // - 这是**页面底**，不是主视觉。渐变只负责"整页不是一块死白"，一旦对比度起来就会抢内容、
  //   也会让白卡浮不起来（本仓卡片恒为纯白，见 [bgCard]）。
  // - 三档 = 起点 / 中点 / 终点，是 LinearGradient 表达"两段式过渡"的最小档数：
  //   中点 [bgWashMid] 让上半屏基本还是白（内容最密的地方），色只在右下角缓缓压上来。
  //
  // 为什么选**浅蓝**而不是浅金 / 浅粉：品牌蓝 [primary] 是本项目唯一强调色，
  // 取它的约 5% 明度当底最"顺眼"，且与价格金 [gold] 不打架（金做底会让整页发黄）。

  /// 页面底渐变 · **起点**（左上）
  ///
  /// `#FFFFFF` 纯白：与 [bgPage]、[bgCard] 同值 —— 页面顶部（页头/主视觉下方的第一屏）
  /// 看上去就是白的，换主题、换页面都不需要用户重新适应。
  static const Color bgWashTop = Color(0xFFFFFFFF);

  /// 页面底渐变 · **中点**（约 45%）
  ///
  /// `#FBFDFF`：比纯白低 1.6% 明度、只往蓝偏 2 点 —— 肉眼几乎读不出"有色"，
  /// 但足以让整页在中段开始有过渡，避免"上半纯白、下半突然有色"的两段感。
  static const Color bgWashMid = Color(0xFFFBFDFF);

  /// 页面底渐变 · **终点**（右下）
  ///
  /// `#EFF6FE`：品牌蓝 [primary] `#2563EB` 的极浅着色调（与 [ice] 同族、更偏白一档）。
  /// **这是全站页底允许出现的最深值** —— 再深一档白卡就浮不起来、渐变也会开始抢内容。
  static const Color bgWashBottom = Color(0xFFEFF6FE);

  // ── 打手等级徽章：五档同色系三层（负责人 2026-10-18「等级太朴素，弄好看点」）──
  //
  // 每档 = 淡底(bg) + 深字(ink) + 图标(icon)。三层**同一色系、只差明度**，
  // 靠"淡底承托 + 深字压住"做出质感，**不用渐变**（反 AI 味红线）。
  //
  // 为什么五档各用一个色系而不是同一色深浅：
  //   等级要能被**一眼分辨**（列表里扫一眼就知道谁高谁低），
  //   同一色系只改深浅，在小尺寸徽章上根本看不出来 —— 灰/青/蓝/紫/金 五色递进，
  //   从"无色"走到"金色"，语义上就是"从起步到顶级"。
  //
  // 可读性：ink 一律取深色（各色系 700 号位），白底/淡底上均 ≥ 4.5:1。

  /// LV1 初出 · 灰阶（起步档不抢眼）
  static const Color grade1Bg = Color(0xFFF1F3F7);
  static const Color grade1Ink = Color(0xFF5A6879);
  static const Color grade1Icon = Color(0xFF8492A4);

  /// LV2 立足 · 青绿（开始有"角色感"）
  static const Color grade2Bg = Color(0xFFE6F7F2);
  static const Color grade2Ink = Color(0xFF0E7A5F);
  static const Color grade2Icon = Color(0xFF14A37F);

  /// LV3 扬名 · 蓝（与品牌主色同族，但更沉，避免与按钮抢）
  static const Color grade3Bg = Color(0xFFE8F0FE);
  static const Color grade3Ink = Color(0xFF1E4FA8);
  static const Color grade3Icon = Color(0xFF2E6BE0);

  /// LV4 称雄 · 紫（明显高于前三档的"稀有"信号）
  static const Color grade4Bg = Color(0xFFF1EAFE);
  static const Color grade4Ink = Color(0xFF5B2FA8);
  static const Color grade4Icon = Color(0xFF7C4DE0);

  /// LV5 宗师 · 金（最高档，唯一带描边的一档）
  static const Color grade5Bg = Color(0xFFFDF3E0);
  static const Color grade5Ink = Color(0xFF935F06);
  static const Color grade5Icon = Color(0xFFC98A0E);
  static const Color grade5Border = Color(0xFFE8C07A);

  /// 主要文字（近黑蓝）
  ///
  /// `#14202E` 与方案 F 正文色**逐值相同**（planF `body{color:#14202E}`），保留。
  /// 白底对比度 **16.5:1**（旧冷灰蓝页底上是 15.2:1 → 换底后**上升**）。
  static const Color textPrimary = Color(0xFF14202E);

  /// 次级文字
  ///
  /// `#4A5A6E` 与方案 F 次要文字**逐值相同**，保留。
  /// 白底对比度 **7.05:1**（旧页底 6.5:1 → 换底后**上升**），远超 AA 4.5:1。
  static const Color textSecondary = Color(0xFF4A5A6E);

  /// 辅助文字/占位（**图标/分隔/装饰**用色）
  ///
  /// `#94A3B8`：白底对比度仅约 **2.56:1**，**不达正文 4.5:1** —— 这正是它只服务
  /// 图标/发丝线/禁用态的原因；白底上的**说明文字**请用 [mutedText]。
  /// 方案 F 里这一档同样是 `#94A3B8`（另有更弱的 `#8A99AB` 见 [textPlaceholder]），故保留。
  static const Color textTertiary = Color(0xFF94A3B8);

  /// 白/浅底上的**正文、说明文字与输入框占位符**
  ///
  /// `#4A5A6E`：与白底对比度 **7.05:1**（远超 WCAG AA 正文 4.5:1），与方案 F 次要文字同值。
  /// 与 [textPrimary] 一起构成「标题 → 正文 → 说明」三级。
  ///
  /// **用途边界（负责人 2026-10-06 统一裁决，本轮不变）**：
  /// - 用 `mutedText`：白/浅底上的**正文、说明条、副标题、事实行、输入框 hint 占位符**；
  /// - 用 [textTertiary]：**图标、发丝线、禁用态**（那里不需要 4.5:1）。
  static const Color mutedText = Color(0xFF4A5A6E);

  /// 成功
  ///
  /// `#10B981`：方案 F 绿（21 次），**语义 = 成功 / 安全 / 在线**（与 [accentSafe] 同值）。
  /// 由旧青瓷 `#0E7C7B` 改来：青瓷**不在 F 调色板内**，留着它就是留一个"体系外的颜色"。
  /// 白底对比度 **2.54:1** —— 它只在**实色底/浅底标签**上承载白字或深字（不作白底正文）。
  static const Color success = Color(0xFF10B981);

  /// 警告
  ///
  /// `#B45309` 与方案 F **逐值相同**（F 用 14 次），保留；白底对比度 **5.02:1**（达 AA）。
  static const Color warning = Color(0xFFB45309);

  /// 错误
  ///
  /// `#B42318` **保留原值**：方案 F 的红是 `#EF4444`，但它白底只有 **3.76:1**
  /// （**不达 WCAG AA 正文 4.5:1**），而错误色大量用于白底正文。
  /// 质量优先于色相统一 → 保留 `#B42318`（白底 **6.60:1**），在报告里如实登记为"未跟 F"。
  static const Color error = Color(0xFFB42318);

  /// 分割线 / 描边
  ///
  /// `#E9EEF5`：方案 F 的**唯一发丝线色**（26 次；F 的卡片描边、底栏上边线、输入框描边、
  /// 消息页分隔全用它）。由 `#E3E8EF` 改来，全站描边从此只有一档。
  static const Color divider = Color(0xFFE9EEF5);

  // ============ 品牌扩展（方案 F 更新）============

  /// 冰蓝浅底（页面顶部渐隐 / 浅色信息条 / 分区浅底·蓝）
  ///
  /// `#EFF6FF`：方案 F 的蓝浅底（19 次，F 里 `#2563EB` 的胶囊底一律用它）。
  static const Color ice = Color(0xFFEFF6FF);

  /// 主色浅底（选中底 / 浅色标签底）
  ///
  /// `#EFF6FF` 与 [ice] 同值 —— 两者都是"主色浅底"这一个语义，
  /// 分名只是为了让存量调用点各取所需（删任一个都会连锁断调用）。
  static const Color primarySoft = Color(0xFFEFF6FF);

  /// 价格 / 等级 / 榜单数值 / **资金** —— **大号金额专用金**（小字一律用 [goldText]）
  ///
  /// `#F59E0B`：方案 F 橙金（71 次，全稿第二高频）。F 稿的金额有两态：
  /// ① 实色底胶囊 `background:#F59E0B` + 白字；② 白底大字 `color:#F59E0B`（23px/19px w800）。
  ///
  /// ⚠️ **白底仅 2.15:1**（不达 WCAG AA 正文 4.5:1，也不达大字 3:1）——
  /// 这是 F 的设计意图（大字靠尺寸与字重立住），**保留不变**。
  /// 但**小字（<19px 或字重 < w700）必须走 [goldText]**，否则白天在手机上读不清；
  /// 该规则由 `core/test/money_gold_guard_test.dart` 的**源码级红线**守着，不靠注释。
  static const Color gold = Color(0xFFF59E0B);

  /// **[小字金]** 小字 / 标签 / 单位 / 次要金额专用 —— `#935F06`
  ///
  /// 与 [gold] **同一支橙金**：色相 37.7°、饱和 92% 逐项相同，只把明度 50% → 30%
  /// —— 由 `#F59E0B` 机械推导而来，**不引入第二个色相**（不是"另一支金"）。
  ///
  /// 实测对比度（WCAG 2.x 相对亮度，node 复算，守卫用例逐底断言）：
  ///
  /// | 底 | 白 `#FFFFFF` | 分区浅底 `#EFF6FF` | 琥珀浅底 `#FEF3C7` |
  /// |---|---|---|---|
  /// | `#935F06` | **5.41:1** | **4.97:1** | **4.86:1** |
  /// | （对照 `#F59E0B`） | 2.15:1 | 2.03:1 | 1.98:1 |
  ///
  /// 三底**全部 ≥ WCAG AA 正文 4.5:1**。用途：`<19px` 或字重 `< w700` 的**一切"金"字**
  /// （价格小字、单位、次要金额、等待超时提示、评分值、榜单金额、行内金额），
  /// 以及**字号 <19px 的金色图标**（图标同属"小字可读性"问题）。
  static const Color goldText = Color(0xFF935F06);

  /// 琥珀浅底（进度条槽 / 等级底 / 价格提示条底）
  ///
  /// `#FEF3C7`：方案 F 的琥珀浅底（8 次），与 [gold] 同族；
  /// [goldText] 压在这张底上实测 **4.86:1**（[gold] 只有 1.98:1）。
  static const Color goldSoft = Color(0xFFFEF3C7);

  /// 状态：在线 / 成功（绿）
  ///
  /// 与 [success] 同值 `#10B981`（F 绿）—— 在线与成功共用一个语义，不做第二个绿。
  static const Color statusOnline = Color(0xFF10B981);

  /// 状态：在线 / 成功的浅底
  ///
  /// `#DCFCE7`：方案 F 绿浅底（4 次）。
  static const Color statusOnlineSoft = Color(0xFFDCFCE7);

  /// 状态：忙碌 / 待处理（琥珀深一档，白底可读）
  ///
  /// `#B45309` 与方案 F 同值，保留（F 里也是"深琥珀字"这一档）。
  static const Color statusBusy = Color(0xFFB45309);

  /// 状态：忙碌 / 待处理的浅底
  ///
  /// 与 [goldSoft] 同值 `#FEF3C7` —— 琥珀浅底只有一个，不做第二档。
  static const Color statusBusySoft = Color(0xFFFEF3C7);

  /// 状态：警示 / 已结束（灰）
  ///
  /// `#8A99AB` 与方案 F 弱化文字**逐值相同**（F 用 119 次），保留。
  static const Color statusMuted = Color(0xFF8A99AB);

  /// 状态：警示 / 已结束的浅底（冷灰）
  ///
  /// `#F1F4F8` 保留：F 稿的等价档是 `#F1F5FA`，两者 ΔRGB=(0,1,2)，肉眼不可分，
  /// 而本值被出图/快照用例逐值断言 → 不动（避免"改颜色 = 改测试期望"）。
  static const Color statusMutedSoft = Color(0xFFF1F4F8);

  /// 弱化文字（辅助说明 / 占位 / 元信息行）
  ///
  /// `#8A99AB`：方案 F 的"弱"档（F 用 119 次，与提案表一致）。白底对比度 **2.91:1**，
  /// 定位是**不可读性优先的元信息**（介绍待补充、评价时间、来源小字），要读的正文走 [mutedText]。
  static const Color textPlaceholder = Color(0xFF8A99AB);

  /// 冷描边（非分割线）—— 控件/空框的可见轮廓
  ///
  /// `#CDD6E2`：比 [divider] 深一档（divider = 行与行之间的发丝线；hairline = 控件轮廓、
  /// 未选中格描边、预留虚框）。保留原值（被快照用例断言）。
  static const Color hairline = Color(0xFFCDD6E2);

  /// 页头衬底 / 骨架条底（冷灰蓝 `#F1F4F8`）
  ///
  /// **只给「区块级浅底」**（打手主页头部网格场、骨架条底色），不是页底 [bgPage] 的替代。
  /// 保留原值（被出图用例断言）。
  static const Color fieldBg = Color(0xFFF1F4F8);

  /// 禁用态底（不可点的输入/按钮）
  ///
  /// `#E9EDF4` 收口而来（原先 auth_widgets 与身份切换弹层各写一次字面量）——
  /// 比 [fieldBg] 深半档、比 [hairline] 浅，是"看得见但明确不可用"的那一档灰。
  static const Color disabledBg = Color(0xFFE9EDF4);

  /// 图片/内容**占位底**（空图位、骨架块、待载入缩略图）
  ///
  /// `#F1F5FA`：方案 F 的高频浅中性底（57 次）。原先全仓散着 4 个近似字面量
  /// （`#EDF1F7` / `#EDF0F4` / `#F2F4F8` / `#E8EAF0`）—— 现在只有一个。
  static const Color placeholderBg = Color(0xFFF1F5FA);

  /// 面板**拖拽把手**（底部弹层顶部那根 2dp 短横）
  ///
  /// `#DDE3EC` 收口而来（充值审核 / 身份切换 / 提现三处各写一次）。
  static const Color dragHandle = Color(0xFFDDE3EC);

  // ============ 六个强调色（方案 F 语义绑定，planF.html 实测）============

  /// **资金**（余额 / 充值 / 提现 / 结算额）
  ///
  /// `#F59E0B`：与 [gold] 同值 —— F 稿里"钱"只有一个颜色，
  /// 分名是为了让调用点直接读出用途（`accentMoney` 出现在账务页，`gold` 出现在价格位）。
  /// **小字资金同样走 [goldText]**（大字才用本值）。
  static const Color accentMoney = Color(0xFFF59E0B);

  /// **AI（祁小山）** —— 紫色
  ///
  /// `#8B5CF6`：方案 F 紫（54 次）。F 稿里 AI 位的图标底一律是
  /// `linear-gradient(135deg,#8B5CF6,#A78BFA)`（`ic-bot` 那枚），配上「祁小山 AI」字样。
  static const Color accentAi = Color(0xFF8B5CF6);

  /// AI 浅底（AI 说明条 / AI 推荐位底）
  ///
  /// `#F5F3FF`：方案 F 的紫浅底（6 次）。
  static const Color accentAiSoft = Color(0xFFF5F3FF);

  /// **客服** —— 青色
  ///
  /// `#06B6D4`：与 [primarySecondary] 同值。F 稿里"客服 24h"胶囊是
  /// `#ECFEFF` 底 + `#0891B2` 字 + `ic-headset`，深底版本是 `#06B6D4 → #22D3EE` 渐变。
  static const Color accentSupport = Color(0xFF06B6D4);

  /// 客服浅底（客服入口底 / 青分区浅底）
  ///
  /// `#ECFEFF`：方案 F 的青浅底（10 次），同时也是 F 的"分区浅底·青"。
  static const Color accentSupportSoft = Color(0xFFECFEFF);

  /// **安全 / 担保 / 平台保障** —— 绿色
  ///
  /// `#10B981`：与 [success] 同值。F 稿里 `ic-shield`（平台担保 / 安全）底是
  /// `#10B981 → #22D3EE` 渐变，保障说明条用绿浅底。
  static const Color accentSafe = Color(0xFF10B981);

  /// 安全浅底（保障条 / 已担保标底）
  ///
  /// `#DCFCE7`：方案 F 绿浅底（4 次）。
  static const Color accentSafeSoft = Color(0xFFDCFCE7);

  /// **活动 / 榜单热度** —— 粉色
  ///
  /// `#F472B6`：方案 F 粉（12 次）。F 稿里榜单/热度条与"限时"胶囊用它
  /// （`linear-gradient(135deg,#F472B6,#F59E0B)` 那枚 `ic-trophy`）。
  static const Color accentPink = Color(0xFFF472B6);

  /// 粉浅底（活动标签底 / 粉分区浅底）
  ///
  /// `#FDF2F8`：方案 F 的粉浅底。
  static const Color accentPinkSoft = Color(0xFFFDF2F8);

  // ============ 状态：异常/售后（红浅底）============

  /// 状态：异常/售后（红浅底）
  ///
  /// `#F7E7E5` 保留：F 没有定义红浅底，而本值被出图/快照用例断言
  /// （`order_review_section` 的"否"选项底、订单状态标签「异常」底）。
  static const Color dangerSoft = Color(0xFFF7E7E5);

  // ============ 订单状态标签的描边与中性底 ============
  //
  // 命名口径：`status*` = 订单/售后状态标签族专用；`*Border` = 1px 描边（浅档），
  // `*Bg` = 浅底。**只用于状态标签，不用于大面积背景**。

  /// 状态：待处理/警告 的浅描边（与 [warning] `#B45309` 同族、亮度更高）
  static const Color statusWarnBorder = Color(0xFFE6CFAE);

  /// 状态：正常/完成 的浅描边（与 [success] 绿 `#10B981` 同族）
  ///
  /// 由 `#BCD9D7`（青瓷族）改为 `#A7F3D0`：本 token 的注释契约是"与 [success] 同族"，
  /// 而 [success] 已按方案 F 换成绿 `#10B981` —— 不改就是"绿字配青瓷描边"的撞色。
  static const Color statusOkBorder = Color(0xFFA7F3D0);

  /// 状态：中性（待接单/进行中等无情绪档）的浅底
  ///
  /// `#F0F2F5` 保留：让标签从白卡上浮起一格，既不等于白、也不到 [fieldBg] 那么实。
  /// 被 `order_status_tag_test` 逐值断言。
  static const Color statusNeutralBg = Color(0xFFF0F2F5);

  /// 状态：中性档的 1px 描边（与 [statusNeutralBg] 配套）
  static const Color statusNeutralBorder = Color(0xFFD8DEE6);

  /// 状态：失败/驳回 的浅描边（与 [error] 同族）
  static const Color statusBadBorder = Color(0xFFE7C6C2);

  /// 状态：售后中 的浅描边（比 [statusBadBorder] 更沉一档，与"失败"可区分）
  static const Color statusAfterSaleBorder = Color(0xFFD8A9A3);

  // ============ 提示条三件套（浅底 + 同色描边 + 同色深字）============
  //
  // 为什么收这一族：身份页/充值页/提现页的错误提示条原先各自写字面量，
  // `identity_widgets.dart` 里还专门留了注释说"token 里没有对应值，只能写死"。
  // 现在补齐 —— 提示条从此只有"四档色调"，逐处字面量归零。

  /// 提示条：错误档浅底（与 [error] 同族）
  static const Color bannerDangerBg = Color(0xFFFDECEC);

  /// 提示条：错误档描边
  static const Color bannerDangerBorder = Color(0xFFF3C4C4);

  /// 提示条：错误档明细文字（比 [error] 浅半档，用于第二行小字）
  static const Color bannerDangerInk = Color(0xFF8C3A3A);

  /// 提示条：警告档浅底（与 [warning] `#B45309` 同族）
  static const Color bannerWarnBg = Color(0xFFFFF4EC);

  /// 提示条：警告档描边
  static const Color bannerWarnBorder = Color(0xFFF6D3B8);

  /// 提示条：警告档明细文字
  static const Color bannerWarnInk = Color(0xFF8A4A21);

  /// 提示条：信息档描边（浅底走 [ice] `#EFF6FF`，字走 [primary]）
  static const Color bannerInfoBorder = Color(0xFFCCE0FB);

  /// 提示条：信息档明细文字（比 [primary] 浅半档）
  static const Color bannerInfoInk = Color(0xFF3A5A99);

  /// 提示条：成功档浅底
  static const Color bannerOkBg = Color(0xFFF1FBF4);

  /// 提示条：成功档描边（与 [success] 绿同族）
  static const Color bannerOkBorder = Color(0xFFBFE7CC);

  /// 提示条：成功档前景（深绿，白底可读）
  static const Color bannerOkInk = Color(0xFF15803D);

  /// 提示条：成功档明细文字（再浅半档）
  static const Color bannerOkDetail = Color(0xFF3D6B4C);

  // ============ 身份标签 ============

  /// 中性身份标签底（「当前身份：老板」，17dp / r4 / 10.5sp w700 / `textSecondary` 字）
  ///
  /// 为什么是中性灰而不是主色：这枚标签是**只读事实**（你现在是谁），
  /// 主色留给"可操作"（切换入口、选中态）——docs/21「蓝=可操作，灰=事实」。
  static const Color tagNeutralBg = Color(0xFFF1F4F8);

  /// 中性身份标签描边（1px，与 [tagNeutralBg] 配套）
  static const Color tagNeutralBorder = Color(0xFFCDD6E2);

  // ============ 方案 G 首页 / 分类页专用（`site/design/ref-video/planG-all.html` 实测色值）============
  //
  // 为什么单开这一组而不是复用既有 token：方案 G 的首页/分类页两屏对这几个色是**逐值指定**的，
  // 而色板里没有同值项（例如描边稿内是 `#E8ECF2`，色板唯一发丝线是 `#E9EEF5`）。
  // 直接把 `Color(0x…)` 写进页面会踩 `page_deco_services_orders_test` 的
  // 「硬编码色值 0」源码红线（该红线只允许色板取色），因此一律收进色板 ——
  // 这同时也满足仓库规范「每个颜色都要能说出理由」。

  /// **方案 G 页底**（`#F6F7F9`）
  ///
  /// 稿内 `body` 的画面底。与 [bgPage] `#FFFFFF` 不同值：G 要让**纯白卡片浮在微灰底上**，
  /// 卡片轮廓才看得出来；纯白底 + 纯白卡会只剩 1px 描边当边界证据，观感糊成一片。
  ///
  /// ⚠️ **2026-10-17 收口补**：此前 6 个页面（登录/我的/排行榜/公告/接单大厅/提现）
  /// 各自写了 `const Color _pageBg = Color(0xFFF6F7F9)` —— 并行改动的几路互相不知道对方也在用这个色。
  /// 现统一收敛到本 token（各文件保留私有常量名当**别名**，调用点零改动）：
  /// 以后调页底色只改这一处，不会再出现"改了一屏忘了其它五屏"。
  static const Color bgPageG = Color(0xFFF6F7F9);

  /// 入口·**投诉客服**（绿 `#0E9F6E`）
  ///
  /// 稿内 `ic-headset` 的图标色。与 [success] `#10B981` 不同值：G 稿这一枚是偏松针的绿，
  /// 只用于「投诉客服」入口图标，不参与状态语义（状态绿仍是 [success]）。
  static const Color entrySupport = Color(0xFF0E9F6E);

  /// 入口·**打赏**（橙金 `#C2760B`）
  ///
  /// 稿内 `ic-gift` 的图标色。比 [gold] `#F59E0B` 深一档，白底 4.63:1（达 AA 正文）——
  /// 它是**图标 + 少量文字**用色，不是金额主色（金额仍走 [gold]/[goldText]）。
  static const Color entryTip = Color(0xFFC2760B);

  /// 入口格 / 商品卡的 **1px 描边**（`#E8ECF2`）
  ///
  /// 稿内 `.entry` / `.gcard` 的 border。与 [divider] `#E9EEF5` 相差 ΔRGB=(1,2,3)，
  /// 肉眼看不出，但稿子是逐值定案的 → 单独留一个 token 以免"实现看起来没照稿"。
  static const Color strokeSoft = Color(0xFFE8ECF2);

  /// 滚动播报条**底**（`#FFFBEB`）
  ///
  /// 稿内 `.ticker`。极浅琥珀 —— 它表达"平台公告"的语气比纯白暖一档，
  /// 又不至于和 `goldSoft` 抢（那是价格提示条底）。
  static const Color tickerBg = Color(0xFFFFFBEB);

  /// 滚动播报条**文字/图标**（`#8A5A00`）
  ///
  /// 压在上面那张 `#FFFBEB` 底上实测 **5.62:1**（达 WCAG AA 正文 4.5:1）。
  static const Color tickerInk = Color(0xFF8A5A00);

  /// **选中**筛选胶囊底（`#111827`）
  ///
  /// 稿内 `.pill.on`。注意这是本项目唯一允许的"近黑"底 —— 只用于**选中的胶囊**
  /// （面积小、白字对比 16.6:1），不用于正文/大块背景（docs/21「纯黑配纯白」禁项指的是大面）。
  static const Color chipInk = Color(0xFF111827);

  /// 商品卡**卡头**淡蓝底（`#EEF4FC`）
  ///
  /// 稿内 `.gcard .chead`：卡头写「祁连山电竞」，靠这一条淡蓝把"官方自营"这一事实
  /// 从卡身里分出来（不靠彩色标签，docs/21）。
  static const Color cardHeadBg = Color(0xFFEEF4FC);

  /// 商品卡**卡头**深蓝字（`#1E40AF`）
  ///
  /// 压 `#EEF4FC` 上实测 **6.55:1**（达 AA）。比 [primary] 深一档，避免与"可点击"蓝混淆。
  static const Color cardHeadInk = Color(0xFF1E40AF);

  /// **价格胶囊**底（`#FACC15`）
  ///
  /// 稿内 `.price` 的实色底。这是首页/分类页商品价的**唯一容器**（不再让金色文字裸奔在卡上）：
  /// 亮黄底 + 深棕字（[pricePillInk]）实测 **9.7:1**，弱光/大太阳下都读得清。
  static const Color pricePillBg = Color(0xFFFACC15);

  /// **价格胶囊**字（`#3B2400`）
  ///
  /// 压 `#FACC15` 上 9.7:1；深棕而非纯黑，与亮黄同族、不刺眼。
  static const Color pricePillInk = Color(0xFF3B2400);

  /// 品类色（分部/标签，6 色循环）
  ///
  /// 2026-10-16 随方案 F 重排：就是 F 的**六个强调色族**（蓝/青/紫/橙金/绿/粉），
  /// 顺序即"品牌主色优先"；不再保留任何 F 体系外的颜色。
  static const List<Color> categoryColors = [
    Color(0xFF2563EB), // 品牌主蓝（可操作）
    Color(0xFF06B6D4), // 客服青
    Color(0xFF8B5CF6), // AI 紫
    Color(0xFFF59E0B), // 资金橙金
    Color(0xFF10B981), // 安全绿
    Color(0xFFF472B6), // 活动粉
  ];

  // ============ 渐变（方案 F 实测）============

  /// 品牌主渐变（主按钮 / 榜单横幅 / 头像 / 浮标 用）
  ///
  /// `135deg, #2563EB → #06B6D4` —— 方案 F 的**主渐变**（`.gm`，全稿出现 20+ 次：
  /// 主按钮、底栏选中 nib、进度条、首页 Hero 全用它）。
  /// ⚠️ docs/21 禁"渐变做主视觉"仍然有效：**只用于极小面积**（主按钮底、C 位徽章）。
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF2563EB), Color(0xFF06B6D4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 页面顶部冰蓝渐隐（列表页背景）—— 保持极浅，白底为主
  static const LinearGradient iceFade = LinearGradient(
    colors: [ice, bgPage],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// 深色权益卡（工作端收益卡等）
  ///
  /// 方案 F 没有深色大块；白底为主定案也要求"深色大块尽量不用"。
  /// 保留品牌锚墨蓝同族（不属于 F 品牌色族，属"一次性深底"）。
  static const LinearGradient deepGradient = LinearGradient(
    colors: [brandInk, Color(0xFF1B3A5C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 品类色 → 渐变（头像/封面用，自动取同色系深浅）
  ///
  /// ⚠️ 白底为主定案后：**头像优先用实色浅底 + 主色首字**，
  /// 本函数**保留兼容**，但新代码不应再用它做头像底。
  static LinearGradient categoryGradient(Color color) => LinearGradient(
        colors: [_lighten(color, 0.34), _lighten(color, 0.06)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  /// 品类色 → 柔和标签底（浅底 + 同色描边 + 同色字中的"底"）
  static Color categorySoft(Color color) => Color.lerp(color, Colors.white, 0.86)!;

  /// 品类色 → 柔和标签描边
  static Color categoryBorder(Color color) => Color.lerp(color, Colors.white, 0.55)!;

  static Color _lighten(Color c, double t) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + t).clamp(0.0, 1.0)).toColor();
  }
}
