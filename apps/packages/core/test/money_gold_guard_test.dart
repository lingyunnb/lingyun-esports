import 'dart:io';
import 'dart:math' as math;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// # 「两档金」源码红线（2026-10-16 负责人拍板）
///
/// ## 为什么要这条红线
/// 方案 F 的橙金 `#F59E0B` 白底只有 **2.15:1** —— 作为**大字金额**（≥19px 且 w700+）它靠
/// 尺寸与字重立住、是 F 的设计意图，**保留**；但作为**小字**在手机上白天读不清。
/// 于是金分两档：
///
/// | 档 | token | 值 | 白底 | `#EFF6FF` | `#FEF3C7` | 用在哪 |
/// |---|---|---|---|---|---|---|
/// | 大字金 | [AppColors.gold] | `#F59E0B` | 2.15:1 | 2.03:1 | 1.98:1 | ≥19px 且 w700+ 的金额/等级 |
/// | **小字金** | [AppColors.goldText] | `#935F06` | **5.41:1** | **4.97:1** | **4.86:1** | <19px 或字重 <w700 的**一切"金"字与金图标** |
///
/// `goldText` 与 `gold` **同一支橙金**（色相 37.7° / 饱和 92% 逐项相同，只是明度 50%→30%），
/// 所以它**不是第二个色相**，只是同一支金的深档。
///
/// ## 本文件守什么（**四层，缺一不可**）
/// - **R1/R2/R3＝源码级红线**：小字场景直接用 `gold` 会被抓（R1 `TextStyle` / R2 `Icon`），
///   其余每一处裸 `gold` 引用还要按「文件 → 次数」登记（R3）——**新增或回退立刻红**；
/// - **R4＝token 契约**：两档值 + 三个底色上的实算对比度（不写死对比度数字，是算出来的）；
/// - **R5＝组件行为**：`AppPrice` / `AppMoney` **按字号自动选档**——
///   这条最关键：它保证**每个页面（含曾经"一行不动"的 `product_list_page.dart`）都拿到可读的深金**，
///   所以"小字用深金"收口在组件里，而不是靠每个页面自觉。
///   （2026-10-17：该页价格改成方案 G 黄色价格胶囊 `pricePillBg`+`pricePillInk`，不再传裸 `gold`，
///   R3 登记表已相应摘除 —— 见 `_allowedGoldSites` 下方注释。）
///
/// ⚠️ 本文件**不是**"靠注释提醒"：R1–R3 扫的是**源码正文**（注释已剥掉）。
void main() {
  // =====================================================================================
  // WCAG（与 theme_tokens_test 同一套公式）
  // =====================================================================================

  double luminance(Color c) {
    double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  // =====================================================================================
  // R4 · token 契约
  // =====================================================================================

  group('R4 · 两档金的取值与对比度', () {
    test('大字金 gold = #F59E0B（F 的橙金，保留）', () {
      expect(AppColors.gold, const Color(0xFFF59E0B));
    });

    test('小字金 goldText = #935F06（由 #F59E0B 同色相/同饱和降明度推导，不是新色相）', () {
      expect(AppColors.goldText, const Color(0xFF935F06));
      expect(AppColors.goldText.a, 1.0, reason: '必须是不透明实色（叠底不得变淡）');

      // 色相 / 饱和 与 gold 逐项相同 —— 证明"同一支金"
      final g = HSLColor.fromColor(AppColors.gold);
      final t = HSLColor.fromColor(AppColors.goldText);
      expect((t.hue - g.hue).abs(), lessThan(1.0), reason: '色相必须一致（否则是第二支金）');
      expect((t.saturation - g.saturation).abs(), lessThan(0.03), reason: '饱和必须一致');
      expect(t.lightness, lessThan(g.lightness), reason: '小字金只能更深');
    });

    test('小字金在 3 个底上全部 ≥4.5:1（白底 / 分区浅底 / 琥珀浅底）', () {
      final onWhite = contrast(AppColors.goldText, AppColors.bgCard);
      final onTint = contrast(AppColors.goldText, AppColors.ice);
      final onGoldSoft = contrast(AppColors.goldText, AppColors.goldSoft);
      // ignore: avoid_print
      print('[两档金] goldText 白底 ${onWhite.toStringAsFixed(2)}:1 · '
          '#EFF6FF ${onTint.toStringAsFixed(2)}:1 · #FEF3C7 ${onGoldSoft.toStringAsFixed(2)}:1');
      expect(onWhite, greaterThanOrEqualTo(4.5), reason: '白底 $onWhite');
      expect(onTint, greaterThanOrEqualTo(4.5), reason: '分区浅底 $onTint');
      expect(onGoldSoft, greaterThanOrEqualTo(4.5), reason: '琥珀浅底 $onGoldSoft');
    });

    test('对照：大字金 gold 白底确实不达标（这正是要分两档的原因，不是回归）', () {
      final onWhite = contrast(AppColors.gold, AppColors.bgCard);
      // ignore: avoid_print
      print('[两档金] gold 白底 ${onWhite.toStringAsFixed(2)}:1（F 的大字金取舍）');
      expect(onWhite, lessThan(4.5));
      expect(contrast(AppColors.goldText, AppColors.bgCard),
          greaterThan(contrast(AppColors.gold, AppColors.bgCard)));
    });
  });

  // =====================================================================================
  // R5 · 组件按字号自动选档（**最关键的一层**：连冻结文件也自动拿到深金）
  // =====================================================================================

  group('R5 · AppPrice / AppMoney 按字号自动选档', () {
    Future<void> pump(Widget w, WidgetTester t) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: w)));

    testWidgets('AppPrice：<19px 用 goldText、≥19px 用 gold、单位一律 goldText', (t) async {
      // 小字（页面里最典型的 15/17/18）
      for (final s in <double>[12, 15, 17, 18, 18.9]) {
        await pump(AppPrice(value: '¥18.80', size: s), t);
        expect(t.widget<Text>(find.text('¥18.80')).style!.color, AppColors.goldText,
            reason: 'size=$s 小于大字门槛 ${AppPrice.largeMoneySize} → 必须小字金');
      }
      // 大字
      for (final s in <double>[19, 22, 31]) {
        await pump(AppPrice(value: '¥18.80', size: s), t);
        expect(t.widget<Text>(find.text('¥18.80')).style!.color, AppColors.gold, reason: 'size=$s 是大字');
      }
      // 单位永远是"小字"（size×0.55）
      await pump(AppPrice(value: '¥18.80', unit: '/局', size: 19), t);
      expect(t.widget<Text>(find.text('/局')).style!.color, AppColors.goldText,
          reason: '单位紧跟数字、字号只有 10.45，必须用深金');
    });

    testWidgets('AppPrice：**显式传 T.gold 也照样降档**（这就是冻结文件不改也安全的原因）', (t) async {
      await pump(AppPrice(value: '¥9.90', size: 15, color: T.gold), t);
      expect(t.widget<Text>(find.text('¥9.90')).style!.color, AppColors.goldText);
      await pump(AppPrice(value: '¥9.90', size: 22, color: T.gold), t);
      expect(t.widget<Text>(find.text('¥9.90')).style!.color, AppColors.gold);
    });

    testWidgets('AppPrice：非金的自定义色原样保留（如"已退款"压灰）', (t) async {
      await pump(AppPrice(value: '¥9.90', size: 15, color: AppColors.textPlaceholder), t);
      expect(t.widget<Text>(find.text('¥9.90')).style!.color, AppColors.textPlaceholder);
    });

    testWidgets('AppMoney：三档 15/18 → goldText，22 → gold；单位灰不变', (t) async {
      for (final s in <AppFigureSize>[AppFigureSize.sm, AppFigureSize.md]) {
        await pump(AppMoney(8.8, size: s), t);
        expect(t.widget<Text>(find.text('¥8.80')).style!.color, AppColors.goldText,
            reason: '${s.value}px 属小字档');
        expect(t.widget<Text>(find.text('¥8.80')).style!.fontSize, s.value);
      }
      await pump(const AppMoney(8.8, size: AppFigureSize.lg), t);
      expect(t.widget<Text>(find.text('¥8.80')).style!.color, AppColors.gold);
      // 单位仍与金额异色（弱化灰），不受两档金影响
      await pump(const AppMoney(36.6, unit: '起'), t);
      expect(t.widget<Text>(find.text('起')).style!.color, AppColors.textPlaceholder);
    });

    test('两档门槛同源：AppPrice.largeMoneySize = 19（= WCAG 大字门槛 18.66 取整）', () {
      expect(AppPrice.largeMoneySize, 19);
      expect(AppMoney.unitSize, 12);
    });
  });

  // =====================================================================================
  // R1 / R2 / R3 · 源码级红线
  // =====================================================================================

  group('R1–R3 · 源码红线：小字场景不得直接引用 gold', () {
    // 仓库根：从测试进程工作目录往上找，定位同时含 core 与 boss-app 两层源码的那个目录
    Directory repoRoot() {
      var dir = Directory.current;
      for (var i = 0; i < 8; i++) {
        if (Directory('${dir.path}/apps/packages/core/lib/src').existsSync() &&
            Directory('${dir.path}/apps/boss-app/lib').existsSync()) {
          return dir;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
      // 兼容"直接在仓库根跑"的形态
      if (Directory('${dir.path}/packages/core/lib/src').existsSync()) return dir.parent.parent.parent;
      return dir;
    }

    /// 被扫的两层源码（**只扫 App 侧**：server / admin-web / h5-web 不在本轮范围）
    List<File> scannedSources() {
      final root = repoRoot();
      final out = <File>[];
      for (final rel in <String>['apps/packages/core/lib/src', 'apps/boss-app/lib']) {
        final d = Directory('${root.path}/$rel');
        if (!d.existsSync()) continue;
        out.addAll(d
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')));
      }
      out.sort((a, b) => a.path.compareTo(b.path));
      return out;
    }

    /// 剥掉注释（行注释 + 块注释）后的**代码正文**
    ///
    /// ⚠️ 本仓的 Dart 源码里没有"字符串内含 `//`"的关键行（与 `deco_test` 同一前提）；
    /// 注释里出现 `AppColors.gold` 不算违规 —— 红线的对象是**代码**。
    String codeOnly(String src) => src
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'//.*'), ''))
        .join('\n');

    /// 裸 `gold` 引用（**不含** goldText / goldSoft）
    final goldRe = RegExp(r'\b(?:AppColors|T)\.gold(?!Text|Soft)\b');

    /// 从 [index] 往前找最近的 [open] 调用，并返回它的括号区间；不在其内则返回 null
    List<int>? enclosingCall(String code, int index, String open) {
      var start = code.lastIndexOf(open, index);
      while (start >= 0) {
        var depth = 0;
        for (var i = start + open.length - 1; i < code.length; i++) {
          final ch = code[i];
          if (ch == '(') depth++;
          if (ch == ')') {
            depth--;
            if (depth == 0) {
              if (index > start && index < i) return [start, i];
              break;
            }
          }
        }
        start = code.lastIndexOf(open, start - 1);
      }
      return null;
    }

    double? fontSizeIn(String span) {
      final m = RegExp(r'fontSize:\s*([0-9.]+)').firstMatch(span);
      return m == null ? null : double.tryParse(m.group(1)!);
    }

    int? fontWeightIn(String span) {
      final m = RegExp(r'fontWeight:\s*FontWeight\.w(\d{3})').firstMatch(span);
      return m == null ? null : int.tryParse(m.group(1)!);
    }

    double? iconSizeIn(String span) {
      final m = RegExp(r'size:\s*([0-9.]+)').firstMatch(span);
      return m == null ? null : double.tryParse(m.group(1)!);
    }

    test('R1+R2 · TextStyle(<19px) / TextStyle(字重<w700) / Icon(<19px) 里不得出现 gold', () {
      final violations = <String>[];
      for (final f in scannedSources()) {
        final code = codeOnly(f.readAsStringSync());
        for (final m in goldRe.allMatches(code)) {
          // R1：TextStyle 内
          final ts = enclosingCall(code, m.start, 'TextStyle(');
          if (ts != null) {
            final span = code.substring(ts[0], ts[1]);
            final fs = fontSizeIn(span);
            final fw = fontWeightIn(span);
            if (fs != null && fs < AppPrice.largeMoneySize) {
              violations.add('${f.path}: TextStyle(fontSize: $fs) 里直接用 gold → 应改 goldText');
            }
            if (fw != null && fw < 700) {
              violations.add('${f.path}: TextStyle(fontWeight: w$fw) 里直接用 gold → 应改 goldText');
            }
          }
          // R2：Icon 内
          final ic = enclosingCall(code, m.start, 'Icon(');
          if (ic != null) {
            final span = code.substring(ic[0], ic[1]);
            final s = iconSizeIn(span);
            if (s != null && s < AppPrice.largeMoneySize) {
              violations.add('${f.path}: Icon(size: $s) 里直接用 gold → 应改 goldText');
            }
          }
        }
      }
      expect(violations, isEmpty,
          reason: '小字场景必须用 AppColors.goldText（#935F06）：\n${violations.join('\n')}');
    });

    test('R3 · 其余每一处裸 gold 引用都必须登记（新增或回退立刻红）', () {
      final seen = <String, int>{};
      for (final f in scannedSources()) {
        // 只登记**文件 → 次数**（与行号无关）：行号会随无关改动漂移，次数不会
        final rel = f.path.replaceAll('\\', '/').split('/apps/').last;
        final n = goldRe.allMatches(codeOnly(f.readAsStringSync())).length;
        if (n > 0) seen['apps/$rel'] = n;
      }

      // 期望值（每一处的理由见下方常量注释；改这里必须同时改代码）
      expect(seen, _allowedGoldSites,
          reason: '裸 gold 的落点变了 —— 若确实要新增"大字金额/非文字金"，请先改 '
              '_allowedGoldSites 并在注释里写明理由；若只是想给某处上色，请改用 goldText');
    });

    test('R3 · 白名单里的每一处都还活着（防止清单腐烂）', () {
      final seen = <String, int>{};
      for (final f in scannedSources()) {
        final rel = f.path.replaceAll('\\', '/').split('/apps/').last;
        final n = goldRe.allMatches(codeOnly(f.readAsStringSync())).length;
        if (n > 0) seen['apps/$rel'] = n;
      }
      for (final e in _allowedGoldSites.entries) {
        expect(seen[e.key], e.value, reason: '${e.key} 的 gold 处数与登记不符（清单已过期）');
      }
    });
  });
}

