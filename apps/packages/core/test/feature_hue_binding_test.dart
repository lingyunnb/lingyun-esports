import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// **方案 F 功能区色相绑定**（「同功能全 App 同色」的机器可读契约）
///
/// 背景：负责人反馈「改了色看不出来」。色值备在 `AppColors` 里并不等于**配色落地** ——
/// 还必须有"哪个功能用哪个色"的规则。本用例守的就是这条规则：
/// 1. 五个功能区的色值 = planF 实测值（逐值回归，防止有人顺手调色）；
/// 2. **同功能同色**：同一功能区的任何图标取到的色**必须完全相同**，且等于该区的色相；
/// 3. 双色实底渐变的**起点必须是该区色相**（渐变不许另起炉灶）；
/// 4. AI 渐变 = `#8B5CF6 → #2563EB`（负责人 2026-10-16 点名）；
/// 5. 未登记的图标有**确定归属**（品牌主色），绝不随机取色。
void main() {
  group('功能区色相绑定（方案 F：同功能同色）', () {
    test('五个功能区 = planF 实测色值（逐值回归）', () {
      expect(featureHue(AppFeature.money), const Color(0xFFF59E0B), reason: '资金 = 橙金');
      expect(featureHue(AppFeature.support), const Color(0xFF06B6D4), reason: '客服 = 青');
      expect(featureHue(AppFeature.ai), const Color(0xFF8B5CF6), reason: 'AI = 紫');
      expect(featureHue(AppFeature.safe), const Color(0xFF10B981), reason: '安全 = 绿');
      expect(featureHue(AppFeature.activity), const Color(0xFFF472B6), reason: '活动 = 粉');
      expect(featureHue(AppFeature.brand), AppColors.primary, reason: '品牌 = 主色 #2563EB');
    });

    test('同功能同色：映射表每条的取色 = 它所属功能区的色', () {
      expect(featureIconMap, isNotEmpty, reason: '绑定表不许为空（空表 = 颜色又会各写各的）');
      for (final entry in featureIconMap.entries) {
        expect(
          featureHue(featureOfIcon(entry.key)),
          featureHue(entry.value),
          reason: '${entry.key} 声明属于 ${entry.value.name}，但取到的色不是该区色相',
        );
      }
    });

    test('同功能同色：同一区里不同图标拿到的是**同一个色值**（不随调用点变）', () {
      Set<Color> huesOf(List<IconData> icons) =>
          icons.map((i) => featureHue(featureOfIcon(i))).toSet();

      final money = huesOf([AppIcon.wallet, AppIcon.coin, AppIcon.tip, AppIcon.refund, AppIcon.gift]);
      expect(money, hasLength(1), reason: '资金区所有图标必须同色');
      expect(money.single, const Color(0xFFF59E0B));

      final safe = huesOf([AppIcon.shield, AppIcon.complaint, AppIcon.lock, AppIcon.safe]);
      expect(safe, hasLength(1));
      expect(safe.single, const Color(0xFF10B981));

      final activity = huesOf([AppIcon.rank, AppIcon.trophy, AppIcon.fire, AppIcon.crown, AppIcon.bell]);
      expect(activity, hasLength(1));
      expect(activity.single, const Color(0xFFF472B6));

      final support = huesOf([AppIcon.headset]);
      expect(support.single, const Color(0xFF06B6D4));
    });

    test('双色实底渐变：起点必须 = 该区色相（渐变不得另起炉灶）', () {
      for (final f in AppFeature.values) {
        final g = featureGradient(f);
        expect(g.colors.first, featureHue(f), reason: '${f.name} 的渐变起点不是本区色相');
        expect(g.colors, hasLength(2), reason: '${f.name} 必须是双色（planF 的 .rc 都是两停）');
      }
    });

    test('AI 渐变 = 紫 → 蓝（负责人点名 accentAi #8B5CF6）', () {
      final g = featureGradient(AppFeature.ai);
      expect(g.colors.first, AppColors.accentAi);
      expect(g.colors.first, const Color(0xFF8B5CF6));
      expect(g.colors.last, const Color(0xFF2563EB));
    });

    test('彩色柔和阴影：同色系、低透明（只给小实底元件，不铺卡片）', () {
      final shadows = featureShadow(AppFeature.brand);
      expect(shadows, hasLength(1));
      expect(shadows.single.color.a, closeTo(.35, 0.001), reason: 'planF：底栏选中 nib 是 rgba(...,.35)');
      expect(shadows.single.blurRadius, 11, reason: 'planF：0 5px 11px');
      expect(shadows.single.offset.dy, 5);
      // 阴影色 = 该区色相的半透明版本（不是纯黑，也不是另一个色相）
      final hue = featureHue(AppFeature.brand);
      expect(shadows.single.color.r, closeTo(hue.r, 0.001));
      expect(shadows.single.color.g, closeTo(hue.g, 0.001));
      expect(shadows.single.color.b, closeTo(hue.b, 0.001));
    });

    test('未登记图标 → 品牌主色（有确定归属，绝不随机）', () {
      expect(
        featureOfIcon(const IconData(0xe999, fontFamily: 'MaterialIcons')),
        AppFeature.brand,
      );
    });

    test('浅底与色相同族（标签胶囊底不许跳到别的色系）', () {
      for (final f in AppFeature.values) {
        expect(featureSoft(f).a, 1.0, reason: '${f.name} 的浅底必须是不透明实色');
        // 浅底必须比色相**亮**（否则标签会糊成一团）
        expect(featureSoft(f).computeLuminance(), greaterThan(featureHue(f).computeLuminance()),
            reason: '${f.name} 浅底不比色相亮');
      }
    });
  });
}
