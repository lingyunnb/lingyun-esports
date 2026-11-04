/**
 * 管理端表格「操作」列可见性核验（无头 Edge + CDP 真跑真截图）
 * ---------------------------------------------------------------------------
 * 为什么有这个脚本（负责人 2026-10-08 反馈：「管理端里的删除/封号被挤没了显示不完全」）：
 *   · 根因是 `:scroll-x` 小于列宽总和 + 操作列没有 fixed:'right' → 右侧列被裁；
 *   · 「够不够放按钮」**不能靠猜**，必须在真浏览器里量：td 内宽、按钮 rect、是否折行、
 *     以及按钮右边界是否落在表格可视区域内（fixed 列是否真的钉住了）。
 * 本脚本对每个页面输出：
 *   ① 表格可视区宽度 vs 内容宽度（有无横向滚动）
 *   ② 每个「操作」单元格里按钮的文本/宽度/top（top 不一致=折行）与右边界是否越界（=被裁）
 *   ③ 1280 / 1600 两个窗口宽度各截一张图（默认存 docs/验收素材/2026-10-08-管理端操作列/）
 *
 * 并行环境铁律（沿用 verify-recharge-qr-upload.mjs）：
 *   · **绝不用真实超管 `kslingyun` 登录**（会顶掉负责人会话）→ 一律走 `scripts/tools/regression-admin.js`
 *     的专用测试超管（`.env` 里登记的 `REGRESSION_ADMIN_USER` / `REGRESSION_ADMIN_PASSWORD`）；
 *     仍可用 `VTA_ADMIN_USER` / `VTA_ADMIN_PASS` 显式覆盖。
 *     （2026-10-08 前此处读 `FISHADMIN_*`，该账号已随「清理测试数据」删除 → 死凭证，已收口，见 docs/12）
 *   · 会话被顶掉（落到 /login）不静默重登，如实打印并中断该页。
 *
 * 运行：node scripts/tools/verify-admin-table-actions.mjs
 * 前置：pm2 fish-server（3100）、pm2 fish-admin（Vite dev 5173，只绑 IPv6 → http://[::1]:5173）
 * 可选环境变量：
 *   VTA_UI            管理端地址（默认 http://[::1]:5173；验证 dist 走 http://127.0.0.1:3100）
 *   VTA_API           后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   VTA_WIDTHS        窗口宽度列表（默认 1280,1600）
 *   VTA_PAGES         页面路径列表（默认 /users,/admins,/workers,... 全量）
 *   VTA_SHOT_DIR      截图目录（默认 <root>/docs/验收素材/2026-10-08-管理端操作列）
 *   VTA_TAG           截图文件名前缀（如 before / after）
 *   VTA_EDGE_BIN      Edge 可执行文件
 *   VTA_CDP_PORT      CDP 端口（默认 9262）
 */
import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
// 管理端账号：**唯一入口** scripts/tools/regression-admin.js（债 1；ESM 里用 createRequire 引 CJS）。
// 原先读 server/.env 的 FISHADMIN_*（账号已于 2026-10-08 随「清理测试数据」被删除 → 死凭证）。
const requireCjs = createRequire(import.meta.url);
const { adminUser: REG_ADMIN_USER, adminPassword: REG_ADMIN_PASS } = requireCjs('./regression-admin.js');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(process.env.FISH_ROOT || path.join(HERE, '..', '..'));
const SERVER_ENV = path.join(ROOT, 'server', '.env');

const envFile = (() => { try { return fs.readFileSync(SERVER_ENV, 'utf8'); } catch { return ''; } })();
const envOf = (k) => { const m = envFile.match(new RegExp('^' + k + '=(.+)$', 'm')); return m ? m[1].trim() : null; };

const UI = process.env.VTA_UI || 'http://[::1]:5173';
const API = process.env.VTA_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VTA_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VTA_CDP_PORT || 9262);
const WIDTHS = (process.env.VTA_WIDTHS || '1280,1600').split(',').map((s) => Number(s.trim())).filter(Boolean);
const PAGES = (process.env.VTA_PAGES || '/users,/admins,/workers,/orders,/catalog,/recharge,/wallets,/refunds,/complaints,/appeals,/tips,/commission,/audit,/feedback,/announcements,/banners,/divisions,/clubs,/chat,/leaderboard,/settings,/app-update,/identity-bindings').split(',').map((s) => s.trim()).filter(Boolean);
const SHOT_DIR = process.env.VTA_SHOT_DIR || path.join(ROOT, 'docs', '验收素材', '2026-10-08-管理端操作列');
const TAG = process.env.VTA_TAG || 'after';
const USER = process.env.VTA_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VTA_ADMIN_PASS || REG_ADMIN_PASS;

