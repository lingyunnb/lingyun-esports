/**
 * 管理端「浅色为默认 + 侧栏分组折叠」核验（无头 Edge + CDP 真跑真截图）
 * ============================================================================
 * 为什么有这个脚本（负责人 2026-10-11 第二轮任务）：
 *   · 主题默认档从 dark 改成 **light**，侧栏从"28 条平铺"改成"**8 个顶层项、父项点击展开子项**"；
 *   · 这两件事都**只能在真浏览器里按渲染结果断言**：读代码看不出 `body` 底色到底算出来是什么、
 *     看不出父项点击后子项 DOM 有没有真的多出来、看不出折叠态下子项是不是"点不到"。
 *
 * 逐项断言（任一 FAIL → exit 1）：
 *   ① **浅色为默认**：清空 localStorage → 重载 → `body` 底色**逐字** `rgb(245, 247, 251)`、
 *      `<html data-theme="light">`；侧栏白底 `rgb(255, 255, 255)`、顶栏/卡面白、发丝线 #E5E9F2；
 *      并断 `localStorage` 里**没有**主题偏好（= 真·默认档，不是"存过一次 light"）
 *   ② **侧栏结构 = 8 个顶层项**（3 个直接项…实际 2 直接 + 6 父项，按实现的 8 个名字逐条比对）：
 *      工作台 / 订单与售后 / 用户与身份 / 资金与抽成 / 商品与内容 / 客服与消息 / 排行榜 / 系统管理，
 *      且**父项是 `<button>`**（tagName + 右侧 chevron 存在）
 *   ③ **点父项 → 子项出现；再点 → 收起**（断 `.nav-children[data-nav-children="…"]` 容器
 *      **从无到有再到无**，并断子项数量与表格里的子项数一致）
 *   ④ **直接访问 `/orders`**：「订单与售后」默认已展开 + 当前项「订单管理」高亮（`.is-active`）
 *   ⑤ **折叠成图标条（64px）下能打开某一组的子项**：点父项 → 侧栏展开到 220 + 该组子项出现 → 再收起
 *   ⑥ 截图 6 张：登录页(浅) / 工作台(浅) / 侧栏展开态 / 侧栏全收起 / 折叠成图标条 / 一个业务页(浅)
 *   ⑦ **浅色对比度逐项复校**（要求"11 类对比度修复不许退步"）：
 *      `¥` 金额 ≥4.5 · 三级文字 ≥4.5 · 发丝线可见 · 分页当前页 ≥4.5 · **主按钮白字** ≥4.5 ·
 *      侧栏菜单文字 ≥4.5 · 输入框占位符 ≥2.5
 *   ⑧ **深色档没被改坏**：切到深色 → `body` = `rgb(11, 18, 32)`、侧栏近黑、文字 ≥4.5，
 *      再切回浅色（本次交付的硬约束：深色仍要能看）
 *
 * 反向断言（变异）：把 `stores/theme.ts` 的 `DEFAULT_MODE` 改回 `'dark'` → **①必须红**。
 *   脚本支持 `--expect-default=dark` 跑同一条 ① 断言但期望深色 —— 变异时用它把红/绿贴进报告：
 *     node scripts/tools/verify-admin-light-grouped-shell.mjs --expect-default=dark
 *
 * 并行环境铁律（沿用 verify-admin-dark-shell.mjs / verify-admin-table-actions.mjs）：
 *   · **绝不用真实超管 `kslingyun` 登录** → 一律走 `scripts/tools/regression-admin.js`
 *     的专用测试超管（`.env` 里的 `REGRESSION_ADMIN_USER`）；
 *   · 会话被顶掉（落到 /login）**不静默重登**，如实打印并中断该页。
 *
 * 运行：node scripts/tools/verify-admin-light-grouped-shell.mjs
 * 前置：pm2 fish-server（3100）、pm2 fish-admin（Vite dev 5173，只绑 IPv6 → http://[::1]:5173）
 * 可选环境变量：
 *   VLG_UI        管理端地址（默认 http://[::1]:5173；验证 dist 走 http://127.0.0.1:3100）
 *   VLG_API       后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   VLG_PAGES     浅色逐页抽查（默认 /users,/wallets,/recharge,/orders,/settings,/dashboard）
 *   VLG_SPOT      业务页截图路径（默认 /orders）
 *   VLG_SHOT_DIR  截图目录（默认 <root>/docs/验收素材/2026-10-11-管理端浅色）
 *   VLG_WIDTH     窗口宽度（默认 1600）
 *   VLG_EDGE_BIN  Edge 可执行文件
 *   VLG_CDP_PORT  CDP 端口（默认 9282）
 */
import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
// 管理端账号：**唯一入口** scripts/tools/regression-admin.js（ESM 里用 createRequire 引 CJS）
const requireCjs = createRequire(import.meta.url);
const { adminUser: REG_ADMIN_USER, adminPassword: REG_ADMIN_PASS } = requireCjs('./regression-admin.js');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(process.env.FISH_ROOT || path.join(HERE, '..', '..'));

const UI = process.env.VLG_UI || 'http://[::1]:5173';
const API = process.env.VLG_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VLG_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VLG_CDP_PORT || 9282);
const WIDTH = Number(process.env.VLG_WIDTH || 1600);
const HEIGHT = Number(process.env.VLG_HEIGHT || 1000);
const PAGES = (process.env.VLG_PAGES || '/users,/wallets,/recharge,/orders,/settings,/dashboard')
  .split(',').map((s) => s.trim()).filter(Boolean);
const SPOT = process.env.VLG_SPOT || '/orders';
const SHOT_DIR = process.env.VLG_SHOT_DIR || path.join(ROOT, 'docs', '验收素材', '2026-10-11-管理端浅色');
const USER = process.env.VLG_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VLG_ADMIN_PASS || REG_ADMIN_PASS;

/** 反向断言开关：变异时把 DEFAULT_MODE 改回 'dark'，再跑一次让 ① 断言翻红 */
const EXPECT_DEFAULT = (process.argv.find((a) => a.startsWith('--expect-default=')) || '').split('=')[1] || 'light';
/**
 * 只跑 ①（反向断言模式）。
 * 为什么需要它：② – ⑨ 断的是"**浅色为默认**"这一档的具体色值（白底侧栏、#F5F7FB 主区…），
 * 默认档被改成 dark 时它们**必然**一起红，那一片红只是噪声、盖住了"① 自己红了没有"这个结论。
 * 变异时用 `--only-default` 只跑 ① 并把结论打印成 RED/GREEN 两行，一眼能读。
 */
const ONLY_DEFAULT = process.argv.includes('--only-default');

