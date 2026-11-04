import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 解析服务端的「建设中」标记（**服务页与商品列表页共用**）
///
/// 服务端公开接口 `underConstruction` 现在是布尔 `true/false`（`DivisionService.toView` 里
/// `tinyint → boolean`），但管理端列表接口历史口径是 0/1 —— 两种都认，
/// 将来任一端改口径也不会让「建设中」判定静默失效（判定失效 = 用户直接看到空货架）。
bool divisionUnderConstruction(Object? raw) {
  if (raw == null) return false;
  if (raw is bool) return raw;
  if (raw is num) return raw.toInt() == 1;
  final s = raw.toString().trim().toLowerCase();
  return s == '1' || s == 'true';
}

/// 分部「建设中」页（负责人 2026-10-05）
///
/// 需求原文：
/// > 增加**瓦端（无畏契约端游）**和**瓦手（无畏契约手游）**，但是用户点开先显示
/// > **该分部正在建设中，敬请期待**；本分部大力招人，有意联系本人 **q：3989032755**
///
/// 三条硬规则：
/// 1. **文案全部来自服务端**（`GET /divisions/grouped` 的 `noticeText`），本页**不写死任何文案、不写死 QQ 号**；
///    服务端留空时才回退到 [fallbackNotice]（一句话，不含任何联系方式）。
/// 2. **数据驱动，不是代码开关**：分部把 `under_construction` 改成 0 之后，服务页卡片直接进商品列表，
///    本页从此不会被打开 —— 上线不需要改客户端、也不需要发版。
/// 3. 反 AI 味（docs/21）：左对齐、发丝线分区、圆角分档（10 / 12）、单一实色小片、无装饰插画、无 emoji。
///
/// 进页方式：服务页分部卡（`ServicesPage._divisionWideCard/_divisionHalfCard`）在
/// `underConstruction == true` 时 push 本页；商品列表页的兜底拦截复用 [DivisionUnderConstructionView]。
class DivisionUnderConstructionPage extends StatelessWidget {
  const DivisionUnderConstructionPage({
    super.key,
    required this.name,
    this.shortName = '',
    this.platform = '',
    this.platformLabel = '',
    this.gameKey = '',
    this.themeColor = '',
    this.imageMediaId,
    this.noticeText = '',
  });

  /// 分部展示名（如「无畏契约 · 端游」）
  final String name;

  /// 分部简称（卡片主标题，如「无畏契约」）
  final String shortName;

  /// mobile / pc（端游贴「端」角标）
  final String platform;

  /// 平台标签（手游 / 端游）
  final String platformLabel;

  /// 游戏图标映射键（code + gameName + name；认不出走兜底图标）
  final String gameKey;

  /// 分部主题色 #RRGGBB
  final String themeColor;

  /// 管理端为该分部挂的官方图（无图则自绘游戏图标）
  final String? imageMediaId;

  /// **服务端下发的提示文案**（可含换行与 QQ 号）
  final String noticeText;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          AppPageHeader(title: name.isEmpty ? (shortName.isEmpty ? '分部' : shortName) : name),
          Expanded(
            child: DivisionUnderConstructionView(
              name: name,
              shortName: shortName,
              platform: platform,
              platformLabel: platformLabel,
              gameKey: gameKey,
              themeColor: themeColor,
              imageMediaId: imageMediaId,
              noticeText: noticeText,
            ),
          ),
        ],
      ),
    );
  }
}

/// 建设中内容块（页面主体，也可嵌进别的页面的内容区做拦截态）
class DivisionUnderConstructionView extends StatelessWidget {
  const DivisionUnderConstructionView({
    super.key,
    required this.name,
    this.shortName = '',
    this.platform = '',
    this.platformLabel = '',
    this.gameKey = '',
    this.themeColor = '',
    this.color,
    this.imageMediaId,
    this.noticeText = '',
    this.onSeeOthers,
  });

  /// 服务端没下发文案时的兜底（**不含任何联系方式**，绝不硬编码负责人 QQ 号）
  static const String fallbackNotice = '该分部正在建设中，敬请期待';

  final String name;
  final String shortName;
  final String platform;
  final String platformLabel;
  final String gameKey;
  final String themeColor;

  /// 已解析好的主题色（商品列表页手里是 `Color`，直接传它，避免再走一次 #RRGGBB 解析）
  final Color? color;
  final String? imageMediaId;
  final String noticeText;

  /// 「看看其他分部」按钮行为（默认返回上一页 = 服务页分部列表）
  final VoidCallback? onSeeOthers;

  /// 实际展示的文案：**服务端优先**；服务端为空才用兜底
  String get displayNotice {
    final t = noticeText.trim();
    return t.isEmpty ? fallbackNotice : noticeText;
  }

  Color get _color {
    if (color != null) return color!;
    final hex = themeColor.replaceFirst('#', '');
    if (hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    // 内容区标题用**简称**（与分部卡主标题一致）：
    // 页头已经是完整分部名（无畏契约 · 端游），内容区再重复一遍完整名纯属堆字；
    // 简称 + 平台标签 + 「建设中」小片三件事各说一次，不再重复。
    final title = shortName.isNotEmpty ? shortName : (name.isNotEmpty ? name : '分部');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        // 标题区：分部图标（管理端有官方图就用图）+ 简称 + 细描边「建设中」小片
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GameIconTile(
              gameKey: gameKey.isEmpty ? name : gameKey,
              platform: platform,
              color: _color,
              size: 44,
              radius: 10,
              mediaId: imageMediaId,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: T.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // 细描边小片（docs/21：状态标识用发丝线，不做彩色胶囊堆砌）
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: T.divider),
                        ),
                        child: Text(
                          '建设中',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: T.textSecondary),
                        ),
                      ),
                      if (platformLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(platformLabel, style: TextStyle(fontSize: 10.5, color: T.mutedText)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(height: 1, color: T.divider),
        const SizedBox(height: 18),
        // 提示文案：**服务端下发原文**（保留换行），左对齐、行距放宽便于读
        SelectableText(
          displayNotice,
          style: TextStyle(fontSize: 13.5, height: 1.85, color: T.textSecondary),
        ),
        const SizedBox(height: 26),
        AppButton(
          label: '看看其他分部',
          onPressed: onSeeOthers ?? () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(height: 22),
        // 品牌元素：雪山标（线稿，纯绘制，无插画依赖）
        Row(
          children: [
            AppMountainMark(size: 16, color: T.textTertiary),
            const SizedBox(width: 6),
            Text('祁连山电竞', style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
          ],
        ),
      ],
    );
  }
}
