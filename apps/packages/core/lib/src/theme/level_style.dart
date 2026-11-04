import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../icons/app_icon.dart';

/// 会员等级视觉体系（负责人需求 #9 + 2026-09-22 高端化升级）：5 级独立配色/标识，
/// 三段渐变 + 专属点缀色，等级越高视觉越华贵（银→蓝→金→紫→赤金），整体走高端大气路线
/// L1 新星·银灰 → L2 进阶·宝蓝 → L3 精英·鎏金 → L4 尊享·紫金 → L5 王者·赤金（皇冠）
class LevelStyle {
  const LevelStyle({
    required this.label,
    required this.color,
    required this.bg,
    required this.gradient,
    required this.accent,
    required this.icon,
  });

  final String label;

  /// 主色（徽章文字/图标）
  final Color color;

  /// 浅底（徽章背景）
  final Color bg;

  /// 会员卡片三段渐变（深→浅，左上有光感）
  final List<Color> gradient;

  /// 点缀色（卡片内高光元素/描边）
  final Color accent;

  /// 徽章图标
  final IconData icon;
}

/// 2026-10-16 随「方案 F」重新锚定 L2/L3/L4 的色族：
/// **L2=品牌蓝族 · L3=橙金族 · L4=紫族**（三族一律取 F 稿实测值）——
/// 理由：`docs/21` 的硬契约是「**全站唯一"金"**」（`AppColors.gold`），
/// 而 L3 原来的 `#C9831B/#C07A12/#E0A63E` 是第二套金，F 落地后就成了两个金。
/// L1（银灰）与 L5（赤金/王者红）F 稿没有对应族，**原值保留**（它们不是"金"）。
const List<LevelStyle> kLevelStyles = [
  LevelStyle(
    label: '初识会员',
    color: Color(0xFF7C8698),
    bg: Color(0xFFF2F4F8),
    gradient: [Color(0xFF6E7988), Color(0xFF8A94A6), Color(0xFFA8B1BF)],
    accent: Color(0xFFD3D9E2),
    icon: AppIconsLegacy.star_border,
  ),
  LevelStyle(
    // 进阶 · F 蓝族（`#2563EB` = 品牌主色；深档 `#0369A1`、浅底 `#EFF6FF`/`#DBEAFE` 均取自 planF）
    label: '知交会员',
    color: Color(0xFF2563EB),
    bg: Color(0xFFEFF6FF),
    gradient: [Color(0xFF0369A1), Color(0xFF2563EB), Color(0xFF3B82F6)],
    accent: Color(0xFFDBEAFE),
    icon: AppIconsLegacy.star_half,
  ),
  LevelStyle(
    // 精英 · F 橙金族（`#F59E0B` = 全站唯一金；文字用深琥珀 `#B45309` 保证浅底可读 5.02:1）
    label: '尊享会员',
    color: Color(0xFFB45309),
    bg: Color(0xFFFEF3C7),
    gradient: [Color(0xFFB45309), Color(0xFFF59E0B), Color(0xFFFDE6C8)],
    accent: Color(0xFFFDE6C8),
    icon: AppIconsLegacy.star,
  ),
  LevelStyle(
    // 尊享 · F 紫族（`#8B5CF6` = AI/尊享紫；深档 `#6D28D9`、亮档 `#A78BFA`、浅底 `#F5F3FF` 均取 planF）
    label: '臻享会员',
    color: Color(0xFF6D28D9),
    bg: Color(0xFFF5F3FF),
    gradient: [Color(0xFF6D28D9), Color(0xFF8B5CF6), Color(0xFFA78BFA)],
    accent: Color(0xFFEDE9FE),
    icon: AppIconsLegacy.workspace_premium,
  ),
  LevelStyle(
    label: '至尊会员',
    color: Color(0xFFC2232E),
    bg: Color(0xFFFDEEEC),
    gradient: [Color(0xFFB91F35), Color(0xFFE5484D), Color(0xFFF08A5D)],
    accent: Color(0xFFFCD9B8),
    icon: AppIconsLegacy.emoji_events,
  ),
];

LevelStyle levelStyleOf(int level) => kLevelStyles[(level - 1).clamp(0, 4)];

/// 等级规则（后台配置数据结构）：升级阈值由后台 GET /public/levels 下发（负责人 2026-09-25：
/// "升级所需累计消费金额由后台配置，前端只读取后台数据"），前端不再写死。
class LevelRule {
  const LevelRule({required this.level, required this.name, required this.minSpent});

  final int level;
  final String name;
  final double minSpent;
}

/// 等级规则存储：启动后拉取后台配置并缓存；拉取前/失败回退默认阈值，页面在任何网络状况下可用。
/// ChangeNotifier：配置到达后通知监听页面刷新进度（升级阈值变了立即生效）。
class LevelRulesStore extends ChangeNotifier {
  LevelRulesStore._();
  static final LevelRulesStore instance = LevelRulesStore._();

  static const List<LevelRule> kDefaultRules = [
    LevelRule(level: 1, name: '初识会员', minSpent: 0),
    LevelRule(level: 2, name: '知交会员', minSpent: 500),
    LevelRule(level: 3, name: '尊享会员', minSpent: 2000),
    LevelRule(level: 4, name: '臻享会员', minSpent: 10000),
    LevelRule(level: 5, name: '至尊会员', minSpent: 50000),
  ];

  List<LevelRule>? _rules;
  Future<void>? _fetching;

  List<LevelRule> get rules => _rules ?? kDefaultRules;

  /// 幂等拉取（重复调用共享同一 Future，不会并发请求）
  Future<void> ensureLoaded() async {
    if (_rules != null) return;
    _fetching ??= _fetch();
    await _fetching;
  }

  Future<void> _fetch() async {
    try {
      final api = ApiClient();
      final resp = await api.request('GET', '/public/levels');
      final list = ((resp['data'] as List<dynamic>?) ?? [])
          .map((e) => LevelRule(
                level: ((e as Map<String, dynamic>)['level'] as num?)?.toInt() ?? 0,
                name: '${e['name'] ?? ''}',
                minSpent: (e['minSpent'] as num?)?.toDouble() ?? 0,
              ))
          .where((r) => r.level >= 1 && r.level <= 5 && r.name.isNotEmpty)
          .toList()
        ..sort((a, b) => a.level.compareTo(b.level));
      if (list.isNotEmpty) {
        _rules = list;
        notifyListeners();
      }
    } on ApiException {
      // 静默：保留默认阈值（离线/未登录也能渲染）
    }
  }

  /// 下一等级所需累计消费（用于会员进度展示；最高级返回 null）
  int? nextSpentOf(int level) {
    final rs = rules;
    for (final r in rs) {
      if (r.level == level + 1) return r.minSpent.round();
    }
    return null;
  }
}

/// 下一等级所需累计消费（兼容旧调用入口，内部走后台配置）
int? nextLevelSpentOf(int level) => LevelRulesStore.instance.nextSpentOf(level);

/// 等级徽章（头像旁/列表等位置通用）
class LevelBadge extends StatelessWidget {
  const LevelBadge({super.key, required this.level, this.compact = false, this.showLabel = true});

  final int level;
  final bool compact;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final style = levelStyleOf(level);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 1.5 : 2.5),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        border: Border.all(color: style.color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon.of(style.icon, size: compact ? 10 : 12, color: style.color),
          SizedBox(width: compact ? 2 : 3),
          Text(
            showLabel ? 'L$level ${style.label}' : 'L$level',
            style: TextStyle(fontSize: compact ? 10 : 11, color: style.color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
