/**
 * 管理端「提现审核」**真数据真浏览器**核验（无头 Edge + CDP 真跑真截图）
 * ============================================================================
 * 与 `verify-admin-withdraw.mjs` 的分工（**互补，不是替代**）
 * ----------------------------------------------------------------------------
 *   · `verify-admin-withdraw.mjs`：默认**打桩**模式 —— 断渲染/交互/权限/文案那四件事，
 *     数据是网络层 mock 出来的（确定性），**证明不了"真库里的申请能不能被管理端看到"**；
 *   · 本脚本：`VWD_LIVE` 的补位 —— **不打桩、不 mock**，全程打真后端，断的就是那句
 *     "服务端 e2e 绿了但库里 0 行、页面从没在真数据上验过"的缺口：
 *       ① 真实链路留下的那笔申请（`withdraw-real-apply.js` → `real-apply.json`，当前 id=45）
 *          在**列表里真的出现**（昵称 + 工号 + `¥10.00` + 状态标签 + 标签色 = 对应 token）
 *          ＋ **收款信息列给完整值**（姓名 · 电话 · 微信号；`139****5528` 这类打码串**不许**再出现
 *          —— 负责人 2026-10-11 口径：能看列表 = 有 `withdraw:review` = 审核人本人）；
 *       ② 点开详情 → **收款码大图真的加载出来**（`naturalWidth > 0`、`src` 是带令牌取的 `blob:`，
 *          不是裂图、不是直连 URL）+ 完整姓名/电话/微信号；
 *       ③ 状态守卫：**只有 pending 才有**打款/驳回入口；非 pending 一律只读（脚本**绝不去点**它们），
 *          这笔单子留给负责人亲手操作；
 *       ④ 全程**只读**：只点「处理」打开详情，不点「已提现」/「驳回」，不发任何写请求。
 *
 * ## 铁律
 *   · **绝不用 `kslingyun`** → 走 `scripts/tools/regression-admin.js` 的专用测试超管（`opsadmin`）；
 *     用它会顶掉它自己在别处的会话（正常，单设备铁律）；
 *   · **只点「处理」**（打开详情），**绝不点「已提现」/「驳回」**，不改任何数据；
 *   · 落到 `/login`（被并行批次顶号）**不静默重登**超过一次，再顶就如实中断；
 *   · 截图落 `docs/验收素材/2026-10-11-提现/`（**不入 git**）。
 *
 * 运行：node scripts/tools/verify-admin-withdraw-real-row.mjs
 * 前置：① pm2 fish-server（3100，托管 admin-web dist，SPA 路由 `/withdraw` 可直接打开）
 *       ② 先跑 `node scripts/tools/withdraw-real-apply.js` 产出 real-apply.json
 * 可选环境变量：VWR_UI / VWR_API / VWR_ARTIFACT / VWR_EDGE_BIN / VWR_CDP_PORT / VWR_WIDTH / VWR_HEIGHT
 */
import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const requireCjs = createRequire(import.meta.url);
const { adminUser: REG_ADMIN_USER, adminPassword: REG_ADMIN_PASS } = requireCjs('./regression-admin.js');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(process.env.FISH_ROOT || path.join(HERE, '..', '..'));
const UI = process.env.VWR_UI || 'http://127.0.0.1:3100';
const API = process.env.VWR_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VWR_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VWR_CDP_PORT || 9291);
const WIDTH = Number(process.env.VWR_WIDTH || 1600);
const HEIGHT = Number(process.env.VWR_HEIGHT || 1000);
const SHOT_DIR = path.join(ROOT, 'docs', '验收素材', '2026-10-11-提现');
const ARTIFACT = process.env.VWR_ARTIFACT || path.join(SHOT_DIR, 'real-apply.json');
const USER = process.env.VWR_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VWR_ADMIN_PASS || REG_ADMIN_PASS;