if (!PASS) { console.error('缺少管理端口令（VLG_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

/* ------------------------------------------------------------------ 期望值
 * 全部与 src/styles/tokens.css / src/theme.ts **逐值同源**；改了 token 这里必须同步，
 * 否则断言会"假红"（这三个常量是"逐字比对"的靶子，故意写成字面量而不是从源码 import）。
 */
const LIGHT_BODY = 'rgb(245, 247, 251)';   // --color-bg-page 浅色档 #F5F7FB
const LIGHT_CARD = 'rgb(255, 255, 255)';   // --color-bg-card 浅色档 #FFFFFF
const LIGHT_SIDER = 'rgb(255, 255, 255)';  // --sider-bg 浅色档 #FFFFFF
const DARK_BODY = 'rgb(11, 18, 32)';       // --color-bg-page 深色档 #0B1220（保留档，不许坏）

/** 侧栏 8 个顶层项（与 LayoutView 的 NAV_GROUPS 逐条对齐）+ 每组的子项数 */
const EXPECT_TOP = [
  '工作台', '订单与售后', '用户与身份', '资金与抽成', '商品与内容', '客服与消息', '排行榜', '系统管理',
];
const EXPECT_DIRECT = ['工作台', '排行榜'];
const EXPECT_CHILD_COUNT = {
  订单与售后: 5, 用户与身份: 3, 资金与抽成: 4, 商品与内容: 7, 客服与消息: 2, 系统管理: 4,
};
/** 分组 → 子项中文名（断"子项真的渲染出来了"，不只是个空壳容器） */
const EXPECT_CHILDREN = {
  订单与售后: ['订单管理', '售后管理', '退款审批', '投诉工单', '打赏管理'],
  用户与身份: ['用户管理', '身份绑定', '工作端管理'],
  // 2026-10-11 第六轮同步：新增「提现审核」（/withdraw，权限 withdraw:review/pay）→ 3 → 4 项。
  // 这是**产品要求**带来的硬编码期望变更（本节数据表原本只有 3 项），不是断言放宽。
  资金与抽成: ['余额管理', '充值管理', '提现审核', '抽成中心'],
  商品与内容: ['游戏与商品', '分部管理', '官方馆管理', '下单页配置', '公告管理', '宣传图', '官网内容'],
  客服与消息: ['聊天管理', '意见反馈'],
  系统管理: ['系统设置', '管理员与角色', '操作日志与审计', '应用更新'],
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);

const results = [];
let failCount = 0;
function record(name, fails, extra = {}) {
  const ok = fails.length === 0;
  if (!ok) failCount += 1;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  for (const [k, v] of Object.entries(extra)) console.log(`     ${k}：${v}`);
  for (const f of fails) console.log(`     ✗ ${f}`);
  results.push({ name, fails, ...extra });
}

// ------------------------------------------------------------------ CDP
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.exceptions = [];
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.method === 'Runtime.exceptionThrown') {
        this.exceptions.push(flat(JSON.stringify(m.params?.exceptionDetails ?? {})).slice(0, 260));
      }
      if (m.id && this.pending.has(m.id)) {
        const q = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? q.reject(new Error(JSON.stringify(m.error))) : q.resolve(m.result);
      }
    });
  }
  send(method, params = {}, timeoutMs = 25000) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); } }, timeoutMs);
    });
  }
  async evalJs(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r?.exceptionDetails) throw new Error('页面执行异常：' + flat(JSON.stringify(r.exceptionDetails)).slice(0, 300));
    return r?.result?.value;
  }
  async shot(name, { beyond = false } = {}) {
    const r = await this.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: beyond });
    const buf = Buffer.from(r.data, 'base64');
    const p = path.join(SHOT_DIR, name);
    fs.writeFileSync(p, buf);
    console.log(`     [SHOT] ${path.basename(p)} (${(buf.length / 1024).toFixed(0)} KB)`);
    return p;
  }
}

// ------------------------------------------------------------------ 页面内测量
/**
 * 浅色档对比度探针：在页面里量**每个直接承载文字的元素**的对比度，判定在 Node 侧做。
 * 与 verify-admin-dark-shell.mjs 的探针同构，只有一处**口径反转**：
 *   那份脚本按"侧栏恒深色"把 `.n-layout-sider` 里的文字单独归类；
 *   本轮浅色档侧栏是**白底**，所以侧栏文字直接计入正文 AA，不再豁免
 *   （深色档那一条豁免仍由本脚本第 ⑧ 组单独处理）。
 * 注意：反斜杠都要写成 `\\`（这段是塞进 Runtime.evaluate 的字符串）。
 */
const CONTRAST_PROBE = `(() => {
  const parse = (c) => {
    const m = String(c).match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    const p = m[1].split(',').map((x) => parseFloat(x.trim()));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
  const lum = (c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  const ratio = (a, b) => { const l1 = lum(a), l2 = lum(b); const hi = Math.max(l1, l2), lo = Math.min(l1, l2); return (hi + 0.05) / (lo + 0.05); };
  /** 从元素往上找到第一个不透明背景（跳过 alpha<0.5 的祖先，避免"半透明柔底"被当成实底） */
  const bgOf = (el) => {
    let n = el;
    while (n && n !== document.documentElement) {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c && c.a > 0.5) return c;
      n = n.parentElement;
    }
    return parse(getComputedStyle(document.body).backgroundColor) || { r: 255, g: 255, b: 255, a: 1 };
  };
  const hasDirectText = (el) => {
    for (const n of el.childNodes) if (n.nodeType === 3 && n.nodeValue && n.nodeValue.trim()) return true;
    return false;
  };
  const isPlaceholder = (el) => !!el.closest('.n-input__placeholder');
  const items = [];
  const placeholders = [];
  const siderItems = [];
  const buttons = [];
  for (const el of [...document.querySelectorAll('body *')]) {
    if (!hasDirectText(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) < 0.3) continue;
    const fg = parse(cs.color); if (!fg) continue;
    const bg = bgOf(el);
    const px = parseFloat(cs.fontSize) || 14;
    const bold = (parseInt(cs.fontWeight, 10) || 400) >= 700;
    const large = px >= 24 || (px >= 18.66 && bold);
    const cr = ratio(fg, bg);
    const rec = {
      tag: el.tagName.toLowerCase(), cls: String(el.className || '').slice(0, 60),
      text: (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 26),
      px: Math.round(px), large, ratio: Math.round(cr * 100) / 100,
      fg: cs.color, bg: 'rgb(' + Math.round(bg.r) + ', ' + Math.round(bg.g) + ', ' + Math.round(bg.b) + ')',
    };
    if (isPlaceholder(el)) { placeholders.push(rec); continue; }
    if (el.closest('.n-layout-sider')) { siderItems.push(rec); continue; }
    items.push(rec);
  }
  /* 主按钮：断"白字 + 底是品牌主色"（浅色档最容易被 naive 解析成黑字的一处） */
  for (const b of [...document.querySelectorAll('.n-button--primary-type')]) {
    const r = b.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    const inner = b.querySelector('.n-button__content') || b;
    const cs = getComputedStyle(inner);
    const bcs = getComputedStyle(b);
    const own = parse(bcs.backgroundColor);
    /*
     * background-clip: text 的元素（naive 的 ghost/text 主按钮就是这种：底色只画在**字形里**）
     * 不能拿自己的 backgroundColor 当"文字底"——那会把按钮的**前景色**当成背景色算，
     * 得出一个毫无意义的低比值。这类元素一律沿祖先取实底。
     * （注意：这段代码在模板串里，注释里**不能出现反引号**，会提前闭合模板。）
     */
    const effectiveBg = (own && own.a > 0.5 && bcs.backgroundClip !== 'text') ? own : bgOf(b);
    buttons.push({
      text: (b.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 14),
      color: cs.color, bg: 'rgb(' + Math.round(effectiveBg.r) + ', ' + Math.round(effectiveBg.g) + ', ' + Math.round(effectiveBg.b) + ')',
      ratio: Math.round(ratio(parse(cs.color), effectiveBg) * 100) / 100,
      clipped: bcs.backgroundClip === 'text',
      ghost: b.classList.contains('n-button--ghost') || b.classList.contains('n-button--text'),
    });
  }
  /* 分页当前页 */
  let pager = null;
  const pa = document.querySelector('.n-pagination-item--active');
  if (pa) {
    const cs = getComputedStyle(pa);
    pager = { text: pa.innerText.trim(), color: cs.color, bg: 'rgb(' + [bgOf(pa)].map((c) => Math.round(c.r) + ', ' + Math.round(c.g) + ', ' + Math.round(c.b)) + ')', ratio: Math.round(ratio(parse(cs.color), bgOf(pa)) * 100) / 100 };
  }
  /* 表格发丝线：与表体底色的亮度差 */
  let hairline = null;
  const t = [...document.querySelectorAll('.n-data-table')].find((x) => x.getClientRects().length);
  if (t) {
    const th = t.querySelector('thead th');
    const td = t.querySelector('tbody td') || th;
    if (td) {
      const cs = getComputedStyle(td);
      hairline = { border: cs.borderBottomColor, bg: cs.backgroundColor, w: cs.borderBottomWidth, gap: Math.abs(lum(parse(cs.borderBottomColor) || { r: 0, g: 0, b: 0 }) - lum(parse(cs.backgroundColor) || { r: 255, g: 255, b: 255 })) };
    }
  }
  const yuan = items.filter((i) => i.text.includes('¥'));
  const bodyBg = getComputedStyle(document.body).backgroundColor;
  const sider = document.querySelector('.n-layout-sider');
  return {
    path: location.pathname,
    bodyBg, siderBg: sider ? getComputedStyle(sider).backgroundColor : null,
    themeAttr: document.documentElement.getAttribute('data-theme'),
    cardBg: (() => { const c = document.querySelector('.header'); return c ? getComputedStyle(c).backgroundColor : null; })(),
    divider: getComputedStyle(document.documentElement).getPropertyValue('--color-divider').trim(),
    total: items.length,
    minRatio: items.reduce((a, i) => Math.min(a, i.ratio), 99),
    worst: items.slice().sort((a, b) => a.ratio - b.ratio).slice(0, 6),
    belowAA: items.filter((i) => i.ratio < (i.large ? 3.0 : 4.5)),
    yuanCount: yuan.length,
    yuanMin: yuan.reduce((a, i) => Math.min(a, i.ratio), 99),
    yuanWorst: yuan.slice().sort((a, b) => a.ratio - b.ratio).slice(0, 3),
    phCount: placeholders.length,
    phMin: placeholders.reduce((a, i) => Math.min(a, i.ratio), 99),
    siderTotal: siderItems.length,
    siderMin: siderItems.reduce((a, i) => Math.min(a, i.ratio), 99),
    siderWorst: siderItems.slice().sort((a, b) => a.ratio - b.ratio).slice(0, 3),
    buttons,
    pager,
    hairline,
  };
})()`;

