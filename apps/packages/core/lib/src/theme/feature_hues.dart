import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import 'app_colors.dart';

/// 功能区（语义分区）→ 专属色相 —— **方案 F 的唯一出处**（2026-10-16）
///
/// ## 为什么要有这个文件
/// 负责人反馈「改色改到哪去了，看不出来」的根因之一：色值都在 `AppColors` 里备好了，
/// 但**没有任何一处规定"哪个功能用哪个色"** —— 于是页面各写各的，看起来还是老样子。
/// 本文件把这条规则收口成**一处**：功能 → 色相、浅底、双色实底渐变、彩色柔和阴影。
///
/// ## 绑定表（照 `site/design/color-graphics/planF.html` 实测，不得随机用色）
/// | 功能区 | 色相 | F 实测值 | 出现在哪 |
/// |---|---|---|---|
/// | [AppFeature.money] 资金 | `accentMoney` | `#F59E0B` | 余额 / 充值 / 提现 / 打赏 / 退款 / 结算额 |
/// | [AppFeature.support] 客服 | `accentSupport` | `#06B6D4` | 客服会话 / 在线服务 |
/// | [AppFeature.ai] AI（祁小山） | `accentAi` | `#8B5CF6` | 祁小山入口 / AI 会话 |
/// | [AppFeature.safe] 安全 | `accentSafe` | `#10B981` | 担保 / 平台保障 / 投诉 / 封禁 |
/// | [AppFeature.activity] 活动 | `accentPink` | `#F472B6` | 榜单热度 / 限时 / 公告 |
/// | [AppFeature.brand] 品牌 | `primary` | `#2563EB` | 导航 / 主按钮 / 可操作 |
///
/// ⚠️ **不发明新色**：实色与浅底一律取自 [AppColors]；只有**双色实底的渐变副色**
/// 是 F 稿里逐条实测出来的（见 [featureGradient] 每个分支的行内出处）。
enum AppFeature {
  /// 品牌主色（导航 / 主按钮 / 可操作）
  brand,

  /// 资金：余额 / 充值 / 提现 / 打赏 / 退款 / 结算额
  money,

  /// 客服：客服会话 / 在线服务
  support,

  /// AI：祁小山
  ai,

  /// 安全：担保 / 平台保障 / 投诉 / 封禁
  safe,

  /// 活动：榜单热度 / 限时 / 公告
  activity,
}

/// 色相（实色）—— 用于图标着色、文字、描边
Color featureHue(AppFeature feature) => switch (feature) {
      AppFeature.brand => AppColors.primary,
      AppFeature.money => AppColors.accentMoney,
      AppFeature.support => AppColors.accentSupport,
      AppFeature.ai => AppColors.accentAi,
      AppFeature.safe => AppColors.accentSafe,
      AppFeature.activity => AppColors.accentPink,
    };

/// 浅底 —— 用于彩色标签胶囊底 / 分区浅底（与 [featureHue] 同族）
Color featureSoft(AppFeature feature) => switch (feature) {
      AppFeature.brand => AppColors.ice,
      AppFeature.money => AppColors.goldSoft,
      AppFeature.support => AppColors.accentSupportSoft,
      AppFeature.ai => AppColors.accentAiSoft,
      AppFeature.safe => AppColors.accentSafeSoft,
      AppFeature.activity => AppColors.accentPinkSoft,
    };

