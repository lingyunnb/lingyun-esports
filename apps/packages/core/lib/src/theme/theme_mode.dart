/// 主题模式（底层枚举；**用户可见的主题选择 UI 已全部移除**，2026-10-04 三端统一单一主题）
///
/// - classic：当前唯一在用的主题（= 设计稿 I 系列基线）
/// - liquidGlass：历史玻璃主题，已下线（保留枚举与 token 以避免大范围改动）
///
/// 注：原「初始主题 / 液态玻璃」选择文案（label/description）随主题设置页一并删除。
enum AppThemeMode {
  classic,
  liquidGlass;

  static AppThemeMode fromKey(String? key) =>
      key == 'liquidGlass' ? AppThemeMode.liquidGlass : AppThemeMode.classic;

  String get storageKey => name;
}