if (!PASS) { console.error('缺少管理端口令（VTA_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);

// ------------------------------------------------------------------ CDP
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.console = []; this.exceptions = [];
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.method === 'Runtime.consoleAPICalled') {
        const t = (m.params?.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ');
        if (m.params?.type === 'error') this.console.push(t);
      }
      if (m.method === 'Runtime.exceptionThrown') this.exceptions.push(flat(JSON.stringify(m.params?.exceptionDetails ?? {})).slice(0, 200));
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
  async shot(name) {
    const r = await this.send('Page.captureScreenshot', { format: 'png' });
    const buf = Buffer.from(r.data, 'base64');
    const p = path.join(SHOT_DIR, name);
    fs.writeFileSync(p, buf);
    console.log(`[SHOT] ${p} (${buf.length} bytes)`);
    return p;
  }
}

// ------------------------------------------------------------------ 页面内测量
/** 在页面里量：表格可视区、横向滚动、每列宽度、操作列按钮 rect/折行/是否越界 */
const PROBE = `(() => {
  const out = { tables: [] };
  const tables = [...document.querySelectorAll('.n-data-table')].filter((t) => t.offsetParent !== null || t.getClientRects().length);
  for (const t of tables) {
    const info = { rowCount: t.querySelectorAll('tbody tr').length, headerScrollWidth: null, viewWidth: null, contentWidth: null, cols: [], actionCells: [], clippedCells: [] };
    // 横向滚动容器：naive-ui 里带 overflow-x 且内容超宽的那层
    let sc = null;
    for (const e of t.querySelectorAll('*')) {
      const cs = getComputedStyle(e);
      if ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') && e.scrollWidth > e.clientWidth + 1) { sc = e; break; }
    }
    if (!sc) { for (const e of t.querySelectorAll('*')) { const cs = getComputedStyle(e); if (cs.overflowX === 'auto' || cs.overflowX === 'scroll') { sc = e; break; } } }
    const clipRect = (sc || t).getBoundingClientRect();
    info.viewWidth = Math.round(clipRect.width);
    info.contentWidth = sc ? sc.scrollWidth : Math.round(t.getBoundingClientRect().width);
    info.hasHScroll = !!sc && sc.scrollWidth > sc.clientWidth + 1;
    info.scrollCls = sc ? sc.className : null;
    const ths = [...t.querySelectorAll('thead th')];
    info.cols = ths.map((th) => {
      const r = th.getBoundingClientRect();
      return { text: th.innerText.replace(/\\s+/g, ' ').trim(), w: Math.round(r.width), left: Math.round(r.left), right: Math.round(r.right), fixedRight: /fixed-right/.test(th.className) };
    });
    const rows = [...t.querySelectorAll('tbody tr')].slice(0, 3);
    // 每列「视觉行数 / 是否横向溢出单元格」：用 Range 的 client rects 量真实排版
    // （文字被挤到换行 = 行数 > 1；nowrap 内容超出单元格 = rightMost > 单元格右边界）
    info.colStats = info.cols.map(() => ({ maxLines: 0, overflow: false, sample: '' }));
    const measureTd = (td, ci) => {
      const st = info.colStats[ci]; if (!st) return;
      // 列配置写了 ellipsis 的单元格：naive-ui 用 NEllipsis 包住（.n-ellipsis，CSS 截断 + 省略号 + tooltip），
      // Range 量到的是完整文本盒 → 不算溢出（否则每次都会误报）
      if (td.querySelector('.n-ellipsis') || /ellipsis/.test(td.className)) { st.ellipsis = true; return; }
      const tdRect = td.getBoundingClientRect();
      // 只量**文本节点**的排版盒：元素盒（tag/按钮/span）会给出跨行合并盒，导致行数误判
      const rects = [];
      const walker = document.createTreeWalker(td, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (!n.nodeValue || !n.nodeValue.trim()) continue;
        const r = document.createRange(); r.selectNodeContents(n);
        for (const x of r.getClientRects()) if (x.width > 0.5 && x.height > 0.5) rects.push(x);
      }
      if (!rects.length) return;
      const lines = new Set(rects.map((x) => Math.round(x.top))).size;
      const rightMost = Math.max(...rects.map((x) => x.right));
      st.maxLines = Math.max(st.maxLines, lines);
      st.rects = Math.max(st.rects ?? 0, rects.length);
      st.tops = [...new Set(rects.map((x) => Math.round(x.top)))].join(',');
      if (rightMost > tdRect.right + 1) st.overflow = true;
      if (!st.sample) st.sample = (td.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 28);
    };
    rows.forEach((tr, ri) => {
      const tds = [...tr.querySelectorAll('td')];
      tds.forEach((td, ci) => { measureTd(td, ci); });
    });
    rows.forEach((tr, ri) => {
      const tds = [...tr.querySelectorAll('td')];
      tds.forEach((td, ci) => {
        const head = info.cols[ci]?.text ?? '';
        const cs = getComputedStyle(td);
        const inner = td.firstElementChild;
        const cellRect = td.getBoundingClientRect();
        const overflow = inner ? inner.scrollWidth > td.clientWidth + 1 : false;
        const btns = [...td.querySelectorAll('button')].map((b) => {
          const r = b.getBoundingClientRect();
          return {
            text: b.innerText.replace(/\\s+/g, ' ').trim(),
            w: Math.round(r.width), h: Math.round(r.height),
            left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top),
            insideClip: r.right <= clipRect.right + 1 && r.left >= clipRect.left - 1,
          };
        });
        const rec = {
          col: head, tdW: td.clientWidth, tdRight: Math.round(cellRect.right), padding: cs.paddingLeft + '/' + cs.paddingRight,
          contentOverflow: overflow, ellipsis: !!td.querySelector('.n-ellipsis') || /ellipsis/.test(td.className), btns,
          btnRowWrapped: btns.length > 1 && new Set(btns.map((b) => b.top)).size > 1,
          btnRightBeyondTd: btns.length ? Math.max(...btns.map((b) => b.right)) > Math.round(cellRect.right) + 1 : false,
        };
        if (ci === 0 && ri === 0) info.firstCell = rec;
        if (btns.length) info.actionCells.push({ row: ri, ...rec });
        // 所有单元格的内容溢出（文字被挤到换行/裁切）；ellipsis 列是设计内截断，不算
        if ((overflow && !td.querySelector('.n-ellipsis') && !/ellipsis/.test(td.className)) || rec.btnRightBeyondTd) info.clippedCells.push({ row: ri, col: head, tdW: td.clientWidth, overflow, btnRightBeyondTd: rec.btnRightBeyondTd, text: (td.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40) });
      });
    });
    out.tables.push(info);
  }
  // 内容区可用宽度（供「1600 下是否还需横向滚动」判断）
  const content = document.querySelector('.n-layout-content') || document.querySelector('.n-layout .n-layout-scroll-container');
  out.contentWidth = content ? Math.round(content.getBoundingClientRect().width) : null;
  out.pageScrollX = window.scrollX;
  out.path = location.pathname;
  return out;
})()`;

// ------------------------------------------------------------------ 主流程
const PROFILE = os.tmpdir() + '/fish-edge-tableact-' + Date.now();
let browser = null;
const results = [];

async function apiLogin() {
  const r = await fetch(API + '/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: USER, password: PASS, role: 'admin' }),
    signal: AbortSignal.timeout(15000),
  });
  const text = await r.text();
  let j = null; try { j = JSON.parse(text); } catch { /* ignore */ }
  return { status: r.status, token: j?.data?.accessToken ?? null, raw: text.slice(0, 200) };
}

