/**
 * 管理端「提现审核」核验（无头 Edge + CDP 真跑真截图）
 * ============================================================================
 * 为什么有这个脚本（本轮任务：新增提现审核页）：
 *   这一页是**资金出账**链路，页面上的四件事都只能按渲染结果断，读代码断不出来：
 *     ① 菜单项有没有真的出现在「资金与抽成」组下；
 *     ② 金额是不是 `¥` + 两位小数 + 千分位（不是 `288.5 元`、不是 `¥288.5`）；
 *     ③ 状态标签（待处理/已打款/已驳回）与"非 pending 行**一个按钮都没有**"的状态守卫；
 *     ④ 权限渲染：没有 `withdraw:pay` 的账号**看不到**打款/驳回按钮（前端隐藏 + 服务端兜底）。
 *
 * 逐项断言（任一 FAIL → exit 1）：
 *   ① 菜单：展开「资金与抽成」→ 子项里有 `提现审核`（`data-nav-item="withdraw"`），且与
 *      「余额管理 / 充值管理 / 抽成中心」同组并列；
 *   ② 页面可打开 + 列表渲染：`h1` = 提现审核、表体 3 行（待处理/已打款/已驳回各一）；
 *   ②b **收款信息列给完整值**（负责人 2026-10-11 改定：能看列表 = 有 `withdraw:review` = 审核人本人）：
 *      第一行该列必须含**完整 11 位手机号** `13812346621`，且**不再出现** `139****5528` 这类脱敏串、
 *      表头不得再写「脱敏」；
 *   ②c **列宽 / 横向滚动 / 操作列固定**：宽屏下操作列 `position: sticky` 且右缘贴住可视区；
 *      窄屏（1024）下 `:scroll-x` 区域**真的能横向滚动**（scrollLeft 可置 >0、表头同步），
 *      滚动到右侧后「处理」仍完整可见，收款信息格不溢出（不破版）；
 *   ②d **回退不裂**：服务端未更新（列表只有 `accountMasked`、没有 `account`）时，
 *      该列回退显示脱敏串且不为空（`account` 取不到不会白屏）；
 *   ③ 金额：三个金额单元格**逐字**等于 `¥288.50` / `¥1,240.00` / `¥76.40`，且全部匹配 `/^¥[\d,]+\.\d{2}$/`；
 *   ④ 状态标签：文字 待处理/已打款/已驳回 + 标签色（warning/success/error）逐行对得上；
 *   ⑤ 状态守卫：非 pending 两行的操作列**没有任何 `<button>`**，只有只读结果文字；
 *   ⑥ 权限渲染（本轮硬要求）：把 `/auth/me` 换成"有 review、无 pay"的运营账号 →
 *      列表行**没有「驳回」按钮**、抽屉里**没有「已提现」「驳回」按钮**，并显示只读说明；
 *      ⑥b 再把 `/auth/me` 换成**两个权限都没有** → 侧栏「提现审核」整项消失（两个都没有才隐藏）；
 *   ⑦ 上传凭证前「已提现」不可用：抽屉里「已提现」初始 `disabled` → CDP 真上传一张图（打桩的上传接口）
 *      → 按钮变可用 → 点它弹二次确认（含「确认后将标记为已打款」「此操作不可撤销」）→ 确认后
 *      **实际发出的 `POST /admin/withdraw/requests/:id/pay` 请求体里带着刚上传的 proofMediaId**；
 *   ⑧ 驳回二次确认含「余额将退回打手」（打款/驳回的语义差别必须写在确认框里）；
 *   ⑨ 页面**不含"积分"**二字（全文 innerText 检索，列表与抽屉各查一次）；
 *   ⑩ 线上 bundle 已更新：`http://127.0.0.1:3100/` 的入口 JS 与本地 `admin-web/dist` 逐字一致，
 *      且 dist 里存在含「提现审核」的 WithdrawView chunk（服务端直接托管 dist，构建完即生效）。
 *
 * ## 两种取数模式（服务端由另一批并行实现，本轮可能还没落盘）
 *   · **默认 = 打桩模式**（`VWD_LIVE` 未设）：用 CDP `Fetch` 域在**网络层**打桩
 *     `/api/v1/admin/withdraw/*`（列表/详情/取图/打款/驳回/配置）与 `/admin/media/upload`，
 *     桩数据严格按任务书契约形状造（金额是三笔拟真的非整数）。这样上面 ①–⑨ 的**渲染断言**是完全
 *     确定性的，不依赖服务端进度。**打桩只发生在浏览器网络层，没有改任何页面代码。**
 *   · `VWD_LIVE=1` = **真后端模式**：不打桩，直接打真实接口（服务端落盘后用它做联调/回归；
 *     此时断言 ②–⑤ 需要库里真的有待处理/已打款/已驳回三种样本，缺样本会如实报 FAIL）。
 *
 * ## 变异（反向断言）：`--mutate-pay-guard`
 *   把 `WithdrawView.vue` 里操作列/抽屉的 `canPay` 判断去掉（即"前端不做权限渲染"），
 *   再跑本脚本 → **⑥ 必须红**。变异模式下只跑 ⑥ 并打印 RED/GREEN 两行：
 *     🔴 RED  = 无 pay 权限的账号看到了打款/驳回按钮（探针命中变异，断言是有效的）
 *     🟢 GREEN = 按钮仍然不出现（要么变异没生效、要么断言根本没在起作用 → 需要查）
 *
 * ## 变异（反向断言）：`--mutate-masked-account`
 *   把 `WithdrawView.vue` 的收款信息列**改回读 `row.accountMasked`**（即"列表继续脱敏"），
 *   再跑本脚本 → **②b 必须红**。变异模式下只跑 ②/②b 并打印 RED/GREEN 两行：
 *     🔴 RED  = 该列又出现了脱敏串/没有完整手机号（探针命中变异，断言是有效的）
 *     🟢 GREEN = 仍然显示完整 11 位手机号（变异没生效或断言不起作用 → 需要查）
 *   ⚠️ 变异要**改源码后重新构建**（`npm run build`）或对着 Vite dev 跑；对着线上 dist 跑必须先构建。
 *
 * ## 并行环境铁律（沿用 verify-admin-light-grouped-shell.mjs）
 *   · **绝不用真实超管 `kslingyun` 登录** → 一律走 `scripts/tools/regression-admin.js` 的专用测试超管；
 *   · 会话被顶掉（落到 /login）**不静默重登**，如实打印并中断；
 *   · 截图目录 `docs/验收素材/2026-10-11-提现/`（**不入 git**）。
 *
 * 运行：node scripts/tools/verify-admin-withdraw.mjs
 * 前置：pm2 fish-server（3100）+ pm2 fish-admin（Vite dev 5173，只绑 IPv6 → http://[::1]:5173）
 * 可选环境变量：
 *   VWD_UI        管理端地址（默认 http://[::1]:5173；验 dist 走 http://127.0.0.1:3100）
 *   VWD_API       后端 API 前缀（默认 http://127.0.0.1:3100/api/v1）
 *   VWD_LIVE      设为 1 = 不打桩，直接打真后端
 *   VWD_SHOT_DIR  截图目录（默认 <root>/docs/验收素材/2026-10-11-提现）
 *   VWD_WIDTH/VWD_HEIGHT  窗口尺寸（默认 1600x1000）
 *   VWD_EDGE_BIN  Edge 可执行文件
 *   VWD_CDP_PORT  CDP 端口（默认 9286）
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

const UI = process.env.VWD_UI || 'http://[::1]:5173';
const DIST_ORIGIN = process.env.VWD_DIST_ORIGIN || 'http://127.0.0.1:3100';
const API = process.env.VWD_API || 'http://127.0.0.1:3100/api/v1';
const EDGE = process.env.VWD_EDGE_BIN || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const PORT = Number(process.env.VWD_CDP_PORT || 9286);
const WIDTH = Number(process.env.VWD_WIDTH || 1600);
const HEIGHT = Number(process.env.VWD_HEIGHT || 1000);
const LIVE = process.env.VWD_LIVE === '1';
const SHOT_DIR = process.env.VWD_SHOT_DIR || path.join(ROOT, 'docs', '验收素材', '2026-10-11-提现');
const USER = process.env.VWD_ADMIN_USER || REG_ADMIN_USER;
const PASS = process.env.VWD_ADMIN_PASS || REG_ADMIN_PASS;
const DIST = path.join(ROOT, 'admin-web', 'dist');
/** 变异模式：去掉页面的 canPay 判断后，⑥ **必须红**（见文件头） */
const MUTATE = process.argv.includes('--mutate-pay-guard');
/** 变异模式：把取值改回 `accountMasked`（列表继续脱敏）后，②b **必须红**（见文件头） */
const MUTATE_MASK = process.argv.includes('--mutate-masked-account');