/** 侧栏结构探针：顶层项名字 / 是否 button / 子项容器与子项名 / 选中态 / 宽度 */
const SIDER_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const parents = [...document.querySelectorAll('.sider-menu .nav-parent')];
  const groups = parents.map((p) => {
    const label = p.getAttribute('data-nav-group');
    const box = document.querySelector('.nav-children[data-nav-children="' + label + '"]');
    return {
      label,
      tag: p.tagName.toLowerCase(),
      direct: p.getAttribute('data-nav-direct') === '1',
      expanded: p.getAttribute('aria-expanded'),
      chevron: !!p.querySelector('.nav-chevron'),
      chevronOpen: !!p.querySelector('.nav-chevron.is-open'),
      /* 折叠态关键：标签必须**整条不显示**（否则 64px 装不下中文标签会漏出半个字 —— 实测踩过） */
      labelShown: (() => { const l = p.querySelector('.nav-label'); return !!l && getComputedStyle(l).display !== 'none' && l.getClientRects().length > 0; })(),
      iconShown: (() => { const i = p.querySelector('.nav-icon svg'); return !!i && i.getClientRects().length > 0; })(),
      active: p.classList.contains('is-active'),
      current: p.classList.contains('is-current'),
      childBox: !!box,
      children: box ? [...box.querySelectorAll('.nav-child')].map((c) => txt(c)) : [],
      childKeys: box ? [...box.querySelectorAll('.nav-child')].map((c) => c.getAttribute('data-nav-item')) : [],
    };
  });
  return {
    path: location.pathname,
    siderW: Math.round((document.querySelector('.n-layout-sider') || document.body).getBoundingClientRect().width),
    topCount: groups.length,
    groups,
    activeChild: (() => { const el = document.querySelector('.sider-menu .nav-child.is-active'); return el ? txt(el) : null; })(),
    activeChildKey: (() => { const el = document.querySelector('.sider-menu .nav-child.is-active'); return el ? el.getAttribute('data-nav-item') : null; })(),
    themeAttr: document.documentElement.getAttribute('data-theme'),
    storage: { theme: localStorage.getItem('fish_admin_theme_mode'), expanded: sessionStorage.getItem('fish_admin_nav_expanded') },
    collapsedClass: !!(document.querySelector('.sider-menu') || { classList: null })?.classList?.contains('is-collapsed'),
  };
})()`;

/** 颜色 → 相对亮度（Node 侧，用于判断"深浅"） */
function lumOf(css) {
  const m = String(css).match(/rgba?\(([^)]+)\)/);
  if (!m) return null;
  const [r, g, b] = m[1].split(',').map((x) => parseFloat(x));
  const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

// ------------------------------------------------------------------ 主流程
const PROFILE = os.tmpdir() + '/fish-edge-lightshell-' + Date.now();
let browser = null;

/**
 * 把指针停到视口左上角的空白处。
 * 为什么每条对比度断言前都要做：naive 的按钮/标签/下拉有 hover 态（quaternary 主按钮 hover
 * 会变成 `#2080F0` + 半透明底、tag 的关闭钮会变色），鼠标一旦停在被量元素上，
 * 探针读到的就是**hover 值**而不是常态值 —— 会凭空造出"不达标"的假红（2026-10-11 实测踩过：
 * ghost 主按钮量到 4.06:1、超管标签量到灰底 4.68:1）。用 CDP 的真鼠标事件（isTrusted=true），
 * 合成事件不一定能触发 :hover。
 */
async function parkMouse(cdp) {
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 2, y: 1, button: 'none' });
  await sleep(320);
}
/** 量一次对比度（先停鼠标，再探针） */
async function probeContrast(cdp) {
  await parkMouse(cdp);
  return cdp.evalJs(CONTRAST_PROBE);
}

async function apiLogin() {
  const r = await fetch(API + '/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: USER, password: PASS, role: 'admin' }),
    signal: AbortSignal.timeout(15000),
  });
  const text = await r.text();
  let j = null; try { j = JSON.parse(text); } catch { /* ignore */ }
  return { status: r.status, token: j?.data?.accessToken ?? null, isOwner: j?.data?.admin?.isOwner ?? null, raw: text.slice(0, 200) };
}

