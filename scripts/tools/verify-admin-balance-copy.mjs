/**
 * 管理端「余额口径」核验（无头 Edge + CDP 真跑真截图）
 * ============================================================================
 * 为什么有这个脚本（负责人 2026-10-09 拍板：计价单位 积分 → 余额）：
 *   · 平台计价单位从「积分（1 元 = 10 积分）」改为「余额（1 元 = 1 元）」，存量金额由**服务端**按 10:1 折算；
 *   · 管理端只改**显示与文案**：金额一律 `¥` + 两位小数、金额语境里不再出现「积分」二字、
 *     合规口径（余额仅可用于平台内消费、不可提现、不可转让；平台不提供在线支付、不经手资金）必须可见。
 *   · 这三条**不能靠读代码确认** —— 必须在真浏览器里按渲染结果断言（Vue 模板没渲染出来就等于没有）。
 *
 * 逐页断言（**红/绿由退出码决定**，任一 FAIL → exit 1）：
 *   ① 页面可见文本里**不出现「积分」**（金额语境页面）+ 不出现「支付成功」（合规红线）；
 *   ② 表格里**金额列**的每个单元格都形如 `¥1,234.56`（¥ + 千分位 + 恒两位小数）；
 *   ③ 页面级：所有「两位小数」形态的数字**前面必须紧跟 ¥**，且每个 `¥` 金额都必须是两位小数；
 *   ④ 关键文案/合规句可见（充值页与余额页必须命中「不可提现/不可转让/不经手资金」）；
 *   ⑤ `/recharge` 专项：点「发放」后的二次确认弹窗必须写「确认发放余额 / ¥6.00 / 不可提现」，点「取消」收尾
 *      （**只看不点确认**，一分钱不动）。
 *   · **逐 tab 探测**：金额列可能不在默认 tab 上（/catalog 的价格在「商品」、/wallets 的流水在第二个 tab）。
 *
 * 并行环境铁律（沿用 verify-admin-table-actions.mjs）：
 *   · **绝不用真实超管 `kslingyun` 登录**（会顶掉负责人会话）→ 一律走 `scripts/tools/regression-admin.js`
 *     的专用测试超管（`.env` 里登记的 `REGRESSION_ADMIN_USER` / `REGRESSION_ADMIN_PASSWORD`）；
 *     仍可用 `VBC_ADMIN_USER` / `VBC_ADMIN_PASS` 显式覆盖。
 *   · 会话被顶掉（落到 /login）不静默重登，如实打印并判 FAIL。
 *
 * 运行：node scripts/tools/verify-admin-balance-copy.mjs
 * 前置：pm2 fish-server（3100）、pm2 fish-admin（Vite dev 5173，只绑 IPv6 → http://[::1]:5173）
 *       充值审阅列表要有数据行才量得到金额列：先跑 scripts/tmp/balance-fixture-recharge.js（造 1 条 ¥6.00 待核对申请）
 * 可选环境变量：
 *   VBC_UI          管理端地址（默认 http://[::1]:5173；验证 dist 走 http://127.0.0.1:3100）
 *   VBC_API         后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   VBC_PAGES       页面路径列表（默认 8 个：用户/余额/充值/商品/订单/抽成/系统设置/排行榜）
 *   VBC_SHOT_DIR    截图目录（默认 <root>/docs/验收素材/2026-10-09-余额口径）
 *   VBC_TAG         截图文件名前缀（默认 green；变异验证用 red）
 *   VBC_WIDTH       窗口宽度（默认 1600）
 *   VBC_EDGE_BIN    Edge 可执行文件
 *   VBC_CDP_PORT    CDP 端口（默认 9271）
 */
import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
// 管理端账号：**唯一入口** scripts/tools/regression-admin.js（债 1；ESM 里用 createRequire 引 CJS）。
const requireCjs = createRequire(import.meta.url);
const { adminUser: REG_ADMIN_USER, adminPassword: REG_ADMIN_PASS } = requireCjs('./regression-admin.js');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(process.env.FISH_ROOT || path.join(HERE, '..', '..'));