if (!PASS) { console.error('缺少管理端口令（VWR_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
if (!fs.existsSync(ARTIFACT)) { console.error(`读不到真实链路产物：${ARTIFACT}（先跑 node scripts/tools/withdraw-real-apply.js）`); process.exit(2); }
const ART = JSON.parse(fs.readFileSync(ARTIFACT, 'utf8'));
fs.mkdirSync(SHOT_DIR, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);
const NICK = ART.worker.nickname;
const NO = ART.worker.workerNo;
const AMOUNT_LABEL = ART.amountLabel || `¥${Number(ART.amount).toFixed(2)}`;

let failCount = 0;
const results = [];
function record(name, fails, extra = {}) {
  const ok = fails.length === 0;
  if (!ok) failCount += 1;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  for (const [k, v] of Object.entries(extra)) console.log(`     ${k}：${v}`);
  for (const f of fails) console.log(`     ✗ ${f}`);
  results.push({ name, ok, fails, ...extra });
}

/* ================================================================== CDP */
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.exceptions = [];
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.method === 'Runtime.exceptionThrown') {
        this.exceptions.push(flat(JSON.stringify(m.params?.exceptionDetails ?? {})).slice(0, 300));
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

/* ================================================================== 页面内探针 */
/** 表格快照：逐行单元格 / 按钮 / 状态标签（含计算色）+ 设计 token + 正文 */
const LIST_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const tok = (name) => {
    const d = document.createElement('div');
    d.style.color = 'var(' + name + ')';
    document.body.appendChild(d);
    const c = getComputedStyle(d).color;
    d.remove();
    return c;
  };
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  return {
    path: location.pathname,
    h1: txt(document.querySelector('.withdraw-page h1, h1')),
    headers: [...document.querySelectorAll('.n-data-table-thead .n-data-table-th')].map((th) => txt(th)),
    tokens: { warning: tok('--color-warning'), success: tok('--color-success'), error: tok('--color-error') },
    pendingChip: txt(document.querySelector('.pending-chip')),
    rows: trs.map((tr, idx) => {
      const tds = [...tr.querySelectorAll('.n-data-table-td')];
      return {
        idx,
        cells: tds.map((td) => txt(td)),
        buttons: [...tr.querySelectorAll('button')].map((b) => txt(b)),
        tags: [...tr.querySelectorAll('.n-tag')].map((t) => ({ text: txt(t), color: getComputedStyle(t).color })),
      };
    }),
    bodyText: (document.body.innerText || '').replace(/\\s+/g, ' '),
  };
})()`;

/** 抽屉快照：各块文字 + 所有 <img> 的真实加载状态（断"收款码大图真的出来了"） */
const DRAWER_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const drawer = document.querySelector('.n-drawer');
  if (!drawer) return { open: false };
  return {
    open: true,
    head: txt(drawer.querySelector('.n-drawer-header')),
    body: txt(drawer),
    amount: txt(drawer.querySelector('.amount-line')),
    kvKeys: [...drawer.querySelectorAll('.kv dt')].map((dt) => txt(dt)),
    qrBoxImgs: [...drawer.querySelectorAll('.qr-box img')].map((i) => ({
      src: i.getAttribute('src'), nw: i.naturalWidth, nh: i.naturalHeight,
      visible: i.getClientRects().length > 0, done: i.complete === true,
    })),
    allImgs: [...drawer.querySelectorAll('img')].map((i) => ({ src: i.getAttribute('src'), nw: i.naturalWidth })),
    buttons: [...drawer.querySelectorAll('button')].map((b) => ({
      text: txt(b), disabled: b.disabled === true || b.classList.contains('n-button--disabled'),
    })),
  };
})()`;

