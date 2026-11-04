/**
 * 充值管理 →「收款码 → 新增收款码」**真浏览器 + 真实文件注入**端到端核验
 * ---------------------------------------------------------------------------
 * ⚠️ 为什么会有这个脚本（负责人 2026-10-07 反馈「二维码咋加不了」）：
 *    **上一版 `verify-recharge-ui.mjs` 因无法驱动 `n-upload` 的真实文件框，只验了接口**
 *    —— 它自己 fetch 打 `/admin/media/upload` 拿到 mediaId，再用 Vue 事件路径 `$emit` 回填表单，
 *    于是「选文件 → customRequest → 真上传」这条**真实用户路径从未被执行过一次**，
 *    漏验的正是当时坏掉的那一段（控件层一个请求都不发）。
 *    **本脚本用 CDP `DOM.setFileInputFiles` 把真实 PNG 真注入 `input[type=file]`**，
 *    并监听 `Page.fileChooserOpened` / `Input.domFileChooserOpened` + Network 域抓请求/响应原文。
 *
 * 覆盖（每一步都打印取证原文 + 截图）：
 *  ① 新增收款码按钮是否存在/可点 ② 弹层上传控件 disabled?/文案?/中文说明?
 *  ③ 用 CDP 真鼠标事件点上传按钮 → 是否真弹文件框（+ input.click() 打点）
 *  ④ DOM.setFileInputFiles 真注入 → 是否真发 POST /api/v1/admin/media/upload（贴请求/响应原文）
 *  ⑤ 保存收款码 → 列表可见 → GET /admin/recharge/qr-codes + GET /public/recharge/config 的 qrCodes 计数 +1
 *  ⑥ 回归：共用组件在「宣传图管理」页也能真上传（一处修复 → 六个页面一起好）
 *  ⑦ 无未捕获异常 ⑧ 清理（测试收款码 / 测试媒体 / 临时超管）并复核计数
 *
 * 三条踩过的坑（照抄时别删）：
 *  · **点上传按钮必须用 CDP `Input.dispatchMouseEvent` 派发真鼠标事件**：原生文件框需要 user activation，
 *    页面脚本的 `el.click()` 拿不到 → `Page.fileChooserOpened` 永远不出现（这就是"上一版没法驱动文件框"的根因）；
 *  · **响应体要等 `Network.loadingFinished`**：`requestWillBeSent` 一到就读 `Network.getResponseBody`
 *    会报 `No data found for resource with given identifier`；
 *  · **`n-input-number` 带 `:precision` 时只在 blur 提交值**（InputNumber.mjs:482）→ 注入 input+change 后要补 blur。
 *
 * 并行环境铁律（沿用 verify-recharge-ui.mjs）：
 *  · **绝不用真实超管 `kslingyun` 登录**（会顶掉负责人正在用的会话）→ 自建临时超管，跑完即删；
 *  · 会话被顶掉（落到 /login）绝不重新登录，直接中断并如实报告；
 *  · 夹具按 id/username 精确删除，绝不 DELETE 全表。
 *
 * 运行：node scripts/tools/verify-recharge-qr-upload.mjs
 * 前置：pm2 fish-server（3100）+ pm2 fish-admin（Vite dev 5173，**只绑 IPv6** → 用 http://[::1]:5173）
 *
 * ── 2026-10-07 从 `scripts/tmp/` 移入 `scripts/tools/` 并**参数化**（债 3）──
 * 为什么入库：这是"上传控件必须真注入文件"这条铁律的**参考实现**，有长期回归价值；
 * `scripts/tmp/**` 是本机草稿区（多数文件不入库），放在那里等于没有这个工具。
 * 原先写死的路径/账号常量全部可由环境变量覆盖（默认值与移动前**逐字一致**，不改变行为）：
 *   FISH_ROOT                 仓库根（默认从脚本位置推导 = scripts/tools/../..）
 *   RC_API_BASE               后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   RC_UI_BASE                管理端地址（默认 http://[::1]:5173）
 *   RC_EDGE_BIN               Edge 可执行文件（默认 Program Files (x86) 下那份）
 *   RC_CDP_PORT               CDP 调试端口（默认 9261）
 *   RC_SHOT_DIR               截图输出目录（默认 <root>/scripts/tmp，**不入库**）
 *   RC_QR_IMG                 测试收款码 PNG 路径（默认 <root>/data/temp/rc-qr-200x200.png）
 *   RC_TMP_ADMIN_PASSWORD     临时超管口令（默认 QrUpload#2026a；该账号**本次运行内建、跑完即删**）
 *   RC_DB_HOST/PORT/USER/PASSWORD/NAME  DB 连接（默认读 <root>/server/.env 的 DB_*）
 */
import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
/** 仓库根：默认 scripts/tools/../.. */
const ROOT = path.resolve(process.env.FISH_ROOT || path.join(HERE, '..', '..'));
const SERVER_ENV = path.join(ROOT, 'server', '.env');

/** 读 server/.env 的键（DB 连接用；缺失时回退 NULL） */
const envFileCache = (() => {
  try { return fs.readFileSync(SERVER_ENV, 'utf8'); } catch { return ''; }
})();
const envOf = (k) => {
  const m = envFileCache.match(new RegExp('^' + k + '=(.+)$', 'm'));
  return m ? m[1].trim() : null;
};

const mysql = require(path.join(ROOT, 'server', 'node_modules', 'mysql2', 'promise'));
const bcrypt = require(path.join(ROOT, 'server', 'node_modules', 'bcryptjs'));
const sharp = require(path.join(ROOT, 'server', 'node_modules', 'sharp'));

