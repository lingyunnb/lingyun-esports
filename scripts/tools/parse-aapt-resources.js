/**
 * 解析 aapt2 dump resources 的输出 → 提取竞品的"设计规范"
 *
 * 为什么用 aapt2：它是 Android SDK 官方工具，1 秒导出完整资源表（6.4MB 文本），
 * 且**资源名可读**（`color/app_primary`），比 androguard 的 API 稳（后者返回结构对不上）。
 *
 * 提取（**只取设计规范，不取文案/图片**）：
 *   ① 自研颜色（过滤 AndroidX/Material/系统库前缀）→ 色板 + 频次
 *   ② 自研尺寸（dimen）→ 间距/字号/圆角刻度
 *   ③ 自研 style 里的颜色引用 → 主题色
 *   ④ 结构规模（布局数、页面数）
 *
 * 用法: node scripts/tools/parse-aapt-resources.js <dump文件> [--out 输出目录]
 */
const fs = require('fs');
const path = require('path');

const src = process.argv[2];
const outDir = process.argv.includes('--out') ? process.argv[process.argv.indexOf('--out') + 1] : null;
if (!src || !fs.existsSync(src)) { console.error('用法: node parse-aapt-resources.js <dump.txt> [--out dir]'); process.exit(1); }

const text = fs.readFileSync(src, 'utf8');
// ⚠️ 必须按 /\r?\n/ 切：Windows 下 aapt2 输出是 CRLF，而 JS 的 `.` **不匹配 \r**（它是行终止符）
// → 若按 '\n' 切，行尾会留 \r，导致 `(.+)$` 永远匹配失败（踩过一次，0 命中）
const lines = text.split(/\r?\n/);

// 第三方/系统库前缀（不是该 App 的设计语言）
const LIBS = ['abc_', 'mtrl_', 'android_', 'compat_', 'notification_', 'material_', 'design_',
  'preference_', 'appcompat_', 'umeng_', 'tbs_', 'tencent_', 'wx_', 'amap_', 'bugly_', 'nim_',
  'jrmf_', 'zxing_', 'ucrop_', 'picture_', 'camera_', 'banner_', 'smartrefresh_', 'recyclerview_',
  'viewpager_', 'fragment_', 'titlebar_', 'svga_', 'lottie_', 'glide_', 'okhttp_', 'mmkv_',
  'select_dialog', 'browser_', 'socket_', 'google_', 'gms_', 'firebase_', 'crashlytics_',
  'media_', 'exo_', 'tt_', 'play_', 'scan_', 'qrcode_', 'nav_', 'shimmer_', 'status_bar_',
  'content_', 'bottom_', 'base_', 'lib_', 'sdk_', 'common_', 'pangle_', 'bytedance_', 'pandora_',
  'miui_', 'amigo_', 'hw_', 'oplus_', 'vivo_', 'meizu_', 'samsung_', 'flyme_', 'push_', 'mipush_'];
const isLib = (name) => { const n = name.toLowerCase(); return LIBS.some((p) => n.startsWith(p)); };

// ---- 解析 ----
const byType = {};      // type -> [{name, value, file, config}]
let curType = null, curRes = null;
for (let i = 0; i < lines.length; i++) {
  const L = lines[i];
  const mt = L.match(/^\s+type (\w+) id=(\w+) entryCount=(\d+)/);
  if (mt) { curType = mt[1]; byType[curType] = byType[curType] || []; curRes = null; continue; }
  const mr = L.match(/^\s+resource (0x[0-9a-f]+) ([\w.-]+)\/(.+)$/);
  if (mr && curType) {
    curRes = { id: mr[1], pkg: mr[2], name: mr[3], value: null, file: null, config: null };
    byType[curType].push(curRes);
    continue;
  }
  const mv = L.match(/^\s+\(([^)]*)\)\s+(.*)$/);
  if (mv && curRes) {
    curRes.config = mv[1];
    const rest = mv[2].trim();
    const mf = rest.match(/\(file\)\s+(\S+)/);
    if (mf) curRes.file = mf[1];
    else if (!rest.startsWith('(file)')) curRes.value = rest;
  }
}

