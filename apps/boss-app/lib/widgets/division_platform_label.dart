import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 「选择服务」上方的平台标识（负责人 2026-10-04）
///
/// 场景：三角洲行动同时有「手游 / 端游」两个分部（和平精英只有手游）。商品列表与确认订单页
/// 此前只有图片角标能区分平台，文字上看不出当前看的是手游还是端游 —— 这里在服务区上方
/// 补一行明确的平台标识（`三角洲行动 · 端游`）。
///
/// 视觉（docs/21 反 AI 味）：
/// - 白色实底 + 发丝线描边的小圆角(6)条，不用渐变、不用阴影；
/// - 11.5px 次要文字，只有必须区分的信息才做标识，不堆彩色标签、不用 emoji；
/// - 数据全部来自管理端 `/divisions`（name / shortName / platformLabel），客户端不写死。
class DivisionPlatformLabel extends StatelessWidget {
  const DivisionPlatformLabel({
    super.key,
    required this.name,
    this.shortName = '',
    this.platformLabel = '',
  });

  /// 分部展示名（`/divisions` 的 name，如「三角洲行动 · 端游」）
  final String name;

  /// 分部简称（如「三角洲行动」）；为空时退回 [name]
  final String shortName;

  /// 平台标签（管理端 `platformLabel`：手游 / 端游）；为空时只显示 [name]
  final String platformLabel;

  /// 稳定 Key（widget 测试与定位用）
  static const Key labelKey = Key('division-platform-label');

  /// 展示文案：`简称 · 平台`（如「三角洲行动 · 端游」）；无平台标签时用完整分部名
  String get text {
    if (platformLabel.isEmpty) return name;
    final base = shortName.isNotEmpty ? shortName : name;
    return '$base · $platformLabel';
  }

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty && platformLabel.isEmpty) return const SizedBox.shrink();
    return Container(
      key: labelKey,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: T.divider),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w500, color: T.textSecondary),
      ),
    );
  }
}
