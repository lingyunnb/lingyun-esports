/**
 * 用户可见文案护栏（**扫描真实源码**，不是硬编码清单）
 * ============================================================================
 *
 * 负责人 2026-10-05 定案：「一切有关管理端的字眼不要给老板看，要不显得 AI。」
 * 2026-10-06 复述：「其他页面也是」——于是把它做成**护栏测试**，以后新增页面自动被覆盖。
 *
 * ## 拦什么
 * 1. **禁用词**（任何文件、任何位置都不许出现在用户可见字符串里）：
 *    `管理端` / `后台管理` / `管理中心` / `管理端维护` / `由管理端` / `超管` / `超级管理员`。
 *    这些词要么暴露实现（用户不该知道有个"端"在配），要么是内部称呼（"超管"）。
 * 2. **`管理员`**：只允许出现在 [adminFeatureFiles] 白名单文件里 ——
 *    那是负责人自己定的**「管理员身份」功能名**（进 App 内充值审核态的入口），
 *    属于功能本身而不是"暴露后台"。其它任何文件出现即 FAIL。
 *
 * ## 怎么判（关键：只看用户可见的字符串字面量）
 * - **逐行**读源码，先剥掉行内的 `//` / `///` 注释（代码注释与文档**不受此规则约束**，
 *   见 CLAUDE.md/负责人口径：注释与 `.md` 允许保留"管理端/管理员"）；
 * - 再抽出该行的单引号字符串字面量，命中禁用词即 FAIL；
 * - 命中时打印 `文件:行号` 与那一行的原文，便于直接定位。
 *
 * ## 局限（写在这里，别误以为它管了一切）
 * - **只管客户端写死的字面量**。服务端下发的文案（如 `message` / `divisionDenied`）
 *   不在扫描范围内 —— 那种要改服务端常量，另有断言（见 core 的
 *   `IdentityWorkerCleanliness` 与 boss-app 各页测试）。
 * - 注释里**引号包起来的**被禁词（如 `// 主文案（如「管理端还没上传商品图」）`）用的是
 *   中文书名号「」，不是被扫描的定界符，因此不会误报；
 * - 块注释（斜杠星号那种）、以及跨行字符串的续行行首 `'…` 不做特殊处理（本仓库不存在这两种写法）。
 *
 * ## 红→绿自证（务必保持有效）
 * 故意在任一被扫文件里加一句含「管理端」的可见文案 → 本测试必须变红；
 * 删掉后恢复绿。实测记录见 开发日志 2026-10-06。
 */
import 'dart:io';

/// 扫描配置（两个包各持一份路径，规则本身共用）
class CopyGuardConfig {
  const CopyGuardConfig({required this.root, required this.label, required this.include});

  /// 仓库根目录的**绝对路径**（用 [resolveRepoRoot] 从当前工作目录自动定位 ——
  /// `flutter test` 的工作目录并不保证是包根，写死相对层级会踩空）
  final String root;

  /// 报告里用的名字（如 `boss-app`）
  final String label;

  /// 要扫描的 lib 目录（相对 [root]）
  final List<String> include;
}