// Vite dev 只监听了 IPv6（`[::1]`）—— 显式用 [::1] 更硬（127.0.0.1:5173 连不上）
const UI = process.env.RC_UI_BASE || 'http://[::1]:5173';
const API = process.env.RC_API_BASE || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.RC_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.RC_CDP_PORT || 9261);
/** 截图落 `scripts/tmp`（本机草稿区、不入库）—— 不要把 PNG 提交进仓库 */
const OUT = process.env.RC_SHOT_DIR || path.join(ROOT, 'scripts', 'tmp');
/** 真实测试收款码图：200×200 PNG（自己生成，放 data/temp/） */
const QR_IMG = process.env.RC_QR_IMG || path.join(ROOT, 'data', 'temp', 'rc-qr-200x200.png');

const TS = String(Date.now()).slice(-6);
const PFX = `qrui_${TS}_`;
const ADMIN_ACC = `${PFX}admin`;
/** 临时超管口令（该账号在本次运行内 INSERT、收尾 DELETE，不是任何真实账号的凭据） */
const PW = process.env.RC_TMP_ADMIN_PASSWORD || 'QrUpload#2026a';

let pass = 0;
let fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass += 1; console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`); }
  else { fail += 1; console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);

// ------------------------------------------------------------------ HTTP

async function apiOnce(method, path, body, token, raw) {
  try {
    const r = await fetch(API + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    });
    const text = await r.text();
    let json = null; try { json = JSON.parse(text); } catch { /* 非 JSON */ }
    return raw ? { status: r.status, text } : { status: r.status, json, data: json?.data, code: json?.code, message: json?.message, text };
  } catch (e) {
    return { status: -1, json: null, data: null, message: String(e?.message ?? e), text: '' };
  }
}

/** 带 429 退避重试（本机有并行任务在跑回归，同 IP 限流会互相影响 —— 不是被测代码缺陷） */
async function api(method, path, body, token, raw, retries = 4) {
  let last = null;
  for (let i = 0; i <= retries; i += 1) {
    last = await apiOnce(method, path, body, token, raw);
    if (last.status !== 429) return last;
    const waitMs = 5000 * (i + 1);
    console.log(`  [限流] ${method} ${path} → 429，${waitMs / 1000}s 后重试（${i + 1}/${retries}）`);
    await sleep(waitMs);
  }
  return last;
}

// ------------------------------------------------------------------ CDP

class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    this.console = []; this.exceptions = [];
    this.requests = new Map();        // requestId → {seq,method,url,headers,hasPostData,postDataLength}
    this.requestOrder = [];           // 有序 `METHOD url` 列表
    this.responses = new Map();       // requestId → {status,mimeType}
    this.loadingFinished = new Set(); // requestId（响应体必须等 loadingFinished 才取得到）
    this.fileChooser = [];            // Page.fileChooserOpened / Input.domFileChooserOpened
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      const p = m.params ?? {};
      switch (m.method) {
        case 'Runtime.consoleAPICalled':
          this.console.push({ type: p.type, text: (p.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ') });
          break;
        case 'Runtime.exceptionThrown':
          this.exceptions.push(flat(JSON.stringify(p.exceptionDetails ?? {})).slice(0, 300));
          break;
        case 'Page.fileChooserOpened':
          this.fileChooser.push({ event: 'Page.fileChooserOpened', mode: p.mode, backendNodeId: p.backendNodeId, frameId: p.frameId });
          break;
        case 'Input.domFileChooserOpened':
          this.fileChooser.push({ event: 'Input.domFileChooserOpened', mode: p.mode, backendNodeId: p.backendNodeId });
          break;
        case 'Network.requestWillBeSent':
          this.requests.set(p.requestId, {
            seq: this.requestOrder.length,
            method: p.request?.method, url: p.request?.url, headers: p.request?.headers,
            hasPostData: p.request?.hasPostData, postDataLength: (p.request?.postData ?? '').length, type: p.type,
          });
          this.requestOrder.push(`${p.request?.method} ${p.request?.url}`);
          break;
        case 'Network.responseReceived':
          this.responses.set(p.requestId, { status: p.response?.status, mimeType: p.response?.mimeType });
          break;
        case 'Network.loadingFinished':
          this.loadingFinished.add(p.requestId);
          break;
        case 'Network.loadingFailed':
          this.responses.set(p.requestId, { status: -1, mimeType: null, errorText: p.errorText });
          this.loadingFinished.add(p.requestId);
          break;
        default: break;
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
  /** 定位「当前可见弹层」里的 file input（任务书要求走 DOM.getDocument + querySelector） */
  async fileInputNode() {
    const { root } = await this.send('DOM.getDocument', { depth: 2, pierce: true });
    const { nodeId } = await this.send('DOM.querySelector', { nodeId: root.nodeId, selector: '.n-modal input[type=file]' });
    if (!nodeId) return { nodeId: 0, backendNodeId: 0 };
    let backendNodeId = 0;
    try { const d = await this.send('DOM.describeNode', { nodeId }); backendNodeId = d?.node?.backendNodeId ?? 0; } catch { /* 忽略 */ }
    return { nodeId, backendNodeId };
  }
  async shot(name) {
    const r = await this.send('Page.captureScreenshot', { format: 'png' });
    const buf = Buffer.from(r.data, 'base64');
    fs.writeFileSync(`${OUT}/${name}`, buf);
    console.log(`[SHOT] ${OUT}/${name} (${buf.length} bytes)`);
    return `${OUT}/${name}`;
  }
  /**
   * 等待某个 URL 片段出现（Network 域）；返回 {requestId,req,res} 或 null。
   *
   * `fromIndex` 必须传：`requests` 是全量累积的，页面加载时的 GET（列表刷新等）也在里面，
   * 不设起点会把"上一轮就存在的请求"误判成"这一次点击发出的请求"（实测踩过）。
   */
  async waitRequest(urlPart, ms = 8000, step = 250, fromIndex = 0, method = null) {
    const until = Date.now() + ms;
    while (Date.now() < until) {
      for (const [rid, req] of this.requests) {
        if (req.seq < fromIndex) continue;
        if (req.url.includes(urlPart) && (!method || req.method === method)) {
          return { requestId: rid, req, res: this.responses.get(rid) ?? null };
        }
      }
      await sleep(step);
    }
    return null;
  }
  /** 等响应真的回来（只看 requestWillBeSent 会取不到状态码与响应体） */
  async waitResponse(requestId, ms = 8000, step = 200) {
    const until = Date.now() + ms;
    while (Date.now() < until) {
      if (this.responses.has(requestId) && this.loadingFinished.has(requestId)) return this.responses.get(requestId);
      await sleep(step);
    }
    return this.responses.get(requestId) ?? null;
  }
  /** 响应体原文（先等 loadingFinished） */
  async body(requestId) {
    await this.waitResponse(requestId);
    try { return (await this.send('Network.getResponseBody', { requestId }))?.body ?? ''; }
    catch (e) { return `(取响应体失败：${String(e?.message ?? e)})`; }
  }
  /** `input[type=file].click()` 打点：把「按钮点击是否真触达 input.click()」与「headless 是否上报文件框事件」分开取证 */
  async installClickSpy() {
    return this.evalJs(`(() => {
      if (window.__inputClickSpy) { window.__inputClickSpy.clicks = 0; return 'reset'; }
      window.__inputClickSpy = { clicks: 0, targets: [] };
      const orig = HTMLInputElement.prototype.click;
      HTMLInputElement.prototype.click = function (...a) {
        window.__inputClickSpy.clicks += 1;
        window.__inputClickSpy.targets.push((this.type || '?') + ':' + (this.accept || '-'));
        return orig.apply(this, a);
      };
      return 'installed';
    })()`);
  }
}

// ------------------------------------------------------------------ 夹具

/** 真实 200×200 PNG（自己画个假二维码；不引新依赖，用 server 已有的 sharp） */
async function makeQrPng() {
  fs.mkdirSync(path.dirname(QR_IMG), { recursive: true });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
    <rect width="200" height="200" fill="#ffffff"/>
    <g fill="#111827">${Array.from({ length: 100 }, (_, i) => {
      const x = i % 10, y = Math.floor(i / 10);
      const bit = ((x * 5 + y * 11 + ((x * y) % 7)) % 3) === 0 ? 1 : 0;
      return bit ? `<rect x="${10 + x * 18}" y="${10 + y * 18}" width="18" height="18"/>` : '';
    }).join('')}</g>
    <rect x="10" y="10" width="54" height="54" fill="#111827"/><rect x="18" y="18" width="38" height="38" fill="#fff"/><rect x="26" y="26" width="22" height="22" fill="#111827"/>
    <rect x="136" y="10" width="54" height="54" fill="#111827"/><rect x="144" y="18" width="38" height="38" fill="#fff"/><rect x="152" y="26" width="22" height="22" fill="#111827"/>
    <rect x="10" y="136" width="54" height="54" fill="#111827"/><rect x="18" y="144" width="38" height="38" fill="#fff"/><rect x="26" y="152" width="22" height="22" fill="#111827"/>
  </svg>`;
  const info = await sharp(Buffer.from(svg)).png().toFile(QR_IMG);
  const st = fs.statSync(QR_IMG);
  return { path: QR_IMG, bytes: st.size, width: info.width, height: info.height };
}

