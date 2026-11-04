# -*- coding: utf-8 -*-
"""MiSans 字体子集化（生产版，可重跑 / 幂等 / 参数化）。

背景
----
`apps/boss-app/assets/fonts/MiSans-Normal.ttf` 是完整 MiSans（7.58MB / 2.9 万+ 码位），
打进 APK 后是最大的单个资源。实测把它子集到"本站真用得上的字符"可降到 ~1.6MB
（APK 内再省约 4.0MB / -15%），直接改善下载速度与流量。

**为什么不只子集"库里已用字符"（负责人 2026-10-06 裁决）**
----------------------------------------------------------
只按数据库当前存在的 627 个字符子集，用户改个昵称（生僻字）就会缺字。
所以目标字符集 = 三部分的并集：

  1. **GB2312 全集（6763 汉字 + 全角标点/希腊/俄文/序号）**
     —— 大陆日常用字的下界（一级 3755 + 二级 3008，含人名地名常用字）。
  2. **全库已用字符**（从数据库所有 varchar/text 列实拉，含 U+2795 ➕ 这类符号）
     —— 保证"现有数据一个字都不缺"。
  3. **常用符号 / 标点 / 拉丁 / 数字 / 单位 / 拉丁扩展**
     —— ℃ ㎡ · × ÷ ≈ ≥ ≤ ≠ ← → ↑ ↓ ★ ☆ ✓ ✗ ⚠ ①②③ ₽° 以及 Latin-1 补充、Latin Extended-A/B。

用法（fontTools 是**构建期工具**，不进 App 依赖；本机已随 scripts/tmp/_fonttools 落地）
----------------------------------------------------------------------------------------
    set PYTHONPATH=D:\\fish\\scripts\\tmp\\_fonttools
    python scripts/tools/subset-font.py                 # 只算+验，不落盘（dry-run）
    python scripts/tools/subset-font.py --write         # 写 assets（先自动备份原字体）
    python scripts/tools/subset-font.py --write --force # 产物已存在且指纹一致时也重写

幂等性：写入前比对"输入字体 sha256 + 字符集 sha256"，指纹写进 .subset-manifest.json；
一致且产物存在时直接跳过（打印 SKIP），不重复落盘、不重复备份。
"""
import argparse
import glob
import hashlib
import json
import os
import shutil
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
DEFAULT_SRC = os.path.join(REPO, 'apps', 'boss-app', 'assets', 'fonts', 'MiSans-Normal.ttf')
DEFAULT_OUT = os.path.join(REPO, 'apps', 'boss-app', 'assets', 'fonts', 'MiSans-Normal.ttf')
DEFAULT_BACKUP = os.path.join(REPO, 'data', 'backups', 'fonts')
MANIFEST = '.subset-manifest.json'

# 数据库直查（--used-from-db 时用）：走 docker exec，口令读 server/.env，不落任何临时文件
ENV_FILE = os.path.join(REPO, 'server', '.env')
MYSQL_CONTAINER = 'fish-mysql'


# --------------------------------------------------------------------------- 字符集

def gb2312_charset() -> set:
    """GB2312 全集：6763 个汉字 + 全角标点/希腊字母/俄文字母/序号等（约 7445 个码位）。"""
    out = set()
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                out.add(bytes([hi, lo]).decode('gb2312'))
            except UnicodeDecodeError:
                pass
    return out


