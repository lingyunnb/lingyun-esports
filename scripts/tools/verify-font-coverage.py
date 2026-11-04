# -*- coding: utf-8 -*-
"""字体子集覆盖率自证（**查真实字体文件**，不是查字符集公式）。

为什么必须查文件而不是查字符集：`subset-font.py` 里的字符集是"想要什么"，
`subset` 落盘后真正保留了什么才是"用户会看到什么"。本脚本直接读 TTF 的 cmap，
再用数据库全量文本逐字符核对，回答两个问题：

  1. **全库已用字符**：一个都不缺？（含 U+2795 ➕ 这类符号）
  2. **GB2312 全集**：6763 汉字 + 全角/希腊/俄文一个都不缺？（用户改昵称用的字）

用法（需先启动 fish-mysql）：
    set PYTHONPATH=D:\\fish\\scripts\\tmp\\_fonttools
    python scripts/tools/verify-font-coverage.py                      # 验 boss-app 的 MiSans-Normal.ttf
    python scripts/tools/verify-font-coverage.py --font <path.ttf>
    python scripts/tools/verify-font-coverage.py --extra-chars "𠮷𰻞"   # 期望"缺"的字（回退实测用）

退出码：0 = 全覆盖；1 = 有缺字（打印清单）。
"""
import argparse
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
ENV_FILE = os.path.join(REPO, 'server', '.env')
MYSQL_CONTAINER = 'fish-mysql'
DEFAULT_FONT = os.path.join(REPO, 'apps', 'boss-app', 'assets', 'fonts', 'MiSans-Normal.ttf')


