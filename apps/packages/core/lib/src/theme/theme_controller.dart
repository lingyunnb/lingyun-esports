import 'package:flutter/foundation.dart';

import '../auth/auth_store.dart';
import '../config/app_settings.dart';
import 'theme_mode.dart';
import 'theme_tokens.dart';

/// 主题控制器（底层实现，**已无用户可见的主题选择入口**）
///
/// 负责人 2026-10-04：「设置里的主题设置删干净」→ 三端统一单一主题：
/// - 删掉主题设置页与所有入口/文案；账号不再按历史选择切主题（`init()` 固定单一主题）
/// - 保留 [tokens] / [T] 门面，页面继续从这里取色（不删底层实现，避免大面积改动）
/// - [setMode] 保留为底层能力，但**没有任何 UI 调用它**
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  /// 单一主题：classic token（= 设计稿 I 系列基线；玻璃主题已下线）
  AppThemeMode _mode = AppThemeMode.classic;
  AppThemeMode get mode => _mode;

  ThemeTokens get tokens => _mode == AppThemeMode.liquidGlass ? kGlassTokens : kClassicTokens;
  bool get isGlass => _mode == AppThemeMode.liquidGlass;

  /// 单一主题：不再读取历史选择（老账号存过 liquidGlass 也一律回到统一主题）
  Future<void> init() async => _setSilent(AppThemeMode.classic);

  /// 底层切换能力（无 UI 入口；保留以兼容可能的内部调用）
  Future<void> setMode(AppThemeMode m) async {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    final uname = AuthStore.instance.me?.username ?? await AppSettings.instance.readLastUsername();
    await AppSettings.instance.writeThemeMode('theme_mode_${uname ?? 'default'}', m.storageKey);
  }

  void _setSilent(AppThemeMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
  }
}
