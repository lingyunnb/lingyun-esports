import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';

/// 应用内轻提示（负责人 2026-10-04：下单成功提示"违和"→ 换成品牌化动效提示）
///
/// 替代系统 SnackBar：屏上方居中浮出、品牌渐变底 + 图标 + 白字，进场用 Material Motion
/// 的 emphasized 曲线（淡入 + 轻微上浮 + 缩放），2 秒后自动淡出。不遮挡底部操作区。
class AppToast {
  AppToast._();

  static OverlayEntry? _current;
  static Timer? _timer;

  static void success(BuildContext context, String message, {IconData? icon}) =>
      _show(context, message, AppColors.statusOnline, icon ?? AppIcon.check);

  static void info(BuildContext context, String message, {IconData? icon}) =>
      _show(context, message, T.primary, icon ?? AppIcon.info);

  static void error(BuildContext context, String message, {IconData? icon}) =>
      _show(context, message, AppColors.error, icon ?? AppIcon.info);

  static void _show(BuildContext context, String message, Color color, IconData icon) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    dismiss();

    final entry = OverlayEntry(
      builder: (_) => _ToastView(message: message, color: color, icon: icon),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(milliseconds: 2000), dismiss);
  }

  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _current?.remove();
    _current = null;
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({required this.message, required this.color, required this.icon});

  final String message;
  final Color color;
  final IconData icon;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: const Cubic(0.2, 0, 0, 1));
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, -0.25), end: Offset.zero).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              child: Material(
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [widget.color, Color.lerp(widget.color, Colors.black, 0.12)!]),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: widget.color.withValues(alpha: 0.32),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.of(widget.icon, size: 17, color: Colors.white),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.message,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white, height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