/// **双色实底渐变的底**（planF 的 `.rc` / `.nib`：`linear-gradient(135deg, A, B)`）
///
/// 每个分支的副色都在 planF.html 里**逐条实测**（同一屏同一元件的成对取值）：
/// - `brand`：`.btn.gm` / `.bnav .it.on .nib` → `#2563EB → #06B6D4`（= [AppColors.brandGradient]）
/// - `money`：抢单卡/计时块 `.rc` → `#F59E0B → #FB923C`
/// - `support`：`.rc` → `#06B6D4 → #22D3EE`
/// - `ai`：AI 位 `.rc`（`ic-bot`） → `#8B5CF6 → #2563EB`（负责人 2026-10-16 点名用这一对）
/// - `safe`：`ic-shield` 底 → `#10B981 → #22D3EE`
/// - `activity`：`ic-trophy` 底 → `#F472B6 → #8B5CF6`
LinearGradient featureGradient(AppFeature feature) => switch (feature) {
      AppFeature.brand => AppColors.brandGradient,
      AppFeature.money => const LinearGradient(
          colors: [AppColors.accentMoney, Color(0xFFFB923C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      AppFeature.support => const LinearGradient(
          colors: [AppColors.accentSupport, Color(0xFF22D3EE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      AppFeature.ai => const LinearGradient(
          colors: [AppColors.accentAi, AppColors.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      AppFeature.safe => const LinearGradient(
          colors: [AppColors.accentSafe, Color(0xFF22D3EE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      AppFeature.activity => const LinearGradient(
          colors: [AppColors.accentPink, AppColors.accentAi],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
    };

/// **彩色柔和阴影**（planF：底栏选中 nib 是 `0 5px 11px rgba(37,99,235,.35)`）
///
/// 底色同色系、透明度 <0.4，只给**实底小元件**用；cards 仍走 docs/21 的发丝线 + 轻阴影。
List<BoxShadow> featureShadow(AppFeature feature, {double blur = 11, double dy = 5}) => <BoxShadow>[
      BoxShadow(
        color: featureHue(feature).withValues(alpha: .35),
        blurRadius: blur,
        offset: Offset(0, dy),
      ),
    ];

/// 图标 → 功能区（**「同功能同色」的机器可读绑定**）
///
/// 键是**旧 `IconData`**（`AppIcon.x` / `AppIconsLegacy.x` 的值）—— 因为底栏、服务页三格、
/// 列表行这些调用点都还在传旧值；值就是它们所属的功能区。
/// 未登记的图标一律落 [AppFeature.brand]（品牌主色），**不会随机取色**。
///
/// ⚠️ **按「值」去重**：`IconData` 没有覆写 `==`，而 `AppIcon.wallet` 与
/// `AppIconsLegacy.account_balance_wallet_outlined` **是同一个 const 值** ——
/// 两条都写会被 analyzer 判为 `equal_keys_in_map`（且运行时只有后写的那条生效）。
/// 所以这里**每个 IconData 值只登记一次**（写语义名，读旧 Material 名同样命中，因为值相同）。
Map<IconData, AppFeature> get featureIconMap => _featureIconMap;
final Map<IconData, AppFeature> _featureIconMap = <IconData, AppFeature>{
  // 资金（余额 / 充值 / 提现 / 打赏 / 退款 / 结算额）
  AppIcon.wallet: AppFeature.money, // = Icons.account_balance_wallet_outlined
  AppIcon.coin: AppFeature.money, // = Icons.monetization_on_outlined
  AppIcon.gift: AppFeature.money, // = Icons.card_giftcard_rounded
  AppIcon.tip: AppFeature.money, // = Icons.volunteer_activism_outlined
  AppIcon.refund: AppFeature.money, // = Icons.assignment_return_outlined
  AppIconsLegacy.credit_card_outlined: AppFeature.money, // 充值
  AppIconsLegacy.credit_card_rounded: AppFeature.money, // 接单（打手态底栏选中）
  // 客服
  AppIcon.headset: AppFeature.support, // = Icons.headset_mic_outlined
  AppIconsLegacy.support_agent_outlined: AppFeature.support,
  AppIconsLegacy.support_agent_rounded: AppFeature.support,
  // AI：祁小山入口不用 Material 图标（走 `qishan_mark.dart` 自绘雪山标），
  // 所以这里没有 ai 的条目 —— 它的紫走 [featureGradient]([AppFeature.ai]) / [featureHue]。
  // 安全（担保 / 平台保障 / 投诉 / 封禁）
  AppIcon.shield: AppFeature.safe, // = Icons.verified_user_outlined
  AppIcon.safe: AppFeature.safe, // = Icons.security_rounded
  AppIcon.complaint: AppFeature.safe, // = Icons.report_problem_outlined
  AppIcon.lock: AppFeature.safe, // = Icons.lock_outline_rounded
  AppIconsLegacy.shield_outlined: AppFeature.safe,
  AppIconsLegacy.warning_amber_rounded: AppFeature.safe,
  // 活动（榜单热度 / 限时 / 公告）
  AppIcon.trophy: AppFeature.activity, // = Icons.emoji_events_outlined
  AppIcon.rank: AppFeature.activity, // = Icons.leaderboard_outlined
  AppIcon.fire: AppFeature.activity, // = Icons.local_fire_department_outlined
  AppIcon.crown: AppFeature.activity, // = Icons.workspace_premium_outlined
  AppIcon.bell: AppFeature.activity, // = Icons.notifications_none_rounded
  // 品牌（导航 / 通用操作）
  AppIcon.services: AppFeature.brand,
  AppIcon.orders: AppFeature.brand,
  AppIcon.messages: AppFeature.brand,
  AppIcon.mine: AppFeature.brand,
  AppIcon.plus: AppFeature.brand,
  AppIcon.search: AppFeature.brand,
  AppIcon.settings: AppFeature.brand,
  AppIcon.info: AppFeature.brand,
  AppIcon.help: AppFeature.brand,
  AppIcon.players: AppFeature.brand,
};

/// 取图标所属功能区；未登记 → [AppFeature.brand]（有确定归属，不随机）
AppFeature featureOfIcon(IconData icon) => _featureIconMap[icon] ?? AppFeature.brand;