/// 从当前工作目录向上找**仓库根**（以 `apps/boss-app/lib` 与 `apps/packages/core/lib` 同时存在为准）
///
/// 为什么不能写死 `../../../`：`flutter test` 的进程工作目录由测试运行器决定
/// （实测在 boss-app 里跑时它并不是 `apps/boss-app`），写死相对层级会得到
/// `<cwd>/../../..//apps/boss-app/lib` 这种不存在的路径。
/// 向上找标记目录则与"从哪里跑"无关：包根、仓库根、甚至 test 目录下都能定位到。
String resolveRepoRoot({int maxUp = 8}) {
  var dir = Directory.current.absolute;
  for (var i = 0; i <= maxUp; i++) {
    final bossLib = Directory('${dir.path}/apps/boss-app/lib');
    final coreLib = Directory('${dir.path}/apps/packages/core/lib');
    if (bossLib.existsSync() && coreLib.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break; // 到盘符根了
    dir = parent;
  }
  throw StateError(
    '找不到仓库根（从 ${Directory.current.path} 向上 ${maxUp + 1} 层都没有 apps/boss-app/lib + apps/packages/core/lib，'
    '先 cd 到仓库里任意位置再跑测试）',
  );
}

/// 一条命中记录
class CopyViolation {
  const CopyViolation({required this.file, required this.line, required this.word, required this.text});

  final String file;
  final int line;
  final String word;
  final String text;

  @override
  String toString() => '$file:$line 命中「$word」→ $text';
}

/// 用户可见文案护栏的规则与扫描器（**规则只有一份**，两个包共用）
class UserVisibleCopyGuard {
  UserVisibleCopyGuard._();

  /// 任何文件都不许出现在用户可见字符串里的词
  static const List<String> bannedWords = [
    '管理端', // 暴露实现：用户不需要知道有个"管理端"
    '后台管理',
    '管理中心',
    '管理端维护',
    '由管理端',
    '超管', // 内部称呼
    '超级管理员', // 内部称呼（"管理员"另见白名单）
  ];

  /// 「管理员」**只允许**出现在这些文件（负责人自己定的「管理员身份」功能）
  ///
  /// 相对仓库根的路径；斜杠统一用 `/`。
  static const List<String> adminFeatureFiles = [
    // 「切换身份」弹层：我是管理员 / 管理员账号 / 管理员登录密码 / 绑定管理员账号（充值审核）
    'apps/packages/core/lib/src/identity/identity_switch_sheet.dart',
    // 管理员态（充值审核）壳：页头、细带、干净度黑名单
    'apps/packages/core/lib/src/recharge/recharge_admin_shell.dart',
    // 会话与身份提示：正在验证管理员账号… / 管理员身份已失效
    'apps/packages/core/lib/src/auth/auth_store.dart',
    // 身份切换过渡提示（[IdentityTransition.toAdmin]，含"切换身份"文案）
    'apps/packages/core/lib/src/identity/identity_widgets.dart',
  ];

  /// 「管理员身份」功能特有的**黑名单常量**例外
  /// （`recharge_admin_shell.dart` 的 `RechargeAdminCleanliness.adminForbiddenWords`）
  ///
  /// 那些值是**判定用的词表**：本身不出现在任何一屏上，只是被测试拿去比对页面文本；
  /// 但字面量确实就是被禁的那个词，所以按「文件 → 允许的字面量值」单独放行。
  /// 只放行列在这里的值，别处再出现同一个词照样 FAIL。
  ///
  /// 值用**全角转义**写，避免本文件被自己扫出命中。
  static const Map<String, Set<String>> literalExemptions = {
    'apps/packages/core/lib/src/recharge/recharge_admin_shell.dart': {
      '\u540E\u53F0\u7BA1\u7406', // 后台管理（词表值，见上）
    },
    // 提现链路（2026-10-11）：同样的"判定用词表"（提现审核屏禁用的管理端字眼，
    // 含「后台管理」）；值本身不出现在任何一屏上，只被测试拿去比对页面文本。
    'apps/packages/core/lib/src/withdraw/withdraw_models.dart': {
      '\u540E\u53F0\u7BA1\u7406', // 后台管理（词表值，见上）
    },
  };

  /// 规则文件自身不参与扫描
  ///
  /// 否则禁用词表 / 白名单表 / 判定逻辑自己的字符串字面量会把测试判红（自指）。
  /// 代价：这个文件里若真写了一句用户可见文案，护栏管不到它 —— 但它不含任何 UI，
  /// 且本文件不面向用户，可接受。
  static const String scannerFile = 'apps/packages/core/lib/src/util/user_visible_copy_guard.dart';

  /// 行内注释的起点（代码里的 `//`；不含 `://` 这种 URL 里的双斜杠）
  static final RegExp _lineComment = RegExp(r'(^|\s)//');

  /// 单引号字符串字面量（Dart 里本项目只用单引号；转义引号 `\'` 由 `[^']*` 自然跳过）
  static final RegExp _quoted = RegExp(r"'[^']*'");

  /// 「管理员」的判定用**全角转义**写，避免本文件被自己扫出命中：
  /// `\u7BA1\u7406\u5458` 就是「管理员」三个字（下方注释里也不出现该词）。
  static const String _adminWord = '\u7BA1\u7406\u5458';

  /// 扫描 [cfg] 覆盖的全部 `.dart` 文件，返回命中清单（按 文件 → 行号 稳定排序）
  static List<CopyViolation> scan(CopyGuardConfig cfg) {
    final violations = <CopyViolation>[];
    final files = <File>[];
    for (final dir in cfg.include) {
      final d = Directory('${cfg.root}/$dir');
      if (!d.existsSync()) {
        throw StateError('扫描目录不存在：${d.path}（护栏测试的 root 算错了？）');
      }
      files.addAll(d
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList());
    }
    // 稳定顺序：不依赖文件系统的枚举顺序，红→绿自证才能复现同一条
    files.sort((a, b) => a.path.compareTo(b.path));

    for (final f in files) {
      final rel = _relative(cfg.root, f.path);
      if (rel == scannerFile) continue; // 规则文件自身除外（见 [scannerFile]）
      final adminAllowed = adminFeatureFiles.contains(rel);
      final exempt = literalExemptions[rel] ?? const <String>{};
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final raw = lines[i];
        final commentAt = _lineComment.firstMatch(raw)?.start ?? -1;
        if (commentAt >= 0) {
          // `(^|\s)//` 的 start 落在空白或行首 → 从斜杠处切开
          final cut = raw[commentAt] == '/' ? commentAt : commentAt + 1;
          final code = raw.substring(0, cut);
          // 整行都是注释 → 整行跳过（注释不受本规则约束）
          if (code.trim().isEmpty) continue;
          _collect(violations, rel, i + 1, code, adminAllowed, exempt);
        } else {
          _collect(violations, rel, i + 1, raw, adminAllowed, exempt);
        }
      }
    }
    return violations;
  }

  /// 归一化成"相对仓库根 + 正斜杠"：Windows 下 `File.path` 同时可能出现 `\` 与 `/`
  /// （`Directory('$root/apps/...')` 拼出来的是混合分隔符），不归一化会与白名单路径对不上。
  static String _relative(String root, String path) {
    var p = path.replaceAll(r'\', '/');
    final r = root.replaceAll(r'\', '/');
    if (p.toLowerCase().startsWith('${r.toLowerCase()}/')) {
      p = p.substring(r.length + 1);
    }
    return p;
  }

  static void _collect(
    List<CopyViolation> out,
    String rel,
    int lineNo,
    String code,
    bool adminAllowed,
    Set<String> exempt,
  ) {
    for (final m in _quoted.allMatches(code)) {
      final value = m.group(0)!.replaceAll("'", '');
      // 词表例外：只放行列在这里的值（见 [literalExemptions]）
      if (exempt.contains(value)) continue;
      final literal = m.group(0)!;
      for (final w in bannedWords) {
        if (literal.contains(w)) {
          out.add(CopyViolation(file: rel, line: lineNo, word: w, text: code.trim()));
          break;
        }
      }
      if (!adminAllowed && literal.contains(_adminWord)) {
        out.add(CopyViolation(file: rel, line: lineNo, word: '$_adminWord（该文件不在「${_adminWord}身份」功能白名单里）', text: code.trim()));
      }
    }
  }

  /// 报告用：本次实际扫了多少个文件（与 [scan] 同一套枚举与排除规则）
  static int fileCount(CopyGuardConfig cfg) {
    var n = 0;
    for (final dir in cfg.include) {
      for (final f in Directory('${cfg.root}/$dir').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (_relative(cfg.root, f.path) == scannerFile) continue; // 规则文件自身不参与扫描
        n++;
      }
    }
    return n;
  }
}