// ---- ① 自研颜色 ----
const colors = (byType['color'] || []).filter((r) => !isLib(r.name) && r.value && /^#/.test(r.value));
const colorCount = {};
for (const c of colors) colorCount[c.value.toLowerCase()] = (colorCount[c.value.toLowerCase()] || 0) + 1;
const allColors = (byType['color'] || []).filter((r) => r.value && /^#/.test(r.value));
const allCount = {};
for (const c of allColors) allCount[c.value.toLowerCase()] = (allCount[c.value.toLowerCase()] || 0) + 1;

// ---- ② 自研尺寸 ----
const dimens = (byType['dimen'] || []).filter((r) => !isLib(r.name) && r.value);
const dimenCount = {};
for (const d of dimens) dimenCount[d.value] = (dimenCount[d.value] || 0) + 1;

// ---- ③ 自研 style 里的颜色引用 ----
const styles = (byType['style'] || []).filter((r) => !isLib(r.name));

// ---- ④ 结构 ----
const layouts = (byType['layout'] || []).length;
const stylesAll = (byType['style'] || []).length;

// ---- 输出 ----
const out = [];
const p = (s = '') => { out.push(String(s)); console.log(s); };
const argb = (h) => { const v = h.replace('#', ''); return v.length === 8 ? v.toLowerCase() : ('ff' + v).toLowerCase(); };
const lum = (h) => parseInt(argb(h).slice(2, 4), 16);

p('='.repeat(80));
p('东东电竞 4.6.0 · 设计规范提取（aapt2 dump resources 解析）');
p('='.repeat(80));
p('来源: ' + path.basename(src) + '  ' + (fs.statSync(src).size / 1024 / 1024).toFixed(2) + ' MB');

p('\n【0】资源规模（看它的体量）');
for (const [t, arr] of Object.entries(byType).sort((a, b) => b[1].length - a[1].length)) {
  if (['id', 'attr'].includes(t)) continue;
  p(`  ${t.padEnd(14)} ${arr.length}`);
}
p(`  （id / attr 为系统引用，已省略；两者共 ${(byType['id'] || []).length + (byType['attr'] || []).length}）`);

p('\n【1】自研颜色 —— 过滤库前缀后剩 ' + colors.length + ' 个（去重 ' + Object.keys(colorCount).length + ' 色）');
p('  按引用次数排序 Top 45（次数高 = 通用色，最可能是主色/底色/文字色）:');
Object.entries(colorCount).sort((a, b) => b[1] - a[1]).slice(0, 45).forEach(([h, c]) => {
  p(`      ${h.padEnd(11)} ×${String(c).padEnd(4)}  亮度 ${lum(h).toString(16).padStart(2, '0')}`);
});

p('\n【1b】含库在内的全量色值 Top 25（看整体倾向）');
Object.entries(allCount).sort((a, b) => b[1] - a[1]).slice(0, 25).forEach(([h, c]) => {
  p(`      ${h.padEnd(11)} ×${c}`);
});
const dark = Object.entries(allCount).reduce((s, [h, c]) => s + (lum(h) < 0x60 ? c : 0), 0);
const light = Object.entries(allCount).reduce((s, [h, c]) => s + (lum(h) > 0xb0 ? c : 0), 0);
p(`  倾向：深色 ${dark} 次 / 浅色 ${light} 次 → ${dark > light * 1.5 ? '偏深色底' : light > dark * 1.5 ? '偏浅色底' : '深浅均衡'}`);

p('\n【2】自研尺寸 —— ' + dimens.length + ' 个（去重 ' + Object.keys(dimenCount).length + ' 值）');
p('  按出现次数排序 Top 40（这套刻度就是它的间距/字号体系）:');
Object.entries(dimenCount).sort((a, b) => b[1] - a[1]).slice(0, 40).forEach(([v, c]) => {
  p(`      ${v.padEnd(14)} ×${c}`);
});

p('\n【2b】自研尺寸资源名样例（前 40 个，看命名体系）');
dimens.slice(0, 40).forEach((d) => p(`      ${d.name.slice(0, 46).padEnd(48)} = ${d.value}`));

p('\n【3】自研 style/theme —— ' + styles.length + ' 个（全量 ' + stylesAll + '）');
p('  名字里含 theme/app/color 的（前 30 个，主题色线索）:');
styles.filter((s) => /theme|app|color|main|primary/i.test(s.name)).slice(0, 30).forEach((s) =>
  p(`      ${s.name}`));

p('\n【4】结构规模');
p(`  layout 资源 ${layouts} 个（页面/组件布局数 —— 信息架构规模）`);
p(`  style  ${stylesAll} 个 / dimen ${(byType['dimen'] || []).length} 个 / color ${(byType['color'] || []).length} 个`);

p('\n' + '='.repeat(80));
p('说明：只提取【色值/尺寸/结构】等设计规范；**不含文案、不含图片、不含品牌资产**。');
p('      用途 = 校准比例/配色/尺寸刻度，不用于搬素材。');
p('='.repeat(80));

if (outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const fp = path.join(outDir, 'dongdong-design-spec.md');
  fs.writeFileSync(fp, out.join('\n'), 'utf8');
  console.log('\n已写入: ' + fp);
}
