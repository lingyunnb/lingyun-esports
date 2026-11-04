import 'dart:math' as math;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设计 token 契约（2026-10-05 好友页重构：负责人审批新增 `AppColors.mutedText`）
///
/// 背景：老板端「添加好友」页的说明文字原先用 `textTertiary`（#94A3B8）写在白底上，
/// 实测对比度仅 **2.6:1** —— 远低于 WCAG AA 正文要求的 4.5:1（浅灰字在白色卡片上"看不清"）。
/// 新增 `mutedText`（#5B6B80，5.44:1）专供**白底说明文字/副标题/输入提示**；
/// `textTertiary` **保留**给图标/发丝线/禁用态（那里不需要 4.5:1）。
void main() {
  /// WCAG 2.x 相对亮度
  double luminance(Color c) {
    double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }

  /// WCAG 对比度（(L1+0.05)/(L2+0.05)，亮者作分子）
  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  test('mutedText = #4A5A6E（2026-10-14 品牌升级值，值本身可回归）', () {
    expect(AppColors.mutedText, const Color(0xFF4A5A6E));
    expect(AppColors.mutedText.a, 1.0, reason: '必须是不透明实色（叠在其它底色上不得变淡）');
  });

  test('mutedText 在白底上达 WCAG AA 正文（≥4.5:1），实测 7.05:1', () {
    final onWhite = contrast(AppColors.mutedText, AppColors.bgCard);
    expect(onWhite, greaterThanOrEqualTo(4.5), reason: '白底说明文字对比度 $onWhite');
    expect(onWhite, closeTo(7.05, 0.05), reason: '设计稿标注 7.05:1（2026-10-14 品牌升级后复算）');
  });

  test('mutedText 在冷灰蓝页底 #F5F7FB 上同样达标（≥4.5:1）', () {
    expect(contrast(AppColors.mutedText, AppColors.bgPage), greaterThanOrEqualTo(4.5));
  });

  test('mutedText 比 textTertiary 深一档，但仍在同一冷灰色系', () {
    final muted = luminance(AppColors.mutedText);
    final tertiary = luminance(AppColors.textTertiary);
    expect(muted, lessThan(tertiary), reason: 'mutedText 必须比 textTertiary 更深（更亮 = 更浅 = 更看不清）');
    // 旧 token 不得被顺手删掉（存量页面与图标仍在用）
    expect(AppColors.textTertiary, const Color(0xFF94A3B8));
    // 白底上 textTertiary 不达 AA —— 这正是要新增 mutedText 的原因
    expect(contrast(AppColors.textTertiary, AppColors.bgCard), lessThan(4.5));
  });
}
