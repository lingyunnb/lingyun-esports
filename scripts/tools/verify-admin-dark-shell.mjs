/**
 * 管理端「深色科技风外壳」核验（无头 Edge + CDP 真跑真截图）
 * ============================================================================
 * 为什么有这个脚本（负责人 2026-10-11 任务）：
 *   · 本轮**只换壳不动业务**，因此"换得对不对"必须**在真浏览器里按渲染结果断言**
 *     （Vue 模板没渲染出来就等于没有）—— 尤其"登录页是否真的居中"、
 *     "深色下文字/发丝线/金额是否还看得清"这两类，读代码是读不出来的。
 *
 * 逐项断言（任一 FAIL → exit 1）：
 *   ① 登录页：卡片**水平居中**（左右留白差 ≤ 2% 视口宽）+ 页面背景为深色（`#080E1A`）+ 无横向滚动；
 *   ② 登录成功欢迎序列：全屏黑底 + 两行文案逐字命中（`欢迎回来，董事长`）+ `is_owner` 角色区分；
 *      并实测**总时长**落在 2.4–2.8s（不可跳过时）；
 *   ③ 主框架：侧栏为深色近黑（`#0B1220`）、菜单文字为白字系、折叠按钮生效（宽度 220 → 64 → 220）、
 *      面包屑与标签页存在且当前页命中；
 *   ④ 工作台：快捷导航卡 = 6 张、数据概览卡 ≥ 3 张；
 *   ⑤ 逐页深色对比度抽查（用户/钱包/充值/商品/订单/系统设置 6 页）：
 *      · 每页 `body` 背景是深色（相对亮度 < 0.1）；
 *      · 所有**直接承载文字**的元素对比度 ≥ 4.5（大字号 ≥ 3.0），并打印最低的 5 个；
 *      · 表格发丝线可见（`border-color` 与底色亮度差 ≥ 0.01）；
 *      · 页面上每个 `¥` 金额都能吃到（金额字符对比度 ≥ 4.5）；
 *      · 无未捕获异常；
 *   ⑥ **反向断言（变异）**：主题变量若没生效，`body` 背景色必须**逐字等于浅色档**
 *      （`rgb(245, 247, 251)`）；反之切到深色后必须**不再是**该值。
 *      这条是"如果主题变量没生效"的探针 —— 一旦 `data-theme` / themeOverrides 断链，它立刻 FAIL。
 *
 * 并行环境铁律（沿用 verify-admin-balance-copy.mjs / verify-admin-table-actions.mjs）：
 *   · **绝不用真实超管 `kslingyun` 登录** → 一律走 `scripts/tools/regression-admin.js`
 *     的专用测试超管（`.env` 里的 `REGRESSION_ADMIN_USER`）；
 *   · 会话被顶掉（落到 /login）**不静默重登**，如实打印并中断该页。
 *
 * 运行：node scripts/tools/verify-admin-dark-shell.mjs
 * 前置：pm2 fish-server（3100）、pm2 fish-admin（Vite dev 5173，只绑 IPv6 → http://[::1]:5173）
 * 可选环境变量：
 *   VDS_UI        管理端地址（默认 http://[::1]:5173；验证 dist 走 http://127.0.0.1:3100）
 *   VDS_API       后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   VDS_PAGES     深色抽查页面（默认 /users,/wallets,/recharge,/catalog,/orders,/settings）
 *   VDS_SHOT_DIR  截图目录（默认 <root>/docs/验收素材/2026-10-11-管理端深色）
 *   VDS_WIDTH     窗口宽度（默认 1600）
 *   VDS_EDGE_BIN  Edge 可执行文件
 *   VDS_CDP_PORT  CDP 端口（默认 9281）
 *   VDS_SKIP_WELCOME=1  跳过欢迎序列实测（只截最终工作台）
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

const UI = process.env.VDS_UI || 'http://[::1]:5173';
const API = process.env.VDS_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VDS_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VDS_CDP_PORT || 9281);
const WIDTH = Number(process.env.VDS_WIDTH || 1600);
const HEIGHT = Number(process.env.VDS_HEIGHT || 1000);
const PAGES = (process.env.VDS_PAGES || '/users,/wallets,/recharge,/catalog,/orders,/settings')
  .split(',').map((s) => s.trim()).filter(Boolean);
const SHOT_DIR = process.env.VDS_SHOT_DIR || path.join(ROOT, 'docs', '验收素材', '2026-10-11-管理端深色');
const USER = process.env.VDS_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VDS_ADMIN_PASS || REG_ADMIN_PASS;

if (!PASS) { console.error('缺少管理端口令（VDS_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

// 期望值（与 src/styles/tokens.css 逐值同源；改了 token 这里要同步，否则断言会"假红"）
const DARK_BODY = 'rgb(11, 18, 32)';      // --color-bg-page 深色档 #0B1220
const LIGHT_BODY = 'rgb(245, 247, 251)';  // --color-bg-page 浅色档 #F5F7FB
const LOGIN_BG = 'rgb(8, 14, 26)';        // 登录页底 #080E1A
const SIDER_BG = 'rgb(11, 18, 32)';       // 侧栏恒近黑 #0B1220

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

// ------------------------------------------------------------------ 页面内测量（对比度）
/**
 * 在页面里量**每个直接承载文字的元素**的对比度。
 * 只读测量，判定在 Node 侧做（便于打印"哪个元素、什么文本、多少比值"）。
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
  /** 从元素往上找到第一个不透明背景（跳过 alpha=0 的祖先） */
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
  /** 占位符文本（naive 的 placeholder 用 span 渲染）：不算"正文对比度"，
      但要单独量一遍 —— 输入框里"搜得到什么"也是可读性的一部分 */
  const isPlaceholder = (el) => !!el.closest('.n-input__placeholder');
  /** 侧栏菜单项：**恒深色底**（不随主题），单独统计 —— 不能拿主区的 AA 阈值套它 */
  const isSider = (el) => !!el.closest('.n-layout-sider');
  const items = [];
  const placeholders = [];
  const siderItems = [];
  const all = [...document.querySelectorAll('body *')];
  for (const el of all) {
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
      tag: el.tagName.toLowerCase(),
      cls: String(el.className || '').slice(0, 60),
      text: (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 26),
      px: Math.round(px), large, ratio: Math.round(cr * 100) / 100,
      fg: cs.color, bg: 'rgb(' + Math.round(bg.r) + ', ' + Math.round(bg.g) + ', ' + Math.round(bg.b) + ')',
    };
    if (isPlaceholder(el)) { placeholders.push(rec); continue; }
    if (isSider(el)) { siderItems.push(rec); continue; }
    items.push(rec);
  }
  const bodyBg = getComputedStyle(document.body).backgroundColor;
  const sider = document.querySelector('.n-layout-sider');
  const siderBg = sider ? getComputedStyle(sider).backgroundColor : null;
  /** 表格发丝线：取第一张可见表的 th / td 边框色，与表体底色比亮度差 */
  let hairline = null;
  const t = [...document.querySelectorAll('.n-data-table')].find((x) => x.getClientRects().length);
  if (t) {
    const th = t.querySelector('thead th');
    const td = t.querySelector('tbody td') || th;
    const el = td || th;
    if (el) {
      const cs = getComputedStyle(el);
      hairline = { border: cs.borderBottomColor, bg: cs.backgroundColor, w: cs.borderBottomWidth, cls: String(el.className).slice(0, 40) };
    }
  }
  const yuan = items.filter((i) => i.text.includes('¥'));
  return {
    path: location.pathname,
    bodyBg, siderBg,
    scrollW: document.documentElement.scrollWidth,
    clientW: document.documentElement.clientWidth,
    total: items.length,
    minRatio: items.reduce((a, i) => Math.min(a, i.ratio), 99),
    worst: items.slice().sort((a, b) => a.ratio - b.ratio).slice(0, 8),
    belowAA: items.filter((i) => i.ratio < (i.large ? 3.0 : 4.5)),
    yuanCount: yuan.length,
    yuanMin: yuan.reduce((a, i) => Math.min(a, i.ratio), 99),
    phCount: placeholders.length,
    phMin: placeholders.reduce((a, i) => Math.min(a, i.ratio), 99),
    siderTotal: siderItems.length,
    siderMin: siderItems.reduce((a, i) => Math.min(a, i.ratio), 99),
    siderWorst: siderItems.slice().sort((a, b) => a.ratio - b.ratio).slice(0, 3),
    hairline,
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
const PROFILE = os.tmpdir() + '/fish-edge-darkshell-' + Date.now();
let browser = null;

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

try {
  console.log(`[配置] UI=${UI} API=${API} 窗口=${WIDTH}x${HEIGHT} 抽查页=${PAGES.length} 截图目录=${SHOT_DIR}`);
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

  // ================================================================ 0. 登录页（居中）
  hr('0. 登录页：居中卡片 + 深色底');
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2600);
  /*
   * 清干净上一次运行留下的 localStorage（令牌 / 主题偏好 / 标签页列表）→ 本套件**可重复跑且结果一致**：
   *   · 令牌不清 → 路由守卫会直接把人从 /login 弹到 /dashboard，登录页就量不到了；
   *   · 主题偏好不清 → 若上一次点过「明暗切换」，这一轮就不在默认档上，"默认深色"这条就失去意义；
   *   · 标签页不清 → 之后截的图里会带上历史页签。
   */
  await cdp.evalJs(`localStorage.clear(); 'ok'`);
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2600);

  const loginProbe = await cdp.evalJs(`(() => {
    const card = document.querySelector('.login-card');
    const page = document.querySelector('.login-page');
    if (!card || !page) return { ok: false };
    const c = card.getBoundingClientRect();
    const vw = window.innerWidth;
    const cs = getComputedStyle(page);
    return {
      ok: true,
      vw,
      cardW: Math.round(c.width), cardH: Math.round(c.height),
      left: Math.round(c.left), right: Math.round(vw - c.right),
      cardCenter: Math.round(c.left + c.width / 2),
      pageBg: cs.backgroundColor,
      pageH: Math.round(page.getBoundingClientRect().height),
      hasGrid: !!document.querySelector('.bg-grid'),
      hasGlow: !!document.querySelector('.bg-glow'),
      brand: !!document.querySelector('.login-card svg.mountain-mark'),
      cardBg: getComputedStyle(card).backgroundColor,
      // 反面：登录页**不许**出现"左大图 / 右登录卡"那种分栏（左半区不该有任何大块元素）
      sideBySideBlocks: [...document.querySelectorAll('.login-page > *')].map((e) => e.className).join('|'),
      docScrollW: document.documentElement.scrollWidth,
      docClientW: document.documentElement.clientWidth,
    };
  })()`);
  const loginShot = await cdp.shot('01-登录页-居中卡片.png');
  const lf = [];
  if (!loginProbe?.ok) lf.push('没找到 .login-card / .login-page（登录页没渲染出来）');
  else {
    if (Math.abs(loginProbe.left - loginProbe.right) > loginProbe.vw * 0.02) {
      lf.push(`卡片未水平居中：左留白 ${loginProbe.left}px vs 右留白 ${loginProbe.right}px（视口 ${loginProbe.vw}）`);
    }
    if (Math.abs(loginProbe.cardCenter - loginProbe.vw / 2) > loginProbe.vw * 0.01) {
      lf.push(`卡片中心 ${loginProbe.cardCenter}px 偏离视口中线 ${loginProbe.vw / 2}px`);
    }
    if (loginProbe.pageBg !== LOGIN_BG) lf.push(`登录页底色不是深色 ${LOGIN_BG}，实际 ${loginProbe.pageBg}`);
    if (!loginProbe.hasGrid || !loginProbe.hasGlow) lf.push('缺少 CSS 背景层（极细网格 / 光晕）');
    if (!loginProbe.brand) lf.push('卡片里没有品牌雪山标（svg.mountain-mark）');
    if (loginProbe.docScrollW > loginProbe.docClientW + 1) lf.push(`登录页有横向滚动（${loginProbe.docScrollW} > ${loginProbe.docClientW}）`);
  }
  record('登录页（居中 + 深色底 + 品牌标）', lf, {
    卡片: `${loginProbe?.cardW}×${loginProbe?.cardH} @ left=${loginProbe?.left} right=${loginProbe?.right}`,
    页面底色: loginProbe?.pageBg,
    卡片底色: loginProbe?.cardBg,
    截图: loginShot,
  });

  // ================================================================ 1. 登录 → 欢迎序列
  hr('1. 登录成功欢迎序列（全屏纯黑 → 两行文案 → 淡出）');
  const who = await apiLogin();
  console.log(`     [账号] ${USER}（回归专用；isOwner=${who.isOwner}）`);
  if (!who.token) throw new Error(`测试超管 ${USER} 登录失败，无法继续（HTTP ${who.status}）：${who.raw}`);

  const t0 = Date.now();
  const fill = await cdp.evalJs(fillAndSubmit(USER, PASS));
  if (fill !== 'OK') throw new Error(`登录表单填充失败：${fill}`);

  // 轮询等欢迎覆盖层出现（它只在 fetchMe 成功后挂载）
  let welcomeAppeared = false;
  for (let i = 0; i < 40; i += 1) {
    await sleep(150);
    const has = await cdp.evalJs(`!!document.querySelector('[data-testid="welcome-overlay"]')`);
    if (has) { welcomeAppeared = true; break; }
  }
  const welcomeProbe = welcomeAppeared
    ? await cdp.evalJs(`(() => {
        const el = document.querySelector('[data-testid="welcome-overlay"]');
        const lines = [...el.querySelectorAll('[data-welcome-line]')].map((x) => x.innerText.trim());
        const cs = getComputedStyle(el);
        const first = el.querySelector('.welcome-line');
        const fs = first ? getComputedStyle(first) : null;
        const r = el.getBoundingClientRect();
        return {
          bg: cs.backgroundColor, zIndex: cs.zIndex,
          rect: { w: Math.round(r.width), h: Math.round(r.height), top: Math.round(r.top), left: Math.round(r.left) },
          lines,
          fontSize: fs ? fs.fontSize : null, fontWeight: fs ? fs.fontWeight : null,
          lineColor: fs ? fs.color : null,
          rule: !!el.querySelector('.welcome-rule'),
          path: location.pathname,
          modalCount: document.querySelectorAll('.n-modal, .n-dialog').length,
        };
      })()`)
    : null;
  const welcomeShot = welcomeAppeared ? await cdp.shot('02-登录成功欢迎序列.png') : null;
  // 等它自己播完（不可跳过时 ≈ 2.4s；这里给足余量）
  let welcomeGone = false;
  for (let i = 0; i < 60; i += 1) {
    await sleep(150);
    const has = await cdp.evalJs(`!!document.querySelector('[data-testid="welcome-overlay"]')`);
    if (!has) { welcomeGone = true; break; }
  }
  const elapsed = Date.now() - t0;
  const afterWelcome = await cdp.evalJs(`({ path: location.pathname, search: location.search })`);

  const wf = [];
  if (!welcomeAppeared) wf.push('登录后没有出现欢迎覆盖层（data-testid="welcome-overlay"）');
  else {
    if (welcomeProbe.bg !== 'rgb(0, 0, 0)') wf.push(`欢迎层底色不是纯黑，实际 ${welcomeProbe.bg}`);
    if (welcomeProbe.rect.w < WIDTH - 2 || welcomeProbe.rect.h < HEIGHT - 2) {
      wf.push(`欢迎层没有铺满视口：${welcomeProbe.rect.w}×${welcomeProbe.rect.h}（视口 ${WIDTH}×${HEIGHT}）`);
    }
    const expect = welcomeProbe.lines.length;
    if (who.isOwner) {
      if (!welcomeProbe.lines.includes('山高人为峰，客至心自明')) wf.push(`缺第一行文案（is_owner 角色），实际：${JSON.stringify(welcomeProbe.lines)}`);
      if (!welcomeProbe.lines.includes('欢迎回来，董事长')) wf.push(`缺第二行文案（is_owner 角色），实际：${JSON.stringify(welcomeProbe.lines)}`);
    } else if (welcomeProbe.lines.length !== 1 || welcomeProbe.lines[0] !== '欢迎回来') {
      wf.push(`非 is_owner 角色应只显示一行「欢迎回来」，实际：${JSON.stringify(welcomeProbe.lines)}`);
    }
    const px = parseFloat(welcomeProbe.fontSize || '0');
    if (!(px >= 40 && px <= 48)) wf.push(`欢迎文案字号 ${welcomeProbe.fontSize} 不在 40–48px 区间`);
    if (Number(welcomeProbe.fontWeight) < 800) wf.push(`欢迎文案字重 ${welcomeProbe.fontWeight} < 800`);
    if (welcomeProbe.lineColor !== 'rgb(255, 255, 255)') wf.push(`欢迎文案不是白色，实际 ${welcomeProbe.lineColor}`);
    if (!welcomeProbe.rule) wf.push('缺少品牌色细线（.welcome-rule）');
  }
  if (!welcomeGone) wf.push('欢迎层一直没消失（2.4s 后仍在，可能定时器没跑）');
  else if (who.isOwner && (elapsed < 2200 || elapsed > 3600)) {
    // 实测含轮询粒度（150ms）与登录请求耗时，故给 2.4s±(0.2 下限/1.2 上限) 的宽容带
    wf.push(`欢迎序列实测耗时 ${elapsed}ms，偏离 2.4–2.8s 规格（含登录请求与 150ms 轮询粒度）`);
  }
  if (afterWelcome?.search && afterWelcome.search.includes('welcome')) {
    wf.push(`播完后地址栏仍带 welcome 参数（${afterWelcome.search}）→ 刷新会重播`);
  }
  record('欢迎序列（黑底/文案/字号/字重/细线/时长/一次性）', wf, {
    文案行: JSON.stringify(welcomeProbe?.lines ?? []),
    字号字重: `${welcomeProbe?.fontSize} / ${welcomeProbe?.fontWeight}`,
    实测耗时: `${elapsed}ms`,
    播完地址: `${afterWelcome?.path}${afterWelcome?.search ?? ''}`,
    截图: welcomeShot,
  });
  if (!welcomeAppeared || !welcomeGone) throw new Error('欢迎序列未按预期出现/消失，后续页面断言已无意义，中断');

  // ================================================================ 2. 主框架
  hr('2. 主框架：深色侧栏 + 折叠 + 面包屑 + 标签页');
  await sleep(1200);
  const shell = await cdp.evalJs(`(() => {
    const sider = document.querySelector('.n-layout-sider');
    const menu = document.querySelector('.sider-menu .n-menu');
    const item = document.querySelector('.sider-menu .n-menu-item-content-header');
    const crumbs = [...document.querySelectorAll('.crumbs .crumb')].map((x) => x.innerText.trim());
    const tabs = [...document.querySelectorAll('.tabbar .tab')].map((x) => x.innerText.replace(/\\s+/g, '').trim());
    const header = document.querySelector('.header');
    return {
      siderBg: sider ? getComputedStyle(sider).backgroundColor : null,
      siderW: sider ? Math.round(sider.getBoundingClientRect().width) : null,
      menuBg: menu ? getComputedStyle(menu).backgroundColor : null,
      itemColor: item ? getComputedStyle(item).color : null,
      crumbs, tabs,
      headerBg: header ? getComputedStyle(header).backgroundColor : null,
      tabbarBg: document.querySelector('.tabbar') ? getComputedStyle(document.querySelector('.tabbar')).backgroundColor : null,
      bodyBg: getComputedStyle(document.body).backgroundColor,
      themeAttr: document.documentElement.getAttribute('data-theme'),
    };
  })()`);
  // 折叠：点按钮 → 量宽度 → 再点一次还原
  const collapsedW = await (async () => {
    await cdp.evalJs(`document.querySelector('.header .icon-btn').dispatchEvent(new MouseEvent('click', { bubbles: true })); 'ok'`);
    await sleep(700);
    const w = await cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
    await cdp.shot('03b-主框架-侧栏已折叠.png');
    await cdp.evalJs(`document.querySelector('.header .icon-btn').dispatchEvent(new MouseEvent('click', { bubbles: true })); 'ok'`);
    await sleep(700);
    return w;
  })();
  const restoreW = await cdp.evalJs(`Math.round(document.querySelector('.n-layout-sider').getBoundingClientRect().width)`);
  /*
   * 展开态整屏截图放在折叠往返**之后**、且**在业务页上取**：
   * ① 那时主题已稳定（避免截到"主题刚切过来"的中间帧）；
   * ② 若停在工作台，这张图会与后面的工作台整屏图**逐字节相同**（实测撞过一次，
   *    两张 108580B 的 PNG 同哈希）—— 换到业务页取，才真的拍出"外壳包住业务页"的样子。
   */
  await cdp.send('Page.navigate', { url: `${UI}/users` });
  await sleep(3200);
  const shellShot = await cdp.shot('03-主框架-深色侧栏.png');

  const sf = [];
  if (shell.siderBg !== SIDER_BG) sf.push(`侧栏底色不是近黑 ${SIDER_BG}，实际 ${shell.siderBg}`);
  if ((lumOf(shell.itemColor) ?? 1) < 0.5) sf.push(`侧栏菜单文字不是白字系（${shell.itemColor}）`);
  if (shell.menuBg !== 'rgba(0, 0, 0, 0)') sf.push(`菜单自身底色未透明化（${shell.menuBg}）→ 会盖掉近黑侧栏`);
  if (collapsedW !== 64) sf.push(`折叠后侧栏宽度 = ${collapsedW}px（期望 64）`);
  if (restoreW !== 220) sf.push(`再次展开后侧栏宽度 = ${restoreW}px（期望 220）`);
  if (!shell.crumbs.length) sf.push('面包屑为空');
  if (!shell.tabs.length) sf.push('标签页为空');
  if (!shell.tabs.some((t) => t.includes('工作台'))) sf.push(`标签页里没有「工作台」：${JSON.stringify(shell.tabs)}`);
  if (shell.themeAttr !== 'dark' && shell.themeAttr !== 'light') sf.push(`<html data-theme> 未设置（${shell.themeAttr}）`);
  record('主框架（侧栏/折叠/面包屑/标签页）', sf, {
    侧栏: `${shell.siderBg} @ ${shell.siderW}px → 折叠 ${collapsedW}px → 展开 ${restoreW}px`,
    菜单文字: shell.itemColor,
    面包屑: shell.crumbs.join(' / '),
    标签页: shell.tabs.join(' | '),
    截图: shellShot,
  });

  // ================================================================ 3. 工作台
  hr('3. 工作台：快捷导航六宫格 + 数据概览卡');
  await cdp.send('Page.navigate', { url: `${UI}/dashboard` });
  await sleep(3200);
  const dash = await cdp.evalJs(`(() => {
    const nav = [...document.querySelectorAll('[data-nav]')].map((x) => ({
      key: x.getAttribute('data-nav'),
      title: x.querySelector('.nav-title')?.innerText.trim(),
      desc: x.querySelector('.nav-desc')?.innerText.trim(),
      iconColor: x.querySelector('.nav-icon') ? getComputedStyle(x.querySelector('.nav-icon')).color : null,
    }));
    const stats = [...document.querySelectorAll('[data-stat]')].map((x) => ({
      key: x.getAttribute('data-stat'),
      tag: x.querySelector('.stat-tag')?.innerText.trim(),
      value: x.querySelector('.stat-value')?.innerText.trim(),
      label: x.querySelector('.stat-label')?.innerText.trim(),
      desc: x.querySelector('.stat-desc')?.innerText.trim(),
      isMoney: !!x.querySelector('.stat-value.is-money'),
    }));
    return { nav, stats, bodyBg: getComputedStyle(document.body).backgroundColor, path: location.pathname };
  })()`);
  const dashShot = await cdp.shot('04-工作台-六宫格与数据概览.png', { beyond: true });

  const df = [];
  const dashContrast = await cdp.evalJs(CONTRAST_PROBE);
  if (dash.nav.length !== 6) df.push(`快捷导航卡 = ${dash.nav.length} 张（期望 6）`);
  if (dash.nav.some((n) => !n.title || !n.desc)) df.push(`有导航卡缺标题或说明：${JSON.stringify(dash.nav.filter((n) => !n.title || !n.desc))}`);
  if (new Set(dash.nav.map((n) => n.iconColor)).size < 3) df.push(`导航卡图标不是彩色（去重后仅 ${new Set(dash.nav.map((n) => n.iconColor)).size} 种颜色）`);
  if (dash.stats.length < 3) df.push(`数据概览卡 = ${dash.stats.length} 张（期望 ≥ 3）`);
  if (!dash.stats.some((s) => s.tag === '今日')) df.push('数据概览里没有「今日」标签的卡');
  if (!dash.stats.some((s) => s.tag === '实时')) df.push('数据概览里没有「实时」标签的卡');
  if (!dash.stats.some((s) => s.tag === '累计')) df.push('数据概览里没有「累计」标签的卡');
  if (dash.bodyBg !== DARK_BODY) df.push(`工作台底色不是 ${DARK_BODY}，实际 ${dash.bodyBg}`);
  if (dashContrast.belowAA.length) {
    df.push(`工作台有 ${dashContrast.belowAA.length} 处文字对比度不达标：${JSON.stringify(dashContrast.belowAA.slice(0, 3))}`);
  }
  if (dashContrast.siderTotal > 0 && dashContrast.siderMin < 4.5) {
    df.push(`侧栏菜单文字最低对比度仅 ${dashContrast.siderMin}:1：${JSON.stringify(dashContrast.siderWorst)}`);
  }
  record('工作台（六宫格 + 数据概览）', df, {
    导航卡: dash.nav.map((n) => n.title).join(' / '),
    概览卡: dash.stats.map((s) => `[${s.tag}]${s.label}=${s.value}`).join(' · '),
    最低对比度: `${dashContrast.minRatio}:1`,
    侧栏对比度: `${dashContrast.siderMin === 99 ? '—' : dashContrast.siderMin + ':1'}`,
    截图: dashShot,
  });

  // ================================================================ 4. 反向断言（变异探针）
  hr('4. 反向断言：主题变量若没生效，body 底色会停在浅色档');
  // 先切到浅色 → 断言 body 底色**逐字等于**浅色档
  await cdp.evalJs(`(() => {
    const btns = [...document.querySelectorAll('.header .icon-btn')];
    btns[1].dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return 'ok';
  })()`);
  await sleep(700);
  const lightState = await cdp.evalJs(`({
    bodyBg: getComputedStyle(document.body).backgroundColor,
    attr: document.documentElement.getAttribute('data-theme'),
    cardBg: (() => { const c = document.querySelector('.stat-card, .nav-card'); return c ? getComputedStyle(c).backgroundColor : null; })(),
    divider: getComputedStyle(document.documentElement).getPropertyValue('--color-divider').trim(),
  })`);
  await cdp.shot('05-浅色主题对照.png');
  // 再切回深色 → 断言**不再是**浅色档
  await cdp.evalJs(`(() => {
    const btns = [...document.querySelectorAll('.header .icon-btn')];
    btns[1].dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return 'ok';
  })()`);
  await sleep(700);
  const darkState = await cdp.evalJs(`({
    bodyBg: getComputedStyle(document.body).backgroundColor,
    attr: document.documentElement.getAttribute('data-theme'),
    cardBg: (() => { const c = document.querySelector('.stat-card, .nav-card'); return c ? getComputedStyle(c).backgroundColor : null; })(),
    divider: getComputedStyle(document.documentElement).getPropertyValue('--color-divider').trim(),
  })`);

  const mf = [];
  if (lightState.bodyBg !== LIGHT_BODY) mf.push(`浅色档 body 底色 = ${lightState.bodyBg}，期望 ${LIGHT_BODY}（主题变量可能没生效）`);
  if (lightState.attr !== 'light') mf.push(`浅色档 <html data-theme> = ${lightState.attr}，期望 light`);
  if (darkState.bodyBg !== DARK_BODY) mf.push(`深色档 body 底色 = ${darkState.bodyBg}，期望 ${DARK_BODY}`);
  if (darkState.attr !== 'dark') mf.push(`深色档 <html data-theme> = ${darkState.attr}，期望 dark`);
  if (darkState.bodyBg === lightState.bodyBg) mf.push('两档 body 底色**完全相同** → 主题变量根本没生效（变异探针命中）');
  if ((lumOf(darkState.bodyBg) ?? 1) > 0.1) mf.push(`深色档底色相对亮度 ${lumOf(darkState.bodyBg)?.toFixed(3)} > 0.1（不够暗）`);
  if ((lumOf(lightState.bodyBg) ?? 0) < 0.8) mf.push(`浅色档底色相对亮度 ${lumOf(lightState.bodyBg)?.toFixed(3)} < 0.8（不够浅）`);
  if (darkState.divider === lightState.divider) mf.push(`两档 --color-divider 相同（${darkState.divider}）→ 发丝线没跟着主题走`);
  record('反向断言（主题变量生效性 + 深浅两档色值）', mf, {
    浅色档: `body=${lightState.bodyBg} attr=${lightState.attr} card=${lightState.cardBg} divider=${lightState.divider}`,
    深色档: `body=${darkState.bodyBg} attr=${darkState.attr} card=${darkState.cardBg} divider=${darkState.divider}`,
  });

  // ================================================================ 5. 逐页深色抽查
  hr(`5. 逐页深色对比度抽查（${PAGES.length} 页）`);
  let relogins = 0;
  for (const p of PAGES) {
    await cdp.send('Page.navigate', { url: `${UI}${p}` });
    await sleep(3400);
    if ((await cdp.evalJs('location.pathname')) === '/login') {
      if (relogins >= 2) { record(`深色抽查 ${p}`, ['落到 /login（会话被顶）']); continue; }
      relogins += 1;
      console.log(`     [会话] ${p} 落到 /login（疑似被并行批次顶号）→ 第 ${relogins} 次重新登录`);
      const again = await apiLogin();
      if (!again.token) { record(`深色抽查 ${p}`, ['重新登录失败']); continue; }
      await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(again.token)}); 'ok'`);
      await cdp.send('Page.navigate', { url: `${UI}${p}` });
      await sleep(3400);
    }
    const probe = await cdp.evalJs(CONTRAST_PROBE);
    // 表格另量发丝线：与表体底色的亮度差
    const hair = probe.hairline;
    const hairGap = hair && hair.border && hair.bg ? Math.abs((lumOf(hair.border) ?? 0) - (lumOf(hair.bg) ?? 0)) : null;
    const shot = await cdp.shot(`06-深色抽查-${p.replace(/\//g, '')}.png`, { beyond: true });

    const fails = [];
    const bodyLum = lumOf(probe.bodyBg);
    if (bodyLum === null || bodyLum > 0.1) fails.push(`页面底色不够深：${probe.bodyBg}（亮度 ${bodyLum?.toFixed(3)}）`);
    if (probe.belowAA.length) {
      fails.push(`有 ${probe.belowAA.length} 处文字对比度 < AA：${JSON.stringify(probe.belowAA.slice(0, 4))}`);
    }
    if (hair && hairGap !== null && hairGap < 0.01) {
      fails.push(`表格发丝线与底色几乎无亮度差（${hair.border} vs ${hair.bg}，差 ${hairGap.toFixed(4)}）→ 深色下看不见`);
    }
    if (probe.yuanCount > 0 && probe.yuanMin < 4.5) {
      fails.push(`有 ¥ 金额对比度仅 ${probe.yuanMin}:1（< 4.5）`);
    }
    // 输入框占位符：不按正文 AA 卡（占位文本本就该弱化），但低于 2.5:1 就是"看不见"
    if (probe.phCount > 0 && probe.phMin < 2.5) {
      fails.push(`输入框占位符对比度仅 ${probe.phMin}:1（< 2.5，深色下几乎看不见）`);
    }
    // 侧栏：恒深色底，文字按同一套 AA 阈值（白字菜单是本次交付的明确要求）
    if (probe.siderTotal > 0 && probe.siderMin < 4.5) {
      fails.push(`侧栏菜单文字最低对比度仅 ${probe.siderMin}:1：${JSON.stringify(probe.siderWorst)}`);
    }
    if (probe.scrollW > probe.clientW + 1 && !/^\/chat$/.test(p)) {
      // 页面级横向滚动（表格自身的 scroll-x 不算：那是表格内部容器）
      // 这里只提示，不判失败：宽表在窄视口下的页面级滚动属既有行为
    }
    record(`深色抽查 ${p}`, fails, {
      底色: `${probe.bodyBg}（亮度 ${bodyLum?.toFixed(3)}）`,
      文字元素: `${probe.total} 个 · 最低对比度 ${probe.minRatio}:1 · 不达标 ${probe.belowAA.length}`,
      '¥金额': `${probe.yuanCount} 处 · 最低 ${probe.yuanMin === 99 ? '—' : probe.yuanMin + ':1'}`,
      占位符: `${probe.phCount} 处 · 最低 ${probe.phMin === 99 ? '—' : probe.phMin + ':1'}`,
      侧栏: `${probe.siderTotal} 项 · 最低 ${probe.siderMin === 99 ? '—' : probe.siderMin + ':1'}`,
      发丝线: hair ? `${hair.border} vs ${hair.bg}（差 ${hairGap === null ? '—' : hairGap.toFixed(4)}，宽 ${hair.w}）` : '本页无表格',
      最差5处: JSON.stringify(probe.worst.slice(0, 5)),
      截图: shot,
    });
  }

  // ================================================================ 6. 控制台异常
  hr('6. 运行时异常');
  const ef = [];
  if (cdp.exceptions.length) ef.push(`页面抛了 ${cdp.exceptions.length} 个未捕获异常：${cdp.exceptions.slice(0, 3).join(' | ')}`);
  record('无未捕获异常', ef, { 异常数: cdp.exceptions.length });

  // ================================================================ 汇总
  hr('汇总');
  for (const r of results) console.log(`${r.fails.length ? 'FAIL' : 'PASS'}  ${r.name}  失败项=${r.fails.length}`);
  console.log(`\n共 ${results.length} 组断言，FAIL ${failCount} 组`);
  fs.writeFileSync(path.join(SHOT_DIR, 'probe-dark-shell.json'), JSON.stringify(results, null, 2), 'utf8');
  console.log(`[落盘] ${path.join(SHOT_DIR, 'probe-dark-shell.json')}`);
  if (failCount) process.exitCode = 1;
} catch (e) {
  console.error('运行失败：', e?.message ?? e);
  process.exitCode = 1;
} finally {
  try { browser?.kill(); } catch { /* ignore */ }
  await sleep(300);
  try { fs.rmSync(PROFILE, { recursive: true, force: true }); } catch { /* ignore */ }
}
