// 用户可见文案护栏测试（core 自身 + 共享规则）
// ============================================================================
//
// 规则与扫描器在 `lib/src/util/user_visible_copy_guard.dart`（**只有一份实现**），
// 本文件负责在 core 包里跑它，并打印"扫了多少文件"。
// 老板端那份（`apps/boss-app/test/user_visible_copy_guard_test.dart`）复用同一套规则，
// 只是把扫描根指向 `apps/boss-app/lib` —— 这样新增页面/新增包都会自动被覆盖。
//
// 反面（红）自证：故意在任一被扫文件里加一句含「管理端」的可见文案，跑本测试必须 FAIL。
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cfg = CopyGuardConfig(
    root: resolveRepoRoot(), // 仓库根自动定位（flutter test 的工作目录不保证是包根）
    label: 'core',
    include: ['apps/packages/core/lib/src'],
  );

  test('core 的用户可见文案不含「管理端/后台/超管」等内部说法', () {
    final violations = UserVisibleCopyGuard.scan(cfg);
    final scanned = UserVisibleCopyGuard.fileCount(cfg);
    // 扫描面必须真实存在（防"扫描目录写错 → 0 文件 → 假绿"）。
    // 当前 core 实扫 64 个 dart 文件（护栏规则文件自身不计），下限 55 留余量。
    expect(scanned, greaterThan(55), reason: 'core 至少要扫到 55 个 dart 文件（实际 $scanned）');
    expect(
      violations,
      isEmpty,
      reason: '命中 ${violations.length} 处：\n${violations.join('\n')}\n\n'
          '改法：能用「客服 / 平台 / 官方」就别用「管理员」；'
          '「管理端」这类暴露实现的说法一律改成用户视角的说法。',
    );
  });

  test('白名单只放行「管理员身份」功能那几个文件（其余文件出现「管理员」即 FAIL）', () {
    // 规则自检：白名单必须是**收敛的**（防止以后有人图省事往白名单里塞文件）
    expect(
      UserVisibleCopyGuard.adminFeatureFiles.length,
      lessThanOrEqualTo(6),
      reason: '「管理员身份」是负责人定的功能名，白名单文件应当只有那几个（含切换入口与管理员态壳）',
    );
    for (final f in UserVisibleCopyGuard.adminFeatureFiles) {
      expect(
        UserVisibleCopyGuard.adminFeatureFiles.where((x) => x == f).length,
        1,
        reason: '白名单不得重复：$f',
      );
    }
    // 禁用词与「管理员」必须是两套判定（禁用词在任何文件都不放行）
    expect(UserVisibleCopyGuard.bannedWords, contains('管理端'));
    expect(UserVisibleCopyGuard.bannedWords, contains('超管'));
    expect(UserVisibleCopyGuard.bannedWords, isNot(contains('管理员')),
        reason: '「管理员」走白名单分支，不放进 bannedWords（否则白名单文件也会被拦）');
  });
}
