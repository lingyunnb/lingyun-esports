"""
APK 设计规格提取器 v2（竞品设计研究 + 自查）
===========================================
关键改进：**先识别技术栈**，再按栈选提取路径 ——
  原生 Android → res/values/*.xml + res/color/*.xml 有可读色值
  Flutter      → 界面在 libapp.so（Android 资源里几乎没东西）
  React Native → assets/index.android.bundle 里的 JS 有大量可读色值/字号
  uni-app/小程序 → assets/app-service.js / app-view.js 同理（CSS 风格）
  Cordova/Ionic → assets/www/ 下的 HTML/CSS

对"设计规范提取"最有价值的是 **RN / uni-app / H5 系**：它们的样式是**可读文本**
（颜色 #RRGGBB、字号 px/rpx、间距）→ 能直接量化出竞品的规范。

**边界**：只提取【色值/字号/间距/结构】等规范；**不导出文案、不复制图片与品牌资产**。

用法: python scripts/tools/apk-design-spec.py <apk> [--out 目录]
"""
import sys, os, zipfile, re, json
from collections import Counter

os.environ.setdefault('LOGURU_LEVEL', 'CRITICAL')
try:
    from loguru import logger as _lg
    _lg.remove()
except Exception:
    pass


def detect_stack(z, names):
    """识别技术栈（决定后面怎么提取）"""
    s = []
    if any(n.startswith('lib/') and 'libflutter.so' in n for n in names):
        s.append('Flutter')
        libs = [n for n in names if n.endswith('libapp.so')]
        s.append('  libapp.so: %s' % (', '.join(os.path.basename(x) for x in libs) or '未找到'))
    if any('libhermes.so' in n or 'libhermes' in n for n in names):
        s.append('React Native（Hermes 引擎）')
    if any(n.startswith('assets/') and n.endswith('.bundle') for n in names):
        s.append('React Native（JS bundle）')
    if any(n.startswith('assets/app-service.js') or n.startswith('assets/app-view.js') for n in names):
        s.append('uni-app / 小程序（Vue 系）')
    if any(n.startswith('assets/www/') for n in names):
        s.append('Cordova / Ionic（H5）')
    if any(n.endswith('.dex') for n in names) and not s:
        s.append('原生 Android（Java/Kotlin）')
    if any('libreactnativejni' in n for n in names):
        s.append('React Native（JNI）')
    if any(n.startswith('assets/') and ('taro' in n.lower() or 'vconsole' in n.lower()) for n in names):
        s.append('H5 混合 / Taro / vConsole 调试包')
    return s or ['未能识别']


HEX = re.compile(rb'#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b')
DIM = re.compile(rb'(\d+(?:\.\d+)?)(rpx|px|dp|sp|rem|em)\b')