const UI = process.env.VBC_UI || 'http://[::1]:5173';
const API = process.env.VBC_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VBC_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VBC_CDP_PORT || 9271);
const WIDTH = Number(process.env.VBC_WIDTH || 1600);
const PAGES = (process.env.VBC_PAGES || '/users,/wallets,/recharge,/catalog,/orders,/commission,/settings,/leaderboard')
  .split(',').map((s) => s.trim()).filter(Boolean);
const SHOT_DIR = process.env.VBC_SHOT_DIR || path.join(ROOT, 'docs', '验收素材', '2026-10-09-余额口径');
const TAG = process.env.VBC_TAG || 'green';
const USER = process.env.VBC_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VBC_ADMIN_PASS || REG_ADMIN_PASS;

if (!PASS) { console.error('缺少管理端口令（VBC_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);

/**
 * 逐页规则（页面级期望）。
 * - mustSee：页面可见文本必须包含的字符串（合规口径/关键文案；**逐 tab 取并集**）；
 * - mustMoneyCols：表格里**必须存在**且**每个单元格都带 ¥ 两位小数**的金额列（按表头子串匹配）；
 * - expectYuan：页面至少出现几处 `¥` 形态金额。
 */
const PAGE_RULES = {
  '/users': { mustSee: ['余额'], mustMoneyCols: ['余额'], expectYuan: 1 },
  '/wallets': {
    mustSee: ['余额', '不可提现', '不可转让', '不经手资金'],
    mustMoneyCols: ['余额', '累计消费', '金额', '前余额', '后余额'],
    expectYuan: 3,
  },
  '/recharge': {
    mustSee: ['余额', '不可提现', '不可转让', '不经手资金', '已发放'],
    mustMoneyCols: ['金额', '应得余额'],
    expectYuan: 1,
  },
  '/catalog': { mustSee: [], mustMoneyCols: ['价格'], expectYuan: 1 },
  '/orders': { mustSee: [], mustMoneyCols: ['金额'], expectYuan: 1 },
  '/commission': { mustSee: ['（元）'], mustMoneyCols: ['订单金额', '收益', '抽成'], expectYuan: 3 },
  '/settings': { mustSee: [], mustMoneyCols: [], expectYuan: 0 },
  '/leaderboard': { mustSee: ['真实金额', '有效金额'], mustMoneyCols: ['真实金额', '有效金额'], expectYuan: 2 },
};

/** 全站红线：这些字样出现在任何页面都算 FAIL */
const GLOBAL_FORBIDDEN = ['积分', '支付成功'];

// ------------------------------------------------------------------ CDP
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.exceptions = [];
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
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
    const r = await this.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    const buf = Buffer.from(r.data, 'base64');
    const p = path.join(SHOT_DIR, name);
    fs.writeFileSync(p, buf);
    return p;
  }
}

// ------------------------------------------------------------------ 页面内断言
/**
 * 在页面里做**只读测量**（判定在 Node 侧做，便于打印"哪个单元格、什么文本"）。
 * `__MUST_SEE__` 会被替换成本页的 mustSee 数组（逐页注入，避免把整页文本传回来）。
 * 注意：所有反斜杠都要写成 `\\` —— 这段是塞进 Runtime.evaluate 的字符串。
 */