if (!PASS) { console.error('缺少管理端口令（VWD_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

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

/* ================================================================== 打桩数据
 * **严格照真契约的形状造**（服务端已落盘：`server/src/modules/withdraw/withdraw.service.ts`）：
 *   · 列表行：`workerNo` / `workerNickname` / `amount` / `status` / **`appliedAt`** /
 *     **`account: { realName, phone, wechatId }`（完整值，2026-10-11 列表接口新增）** ＋
 *     **`accountMasked: { realName, phone, wechatId }`（对象，同时保留）**；
 *   · 列表响应：`{ list, total, page, pageSize, **pendingTotal** }`；
 *   · 详情：`{ ...行, **account: { realName, phone, wechatId, qrMediaId, qrUrl }**, rejectTransaction }`
 *     ＋ 打款记录是**平铺字段**（`payerName` / `paidAt` / `payoutProofMediaId` / `payoutNote`）。
 * 按真形状造桩，这一套断言就同时覆盖了前端的**别名归一**逻辑（字段名写错会当场红）。
 * 金额刻意是**拟真的非整数**（docs/21 反 AI 味：假数据必须拟真）。
 * 三种状态各一条：待处理（本轮所有交互都在它身上）/ 已打款（带打款记录与凭证）/ 已驳回（带原因）。
 */
const FIX_ROWS = [
  {
    id: '9001',
    workerId: '51',
    userId: '88',
    workerNo: 'W-20418',
    workerNickname: '夜航船',
    amount: 288.5,
    amountYuan: 288.5,
    status: 'pending',
    appliedAt: '2026-10-11T09:24:00.000Z',
    paidAt: null,
    payerName: '',
    payoutProofMediaId: null,
    payoutNote: null,
    rejectReason: null,
    // 列表新增的**完整**收款信息（展示口径 = 完整；`accountMasked` 只作回退）
    account: { realName: '李承霖', phone: '13812346621', wechatId: 'lxz_88' },
    accountMasked: { realName: '李**', phone: '138****6621', wechatId: 'lx****88' },
    hasAccount: true,
  },
  {
    id: '9002',
    workerId: '52',
    userId: '91',
    workerNo: 'W-19877',
    workerNickname: '青柠不酸',
    amount: 1240,
    amountYuan: 1240,
    status: 'paid',
    appliedAt: '2026-10-10T13:07:00.000Z',
    paidAt: '2026-10-11T02:02:00.000Z',
    payerName: '运营-小祁',
    payoutProofMediaId: 'm-payout-9002',
    payoutNote: '已转微信，对方已确认到账',
    rejectReason: null,
    account: { realName: '王琪', phone: '15911023308', wechatId: 'wq_1021' },
    accountMasked: { realName: '王**', phone: '159****3308', wechatId: 'wq****21' },
    hasAccount: true,
  },
  {
    id: '9003',
    workerId: '53',
    userId: '95',
    workerNo: 'W-20355',
    workerNickname: '老陈的猫',
    amount: 76.4,
    amountYuan: 76.4,
    status: 'rejected',
    appliedAt: '2026-10-10T08:41:00.000Z',
    paidAt: null,
    payerName: '',
    payoutProofMediaId: null,
    payoutNote: null,
    rejectReason: '收款码与申请姓名不一致，请换成本人收款码重新申请',
    account: { realName: '陈屿', phone: '13760422094', wechatId: 'ch_07' },
    accountMasked: { realName: '陈**', phone: '137****2094', wechatId: 'ch****07' },
    hasAccount: true,
  },
];
/** 详情 = 行 + `account`（完整收款信息）+ 打款记录平铺字段 */
const FIX_DETAIL = {
  9001: {
    ...FIX_ROWS[0],
    account: { realName: '李承霖', phone: '13812346621', wechatId: 'lxz_88', qrMediaId: 'm-qr-9001', qrUrl: '/uploads/m-qr-9001.png', updatedAt: '2026-10-11T08:00:00.000Z' },
    rejectTransaction: null,
  },
  9002: {
    ...FIX_ROWS[1],
    account: { realName: '王琪', phone: '15911023308', wechatId: 'wq_1021', qrMediaId: 'm-qr-9002', qrUrl: '/uploads/m-qr-9002.png', updatedAt: '2026-10-09T08:00:00.000Z' },
    rejectTransaction: null,
  },
  9003: {
    ...FIX_ROWS[2],
    account: { realName: '陈屿', phone: '13760422094', wechatId: 'ch_07', qrMediaId: 'm-qr-9003', qrUrl: '/uploads/m-qr-9003.png', updatedAt: '2026-10-08T08:00:00.000Z' },
    rejectTransaction: null,
  },
};
/** 真契约的配置默认值（`withdraw-config.ts` 的 WITHDRAW_CONFIG_DEFAULT 逐值一致） */
const FIX_CONFIG = {
  minAmount: 10,
  maxAmount: 2000,
  dailyLimit: 3,
  feeRate: 0,
  noticeText: '提现 1–3 个工作日处理\n请确保姓名、手机号、微信号与收款码是同一人',
};

/** 1x1 透明 PNG（兜底：仓库里没有二维码图时不让断言挂掉） */
const PNG_FALLBACK = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
);
function readPng(rel) {
  const p = path.join(ROOT, rel);
  try {
    const buf = fs.readFileSync(p);
    return buf.length > 512 ? buf : PNG_FALLBACK;
  } catch {
    return PNG_FALLBACK;
  }
}
/** 收款码桩图 = 仓库里现成的真二维码图（截图看着才像回事） */
const QR_PNG = readPng('site/download/boss-qr.png');
const PAYOUT_PNG = readPng('site/download/download-temp-qr.png');
/** 上传用临时文件（CDP `DOM.setFileInputFiles` 需要一个真实路径） */
const UPLOAD_FILE = path.join(os.tmpdir(), `vwd-proof-${Date.now()}.png`);
fs.writeFileSync(UPLOAD_FILE, readPng('site/download/boss-qr.png'));

/** 记账：被打桩拦下的写请求（用来断言"点了按钮真的发出去了、带对了参数"） */
const captured = { pay: null, reject: null, configPut: null, uploads: 0 };

/* ================================================================== CDP */
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.exceptions = []; this.handlers = new Map();
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.method === 'Runtime.exceptionThrown') {
        this.exceptions.push(flat(JSON.stringify(m.params?.exceptionDetails ?? {})).slice(0, 260));
      }
      if (m.method && this.handlers.has(m.method)) {
        // 事件回调（Fetch.requestPaused 等）：不阻塞消息循环，失败只记日志
        Promise.resolve(this.handlers.get(m.method)(m.params)).catch((e) => console.log(`     [事件处理失败] ${m.method}: ${e?.message ?? e}`));
      }
      if (m.id && this.pending.has(m.id)) {
        const q = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? q.reject(new Error(JSON.stringify(m.error))) : q.resolve(m.result);
      }
    });
  }
  on(method, cb) { this.handlers.set(method, cb); }
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

/* ================================================================== 打桩实现 */
const b64 = (buf) => Buffer.from(buf).toString('base64');
const jsonBody = (data) => b64(Buffer.from(JSON.stringify({ code: 0, message: 'ok', data, requestId: 'stub', timestamp: Date.now() }), 'utf8'));

/** `/auth/me` 覆盖（null = 放行到真后端） */
let meOverride = null;

/**
 * 打桩的收款信息形状：
 *   `full`       = 新契约（`account` 完整值 + `accountMasked`）→ 列表必须显示**完整**
 *   `maskedOnly` = 模拟"服务端还没更新"（只有 `accountMasked`）→ 列表必须**回退**显示脱敏串且不裂
 */
let listAccountShape = 'full';

function stubRows() {
  if (listAccountShape === 'maskedOnly') {
    return FIX_ROWS.map(({ account, ...rest }) => rest);
  }
  return FIX_ROWS;
}

function listPayload(url) {
  const u = new URL(url);
  const status = u.searchParams.get('status') || '';
  const pageSize = Number(u.searchParams.get('pageSize') || 20);
  // 真契约：`all` 与空串都表示不过滤（服务端 `reviewList` 的判定）
  const rows = stubRows();
  const pool = status && status !== 'all' ? rows.filter((r) => r.status === status) : rows;
  return {
    list: pool.slice(0, pageSize),
    total: pool.length,
    page: Number(u.searchParams.get('page') || 1),
    pageSize,
    // 真契约字段名（全库待处理总数）
    pendingTotal: rows.filter((r) => r.status === 'pending').length,
  };
}

/** 打桩路由：返回 `{code, headers, body}` 或 null（= 放行到真后端） */
function stubFor(method, url, postData) {
  const u = new URL(url);
  const p = u.pathname; // /api/v1/admin/withdraw/...
  if (!p.startsWith('/api/v1/admin/withdraw')) return null;

  if (p === '/api/v1/admin/withdraw/requests' && method === 'GET') {
    return { body: jsonBody(listPayload(url)), type: 'application/json' };
  }
  const mDetail = p.match(/^\/api\/v1\/admin\/withdraw\/requests\/([^/]+)$/);
  if (mDetail && method === 'GET') {
    const d = FIX_DETAIL[mDetail[1]];
    return d ? { body: jsonBody(d), type: 'application/json' } : { code: 404, body: jsonBody({ code: 404, message: '提现申请不存在' }), type: 'application/json' };
  }
  const mPay = p.match(/^\/api\/v1\/admin\/withdraw\/requests\/([^/]+)\/pay$/);
  if (mPay && method === 'POST') {
    captured.pay = { id: mPay[1], body: postData ? JSON.parse(postData) : null };
    return { body: jsonBody({ id: mPay[1], status: 'paid' }), type: 'application/json' };
  }
  const mReject = p.match(/^\/api\/v1\/admin\/withdraw\/requests\/([^/]+)\/reject$/);
  if (mReject && method === 'POST') {
    captured.reject = { id: mReject[1], body: postData ? JSON.parse(postData) : null };
    return { body: jsonBody({ id: mReject[1], status: 'rejected' }), type: 'application/json' };
  }
  if (p === '/api/v1/admin/withdraw/config') {
    if (method === 'GET') return { body: jsonBody(FIX_CONFIG), type: 'application/json' };
    if (method === 'PUT') {
      captured.configPut = postData ? JSON.parse(postData) : null;
      return { body: jsonBody(FIX_CONFIG), type: 'application/json' };
    }
  }
  const mProof = p.match(/^\/api\/v1\/admin\/withdraw\/proof\/([^/]+)$/);
  if (mProof && method === 'GET') {
    const kind = u.searchParams.get('kind') || 'qr';
    const png = kind === 'payout' ? PAYOUT_PNG : QR_PNG;
    return { body: b64(png), type: 'image/png', raw: true };
  }
  return null;
}

async function onRequestPaused(cdp, params) {
  const { requestId, request } = params;
  const method = request.method;
  const url = request.url;
  try {
    if (url.includes('/api/v1/admin/media/upload')) {
      captured.uploads += 1;
      const id = `m-proof-${captured.uploads}`;
      await cdp.send('Fetch.fulfillRequest', {
        requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: 'application/json' }],
        body: jsonBody({ id, path: `/uploads/${id}.png`, mimeType: 'image/png', width: 720, height: 1280, sizeBytes: 46600 }),
      });
      return;
    }
    /*
     * 受保护媒体直读通道：**打款凭证是 protected 用途**，`/media/public/:id` 一定 404，
     * MediaUploadField 会退到 `/media/protected/:id`（带令牌）。这里把它也打桩成真 PNG，
     * 这样 ⑦ 才能断"上传后缩略图真的显示出来了"（而不是只断"按钮变可用了"）。
     */
    if (url.includes('/api/v1/media/protected/')) {
      await cdp.send('Fetch.fulfillRequest', {
        requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: 'image/png' }, { name: 'Cache-Control', value: 'no-store' }],
        body: b64(PAYOUT_PNG),
      });
      return;
    }
    if (url.includes('/api/v1/auth/me')) {
      if (meOverride) {
        await cdp.send('Fetch.fulfillRequest', {
          requestId, responseCode: 200,
          responseHeaders: [{ name: 'Content-Type', value: 'application/json' }],
          body: jsonBody(meOverride),
        });
        return;
      }
      await cdp.send('Fetch.continueRequest', { requestId });
      return;
    }
    const stub = LIVE ? null : stubFor(method, url, request.postData);
    if (!stub) {
      await cdp.send('Fetch.continueRequest', { requestId });
      return;
    }
    await cdp.send('Fetch.fulfillRequest', {
      requestId,
      responseCode: stub.code ?? 200,
      responseHeaders: [
        { name: 'Content-Type', value: stub.type },
        { name: 'Cache-Control', value: 'no-store' },
      ],
      body: stub.body,
    });
  } catch (e) {
    // 兜底：任何打桩失败都必须把请求放行，否则页面会一直挂着等
    try { await cdp.send('Fetch.continueRequest', { requestId }); } catch { /* ignore */ }
    console.log(`     [打桩异常] ${method} ${url}: ${e?.message ?? e}`);
  }
}