/** 点某一行里的按钮（按可见文字） */
const clickRowButton = (idx, label) => `(() => {
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  const tr = trs[${idx}];
  if (!tr) return 'NO_ROW';
  const b = [...tr.querySelectorAll('button')].find((x) => (x.innerText || '').replace(/\\s+/g, '') === ${JSON.stringify(label)});
  if (!b) return 'NO_BUTTON';
  if (b.disabled) return 'DISABLED';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

async function waitFor(cdp, expr, { timeout = 15000, step = 250 } = {}) {
  const t0 = Date.now();
  for (;;) {
    let ok = false;
    try { ok = await cdp.evalJs(`(() => { try { return !!(${expr}); } catch { return false; } })()`); } catch { ok = false; }
    if (ok) return true;
    if (Date.now() - t0 > timeout) return false;
    await sleep(step);
  }
}

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

/**
 * 读这笔申请的**详情**（只读 GET）→ 拿"当前真实状态 + 完整/脱敏收款信息"的**权威值**。
 * 为什么不直接用 `real-apply.json`：那是**申请时刻**的快照（状态/值都可能已经变了，
 * 而且文件里中文按当时控制台编码落盘过），拿它当期望值会假红/假绿。
 */
async function apiDetail(token, id) {
  const r = await fetch(`${API}/admin/withdraw/requests/${id}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15000),
  });
  const j = await r.json().catch(() => null);
  return { status: r.status, data: j?.data ?? null };
}

/** 状态 → 列表标签文字 / 标签色 token（三态；服务端只会有这三种） */
const STATUS_LABEL = { pending: '待处理', paid: '已打款', rejected: '已驳回' };
const STATUS_TOKEN = { pending: 'warning', paid: 'success', rejected: 'error' };

/* ================================================================== 主流程 */
const PROFILE = path.join(os.tmpdir(), 'fish-edge-withdraw-real-' + Date.now());
let cdp = null;
let browser = null;