const PROBE = `(() => {
  const mustSee = __MUST_SEE__;
  const out = { path: location.pathname, jifen: [], forbidden: [], moneyCells: [], bareAmounts: [], badYuan: [], yuanCount: 0, tables: [], see: {} };
  const txt = document.body.innerText || '';
  const clip = (s, i, n) => s.slice(Math.max(0, i - (n || 16)), i + (n || 16)).replace(/\\s+/g, ' ');

  // ① 红线字样出现位置（含上下文，便于定位是哪个卡片/哪一列）
  for (const bad of ${JSON.stringify(GLOBAL_FORBIDDEN)}) {
    let i = -1;
    while ((i = txt.indexOf(bad, i + 1)) !== -1) (bad === '积分' ? out.jifen : out.forbidden).push(clip(txt, i));
  }
  // ④ 关键文案 / 合规句
  for (const s of mustSee) out.see[s] = txt.includes(s);

  // ② 表格「金额列」逐单元格断言：¥ + 千分位 + 恒两位小数
  const MONEY_HEAD = /(金额|余额|价格|收益|抽成|消费|退款|打赏|调整)/;
  // 不是金额的列（计数/时间/人数）：即使列名里带「金额」这类词也不该有 ¥
  const NOT_MONEY = /(单数|次数|时间|人数|数量|条数)/;
  const MONEY_RE = /¥\\s?-?\\d{1,3}(?:,\\d{3})*\\.\\d{2}/;
  for (const t of document.querySelectorAll('.n-data-table')) {
    const ths = [...t.querySelectorAll('thead th')].map((th) => th.innerText.replace(/\\s+/g, ' ').trim());
    const rows = [...t.querySelectorAll('tbody tr')];
    if (rows.length) out.tables.push({ headers: ths, rows: rows.length });
    rows.slice(0, 6).forEach((tr) => {
      [...tr.querySelectorAll('td')].forEach((td, ci) => {
        const head = ths[ci] ?? '';
        if (!MONEY_HEAD.test(head) || NOT_MONEY.test(head)) return;
        const cell = (td.innerText || '').replace(/\\s+/g, ' ').trim();
        if (!cell || cell === '—') return;
        out.moneyCells.push({ head, cell: cell.slice(0, 40), ok: MONEY_RE.test(cell) });
      });
    });
  }

  // ③ 页面级：所有「两位小数」形态的数字前面必须紧跟 ¥（抓漏改的裸金额，如 8.80 / 99,999.90）
  const re = /\\d{1,3}(?:,\\d{3})*\\.\\d{2}/g;
  let m;
  while ((m = re.exec(txt))) {
    if (txt[m.index - 1] === '¥') out.yuanCount += 1;
    else out.bareAmounts.push(clip(txt, m.index, 20));
  }
  // 「¥ 存在但格式不对」：把每个 ¥ 开头的金额整块切出来再整体校验。
  // （**不能**用「¥ 后跟一位小数」这类正则直接判 —— 它会在 \`¥4,720.00\` 上回溯出假的 \`¥4\`；
  //   本脚本第一版就这么误报过，所以改成"先切词、再整体匹配"。）
  const tokens = txt.match(/¥\\s?-?[\\d,]+(?:\\.\\d+)?/g) || [];
  out.badYuan = tokens.filter((s) => !/^¥-?\\d{1,3}(?:,\\d{3})*\\.\\d{2}$/.test(s.replace(/\\s/g, ''))).slice(0, 10);
  return out;
})()`;

/** 点第 i 个 tab（naive-ui 的 tab 自己接 click，派发冒泡 MouseEvent 即可） */
const clickTab = (i) => `(() => {
  const tabs = [...document.querySelectorAll('.n-tabs-tab')];
  if (!tabs[${i}]) return null;
  tabs[${i}].dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return tabs[${i}].innerText.replace(/\\s+/g, ' ').trim();
})()`;

/** 可见弹层（n-dialog / n-modal）的文本 */
const DIALOG_TEXT = `(() => {
  const d = [...document.querySelectorAll('.n-dialog, .n-modal')].find((x) => x.offsetParent !== null);
  return d ? d.innerText.replace(/\\s+/g, ' ').trim() : null;
})()`;