/* ================================================================== 页面内探针 */
/**
 * 布局探针（②b）：`:scroll-x` 区域能不能真横向滚动 + 操作列（含表头）是不是**固定右侧**。
 * 结构（naive-ui 2.4x，实测）：
 *   `.n-data-table-base-table` → 表体 `.n-data-table-base-table-body`（内部 `.n-scrollbar-container`
 *   才是真滚动容器）；**没设 max-height/flex-height 时表头被渲染在表体同一个滚动容器里**
 *   （`MainTable` 的 `headerInBody`）→ 此时 `.n-data-table-base-table-header` 根本不存在，
 *   不能用"表头 scrollLeft 是否同步"来断，改成断**表头首列跟着左移**（错位会立刻被抓到）。
 *   固定列 = 该格 `position: sticky; right: 0`（`n-data-table-td--fixed-right` / `-th--fixed-right`）。
 */
const LAYOUT_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const body = document.querySelector('.n-data-table-base-table-body');
  const container = body ? (body.querySelector('.n-scrollbar-container') || body) : null;
  const separateHead = document.querySelector('.n-data-table-base-table-header');
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  const firstTr = trs[0] || null;
  const tds = firstTr ? [...firstTr.querySelectorAll('.n-data-table-td')] : [];
  const opTd = tds.length ? tds[tds.length - 1] : null;
  const ths = [...document.querySelectorAll('.n-data-table-thead .n-data-table-th')];
  const firstTh = ths[0] || null;
  const opTh = ths.length ? ths[ths.length - 1] : null;
  const payeeTd = tds[2] || null;
  const box = container ? container.getBoundingClientRect() : null;
  const rect = (el) => { const r = el && el.getBoundingClientRect(); return r ? { left: r.left, right: r.right, width: r.width } : null; };
  const cs = opTd ? getComputedStyle(opTd) : null;
  const payeeCs = payeeTd ? getComputedStyle(payeeTd) : null;
  return {
    found: !!container,
    containerCls: container ? String(container.className) : '',
    headMode: separateHead ? 'separate' : 'inBody',
    scrollWidth: container ? container.scrollWidth : 0,
    clientWidth: container ? container.clientWidth : 0,
    xScrollable: !!container && container.scrollWidth > container.clientWidth + 2,
    opSticky: cs ? cs.position : '',
    opFixedCls: opTd ? String(opTd.className) : '',
    opThFixedCls: opTh ? String(opTh.className) : '',
    opRightGap: box && opTd ? Math.round(box.right - opTd.getBoundingClientRect().right) : null,
    opThRightGap: box && opTh ? Math.round(box.right - opTh.getBoundingClientRect().right) : null,
    firstThLeft: rect(firstTh) ? Math.round(rect(firstTh).left) : null,
    opText: txt(opTd),
    opButtons: opTd ? [...opTd.querySelectorAll('button')].map((b) => txt(b)) : [],
    opBtnVisible: opTd
      ? [...opTd.querySelectorAll('button')].every((b) => {
          const r = b.getBoundingClientRect();
          return r.width > 0 && (!box || (r.left >= box.left - 1 && r.right <= box.right + 1));
        })
      : false,
    payeeText: txt(payeeTd),
    payeeCellWidth: payeeTd ? payeeTd.clientWidth : 0,
    payeeScrollWidth: payeeTd ? payeeTd.scrollWidth : 0,
    payeeWhiteSpace: payeeCs ? payeeCs.whiteSpace : '',
    payeeRight: rect(payeeTd) ? Math.round(rect(payeeTd).right) : null,
  };
})()`;

/** 滚动一次并读回：表体真的滚了 + 表头首列跟着左移（同容器）+ 固定列右缘仍贴住可视区 */
const SCROLL_PROBE = (px) => `(() => {
  const body = document.querySelector('.n-data-table-base-table-body');
  const container = body ? (body.querySelector('.n-scrollbar-container') || body) : null;
  const separateHead = document.querySelector('.n-data-table-base-table-header');
  if (!container) return { ok: false, reason: '找不到表体滚动容器' };
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const ths = [...document.querySelectorAll('.n-data-table-thead .n-data-table-th')];
  const firstTh = ths[0] || null;
  const opTh = ths.length ? ths[ths.length - 1] : null;
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  const tds = trs[0] ? [...trs[0].querySelectorAll('.n-data-table-td')] : [];
  const opTd = tds.length ? tds[tds.length - 1] : null;
  const containerBox = container.getBoundingClientRect();
  container.scrollLeft = ${px};
  container.dispatchEvent(new Event('scroll', { bubbles: true }));
  const btn = opTd ? [...opTd.querySelectorAll('button')].find((b) => txt(b) === '处理') : null;
  const br = btn ? btn.getBoundingClientRect() : null;
  return {
    ok: true,
    scrollLeftBody: container.scrollLeft,
    scrollLeftHead: separateHead ? separateHead.scrollLeft : null,
    headMode: separateHead ? 'separate' : 'inBody',
    firstThLeftAfter: firstTh ? Math.round(firstTh.getBoundingClientRect().left) : null,
    opThRightGap: opTh ? Math.round(containerBox.right - opTh.getBoundingClientRect().right) : null,
    opRightGap: opTd ? Math.round(containerBox.right - opTd.getBoundingClientRect().right) : null,
    opText: txt(opTd),
    payBtnVisible: !!br && br.width > 0 && br.left >= containerBox.left - 1 && br.right <= containerBox.right + 1,
    scrollTop: container.scrollTop,
  };
})()`;

/** 表格快照：每行的单元格文字 / 按钮 / 标签（标签带**计算后的颜色**，用来断"状态色对不对"） */
const TABLE_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  /* 取设计 token 的计算值：标签色必须等于 --color-warning / --color-success / --color-error */
  const tok = (name) => {
    const d = document.createElement('div');
    d.style.color = 'var(' + name + ')';
    document.body.appendChild(d);
    const c = getComputedStyle(d).color;
    d.remove();
    return c;
  };
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  const headers = [...document.querySelectorAll('.n-data-table-thead .n-data-table-th')].map((th) => txt(th));
  return {
    path: location.pathname,
    h1: txt(document.querySelector('.withdraw-page h1, h1')),
    headers,
    tokens: { warning: tok('--color-warning'), success: tok('--color-success'), error: tok('--color-error') },
    rows: trs.map((tr) => {
      const tds = [...tr.querySelectorAll('.n-data-table-td')];
      return {
        cells: tds.map((td) => txt(td)),
        buttons: [...tr.querySelectorAll('button')].map((b) => txt(b)),
        tags: [...tr.querySelectorAll('.n-tag')].map((t) => ({
          text: txt(t),
          cls: String(t.className),
          color: getComputedStyle(t).color,
          border: getComputedStyle(t).borderTopColor,
        })),
      };
    }),
    pendingChip: txt(document.querySelector('.pending-chip')),
    bodyText: (document.body.innerText || '').replace(/\\s+/g, ' '),
  };
})()`;

/** 侧栏「资金与抽成」组的子项 */
const GROUP_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const box = document.querySelector('.nav-children[data-nav-children="资金与抽成"]');
  const item = document.querySelector('.nav-child[data-nav-item="withdraw"]');
  return {
    groupExists: !!document.querySelector('.nav-parent[data-nav-group="资金与抽成"]'),
    children: box ? [...box.querySelectorAll('.nav-child')].map((c) => ({ key: c.getAttribute('data-nav-item'), label: txt(c) })) : [],
    withdrawItem: item ? { label: txt(item), visible: item.getClientRects().length > 0 } : null,
  };
})()`;

/** 抽屉快照：标题 / 各块文字 / 按钮（含 disabled）/ 收款码图状态 */
const DRAWER_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const drawer = document.querySelector('.n-drawer');
  if (!drawer) return { open: false };
  const btns = [...drawer.querySelectorAll('button')].map((b) => ({
    text: txt(b),
    disabled: b.disabled === true || b.classList.contains('n-button--disabled'),
  }));
  const img = drawer.querySelector('.qr-img img');
  const amount = drawer.querySelector('.amount-line');
  const rejectBox = drawer.querySelector('.reject-input textarea');
  return {
    open: true,
    head: txt(drawer.querySelector('.n-drawer-header')),
    body: txt(drawer),
    buttons: btns,
    kv: [...drawer.querySelectorAll('.kv dt')].map((dt) => txt(dt)),
    amount: txt(amount),
    qrSrc: img ? img.getAttribute('src') : null,
    qrLoaded: !!(img && img.naturalWidth > 0),
    rejectValue: rejectBox ? rejectBox.value : null,
  };
})()`;