def scan_blob(data, label, out, topn=28):
    """从一段（可能是 JS/CSS/XML 的）字节里扫色值与尺寸单位"""
    hexes = Counter(m.group(0).decode().lower() for m in HEX.finditer(data))
    dims = Counter(m.group(0).decode() for m in DIM.finditer(data))
    if hexes:
        out.append("  [%s] 色值去重 %d 个，Top %d：" % (label, len(hexes), min(topn, len(hexes))))
        for h, c in hexes.most_common(topn):
            out.append("      %-11s ×%d" % (h, c))
    else:
        out.append("  [%s] 未发现可读色值" % label)
    if dims:
        out.append("  [%s] 尺寸单位出现次数：" % label)
        for d, c in dims.most_common(12):
            out.append("      %-10s ×%d" % (d, c))
    return len(hexes)


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    apk_path = sys.argv[1]
    out_dir = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
    if not os.path.exists(apk_path):
        print("找不到 APK:", apk_path); sys.exit(1)

    lines = []
    def p(s=""):
        lines.append(str(s)); print(s)

    p("=" * 76)
    p("APK 设计规格提取 v2")
    p("文件: %s   %.1f MB" % (os.path.basename(apk_path), os.path.getsize(apk_path) / 1024 / 1024))
    p("=" * 76)

    try:
        z = zipfile.ZipFile(apk_path)
        names = z.namelist()
    except Exception as e:
        print("打不开 APK:", e); sys.exit(1)

    # ---------- 0) 技术栈 ----------
    p("\n【0】技术栈识别（决定提取路径）")
    for s in detect_stack(z, names):
        p("  · %s" % s)

    # ---------- 1) 清单 ----------
    p("\n【1】清单")
    try:
        from pyaxmlparser import APK as PA
        a = PA(apk_path)
        p("  包名: %s" % a.package)
        p("  版本: %s (code %s)    minSdk %s / targetSdk %s" % (a.version_name, a.version_code,
                                                              a.get_min_sdk_version(), a.get_target_sdk_version()))
        perms = sorted(a.get_permissions() or [])
        p("  权限 %d 条: %s" % (len(perms), ', '.join(x.split('.')[-1] for x in perms)))
        acts = a.get_activities() or []
        p("  Activity %d 个（前 40 个末段命名）:" % len(acts))
        for x in acts[:40]:
            p("      %s" % x.split('.')[-1])
    except Exception as e:
        p("  ⚠️ 失败: %s" % e)

    # ---------- 2) 可读样式源（按栈） ----------
    p("\n【2】可读样式源扫描（色值 / 尺寸单位）")
    total_hex = 0

    # 2a) res/values/*.xml 与 res/color/*.xml（原生/混合都可能有）
    xml_targets = [n for n in names if re.match(r'res/(values|color)[^/]*/.*\.xml$', n)]
    if xml_targets:
        p("\n  res/values 与 res/color 下的 XML（%d 个，取前 10）:" % len(xml_targets))
        for n in xml_targets[:10]:
            try:
                data = z.read(n)
                total_hex += scan_blob(data, n, lines, 16)
            except Exception as e:
                p("      ⚠️ %s: %s" % (n, e))
    else:
        p("\n  未发现 res/values 或 res/color XML（该 app 可能不用原生资源做样式）")

    # 2b) JS / bundle / H5（RN / uni-app / Cordova）
    js_targets = [n for n in names if n.startswith('assets/') and (
        n.endswith('.js') or n.endswith('.bundle') or n.endswith('.css') or n.endswith('.html'))]
    js_targets.sort(key=lambda n: -z.getinfo(n).file_size)
    if js_targets:
        p("\n  assets 下最大的 %d 个 JS/CSS/HTML（样式最可能在这里）:" % min(3, len(js_targets)))
        for n in js_targets[:3]:
            try:
                data = z.read(n)
                p("\n  === %s（%.2f MB）===" % (n, len(data) / 1024 / 1024))
                total_hex += scan_blob(data, n, lines, 24)
            except Exception as e:
                p("      ⚠️ %s" % e)

    # 2c) Flutter：libapp.so 里扫可读字符串（色值一般是整型，命中率低，只作参考）
    flutter_libs = [n for n in names if n.endswith('libapp.so')]
    if flutter_libs:
        p("\n  Flutter 检测到 libapp.so：界面色值为编译期整型，**Android 资源里拿不到**；")
        p("  该栈只能靠**真机截图 + 取色**做设计分析（工具旁路，见报告说明）。")

    # ---------- 3) 资源规模 ----------
    p("\n【3】资源与结构规模")
    exts = Counter(os.path.splitext(n)[1].lower() for n in names if n.startswith('res/') and os.path.splitext(n)[1])
    p("  res/ 按扩展名: %s" % ', '.join('%s×%d' % (e, c) for e, c in exts.most_common(8)))
    imgs = [n for n in names if n.startswith('res/') and os.path.splitext(n)[1].lower() in ('.png', '.webp', '.jpg', '.jpeg')]
    p("  图片 %d 个" % len(imgs))
    dens = Counter((re.search(r'-(\w+dpi|nodpi|anydpi)', n) or [None, 'default'])[1] if re.search(r'-(\w+dpi|nodpi|anydpi)', n) else 'default' for n in imgs)
    for d, c in dens.most_common():
        p("      %-10s %d" % (d, c))
    layouts = [n for n in names if n.startswith('res/layout')]
    p("  layout 文件 %d 个" % len(layouts))
    for n in sorted(layouts)[:30]:
        p("      %s" % n.split('/')[-1])
    dexs = [n for n in names if n.endswith('.dex')]
    p("  dex 文件 %d 个，合计 %.1f MB" % (len(dexs), sum(z.getinfo(n).file_size for n in dexs) / 1024 / 1024))
    assets = [n for n in names if n.startswith('assets/')]
    p("  assets %d 个文件，合计 %.1f MB" % (len(assets), sum(z.getinfo(n).file_size for n in assets) / 1024 / 1024))
    for n in sorted(assets, key=lambda x: -z.getinfo(x).file_size)[:12]:
        p("      %-52s %.2f MB" % (n, z.getinfo(n).file_size / 1024 / 1024))

    p("\n" + "=" * 76)
    p("共提取可读色值 %d 个（去重前）" % total_hex)
    p("说明: 只提取【结构与规范】；**不导出文案、不复制图片与品牌资产**。")
    p("=" * 76)

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        fp = os.path.join(out_dir, os.path.splitext(os.path.basename(apk_path))[0] + '-design-spec.txt')
        with open(fp, 'w', encoding='utf-8') as f:
            f.write("\n".join(lines))
        print("\n已写入: %s" % fp)


if __name__ == '__main__':
    main()