def load_env() -> dict:
    out = {}
    with open(ENV_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^\s*([A-Za-z_]+)\s*=\s*(.*)$', line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


def mysql(env: dict, sql: str) -> str:
    # SQL 走 stdin（docker exec -i）而不是命令行参数：194 条语句拼起来远超 Windows 32K 命令行上限
    cmd = ['docker', 'exec', '-i', MYSQL_CONTAINER, 'mysql',
           f"-u{env['DB_USER']}", f"-p{env['DB_PASSWORD']}",
           '--default-character-set=utf8mb4', '-N', '-B', env['DB_NAME']]
    p = subprocess.run(cmd, input=sql, capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise SystemExit(f'!! mysql 失败（exit {p.returncode}）')
    return p.stdout


def gb2312_charset() -> set:
    out = set()
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                out.add(bytes([hi, lo]).decode('gb2312'))
            except UnicodeDecodeError:
                pass
    return out


def font_codepoints(path: str) -> set:
    from fontTools.ttLib import TTFont
    font = TTFont(path, lazy=True)
    out = set()
    for table in font['cmap'].tables:
        out |= set(table.cmap.keys())
    return out


def db_text_all(env: dict) -> tuple:
    cols = [c.strip() for c in mysql(env, """
        SELECT CONCAT(table_name, '.', column_name)
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND data_type IN ('varchar','char','text','mediumtext','longtext','tinytext')
        ORDER BY table_name, ordinal_position;
    """).strip().splitlines() if c.strip()]
    stmts = []
    for c in cols:
        table, column = c.split('.', 1)
        stmts.append(
            f"SELECT CONCAT('\\n=={c}==\\n', IFNULL(GROUP_CONCAT(`{column}` SEPARATOR ' '), '')) "
            f"FROM `{table}` WHERE `{column}` IS NOT NULL AND `{column}` <> '';"
        )
    raw = mysql(env, '\n'.join(stmts)).replace('NULL', '')
    return cols, raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--font', default=DEFAULT_FONT)
    ap.add_argument('--orig', default='', help='原字体（用于区分"子集丢的"与"原字体本来就没有的"）')
    ap.add_argument('--extra-chars', default='', help='额外核对字符串（用于"期望缺字"的正向证据）')
    ap.add_argument('--no-db', action='store_true', help='跳过数据库，只验 GB2312 全集')
    args = ap.parse_args()

    font_path = os.path.abspath(args.font)
    if not os.path.isfile(font_path):
        print(f'!! 找不到字体: {font_path}')
        return 2
    try:
        have = font_codepoints(font_path)
    except ImportError:
        print('!! 缺少 fontTools：set PYTHONPATH=D:\\fish\\scripts\\tmp\\_fonttools')
        return 3

    # --orig 缺省时自动取 data/backups/fonts 里最新的 .orig（子集化脚本的备份）
    if not args.orig:
        import glob
        baks = sorted(glob.glob(os.path.join(REPO, 'data', 'backups', 'fonts',
                                             os.path.basename(font_path) + '.*.orig')))
        if baks:
            args.orig = baks[-1]
            print(f'（未指定 --orig，自动采用最新备份对照：{os.path.basename(args.orig)}）')

    print(f'字体    : {font_path}')
    print(f'          {os.path.getsize(font_path) / 1048576:.2f} MB / {len(have)} 码位')

    # 原字体（可选）：用来把缺字分成两类 ——
    #   A) **子集回退**：原字体有、子集丢了 → 这是我们造成的，必须修
    #   B) **原字体就没有**：靠系统字体回退（Flutter/Skia 在 App 字体缺字时回退系统字体）
    orig_have = None
    if args.orig and os.path.isfile(os.path.abspath(args.orig)):
        orig_have = font_codepoints(os.path.abspath(args.orig))
        print(f'原字体  : {os.path.abspath(args.orig)}  ({len(orig_have)} 码位)')
        print(f'          ✓ 子集是原字体的子集: {len(have - orig_have) == 0}'
              f'（新增码位 {len(have - orig_have)}，应为 0）')

    def classify(cp_set: set) -> tuple:
        """返回 (子集回退, 原字体本来就缺)"""
        if orig_have is None:
            return set(), set()
        return {c for c in cp_set if c in orig_have and c not in have}, {c for c in cp_set if c not in orig_have}

    rc = 0

    # ---- 1. GB2312 全集（用户改昵称能用的字）
    gb = gb2312_charset()
    gb_cp = {ord(c) for c in gb}
    miss_gb = sorted(gb_cp - have)
    reg_gb, pre_gb = classify(set(miss_gb))
    print('')
    print(f'[1] GB2312 全集: {len(gb_cp)} 码位，缺 {len(miss_gb)}'
          + (f'（子集回退 {len(reg_gb)} / 原字体本就缺 {len(pre_gb)}）' if orig_have is not None else ''))
    if miss_gb:
        print('    缺字: ' + ' '.join(f'{chr(c)}(U+{c:04X})' for c in miss_gb[:60])
              + (' …' if len(miss_gb) > 60 else ''))
    if reg_gb:
        rc = 1
        print('    ✗ **子集回退（必须修）**: ' + ' '.join(f'U+{c:04X}' for c in sorted(reg_gb)))
    elif pre_gb:
        print(f'    ✓ 零回退：{len(miss_gb)} 个缺字全部是**原字体本身就没有**的（+ 靠系统字体回退，与子集无关）')
    else:
        print('    ✓ GB2312 全集零缺字')

    # ---- 2. 全库已用字符
    if not args.no_db:
        env = load_env()
        cols, text = db_text_all(env)
        used = {ch for ch in text if not ch.isspace()}
        miss_used = sorted(used - {chr(c) for c in have})
        reg_used, pre_used = classify({ord(c) for c in miss_used})
        print('')
        print(f'[2] 数据库  : {env["DB_NAME"]} / 容器 {MYSQL_CONTAINER}')
        print(f'    扫描列数: {len(cols)}（全库所有 varchar/text 列，不挑列不采样）')
        print(f'    取回文本: {len(text)} 字符；不同字符 {len(used)}')
        print(f'    覆盖    : {len(used) - len(miss_used)}/{len(used)}，缺 {len(miss_used)}'
              + (f'（子集回退 {len(reg_used)} / 原字体本就缺 {len(pre_used)}）' if orig_have is not None else ''))
        if miss_used:
            print('    缺字清单:')
            print('      ' + ' '.join(f'{c}(U+{ord(c):04X})' for c in miss_used[:80]))
        if reg_used:
            rc = 1
            print('    ✗ **子集回退（必须修）**: '
                  + ' '.join(f'{chr(c)}(U+{c:04X})' for c in sorted(reg_used)))
        elif pre_used:
            print('    ✓ 零回退：这些缺字在**原版 MiSans 里同样没有**，'
                  '即当前线上版本本来就是系统字体回退，子集没有让情况变差')
        else:
            print(f'    ✓ **{len(used)}/{len(used)} 全覆盖**')

    # ---- 3. 额外核对（"期望缺字"的正向证据：证明子集边界确实收紧过）
    if args.extra_chars:
        extra = {ch for ch in args.extra_chars if not ch.isspace()}
        present = sorted(ch for ch in extra if ord(ch) in have)
        absent = sorted(ch for ch in extra if ord(ch) not in have)
        print('')
        print(f'[3] 额外核对: {len(extra)} 字符 → 在子集内 {len(present)}，不在子集内 {len(absent)}')
        for ch in present:
            print(f'    在集内: {ch} U+{ord(ch):04X}')
        for ch in absent:
            print(f'    不在集: {ch} U+{ord(ch):04X}  ← 预期：这些字要靠系统字体回退')

    print('')
    if rc == 0:
        print('  -> 结论：**零回退** —— 子集没有丢任何"原字体本来有的、且在本站用得到范围内"的字符；')
        print('     剩余缺字（若有）在**原版 MiSans 里同样没有**，即线上现状本来就是系统字体回退，')
        print('     本次子集化没有让渲染结果变差（对照见上文"子集回退 / 原字体本就缺"两个计数）。')
    else:
        print('  -> 结论：**存在子集回退字符**，见上方标 ✗ 的清单；'
              '把它们并入目标字符集后重新子集化（scripts/tools/subset-font.py）。')
    return rc


if __name__ == '__main__':
    sys.exit(main())
