"""
竞品 APK 设计规格提取器 v3（原生 Android 专用）
==============================================
用 androguard 的 ARSC 解析 API 正确读出**编译后的资源**（v2 当文本读所以 0 命中）：
  · get_color_resources()  → 全部颜色
  · get_dimen_resources()  → 全部尺寸（间距/字号/圆角）
  · get_resource_style()   → 主题与样式
  · res/color/*.xml        → AXML 解码（色值状态列表）

**边界**：只提取【色值/尺寸/结构】等设计规范；不导出文案、不复制图片与品牌资产。
过滤掉 AndroidX / Material / 系统库的色与尺寸（`abc_` `mtrl_` `android_` `compat_` 等），
只留**该 App 自研**的部分 —— 那才是它的设计语言。

用法: python scripts/tools/apk-design-spec-v3.py <apk> [--out 目录]
"""
import os, sys, zipfile, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
from collections import Counter, defaultdict

os.environ.setdefault('LOGURU_LEVEL', 'CRITICAL')
try:
    from loguru import logger as _lg
    _lg.remove()
except Exception:
    pass

# 第三方/系统资源前缀（这些不是该 App 的设计语言）
LIBS = ('abc_', 'mtrl_', 'android_', 'compat_', 'notification_', 'material_', 'design_',
        'preference_', 'appcompat_', 'ui_', 'tt_', 'umeng_', 'tbs_', 'tencent_', 'wx_',
        'amap_', 'bugly_', 'nim_', 'jrmf_', 'zxing_', 'ucrop_', 'picture_', 'camera_',
        'banner_', 'smartrefresh_', 'recyclerview_', 'viewpager_', 'fragment_', 'titlebar_',
        'expand_', 'sunmi_', 'svga_', 'lottie_', 'glide_', 'okhttp_', 'mmkv_', 'bd_')

def is_lib(name):
    n = str(name).lower()
    return any(n.startswith(p) for p in LIBS)


def argb(v):
    """把资源值转成 #AARRGGBB"""
    try:
        if isinstance(v, str):
            s = v.strip()
            if s.startswith('#') and len(s) in (7, 9):
                return s.lower()
            iv = int(s, 0) if s.lower().startswith('0x') or s.isdigit() else None
            if iv is None:
                return None
        elif isinstance(v, int):
            iv = v
        else:
            return None
        return '#%08x' % (iv & 0xFFFFFFFF)
    except Exception:
        return None


