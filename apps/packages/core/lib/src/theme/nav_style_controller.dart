/// 底栏外观（负责人 2026-10-18：「液态玻璃让底部导航栏悬浮，用户可自主选择开启」）
///
/// ## 为什么单独一个控制器
/// 这是一个**跨页面**状态：开关在「我的 → 外观」，生效在 `HomeShell` 的底栏。
/// 沿用项目既有的 `ThemeController` 那套做法（`ChangeNotifier` + 静态单例 + `AppSettings` 持久化），
/// 不新建第二套状态方案。
///
/// ## 默认关
/// `glass = false` —— 液态玻璃是**可选项**，不是默认视觉：
/// · 它每帧对背后区域做折射采样，低端机上代价真实存在；
/// · 它需要宿主 `Scaffold(extendBody: true)`，页面底部留白要跟着变；
/// · 项目历史上 `liquid_glass_widgets` 曾因真机着色器问题被停用
///   （见 CLAUDE.md），所以这次做成"用户要才开"，而不是替所有人开。
library;

import 'package:flutter/foundation.dart';

import '../config/app_settings.dart';

class NavStyleController extends ChangeNotifier {
  NavStyleController._();

  static final NavStyleController instance = NavStyleController._();

  bool _glass = false;

  /// 当前是否启用液态玻璃悬浮底栏
  bool get glass => _glass;

  /// 启动时读一次（`main()` 里 await 过 `ensureInitialized`，此处失败不抛）
  Future<void> init() async {
    try {
      final v = await AppSettings.instance.readNavGlass();
      if (v != null && v != _glass) {
        _glass = v;
        notifyListeners();
      }
    } catch (_) {
      // 读不到就用默认（关）—— 不因为一个外观开关把启动流程搞挂
    }
  }

  /// 切换并持久化。**先改内存再写盘**：开关手感立刻响应，写盘失败只影响下次启动。
  Future<void> setGlass(bool v) async {
    if (_glass == v) return;
    _glass = v;
    notifyListeners();
    try {
      await AppSettings.instance.writeNavGlass(v);
    } catch (_) {
      // 写盘失败不回滚：这一次会话仍然按用户点的来
    }
  }

  /// 玻璃模式下页面**必须额外留出**的底部高度（60 条高 + 8 底距）
  ///
  /// ## 为什么必须有这个
  /// `Scaffold(extendBody: true)` 让 body 铺到导航栏下方 —— 这是玻璃能采样到内容的
  /// 前提。代价是 **body 不再自动为导航栏让位**：页面底部留白不跟着加的话，列表
  /// 滚到底时最后一项会被悬浮胶囊压住（负责人 2026-10-21 截图：「人气打手」的
  /// 「接单 0 次」、「身份」的「解除绑定」都被盖住了）。
  ///
  /// 所以页面底部 padding 一律写成 `基础值 + NavStyleController.instance.navReservedHeight`。
  /// 非玻璃模式返回 **0** → 与改动前逐像素一致。
  double get navReservedHeight => _glass ? 68 : 0;
}