async function main() {
  console.log(`[配置] UI=${UI} API=${API} 窗口=${WIDTH}x${HEIGHT}`);
  console.log(`[真数据] 申请 id=${ART.requestId} 打手=${NICK}（${NO}） 金额=${AMOUNT_LABEL} 状态=${ART.status}`);
  console.log(`[截图] ${SHOT_DIR}`);

  const who = await apiLogin();
  console.log(`[账号] ${USER}（专用测试超管；登录会顶掉它自己在别处的会话，属正常）`);
  if (!who.token) throw new Error(`测试超管 ${USER} 登录失败（HTTP ${who.status}）：${who.raw}`);

  /* 权威值：申请详情（只读 GET）—— 状态与完整/脱敏收款信息都以它为准 */
  const det = await apiDetail(who.token, ART.requestId);
  if (det.status !== 200 || !det.data) throw new Error(`读不到申请 ${ART.requestId} 的详情（HTTP ${det.status}）`);
  const D = det.data;
  const FULL = D.account ?? {};
  const MASK = D.accountMasked ?? {};
  const STATUS = String(D.status ?? '');
  const WANT_LABEL = STATUS_LABEL[STATUS] ?? STATUS;
  const WANT_TOKEN = STATUS_TOKEN[STATUS] ?? 'warning';
  console.log(`[申请 ${D.id}] 打手=${D.workerNickname}（${D.workerNo}） 金额=¥${Number(D.amount).toFixed(2)} 状态=${STATUS}=${WANT_LABEL}`);
  console.log(`[收款信息] 完整=${JSON.stringify(FULL)} 脱敏=${JSON.stringify(MASK)}（列表口径 = **完整**）`);

  browser = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-first-run',
    `--user-data-dir=${PROFILE}`, `--window-size=${WIDTH},${HEIGHT}`, 'about:blank'], { stdio: 'ignore' });
  await sleep(2600);

  const httpGet = (url) => new Promise((res, rej) => {
    import('http').then((h) => h.get(url, (r) => { let d = ''; r.on('data', (c) => (d += c)); r.on('end', () => res(d)); }).on('error', rej));
  });
  const targets = JSON.parse(await httpGet(`http://127.0.0.1:${PORT}/json`));
  const page = targets.find((t) => t.type === 'page');
  if (!page) throw new Error('找不到 CDP 页面目标（Edge 没起来？）');
  cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await sleep(400);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('DOM.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false });

  /* ---------------------------------------------------------- 打开「资金与抽成 → 提现审核」 */
  hr('打开管理端提现审核页（真后端，无打桩）');
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2000);
  await cdp.evalJs(`localStorage.clear(); sessionStorage.clear();
    localStorage.setItem('fish_admin_token', ${JSON.stringify(who.token)});
    sessionStorage.setItem('fish_admin_nav_expanded', JSON.stringify(['资金与抽成'])); 'ok'`);

  const gotoWithdraw = async (wait = 3200) => {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      await cdp.send('Page.navigate', { url: `${UI}/withdraw` });
      await sleep(wait);
      if ((await cdp.evalJs('location.pathname')) !== '/login') return;
      if (attempt === 1) throw new Error('落到 /login（会话被并行批次顶掉两次），后续断言已无意义，中断');
      console.log('     [会话] 落到 /login（疑似被并行批次顶号）→ 重新登录一次');
      const again = await apiLogin();
      if (!again.token) throw new Error(`重新登录失败（HTTP ${again.status}：${again.raw}）`);
      await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(again.token)}); 'ok'`);
    }
  };
  await gotoWithdraw();

  /* ---------------------------------------------------- ① 列表里真的出现这一笔（等真数据渲染） */
  hr('① 列表里出现这一笔真实申请（昵称 / 工号 / ¥10.00 / 状态标签 / **完整收款信息**）');
  const nickJson = JSON.stringify(NICK);
  const appeared = await waitFor(cdp, `(document.body.innerText || '').includes(${nickJson})`, { timeout: 15000 });
  const probe = await cdp.evalJs(LIST_PROBE);
  const row = probe.rows.find((r) => (r.cells[0] || '').includes(NICK)) ?? null;
  const f1 = [];
  if (!appeared || !row) {
    f1.push(`列表里找不到打手「${NICK}」的行（页面 path=${probe.path}，行数=${probe.rows.length}，空态=${probe.bodyText.includes('还没有提现申请')}）`);
  } else {
    if (!String(row.cells[0]).includes(NO)) f1.push(`第一格「打手」= 「${row.cells[0]}」，缺工号 ${NO}`);
    if (String(row.cells[1]).trim() !== AMOUNT_LABEL) f1.push(`金额格 = 「${row.cells[1]}」，期望逐字「${AMOUNT_LABEL}」（¥ + 两位小数）`);
    const tag = row.tags[0];
    if (!tag) f1.push('这一行没有状态标签');
    else {
      if (tag.text !== WANT_LABEL) f1.push(`状态标签 = 「${tag.text}」，期望「${WANT_LABEL}」（申请当前真实状态 ${STATUS}）`);
      const wantColor = probe.tokens[WANT_TOKEN];
      if (tag.color !== wantColor) f1.push(`状态标签色 = ${tag.color}，期望 ${WANT_TOKEN} token ${wantColor}`);
    }
    /*
     * 收款信息列 = **完整值**（负责人 2026-10-11：能看列表 = 有 withdraw:review = 审核人本人）
     * → 完整手机号必须在列里；打码串一个字都不许出现。
     */
    const payeeCell = String(row.cells[2] ?? '');
    for (const want of [FULL.realName, FULL.phone, FULL.wechatId].filter((x) => x)) {
      if (!payeeCell.includes(want)) f1.push(`收款信息列 = 「${payeeCell}」，缺完整值「${want}」`);
    }
    if (!/1[3-9]\d{9}/.test(payeeCell)) f1.push(`收款信息列 = 「${payeeCell}」，没有完整 11 位手机号`);
    if (MASK.phone && payeeCell.includes(MASK.phone)) f1.push(`收款信息列 = 「${payeeCell}」，还在显示打码手机号 ${MASK.phone}`);
    if (/\d{3}\*{2,}\d{4}/.test(flat(probe.bodyText))) {
      f1.push(`列表页正文里出现了打码串（${(flat(probe.bodyText).match(/\d{3}\*{2,}\d{4}/) || [])[0]}）→ 列表口径应为完整值`);
    }
    // 状态守卫：只有 pending 才有「处理」；非 pending 一律只读、一个按钮都没有
    if (STATUS === 'pending') {
      if (!row.buttons.includes('处理')) f1.push(`这一行没有「处理」按钮（实际：${JSON.stringify(row.buttons)}）`);
    } else if (row.buttons.length) {
      f1.push(`状态=${STATUS} 的行不应有按钮（实际：${JSON.stringify(row.buttons)}）`);
    }
  }
  const chipText = flat(probe.pendingChip);
  if (!/^待处理\s*(\d+|—)\s*笔$/.test(chipText)) {
    f1.push(`页头待处理数量 = 「${probe.pendingChip}」，期望形如「待处理 N 笔」`);
  } else if (STATUS === 'pending' && Number(chipText.replace(/\D/g, '')) < 1) {
    f1.push('页头「待处理 0 笔」——真实申请没被算进待处理数');
  }
  const shotList = await cdp.shot('10-真实链路-管理端看到真实申请.png', { beyond: true });
  record(`① 列表出现真实行（昵称+工号+${AMOUNT_LABEL}+${WANT_LABEL}标签+token 色+**完整收款信息**）`, f1, {
    页头: probe.h1, 表头: (probe.headers || []).join('|'), 待处理: probe.pendingChip, 行数: probe.rows.length,
    命中行: row ? row.cells.join(' | ') : '（未命中）',
    该行按钮: row ? JSON.stringify(row.buttons) : '—',
    截图: shotList,
  });

  /* ---------------------------------------------------- ② 详情抽屉：收款码大图真的加载出来 */
  hr('② 点开详情 → 收款码大图真的加载（blob 取图，不是裂图）');
  const f2 = [];
  const openRes = row ? await cdp.evalJs(clickRowButton(row.idx, '处理')) : 'NO_ROW';
  if (openRes !== 'OK') f2.push(`点「处理」失败：${openRes}`);
  await waitFor(cdp, `document.querySelector('.n-drawer .amount-line')`, { timeout: 10000 });
  // 受保护取图是异步 blob：等"图真的解码出来"而不是睡固定时间
  await waitFor(cdp, `(() => { const i = [...document.querySelectorAll('.n-drawer .qr-box img')].find((x) => x.naturalWidth > 0); return !!i; })()`, { timeout: 15000 });
  await sleep(400);
  const d = await cdp.evalJs(DRAWER_PROBE);
  if (!d.open) f2.push('详情抽屉没打开');
  else {
    if (d.head !== '提现详情') f2.push(`抽屉标题 = 「${d.head}」，期望「提现详情」`);
    if (d.amount !== AMOUNT_LABEL) f2.push(`抽屉金额 = 「${d.amount}」，期望「${AMOUNT_LABEL}」`);
    const img = (d.qrBoxImgs ?? []).find((i) => i.nw > 0);
    if (!img) {
      f2.push(`收款码大图**没加载出来**（.qr-box 里 img = ${JSON.stringify(d.qrBoxImgs)}）→ 受保护取图链路有问题/裂图`);
    } else {
      if (!String(img.src).startsWith('blob:')) f2.push(`收款码 src = ${img.src}（不是 blob → 说明是直连 URL，不是带令牌取图）`);
      if (!(img.nw >= 200 && img.nh >= 200)) f2.push(`收款码解码尺寸过小 nw=${img.nw} nh=${img.nh}（可能是占位/裂图）`);
      if (!img.visible) f2.push('收款码图存在但不可见');
    }
    // 完整收款信息（审核必需；**列表与详情同口径**）
    for (const want of [FULL.realName, FULL.phone, FULL.wechatId].filter((x) => x)) {
      if (!String(d.body).includes(want)) f2.push(`抽屉里看不到完整收款信息「${want}」（withdraw:review 应给完整值）`);
    }
    if (MASK.phone && String(d.body).includes(MASK.phone)) {
      f2.push(`抽屉里出现了打码手机号 ${MASK.phone}（口径应为完整值）`);
    }
    if (!String(d.body).includes(NICK) || !String(d.body).includes(NO)) f2.push('抽屉里缺打手昵称/工号');
    /*
     * 状态守卫 + **绝不改数据**：
     *   · pending → 「已提现」「驳回」在位（未上传凭证时「已提现」必须禁用）；**脚本不点它们**；
     *   · 非 pending（已打款/已驳回）→ 一个操作按钮都不该有，只有只读结果说明。
     */
    const payBtn = (d.buttons ?? []).find((b) => b.text === '已提现');
    const rejectBtn = (d.buttons ?? []).find((b) => b.text === '驳回');
    if (STATUS === 'pending') {
      if (!payBtn) f2.push('抽屉里没有「已提现」按钮（超管应有 withdraw:pay）');
      else if (!payBtn.disabled) f2.push('「已提现」在**未上传凭证**时就是可点的（要求：上传前禁用）');
      if (!rejectBtn) f2.push('抽屉里没有「驳回」按钮（超管应有 withdraw:pay）');
      if (String(d.body).includes('没有打款权限')) f2.push('抽屉提示当前账号没有打款权限（opsadmin 不该如此）');
    } else {
      if (payBtn || rejectBtn) {
        f2.push(`状态=${STATUS} 的记录不该出现打款/驳回按钮（实际：${JSON.stringify((d.buttons ?? []).map((b) => b.text))}）`);
      }
      if (!/已打款|已驳回/.test(String(d.body))) f2.push(`非 pending 记录没渲染只读结果说明（${STATUS}）`);
    }
  }
  const shotDetail = await cdp.shot('11-真实链路-详情与收款码.png');
  record('② 详情抽屉：收款码大图加载成功（blob）+ 完整收款信息 + 状态守卫（写入口未点）', f2, {
    抽屉标题: d.open ? d.head : '（没打开）',
    金额: d.open ? d.amount : '—',
    收款码: d.open ? JSON.stringify(d.qrBoxImgs) : '—',
    按钮: d.open ? JSON.stringify((d.buttons ?? []).map((b) => `${b.text}${b.disabled ? '(禁用)' : ''}`)) : '—',
    截图: shotDetail,
  });

  /* ---------------------------------------------------- 收尾：绝不改数据 */
  hr('收尾（本脚本只读：未点打款、未点驳回、未提交任何写请求）');
  const mutated = await cdp.evalJs(`(() => {
    const dlg = document.querySelector('.n-dialog');
    return { dialogOpen: !!dlg, drawerOpen: !!document.querySelector('.n-drawer') };
  })()`);
  console.log(`     [状态] 二次确认弹窗=${mutated.dialogOpen}（应为 false）｜详情抽屉=${mutated.drawerOpen}（只读展示）`);
  if (mutated.dialogOpen) { f2.push('出现了确认弹窗（说明误触发过打款/驳回）'); failCount += 1; }
  if (cdp.exceptions.length) console.log(`     [页面异常] ${cdp.exceptions.slice(0, 3).join(' || ')}`);

  const summary = {
    checkedAt: new Date().toISOString(), ui: UI, artifact: ARTIFACT,
    requestId: ART.requestId, worker: `${NICK}（${NO}）`, amountLabel: AMOUNT_LABEL,
    screenshots: { list: shotList, detail: shotDetail },
    readOnly: true, failCount, results,
  };
  fs.writeFileSync(path.join(SHOT_DIR, 'real-browser-check.json'), JSON.stringify(summary, null, 2), 'utf8');
  console.log(`\n=== 结果：${results.length - failCount} PASS / ${failCount} FAIL ===`);
  if (failCount) process.exitCode = 1;
}

main()
  .catch((e) => { console.error('\n[异常]', e && e.stack ? e.stack : e); process.exitCode = 1; })
  .finally(async () => {
    try { if (browser) browser.kill(); } catch { /* ignore */ }
    await sleep(300);
  });
