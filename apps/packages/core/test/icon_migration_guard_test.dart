import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **源码级红线：业务代码里不许再出现裸 `Icons.`（Material 图标字面量）**
///
/// 为什么要有这条：方案 F 的图标迁移靠**两条机械替换**（`Icons.` → `AppIconsLegacy.`、
/// `Icon(AppIcon.` → `AppIcon.of(AppIcon.`）铺完全仓；机械替换的敌人是"以后再有人顺手写一句
/// `Icon(Icons.xxx)`" —— 那种代码能编译、能跑，但**渲染回 Material 旧字形**，
/// 而且不会有任何测试挂掉。所以这里用源码级断言把它钉死（同 `money_gold_guard_test.dart` 的做法）。
///
/// 白名单只有三类，每一类都有明确理由（都是"登记在案的例外"，不是漏网）：
/// 1. `src/icons/app_icons_legacy.dart` —— **映射表本体**（旧 Material 名 → 新图标）；
/// 2. `src/icons/app_icon.dart` —— 迁移期**旧语义别名区**（70 条，值必须与迁移前逐字一致，
///    否则全仓 53 处 `find.byIcon` 断言会失效）；
/// 3. `src/update/` —— 云端更新模块，负责人 2026-10-16 明确**本轮不许改**（另一路在改）；
/// 4. `pages/product_list_page.dart` —— 负责人明确"商品列表页面一行不动（连图标都不换）"。
///
/// 扫描范围为 core 的 `lib/` 与同工作区 boss-app 的 `lib/`（`flutter test` 的 CWD = `apps/packages/core`）。
void main() {
  /// 裸 `Icons.`：前面不能是标识符字符（否则会误伤 `AppIcons.` / `AppIdentityIcons.`）
  final rawMaterialIcons = RegExp(r'(?<![A-Za-z0-9_])Icons\.');

  final allowPatterns = <String>[
    '/src/icons/app_icons_legacy.dart',
    '/src/icons/app_icon.dart',
    // 映射表的**语义面**：`feature_hues.dart` 的注释里逐条写着「这个键 = 哪个旧 Material 值」，
    // 那是给人看的对照表（删掉就不好维护了），所以登记为例外而不是改注释。
    '/src/theme/feature_hues.dart',
    '/src/update/',
    '/pages/product_list_page.dart',
  ];

  /// 返回 [root] 下**违反红线**的文件（相对路径，正斜杠）
  List<String> offenders(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final prefix = '${root.replaceAll(r'\', '/')}/';
    final bad = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final key = entity.path.replaceAll(r'\', '/');
      if (allowPatterns.any(key.contains)) continue;
      if (rawMaterialIcons.hasMatch(entity.readAsStringSync())) {
        bad.add(key.replaceFirst(prefix, ''));
      }
    }
    bad.sort();
    return bad;
  }

  test('core 的 lib/ 里零裸 Icons.（白名单：映射表本体 / update 模块 / 商品列表页）', () {
    final bad = offenders('lib');
    expect(bad, isEmpty, reason: '这些文件还写着 Material 图标字面量（会渲染回旧字形）：$bad');
  });

  test('boss-app 的 lib/ 里零裸 Icons.（同一条红线，两包一起守）', () {
    final bad = offenders('../../boss-app/lib');
    expect(bad, isEmpty, reason: 'boss-app 还有 Material 图标字面量：$bad');
  });

  test('红线扫描范围本身有效：两个 lib 根都能找到（防"路径写错 → 永远空通过"）', () {
    expect(Directory('lib').existsSync(), isTrue, reason: 'core 的 lib 必须存在');
    expect(
      Directory('../../boss-app/lib').existsSync(),
      isTrue,
      reason: 'boss-app 的 lib 必须存在（相对 `apps/packages/core` 是 ../../boss-app/lib）'
          ' —— 路径写错会让上面两条断言"空通过"',
    );
  });

  test('红线本身有效：造一个含 Icons. 的样本必须被抓出来（反证）', () {
    // 没有这条，"正则写错 → 永远为空 → 永远通过"就没人发现
    expect(rawMaterialIcons.hasMatch('Icon(Icons.bolt, size: 12)'), isTrue);
    expect(rawMaterialIcons.hasMatch('Icon(AppIconsLegacy.bolt)'), isFalse);
    expect(rawMaterialIcons.hasMatch('Icon(AppIdentityIcons.chevron)'), isFalse, reason: '含子串但非裸 Icons.，不许误伤');
    expect(rawMaterialIcons.hasMatch('Icon(AppIcons.bolt)'), isFalse);
  });
}