def symbol_charset() -> set:
    """常用符号 / 标点 / 数字 / 单位 / 拉丁扩展（负责人 2026-10-06 指定必须覆盖）。

    刻意按**区段整段保留**而不是逐个列：区段很窄（总共约 1600 码位），
    省不下多少体积，却能把"漏一个符号就出豆腐块"的风险一次性消掉。
    """
    out = set(chr(c) for c in range(0x20, 0x7F))      # ASCII 可见字符（拉丁 + 数字 + 半角标点）
    out |= set(chr(c) for c in range(0xA0, 0x100))    # Latin-1 补充（°±×÷ 在 0xD7/0xF7）
    out |= set(chr(c) for c in range(0x100, 0x180))   # Latin Extended-A（ā ē ș ń…）
    out |= set(chr(c) for c in range(0x180, 0x2B0))   # Latin Extended-B（Ə ǎ ǒ ɐ ʃ…到 IPA 扩展前）
    out |= set(chr(c) for c in range(0x2B0, 0x300))   # 修饰字母（ʰ ʲ）+ 组合附加符号（注音/拼音声调）
    out |= set(chr(c) for c in range(0x300, 0x370))   # 组合附加符号补充
    out |= set(chr(c) for c in range(0x370, 0x400))   # 希腊字母（Δ π Ω）
    out |= set(chr(c) for c in range(0x400, 0x470))   # 西里尔字母 + 补充（Ѐ Ґ Ғ Ӏ，俄文/中亚 ID 常用）
    out |= set(chr(c) for c in range(0x2000, 0x2070))  # 通用标点 — – ‘ ’ “ ” … •
    out |= set(chr(c) for c in range(0x2070, 0x20D0))  # 上/下标 ⁰ ₂ ₽ ₹ € ₩
    out |= set(chr(c) for c in range(0x2100, 0x2140))  # 字母式符号 ™ № ℃ ℉
    out |= set(chr(c) for c in range(0x2150, 0x2190))  # 数字形式 ⅓ Ⅴ
    out |= set(chr(c) for c in range(0x2190, 0x21A0))  # 箭头 ← → ↑ ↓ ↔
    out |= set(chr(c) for c in range(0x21A0, 0x2200))  # 更多箭头 ⇄ ⇅
    out |= set(chr(c) for c in range(0x2200, 0x2300))  # 数学运算符 ∀ ∂ ∑ √ ∞ ≈ ≠ ≤ ≥
    out |= set(chr(c) for c in range(0x2460, 0x2500))  # 带圈数字/字母 ① ② ⑩ ⓐ
    out |= set(chr(c) for c in range(0x2500, 0x2580))  # 制表/框线 ─ │ ┌
    out |= set(chr(c) for c in range(0x2580, 0x25A0))  # 方块阴影 ░ ▒ ▓
    out |= set(chr(c) for c in range(0x25A0, 0x2600))  # 几何图形 ■ □ ▲ ◆ ● ○ ★ ☆
    out |= set(chr(c) for c in range(0x2600, 0x2700))  # 杂项符号 ☀ ☂ ☎ ✓ ✗ ⚠（含 ⚠ U+26A0）
    out |= set(chr(c) for c in range(0x2700, 0x27C0))  # Dingbats ➕ ✂ ✈ ✔ ✖（库里真有 U+2795 ➕）
    out |= set(chr(c) for c in range(0x2B00, 0x2C00))  # 杂项符号和箭头 ⬆ ⭐ ⭕
    out |= set(chr(c) for c in range(0x3000, 0x3040))  # CJK 标点 《》「」【】、。·〜
    out |= set(chr(c) for c in range(0x30FB, 0x30FC))  # 片假名中点 ・
    out |= set(chr(c) for c in range(0xFE10, 0xFE20))  # 竖排标点
    out |= set(chr(c) for c in range(0xFE30, 0xFE50))  # CJK 兼容形式 ︰
    out |= set(chr(c) for c in range(0xFF00, 0xFF60))  # 全角 ASCII（Ａ１，。！？）
    out |= set(chr(c) for c in range(0xFFE0, 0xFFE7))  # 全角货币 ￥ ＄ ￡
    # 负责人点名的单位/比较/温度符号（多数已在上面区段内，此处显式列出以免将来改区段时漏掉）
    out |= {'℃', '℉', '㎡', '㎥', '㎏', '㎝', '㎜', '°', '×', '÷', '≈', '≥', '≤', '≠',
            '±', '∞', '‰', '·', '—', '–', '…', '←', '→', '↑', '↓', '★', '☆',
            '✓', '✗', '✔', '✘', '⚠', '➕', '①'}
    return out


