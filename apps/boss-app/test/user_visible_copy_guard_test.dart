// 用户可见文案护栏测试（**老板端全部页面**）
// ============================================================================
//
// 负责人 2026-10-05/06：「一切有关管理端的字眼不要给老板看，要不显得 AI。其他页面也是。」
//
// 本测试**读老板端真实源码**（`apps/boss-app/lib/` 下全部 dart 文件）逐行扫字符串字面量，
// 命中禁用词即 FAIL —— 所以以后**新增页面自动被覆盖**，不需要往清单里补文件。
//
// 判据与白名单见 `fish_core` 的 `lib/src/util/user_visible_copy_guard.dart`（规则只有一份）：
//   - 禁用词（任何文件都不许出现在可见文案里）：管理端、后台管理、管理中心、管理端维护、由管理端、超管、超级管理员
//   - `管理员`：只允许出现在「管理员身份」功能那几个文件（白名单在 core，不在这里）
//   - **代码注释不受约束**（`//`、`///` 在扫描时被剥掉）
//
// 红→绿自证：临时加一句含「管理端」的可见文案 → 本测试 FAIL（打印 文件:行号）；
// 删掉 → 恢复绿。记录见 开发日志 2026-10-06。
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cfg = CopyGuardConfig(
    root: resolveRepoRoot(), // 仓库根自动定位（flutter test 的工作目录不保证是包根）
    label: 'boss-app',
    include: [
      'apps/boss-app/lib',
      // 老板端页面直接用 core 的组件与页面（打手态/管理员态也在 core）→ core 一并纳入
      'apps/packages/core/lib/src',
    ],
  );

  test('老板端 + core 的用户可见文案不含「管理端/后台/超管」等内部说法', () {
    final violations = UserVisibleCopyGuard.scan(cfg);
    final scanned = UserVisibleCopyGuard.fileCount(cfg);
    // 当前实扫 106 个 dart 文件（老板端 lib 42 + core/src 64，护栏规则文件自身不计），下限 100 留余量
    expect(scanned, greaterThan(100), reason: '老板端 + core 至少要扫到 100 个 dart 文件（实际 $scanned）');
    expect(
      violations,
      isEmpty,
      reason: '命中 ${violations.length} 处：\n${violations.join('\n')}\n\n'
          '改法：用户视角的说法 =「客服 / 平台 / 官方」；'
          '不要写「管理端配置 / 后台维护 / 由管理员发放」这类暴露实现或内部称呼的话。',
    );
  });
}