/** 弹层（n-dialog / n-modal）快照 */
const DIALOG_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const dlg = document.querySelector('.n-dialog');
  if (!dlg) return { open: false };
  return { open: true, text: txt(dlg), buttons: [...dlg.querySelectorAll('button')].map((b) => txt(b)) };
})()`;

/** 点一个按钮（按可见文字，可限定作用域；作用域取不到时返回 NO_SCOPE 而不是抛异常） */
const clickByText = (text, scope = 'document') => `(() => {
  const root = ${scope};
  if (!root) return 'NO_SCOPE';
  const b = [...root.querySelectorAll('button')].find((x) => (x.innerText || '').replace(/\\s+/g, '') === ${JSON.stringify(text.replace(/\s+/g, ''))});
  if (!b) return 'NOT_FOUND';
  if (b.disabled) return 'DISABLED';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

/**
 * 轮询页面里的一个布尔表达式（抽屉/弹层是异步挂载的，固定 sleep 会随机假红 —— 实测踩过一次）。
 * 断言前用它等"元素真的在"，而不是"睡够 1.6 秒大概就在了"。
 */
async function waitFor(cdp, expr, { timeout = 8000, step = 200 } = {}) {
  const t0 = Date.now();
  for (;;) {
    let ok = false;
    try {
      ok = await cdp.evalJs(`(() => { try { return !!(${expr}); } catch { return false; } })()`);
    } catch { ok = false; }
    if (ok) return true;
    if (Date.now() - t0 > timeout) return false;
    await sleep(step);
  }
}

/** 轮询 Node 侧条件（如"打桩记到了 pay 请求"） */
async function waitUntil(fn, { timeout = 6000, step = 150 } = {}) {
  const t0 = Date.now();
  for (;;) {
    if (fn()) return true;
    if (Date.now() - t0 > timeout) return false;
    await sleep(step);
  }
}

/** 往 textarea 写值（走原生 setter，保证 v-model 收得到） */
const fillTextarea = (sel, value) => `(() => {
  const el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return 'NOT_FOUND';
  const d = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
  d.set.call(el, ${JSON.stringify(value)});
  el.dispatchEvent(new Event('input', { bubbles: true }));
  return 'OK';
})()`;

const closeDialog = `(() => {
  const dlg = document.querySelector('.n-dialog');
  if (!dlg) return 'NO_DIALOG';
  const b = [...dlg.querySelectorAll('button')].find((x) => /取消/.test(x.innerText || ''));
  if (!b) return 'NO_CANCEL';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

async function apiLogin() {
  const r = await fetch(API + '/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: USER, password: PASS, role: 'admin' }),
    signal: AbortSignal.timeout(15000),
  });
  const text = await r.text();
  let j = null; try { j = JSON.parse(text); } catch { /* ignore */ }
  return { status: r.status, token: j?.data?.accessToken ?? null, isOwner: j?.data?.isOwner ?? null, raw: text.slice(0, 200) };
}

/** 打开某一行（第 idx 行，0 基）的「处理」按钮 */
const openRowDetail = (idx, label = '处理') => `(() => {
  const trs = [...document.querySelectorAll('.n-data-table-tbody .n-data-table-tr')];
  const tr = trs[${idx}];
  if (!tr) return 'NO_ROW';
  const b = [...tr.querySelectorAll('button')].find((x) => (x.innerText || '').trim() === ${JSON.stringify(label)});
  if (!b) return 'NO_BUTTON';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

// ------------------------------------------------------------------ 主流程
const PROFILE = os.tmpdir() + '/fish-edge-withdraw-' + Date.now();
let browser = null;

async function main() {
  console.log(`[配置] UI=${UI} API=${API} dist=${DIST_ORIGIN} 窗口=${WIDTH}x${HEIGHT}`);
  console.log(`[模式] ${LIVE ? '真后端（VWD_LIVE=1，不打桩）' : '打桩（网络层 mock /admin/withdraw/*）'}${MUTATE ? ' · 变异：去掉 canPay 判断 → ⑥ 必须红' : ''}${MUTATE_MASK ? ' · 变异：取值改回 accountMasked → ② 必须红' : ''}`);
  console.log(`[截图] ${SHOT_DIR}`);
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
  await cdp.send('DOM.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false });
  cdp.on('Fetch.requestPaused', (p) => onRequestPaused(cdp, p));
  // 只拦需要的三条（全量拦会让每次页面加载都慢一个数量级）
  await cdp.send('Fetch.enable', {
    patterns: [
      { urlPattern: '*api/v1/admin/withdraw*', requestStage: 'Request' },
      { urlPattern: '*api/v1/admin/media/upload', requestStage: 'Request' },
      { urlPattern: '*api/v1/media/protected/*', requestStage: 'Request' },
      { urlPattern: '*api/v1/auth/me', requestStage: 'Request' },
    ],
  });

  /* ---------------------------------------------------------- 登录（专用测试超管） */
  hr('登录（专用测试超管，绝不用 kslingyun）');
  const who = await apiLogin();
  console.log(`     [账号] ${USER}（isOwner=${who.isOwner}）`);
  if (!who.token) throw new Error(`测试超管 ${USER} 登录失败，无法继续（HTTP ${who.status}）：${who.raw}`);
  await cdp.send('Page.navigate', { url: `${UI}/login` });
  await sleep(2200);
  // 清干净上一次运行留下的令牌/主题/标签页 → 本套件可重复跑且结果确定（默认浅色档）
  await cdp.evalJs(`localStorage.clear(); sessionStorage.clear(); localStorage.setItem('fish_admin_token', ${JSON.stringify(who.token)}); 'ok'`);

  /**
   * 打开提现审核页。
   * 并行环境铁律的落地：本机多批次共用同一个专用测试超管（`opsadmin`），
   * 别人一登录就把本套件的会话顶掉（docs/04 单设备铁律）→ 落到 /login 时**最多重登一次**，
   * 再被顶就如实中断（绝不无限重登，也不静默假装通过）。
   */
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

  /* ---------------------------------------------------------- ① 菜单归组 */
  hr('① 菜单出现在「资金与抽成」组下');
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', JSON.stringify(['资金与抽成'])); 'ok'`);
  await gotoWithdraw();
  const grp = await cdp.evalJs(GROUP_PROBE);
  const mf = [];
  if (!grp.groupExists) mf.push('侧栏找不到「资金与抽成」分组');
  if (!grp.withdrawItem) mf.push('「资金与抽成」组下没有「提现审核」子项（data-nav-item="withdraw"）');
  else {
    if (grp.withdrawItem.label !== '提现审核') mf.push(`子项文字 = 「${grp.withdrawItem.label}」，期望「提现审核」`);
    if (!grp.withdrawItem.visible) mf.push('「提现审核」子项渲染了但不可见/点不到');
  }
  const keys = grp.children.map((c) => c.key);
  if (!(keys.includes('wallets') && keys.includes('recharge') && keys.includes('withdraw') && keys.includes('commission'))) {
    mf.push(`同组并列的子项不齐：${JSON.stringify(grp.children.map((c) => c.label))}`);
  }
  record('① 侧栏「资金与抽成」组下的「提现审核」', mf, {
    分组子项: grp.children.map((c) => c.label).join(' · '),
  });

  /* ---------------------------------------------------------- ② 页面 + 列表 */
  hr('② 页面可打开 + 列表渲染');
  const probe1 = await cdp.evalJs(TABLE_PROBE);
  const shotList = await cdp.shot('01-列表-浅色.png', { beyond: true });
  const lf = [];
  if ((probe1.h1 || '') !== '提现审核') lf.push(`页头 h1 = 「${probe1.h1}」，期望「提现审核」`);
  if (!LIVE) {
    if (probe1.rows.length !== FIX_ROWS.length) lf.push(`列表行数 = ${probe1.rows.length}，期望 ${FIX_ROWS.length}`);
  } else if (probe1.rows.length === 0) {
    // 真后端空库：必须渲染**空态**（而不是报错）—— 读路径通不通，这条比行数更能说明问题
    const emptyText = await cdp.evalJs(
      `(() => { const e = document.querySelector('.empty'); return e ? (e.innerText || '').replace(/\\s+/g, ' ').trim() : ''; })()`,
    );
    if (!emptyText.includes('还没有提现申请')) lf.push(`真后端空库时没渲染空态（.empty = 「${emptyText}」）`);
  }
  const headers = probe1.headers.join('|');
  for (const want of ['打手', '金额', '收款信息', '状态', '申请时间', '操作']) {
    if (!headers.includes(want)) lf.push(`表头缺列「${want}」（实际：${headers}）`);
  }
  if (/脱敏/.test(headers)) lf.push(`表头仍然写着「脱敏」（实际：${headers}）——列标题必须是「收款信息」`);
  // 待处理数量：打桩模式断具体数字（1），真后端模式断"是个数字而不是 —"（取不到时页面显示 —）
  const chip = flat(probe1.pendingChip);
  if (!chip.includes('待处理') || !/待处理\s*\d+\s*笔/.test(chip)) {
    lf.push(`页头待处理数量 = 「${probe1.pendingChip}」，期望形如「待处理 N 笔」（N 为数字）`);
  } else if (!LIVE && !chip.includes('待处理 1 笔')) {
    lf.push(`页头待处理数量 = 「${probe1.pendingChip}」，期望「待处理 1 笔」`);
  }
  // 行内容断言只在真的有样本时做（真后端空库时本来就没行）
  /** **完整值口径**这一条的失败项（②b 的变异探针只看这一组：改回 accountMasked 必须让它红） */
  const lv = [];
  if (probe1.rows[0]) {
    // 打手列 = 昵称 + 工号
    if (!LIVE && (!probe1.rows[0].cells[0]?.includes('夜航船') || !probe1.rows[0].cells[0]?.includes('W-20418'))) {
      lf.push(`第一行「打手」格 = 「${probe1.rows[0].cells[0]}」，期望含昵称与工号`);
    }
    // ②b 收款信息列必须是**完整**值（负责人 2026-10-11：列表直接看全部，不再打码）
    const payeeCell = flat(probe1.rows[0].cells[2]);
    if (LIVE) {
      // 真后端：服务端列表接口这一批才新增 `account` 完整值 → 断"是 11 位真手机号"
      if (!/1[3-9]\d{9}/.test(payeeCell)) {
        lv.push(
          `第一行收款信息 = 「${payeeCell}」，里面没有完整 11 位手机号` +
            '（真后端模式下若服务端列表接口还没下发 account，本组会红 —— 前端回退逻辑本身见 ②c）',
        );
      }
    } else {
      if (!payeeCell.includes('13812346621')) {
        lv.push(`第一行收款信息 = 「${payeeCell}」，期望含**完整**手机号 13812346621（新契约 account 字段）`);
      }
      if (!/1[3-9]\d{9}/.test(payeeCell)) lv.push(`第一行收款信息 = 「${payeeCell}」，不是 11 位完整手机号`);
      if (/138\*{4}6621/.test(payeeCell)) lv.push(`第一行收款信息 = 「${payeeCell}」，还在显示打码串 138****6621`);
      // 姓名与微信号也要完整（三格一行：姓名 · 电话 · 微信号）
      for (const want of ['李承霖', 'lxz_88']) {
        if (!payeeCell.includes(want)) lv.push(`第一行收款信息 = 「${payeeCell}」，缺完整「${want}」`);
      }
    }
    if (!payeeCell || payeeCell === '—') lv.push('第一行「收款信息」是空的（完整/回退字段都没归一出来）');
    // 列表页文字里不许再出现任何打码串（`138****6621` 这类）或「脱敏」字样
    const maskedHit = flat(probe1.bodyText).match(/\d{3}\*{2,}\d{4}|[\u4e00-\u9fa5]\*{1,3}/);
    if (maskedHit) lv.push(`列表页正文里出现了打码串「${maskedHit[0]}」（列表口径应为完整值）`);
    if (/脱敏/.test(probe1.bodyText)) lv.push('列表页正文里仍然出现「脱敏」字样（口径应改为完整）');
  }
  lf.push(...lv);
  record('② 页面可打开 + 列表渲染（表头/行数/待处理数量/完整收款信息）', lf, {
    页头: probe1.h1, 待处理: probe1.pendingChip, 行数: probe1.rows.length,
    表头: headers,
    第一行: probe1.rows[0]?.cells.join(' | ') ?? '（空库）',
    截图: shotList,
  });

  /* ---------------------------------------------------------- ②b 列宽 / 横向滚动 / 操作列固定 */
  hr('②b 收款信息列完整值 · :scroll-x 可横向滚动 · 操作列仍固定右侧');
  const layoutF = [];
  const wide = await cdp.evalJs(LAYOUT_PROBE);
  // 宽屏（默认窗口）：操作列固定右侧、右缘贴住可视区
  if (!wide.found) layoutF.push('找不到表格滚动容器（.n-data-table-base-table-body）');
  if (wide.opSticky !== 'sticky') layoutF.push(`宽屏操作列 position = ${wide.opSticky}，期望 sticky（固定右侧）`);
  if (!String(wide.opFixedCls).includes('fixed-right')) {
    layoutF.push(`宽屏操作列格类名 = 「${wide.opFixedCls}」，期望含 n-data-table-td--fixed-right`);
  }
  if (!String(wide.opThFixedCls).includes('fixed-right')) {
    layoutF.push(`宽屏表头操作列类名 = 「${wide.opThFixedCls}」，期望含 n-data-table-th--fixed-right`);
  }
  if (wide.opRightGap === null || Math.abs(wide.opRightGap) > 1) {
    layoutF.push(`宽屏操作列右缘与可视区右缘间距 = ${wide.opRightGap}px，期望 ≈0（固定住了）`);
  }
  // 窄屏（900）：列宽和 984 > 可视区 → 必须能横向滚动，且滚动后操作列仍完整可见
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 900, height: HEIGHT, deviceScaleFactor: 1, mobile: false });
  await sleep(900);
  const narrow = await cdp.evalJs(LAYOUT_PROBE);
  const scrolled = await cdp.evalJs(SCROLL_PROBE(120));
  await sleep(250);
  const afterScroll = await cdp.evalJs(LAYOUT_PROBE);
  const shotNarrow = await cdp.shot('12b-窄屏-横向滚动-操作列仍固定.png');
  if (!narrow.xScrollable) {
    layoutF.push(
      `窄屏（900）下 :scroll-x 区域**滚不动**：scrollWidth=${narrow.scrollWidth} clientWidth=${narrow.clientWidth}` +
        `（列宽和 984 应大于可视区）`,
    );
  }
  if (narrow.payeeCellWidth < 300) {
    layoutF.push(`窄屏收款信息格宽 = ${narrow.payeeCellWidth}px，期望 ≥300（minWidth 生效）`);
  }
  if (/1[3-9]\d{9}/.test(flat(narrow.payeeText)) && narrow.payeeScrollWidth > narrow.payeeCellWidth + 2) {
    layoutF.push(
      `窄屏收款信息格文字溢出格宽（cell=${narrow.payeeCellWidth} scroll=${narrow.payeeScrollWidth}）→ 破版`,
    );
  }
  if (!scrolled.ok) layoutF.push(`横向滚动失败：${scrolled.reason}`);
  else {
    if (!(scrolled.scrollLeftBody > 0)) layoutF.push(`设置 scrollLeft=120 后读回 ${scrolled.scrollLeftBody}（没滚动）`);
    if (scrolled.headMode === 'separate') {
      // 表头独立滚动容器（设了 max-height/flex-height 时才是这种结构）：两边必须同步
      if (scrolled.scrollLeftHead === null || Math.abs(scrolled.scrollLeftHead - scrolled.scrollLeftBody) > 2) {
        layoutF.push(`表头没跟着横向滚动：body=${scrolled.scrollLeftBody} head=${scrolled.scrollLeftHead}（表头表体会错位）`);
      }
    } else {
      // 表头在表体同一个滚动容器里（本页的实际结构）：断**表头首列跟着左移**，错位会立刻暴露
      if (!(narrow.firstThLeft !== null && scrolled.firstThLeftAfter !== null && scrolled.firstThLeftAfter <= narrow.firstThLeft - 40)) {
        layoutF.push(
          `表头没跟着横向滚动：首列表头 left ${narrow.firstThLeft} → ${scrolled.firstThLeftAfter}（应左移约 120px）`,
        );
      }
    }
    if (scrolled.opRightGap === null || Math.abs(scrolled.opRightGap) > 1) {
      layoutF.push(`滚动后操作列右缘间距 = ${scrolled.opRightGap}px，期望 ≈0（操作列不许被滚出去）`);
    }
    if (scrolled.opThRightGap === null || Math.abs(scrolled.opThRightGap) > 1) {
      layoutF.push(`滚动后操作列**表头**右缘间距 = ${scrolled.opThRightGap}px，期望 ≈0（表头也要固定住）`);
    }
    if (!scrolled.payBtnVisible) layoutF.push('滚动后「处理」按钮跑出可视区（操作列没有固定住）');
    if (!String(scrolled.opText).includes('处理')) layoutF.push(`滚动后操作列文字 = 「${scrolled.opText}」，期望含「处理」`);
  }
  if (afterScroll.opSticky !== 'sticky') layoutF.push(`滚动后操作列 position = ${afterScroll.opSticky}，期望 sticky`);
  if (!(afterScroll.payeeRight > 0)) layoutF.push('滚动后收款信息格坐标异常（布局塌了）');
  // 还原窗口尺寸（后续断言与截图都按默认窗口）
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false });
  await sleep(700);
  const restored = await cdp.evalJs(LAYOUT_PROBE);
  if (restored.opSticky !== 'sticky') layoutF.push(`还原窗口后操作列 position = ${restored.opSticky}，期望 sticky`);
  record('②b 完整值列宽 · 横向滚动 · 操作列固定右侧', layoutF, {
    宽屏: `列宽和(最小)=984 窗口=${WIDTH} 操作列=${wide.opSticky} 右缘间距=${wide.opRightGap}px`,
    窄屏: `窗口=900 可横向滚动=${narrow.xScrollable} scrollWidth=${narrow.scrollWidth}/clientWidth=${narrow.clientWidth}` +
      ` → scrollLeft=${scrolled.scrollLeftBody}（表头 ${scrolled.scrollLeftHead}）操作列右缘间距=${scrolled.opRightGap}px`,
    收款信息格: `宽=${narrow.payeeCellWidth} 文字「${flat(narrow.payeeText)}」`,
    截图: shotNarrow,
  });

  /* ---------------------------------------------------------- ②c 回退：服务端未更新时不裂 */
  hr('②c 回退口径：服务端列表只有 accountMasked 时，该列回退显示且不空');
  const fallbackF = [];
  if (LIVE) {
    console.log('     [跳过] 真后端模式：回退路径由打桩模式的 ②c 覆盖（这里不改服务端数据）');
  } else {
    listAccountShape = 'maskedOnly';
    await gotoWithdraw();
    const probeFb = await cdp.evalJs(TABLE_PROBE);
    const fbCell = flat(probeFb.rows[0]?.cells[2]);
    if (!fbCell || fbCell === '—') {
      fallbackF.push('服务端没下发 account（只有 accountMasked）时，收款信息列是空的 → 页面裂了');
    }
    if (!fbCell.includes('138****6621')) {
      fallbackF.push(`回退后的收款信息 = 「${fbCell}」，期望逐字段回退到脱敏串 138****6621`);
    }
    listAccountShape = 'full';
    await gotoWithdraw();
  }
  record('②c 回退（account 取不到 → accountMasked，不裂）', fallbackF, {
    模式: LIVE ? '（真后端跳过）' : '打桩 maskedOnly',
  });

  /* ================================================================ 变异模式（完整值）到此为止
   * 把 `WithdrawView.vue` 的取值改回 `accountMasked`（列表继续打码）后 ② 必须红；
   * 只跑 ②/②b 并把结论打成 RED/GREEN 两行（见文件头 `--mutate-masked-account`）。
   */
  if (MUTATE_MASK) {
    hr('变异结论（--mutate-masked-account）');
    const cellText = flat(probe1.rows[0]?.cells[2]);
    const caught = lv.length > 0;
    console.log(`[收款信息列] 第一行 = 「${cellText}」（期望完整 11 位手机号；变异后应变成打码串）`);
    if (!probe1.rows[0]) {
      console.log('⚠️ 列表里没有任何行 → 这条探针本轮无效（变异模式请配合打桩模式跑：不要设 VWD_LIVE=1）');
    } else {
      console.log(caught
        ? '🔴 RED：② 命中 —— 列表又显示打码串/没有完整手机号（取值确实被改回了 accountMasked，断言有效）'
        : '🟢 GREEN：② 仍然全绿 —— 变异**没有**被断言抓到，说明这条断言不起作用，必须查');
    }
    fs.writeFileSync(path.join(SHOT_DIR, 'probe-mutation-masked-account.json'),
      JSON.stringify({ mutate: true, verdict: caught ? 'RED' : 'GREEN', payeeCell: cellText, fails: lv }, null, 2), 'utf8');
    // 变异命中 = 预期结果（这条探针按设计工作）；只有"没抓到"才算这次探针失败
    if (!caught || !probe1.rows[0]) process.exitCode = 1;
    return;
  }

  /** 库里三种状态的样本一条都没有时，下面这些组**断不了**（真后端未造数据时就是这个状态） */
  const SAMPLES = probe1.rows.length;
  const pendingRow = probe1.rows.find((r) => r.tags[0]?.text === '待处理') ?? null;
  const noSample = (name, extra = {}) =>
    record(name, [`库里没有提现申请样本（VWD_LIVE=1 需要真实数据；打桩模式才有样本）→ 本组断言无效`], extra);

  /* ---------------------------------------------------------- ③ 金额格式 */
  hr('③ 金额 = ¥ + 两位小数 + 千分位');
  const amountCells = probe1.rows.map((r) => r.cells[1]);
  const wantAmounts = ['¥288.50', '¥1,240.00', '¥76.40'];
  const af = [];
  if (SAMPLES < 3) {
    noSample('③ 金额格式（逐字比对 + 正则）', { 金额列: JSON.stringify(amountCells) });
  } else {
    if (JSON.stringify(amountCells) !== JSON.stringify(wantAmounts)) {
      af.push(`金额列 = ${JSON.stringify(amountCells)}，期望 ${JSON.stringify(wantAmounts)}`);
    }
    for (const c of amountCells) {
      if (!/^¥[\d,]+\.\d{2}$/.test(c || '')) af.push(`「${c}」不是 ¥ + 两位小数 + 千分位`);
    }
    record('③ 金额格式（逐字比对 + 正则）', af, { 金额列: amountCells.join(' · ') });
  }

  /* ---------------------------------------------------------- ④ 状态标签 */
  hr('④ 状态标签（文字 + 颜色）');
  const sf = [];
  /**
   * 状态色断的是**计算后的文字色**，不是 class 名：
   * naive 2.45 的 Tag 只给根元素一个 `n-tag` 类（type 走 CSS-in-JS 变量），拿 `--warning-type` 断会假红
   * （首次实测三条全红就是踩了这个）。颜色则直接从设计 token 取（浅/深两档各有一套值），
   * 断"待处理=warning / 已打款=success / 已驳回=error"这条语义是稳的。
   */
  const wantTags = [
    { text: '待处理', color: probe1.tokens.warning },
    { text: '已打款', color: probe1.tokens.success },
    { text: '已驳回', color: probe1.tokens.error },
  ];
  probe1.rows.forEach((r, i) => {
    const tag = r.tags[0];
    if (!tag) { sf.push(`第 ${i + 1} 行没有状态标签`); return; }
    if (tag.text !== wantTags[i].text) sf.push(`第 ${i + 1} 行状态文字 = 「${tag.text}」，期望「${wantTags[i].text}」`);
    if (tag.color !== wantTags[i].color) {
      sf.push(`第 ${i + 1} 行状态色 = ${tag.color}，期望 ${wantTags[i].color}（${wantTags[i].text} 对应的 token）`);
    }
  });
  const colors = probe1.rows.map((r) => r.tags[0]?.color);
  if (new Set(colors).size !== 3) sf.push(`三种状态的标签色没有互不相同：${JSON.stringify(colors)}（状态色分不出来）`);
  if (SAMPLES < 3) noSample('④ 状态标签（文字 + 计算色 = 设计 token）', { 行数: SAMPLES });
  else {
    record('④ 状态标签（文字 + 计算色 = 设计 token）', sf, {
      逐行: probe1.rows.map((r) => `${r.tags[0]?.text}(${r.tags[0]?.color})`).join(' · '),
      token: `warning=${probe1.tokens.warning} success=${probe1.tokens.success} error=${probe1.tokens.error}`,
    });
  }

  /* ---------------------------------------------------------- ⑤ 状态守卫 */
  hr('⑤ 非 pending 行没有任何操作按钮');
  const gf = [];
  const [row1, row2, row3] = probe1.rows;
  if (row2?.buttons.length) gf.push(`已打款行的操作列出现了按钮：${JSON.stringify(row2.buttons)}`);
  if (row3?.buttons.length) gf.push(`已驳回行的操作列出现了按钮：${JSON.stringify(row3.buttons)}`);
  if (!flat(row2?.cells[5]).includes('已打款（不可重复打款）')) gf.push(`已打款行只读文案 = 「${row2?.cells[5]}」`);
  if (!flat(row3?.cells[5]).includes('已驳回（不可重复处理）')) gf.push(`已驳回行只读文案 = 「${row3?.cells[5]}」`);
  if (!row1?.buttons.includes('处理')) gf.push(`待处理行缺「处理」按钮（实际 ${JSON.stringify(row1?.buttons)}）`);
  if (!row1?.buttons.includes('驳回')) gf.push(`待处理行缺「驳回」按钮（实际 ${JSON.stringify(row1?.buttons)}）`);
  if (SAMPLES < 3) noSample('⑤ 状态守卫（非 pending 只读、pending 才有操作）', { 行数: SAMPLES });
  else {
    record('⑤ 状态守卫（非 pending 只读、pending 才有操作）', gf, {
      pending行: JSON.stringify(row1?.buttons), 已打款行: JSON.stringify(row2?.buttons), 已驳回行: JSON.stringify(row3?.buttons),
    });
  }

  /* ---------------------------------------------------------- ⑥ 权限渲染 */
  hr('⑥ 权限渲染：无 withdraw:pay 的账号看不到打款/驳回按钮');
  const REVIEW_ONLY_ME = {
    id: 'u-ops-review', username: 'ops_review', uid: 'ops_review', nickname: '运营-小祁（无打款权限）',
    role: 'admin', admin: { roleCode: 'operator', permissions: ['withdraw:review'], isOwner: false },
  };
  meOverride = REVIEW_ONLY_ME;
  await gotoWithdraw();
  const probeR = await cdp.evalJs(TABLE_PROBE);
  const rowR = probeR.rows[0] ?? { buttons: [] };
  const sixF = [];
  // 真后端空库时这一组**断不了**（没有待处理行可点）→ 如实报"无样本"，不假装通过
  const canProbePerm = probeR.rows.length > 0;
  if (canProbePerm) {
    if (!rowR.buttons.includes('处理')) sixF.push(`无 pay 账号连「处理」都不见了（实际 ${JSON.stringify(rowR.buttons)}）`);
    if (rowR.buttons.includes('驳回')) sixF.push('无 pay 账号在**列表行内**看到了「驳回」按钮');
    if (rowR.buttons.includes('已提现')) sixF.push('无 pay 账号在**列表行内**看到了「已提现」按钮');
  }
  const openR = canProbePerm ? await cdp.evalJs(openRowDetail(0)) : 'NO_ROW';
  if (canProbePerm) {
    await waitFor(cdp, `document.querySelector('.n-drawer .n-drawer-header')`);
    await waitFor(cdp, `document.querySelector('.n-drawer .kv')`);
    await sleep(400);
  }
  const drawerR = await cdp.evalJs(DRAWER_PROBE);
  if (!canProbePerm) {
    sixF.push('库里没有提现申请样本（VWD_LIVE=1 需要真实数据；打桩模式才有样本）→ 本轮权限渲染断言无效');
  } else {
    if (openR !== 'OK') sixF.push(`无 pay 账号点不开详情（${openR}）`);
    if (!drawerR.open) sixF.push('详情抽屉没打开');
    else {
      const payBtn = drawerR.buttons.filter((b) => b.text === '已提现');
      const rejectBtn = drawerR.buttons.filter((b) => b.text === '驳回');
      if (payBtn.length) sixF.push('抽屉里出现了「已提现」按钮（无 pay 权限不该有）');
      if (rejectBtn.length) sixF.push('抽屉里出现了「驳回」按钮（无 pay 权限不该有）');
      if (!drawerR.body.includes('withdraw:pay')) sixF.push('抽屉里没有说明缺哪个权限点（withdraw:pay）');
      // 收款信息仍要能看（review 权限给了完整姓名/电话/微信号）
      if (!LIVE && (!drawerR.body.includes('李承霖') || !drawerR.body.includes('13812346621'))) {
        sixF.push('无 pay 账号看不到完整收款信息（review 权限应给）');
      }
    }
  }
  const shotPerm = await cdp.shot('08-权限渲染-无pay账号-按钮消失.png');
  record('⑥ 权限渲染（列表 + 抽屉：无 withdraw:pay → 打款/驳回按钮不出现）', sixF, {
    列表按钮: JSON.stringify(rowR.buttons),
    抽屉按钮: drawerR.open ? JSON.stringify(drawerR.buttons.map((b) => b.text)) : '（抽屉没开）',
    缺权限说明: drawerR.open && drawerR.body.includes('withdraw:pay') ? '有' : '无',
    截图: shotPerm,
  });

  /* ---------------------------------------------------------- ⑥b 两个提现权限都没有 → 菜单整项隐藏 */
  hr('⑥b 两个提现权限都没有 → 侧栏「提现审核」整项隐藏（同组其它项仍在）');
  /*
   * 给这个账号留一个**同组**的权限（`admin:order:read` = 抽成中心）：
   * 这样「资金与抽成」这一组**必须继续存在**，而组里唯独 `提现审核` 消失 ——
   * "父项在有子项可见时不许隐藏"这条分组规则也一并被这条断言覆盖（首次实测就是踩了这个：
   * 权限全空时整组消失，那是既有正确行为，不是 bug，但断言写错就会假红）。
   */
  meOverride = { ...REVIEW_ONLY_ME, nickname: '无提现权限账号', admin: { roleCode: 'operator', permissions: ['admin:order:read'], isOwner: false } };
  await gotoWithdraw(2800);
  const grpNone = await cdp.evalJs(GROUP_PROBE);
  const nf = [];
  if (grpNone.withdrawItem) nf.push('两个提现权限都没有，侧栏却仍然渲染了「提现审核」');
  if (!grpNone.groupExists) nf.push('「资金与抽成」分组整个消失了（同组「抽成中心」还有权限，不该消失）');
  if (grpNone.children.length !== 1 || grpNone.children[0]?.key !== 'commission') {
    nf.push(`组内应只剩「抽成中心」，实际：${JSON.stringify(grpNone.children.map((c) => c.label))}`);
  }
  await cdp.evalJs(`sessionStorage.setItem('fish_admin_nav_expanded', JSON.stringify(['资金与抽成'])); 'ok'`);
  const shotNoPerm = await cdp.shot('09-无权限-菜单项隐藏.png');
  record('⑥b 两个提现权限都没有 → 菜单项隐藏（同组其它项仍在）', nf, {
    组内子项: grpNone.children.map((c) => c.label).join(' · ') || '（无）',
    截图: shotNoPerm,
  });

  /* ================================================================ 变异模式到此为止
   * 去掉 canPay 判断后 ⑥ / ⑥b 必须红；只跑这两组，把结论打成 RED/GREEN 两行（见文件头）。
   */
  if (MUTATE) {
    hr('变异结论（--mutate-pay-guard）');
    // 变异模式必须**真的有待处理行**才能判定（空库时"按钮不出现"是废话，会假绿）
    const caught = sixF.length > 0 && canProbePerm;
    console.log(`[权限渲染] 无 pay 账号的列表按钮 = ${JSON.stringify(rowR.buttons)}`);
    if (!canProbePerm) {
      console.log('⚠️ 库里没有待处理行 → 这条探针本轮无效（变异模式请配合打桩模式跑：不要设 VWD_LIVE=1）');
    } else {
      console.log(caught
        ? '🔴 RED：⑥ 命中 —— 无 withdraw:pay 的账号看到了打款/驳回按钮（权限判断确实被去掉了，断言有效）'
        : '🟢 GREEN：⑥ 仍然全绿 —— 变异**没有**被断言抓到，说明这条断言不起作用，必须查');
    }
    fs.writeFileSync(path.join(SHOT_DIR, 'probe-mutation-pay-guard.json'),
      JSON.stringify({ mutate: true, verdict: caught ? 'RED' : 'GREEN', canProbePerm, listButtons: rowR.buttons, fails: sixF }, null, 2), 'utf8');
    // 变异命中 = 预期结果（这条探针按设计工作）；只有"没抓到"才算这次探针失败
    if (!caught) process.exitCode = 1;
    return;
  }

  /* ---------------------------------------------------------- ⑦ 打款链路 */
  hr('⑦ 上传凭证前「已提现」不可用 → 上传后可用 → 二次确认 → 真发出 pay 请求');
  meOverride = null; // 还原成真实超管（有 review + pay）
  await gotoWithdraw();
  /*
   * 真后端空库（`VWD_LIVE=1` 且一条申请都没有）时，⑦⑧ 需要"有一条待处理申请"才能断 →
   * 用**带标签的块**提前跳出并如实报"无样本"（既不伪造通过，也不让空库把整个套件弄崩）。
   * 用标签块而不是 if 包一大段：只为容纳一个空库分支而整体缩进一级，不值。
   */
  payFlow: {
  if (SAMPLES === 0) { noSample('⑦ 打款链路（凭证必填 → 二次确认 → 真发 pay 请求）'); break payFlow; }
  /**
   * ⚠️ **真后端模式默认只读**（本组会真的点「已提现」= 真把钱标记成已打款）。
   * 库里有一笔**负责人要亲手点的演示申请**（id=45）→ 默认绝不在真数据上跑写链路；
   * 确需在真后端演练（例如专门造的一笔测试单）时显式加 `VWD_LIVE_ALLOW_WRITE=1`。
   */
  if (LIVE && process.env.VWD_LIVE_ALLOW_WRITE !== '1') {
    record('⑦ 打款链路（真后端默认只读：不加 VWD_LIVE_ALLOW_WRITE=1 不执行写操作）', [], {
      说明: '本组会真实点击「已提现」→ 默认跳过，避免误改真实申请（打桩模式已完整覆盖本链路）',
    });
    break payFlow;
  }
  const openOk = await cdp.evalJs(openRowDetail(0));
  // 等抽屉与收款码大图都到位（受保护取图是异步 blob，睡固定时间会随机假红）
  await waitFor(cdp, `document.querySelector('.n-drawer .amount-line')`);
  await waitFor(cdp, `(() => { const i = document.querySelector('.qr-img img'); return i && i.naturalWidth > 0; })()`, { timeout: 10000 });
  await sleep(300);
  const dBefore = await cdp.evalJs(DRAWER_PROBE);
  const payBefore = dBefore.buttons.find((b) => b.text === '已提现');
  const pf = [];
  if (openOk !== 'OK') pf.push(`点「处理」失败：${openOk}`);
  if (!dBefore.open) pf.push('详情抽屉没打开');
  if (!payBefore) pf.push('抽屉里没有「已提现」按钮（超管应有打款权限）');
  else if (!payBefore.disabled) pf.push('**还没上传凭证**时「已提现」就是可用状态（要求：上传前必须不可用）');
  if (!dBefore.qrLoaded) pf.push(`收款码大图没加载出来（src=${dBefore.qrSrc}）→ 受保护取图链路有问题`);
  if (!String(dBefore.qrSrc || '').startsWith('blob:')) pf.push(`收款码 src 不是 blob（${dBefore.qrSrc}）→ 说明是直连 URL，不是带令牌取图`);
  if (!dBefore.body.includes('李承霖') || !dBefore.body.includes('lxz_88')) pf.push('抽屉里没有完整收款信息（姓名/微信号）');
  if (!dBefore.body.includes('打款') || !dBefore.body.includes('驳回')) pf.push('抽屉里缺打款区或驳回区');
  const shotDetail = await cdp.shot('02-详情抽屉-收款码与打款区.png');

  // 真上传一张图（CDP 往 n-upload 的 <input type=file> 里塞文件 → MediaUploadField 的 customRequest 会发请求）
  const doc = await cdp.send('DOM.getDocument', { depth: -1 });
  const nodeRes = await cdp.send('DOM.querySelector', { nodeId: doc.root.nodeId, selector: '.n-drawer input[type=file]' });
  if (!nodeRes?.nodeId) pf.push('抽屉里找不到上传用的 input[type=file]');
  else await cdp.send('DOM.setFileInputFiles', { files: [UPLOAD_FILE], nodeId: nodeRes.nodeId });
  await waitUntil(() => captured.uploads >= 1, { timeout: 8000 });
  await waitFor(cdp, `(() => { const b = [...document.querySelectorAll('.n-drawer button')].find((x) => (x.innerText || '').trim() === '已提现'); return b && !b.disabled; })()`, { timeout: 8000 });
  await sleep(300);
  const dAfter = await cdp.evalJs(DRAWER_PROBE);
  const payAfter = dAfter.buttons.find((b) => b.text === '已提现');
  if (captured.uploads < 1) pf.push('选了文件却没发出 POST /admin/media/upload（上传链路断了）');
  if (!payAfter) pf.push('上传后「已提现」按钮消失了');
  else if (payAfter.disabled) pf.push('上传凭证后「已提现」仍然是禁用的（应变为可用）');
  /*
   * 上传后的**缩略图必须真的显示出来**（打款凭证是 protected 用途）：
   * 公开路径 404 → MediaUploadField 必须自动退到带令牌的 `/media/protected/:id`；
   * 两条都不通时退成一行说明文字，**不许留破图**（2026-10-11 首次截图就踩到这个：凭证位一张裂图）。
   */
  const thumb = await cdp.evalJs(`(() => {
    const box = document.querySelector('.n-drawer .media-upload');
    if (!box) return { found: false };
    const img = box.querySelector('img');
    const hint = box.querySelector('.protected-hint');
    return {
      found: true,
      id: (box.querySelector('.media-id') || {}).textContent || '',
      imgShown: !!img && img.getClientRects().length > 0,
      imgLoaded: !!img && img.naturalWidth > 0,
      fallbackHint: hint ? (hint.textContent || '').trim() : null,
    };
  })()`);
  if (!thumb.found) pf.push('抽屉里找不到上传字段（.media-upload）');
  else {
    if (!String(thumb.id).includes('m-proof-1')) pf.push(`上传字段里的媒体 id = 「${thumb.id}」，期望 #m-proof-1`);
    if (!thumb.imgLoaded) {
      pf.push(
        `上传后缩略图没显示（imgShown=${thumb.imgShown} imgLoaded=${thumb.imgLoaded} 兜底说明=${thumb.fallbackHint ?? '无'}）` +
          '→ 受保护图片的令牌取图兜底没生效',
      );
    }
  }

  // 点「已提现」→ 二次确认（含"不可撤销"）
  const clickPay = await cdp.evalJs(clickByText('已提现'));
  await sleep(700);
  const dlgPay = await cdp.evalJs(DIALOG_PROBE);
  if (clickPay !== 'OK') pf.push(`点「已提现」失败：${clickPay}`);
  if (!dlgPay.open) pf.push('「已提现」没有弹二次确认');
  else {
    if (!dlgPay.text.includes('确认后将标记为已打款')) pf.push(`确认框缺「确认后将标记为已打款」（实际：${dlgPay.text.slice(0, 120)}）`);
    if (!dlgPay.text.includes('此操作不可撤销')) pf.push('确认框缺「此操作不可撤销」');
    if (!dlgPay.text.includes('¥288.50')) pf.push('确认框没写清金额（¥288.50）');
  }
  const shotPay = await cdp.shot('03-二次确认-已打款不可撤销.png');
  // 确认 → 必须真的发出 POST pay，且带上刚上传的 proofMediaId
  const confirmPay = `(() => {
    const dlg = document.querySelector('.n-dialog');
    if (!dlg) return 'NO_DIALOG';
    const b = [...dlg.querySelectorAll('button')].find((x) => /确认已打款/.test(x.innerText || ''));
    if (!b) return 'NO_CONFIRM';
    b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return 'OK';
  })()`;
  const doPay = await cdp.evalJs(confirmPay);
  await waitUntil(() => captured.pay !== null, { timeout: 6000 });
  await sleep(600);
  if (doPay !== 'OK') pf.push(`点确认打款失败：${doPay}`);
  if (!captured.pay) pf.push('确认后**没有**发出 POST /admin/withdraw/requests/:id/pay');
  else {
    if (captured.pay.id !== '9001') pf.push(`pay 打到了别的申请上（id=${captured.pay.id}）`);
    if (!captured.pay.body?.proofMediaId) pf.push(`pay 请求体缺 proofMediaId（实际 ${JSON.stringify(captured.pay.body)}）`);
  }
  record('⑦ 打款链路（凭证必填 → 二次确认 → 真发 pay 请求）', pf, {
    上传次数: captured.uploads,
    pay请求: captured.pay ? JSON.stringify(captured.pay) : '（没发出）',
    截图: `${path.basename(shotDetail)} / ${path.basename(shotPay)}`,
  });
  }

  /* ---------------------------------------------------------- ⑧ 驳回二次确认 */
  hr('⑧ 驳回二次确认含「余额将退回打手」');
  rejectFlow: {
  if (SAMPLES === 0) { noSample('⑧ 驳回二次确认（余额退回打手 + 金额）'); break rejectFlow; }
  // 同 ⑦：真后端默认只读（本组会真的点「驳回」= 真退余额）；演示申请绝不能被本脚本动到
  if (LIVE && process.env.VWD_LIVE_ALLOW_WRITE !== '1') {
    record('⑧ 驳回二次确认（真后端默认只读：不加 VWD_LIVE_ALLOW_WRITE=1 不执行写操作）', [], {
      说明: '本组会真实点击「驳回」→ 默认跳过，避免误改真实申请（打桩模式已完整覆盖本链路）',
    });
    break rejectFlow;
  }
  await gotoWithdraw();
  await cdp.evalJs(openRowDetail(0));
  await waitFor(cdp, `document.querySelector('.reject-input textarea')`, { timeout: 8000 });
  const fillReject = await cdp.evalJs(fillTextarea('.reject-input textarea', '收款码与姓名不一致，请换成本人收款码重新申请'));
  // 驳回按钮 `:disabled="!rejectReason.trim()"`：等它真的变可用再点（否则点到禁用态 = 假红）
  await waitFor(cdp, `(() => { const b = [...document.querySelectorAll('.n-drawer button')].find((x) => (x.innerText || '').trim() === '驳回'); return b && !b.disabled; })()`, { timeout: 6000 });
  const clickReject = await cdp.evalJs(clickByText('驳回', `document.querySelector('.n-drawer')`));
  await waitFor(cdp, `document.querySelector('.n-dialog')`, { timeout: 6000 });
  const dlgReject = await cdp.evalJs(DIALOG_PROBE);
  const rf = [];
  if (fillReject !== 'OK') rf.push(`驳回原因输入框填不进去（${fillReject}）`);
  if (clickReject !== 'OK') rf.push(`点「驳回」失败：${clickReject}`);
  if (!dlgReject.open) rf.push('「驳回」没有弹二次确认');
  else {
    if (!dlgReject.text.includes('余额将退回打手')) rf.push(`确认框缺「余额将退回打手」（实际：${dlgReject.text.slice(0, 120)}）`);
    if (!dlgReject.text.includes('¥288.50')) rf.push('确认框没写清金额');
  }
  const shotReject = await cdp.shot('04-二次确认-驳回退余额.png');
  await cdp.evalJs(closeDialog);
  await sleep(500);
  // 关掉抽屉（否则后面的截图会带着它）
  await cdp.evalJs(`(() => { const b = document.querySelector('.n-drawer .n-drawer-header__close'); if (b) b.dispatchEvent(new MouseEvent('click', {bubbles:true})); return 'ok'; })()`);
  await sleep(900);
  record('⑧ 驳回二次确认（余额退回打手 + 金额）', rf, { 截图: shotReject });
  }

  /* ---------------------------------------------------------- ⑨ 不含"积分" */
  hr('⑨ 页面不含「积分」');
  const nf2 = [];
  const listText = await cdp.evalJs(`(document.body.innerText || '')`);
  if (listText.includes('积分')) nf2.push('提现审核页（列表）正文里出现了「积分」');
  let drawerText = '';
  if (SAMPLES > 0) {
    await cdp.evalJs(openRowDetail(0));
    await waitFor(cdp, `document.querySelector('.n-drawer .amount-line')`, { timeout: 8000 });
    await sleep(300);
    drawerText = await cdp.evalJs(`(document.body.innerText || '')`);
    if (drawerText.includes('积分')) nf2.push('提现审核页（详情抽屉）正文里出现了「积分」');
    await cdp.evalJs(`(() => { const b = document.querySelector('.n-drawer .n-drawer-header__close'); if (b) b.dispatchEvent(new MouseEvent('click', {bubbles:true})); return 'ok'; })()`);
    await sleep(700);
    if (!listText.includes('¥')) nf2.push('列表里一个 ¥ 都没有（金额没渲染）');
  } else {
    console.log('     [跳过] 空库：没有可开的详情抽屉（列表正文仍已检索）');
  }
  record('⑨ 页面不含「积分」（列表 + 抽屉全文检索）', nf2, { 正文长度: `${listText.length} / ${drawerText.length || '（空库未开抽屉）'}` });

  /* ---------------------------------------------------------- ⑩ 系统设置里的提现设置块 */
  hr('⑩ 「系统设置」页里的「提现设置」块');
  await cdp.send('Page.navigate', { url: `${UI}/settings` });
  await sleep(3400);
  const setProbe = await cdp.evalJs(`(() => {
    const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
    const cards = [...document.querySelectorAll('.n-card')];
    const card = cards.find((c) => txt(c.querySelector('.n-card-header')).includes('提现设置'));
    if (!card) return { found: false, cards: cards.map((c) => txt(c.querySelector('.n-card-header'))).slice(0, 12) };
    const nums = [...card.querySelectorAll('input')].map((i) => i.value);
    return {
      found: true,
      header: txt(card.querySelector('.n-card-header')),
      body: txt(card),
      values: nums,
      current: txt(card.querySelector('.current')),
      hasQrTab: false,
    };
  })()`);
  const setShot = await cdp.shot('05-系统设置-提现设置块.png', { beyond: true });
  const setF = [];
  if (!setProbe.found) setF.push(`「系统设置」页里找不到「提现设置」卡片（现有卡片：${JSON.stringify(setProbe.cards)}）`);
  else {
    if (!setProbe.body.includes('门槛')) setF.push('提现设置块里没有「门槛」');
    if (!setProbe.body.includes('每日次数')) setF.push('提现设置块里没有「每日次数」');
    // n-input-number 带 precision=0 → 输入框里是 "10" / "2000" 这种，比较时按数值比
    const nums = (setProbe.values || []).map((v) => Number(v));
    if (!LIVE) {
      if (JSON.stringify(nums) !== JSON.stringify([10, 2000, 3, 0])) {
        setF.push(`四个数字输入框 = ${JSON.stringify(setProbe.values)}（按数值 ${JSON.stringify(nums)}），期望 [10,2000,3,0]`);
      }
    } else {
      // 真后端：值以库为准（当前 10/2000/1/0），只断"四个都是合法范围内的整数"
      if (nums.length !== 4 || nums.some((n) => !Number.isInteger(n))) {
        setF.push(`真后端四个数字输入框 = ${JSON.stringify(setProbe.values)}（期望 4 个整数）`);
      } else if (nums[0] < 1 || nums[1] > 1000000 || nums[2] < 1 || nums[2] > 20 || nums[3] < 0 || nums[3] > 50) {
        setF.push(`真后端取值超出服务端范围：${JSON.stringify(nums)}`);
      }
    }
    if (!/¥[\d,]+\.\d{2}/.test(String(setProbe.current))) {
      setF.push(`「当前生效」没按 ¥ 两位小数/千分位显示：${setProbe.current}`);
    }
  }
  /*
   * 「不含积分」这条**只断本轮新增的提现设置卡片**（不算整页）：
   * 「系统设置」页里还有别的既有配置块（充值/抽成/下单须知…），它们的说明文字是**上一轮既有内容**，
   * 本轮不许改（硬约束：不改既有页业务逻辑）→ 拿整页去断会对既有内容假红。
   * 提现审核页那边是整页断（⑨），这一页只断新增的这块。
   */
  if (setProbe.found && String(setProbe.body).includes('积分')) setF.push('提现设置块里出现了「积分」');
  record('⑩ 提现设置并入系统设置（门槛/上限/每日次数/费率/说明）', setF, {
    数值框: JSON.stringify(setProbe.values), 当前生效: setProbe.current, 截图: setShot,
  });

  /* ---------------------------------------------------------- ⑪ 深色档 */
  hr('⑪ 深色档（列表 + 详情各一张，确认没被做坏）');
  // 走 gotoWithdraw()（它带「落到 /login 最多重登一次」的并行环境兜底）：⑩ 之后会话可能已被并行批次顶掉
  await gotoWithdraw();
  // 等页面框架真的画出来（dist 托管 + 冷缓存时 3s 睡不够：实测 `btns[1]` 会是 undefined 直接抛异常）
  const headerReady = await waitFor(cdp, `document.querySelectorAll('.header .icon-btn').length >= 2`, { timeout: 15000 });
  const themeClick = await cdp.evalJs(`(() => {
    const btns = [...document.querySelectorAll('.header .icon-btn')];
    if (!btns[1]) return 'NO_BUTTON';
    btns[1].dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return 'OK';
  })()`);
  await sleep(1200);
  const darkTheme = await cdp.evalJs(`document.documentElement.getAttribute('data-theme')`);
  const darkBg = await cdp.evalJs(`getComputedStyle(document.body).backgroundColor`);
  const darkRows = await cdp.evalJs(TABLE_PROBE);
  const shotDarkList = await cdp.shot('06-深色档-提现列表.png');
  let darkDrawer = { open: false, qrLoaded: false };
  let shotDarkDetail = null;
  if (SAMPLES > 0) {
    await cdp.evalJs(openRowDetail(0));
    await waitFor(cdp, `document.querySelector('.n-drawer .amount-line')`, { timeout: 8000 });
    await waitFor(cdp, `(() => { const i = document.querySelector('.qr-img img'); return i && i.naturalWidth > 0; })()`, { timeout: 10000 });
    darkDrawer = await cdp.evalJs(DRAWER_PROBE);
    shotDarkDetail = await cdp.shot('07-深色档-提现详情.png');
  } else {
    console.log('     [跳过] 空库：深色档只截列表（没有可开的详情）');
  }
  const df = [];
  if (!headerReady || themeClick !== 'OK') df.push(`点主题切换失败（headerReady=${headerReady} click=${themeClick}）→ 页面框架没画出来`);
  if (darkTheme !== 'dark') df.push(`切深色后 data-theme = ${darkTheme}`);
  if (darkBg !== 'rgb(11, 18, 32)') df.push(`深色档 body 底色 = ${darkBg}，期望 rgb(11, 18, 32)`);
  if (!LIVE && darkRows.rows.length !== FIX_ROWS.length) df.push(`深色档列表行数 = ${darkRows.rows.length}`);
  const darkAmounts = darkRows.rows.map((r) => r.cells[1]);
  if (!LIVE && JSON.stringify(darkAmounts) !== JSON.stringify(wantAmounts)) df.push(`深色档金额列 = ${JSON.stringify(darkAmounts)}`);
  if (!LIVE && !darkRows.rows[0]?.cells[2]?.includes('13812346621')) {
    df.push(`深色档收款信息列 = 「${darkRows.rows[0]?.cells[2]}」，期望同样是**完整**值（深色档不许退回打码）`);
  }
  if (SAMPLES > 0 && (!darkDrawer.open || !darkDrawer.qrLoaded)) df.push('深色档详情抽屉/收款码没出来');
  // 收尾：切回浅色（下一轮运行从默认档开始）
  await cdp.evalJs(`(() => { const b = document.querySelector('.n-drawer .n-drawer-header__close'); if (b) b.dispatchEvent(new MouseEvent('click', {bubbles:true})); return 'ok'; })()`);
  await sleep(600);
  await cdp.evalJs(`(() => { const btns = [...document.querySelectorAll('.header .icon-btn')]; if (!btns[1]) return 'NO_BUTTON'; btns[1].dispatchEvent(new MouseEvent('click', { bubbles: true })); return 'OK'; })()`);
  await sleep(900);
  const backLight = await cdp.evalJs(`document.documentElement.getAttribute('data-theme')`);
  if (backLight !== 'light') df.push(`切回浅色失败：data-theme = ${backLight}`);
  record('⑪ 深色档没被做坏（底色/列表/详情，来回切）', df, {
    深色: `data-theme=${darkTheme} body=${darkBg}`,
    截图: shotDarkDetail ? `${path.basename(shotDarkList)} / ${path.basename(shotDarkDetail)}` : path.basename(shotDarkList),
  });

  /* ---------------------------------------------------------- ⑫ 线上 bundle 已更新 */
  hr('⑫ 线上 bundle 已更新（服务端直接托管 admin-web/dist）');
  const bundleF = [];
  const indexPath = path.join(DIST, 'index.html');
  let entryLocal = '';
  try {
    entryLocal = (fs.readFileSync(indexPath, 'utf8').match(/src="(\/assets\/index-[^"]+\.js)"/) || [])[1] || '';
  } catch (e) {
    bundleF.push(`读不到本地 dist/index.html：${e?.message ?? e}`);
  }
  if (!entryLocal) bundleF.push('本地 dist/index.html 里解析不出入口 JS');
  let entryOnline = '';
  try {
    const html = await httpGet(`${DIST_ORIGIN}/`);
    entryOnline = (String(html).match(/src="(\/assets\/index-[^"]+\.js)"/) || [])[1] || '';
  } catch (e) {
    bundleF.push(`取不到 ${DIST_ORIGIN}/ ：${e?.message ?? e}`);
  }
  if (entryLocal && entryOnline && entryLocal !== entryOnline) {
    bundleF.push(`线上入口 JS = ${entryOnline}，本地最新构建 = ${entryLocal}（服务端托管的还是旧 bundle）`);
  }
  // dist 里必须有一份含「提现审核」的 WithdrawView chunk，且**已换成完整值口径**（旧列标题不许还在）
  let chunk = '';
  let chunkHasOldTitle = false;
  try {
    const assets = fs.readdirSync(path.join(DIST, 'assets'));
    for (const f of assets.filter((x) => /^WithdrawView-.*\.js$/.test(x))) {
      const body = fs.readFileSync(path.join(DIST, 'assets', f), 'utf8');
      if (body.includes('提现审核') && body.includes('withdraw:pay')) {
        chunk = f;
        chunkHasOldTitle = body.includes('收款信息（脱敏）');
        break;
      }
    }
  } catch (e) {
    bundleF.push(`读 dist/assets 失败：${e?.message ?? e}`);
  }
  if (!chunk) bundleF.push('dist/assets 里没有含「提现审核」与 `withdraw:pay` 的 WithdrawView chunk（构建产物不对）');
  if (chunk && chunkHasOldTitle) bundleF.push(`产物里的列标题还是「收款信息（脱敏）」（${chunk}）→ 线上还是旧口径`);
  record('⑫ 线上=本地最新构建，且产物含提现审核页（完整值口径）', bundleF, {
    线上入口: entryOnline || '（取不到）', 本地入口: entryLocal || '（无）', chunk: chunk || '（没找到）',
  });

  /* ---------------------------------------------------------- ⑬ 运行时异常 */
  hr('⑬ 运行时异常');
  const ef = [];
  if (cdp.exceptions.length) ef.push(`页面抛了 ${cdp.exceptions.length} 个未捕获异常：${cdp.exceptions.slice(0, 3).join(' | ')}`);
  record('⑬ 无未捕获异常', ef, { 异常数: cdp.exceptions.length });

  /* ---------------------------------------------------------- 汇总 */
  hr('汇总');
  for (const r of results) console.log(`${r.fails.length ? 'FAIL' : 'PASS'}  ${r.name}  失败项=${r.fails.length}`);
  console.log(`\n共 ${results.length} 组断言，FAIL ${failCount} 组`);
  console.log(failCount === 0 ? '🟢 GREEN：提现审核页 ①–⑬ 全绿' : '🔴 RED：见上方 FAIL 明细');
  fs.writeFileSync(path.join(SHOT_DIR, 'probe-withdraw.json'),
    JSON.stringify({ ui: UI, live: LIVE, results }, null, 2), 'utf8');
  console.log(`[落盘] ${path.join(SHOT_DIR, 'probe-withdraw.json')}`);
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
  try { fs.rmSync(UPLOAD_FILE, { force: true }); } catch { /* ignore */ }
}