def main():
    apk_path = sys.argv[1]
    out_dir = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None

    lines = []
    def p(s=""):
        lines.append(str(s)); print(s)

    p("=" * 78)
    p("竞品 APK 设计规格提取 v3 —— 东东电竞类原生 Android")
    p("文件: %s  %.1f MB" % (os.path.basename(apk_path), os.path.getsize(apk_path) / 1024 / 1024))
    p("=" * 78)

    from androguard.core.apk import APK
    a = APK(apk_path)
    arsc = a.get_android_resources()

    # ---------- 1) 颜色 ----------
    p("\n【1】自研颜色（已过滤 AndroidX/Material/系统库）")
    try:
        PKGS = arsc.get_packages_names()
        colors = {}
        for _pkg in PKGS:
            try:
                colors.update(arsc.get_color_resources(_pkg) or {})
            except Exception as _e:
                p('  (包 %s color 读取失败: %s)' % (_pkg, _e))
        p("  ARSC 里 color 资源共 %d 个 res_id" % len(colors))
        rows = []
        for res_id, cfgmap in colors.items():
            if not isinstance(cfgmap, dict):
                continue
            for cfg, val in cfgmap.items():
                name = None
                try:
                    name = arsc.get_resource_xml_name(res_id) if hasattr(arsc, 'get_resource_xml_name') else None
                except Exception:
                    pass
                nm = str(name or '')
                if nm and is_lib(nm.split('/')[-1]):
                    continue
                h = argb(val)
                if h:
                    rows.append((nm or ('res_0x%08x' % res_id), h, str(cfg)))
        # 频次统计（同一色值被多少处引用）
        cnt = Counter(h for _, h, _ in rows)
        p("  自研色值（去重 %d 个，按引用次数排序，Top 40）:" % len(cnt))
        for h, c in cnt.most_common(40):
            a_ = int(h[1:3], 16)
            op = "" if a_ == 255 else "  (alpha %d)" % a_
            p("      %-11s ×%-4d%s" % (h, c, op))
        # 不过滤的全量 Top（判断主色）
        allc = Counter()
        for rid, cfgmap in colors.items():
            if isinstance(cfgmap, dict):
                for cfg, val in cfgmap.items():
                    h = argb(val)
                    if h:
                        allc[h] += 1
        p("\n  含库在内的全量色值 Top 20（用于看整体倾向）:")
        for h, c in allc.most_common(20):
            p("      %-11s ×%d" % (h, c))
        # 深/浅倾向
        dark = sum(c for h, c in allc.items() if int(h[3:5], 16) < 0x60)
        light = sum(c for h, c in allc.items() if int(h[3:5], 16) > 0xB0)
        p("\n  倾向：深色系 %d / 浅色系 %d %s" % (dark, light,
          "→ 偏深色底" if dark > light * 1.5 else ("→ 偏浅色底" if light > dark * 1.5 else "→ 深浅均衡")))
    except Exception as e:
        p("  [!] 失败: %s: %s" % (type(e).__name__, e))

    # ---------- 2) 尺寸 ----------
    p("\n【2】自研尺寸（间距 / 字号 / 圆角）")
    try:
        dimens = {}
        for _pkg in PKGS:
            try:
                dimens.update(arsc.get_dimen_resources(_pkg) or {})
            except Exception as _e:
                p('  (包 %s dimen 读取失败: %s)' % (_pkg, _e))
        p("  ARSC 里 dimen 资源共 %d 个" % len(dimens))
        drows = []
        for res_id, cfgmap in dimens.items():
            if not isinstance(cfgmap, dict):
                continue
            for cfg, val in cfgmap.items():
                nm = ''
                try:
                    nm = str(arsc.get_resource_xml_name(res_id) or '')
                except Exception:
                    pass
                if nm and is_lib(nm.split('/')[-1]):
                    continue
                # dimen 值可能是 (size, unit) 或字符串
                drows.append((nm, val, str(cfg)))
        vc = Counter()
        for nm, val, cfg in drows:
            vc[str(val)] += 1
        p("  尺寸值频次 Top 35（看它用的是哪套刻度）:")
        for v, c in vc.most_common(35):
            p("      %-22s ×%d" % (v, c))
        p("\n  自研 dimen 资源名样例（前 30 个，看命名体系）:")
        for nm, val, cfg in drows[:30]:
            p("      %-42s = %s" % (nm.split('/')[-1][:42], val))
    except Exception as e:
        p("  [!] 失败: %s: %s" % (type(e).__name__, e))

    # ---------- 3) AXML 解码 res/color/*.xml ----------
    p("\n【3】res/color/*.xml 解码（色值状态列表 —— 这些没被混淆）")
    try:
        from androguard.core.axml import AXMLPrinter
        z = zipfile.ZipFile(apk_path)
        cl = [n for n in z.namelist() if re.match(r'^res/color[^/]*/.*\.xml$', n)]
        p("  共 %d 个，取前 8 个解码:" % len(cl))
        for n in cl[:8]:
            try:
                pr = AXMLPrinter(z.read(n))
                xml = pr.get_xml().decode('utf-8', 'ignore') if pr.get_xml() else ''
                hx = sorted(set(re.findall(r'#[0-9a-fA-F]{6,8}', xml)))
                p("      %-46s → %s" % (os.path.basename(n), ', '.join(hx[:6]) if hx else '(无字面色值)'))
            except Exception as e:
                p("      %-46s [!] %s" % (os.path.basename(n), type(e).__name__))
    except Exception as e:
        p("  [!] 失败: %s: %s" % (type(e).__name__, e))

    # ---------- 4) 结构规模 ----------
    p("\n【4】结构规模")
    try:
        z = zipfile.ZipFile(apk_path)
        names = z.namelist()
        dex = [n for n in names if n.endswith('.dex')]
        p("  dex %d 个 / %.1f MB" % (len(dex), sum(z.getinfo(n).file_size for n in dex) / 1024 / 1024))
        p("  res/ XML %d 个（名称已混淆）" % len([n for n in names if n.startswith('res/') and n.endswith('.xml')]))
        p("  图片 %d 个" % len([n for n in names
            if n.startswith('res/') and os.path.splitext(n)[1].lower() in ('.png', '.webp', '.jpg', '.jpeg')]))
        p("  assets %d 个 / %.1f MB" % (
            len([n for n in names if n.startswith('assets/')]),
            sum(z.getinfo(n).file_size for n in names if n.startswith('assets/')) / 1024 / 1024))
        acts = a.get_activities() or []
        p("  Activity %d 个（信息架构线索）" % len(acts))
    except Exception as e:
        p("  [!] 失败: %s" % e)

    p("\n" + "=" * 78)
    p("说明：本报告只含【颜色/尺寸/结构】等设计规范；**不含文案、不含图片**。")
    p("=" * 78)

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        fp = os.path.join(out_dir, os.path.splitext(os.path.basename(apk_path))[0] + '-design-v3.txt')
        with open(fp, 'w', encoding='utf-8') as f:
            f.write("\n".join(lines))
        print("\n已写入: %s" % fp)


if __name__ == '__main__':
    main()