def used_from_db() -> str:
    """从数据库所有 varchar/text 列实拉全部文本（不挑列、不采样）。"""
    import re
    import subprocess

    env = {}
    with open(ENV_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^\s*([A-Za-z_]+)\s*=\s*(.*)$', line)
            if m:
                env[m.group(1)] = m.group(2).strip()

    def mysql(sql: str) -> str:
        cmd = ['docker', 'exec', '-i', MYSQL_CONTAINER, 'mysql',
               f"-u{env['DB_USER']}", f"-p{env['DB_PASSWORD']}",
               '--default-character-set=utf8mb4', '-N', '-B', env['DB_NAME']]
        # SQL 走 stdin：194 条语句拼起来远超 Windows 命令行上限（WinError 206）
        p = subprocess.run(cmd, input=sql, capture_output=True, text=True,
                           encoding='utf-8', errors='replace')
        if p.returncode != 0:
            sys.stderr.write(p.stderr)
            raise SystemExit(f'!! mysql 失败（exit {p.returncode}）')
        return p.stdout

    cols = [c.strip() for c in mysql("""
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
    raw = mysql('\n'.join(stmts)).replace('NULL', '')
    print(f'  数据库: {len(cols)} 个 varchar/text 列，取回 {len(raw)} 字符')
    return raw


# --------------------------------------------------------------------------- 工具

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def font_codepoints(path: str) -> set:
    from fontTools.ttLib import TTFont
    font = TTFont(path, lazy=True)
    out = set()
    for table in font['cmap'].tables:
        out |= set(table.cmap.keys())
    return out


def replace_with_retry(tmp_path: str, dst_path: str, tries: int = 6) -> None:
    """把 tmp 落到 dst，容忍 Windows 上的瞬时占用（杀软/索引器/编辑器句柄）。

    实测坑（2026-10-06）：
      * fontTools 的 `save()` 会**重新打开源字体写回**，句柄不关 → 下一次操作撞 WinError 32；
        因此调用处先 `font.close()` + gc，且临时文件名带 pid+时间戳（绝不复用旧路径）。
      * 只要临时文件本身被占用，`os.remove` 也会失败 —— 所以降级路径的删除是"尽力而为"，
        **不因为删不掉临时文件就判定失败**（目标文件已经写对了才是关键）。
    """
    last = None
    for i in range(tries):
        try:
            os.replace(tmp_path, dst_path)
            return
        except PermissionError as e:
            last = e
            try:
                # 退化路径：覆盖写（Windows 上 CopyFile 对"只读共享"句柄更宽容）
                shutil.copyfile(tmp_path, dst_path)
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass  # 临时文件残留无害：已被 .gitignore 之外的同名规则覆盖，且下次用新名字
                return
            except PermissionError as e2:
                last = e2
        time.sleep(0.3 * (i + 1))
    raise last if last else RuntimeError('replace failed')


def load_manifest(out_dir: str) -> dict:
    p = os.path.join(out_dir, MANIFEST)
    try:
        with open(p, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_manifest(out_dir: str, data: dict) -> None:
    with open(os.path.join(out_dir, MANIFEST), 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write('\n')


# --------------------------------------------------------------------------- 主流程

def main() -> int:
    ap = argparse.ArgumentParser(description='MiSans 字体子集化（可重跑、幂等）')
    ap.add_argument('--src', default=DEFAULT_SRC, help='源字体（默认 boss-app 的 MiSans-Normal.ttf）')
    ap.add_argument('--out', default=DEFAULT_OUT, help='产物路径（默认覆盖 boss-app 的 MiSans-Normal.ttf）')
    ap.add_argument('--backup-dir', default=DEFAULT_BACKUP, help='原字体备份目录（默认 data/backups/fonts）')
    ap.add_argument('--keep-name', action='store_true', default=True,
                    help='产物沿用 MiSans-Normal.ttf（默认；改名要同步改 pubspec/theme/测试，见 README）')
    ap.add_argument('--extra', default='', help='额外强制保留的字符（字符串，可多次用 `--extra 鑫`）')
    ap.add_argument('--extra-file', default='', help='额外字符文件（UTF-8，逐字符读取；用于数据库导出）')
    ap.add_argument('--used-from-db', action='store_true', help='连带把数据库全库已用字符并入目标集')
    ap.add_argument('--write', action='store_true', help='写入 --out（默认只算不写）')
    ap.add_argument('--force', action='store_true', help='指纹一致时也重写')
    ap.add_argument('--no-backup', action='store_true', help='不备份原字体（默认必备份）')
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    out = os.path.abspath(args.out)
    if not os.path.isfile(src):
        print(f'!! 找不到源字体: {src}')
        return 2
    try:
        from fontTools import subset
    except ImportError:
        print('!! 缺少 fontTools（构建期工具，不是 App 依赖）。可用本机已落地的副本：')
        print('   set PYTHONPATH=D:\\fish\\scripts\\tmp\\_fonttools')
        print('   或 pip install --target scripts/tmp/_fonttools fonttools')
        return 3

    # ---- 目标字符集
    want = symbol_charset() | gb2312_charset()
    n_sym, n_gb = len(symbol_charset()), len(gb2312_charset())
    if args.extra:
        want |= set(args.extra)
    if args.extra_file:
        with open(args.extra_file, 'r', encoding='utf-8') as f:
            want |= {ch for ch in f.read() if not ch.isspace()}
    db_used = set()
    if args.used_from_db:
        db_used = {ch for ch in used_from_db() if not ch.isspace()}
        want |= db_used

    have = font_codepoints(src)
    want_cp = {ord(c) for c in want if c}
    covered = want_cp & have
    missing_src = sorted(want_cp - have)          # 源字体本身没有 → 子集里也拿不到

    src_sha = sha256_file(src)
    charset_sha = hashlib.sha256(
        ''.join(sorted(chr(c) for c in want_cp)).encode('utf-8')).hexdigest()
    fingerprint = f'{src_sha[:16]}-{charset_sha[:16]}-{len(covered)}'

    print(f'源字体  : {src}')
    print(f'          {os.path.getsize(src) / 1048576:.2f} MB / {len(have)} 码位 / sha256 {src_sha[:16]}')
    print(f'目标集  : 符号标点拉丁 {n_sym} + GB2312 {n_gb}'
          + (f' + 库内已用 {len(db_used)}' if args.used_from_db else '')
          + (f' + extra {len(args.extra) + len(args.extra_file and "1" or "")}' if (args.extra or args.extra_file) else ''))
    print(f'          去重后 {len(want_cp)} 码位，源字体覆盖 {len(covered)}，源字体本身缺 {len(missing_src)}')
    if missing_src:
        print('          源字体没有的码位（子集里本来也拿不到，不影响）：'
              + ' '.join(f'U+{c:04X}' for c in missing_src[:20])
              + (' …' if len(missing_src) > 20 else ''))
    print(f'指纹    : {fingerprint}')

    # ---- 幂等判定
    # 幂等命中时**不留任何痕迹**：先把上次异常退出可能残留的临时产物清掉（前缀唯一，只删自己的）
    if args.write:
        for stale in glob.glob(out + '.tmp-subset-*'):
            try:
                os.remove(stale)
            except OSError:
                pass                                    # 被占用就留着，不影响正确性
    man = load_manifest(os.path.dirname(out))
    entry = (man.get('fonts') or {}).get(os.path.basename(out)) or {}
    if args.write and not args.force and os.path.isfile(out) and entry.get('fingerprint') == fingerprint:
        if os.path.getsize(out) == entry.get('outSize') and sha256_file(out) == entry.get('outSha256'):
            print(f'\nSKIP：{os.path.basename(out)} 已是该指纹的产物（--force 可强制重写）')
            return 0

    # ---- 备份（覆盖 assets 前）
    if args.write and not args.no_backup and os.path.abspath(src) == os.path.abspath(out):
        os.makedirs(args.backup_dir, exist_ok=True)
        stamp = time.strftime('%Y%m%d-%H%M%S')
        bak = os.path.join(args.backup_dir, f'{os.path.basename(src)}.{stamp}.orig')
        shutil.copy2(src, bak)
        with open(bak + '.sha256', 'w', encoding='ascii') as f:
            f.write(src_sha + '\n')
        print(f'备份    : {bak}  ({os.path.getsize(bak) / 1048576:.2f} MB)')

    # ---- 子集化
    opts = subset.Options()
    opts.layout_features = ['*']       # 保留 OpenType 布局：中文字距/标点挤压靠它，砍掉排版会变丑
    opts.name_IDs = ['*']              # 保留 name 表（字体全名/家族名）
    opts.name_legacy = True
    opts.notdef_outline = True         # 保留 .notdef 轮廓（真·缺字时至少画方框而不是空白）
    opts.recalc_bounds = True
    opts.drop_tables = ['DSIG']        # 子集后签名失效
    opts.hinting = False               # 手机高 DPI 无收益，去掉再省一点
    opts.desubroutinize = False

    tmp_out = (out + f'.tmp-subset-{os.getpid()}-{int(time.time())}' if args.write
               else os.path.join(REPO, 'scripts', 'tmp', 'MiSans-Normal.subset.ttf'))
    font = subset.load_font(src, opts)
    sub = subset.Subsetter(options=opts)
    sub.populate(unicodes=covered)
    sub.subset(font)
    subset.save_font(font, tmp_out, opts)
    # 关键：fontTools 的 save() 会**重新打开源文件**写入（tmp + 原文件回写），
    # 句柄不关就会在 Windows 上让后续 os.replace/os.remove 撞 WinError 32（实测踩过）。
    try:
        font.close()
    except Exception:  # noqa: BLE001 —— 关闭失败不影响产物正确性
        pass
    import gc
    gc.collect()

    out_size = os.path.getsize(tmp_out)
    src_size = os.path.getsize(src)
    # 复验：产物必须**至少**覆盖目标集里源字体有的那些码位
    got = font_codepoints(tmp_out)
    lost = sorted(covered - got)
    print('')
    print(f'产物    : {tmp_out}')
    print(f'          {out_size / 1048576:.2f} MB / {len(got)} 码位')
    print(f'节省    : {(src_size - out_size) / 1048576:.2f} MB '
          f'（{(1 - out_size / src_size) * 100:.1f}%），APK 内 deflate 后约省 '
          f'{(src_size - out_size) * 0.68 / 1048576:.2f} MB（字体已压缩，二次压缩比约 0.68）')
    print(f'产物复验: 目标集缺 {len(lost)} 个码位'
          + ('  ← 必须为 0！' if lost else ' ✓'))
    if lost:
        print('  ' + ' '.join(f'U+{c:04X}' for c in lost[:40]))
        os.remove(tmp_out)
        return 4

    if not args.write:
        try:
            os.remove(tmp_out)
        except OSError:
            pass
        print('（未给 --write：已删除临时产物，assets 下一个字节都没动）')
        return 0

    if os.path.abspath(tmp_out) != out:
        replace_with_retry(tmp_out, out)
    if os.path.getsize(out) != out_size:
        print(f'!! 写入后大小不符：期望 {out_size}，实际 {os.path.getsize(out)}')
        return 5

    out_sha = sha256_file(out)
    prev = (man.get('fonts') or {}).get(os.path.basename(out)) or {}
    # 记录"**原始完整字体**的 sha256"，而不是"上一次作为输入的那个字体"：
    # 幂等复跑时输入已经是上一次的子集产物，若把当时的 src_sha 当 sourceSha256 写，
    # 就会把"工件自己的哈希"混进"基线来源"，后人无法据此找回原始字体。故只认第一次。
    baseline = prev.get('baselineSha256') or (
        prev.get('sourceSha256') if prev.get('baselineSha256') else src_sha)
    man.setdefault('fonts', {})[os.path.basename(out)] = {
        'source': f'apps/boss-app/assets/fonts/{os.path.basename(out)}',
        'baselineSha256': baseline,
        'baselineSize': prev.get('baselineSize') or max(src_size, os.path.getsize(out)),
        'sourceSha256': src_sha,
        'sourceSize': src_size,
        'charsetSha256': charset_sha,
        'charsetCodePoints': len(want_cp),
        'coveredCodePoints': len(covered),
        'fingerprint': fingerprint,
        'outSha256': out_sha,
        'outSize': out_size,
        'builtAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    }
    man['_howto'] = ('python scripts/tools/subset-font.py --write --used-from-db'
                     '   （PYTHONPATH 指向 fontTools；见 scripts/tools/README-font-subset.md）')
    save_manifest(os.path.dirname(out), man)
    print(f'写入    : {out} → sha256 {out_sha[:16]}')
    print(f'清单    : {os.path.join(os.path.dirname(out), MANIFEST)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