try {
  console.log(`[配置] UI=${UI} API=${API} 宽度=${WIDTHS.join('/')} 页面=${PAGES.length} 张截图目录=${SHOT_DIR} tag=${TAG}`);
  browser = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-first-run',
    `--user-data-dir=${PROFILE}`, '--window-size=1600,1000', 'about:blank'], { stdio: 'ignore' });
  await sleep(2600);

  hr(`0. 登录（专用测试超管 ${USER}，绝不用 kslingyun）`);
  const login = await apiLogin();
  console.log(`[会话] POST /auth/login → HTTP ${login.status}${login.token ? ' 已拿到 accessToken' : ' 无 token：' + login.raw}`);
  if (!login.token) throw new Error(`测试超管 ${USER} 登录失败，无法继续（HTTP ${login.status}）`);

  const httpGet = (url) => new Promise((res, rej) => {
    import('http').then((h) => h.get(url, (r) => { let d = ''; r.on('data', (c) => (d += c)); r.on('end', () => res(d)); }).on('error', rej));
  });
  const targets = JSON.parse(await httpGet(`http://127.0.0.1:${PORT}/json`));
  const page = targets.find((t) => t.type === 'page');
  const cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await sleep(400);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Network.enable');

  // 先落到登录页把 token 塞进 localStorage（管理端按 fish_admin_token 取值）
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2200);
  await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(login.token)}); 'ok'`);
  const me = await cdp.evalJs(`(async () => { const r = await fetch(${JSON.stringify(API)} + '/auth/me', { headers: { Authorization: 'Bearer ' + localStorage.getItem('fish_admin_token') } }); const j = await r.json(); return { status: r.status, role: j?.data?.admin?.roleCode ?? j?.data?.roleCode, isOwner: j?.data?.admin?.isOwner ?? j?.data?.isOwner, perms: (j?.data?.admin?.permissions ?? j?.data?.permissions ?? []).length }; })()`);
  console.log(`[会话] /auth/me → HTTP ${me?.status} roleCode=${me?.role} isOwner=${me?.isOwner} 权限点=${me?.perms}`);
  if (me?.status !== 200) throw new Error('会话不可用，中断（不重新登录以免顶号）');

  for (const width of WIDTHS) {
    hr(`窗口宽度 ${width}`);
    await cdp.send('Emulation.setDeviceMetricsOverride', { width, height: Math.max(900, 1000), deviceScaleFactor: 1, mobile: false });
    for (const p of PAGES) {
      await cdp.send('Page.navigate', { url: `${UI}${p}` });
      await sleep(2600);
      const probe = await cdp.evalJs(PROBE);
      if (probe?.path === '/login') {
        console.log(`[!!] ${p} 落到 /login（会话被顶）→ 跳过，不重新登录`);
        continue;
      }
      const t = probe?.tables?.[0];
      if (!t) { console.log(`[--] ${p} 无可见表格，跳过`); continue; }
      // 表格滚进视口再截图
      await cdp.evalJs(`(() => { const el = document.querySelector('.n-data-table'); if (el) { const y = el.getBoundingClientRect().top + window.scrollY - 90; window.scrollTo(0, Math.max(0, y)); } return 'ok'; })()`);
      await sleep(400);
      const shot = await cdp.shot(`${TAG}-${width}-${p.replace(/\//g, '')}.png`);
      const actions = t.actionCells.filter((a) => a.row === 0);
      const rec = {
        width, page: p, shot, viewWidth: t.viewWidth, contentWidth: t.contentWidth, hasHScroll: t.hasHScroll,
        contentArea: probe.contentWidth,
        cols: t.cols.map((c) => `${c.text}:${c.w}${c.fixedRight ? '(fixedR)' : ''}`).join(' | '),
        actionCol: actions[0]?.col ?? null,
        actionBtns: actions[0]?.btns ?? [],
        actionTdW: actions[0]?.tdW ?? null,
        wrapped: actions[0]?.btnRowWrapped ?? null,
        clipped: t.clippedCells,
        exceptions: cdp.exceptions.slice(-2),
      };
      results.push(rec);
      const btnTxt = rec.actionBtns.map((b) => `${b.text}(${b.w}px${b.insideClip ? '' : ' ⚠越界'})`).join(' + ');
      console.log(`[表] ${p} 可视宽=${t.viewWidth} 内容宽=${t.contentWidth} 横向滚动=${t.hasHScroll ? 'YES' : 'no'} 内容区宽=${probe.contentWidth}`);
      console.log(`     列宽：${rec.cols}`);
      console.log(`     折行/溢出：${(t.colStats || []).map((s, i) => `${t.cols[i]?.text}:${s.maxLines}行/rects${s.rects ?? 0}${s.overflow ? '⚠溢出' : ''}${s.maxLines > 1 ? `[${s.tops}|${s.sample}]` : ''}`).join(' | ')}`);
      console.log(`     操作列：宽=${rec.actionTdW} 按钮=${btnTxt || '(无按钮)'} 折行=${rec.wrapped ? 'YES ⚠' : 'no'} 溢出单元格=${rec.clipped.length ? JSON.stringify(rec.clipped) : '无'}`);
      if (rec.exceptions.length) console.log(`     ⚠ 页面异常：${rec.exceptions.join(' ; ')}`);
    }
  }

  if (process.env.VTA_OWNER_PROBE === '1') {
    hr('超管所有者视角（is_owner=1）：「更多」下拉是否收纳破坏性动作');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
    await cdp.send('Page.navigate', { url: `${UI}/admins` });
    await sleep(3000);
    const before = await cdp.evalJs(`(() => {
      const btn = [...document.querySelectorAll('.n-data-table tbody button')].find((b) => b.innerText.replace(/\\s+/g, '').trim() === '更多');
      if (!btn) return { found: false };
      const r = btn.getBoundingClientRect();
      return { found: true, x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), w: Math.round(r.width), rowBtns: [...btn.closest('td').querySelectorAll('button')].map((b) => b.innerText.replace(/\\s+/g, '').trim()) };
    })()`);
    console.log(`[UI] 管理员表格首行「更多」按钮：${JSON.stringify(before)}`);
    if (before?.found) {
      await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: before.x, y: before.y, button: 'left', clickCount: 1 });
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: before.x, y: before.y, button: 'left', clickCount: 1 });
      await sleep(900);
      const menu = await cdp.evalJs(`(() => { const m = [...document.querySelectorAll('.n-dropdown-menu')].find((x) => x.offsetParent !== null); if (!m) return null; const r = m.getBoundingClientRect(); return { items: [...m.querySelectorAll('.n-dropdown-option')].map((o) => o.innerText.replace(/\\s+/g, ' ').trim()), rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width) }, inViewport: r.right <= innerWidth + 1 && r.bottom <= innerHeight + 1 }; })()`);
      console.log(`[UI] 下拉内容：${JSON.stringify(menu)}`);
      await cdp.shot(`${TAG}-1600-admins-owner-more.png`);
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await sleep(300);
      console.log(`[UI] 已按 Esc 收起下拉（**不点封号/注销** —— 破坏性动作只验证可见性）`);
    } else {
      console.log('[!!] 没找到「更多」按钮（is_owner 未生效？）');
    }
  }

  hr('汇总（操作按钮是否完整落在表格可视区内）');  let bad = 0;
  for (const r of results) {
    const outside = r.actionBtns.filter((b) => !b.insideClip);
    const flag = outside.length || r.wrapped || r.clipped.length ? 'FAIL' : 'PASS';
    if (flag === 'FAIL') bad += 1;
    console.log(`${flag}  ${r.width}  ${r.page}  操作列宽=${r.actionTdW}  按钮=${r.actionBtns.map((b) => b.text).join('/') || '-'}  越界=${outside.length}  折行=${r.wrapped ? 'Y' : 'N'}  其他溢出单元格=${r.clipped.length}  横向滚动=${r.hasHScroll ? 'Y' : 'N'}`);
  }
  console.log(`\n共 ${results.length} 条页面×宽度记录，问题 ${bad} 条`);
  fs.writeFileSync(path.join(SHOT_DIR, `probe-${TAG}.json`), JSON.stringify(results, null, 2), 'utf8');
  console.log(`[落盘] ${path.join(SHOT_DIR, `probe-${TAG}.json`)}`);
} catch (e) {
  console.error('运行失败：', e?.message ?? e);
  process.exitCode = 1;
} finally {
  try { browser?.kill(); } catch { /* ignore */ }
  await sleep(300);
  try { fs.rmSync(PROFILE, { recursive: true, force: true }); } catch { /* ignore */ }
}