/// 裸 `gold`（= 只有大字金额 / 非文字落点才允许）的**全部**落点登记表
///
/// 规则：**文字与图标**只有在 ≥19px 且 w700+ 时才允许直接引用 `gold`；
/// 其余"非文字落点"（容器底色 / 描边 / 调试槽 / 组件内部选档）必须在这里写明理由。
/// 次数是"当前真实处数"——任何一次新增或回退都会让 R3 变红。
const Map<String, int> _allowedGoldSites = <String, int>{
  'apps/packages/core/lib/src/theme/theme_colors.dart': 1, // T.gold 门面（`get gold => AppColors.gold`）
  'apps/packages/core/lib/src/widgets/app_ui.dart': 3, // AppPrice.moneyInk：两处比较 + 一处大字返回
  'apps/packages/core/lib/src/widgets/product_badge.dart': 2, // 徽标实色底 + 描边（非文字）
  'apps/packages/core/lib/src/widgets/deco.dart': 1, // L-SLOT 等级位调试槽 debugColor（生产不渲染）
  'apps/packages/core/lib/src/identity/worker_hall_page.dart': 1, // 19px w700 大字金额
  'apps/packages/core/lib/src/identity/worker_mine_page.dart': 1, // 27px w700 大字金额
  'apps/packages/core/lib/src/identity/worker_wallet_page.dart': 1, // 30px w700 大字金额
  'apps/packages/core/lib/src/withdraw/worker_withdraw_page.dart': 1, // 30px w700 大字金额
  'apps/boss-app/lib/pages/product_detail_page.dart': 1, // 31px w800 大字金额
  'apps/boss-app/lib/pages/order_create_page.dart': 1, // AppPrice size 19（大字档）
  'apps/boss-app/lib/pages/membership_page.dart': 1, // 等级徽章圈的实色描边（非文字）
  // ↑ **2026-10-17 从这张表里摘掉 `product_list_page.dart`**（原登记 1 处：
  //   `AppPrice(..., size: 15, color: T.gold)`）。
  //   负责人本轮明确要求改这个文件（原「一行不动」冻结解除）：价格改成方案 G 的**黄色价格胶囊**
  //   —— `pricePillBg` `#FACC15` 底 + `pricePillInk` `#3B2400` 字（实测 9.7:1），于是
  //   `AppPrice` 的 color 传的是 `pricePillInk` 而不再是裸 `gold` → 该文件裸 gold 处数 **1 → 0**。
  //   这是"落点消失"，不是回退：金额仍只经 `fmtMoney` + `AppPrice`（`balance_display_test` ③
  //   的源码级绑定照旧逐字断言 `AppPrice(value: fmtMoney(p.price)`）。
  'apps/boss-app/lib/pages/leaderboard_page.dart': 1, // 榜首名次徽章实色底（非文字；F 的实色金胶囊范式）
  // ↑ 打手等级徽章（2026-10-17）**不进这张表**：`gradeInk()` 的 3 档与 4–5 档一律用
  //   `AppColors.goldText`（负责人 accessibility 裁决：徽章旁是 11px 文字，裸 `gold` 白底
  //   只有 2.15:1 读不清；深金 5.41:1 达标，图标与文字同色更整齐）→ 该文件裸 gold 处数 = 0。
};