// ------------------------------------------------------------------ 主流程

const PROFILE = os.tmpdir() + '/fish-edge-qrupload-' + Date.now();
let browser = null;
let db = null;
let superToken = null;
let adminUserId = null;
let qrId = null;
let mediaId = null;
let baselineQr = 0;
/** 基线：老板端公开配置里的 qrCodes 条数（finally 里也要用，故放外层） */
let baseLen = -1;

try {
  const img = await makeQrPng();
  console.log(`[夹具] 真实测试收款码图：${img.path} ${img.width}×${img.height} ${img.bytes} bytes`);

  browser = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-first-run',
    `--user-data-dir=${PROFILE}`, '--window-size=1440,980', 'about:blank'], { stdio: 'ignore' });
  await sleep(2600);

  // DB 连接：RC_DB_* 优先，否则读 <root>/server/.env 的 DB_*（与其它回归套件同源）
  db = await mysql.createConnection({
    host: process.env.RC_DB_HOST || envOf('DB_HOST') || '127.0.0.1',
    port: Number(process.env.RC_DB_PORT || envOf('DB_PORT') || 3306),
    user: process.env.RC_DB_USER || envOf('DB_USER') || 'fish_app',
    password: process.env.RC_DB_PASSWORD || envOf('DB_PASSWORD'),
    database: process.env.RC_DB_NAME || envOf('DB_NAME') || 'fish_platform',
  });

  hr('0. 夹具：临时超管（绝不用真实超管 kslingyun 登录）');
  const [roles] = await db.query("SELECT id FROM admin_role WHERE code = 'super_admin'");
  if (!roles[0]) throw new Error('库里没有 super_admin 角色行');
  const [u] = await db.query(
    'INSERT INTO `user` (username, uid, password_hash, nickname, role, status, level) VALUES (?, ?, ?, ?, ?, 1, 1)',
    [ADMIN_ACC, `QR${TS}A`, bcrypt.hashSync(PW, 10), '收款码上传核验（临时超管）', 'admin'],
  );
  adminUserId = String(u.insertId);
  await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?, ?, 1, 0)', [adminUserId, roles[0].id]);
  const al = await api('POST', '/auth/login', { username: ADMIN_ACC, password: PW, role: 'admin' });
  superToken = al.data?.accessToken;
  console.log(`[会话] 临时超管 ${ADMIN_ACC}（userId=${adminUserId}）登录 HTTP ${al.status}`);
  ok('临时超管登录成功（真实超管零登录）', al.status === 200 && !!superToken, `status=${al.status}`);
  if (!superToken) throw new Error('临时超管登录失败，无法继续');

  const [cnt0] = await db.query('SELECT COUNT(*) AS c FROM recharge_qr_code');
  baselineQr = Number(cnt0[0].c);
  const pubBaseline = await api('GET', '/public/recharge/config', undefined, undefined, true);
  let pubBaseJson = null; try { pubBaseJson = JSON.parse(pubBaseline.text); } catch { /* ignore */ }
  baseLen = Array.isArray(pubBaseJson?.data?.qrCodes) ? pubBaseJson.data.qrCodes.length : -1;
  console.log(`[基线] DB recharge_qr_code = ${baselineQr} 条；GET /public/recharge/config → HTTP ${pubBaseline.status}，qrCodes.length = ${baseLen}`);
  console.log(`[基线] 公开配置原文：${pubBaseline.text.slice(0, 420)}`);

  // ---------------------------------------------------------------- CDP
  const httpGet = (url) => new Promise((res, rej) => {
    import('http').then((h) => h.get(url, (r) => { let d = ''; r.on('data', (c) => (d += c)); r.on('end', () => res(d)); }).on('error', rej));
  });
  const targets = JSON.parse(await httpGet(`http://127.0.0.1:${PORT}/json`));
  const page = targets.find((t) => t.type === 'page');
  const cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await sleep(400);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('DOM.enable');
  await cdp.send('Network.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 980, deviceScaleFactor: 1, mobile: false });
  // 拦截原生文件框：才能拿到 Page.fileChooserOpened（headless 下原生框本来也不可见）
  await cdp.send('Page.setInterceptFileChooserDialog', { enabled: true });

  async function goto(path, waitMs = 3200) {
    await cdp.send('Page.navigate', { url: `${UI}${path}` });
    await sleep(waitMs);
    const p = await cdp.evalJs('location.pathname');
    if (p === '/login') throw new Error(`会话失效：${path} 被重定向到 /login（按并行铁律不重新登录，中断）`);
    return p;
  }

  hr('1. 会话就绪（[::1]:5173 → 登录页塞 token → /recharge）');
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(1800);
  await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(superToken)}); 'ok'`);
  const path1 = await goto('/recharge', 3800);
  const meInfo = await cdp.evalJs(`(async () => { const r = await fetch('/api/v1/auth/me', { headers: { Authorization: 'Bearer ' + localStorage.getItem('fish_admin_token') } }); const j = await r.json(); return { status: r.status, roleCode: j?.data?.admin?.roleCode, perms: (j?.data?.admin?.permissions ?? []).length, hasMediaWrite: (j?.data?.admin?.permissions ?? []).includes('admin:media:write') }; })()`);
  console.log(`[会话] /recharge 打开于 ${path1}；/auth/me → HTTP ${meInfo?.status} roleCode=${meInfo?.roleCode} 权限点 ${meInfo?.perms} 个（含 admin:media:write=${meInfo?.hasMediaWrite}）`);
  ok('管理端会话就绪（临时超管，权限点已下发）', path1 === '/recharge' && meInfo?.status === 200, `roleCode=${meInfo?.roleCode} perms=${meInfo?.perms}`);

  hr('2. 「充值管理 → 收款码」按钮与弹层取证');
  const menuTexts = await cdp.evalJs(`[...document.querySelectorAll('.n-menu .n-menu-item-content-header')].map(e => e.innerText.trim())`);
  console.log(`[UI] 侧栏菜单：${JSON.stringify(menuTexts)}`);
  const tabRes = await cdp.evalJs(`(() => { const el = [...document.querySelectorAll('.n-tabs-tab')].find(x => x.innerText.replace(/\\s+/g,'').trim() === '收款码'); if (!el) return 'no-tab'; el.click(); return 'tab-clicked'; })()`);
  console.log(`[UI] 切 tab：${tabRes}`);
  await sleep(1200);

  const addBtn = await cdp.evalJs(`(() => {
    const b = [...document.querySelectorAll('button')].find(x => x.innerText.replace(/\\s+/g,'').trim() === '新增收款码');
    if (!b) return { exists: false };
    const r = b.getBoundingClientRect();
    return { exists: true, disabled: !!b.disabled, cls: b.className, rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) } };
  })()`);
  console.log(`[UI] 「新增收款码」按钮：${JSON.stringify(addBtn)}`);
  ok('①「新增收款码」按钮存在', addBtn?.exists === true, JSON.stringify(addBtn));
  ok('①「新增收款码」按钮可点（未被权限门禁误伤）', addBtn?.exists === true && addBtn?.disabled === false, `disabled=${addBtn?.disabled}`);
  await cdp.shot('qr-verify-01-qr-tab.png');

  console.log(`[UI] 点击「新增收款码」：${await cdp.evalJs(`(() => { const b = [...document.querySelectorAll('button')].find(x => x.innerText.replace(/\\s+/g,'').trim() === '新增收款码'); if (!b) return 'no-btn'; b.click(); return 'clicked'; })()`)}`);
  await sleep(1200);
  const modalText = await cdp.evalJs(`(() => { const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null); return m ? m.innerText.replace(/\\s+/g,' ').trim() : ''; })()`);
  console.log(`[UI] 弹层文案：${modalText.slice(0, 260)}`);
  ok('② 弹层已打开且标题是「新增收款码」', modalText.includes('新增收款码'), modalText.slice(0, 80));

  const upState = await cdp.evalJs(`(() => {
    const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null);
    if (!m) return { modal: false };
    const up = m.querySelector('.n-upload');
    const inp = m.querySelector('input[type=file]');
    const btn = [...m.querySelectorAll('button')].find(x => x.innerText.includes('选择'));
    const deny = m.querySelector('.deny-hint');
    const hint = m.querySelector('.mini-hint');
    return {
      modal: true,
      uploadExists: !!up,
      uploadCls: up ? up.className : null,
      inputExists: !!inp,
      inputDisabled: inp ? !!inp.disabled : null,
      inputAccept: inp ? inp.accept : null,
      btnText: btn ? btn.innerText.replace(/\\s+/g,' ').trim() : null,
      btnDisabled: btn ? !!btn.disabled : null,
      denyHint: deny ? deny.innerText.replace(/\\s+/g,' ').trim() : null,
      miniHint: hint ? hint.innerText.replace(/\\s+/g,' ').trim() : null,
    };
  })()`);
  console.log(`[UI] 上传控件取证：${JSON.stringify(upState)}`);
  ok('② 弹层里有上传控件（n-upload + input[type=file]）', upState?.uploadExists === true && upState?.inputExists === true, JSON.stringify(upState));
  ok('② 超管视角上传控件**未被禁用**（无权限门禁误伤）',
    upState?.inputDisabled === false && upState?.btnDisabled === false && upState?.uploadCls?.includes('n-upload--disabled') !== true,
    `inputDisabled=${upState?.inputDisabled} btnDisabled=${upState?.btnDisabled} cls=${upState?.uploadCls}`);
  ok('② 上传按钮文案可读 + 有中文说明（不是光秃秃一个控件）',
    upState?.btnText === '选择图片上传' && !!upState?.miniHint, `btn="${upState?.btnText}" hint="${upState?.miniHint}"`);
  await cdp.shot('qr-verify-02-modal.png');

  hr('3. 点击上传按钮 → 是否真弹文件框（Page.fileChooserOpened）');
  await cdp.installClickSpy();
  // 必须用 CDP 真鼠标事件：原生文件框需要 user activation，页面里的 el.click() 拿不到（上一版验不了文件框的根因）
  const btnRect = await cdp.evalJs(`(() => {
    const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null);
    const b = [...m.querySelectorAll('button')].find(x => x.innerText.includes('选择图片上传'));
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  console.log(`[UI] 上传按钮中心坐标：${JSON.stringify(btnRect)}`);
  cdp.fileChooser.length = 0;
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: btnRect.x, y: btnRect.y, button: 'none', clickCount: 0 });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: btnRect.x, y: btnRect.y, button: 'left', clickCount: 1 });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: btnRect.x, y: btnRect.y, button: 'left', clickCount: 1 });
  await sleep(1600);
  console.log(`[CDP] 真实鼠标点击后：文件框事件 ${cdp.fileChooser.length} 个 ${JSON.stringify(cdp.fileChooser)}`);
  ok('③ 真实鼠标点击上传按钮 → **弹出文件选择框**（Page.fileChooserOpened / Input.domFileChooserOpened）',
    cdp.fileChooser.length > 0, `事件=${cdp.fileChooser.length} 个`);
  const spyBefore = Number(JSON.parse((await cdp.evalJs('JSON.stringify(window.__inputClickSpy)')) || '{}').clicks ?? 0);
  await cdp.evalJs(`(() => { const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null); const b = [...m.querySelectorAll('button')].find(x => x.innerText.includes('选择图片上传')); if (b) b.click(); return 'clicked'; })()`);
  await sleep(500);
  const spyAfter = Number(JSON.parse((await cdp.evalJs('JSON.stringify(window.__inputClickSpy)')) || '{}').clicks ?? 0);
  console.log(`[CDP] 按钮点击触达 input[type=file].click() 打点：${spyBefore} → ${spyAfter}`);
  ok('③ 按钮点击**触达 n-upload 的真实 input[type=file].click()**（控件本身没坏）', spyAfter > spyBefore, `${spyBefore} → ${spyAfter}`);

  hr('4. 真实注入文件：DOM.setFileInputFiles → 是否真发 POST /api/v1/admin/media/upload');
  const node = await cdp.fileInputNode();
  console.log(`[CDP] DOM.getDocument + querySelector('.n-modal input[type=file]') → nodeId=${node.nodeId} backendNodeId=${node.backendNodeId}`);
  ok('④ 通过 DOM.getDocument/querySelector 定位到真实 file input 节点', node.nodeId > 0, JSON.stringify(node));
  const mark1 = cdp.requestOrder.length;
  await cdp.send('DOM.setFileInputFiles', { files: [QR_IMG], nodeId: node.nodeId });
  console.log(`[CDP] DOM.setFileInputFiles(files=[${QR_IMG}], nodeId=${node.nodeId}) 已执行（真实 PNG 200×200 注入 input[type=file]）`);
  const upHit = await cdp.waitRequest('/admin/media/upload', 9000, 250, mark1, 'POST');
  const sentAfterInject = cdp.requestOrder.filter((x) => x.includes('/admin/media/upload')).length;
  console.log(`[NET] 注入后新增请求：${JSON.stringify(cdp.requestOrder.slice(mark1))}`);
  console.log(`[NET] /admin/media/upload 命中条数 = ${sentAfterInject}`);
  ok('④ 真实注入文件后**浏览器真的发出了** POST /api/v1/admin/media/upload（上一版脚本漏验的就是这一步）',
    sentAfterInject > 0 && !!upHit, `命中=${sentAfterInject}`);

  if (upHit) {
    const req = upHit.req;
    const upRes = await cdp.waitResponse(upHit.requestId);
    const bodyText = await cdp.body(upHit.requestId);
    console.log('  ---- 上传请求原文 ----');
    console.log(`  ${req.method} ${req.url}`);
    console.log(`  Content-Type: ${req.headers?.['Content-Type'] ?? req.headers?.['content-type'] ?? '(none)'}`);
    console.log(`  Authorization: ${String(req.headers?.Authorization ?? req.headers?.authorization ?? '').slice(0, 28)}…（临时超管令牌）`);
    console.log(`  hasPostData=${req.hasPostData} multipart 体长度=${req.postDataLength}`);
    console.log('  ---- 上传响应原文 ----');
    console.log(`  HTTP ${upRes?.status} ${upRes?.mimeType ?? ''}`);
    console.log(`  ${bodyText}`);
    let j = null; try { j = JSON.parse(bodyText); } catch { /* ignore */ }
    mediaId = j?.data?.id ? String(j.data.id) : null;
    ok('④ 上传被服务端接受（HTTP 2xx 且响应带 media id，用途 = recharge_qr）',
      upRes?.status >= 200 && upRes?.status < 300 && !!mediaId, `status=${upRes?.status} mediaId=${mediaId} msg=${j?.message ?? ''}`);
  } else {
    console.log('  [兜底] 未命中上传请求 → 关闭文件框拦截，重新点击上传按钮 + setFileInputFiles 重试一次');
    await cdp.send('Page.setInterceptFileChooserDialog', { enabled: false });
    await cdp.evalJs(`(() => { const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null); const b = [...m.querySelectorAll('button')].find(x => x.innerText.includes('选择图片上传')); if (b) b.click(); return 'clicked'; })()`);
    await sleep(600);
    const n2 = await cdp.fileInputNode();
    const mark2 = cdp.requestOrder.length;
    await cdp.send('DOM.setFileInputFiles', { files: [QR_IMG], nodeId: n2.nodeId });
    const retry = await cdp.waitRequest('/admin/media/upload', 7000, 250, mark2, 'POST');
    console.log(`  [兜底] 重试命中：${!!retry}`);
    ok('④（兜底路径）真实注入文件后发出上传请求', !!retry, `nodeId=${n2.nodeId}`);
  }

  await sleep(1500);
  const afterUp = await cdp.evalJs(`(() => {
    const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null);
    if (!m) return { modal: false };
    return {
      modal: true,
      mediaIdShown: (m.querySelector('.media-id') || {}).innerText || null,
      hasImg: !!m.querySelector('img'),
      text: m.innerText.replace(/\\s+/g,' ').trim().slice(0, 220),
    };
  })()`);
  console.log(`[UI] 上传后弹层状态：${JSON.stringify(afterUp)}`);
  await cdp.shot('qr-verify-03-after-inject.png');
  ok('④ 上传成功后表单已回填 media id（页面显示 #id）且出现预览图',
    !!afterUp?.mediaIdShown && afterUp?.hasImg === true, JSON.stringify(afterUp));
  if (mediaId) {
    ok('④ 页面回填的 media id 与上传响应的 id 一致', flat(afterUp?.mediaIdShown) === `#${mediaId}`, `页面=${afterUp?.mediaIdShown} 响应=#${mediaId}`);
  }

  hr('5. 保存收款码 → 列表可见 → 公开配置 qrCodes 计数 +1');
  const qrLabel = `核验收款码${TS}`;
  const setRes = await cdp.evalJs(`(() => {
    const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null);
    const set = (el, v) => {
      if (!el) return 'no-input';
      const s = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      el.focus();
      s.call(el, v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      // ⚠️ n-input-number 带 :precision 时**只在 blur 才提交值**（InputNumber.mjs:482）→ 不 blur 等于没改
      el.dispatchEvent(new Event('blur', { bubbles: true }));
      el.blur();
      return el.value;
    };
    const items = [...m.querySelectorAll('.n-form-item')];
    const byLabel = (t) => items.find(i => ((i.querySelector('.n-form-item-label') || {}).innerText || '').trim() === t);
    const labelItem = byLabel('标签');
    if (!labelItem) return 'no-label-item';
    const r1 = set(labelItem.querySelector('input'), ${JSON.stringify(qrLabel)});
    const sortItem = byLabel('排序');
    const r2 = sortItem ? set(sortItem.querySelector('input'), '7') : 'no-sort-item';
    return 'label=' + r1 + ' sort=' + r2;
  })()`);
  console.log(`[UI] 填标签/排序：${setRes}`);
  await sleep(500);
  const mark3 = cdp.requestOrder.length;
  console.log(`[UI] 点击「保存」：${await cdp.evalJs(`(() => { const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null); const b = [...m.querySelectorAll('button')].find(x => x.innerText.replace(/\\s+/g,'').trim() === '保存'); if (!b) return 'no-btn'; b.click(); return 'clicked'; })()`)}`);
  await sleep(2300);
  const saveHit = await cdp.waitRequest('/admin/recharge/qr-codes', 6000, 250, mark3, 'POST');
  console.log(`[NET] 保存期间新增请求：${JSON.stringify(cdp.requestOrder.slice(mark3))}`);
  if (saveHit) {
    const req = saveHit.req;
    const saveRes = await cdp.waitResponse(saveHit.requestId);
    const bodyText = await cdp.body(saveHit.requestId);
    console.log('  ---- 保存请求原文 ----');
    console.log(`  ${req.method} ${req.url} → HTTP ${saveRes?.status}`);
    console.log(`  body: ${bodyText}`);
    ok('⑤ 保存走真实接口 POST /admin/recharge/qr-codes',
      req.method === 'POST' && saveRes?.status >= 200 && saveRes?.status < 300, `${req.method} ${req.url} → ${saveRes?.status}`);
  } else {
    ok('⑤ 保存走真实接口 POST /admin/recharge/qr-codes', false, '未捕获到保存请求');
  }

  const [qrRows] = await db.query('SELECT id, media_id, channel, label, sort, enabled FROM recharge_qr_code WHERE label = ?', [qrLabel]);
  qrId = qrRows[0]?.id ? String(qrRows[0].id) : null;
  console.log(`[DB] recharge_qr_code：${JSON.stringify(qrRows[0] ?? null)}`);
  ok('⑤ 收款码已落库（渠道=wechat / 排序=7 / 启用 / 图 = 刚上传的 mediaId）',
    !!qrRows[0] && qrRows[0].channel === 'wechat' && Number(qrRows[0].sort) === 7 && Number(qrRows[0].enabled) === 1
    && (!mediaId || String(qrRows[0].media_id) === mediaId), JSON.stringify(qrRows[0] ?? null));

  const listApi = await api('GET', '/admin/recharge/qr-codes', undefined, superToken);
  console.log(`[接口] GET /admin/recharge/qr-codes → HTTP ${listApi.status}，含本码=${JSON.stringify(listApi.data ?? listApi.json).includes(qrLabel)}`);
  ok('⑤ GET /admin/recharge/qr-codes 里有这条', listApi.status === 200 && JSON.stringify(listApi.data ?? listApi.json).includes(qrLabel), `status=${listApi.status}`);

  const rowText = await cdp.evalJs(`(() => { const tr = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')].find(x => x.innerText.includes(${JSON.stringify(qrLabel)})); return tr ? tr.innerText.replace(/\\s+/g,' ').trim() : 'no-row'; })()`);
  console.log(`[UI] 列表行：${rowText}`);
  ok('⑤ 列表里能看到这张码（状态=启用中）', rowText.includes('启用中'), rowText);
  await cdp.shot('qr-verify-04-saved.png');

  await sleep(600);
  const pubAfter = await api('GET', '/public/recharge/config', undefined, undefined, true);
  let pubJson = null; try { pubJson = JSON.parse(pubAfter.text); } catch { /* ignore */ }
  const afterLen = Array.isArray(pubJson?.data?.qrCodes) ? pubJson.data.qrCodes.length : -1;
  console.log(`[接口] GET /public/recharge/config → HTTP ${pubAfter.status}，qrCodes.length = ${afterLen}（基线 ${baseLen}）`);
  console.log(`[接口] 公开配置原文（节选）：${pubAfter.text.slice(0, 520)}`);
  ok(`⑤ 老板端公开配置 /public/recharge/config 的 qrCodes ${baseLen} → ${baseLen + 1}（+1）`,
    pubAfter.status === 200 && afterLen === baseLen + 1, `${baseLen} → ${afterLen}`);
  ok('⑤ 公开配置里这条码是老板端可直接 <img src> 的公开地址（mediaId 命中）',
    !!mediaId && pubAfter.text.includes(mediaId), `mediaId=${mediaId}`);

  hr('6. 回归：同一个 MediaUploadField 还供着另外 5 个页面 —— 抽一个页面复验上传仍可用');
  const pathB = await goto('/banners', 3400);
  await cdp.evalJs(`(() => { const b = [...document.querySelectorAll('button')].find(x => x.innerText.replace(/\\s+/g,'').trim() === '新建宣传图'); if (b) b.click(); return b ? 'clicked' : 'no-btn'; })()`);
  await sleep(1200);
  const bRect = await cdp.evalJs(`(() => {
    const m = [...document.querySelectorAll('.n-modal')].find(x => x.offsetParent !== null);
    if (!m) return null;
    const b = [...m.querySelectorAll('button')].find(x => x.innerText.includes('选择图片上传'));
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
  })()`);
  const markB = cdp.requestOrder.length;
  if (bRect) {
    await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: bRect.x, y: bRect.y, button: 'left', clickCount: 1 });
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: bRect.x, y: bRect.y, button: 'left', clickCount: 1 });
    await sleep(700);
    const bNode = await cdp.fileInputNode();
    await cdp.send('DOM.setFileInputFiles', { files: [QR_IMG], nodeId: bNode.nodeId });
  }
  const bHit = await cdp.waitRequest('/admin/media/upload', 8000, 250, markB, 'POST');
  if (bHit) {
    const bRes = await cdp.waitResponse(bHit.requestId);
    console.log(`  [回归] ${pathB} 新建宣传图 → 注入文件 → ${bHit.req.method} ${bHit.req.url} → HTTP ${bRes?.status}`);
    console.log(`  [回归] 响应体：${await cdp.body(bHit.requestId)}`);
  } else {
    console.log(`  [回归] ${pathB} 未捕获到上传请求（bRect=${JSON.stringify(bRect)}）`);
  }
  ok('⑥ 回归：共用组件在「宣传图管理」页也能真上传（修一处 → 六个页面一起好，且未修坏别的页面）',
    !!bHit, `bRect=${JSON.stringify(bRect)} hit=${!!bHit}`);
  await cdp.shot('qr-verify-05-banner-regression.png');

  hr('7. 页面异常/控制台');
  const errs = cdp.exceptions.slice();
  const consoleErr = cdp.console.filter((c) => c.type === 'error').map((c) => c.text).slice(0, 6);
  console.log(`[页面] 未捕获异常 ${errs.length} 条；console.error ${consoleErr.length} 条`);
  if (errs.length) console.log(`[页面] 异常：${JSON.stringify(errs)}`);
  if (consoleErr.length) console.log(`[页面] console.error：${JSON.stringify(consoleErr)}`);
  ok('⑦ 全程无未捕获异常', errs.length === 0, `${errs.length} 条`);
} catch (e) {
  fail += 1;
  console.log(`\n[中断] ${String(e?.stack ?? e)}`);
} finally {
  // ---------------------------------------------------------------- 清理
  hr('8. 收尾清理（测试收款码 / 测试媒体 / 临时超管）');
  try {
    if (db) {
      if (qrId) {
        const [r] = await db.query('DELETE FROM recharge_qr_code WHERE id = ?', [qrId]);
        console.log(`[清理] recharge_qr_code id=${qrId} → affectedRows=${r.affectedRows}`);
      }
      if (adminUserId) {
        // 上传产生的媒体行：按 uploader = 临时超管精确删（含回归步骤在宣传图页传的那张）
        const [m] = await db.query('DELETE FROM media WHERE uploader_id = ?', [adminUserId]);
        console.log(`[清理] media(uploader=${adminUserId}) → affectedRows=${m.affectedRows}`);
        const [t] = await db.query('DELETE FROM auth_token WHERE user_id = ?', [adminUserId]);
        const [a] = await db.query('DELETE FROM admin WHERE user_id = ?', [adminUserId]);
        console.log(`[清理] auth_token=${t.affectedRows} admin=${a.affectedRows}`);
      }
      const [ll] = await db.query('DELETE FROM login_log WHERE username = ?', [ADMIN_ACC]);
      console.log(`[清理] login_log(${ADMIN_ACC})=${ll.affectedRows}`);
      if (adminUserId) {
        const [uu] = await db.query('DELETE FROM `user` WHERE id = ?', [adminUserId]);
        console.log(`[清理] user id=${adminUserId} → affectedRows=${uu.affectedRows}`);
      }
      const [c1] = await db.query('SELECT COUNT(*) AS c FROM recharge_qr_code');
      const [c2] = await db.query('SELECT COUNT(*) AS c FROM `user` WHERE username = ?', [ADMIN_ACC]);
      const [c3] = await db.query('SELECT COUNT(*) AS c FROM admin WHERE user_id = ?', [String(adminUserId ?? '')]);
      const [c4] = await db.query('SELECT COUNT(*) AS c FROM media WHERE uploader_id = ?', [String(adminUserId ?? '')]);
      console.log(`[清理] 复核：recharge_qr_code=${c1[0].c}（基线 ${baselineQr}）· 临时账号 user=${c2[0].c} admin=${c3[0].c} · 其 media=${c4[0].c}`);
      ok('⑧ 清理后 recharge_qr_code 回到基线', Number(c1[0].c) === baselineQr, `${c1[0].c} vs 基线 ${baselineQr}`);
      ok('⑧ 清理后临时管理员 0 残留（user/admin/media 三表）',
        Number(c2[0].c) === 0 && Number(c3[0].c) === 0 && Number(c4[0].c) === 0,
        `user=${c2[0].c} admin=${c3[0].c} media=${c4[0].c}`);

      /**
       * ⚠️ `/public/recharge/config` 有**进程内 30s 微缓存**（`PublicCacheInterceptor`；只有走服务层的写路径
       * 才会 `invalidatePublicConfigCache()` 立刻失效）。本脚本的清理是**直接删库**（没走服务层）→ 缓存不会失效，
       * 必须等它自然过期，才能断言"老板端也看不到了"。这不是缺陷，是直连改库的已知代价。
       */
      const lenOf = (t) => { try { const p = JSON.parse(t); return Array.isArray(p?.data?.qrCodes) ? p.data.qrCodes.length : -1; } catch { return -1; } };
      let endLen = lenOf((await api('GET', '/public/recharge/config', undefined, undefined, true)).text);
      let waited = 0;
      while (endLen !== baseLen && waited < 45000) {
        await sleep(5000); waited += 5000;
        endLen = lenOf((await api('GET', '/public/recharge/config', undefined, undefined, true)).text);
        console.log(`  [清理] 公开配置仍是 ${endLen} 条（进程内 30s 微缓存未过期）… 已等 ${waited / 1000}s`);
      }
      console.log(`[清理] GET /public/recharge/config qrCodes.length = ${endLen}（= 基线 ${baseLen}）`);
      ok('⑧ 清理后老板端公开配置回到基线（负责人原有状态零改动）', endLen === baseLen, `${endLen} vs ${baseLen}`);
    }
  } catch (e) {
    console.log(`[清理] 失败：${String(e?.message ?? e)}`);
    fail += 1;
  }
  try { await db?.end(); } catch { /* ignore */ }
  try { browser?.kill(); } catch { /* ignore */ }

  console.log(`\n================ 汇总：PASS ${pass} / FAIL ${fail} ================`);
  process.exit(fail === 0 ? 0 : 1);
}