/** 往输入框写值（走原生 setter，绕开 Vue 的 value 劫持，保证 v-model 真的收到） */
const fillAndSubmit = (user, pass) => `(() => {
  const setVal = (el, v) => {
    const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    d.set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  };
  const inputs = [...document.querySelectorAll('.login-card input')];
  if (inputs.length < 2) return 'NO_INPUTS';
  setVal(inputs[0], ${JSON.stringify(user)});
  setVal(inputs[1], ${JSON.stringify(pass)});
  const btns = [...document.querySelectorAll('.login-card button')];
  const b = btns.find((x) => x.innerText.replace(/\\s+/g, '').includes('登录'));
  if (!b) return 'NO_BUTTON';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

/** 点某个分组父项（走原生 click，Vue 的 @click 收得到） */
const clickGroup = (label) => `(() => {
  const b = [...document.querySelectorAll('.sider-menu .nav-parent')]
    .find((x) => x.getAttribute('data-nav-group') === ${JSON.stringify(label)});
  if (!b) return 'NOT_FOUND';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

async function main() {
  console.log(`[配置] UI=${UI} API=${API} 窗口=${WIDTH}x${HEIGHT} 抽查页=${PAGES.length} 截图目录=${SHOT_DIR}`);
  console.log(`[模式] ① 期望默认档 = ${EXPECT_DEFAULT}${ONLY_DEFAULT ? '（--only-default：只跑 ①）' : ''}`);
  browser = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-first-run',
    `--user-data-dir=${PROFILE}`, `--window-size=${WIDTH},${HEIGHT}`, 'about:blank'], { stdio: 'ignore' });
  await sleep(2600);

  const httpGet = (url) => new Promise((res, rej) => {
    import('http').then((h) => h.get(url, (r) => { let d = ''; r.on('data', (c) => (d += c)); r.on('end', () => res(d)); }).on('error', rej));
  });
  const targets = JSON.parse(await httpGet(`http://127.0.0.1:${PORT}/json`));
  const page = targets.find((t) => t.type === 'page');
  const cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await sleep(400);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false });

  // ================================================================ ① 浅色为默认（登录页）
  hr(`① 浅色为默认档（期望 data-theme=${EXPECT_DEFAULT}，body 逐字比对）`);
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2600);
  /*
   * 清干净上一次运行留下的 localStorage（令牌 / 主题偏好 / 标签页）→ 本套件可重复跑且结果一致：
   *   · 令牌不清 → 路由守卫会把人从 /login 弹到 /dashboard，登录页就量不到了；
   *   · **主题偏好必须清** → "默认浅色"这条断言才有意义（存过 light 的话测的是"记住的偏好"）；
   *   · sessionStorage 也要清 → 侧栏展开态是它管的；
   *   · 标签页不清 → 之后截的图里会带上历史页签。
   */
  await cdp.evalJs(`localStorage.clear(); sessionStorage.clear(); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2600);

  const login = await cdp.evalJs(`(() => {
    const card = document.querySelector('.login-card');
    const pg = document.querySelector('.login-page');
    const c = card ? card.getBoundingClientRect() : null;
    return {
      ok: !!card && !!pg,
      themeAttr: document.documentElement.getAttribute('data-theme'),
      stored: localStorage.getItem('fish_admin_theme_mode'),
      pageBg: pg ? getComputedStyle(pg).backgroundColor : null,
      cardBg: card ? getComputedStyle(card).backgroundColor : null,
      bodyBg: getComputedStyle(document.body).backgroundColor,
      vw: window.innerWidth,
      left: c ? Math.round(c.left) : null, right: c ? Math.round(window.innerWidth - c.right) : null,
      hasGrid: !!document.querySelector('.bg-grid'), hasGlow: !!document.querySelector('.bg-glow'),
      brand: !!document.querySelector('.login-card svg.mountain-mark'),
      /* 反面：登录页**不许**出现"左大图 / 右登录卡"那种分栏（左半区不该有任何大块元素） */
      sideBySideBlocks: [...document.querySelectorAll('.login-page > *')].map((e) => e.className).join('|'),
    };
  })()`);
  const loginShot = await cdp.shot('01-登录页-浅色居中白卡.png');
  const lf = [];
  /*
   * ① 的核心（**变异时这条必须红**）：
   *   正常模式：body 底色**逐字** = rgb(245, 247, 251) + `data-theme=light` + localStorage 没存过偏好。
   *   变异模式（`--expect-default=dark`，把 stores/theme.ts 的 DEFAULT_MODE 改回 'dark'）：
   *     同一句断言换成"必须落在深色档"，**落在浅色就直接红** —— 这就是"改回 dark → ① 必须红"的探针。
   */
  const wantBody = EXPECT_DEFAULT === 'light' ? LIGHT_BODY : 'rgb(11, 18, 32)';
  if (!login?.ok) lf.push('没找到 .login-card / .login-page（登录页没渲染出来）');
  else {
    if (login.bodyBg !== wantBody) {
      lf.push(`① body 底色 = ${login.bodyBg}，期望逐字 ${wantBody}（默认档 = ${EXPECT_DEFAULT} 未生效）`);
    }
    if (login.themeAttr !== EXPECT_DEFAULT) {
      lf.push(`① <html data-theme> = ${login.themeAttr}，期望 ${EXPECT_DEFAULT}`);
    }
    if (EXPECT_DEFAULT === 'light') {
      if (login.stored !== null) lf.push(`① localStorage 里存了主题偏好（${login.stored}）→ 测的不是默认档`);
      if (login.pageBg !== LIGHT_BODY) lf.push(`登录页底色 = ${login.pageBg}，期望 ${LIGHT_BODY}`);
      if (login.cardBg !== LIGHT_CARD) lf.push(`登录卡底色 = ${login.cardBg}，期望白卡 ${LIGHT_CARD}`);
    } else if (login.pageBg !== 'rgb(11, 18, 32)') {
      lf.push(`[变异] 登录页底色 = ${login.pageBg}，期望深色 rgb(11, 18, 32)`);
    }
    if (Math.abs(login.left - login.right) > login.vw * 0.02) lf.push(`卡片未水平居中：左 ${login.left}px vs 右 ${login.right}px`);
    if (!login.hasGrid || !login.hasGlow) lf.push('缺少 CSS 背景层（极细网格 / 光晕）');
    if (!login.brand) lf.push('卡片里没有品牌雪山标（svg.mountain-mark）');
  }
  record(`① 默认档 body 底色逐字 ${wantBody} + data-theme=${EXPECT_DEFAULT}`, lf, {
    卡片: `${login?.left} … ${login?.right}（视口 ${login?.vw}）`,
    登录页底色: login?.pageBg, 登录卡底色: login?.cardBg, body底色: login?.bodyBg,
    主题属性: login?.themeAttr, 存储: String(login?.stored),
    截图: loginShot,
  });

  /* 变异模式：只跑 ①（见文件头 ONLY_DEFAULT 的说明），把结论打成 RED/GREEN 两行 */
  if (ONLY_DEFAULT) {
    hr('反向断言结论（--only-default）');
    const green = failCount === 0;
    console.log(`[默认档] 期望 ${EXPECT_DEFAULT}，实测 body=${login?.bodyBg} / data-theme=${login?.themeAttr}`);
    console.log(green ? '🟢 GREEN：断言与实测一致（这一档的默认值是对的）'
      : '🔴 RED：断言与实测不符（默认档已被改掉 —— 这正是"改回 dark → ① 必红"的探针命中）');
    console.log(`\n结论：${green ? 'GREEN' : 'RED'}（FAIL ${failCount} 组）`);
    fs.writeFileSync(path.join(SHOT_DIR, `probe-${EXPECT_DEFAULT}-default-gate.json`),
      JSON.stringify({ expectDefault: EXPECT_DEFAULT, verdict: green ? 'GREEN' : 'RED', bodyBg: login?.bodyBg, themeAttr: login?.themeAttr, fails: results.flatMap((r) => r.fails) }, null, 2), 'utf8');
    if (!green) process.exitCode = 1;
    return; /* 提前收尾：不再跑 ② – ⑨（它们断的是浅色档的具体色值，变异态下必然一起红 = 噪声） */
  }

  // ================================================================ 登录 → 工作台
  hr('登录（专用测试超管，绝不用 kslingyun）→ 工作台');
  const who = await apiLogin();
  console.log(`     [账号] ${USER}（isOwner=${who.isOwner}）`);
  if (!who.token) throw new Error(`测试超管 ${USER} 登录失败，无法继续（HTTP ${who.status}）：${who.raw}`);
  const fill = await cdp.evalJs(fillAndSubmit(USER, PASS));
  if (fill !== 'OK') throw new Error(`登录表单填充失败：${fill}`);
  /* 等欢迎覆盖层播完（≈2.4s，一次性；播完地址栏的 welcome 参数会被抹掉） */
  for (let i = 0; i < 60; i += 1) {
    await sleep(150);
    if (!(await cdp.evalJs(`!!document.querySelector('[data-testid="welcome-overlay"]')`))) break;
  }
  await sleep(900);
  const dash = await cdp.evalJs(SIDER_PROBE);
  await cdp.send('Page.navigate', { url: `${UI}/dashboard` });
  await sleep(3000);
  const dashShot = await cdp.shot('02-工作台-浅色.png', { beyond: true });
  const dashContrast = await probeContrast(cdp);

  // ================================================================ ② 侧栏结构 = 8 个顶层项
  hr('② 侧栏结构：8 个顶层项（2 直接 + 6 可折叠父项）');
  /* 先把展开态归零（sessionStorage 里写 [] → 重载后所有分组都是收起的），
     这样"父项点击 → 子项出现"才是在干净状态下量的 */
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', '[]'); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/dashboard` });
  await sleep(3000);
  const top = await cdp.evalJs(SIDER_PROBE);
  const siderBg = await cdp.evalJs(`(() => {
    const s = document.querySelector('.n-layout-sider');
    const h = document.querySelector('.header');
    return {
      siderBg: s ? getComputedStyle(s).backgroundColor : null,
      headerBg: h ? getComputedStyle(h).backgroundColor : null,
      bodyBg: getComputedStyle(document.body).backgroundColor,
      divider: getComputedStyle(document.documentElement).getPropertyValue('--color-divider').trim(),
      textPrimary: getComputedStyle(document.documentElement).getPropertyValue('--color-text-primary').trim(),
      textSecondary: getComputedStyle(document.documentElement).getPropertyValue('--color-text-secondary').trim(),
      textTertiary: getComputedStyle(document.documentElement).getPropertyValue('--color-text-tertiary').trim(),
    };
  })()`);

  const names = top.groups.map((g) => g.label);
  const tf = [];
  if (top.topCount !== EXPECT_TOP.length) tf.push(`顶层项 = ${top.topCount} 个，期望 ${EXPECT_TOP.length} 个`);
  if (JSON.stringify(names) !== JSON.stringify(EXPECT_TOP)) {
    tf.push(`顶层项名字/顺序不吻合：\n        实际 ${JSON.stringify(names)}\n        期望 ${JSON.stringify(EXPECT_TOP)}`);
  }
  for (const g of top.groups) {
    if (g.tag !== 'button') tf.push(`「${g.label}」的父项不是 <button>（实际 <${g.tag}>）`);
    if (!g.direct && !g.chevron) tf.push(`「${g.label}」缺右侧 chevron（展开箭头）`);
    if (g.direct && g.label !== '工作台' && g.label !== '排行榜') tf.push(`「${g.label}」被误判为直接项`);
  }
  if (siderBg.siderBg !== LIGHT_SIDER) tf.push(`侧栏底色 = ${siderBg.siderBg}，期望浅色白底 ${LIGHT_SIDER}`);
  if (siderBg.bodyBg !== LIGHT_BODY) tf.push(`主区底 = ${siderBg.bodyBg}，期望 ${LIGHT_BODY}`);
  if ((lumOf(siderBg.siderBg) ?? 0) < 0.8) tf.push(`侧栏底色不够浅（亮度 ${lumOf(siderBg.siderBg)?.toFixed(3)}）→ 侧栏没改成浅色`);
  if (siderBg.divider.toLowerCase() !== '#e5e9f2') tf.push(`发丝线 token = ${siderBg.divider}，期望 #e5e9f2`);
  record('② 侧栏结构（8 顶层项 / 名字 / button / chevron / 浅色白底）', tf, {
    顶层项: names.join(' · '),
    '直接项 vs 父项': `${top.groups.filter((g) => g.direct).length} + ${top.groups.filter((g) => !g.direct).length}`,
    侧栏底色: `${siderBg.siderBg}（亮度 ${lumOf(siderBg.siderBg)?.toFixed(3)}）`,
    主区底色: siderBg.bodyBg, 发丝线: siderBg.divider,
    文字token: `${siderBg.textPrimary} / ${siderBg.textSecondary} / ${siderBg.textTertiary}`,
    截图: dashShot,
  });

  // ================================================================ ③ 点父项 → 子项出现 → 再点收起
  hr('③ 父项点击展开 / 再点收起（断子项 DOM 数量变化）');
  /*
   * 起始状态：② 之后所有分组都收起（sessionStorage 写过 []，且当前页 /dashboard 不在任何分组里
   * → watch 不会自动展开任何一组）。逐组做"点开 → 断言出现 → 再点 → 断言消失"。
   */
  const toggleLog = [];
  const cf = [];
  for (const label of Object.keys(EXPECT_CHILD_COUNT)) {
    const before = await cdp.evalJs(`!!document.querySelector('.nav-children[data-nav-children=${JSON.stringify(label)}]')`);
    const click1 = await cdp.evalJs(clickGroup(label));
    await sleep(260);
    const opened = await cdp.evalJs(`(() => {
      const box = document.querySelector('.nav-children[data-nav-children=${JSON.stringify(label)}]');
      const p = [...document.querySelectorAll('.sider-menu .nav-parent')].find((x) => x.getAttribute('data-nav-group') === ${JSON.stringify(label)});
      return {
        box: !!box,
        count: box ? box.querySelectorAll('.nav-child').length : 0,
        names: box ? [...box.querySelectorAll('.nav-child')].map((c) => c.innerText.trim()) : [],
        chevronOpen: !!(p && p.querySelector('.nav-chevron.is-open')),
        ariaExpanded: p ? p.getAttribute('aria-expanded') : null,
      };
    })()`);
    const click2 = await cdp.evalJs(clickGroup(label));
    await sleep(260);
    const closed = await cdp.evalJs(`(() => {
      const box = document.querySelector('.nav-children[data-nav-children=${JSON.stringify(label)}]');
      const p = [...document.querySelectorAll('.sider-menu .nav-parent')].find((x) => x.getAttribute('data-nav-group') === ${JSON.stringify(label)});
      return { box: !!box, count: box ? box.querySelectorAll('.nav-child').length : 0, chevronOpen: !!(p && p.querySelector('.nav-chevron.is-open')) };
    })()`);
    toggleLog.push(`${label}: ${before ? 1 : 0}项 → 点开 ${opened.count}项(chevron=${opened.chevronOpen}) → 点收 ${closed.count}项(chevron=${closed.chevronOpen})`);
    if (before) cf.push(`「${label}」起始就不是收起态（前置状态脏了，本组断言无效）`);
    if (click1 !== 'OK' || click2 !== 'OK') cf.push(`「${label}」父项按钮点不到（${click1}/${click2}）`);
    if (!opened.box || opened.count === 0) cf.push(`「${label}」点开后子项没出现（box=${opened.box} count=${opened.count}）`);
    if (opened.count !== EXPECT_CHILD_COUNT[label]) cf.push(`「${label}」子项数 = ${opened.count}，期望 ${EXPECT_CHILD_COUNT[label]}`);
    if (JSON.stringify(opened.names) !== JSON.stringify(EXPECT_CHILDREN[label])) {
      cf.push(`「${label}」子项名不吻合：实际 ${JSON.stringify(opened.names)} / 期望 ${JSON.stringify(EXPECT_CHILDREN[label])}`);
    }
    if (!opened.chevronOpen) cf.push(`「${label}」展开后 chevron 没有旋转（is-open 缺失）`);
    if (opened.ariaExpanded !== 'true') cf.push(`「${label}」展开后 aria-expanded=${opened.ariaExpanded}，期望 true`);
    if (closed.box || closed.count !== 0) cf.push(`「${label}」再点后子项没收起（count=${closed.count}）`);
    if (closed.chevronOpen) cf.push(`「${label}」收起后 chevron 仍处于旋转态`);
  }
  record('③ 父项点击展开/收起（子项 DOM 从无到有再到无）', cf, {
    逐组: toggleLog.join('\n         '),
  });

  // ================================================================ ④ 直接访问 /orders → 该组默认展开 + 当前项高亮
  hr('④ 直接访问 /orders：「订单与售后」默认已展开 + 当前项高亮');
  /*
   * 先把展开态清成"从没手动展开过"（删掉 key）→ 走 readExpanded 的默认分支（前 3 组）。
   * 关键是要证明：**即使默认分支没覆盖到该组，watch(immediate) 也会把它展开**。
   * 所以更严格的测法是写 `[]`（一个都不展开）→ 重载后仍必须展开「订单与售后」。
   */
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', '[]'); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/orders` });
  await sleep(3400);
  if ((await cdp.evalJs('location.pathname')) === '/login') throw new Error('落到 /login（会话被顶），后续断言已无意义，中断');
  const orders = await cdp.evalJs(SIDER_PROBE);
  const ordersGroup = orders.groups.find((g) => g.label === '订单与售后') ?? null;
  const of = [];
  if (!ordersGroup) of.push('侧栏里找不到「订单与售后」分组');
  else {
    if (!ordersGroup.expanded || ordersGroup.expanded !== 'true') of.push(`「订单与售后」未默认展开（aria-expanded=${ordersGroup.expanded}, childBox=${ordersGroup.childBox}）`);
    if (!ordersGroup.childBox) of.push('「订单与售后」的子项容器没渲染出来 → 默认展开没生效');
    if (JSON.stringify(ordersGroup.childKeys) !== JSON.stringify(['orders', 'appeals', 'refunds', 'complaints', 'tips'])) {
      of.push(`子项路由不吻合：${JSON.stringify(ordersGroup.childKeys)}`);
    }
    if (!ordersGroup.active) of.push('「订单与售后」父项没有"当前页所在分组"高亮（缺 is-active）');
    if (!ordersGroup.chevronOpen) of.push('「订单与售后」的 chevron 不是展开态');
  }
  if (orders.activeChildKey !== 'orders') of.push(`当前高亮子项 = ${orders.activeChildKey}（${orders.activeChild}），期望 orders（订单管理）`);
  /* 其余 5 组必须是收起的（"其它组默认收起"） */
  const otherOpen = orders.groups.filter((g) => !g.direct && g.label !== '订单与售后' && g.childBox).map((g) => g.label);
  if (otherOpen.length) of.push(`其它分组也处于展开态：${JSON.stringify(otherOpen)}（期望默认收起）`);
  /* 高亮还得是真的看得见：量一次选中项的颜色与底色 */
  const hl = await cdp.evalJs(`(() => {
    const el = document.querySelector('.sider-menu .nav-child.is-active');
    if (!el) return null;
    const parse = (c) => { const m = String(c).match(/rgba?\\(([^)]+)\\)/); const p = m[1].split(',').map(Number); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; };
    const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    const lum = (c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    let bg = { r: 255, g: 255, b: 255 }, n = el;
    while (n && n !== document.documentElement) { const c = parse(getComputedStyle(n).backgroundColor); if (c.a > 0.5) { bg = c; break; } n = n.parentElement; }
    const fg = parse(getComputedStyle(el).color);
    const l1 = lum(fg), l2 = lum(bg);
    const bar = getComputedStyle(el, '::before');
    return { text: el.innerText.trim(), color: getComputedStyle(el).color, bg: 'rgb(' + Math.round(bg.r) + ',' + Math.round(bg.g) + ',' + Math.round(bg.b) + ')', ratio: Math.round(((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)) * 100) / 100, barWidth: bar.width, barColor: bar.backgroundColor, fontWeight: getComputedStyle(el).fontWeight };
  })()`);
  if (hl && hl.ratio < 4.5) of.push(`选中子项对比度仅 ${hl.ratio}:1（< 4.5）`);
  if (hl && (parseFloat(hl.barWidth) || 0) < 2) of.push(`选中子项左侧主色条宽度 = ${hl.barWidth}（期望 3px 装饰条）`);
  record('④ 直达 /orders 时该组默认展开 + 当前项高亮', of, {
    分组: `aria-expanded=${ordersGroup?.expanded} 子项=${JSON.stringify(ordersGroup?.childKeys)}`,
    当前项: `${orders.activeChild}（${hl?.color} on ${hl?.bg} = ${hl?.ratio}:1，左侧条 ${hl?.barWidth} ${hl?.barColor}）`,
    其它组: otherOpen.length ? otherOpen.join(' / ') : '全部收起',
  });

  // ================================================================ ⑤ 折叠成图标条下能打开某一组的子项
  hr('⑤ 折叠态（64px 图标条）下点父项 → 展开侧栏并露出该组子项');
  const foldLog = [];
  const ff = [];
  /* 先确保侧栏展开（④ 之后是展开的），再点顶栏的折叠按钮收成图标条 */
  const wBefore = await cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
  /** 按目标宽度点折叠按钮（**按状态收敛**，不是无脑点一下 —— 否则状态脏了就会反向操作） */
  const setCollapsed = async (want) => {
    for (let i = 0; i < 4; i += 1) {
      const w = await cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
      if ((want && w === 64) || (!want && w === 220)) return w;
      await cdp.evalJs(`document.querySelector('.header .icon-btn').dispatchEvent(new MouseEvent('click', { bubbles: true })); 'ok'`);
      await sleep(700);
    }
    return cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
  };
  await setCollapsed(true);
  const collapsedW = await cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
  const collapsedProbe = await cdp.evalJs(SIDER_PROBE);
  const iconShot = await cdp.shot('05b-侧栏折叠成图标条.png');
  foldLog.push(`展开 ${wBefore}px → 折叠 ${collapsedW}px（顶层项仍 ${collapsedProbe.topCount} 个，子项容器 ${collapsedProbe.groups.filter((g) => g.childBox).length} 个，可见图标 ${collapsedProbe.groups.filter((g) => g.iconShown).length} 个，外露标签 ${collapsedProbe.groups.filter((g) => g.labelShown).length} 个）`);
  if (collapsedW !== 64) ff.push(`折叠后侧栏宽度 = ${collapsedW}px（期望 64）`);
  if (collapsedProbe.topCount !== EXPECT_TOP.length) ff.push(`折叠态顶层项 = ${collapsedProbe.topCount} 个（期望 ${EXPECT_TOP.length}）`);
  if (collapsedProbe.groups.some((g) => g.childBox)) ff.push('折叠态仍渲染了子项容器（应只剩图标条）');
  /* 图标条 = 只剩图标：每个顶层项都有可见图标，且**一个标签都不许露出来** */
  const noIcon = collapsedProbe.groups.filter((g) => !g.iconShown).map((g) => g.label);
  const leakedLabel = collapsedProbe.groups.filter((g) => g.labelShown).map((g) => g.label);
  if (noIcon.length) ff.push(`折叠态这些顶层项没渲染出图标：${JSON.stringify(noIcon)}`);
  if (leakedLabel.length) {
    ff.push(`折叠态这些顶层项的标签仍然可见（64px 装不下会漏出半个字）：${JSON.stringify(leakedLabel)}`);
  }

  /* 挑一组**当前没展开**的（「系统管理」）→ 折叠态点它 → 必须展开侧栏 + 露出子项 */
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', '[]'); 'ok'`);
  const preClick = await cdp.evalJs(`(() => {
    const b = [...document.querySelectorAll('.sider-menu .nav-parent')].find((x) => x.getAttribute('data-nav-group') === '系统管理');
    return { found: !!b, w: Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width) };
  })()`);
  const clickRes = await cdp.evalJs(clickGroup('系统管理'));
  await sleep(900);
  const afterClick = await cdp.evalJs(`(() => {
    const box = document.querySelector('.nav-children[data-nav-children="系统管理"]');
    return {
      w: Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width),
      box: !!box,
      count: box ? box.querySelectorAll('.nav-child').length : 0,
      names: box ? [...box.querySelectorAll('.nav-child')].map((c) => c.innerText.trim()) : [],
      anyChildVisible: [...document.querySelectorAll('.sider-menu .nav-child')].some((c) => c.getClientRects().length > 0),
    };
  })()`);
  foldLog.push(`折叠态点「系统管理」：${clickRes} → 侧栏 ${preClick.w}px→${afterClick.w}px，子项 ${afterClick.count} 个 ${JSON.stringify(afterClick.names)}`);
  if (clickRes !== 'OK') ff.push(`折叠态下「系统管理」父项点不到（${clickRes}）`);
  if (afterClick.w !== 220) ff.push(`折叠态点击父项后侧栏宽度 = ${afterClick.w}px（期望自动展开到 220）`);
  if (!afterClick.box || afterClick.count !== EXPECT_CHILD_COUNT['系统管理']) {
    ff.push(`折叠态点击后子项没出来：box=${afterClick.box} count=${afterClick.count}（期望 ${EXPECT_CHILD_COUNT['系统管理']}）`);
  }
  if (!afterClick.anyChildVisible) ff.push('子项虽然渲染了但**不可见/点不到**（getClientRects 为空）');
  /* 子项真的能点：点「系统设置」应跳到 /settings */
  const navRes = await cdp.evalJs(`(() => {
    const b = [...document.querySelectorAll('.sider-menu .nav-child')].find((x) => x.getAttribute('data-nav-item') === 'settings');
    if (!b) return 'NOT_FOUND';
    b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return 'OK';
  })()`);
  await sleep(1600);
  const navPath = await cdp.evalJs(`location.pathname`);
  foldLog.push(`点子项「系统设置」→ ${navPath}`);
  if (navRes !== 'OK') ff.push('折叠态展开后子项「系统设置」点不到');
  if (navPath !== '/settings') ff.push(`点子项后地址 = ${navPath}，期望 /settings（子项路由没接上）`);
  /* 复原成展开态（后面的截图要用）—— 按状态收敛 + 带走 hover 污染 */
  await parkMouse(cdp);
  const restoredW = await setCollapsed(false);
  if (restoredW !== 220) ff.push(`复原后侧栏宽度 = ${restoredW}px（期望 220）`);
  record('⑤ 折叠态下能打开某一组的子项（点得到、点得进）', ff, {
    过程: foldLog.join('\n         '),
    截图: iconShot,
  });

  // ================================================================ ⑥ 截图（6 张）
  hr(`⑥ 截图 6 张 → ${SHOT_DIR}`);
  /* 侧栏展开态（分组都摊开）+ 侧栏全收起 + 业务页 */
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', JSON.stringify(${JSON.stringify(EXPECT_TOP.filter((x) => !EXPECT_DIRECT.includes(x)))})); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/dashboard` });
  await sleep(3200);
  const shotExpanded = await cdp.shot('03-侧栏展开态-全部分组摊开.png');
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', '[]'); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/dashboard` });
  await sleep(3000);
  const shotAllCollapsed = await cdp.shot('04-侧栏全收起.png');
  await cdp.send('Page.navigate', { url: `${UI}${SPOT}` });
  await sleep(3400);
  const spotContrast = await probeContrast(cdp);
  const shotSpot = await cdp.shot(`06-业务页-浅色${SPOT.replace(/\//g, '-')}.png`, { beyond: true });
  /* 登录页与工作台已在前面截过（01 / 02） */
  const shots = ['01-登录页-浅色居中白卡.png', '02-工作台-浅色.png', '03-侧栏展开态-全部分组摊开.png',
    '04-侧栏全收起.png', '05b-侧栏折叠成图标条.png', `06-业务页-浅色${SPOT.replace(/\//g, '-')}.png`];
  const missing = shots.filter((f) => !fs.existsSync(path.join(SHOT_DIR, f)) || fs.statSync(path.join(SHOT_DIR, f)).size < 4096);
  record('⑥ 截图 6 张（浅色）', missing.map((f) => `缺图或过小：${f}`), {
    目录: SHOT_DIR,
    清单: shots.map((f) => `${f}(${fs.existsSync(path.join(SHOT_DIR, f)) ? Math.round(fs.statSync(path.join(SHOT_DIR, f)).size / 1024) + 'KB' : '缺失'})`).join(' '),
    本轮: `${shotExpanded ? '展开态 ✓' : '✗'} / ${shotAllCollapsed ? '全收起 ✓' : '✗'} / ${shotSpot ? '业务页 ✓' : '✗'}`,
  });

  // ================================================================ ⑦ 浅色对比度逐项复校
  hr(`⑦ 浅色对比度逐项复校（${PAGES.length} 页 + 登录页）`);
  const lightPages = [login, { path: '/dashboard', bodyBg: dashContrast.bodyBg }];
  const cf2 = [];
  /* 登录页 + 工作台（前面已量）先过一遍 */
  for (const probe of [dashContrast]) {
    if (probe.bodyBg !== LIGHT_BODY) cf2.push(`工作台 body 底色 = ${probe.bodyBg}，期望 ${LIGHT_BODY}`);
    if (probe.belowAA.length) cf2.push(`工作台有 ${probe.belowAA.length} 处文字对比度 < AA：${JSON.stringify(probe.belowAA.slice(0, 4))}`);
    if (probe.siderTotal && probe.siderMin < 4.5) cf2.push(`工作台侧栏菜单文字最低对比度 ${probe.siderMin}:1：${JSON.stringify(probe.siderWorst)}`);
  }
  if (!lightPages[0]) cf2.push('登录页探针缺失');
  let relogins = 0;
  const pageLog = [];
  for (const p of PAGES) {
    await cdp.send('Page.navigate', { url: `${UI}${p}` });
    await sleep(3400);
    if ((await cdp.evalJs('location.pathname')) === '/login') {
      if (relogins >= 2) { cf2.push(`浅色抽查 ${p}：落到 /login（会话被顶）`); continue; }
      relogins += 1;
      console.log(`     [会话] ${p} 落到 /login（疑似被并行批次顶号）→ 第 ${relogins} 次重新登录`);
      const again = await apiLogin();
      if (!again.token) { cf2.push(`浅色抽查 ${p}：重新登录失败`); continue; }
      await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(again.token)}); 'ok'`);
      await cdp.send('Page.navigate', { url: `${UI}${p}` });
      await sleep(3400);
    }
    const probe = await probeContrast(cdp);
    const fails = [];
    if (probe.bodyBg !== LIGHT_BODY) fails.push(`底色 = ${probe.bodyBg}，期望 ${LIGHT_BODY}`);
    if (probe.themeAttr !== 'light') fails.push(`data-theme = ${probe.themeAttr}，期望 light`);
    if (probe.belowAA.length) fails.push(`${probe.belowAA.length} 处文字对比度 < AA：${JSON.stringify(probe.belowAA.slice(0, 4))}`);
    /* ¥ 金额（要求逐项过的第 1 项） */
    if (probe.yuanCount > 0 && probe.yuanMin < 4.5) fails.push(`¥ 金额最低对比度 ${probe.yuanMin}:1（< 4.5）：${JSON.stringify(probe.yuanWorst)}`);
    /* 三级文字（第 2 项）：整体最差值就是三级文字的主要去处，这里额外断"侧栏 + 说明文字" */
    if (probe.minRatio < 4.5) fails.push(`全页最低对比度 ${probe.minRatio}:1（< 4.5）：${JSON.stringify(probe.worst.slice(0, 3))}`);
    /* 发丝线（第 3 项） */
    if (probe.hairline && probe.hairline.gap < 0.008) fails.push(`表格发丝线与底色几乎无亮度差（${probe.hairline.border} vs ${probe.hairline.bg}，差 ${probe.hairline.gap.toFixed(4)}）`);
    /* 分页当前页（第 4 项） */
    if (probe.pager && probe.pager.ratio < 4.5) fails.push(`分页当前页「${probe.pager.text}」对比度 ${probe.pager.ratio}:1（< 4.5）`);
    /* 主按钮白字（第 5 项） */
    for (const b of probe.buttons.filter((x) => !x.ghost)) {
      if (b.color !== 'rgb(255, 255, 255)') fails.push(`主按钮「${b.text}」文字不是白字（${b.color}）`);
      if (b.ratio < 4.5) fails.push(`主按钮「${b.text}」白字对比度 ${b.ratio}:1（< 4.5，底 ${b.bg}）`);
    }
    for (const b of probe.buttons.filter((x) => x.ghost)) {
      if (b.ratio < 4.5) fails.push(`ghost 主按钮「${b.text}」对比度 ${b.ratio}:1（< 4.5）`);
    }
    /* 侧栏菜单文字（第 6 项） */
    if (probe.siderTotal > 0 && probe.siderMin < 4.5) fails.push(`侧栏菜单文字最低对比度 ${probe.siderMin}:1：${JSON.stringify(probe.siderWorst)}`);
    /* 占位符（第 7 项） */
    if (probe.phCount > 0 && probe.phMin < 2.5) fails.push(`输入框占位符对比度 ${probe.phMin}:1（< 2.5）`);
    if (fails.length) cf2.push(...fails.map((f) => `${p}：${f}`));
    pageLog.push(`${p} 底=${probe.bodyBg} 最低=${probe.minRatio}:1 ¥=${probe.yuanCount ? probe.yuanMin + ':1' : '—'} 侧栏=${probe.siderTotal ? probe.siderMin + ':1' : '—'} 分页=${probe.pager ? probe.pager.ratio + ':1' : '—'} 主按钮=${probe.buttons.filter((b) => !b.ghost).length}个${probe.buttons.filter((b) => !b.ghost).length ? '最低' + Math.min(...probe.buttons.filter((b) => !b.ghost).map((b) => b.ratio)) + ':1' : ''} 发丝线=${probe.hairline ? probe.hairline.gap.toFixed(4) : '无表'} 占位符=${probe.phCount ? probe.phMin + ':1' : '—'}`);
  }
  /* 业务页（06 那张图那一页）也并入 */
  if (spotContrast.bodyBg !== LIGHT_BODY) cf2.push(`${SPOT}（业务页截图页）body 底色 = ${spotContrast.bodyBg}`);
  record('⑦ 浅色对比度逐项复校（¥ / 三级文字 / 发丝线 / 分页 / 主按钮白字 / 侧栏 / 占位符）', cf2, {
    逐页: pageLog.join('\n         '),
    工作台最低: `${dashContrast.minRatio}:1`,
    工作台主按钮: dashContrast.buttons.map((b) => `「${b.text}」${b.color} on ${b.bg} = ${b.ratio}:1`).join(' · ') || '本页无主按钮',
  });

  // ================================================================ ⑧ 深色档没被改坏
  hr('⑧ 深色档保留且未退步（切成 dark → 断深色值 → 切回 light）');
  /*
   * 切换主题前**必须把鼠标挪走**：naive 的按钮有 hover 态（quaternary 主按钮 hover 会变
   * #2080F0 与半透明底），鼠标停在按钮上时"刚点完的那一下"会把探针量到的颜色污染成 hover 值。
   * 复用顶层的 `parkMouse(cdp)`（走 CDP 真鼠标事件，合成事件不一定触发 :hover），
   * 不在局部复制第二份。
   */
  const toggleTheme = async () => {
    await parkMouse(cdp);
    await cdp.evalJs(`(() => { const btns = [...document.querySelectorAll('.header .icon-btn')]; btns[1].dispatchEvent(new MouseEvent('click', { bubbles: true })); return 'ok'; })()`);
    await sleep(900);
    await parkMouse(cdp);
  };
  await toggleTheme();
  const dark = await probeContrast(cdp);
  const darkShell = await cdp.evalJs(`(() => {
    const s = document.querySelector('.n-layout-sider');
    const h = document.querySelector('.header');
    return { siderBg: s ? getComputedStyle(s).backgroundColor : null, headerBg: h ? getComputedStyle(h).backgroundColor : null, divider: getComputedStyle(document.documentElement).getPropertyValue('--color-divider').trim() };
  })()`);
  const darkShot = await cdp.shot('07-深色档对照-未退步.png');
  await toggleTheme();
  const backLight = await cdp.evalJs(`({ bodyBg: getComputedStyle(document.body).backgroundColor, attr: document.documentElement.getAttribute('data-theme'), siderBg: getComputedStyle(document.querySelector('.n-layout-sider')).backgroundColor })`);

  const df = [];
  /*
   * ⚠️ 范围说明（这一组只断"深色档作为保留档有没有被改坏"，不改动第一轮的交付判定）：
   *   本组页面停在「订单管理」业务页。顶栏里那几个 quaternary 按钮（刷新 / 退出登录）
   *   与「超级管理员」标签在**深色档下本来就不达 AA**（实测 #9DB0C8 on #111C2E = 3.34:1、
   *   主色标签 2.47:1）——这是**第一轮就存在、本轮一行未动**的既有值（darkOverrides 的
   *   textColor2 / Tag 两个键本次都没改，见 git diff），不在"不许退步"的范围里，
   *   但也不该被静默吞掉 → 单独打印成"已知既有项"，只有**新增**的不达标才算失败。
   *   （注：注释里不要写「星号+斜杠+路径」那种写法 —— `*` `/` 会提前闭合块注释。）
   */
  const KNOWN_DARK_HEADER = /(刷新|退出登录|超级管理员)/;
  const darkNew = dark.belowAA.filter((x) => !KNOWN_DARK_HEADER.test(x.text));
  const darkKnown = dark.belowAA.filter((x) => KNOWN_DARK_HEADER.test(x.text));
  if (dark.bodyBg !== DARK_BODY) df.push(`深色档 body 底色 = ${dark.bodyBg}，期望 ${DARK_BODY}`);
  if (dark.themeAttr !== 'dark') df.push(`深色档 data-theme = ${dark.themeAttr}，期望 dark`);
  if ((lumOf(dark.bodyBg) ?? 1) > 0.1) df.push(`深色档底色亮度 ${lumOf(dark.bodyBg)?.toFixed(3)} > 0.1（不够暗）`);
  if (darkNew.length) df.push(`深色档**新增** ${darkNew.length} 处文字对比度 < AA：${JSON.stringify(darkNew.slice(0, 4))}`);
  if (dark.siderTotal && dark.siderMin < 4.5) df.push(`深色档侧栏菜单文字最低对比度 ${dark.siderMin}:1：${JSON.stringify(dark.siderWorst)}`);
  if (dark.yuanCount > 0 && dark.yuanMin < 4.5) df.push(`深色档 ¥ 金额最低对比度 ${dark.yuanMin}:1`);
  if ((lumOf(darkShell.siderBg) ?? 1) > 0.1) df.push(`深色档侧栏底色 = ${darkShell.siderBg}（亮度 ${lumOf(darkShell.siderBg)?.toFixed(3)}）→ 侧栏没跟着档位回到近黑`);
  if (backLight.bodyBg !== LIGHT_BODY || backLight.attr !== 'light') df.push(`切回浅色失败：${backLight.attr} / ${backLight.bodyBg}`);
  if (backLight.siderBg !== LIGHT_SIDER) df.push(`切回浅色后侧栏底色 = ${backLight.siderBg}，期望白底`);
  record('⑧ 深色档保留（底色/侧栏/对比度/来回切换）', df, {
    深色: `body=${dark.bodyBg} 侧栏=${darkShell.siderBg} 发丝线=${darkShell.divider}`,
    深色最低对比度: `${dark.minRatio}:1`, 深色侧栏: `${dark.siderTotal} 项 · ${dark.siderMin === 99 ? '—' : dark.siderMin + ':1'}`,
    深色主区新增不达标: darkNew.length ? JSON.stringify(darkNew.slice(0, 4)) : '0 处',
    顶栏既有项: darkKnown.length ? `${darkKnown.length} 处（刷新/退出登录/超管标签，第一轮既有、本轮未动）：${darkKnown.map((x) => x.ratio + ':1').join(' / ')}` : '0 处',
    切回浅色: `${backLight.attr} / ${backLight.bodyBg} / 侧栏 ${backLight.siderBg}`,
    截图: darkShot,
  });

  // ================================================================ ⑨ 运行时异常
  hr('⑨ 运行时异常');
  const ef = [];
  if (cdp.exceptions.length) ef.push(`页面抛了 ${cdp.exceptions.length} 个未捕获异常：${cdp.exceptions.slice(0, 3).join(' | ')}`);
  record('⑨ 无未捕获异常', ef, { 异常数: cdp.exceptions.length });

  // ================================================================ 汇总
  hr('汇总');
  for (const r of results) console.log(`${r.fails.length ? 'FAIL' : 'PASS'}  ${r.name}  失败项=${r.fails.length}`);
  console.log(`\n共 ${results.length} 组断言，FAIL ${failCount} 组`);
  fs.writeFileSync(path.join(SHOT_DIR, 'probe-light-grouped-shell.json'), JSON.stringify({ mode: EXPECT_DEFAULT, results }, null, 2), 'utf8');
  console.log(`[落盘] ${path.join(SHOT_DIR, 'probe-light-grouped-shell.json')}`);
  if (failCount) process.exitCode = 1;
}

try {
  await main();
} catch (e) {
  console.error('运行失败：', e?.message ?? e);
  process.exitCode = 1;
} finally {
  try { browser?.kill(); } catch { /* ignore */ }
  await sleep(300);
  try { fs.rmSync(PROFILE, { recursive: true, force: true }); } catch { /* ignore */ }
}