// ------------------------------------------------------------------ 主流程
const PROFILE = os.tmpdir() + '/fish-edge-balance-' + Date.now();
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
  console.log(`[配置] UI=${UI} API=${API} 宽度=${WIDTH} 页面=${PAGES.length} 截图目录=${SHOT_DIR} tag=${TAG}`);
  browser = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${PORT}`, '--no-first-run',
    `--user-data-dir=${PROFILE}`, `--window-size=${WIDTH},1000`, 'about:blank'], { stdio: 'ignore' });
  await sleep(2600);

  hr(`0. 登录（专用测试超管 ${USER}，绝不用 kslingyun）`);
  let login = await apiLogin();
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

  await cdp.send('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2200);
  await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(login.token)}); 'ok'`);
  const meProbe = `(async () => { const r = await fetch(${JSON.stringify(API)} + '/auth/me', { headers: { Authorization: 'Bearer ' + localStorage.getItem('fish_admin_token') } }); const j = await r.json(); return { status: r.status, role: j?.data?.admin?.roleCode ?? j?.data?.roleCode, isOwner: j?.data?.admin?.isOwner ?? j?.data?.isOwner, perms: (j?.data?.admin?.permissions ?? j?.data?.permissions ?? []).length }; })()`;
  let me = await cdp.evalJs(meProbe);
  if (me?.status !== 200) {
    // 并行批次可能刚用同一个回归账号登录过（primary↔primary 互斥会把本会话顶掉）→ 只重试一次，如实打印
    console.log(`[会话] /auth/me → HTTP ${me?.status}（疑似被并行批次顶号）→ 重新登录一次`);
    login = await apiLogin();
    if (!login.token) throw new Error('重新登录失败');
    await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(login.token)}); 'ok'`);
    await sleep(500);
    me = await cdp.evalJs(meProbe);
  }
  console.log(`[会话] /auth/me → HTTP ${me?.status} roleCode=${me?.role} isOwner=${me?.isOwner} 权限点=${me?.perms}`);
  if (me?.status !== 200) throw new Error('会话不可用，中断（不再重复登录以免来回顶号）');

  hr('1. 逐页断言（无「积分」/ 金额列 ¥ 两位小数 / 合规句可见）');
  /**
   * 会话恢复（**不是静默重登**）：三个批次并行跑同一个回归超管账号时，
   * primary↔primary 互斥会把本脚本的会话顶掉（实测第 5 个页面开始落到 /login）。
   * 这里**大声打印**并重新登录（上限 3 次），每次都会说明"为什么重登、第几次"。
   */
  let relogins = 0;
  const MAX_RELOGIN = 3;
  async function ensureSession(p) {
    if (await cdp.evalJs('location.pathname') !== '/login') return true;
    if (relogins >= MAX_RELOGIN) return false;
    relogins += 1;
    console.log(`[会话] ${p} 落到 /login（疑似被并行批次顶号）→ 第 ${relogins}/${MAX_RELOGIN} 次重新登录`);
    const again = await apiLogin();
    if (!again.token) { console.log(`[会话] 重新登录失败：HTTP ${again.status}`); return false; }
    await cdp.evalJs(`localStorage.setItem('fish_admin_token', ${JSON.stringify(again.token)}); 'ok'`);
    await sleep(400);
    await cdp.send('Page.navigate', { url: `${UI}${p}` });
    await sleep(3200);
    return (await cdp.evalJs('location.pathname')) !== '/login';
  }

  for (const p of PAGES) {
    const rule = PAGE_RULES[p] ?? { mustSee: [], mustMoneyCols: [], expectYuan: 0 };
    await cdp.send('Page.navigate', { url: `${UI}${p}` });
    await sleep(3200);
    if (!(await ensureSession(p))) {
      console.log(`FAIL ${p} 落到 /login（会话被顶，且已重登 ${relogins} 次）`);
      results.push({ page: p, fails: ['落到 /login（会话被顶，重登上限已用尽）'], shots: [] });
      continue;
    }

    // ---- 逐 tab 探测：金额列可能不在默认 tab 上（/catalog 的价格在「商品」、/wallets 的流水在第二个 tab）----
    const tabLabels = (await cdp.evalJs(`[...document.querySelectorAll('.n-tabs-tab')].map((t) => t.innerText.replace(/\\s+/g, ' ').trim())`)) ?? [];
    const tabCount = Math.max(tabLabels.length, 1);
    const probes = [];
    const shots = [];
    for (let i = 0; i < tabCount; i += 1) {
      if (i > 0) { await cdp.evalJs(clickTab(i)); await sleep(1100); }
      probes.push(await cdp.evalJs(PROBE.replace('__MUST_SEE__', JSON.stringify(rule.mustSee))));
      shots.push(await cdp.shot(`${TAG}-${p.replace(/\//g, '')}${tabCount > 1 ? `-t${i + 1}` : ''}.png`));
    }
    const merged = {
      jifen: probes.flatMap((x) => x.jifen ?? []),
      forbidden: probes.flatMap((x) => x.forbidden ?? []),
      moneyCells: probes.flatMap((x) => x.moneyCells ?? []),
      bareAmounts: probes.flatMap((x) => x.bareAmounts ?? []),
      badYuan: probes.flatMap((x) => x.badYuan ?? []),
      yuanCount: probes.reduce((a, x) => a + (x.yuanCount ?? 0), 0),
      tables: probes.flatMap((x) => x.tables ?? []),
    };

    const fails = [];
    // ① 红线字样（逐 tab 都查）
    for (const bad of GLOBAL_FORBIDDEN) {
      const hits = bad === '积分' ? merged.jifen : merged.forbidden;
      if (hits.length) fails.push(`出现「${bad}」×${hits.length}：${JSON.stringify(hits.slice(0, 3))}`);
    }
    // ② 金额列逐单元格
    for (const col of rule.mustMoneyCols) {
      const hit = merged.moneyCells.filter((c) => c.head.includes(col));
      if (!hit.length) fails.push(`金额列「${col}」在本页所有 tab 里都没量到单元格（列没渲染？没数据行？列名变了？）`);
      const bad = hit.filter((c) => !c.ok);
      if (bad.length) fails.push(`金额列「${col}」有 ${bad.length}/${hit.length} 个单元格不是 ¥ 两位小数：${JSON.stringify(bad.slice(0, 3))}`);
    }
    // ③ 裸金额 / ¥ 格式
    if (merged.bareAmounts.length) fails.push(`有 ${merged.bareAmounts.length} 处「两位小数」前面没有 ¥：${JSON.stringify(merged.bareAmounts.slice(0, 4))}`);
    if (merged.badYuan.length) fails.push(`有 ${merged.badYuan.length} 处 ¥ 金额不是两位小数：${JSON.stringify(merged.badYuan.slice(0, 4))}`);
    // ④ 金额总量
    if (merged.yuanCount < rule.expectYuan) fails.push(`页面只出现 ${merged.yuanCount} 处 ¥ 金额（期望 ≥ ${rule.expectYuan}）`);
    // ⑤ 关键文案 / 合规句（任一 tab 命中即算可见，但会打印命中在哪个 tab）
    for (const s of rule.mustSee) {
      const where = probes.map((pr, i) => (pr.see?.[s] ? (tabLabels[i] ?? `tab${i + 1}`) : null)).filter(Boolean);
      if (!where.length) fails.push(`缺关键文案「${s}」（已查全部 ${tabCount} 个 tab）`);
    }

    const heads = merged.tables.map((t) => `${t.headers.join('|')}(${t.rows}行)`).join('  ||  ');
    console.log(`${fails.length ? 'FAIL' : 'PASS'} ${p}   tab=${tabLabels.join('/') || '—'}  ¥金额=${merged.yuanCount}  金额列单元格=${merged.moneyCells.length}（不合规 ${merged.moneyCells.filter((c) => !c.ok).length}）  积分=${merged.jifen.length}  裸金额=${merged.bareAmounts.length}`);
    if (heads) console.log(`     表格：${heads}`);
    if (merged.moneyCells.length) console.log(`     金额单元格样本：${JSON.stringify(merged.moneyCells.slice(0, 4))}`);
    for (const f of fails) console.log(`     ✗ ${f}`);
    for (const s of shots) console.log(`     截图：${s}`);
    results.push({ page: p, fails, shots, yuanCount: merged.yuanCount, cells: merged.moneyCells.length, jifen: merged.jifen.length });

    // ---- 充值页专项：点「发放」看二次确认文案（**只看不点确认**，金额一分不动）----
    if (p === '/recharge') {
      await cdp.evalJs(clickTab(0)); await sleep(900);
      const clicked = await cdp.evalJs(`(() => {
        const b = [...document.querySelectorAll('.n-data-table tbody button')].find((x) => x.innerText.trim() === '发放');
        if (!b) return false;
        b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        return true;
      })()`);
      await sleep(900);
      const dlg = await cdp.evalJs(DIALOG_TEXT);
      const dlgShot = await cdp.shot(`${TAG}-recharge-grant-dialog.png`);
      const dlgFails = [];
      if (!clicked) dlgFails.push('列表里没找到「发放」按钮（夹具数据行缺失？先跑 scripts/tmp/balance-fixture-recharge.js）');
      if (!dlg) dlgFails.push('点了「发放」但没有弹出二次确认');
      else {
        // 弹窗这一层要的合规句 = 「余额仅可用于平台内消费，不可提现、不可转让」
        // （「平台不提供在线支付、不经手资金」在本页页头常驻，属于**页面级** mustSee，不要求弹窗重复）
        for (const s of ['确认发放余额', '¥6.00', '不可提现', '不可转让']) {
          if (!dlg.includes(s)) dlgFails.push(`发放确认弹窗缺「${s}」`);
        }
        if (dlg.includes('积分')) dlgFails.push('发放确认弹窗仍出现「积分」');
      }
      console.log(`${dlgFails.length ? 'FAIL' : 'PASS'} /recharge 发放二次确认弹窗`);
      console.log(`     弹窗文本：${dlg}`);
      console.log(`     截图：${dlgShot}`);
      for (const f of dlgFails) console.log(`     ✗ ${f}`);
      // 关闭弹窗（点「取消」）；**绝不点确认**，不动任何金额
      const cancelled = await cdp.evalJs(`(() => {
        const d = [...document.querySelectorAll('.n-dialog, .n-modal')].find((x) => x.offsetParent !== null);
        if (!d) return false;
        const b = [...d.querySelectorAll('button')].find((x) => x.innerText.trim() === '取消');
        if (!b) return false;
        b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        return true;
      })()`);
      console.log(`     已点「取消」关闭弹窗（未发放任何余额）：${cancelled ? '是' : '否（请人工确认）'}`);
      if (dlgFails.length) results[results.length - 1].fails.push(...dlgFails);
    }
  }

  hr('汇总');
  let bad = 0;
  for (const r of results) {
    const flag = r.fails.length ? 'FAIL' : 'PASS';
    if (r.fails.length) bad += 1;
    console.log(`${flag}  ${r.page}  失败项=${r.fails.length}  ¥=${r.yuanCount ?? '—'}  金额列单元格=${r.cells ?? '—'}  「积分」命中=${r.jifen ?? '—'}`);
  }
  console.log(`\n共 ${results.length} 个页面，FAIL ${bad} 个`);
  fs.writeFileSync(path.join(SHOT_DIR, `probe-${TAG}.json`), JSON.stringify(results, null, 2), 'utf8');
  console.log(`[落盘] ${path.join(SHOT_DIR, `probe-${TAG}.json`)}`);
  if (bad) process.exitCode = 1;
} catch (e) {
  console.error('运行失败：', e?.message ?? e);
  process.exitCode = 1;
} finally {
  try { browser?.kill(); } catch { /* ignore */ }
  await sleep(300);
  try { fs.rmSync(PROFILE, { recursive: true, force: true }); } catch { /* ignore */ }
}
