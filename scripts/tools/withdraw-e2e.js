/**
 * 打手提现（人工打款）e2e —— **可复跑，自建自清**。
 *
 * 覆盖（对应任务书的 ①…⑫）：
 *   ① 未绑定就申请 → 中文 400「请先绑定收款信息」
 *   ② 绑定收款信息（**打手侧**回显仍脱敏；审核面列表/详情给完整 —— 见 ⑭）
 *   ③ 换绑 → `operation_log` 留痕（含**新旧值摘要**）
 *   ④ 金额 < min / > max / > 余额 → 各自中文错误
 *   ⑤ 正常申请 → 余额**立即减少** + 流水有 `withdraw` 记录（附前后余额快照）
 *   ⑥ **并发两笔 → 只成功一笔**（SQL 证据：pending 恰好 1 行、流水恰好 1 条）
 *   ⑦ 管理端 pay → `paid` + 打款凭证可读 + **重复 pay 中文 400 且无二次生效**
 *   ⑧ reject → `rejected` + **余额退回** + 反向流水 `withdraw_reject`（前后余额快照）
 *   ⑨ 权限：非超管调 pay → 403 中文；无 `withdraw:review` 读列表 → 403 中文
 *   ⑩ App 内「管理员身份」（受限会话 `kind='recharge'`）能调 `/withdraw/*`，
 *      且**不能**调 `/admin/withdraw/*`；附加：companion（打手态）也能提现
 *   ⑪ 全局不出现「积分」（响应文案扫描）
 *   ⑬ **App 内上传打款凭证**（2026-10-11 新增窄通道 `POST /withdraw/requests/:id/pay-proof`）：
 *      ① 受限会话上传 → 200 + mediaId（protected/withdraw_proof）③ 立刻读回自己刚传的图
 *      ② `pay` 只带 `proofMediaId` → 200 且凭证可读 ③（新规则）**只带备注 → 中文 400**
 *      ④ 对已 paid 的申请再上传 → 400 中文 ⑤ 不存在的申请 → 404 中文（不泄漏存在性）
 *      ⑥ 老板/管理端 primary → 403 中文 ⑦ `operation_log` 每次成功上传一条（不落文件内容）
 *      另证：白名单**一个字没改**（新端点落在既有 `/withdraw/*` 前缀内），`/media/*` 仍 403
 *   ⑫ 变异验证：见脚本末尾说明（基线全绿；三条变异里前两条由 `scripts/tmp/wd-mutate.js`
 *      施加后重跑本脚本，第三条 = 把"必须带凭证"改回"凭证或备注" → ⑬-③ 必须变红）
 *   ⑭ **列表下发完整收款信息**（2026-10-11 负责人要求）：列表行新增 `account:{realName,phone,wechatId}`
 *      （与详情**同名同形**，完整值），`accountMasked` **原样保留**（旧客户端仍能跑）。
 *      ① `account.phone` 是完整 11 位且与绑定时提交的值**逐字一致**（realName/wechatId 同样完整）
 *      ② 同一行**同时仍有** `accountMasked`（含 `*`）→ 兼容性
 *      ③ App 受限会话的 `/withdraw/requests` 同样给完整 `account`（与 PC 逐字一致）
 *      ④ **负向断言**：本轮新增的 `operation_log`（withdraw 模块）与 `user_notification`、
 *         以及服务端运行日志的本轮新增部分，**不得出现**完整手机号（精确串 + 正则 `1[3-9]\d{9}` 双查）
 *         或完整微信号 —— 脱敏继续用在**非审核面**（PIPL：不向无关方泄露，不是向审核人隐藏）
 *      ⑤ 变异：把列表改回"只给脱敏" → ① 必须红（见脚本末尾 + `wd-mutate.js apply4`）
 *
 * 账号（**绝不用负责人账号 `kslingyun`**）：
 *   - 管理端走 `scripts/tools/regression-admin.js`（= `server/.env` 的 `REGRESSION_ADMIN_USER`，专用测试超管 opsadmin）；
 *   - 非超管权限用例走仓库共享夹具 `chat_limited_admin`（角色 = 既有 `operator`，由 `test-fixtures.ensureAdmin` 幂等引导）；
 *   - 打手走夹具 `worker01` + 本套件自建的 `wd_e2e_worker`；老板走夹具 `boss_demo`（仅供打手态绑定）。
 *
 * 自建自清（2026-10-11 修：**旧收尾会静默吃掉账号余额**）：
 *   - 收尾**只按「本轮创建的 withdraw_request id」精确成对删除** —— 每张申请先做资金对账
 *     （扣款 `withdraw:<id>` 必有、且与申请回写的 `wallet_transaction_id` 一致；`rejected` 必须有退回
 *     `withdraw_reject:<id>`；`pending` / `paid` 必须**没有**退回流水），
 *     **不成对 → 报红且原地保留，绝不硬删半对**；
 *   - 同一事务里删掉这些申请的**全部**关联流水（扣款 + 退回）+ 本轮夹具「余额归一」写的 grant 流水，
 *     并**按删掉的流水金额之和反向修正余额**（删多少补多少）→ 任何时刻 `余额 = Σ 流水` 都成立；
 *   - 收尾后**逐账号**比对「余额 + 流水条数」是否回到跑前基线，并断言账实一致（漂移必须 0.00）；
 *     **不回滚 → 本套件判 FAIL**（绝不允许静默通过）；
 *   - 长期夹具账号 `worker01`(user 1114) 上那 18 条历史孤儿扣款（Σ −1800.00）是**历史问题**，
 *     收尾只做「跑前/跑后 id 集逐条相同」的比对来证明**一条未动**，等负责人裁决。
 * 跑前归一：只碰两个测试打手（`worker01` / `wd_e2e_worker`），用**同一套**精确成对删除愈合上一轮残留
 * （含被限流 429 / 崩溃中断那一轮留下的夹具「余额归一」grant 流水 —— 按本代专属前缀 `wd-e2e-fixture-topup:` 认；
 *  **旧前缀 `wd-e2e-topup:` 下的历史账本（worker01 那 18 条历史归一 grant）对新代码完全不可见，一条都不碰**），
 * 余额只向上归一到 ≥500（整数：`GrantDto.amount` 是 @IsInt；按仓库既有修数脚本口径写 grant 流水 +
 * 同步 `wallet.balance`，**账实始终一致**，不手写"半条"资金）；管理端白名单若被本套件临时加入，
 * 结束时移除。**不动任何真人账号**。
 *
 * 运行：node scripts/tools/withdraw-e2e.js
 */
const fs = require('fs');
const mysql = require('D:/fish/server/node_modules/mysql2/promise');
const { adminUser, adminPassword: adminPw } = require('./regression-admin');
const fixtures = require('../tmp/test-fixtures');

const BASE = 'http://127.0.0.1:3100/api/v1';
const W1 = 'worker01';
const W2 = 'wd_e2e_worker';
const BOSS = 'boss_demo';
const LIMITED_ADMIN = 'chat_limited_admin';
/** 夹具管理端口令（与 `scripts/tmp/test-fixtures.js` 的 FIXTURE_ADMIN_PASSWORD 同一口径） */
const FIXTURE_ADMIN_PASSWORD = 'ChatLimited#2026';
/** 余额归一目标（**只向上**补足；整数：`GrantDto.amount` 是 @IsInt） */
const TARGET_BALANCE = 500;
const AMOUNT = 100;
/**
 * 本轮运行的起始时刻（**库内 DATETIME 裸值**：TypeORM `timezone:'Z'` → 库里存的是 UTC 墙钟）。
 * 所有"本轮产生的流水"都用它做时间下界，避免重复运行时的历史流水干扰断言。
 */
const RUN_START_DB = new Date().toISOString().slice(0, 19).replace('T', ' ');

/**
 * 「本轮造的提现申请 id」清单 —— 收尾**只按这份清单**精确成对删除（不再按 worker 一把梭）。
 * 每造一张就 `trackReq()` 一次；收尾还会与库内「id > REQ_MARK」的新行**双向比对**：
 * 脚本没记到的行 → 报红，且**一并纳入清理**（宁可多清已知的本轮行，不可漏删留下孤儿扣款）。
 */
const CREATED_REQ_IDS = [];
const trackReq = (id) => {
  const s = String(id ?? '').trim();
  if (s && s !== 'undefined' && s !== 'null' && !CREATED_REQ_IDS.includes(s)) CREATED_REQ_IDS.push(s);
  return s;
};
/**
 * 夹具「余额归一」写的 grant 流水幂等键 —— 收尾要**连它一起撤**，余额才回得到跑前基线
 * （旧实现只补不退：每跑一轮就往 `worker01` 里注入一笔 ~¥100 的 grant，属于"测试悄悄改钱"的另一半）。
 */
const TOPUP_KEYS = [];

let pass = 0;
let fail = 0;
/** ⑪：把**每一个**响应体原文收集起来，最后统一扫描「积分」 */
const SCRAPED = [];

function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isChinese = (s) => /[\u4e00-\u9fa5]/.test(String(s ?? ''));
const j = (v) => JSON.stringify(v);
const yuan = (n) => `¥${Number(n).toFixed(2)}`;

async function req(method, path, token, body, extraHeaders = {}) {
  const r = await fetch(BASE + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
      ...extraHeaders,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  SCRAPED.push({ method, path, status: r.status, text });
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* 二进制/空响应体 */
  }
  return { status: r.status, json, text, message: json?.message, data: json?.data };
}

/** 媒体上传（multipart）：收款码 = withdraw_qr，打款凭证 = withdraw_proof，两者都是 protected */
async function uploadMedia(token, buffer, filename, type) {
  const fd = new FormData();
  fd.append('type', type);
  fd.append('file', new File([buffer], filename, { type: 'image/png' }));
  const r = await fetch(`${BASE}/media/upload`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: fd,
  });
  const text = await r.text();
  SCRAPED.push({ method: 'POST(multipart)', path: '/media/upload', status: r.status, text });
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* ignore */
  }
  return { status: r.status, json, data: json?.data, message: json?.message };
}

/** 取受保护图片（验证"凭证可读"）：返回 { status, type, bytes } */
async function fetchMedia(token, path) {
  const r = await fetch(BASE + path, { headers: { Authorization: 'Bearer ' + token } });
  const buf = Buffer.from(await r.arrayBuffer());
  SCRAPED.push({ method: 'GET(binary)', path, status: r.status, text: `[binary ${buf.length}B ${r.headers.get('content-type')}]` });
  return { status: r.status, type: r.headers.get('content-type') ?? '', bytes: buf.length };
}

/** 生成一张真 PNG（sharp 已在 server 依赖里；96×96 纯色） */
async function makePng(rgb) {
  const sharp = require('D:/fish/server/node_modules/sharp');
  return sharp({ create: { width: 96, height: 96, channels: 3, background: rgb } }).png().toBuffer();
}

/** pm2 给 fish-server 落的两个运行日志（⑭-④ 的"任何日志"面） */
const PM2_LOGS = ['D:/fish/data/logs/fish-server-out.log', 'D:/fish/data/logs/fish-server-error.log'];

/** 取两个日志文件的当前字节长度（作为"本轮新增部分"的起点水位） */
function logMarks() {
  return PM2_LOGS.map((p) => {
    try {
      return fs.statSync(p).size;
    } catch {
      return 0;
    }
  });
}

/** 只读回**水位之后新增**的那段日志（不整文件扫描：库里历史与上几轮运行的内容不参与断言） */
function logTailSince(marks) {
  return PM2_LOGS.map((p, i) => {
    try {
      const size = fs.statSync(p).size;
      const from = Math.min(marks[i] ?? 0, size);
      const len = size - from;
      if (len <= 0) return '';
      const buf = Buffer.alloc(len);
      const fd = fs.openSync(p, 'r');
      fs.readSync(fd, buf, 0, len, from);
      fs.closeSync(fd);
      return buf.toString('utf8');
    } catch {
      return '';
    }
  }).join('\n');
}

(async () => {
  const env = fs.readFileSync('D:/fish/server/.env', 'utf8');
  const g = (k) => {
    const m = env.match(new RegExp('^' + k + '=(.+)$', 'm'));
    return m ? m[1].trim() : null;
  };
  const db = await mysql.createConnection({
    host: g('DB_HOST'),
    port: Number(g('DB_PORT')),
    user: g('DB_USER'),
    password: g('DB_PASSWORD'),
    database: g('DB_NAME'),
  });
  const q = async (sql, args) => (await db.query(sql, args))[0];
  const idem = (tag) => `${tag}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  console.log('=== 打手提现（人工打款）e2e ===');

  // ---------- 登录（每个账号恰好一次：登录限流 5 次/分/账号）----------
  const al = await req('POST', '/auth/login', null, { username: adminUser, password: adminPw, role: 'admin' });
  if (al.status !== 200) throw new Error(`管理端登录失败（${adminUser}）：${al.status} ${al.message}`);
  const adminToken = al.data.accessToken;
  const adminUserId = String((await req('GET', '/auth/me', adminToken)).data?.id ?? '');
  console.log(`[账号] 管理端=${adminUser}（专用测试超管，id=${adminUserId}）`);

  /**
   * 打手 token = **companion**（2026-10-13 改造，**不要改回 worker primary**）
   *
   * 工作端到期收口已生效（产品既定行为）：`POST /auth/login`（role=worker）**一律 403**
   * 「工作端已停止服务…」→ 旧实现第一步就 403，落到创建分支撞「用户名已存在」→ 脚本自杀
   * （本套件的 98/0 基线因此长期跑不到）。
   *
   * 打手态真实入口 = 老板端「我的 → 身份 → 绑定打手账号」：夹具 `ensureWorker` 建号（管理员接口）
   * → 老板 `POST /user/identity/bind` → 返回 **companion** token。
   * ⚠️ 一个老板只能同时绑一个打手（`worker_binding_max_per_boss` 默认 1）+ 一个打手只能被一个老板绑：
   * 所以 W1 显式绑给 `boss_demo`（**本套件下面「附加」一节要验的就是 boss_demo 那条绑定链路**），
   * W2 走默认派生老板 `wfx_wd_e2e_worker` —— 两个 companion 才能同时有效。
   * 本套件打的 `/worker/withdraw/*`、`/media/upload`、`/media/protected/*` 均在 companion 白名单内。
   */
  const w1 = await fixtures.ensureWorker(adminToken, {
    username: W1, workerNo: 'W001', nickname: '演示工作端', takeOrder: true, serveCustomer: true,
    bossUsername: BOSS,
  });
  const w2 = await fixtures.ensureWorker(adminToken, {
    username: W2, workerNo: 'WDE2E', nickname: '提现 e2e 打手', takeOrder: false, serveCustomer: false,
  });
  const worker1 = { token: w1.token, userId: String(w1.userId), workerId: String(w1.workerRow?.id ?? '') };
  const worker2 = { token: w2.token, userId: String(w2.userId), workerId: String(w2.workerRow?.id ?? '') };
  const bossToken = await fixtures.ensureBoss(BOSS, '演示老板');
  console.log(`[账号] 打手 ${W1}#${worker1.userId}(workerId=${worker1.workerId}) / ${W2}#${worker2.userId}(workerId=${worker2.workerId}) ｜ 老板=${BOSS}`);

  const wIds = [worker1.workerId, worker2.workerId].filter((x) => x);

  // =========================================================================
  // 精确成对清理（本文件**唯一**的「删钱」路径）
  //
  // 背景（2026-10-11 真 bug）：旧收尾按 worker 一把梭
  //   `DELETE FROM withdraw_request WHERE worker_id IN (…)`
  // —— 申请行删了，它对应的 `wallet_transaction` 却留下了（扣款 `withdraw:<id>`、
  // 退回 `withdraw_reject:<id>`）。后果：钱还在流水里扣着、退款那半对也在流水里，
  // 长期回归夹具账号 `worker01`(user 1114) 上因此积了 **18 条孤儿扣款（Σ −1800.00）**；
  // 账实仍自洽（余额 = Σ 流水）但**余额被测试悄悄扣掉了 ¥1800**，且"已驳回应退回"的凭据被抹掉
  // ——「临时数据自清」这个说法不成立。
  // 现在：**只按本轮创建的 request id 精确成对删除 + 收尾做余额回滚与账实一致自检**。
  // =========================================================================

  /** 账号资金快照：余额 + 流水条数 + 流水之和（账实一致用） */
  const snapshot = async (label, userId) => {
    const balance = Number((await q('SELECT balance FROM wallet WHERE user_id = ?', [userId]))[0]?.balance ?? 0);
    const cnt = Number((await q('SELECT COUNT(*) AS n FROM wallet_transaction WHERE user_id = ?', [userId]))[0].n);
    const sums = Number((await q('SELECT COALESCE(SUM(amount), 0) AS s FROM wallet_transaction WHERE user_id = ?', [userId]))[0].s);
    return { label, userId: String(userId), balance, cnt, sums };
  };

  /**
   * 历史孤儿扣款：有 `withdraw` 流水、但对应 `withdraw_request` 行**早已不在**的那些行。
   * 这是**历史问题**（等负责人裁决），本套件**一条都不许碰** —— 收尾用「跑前/跑后 id 集逐条相同」
   * 来证明没动它（也顺带证明精确清理没有误伤"不属于本轮"的流水）。
   */
  const orphansOf = async (userId) =>
    q(
      `SELECT t.id, t.amount, t.idempotency_key FROM wallet_transaction t
        WHERE t.user_id = ? AND t.change_type = 'withdraw'
          AND NOT EXISTS (SELECT 1 FROM withdraw_request r WHERE r.id = CAST(SUBSTRING_INDEX(t.idempotency_key, ':', -1) AS UNSIGNED))
        ORDER BY t.id`,
      [userId],
    );

  /**
   * 单张申请的**资金对账**（删除前的必过关卡）。不成对 → **不删**、报红、留给人查。
   *   ① 扣款流水 `withdraw:<id>` 必须存在，且金额 = −申请金额；
   *   ② 申请回写的 `wallet_transaction_id` 必须就是那条扣款流水（证明删的是"这张单子的钱"）；
   *   ③ `rejected` 必须有退回流水 `withdraw_reject:<id>`；`pending` / `paid` 必须**没有**退回流水
   *      （pending 的钱还锁着、paid 的钱已线下打出去 —— 有退回流水就是状态与流水矛盾）。
   * 注：`paid` 允许的形态是"仅扣款"；但**测试**不得真把钱花掉，所以收尾照样撤掉这条扣款
   * 并把余额补回基线（见 preciseCleanup ③）。
   */
  const pairCheck = async (id) => {
    const row = (await q(
      'SELECT id, worker_id, user_id, amount, status, wallet_transaction_id FROM withdraw_request WHERE id = ?',
      [String(id)],
    ))[0] ?? null;
    if (!row) return { id: String(id), ok: false, why: '申请行不存在（可能已被删）', row: null, deduct: null, refund: null };
    const deduct = (await q('SELECT * FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1', [`withdraw:${id}`]))[0] ?? null;
    const refund = (await q('SELECT * FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1', [`withdraw_reject:${id}`]))[0] ?? null;
    let why = null;
    if (!deduct) why = `缺扣款流水 withdraw:${id}`;
    else if (String(row.wallet_transaction_id ?? '') !== String(deduct.id)) {
      why = `申请回写的 wallet_transaction_id=${row.wallet_transaction_id} ≠ 实际扣款流水 ${deduct.id}`;
    } else if (Number(deduct.amount) !== -Number(row.amount)) why = `扣款金额 ${deduct.amount} ≠ −申请金额 ${row.amount}`;
    else if (row.status === 'rejected' && !refund) why = `已驳回却缺退回流水 withdraw_reject:${id}`;
    else if (row.status !== 'rejected' && refund) why = `状态 ${row.status} 却有退回流水 withdraw_reject:${id}（状态与流水矛盾）`;
    return { id: String(id), ok: !why, why, row, deduct, refund };
  };

  /**
   * 精确成对清理（②③④ 在**同一事务**里做；删行数与计划不符 → 整体回滚，绝不硬删）：
   *   ① 逐张 `pairCheck`（不成对的**原地保留**，只报红）
   *   ② 只删成对申请的**全部**关联流水（扣款 `withdraw:<id>` + 退回 `withdraw_reject:<id>`）
   *      ＋本轮夹具「余额归一」写的 grant 流水（`topupKeys`）
   *   ③ **按删掉的流水金额之和反向修正余额**（删多少补多少）→ 任何时刻 `余额 = Σ 流水` 都成立
   *   ④ 删申请行（+ 需要时删收款信息行）
   */
  const preciseCleanup = async ({ ids, topupKeys = [], staleTopupPrefix = null, staleTopupUsers = [], wipeWorkerIds = [], label = '清理' }) => {
    const pairs = [];
    for (const id of [...new Set(ids.map((x) => String(x)))]) pairs.push(await pairCheck(id));
    const bad = pairs.filter((p) => !p.ok);
    const good = pairs.filter((p) => p.ok);
    const rows = [];
    for (const p of good) {
      rows.push(p.deduct);
      if (p.refund) rows.push(p.refund);
    }
    if (topupKeys.length) rows.push(...(await q('SELECT * FROM wallet_transaction WHERE idempotency_key IN (?)', [topupKeys])));
    /**
     * **跑前愈合**（只有跑前清理用）：把本套件夹具「余额归一」遗留的 grant 流水撤掉。
     * 为什么必须单独扫一遍：被限流 429 / 崩溃中断的那一轮**跑不到收尾**，它写下的归一 grant
     * 既没有申请 id、也不在下一轮的 `TOPUP_KEYS` 里 —— 只按 request id 清理会把它留下
     * （实测：run4 被 429 中断后 `worker01` 就多挂了 ¥100 / 1 条，下一轮基线被抬到 ¥499.72/84）。
     *
     * ⚠️ 这里**只认本代夹具的专属前缀** `wd-e2e-fixture-topup:`（2026-10-11 起启用）。
     * 血泪教训：上一代的键是 `wd-e2e-topup:<userId>:<ts>`，而 worker01 上**历史遗留**的 18 条
     * 归一 grant 用的就是这个旧前缀（它们与"18 条历史孤儿扣款"是同一笔历史账，负责人明令不许动）。
     * 按旧前缀扫（哪怕加了"最近 30 分钟"窗口 —— 实测那段历史就是几十分钟前产生的）会把它们一起删掉，
     * 余额 499.72 → −1203.28，只能从 `data/backups/fish_20261011_150605.zip` 原样恢复。
     * 因此：**换前缀 + 只扫新前缀**，旧前缀的历史账本对新代码完全不可见（既不清、也不碰）。
     */
    if (staleTopupPrefix && staleTopupUsers.length) {
      rows.push(...(await q('SELECT * FROM wallet_transaction WHERE idempotency_key LIKE ? AND user_id IN (?)', [staleTopupPrefix, staleTopupUsers])));
    }
    /** 去重：同一行可能同时被「申请 id」与「夹具标记」两条路径命中，绝不能重复删/重复补 */
    const uniqRows = [];
    const seenRowIds = new Set();
    for (const r of rows) {
      if (seenRowIds.has(String(r.id))) continue;
      seenRowIds.add(String(r.id));
      uniqRows.push(r);
    }
    rows.length = 0;
    rows.push(...uniqRows);
    /** userId → 本批删掉的流水金额之和（扣款为负、退回/归一为正，按实际符号累加） */
    const delta = new Map();
    for (const r of rows) {
      const uid = String(r.user_id);
      delta.set(uid, Number(((delta.get(uid) ?? 0) + Number(r.amount)).toFixed(2)));
    }
    const before = [];
    for (const uid of delta.keys()) before.push(await snapshot(`user#${uid}`, uid));

    let txError = null;
    let deletedTxns = 0;
    let deletedReqs = 0;
    try {
      await db.beginTransaction();
      if (rows.length) {
        const [res] = await db.query('DELETE FROM wallet_transaction WHERE id IN (?)', [rows.map((r) => r.id)]);
        deletedTxns = Number(res.affectedRows);
        if (deletedTxns !== rows.length) throw new Error(`流水删除行数不符：计划 ${rows.length}、实际 ${deletedTxns}`);
      }
      for (const [uid, d] of delta) {
        const [res] = await db.query('UPDATE wallet SET balance = balance - ? WHERE user_id = ?', [d, uid]);
        if (Number(res.affectedRows) === 0) {
          await db.query('INSERT INTO wallet (user_id, balance) VALUES (?, ?)', [uid, Number((-d).toFixed(2))]);
        }
      }
      if (good.length) {
        const [res] = await db.query('DELETE FROM withdraw_request WHERE id IN (?)', [good.map((p) => p.id)]);
        deletedReqs = Number(res.affectedRows);
        if (deletedReqs !== good.length) throw new Error(`申请删除行数不符：计划 ${good.length}、实际 ${deletedReqs}`);
      }
      if (wipeWorkerIds.length) await db.query('DELETE FROM worker_withdraw_account WHERE worker_id IN (?)', [wipeWorkerIds]);
      await db.commit();
    } catch (e) {
      txError = (e && e.message) || String(e);
      try {
        await db.rollback();
      } catch {
        /* ignore */
      }
    }
    const after = [];
    for (const uid of delta.keys()) after.push(await snapshot(`user#${uid}`, uid));
    console.log(
      `[${label}] 成对 ${good.length} 张 / 不成对 ${bad.length} 张 ｜ 删流水 ${deletedTxns} 条（计划 ${rows.length}）+ 申请 ${deletedReqs} 行` +
        `${txError ? ` ｜ ⚠️ 事务已回滚：${txError}` : ''}`,
    );
    return { label, pairs, bad, good, rows, delta, before, after, txError, deletedTxns, deletedReqs };
  };

  // ---------- 自建自清①：跑前归一（只碰自建夹具；同一套精确成对删除，愈合上一轮崩溃残留）----------
  /** 本代夹具「余额归一」grant 的幂等键前缀（跑前愈合靠它认出"上一轮没跑完留下的测试资金"；
   *  **刻意换掉了旧前缀 `wd-e2e-topup:`** —— 那个前缀下面挂着 worker01 的历史账本，新代码对它完全不可见） */
  const TOPUP_PREFIX = 'wd-e2e-fixture-topup:%';
  const wipe = async () => {
    const accts = Number((await q('SELECT COUNT(*) AS n FROM worker_withdraw_account WHERE worker_id IN (?)', [wIds]))[0].n);
    const mine = await q('SELECT id FROM withdraw_request WHERE worker_id IN (?) ORDER BY id', [wIds]);
    const res = await preciseCleanup({
      ids: mine.map((r) => String(r.id)),
      staleTopupPrefix: TOPUP_PREFIX,
      staleTopupUsers: [worker1.userId, worker2.userId],
      wipeWorkerIds: wIds,
      label: `跑前清理 ${W1}/${W2}`,
    });
    /** 愈合留痕：把"上一轮残留被撤掉、余额被补回"的数值贴出来（没有残留就不打印） */
    if (res.rows.length) {
      console.log(
        `[跑前愈合] ${res.before.map((b, i) => `${b.label} 余额 ${yuan(b.balance)}/${b.cnt} 条 → ${yuan(res.after[i].balance)}/${res.after[i].cnt} 条`).join(' ｜ ')}` +
          `（撤掉上一轮未跑完收尾留下的 ${res.rows.length} 条流水：${j(res.rows.map((r) => r.idempotency_key))}）`,
      );
    }
    return { reqs: mine.length, accts, res };
  };
  const before1 = await wipe();
  console.log(`[清理] 跑前清掉 ${W1}/${W2} 的提现申请 ${before1.reqs} 行、收款信息 ${before1.accts} 行`);

  // ---------- 自建自清②：**跑前基线快照**（收尾必须回到这里）----------
  /**
   * 基线取在**跑前清理之后** —— 跑前清理只愈合"上一轮崩溃残留"，属于有意的归一，不算本轮改动；
   * 之后（含夹具「余额归一」那笔 grant）产生的**任何**余额/流水变化都必须被收尾撤干净。
   *   · `worker01`(user 1114)：长期回归夹具账号（历史孤儿 18 条挂在这里 → 收尾 清理-h 专门盯住）
   *   · `wd_e2e_worker`：本套件自建夹具（跑前通常余额 0、流水 0 条）
   *   · `boss_demo`：只用于打手态绑定（**不该有任何资金变化**，一并纳入自检）
   */
  const bossUserId = String((await req('GET', '/auth/me', bossToken)).data?.id ?? '');
  const TOUCHED = [
    await snapshot(W1, worker1.userId),
    await snapshot(W2, worker2.userId),
    ...(bossUserId ? [await snapshot(BOSS, bossUserId)] : []),
  ];
  /** 本轮水位：收尾用它反查"本轮真正新建了什么"（比时间戳可靠，不受时钟/重复运行影响） */
  const REQ_MARK = Number((await q('SELECT COALESCE(MAX(id), 0) AS m FROM withdraw_request'))[0].m);
  const TXN_MARK = Number((await q('SELECT COALESCE(MAX(id), 0) AS m FROM wallet_transaction'))[0].m);
  /** `worker01` 的历史孤儿扣款（**一条都不许动**）：跑前记 id 集，收尾逐条比对 */
  const ORPHANS0 = await orphansOf(worker1.userId);
  console.log(
    `[基线] ${TOUCHED.map((s) => `${s.label}(user#${s.userId})=${yuan(s.balance)}/${s.cnt} 条`).join(' ｜ ')}` +
      ` ｜ 水位 申请>${REQ_MARK} 流水>${TXN_MARK}`,
  );
  console.log(
    `[基线] ${W1} 历史孤儿扣款 ${ORPHANS0.length} 条 / Σ ${yuan(ORPHANS0.reduce((a, r) => a + Number(r.amount), 0))}` +
      `（历史问题，等负责人裁决；本套件**不动它**，只证明跑前跑后一条未少）`,
  );

  /**
   * 余额只向上归一到 ≥ TARGET。
   *
   * 为什么这里用**夹具 SQL** 而不是 `POST /admin/wallets/grant`：那个接口的既有口径是
   * `userRepo.findOne({ where: { id, role: 'user' } })` —— **只服务老板账号**，
   * 打手（`role='worker'`）打进去会 404「用户不存在」。打手钱包的正常入账来源是订单结算，
   * 而 e2e 不想为了"有钱可提"去跑一整条下单链路。
   *
   * 因此按仓库既有的**修数脚本口径**（如 `scripts/tmp/_task2-repair.js`）：
   * 写一条 `grant` 流水 + 同步 `wallet.balance` —— **账实始终一致（余额 = Σ 流水）**，
   * 且流水里带 `idempotency_key` 便于复查。这是夹具，不是业务路径。
   *
   * ⚠️ 2026-10-11 修：这笔归一 grant 的幂等键要记进 `TOPUP_KEYS`，**收尾连它一起撤**
   * （并把余额补回跑前基线）—— 否则"只补不退"等于每跑一轮就往长期夹具账号注入一笔测试资金，
   * 与"扣款流水留成孤儿"是同一类"测试悄悄改钱"。
   */
  const normalize = async (userId, label) => {
    const cur = Number((await q('SELECT balance FROM wallet WHERE user_id = ?', [userId]))[0]?.balance ?? 0);
    if (cur < TARGET_BALANCE) {
      const add = Math.round(TARGET_BALANCE - cur);
      const after = cur + add;
      const topupKey = `wd-e2e-fixture-topup:${userId}:${Date.now()}`;
      await q(
        `INSERT INTO wallet_transaction
           (transaction_no, user_id, change_type, amount, balance_before, balance_after,
            operator_type, operator_id, source, reason, idempotency_key, ip, created_at)
         VALUES (?, ?, 'grant', ?, ?, ?, 'admin', ?, 'admin-web', '提现 e2e 夹具：余额归一（账实一致）', ?, '127.0.0.1', NOW(3))`,
        [
          `WDE2E${Date.now().toString(36).toUpperCase()}${Math.random().toString(36).slice(2, 5).toUpperCase()}`.slice(0, 32),
          userId, add, cur, after, adminUserId, topupKey,
        ],
      );
      TOPUP_KEYS.push(topupKey);
      const upd = await q('UPDATE wallet SET balance = ? WHERE user_id = ?', [after, userId]);
      if (Number(upd.affectedRows ?? 0) === 0) {
        await q('INSERT INTO wallet (user_id, balance) VALUES (?, ?)', [userId, after]);
      }
      console.log(`[夹具] ${label} 余额 ${yuan(cur)} → ${yuan(after)}（补 ${yuan(add)}）`);
    }
    const final = Number((await q('SELECT balance FROM wallet WHERE user_id = ?', [userId]))[0]?.balance ?? 0);
    return final;
  };
  const b1Start = await normalize(worker1.userId, W1);
  const b2Start = await normalize(worker2.userId, W2);
  console.log(`[余额] 起点 ${W1}=${yuan(b1Start)} ｜ ${W2}=${yuan(b2Start)}`);

  /**
   * 「非审核面」负向断言（⑭-④）的**水位**：本轮开始时的 `operation_log` / `user_notification`
   * 最大 id + 服务端运行日志文件字节数。
   *
   * 只看**本轮新增**的内容：库里那笔真实 pending 申请（负责人演示数据）的历史审计行与历史通知
   * 一律不参与断言，也**绝不被本套件改动**（本套件只碰自建的两个夹具打手）。
   */
  const LOG_MARK = Number((await q('SELECT COALESCE(MAX(id), 0) AS m FROM operation_log'))[0].m);
  const NOTI_MARK = Number((await q('SELECT COALESCE(MAX(id), 0) AS m FROM user_notification'))[0].m);
  const LOG_MARKS = logMarks();
  console.log(`[水位] operation_log>${LOG_MARK} ｜ user_notification>${NOTI_MARK} ｜ 运行日志起点 ${j(LOG_MARKS)}`);

  const balanceOf = async (userId) =>
    Number((await q('SELECT balance FROM wallet WHERE user_id = ?', [userId]))[0]?.balance ?? 0);
  const reqRow = async (id) => (await q('SELECT * FROM withdraw_request WHERE id = ?', [String(id)]))[0] ?? null;
  const txnOf = async (key) =>
    (await q('SELECT * FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1', [key]))[0] ?? null;

  // =========================================================================
  // ① 未绑定就申请 → 中文 400「请先绑定收款信息」
  // =========================================================================
  console.log('\n--- ① 未绑定收款信息 ---');
  const accBefore = await req('GET', '/worker/withdraw/account', worker1.token);
  ok('①-a 未绑定时 GET /worker/withdraw/account → bound:false（不是 404，客户端可直接渲染引导态）',
    accBefore.status === 200 && accBefore.data?.bound === false, j(accBefore.data));

  const cfg0 = await req('GET', '/worker/withdraw/config', worker1.token);
  ok('①-b GET /worker/withdraw/config → 门槛与余额（服务端权威数据源）',
    cfg0.status === 200 && cfg0.data?.minAmount === 10 && cfg0.data?.maxAmount === 2000 && cfg0.data?.dailyLimit === 1 &&
      cfg0.data?.feeRate === 0 && typeof cfg0.data?.balance === 'number' && typeof cfg0.data?.todayUsed === 'number',
    j({ min: cfg0.data?.minAmount, max: cfg0.data?.maxAmount, daily: cfg0.data?.dailyLimit, fee: cfg0.data?.feeRate, balance: cfg0.data?.balance, todayUsed: cfg0.data?.todayUsed }));

  const applyNoAcc = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: AMOUNT });
  ok('①-c 未绑定就申请 → 400 中文「请先绑定收款信息」',
    applyNoAcc.status === 400 && applyNoAcc.message === '请先绑定收款信息',
    `status=${applyNoAcc.status} message=${applyNoAcc.message}`);
  ok('①-d 未绑定被拒时不产生任何单据（也不会扣钱）',
    Number((await q('SELECT COUNT(*) AS n FROM withdraw_request WHERE worker_id = ?', [worker1.workerId]))[0].n) === 0 &&
      (await balanceOf(worker1.userId)) === b1Start,
    `balance=${await balanceOf(worker1.userId)}`);

  // =========================================================================
  // ② 绑定收款信息（脱敏返回）
  // =========================================================================
  console.log('\n--- ② 绑定收款信息（微信收款码 + 微信号 + 姓名 + 电话）---');
  /**
   * 绑定/换绑收款信息（上传自己的收款码 → POST account）。
   *
   * ⚠️ 每个打手必须用**不同颜色**的图：`MediaService.upload` 按 `sha256 + mediaType` 去重，
   * 内容相同的图会**复用别人的 media 行**（uploaderId 是别人）→ 归属校验直接 400
   * 「收款码必须是你本人上传的图片」。这是既有媒体层的正确行为，夹具要顺着它来。
   */
  const bindAccount = async (worker, { realName, phone, wechatId, tag, rgb }) => {
    const up = await uploadMedia(worker.token, await makePng(rgb), `wd-qr-${tag}.png`, 'withdraw_qr');
    const r = await req('POST', '/worker/withdraw/account', worker.token, {
      realName, phone, wechatId, qrMediaId: String(up.data?.id ?? ''),
    });
    return { up, mediaId: String(up.data?.id ?? ''), res: r };
  };
  const qrBuf = await makePng({ r: 40, g: 160, b: 90 });
  const qrUp = await uploadMedia(worker1.token, qrBuf, 'wd-qr-1.png', 'withdraw_qr');
  const qrMediaId = String(qrUp.data?.id ?? '');
  ok('②-a 收款码上传（type=withdraw_qr，**protected**：返回的 path 是 /api/v1/media/protected/…）→ 201 + mediaId',
    (qrUp.status === 201 || qrUp.status === 200) && !!qrMediaId &&
      String(qrUp.data?.path ?? '').includes('/api/v1/media/protected/'),
    `status=${qrUp.status} id=${qrMediaId} path=${qrUp.data?.path}`);

  const bind = await req('POST', '/worker/withdraw/account', worker1.token, {
    realName: '张三丰', phone: '13800138000', wechatId: 'wd_test_wx01', qrMediaId,
  });
  ok('②-b 绑定成功 → 200 + **脱敏**回显（姓名 张**、手机号 138****8000），微信号本人可见',
    bind.status === 200 && bind.data?.bound === true && bind.data?.realName === '张**' &&
      bind.data?.phone === '138****8000' && bind.data?.wechatId === 'wd_test_wx01',
    j({ realName: bind.data?.realName, phone: bind.data?.phone, wechatId: bind.data?.wechatId, rebind: bind.data?.rebind }));
  ok('②-c qrUrl 走**受保护通道**（/api/v1/media/protected/…，绝不是 /media/public/…）',
    typeof bind.data?.qrUrl === 'string' && bind.data.qrUrl.includes('/api/v1/media/protected/') && !bind.data.qrUrl.includes('/media/public/'),
    `qrUrl=${bind.data?.qrUrl}`);
  const qrSelf = await fetchMedia(worker1.token, `/media/protected/${qrMediaId}`);
  ok('②-c2 收款码 public 直连被拒（受保护资源必须走 protected 通道）',
    (await req('GET', `/media/public/${qrMediaId}`, null)).status === 404,
    'GET /media/public/<id> → 404');
  ok('②-c3 本人可读自己的收款码（protected + 归属校验）', qrSelf.status === 200 && qrSelf.bytes > 0,
    `status=${qrSelf.status} bytes=${qrSelf.bytes} type=${qrSelf.type}`);

  const accAfterBind = await req('GET', '/worker/withdraw/account', worker1.token);
  ok('②-c4 重新读取仍是脱敏值（接口不会把完整姓名/手机号发给客户端）',
    accAfterBind.data?.realName === '张**' && accAfterBind.data?.phone === '138****8000' &&
      !accAfterBind.text.includes('张三丰') && !accAfterBind.text.includes('13800138000'),
    j(accAfterBind.data));

  // =========================================================================
  // ③ 换绑 → 审计留痕（新旧值摘要）
  // =========================================================================
  console.log('\n--- ③ 换绑（覆盖同一行 + 审计新旧值）---');
  const rebind = await req('POST', '/worker/withdraw/account', worker1.token, {
    realName: '张三丰', phone: '13900139000', wechatId: 'wd_test_wx02', qrMediaId,
  });
  ok('③-a 换绑成功 → 200 + rebind:true（覆盖，不新增行）',
    rebind.status === 200 && rebind.data?.rebind === true && rebind.data?.phone === '139****9000',
    j({ rebind: rebind.data?.rebind, phone: rebind.data?.phone }));
  const accRows = await q('SELECT id, real_name, phone, wechat_id, status FROM worker_withdraw_account WHERE worker_id = ?', [worker1.workerId]);
  ok('③-b 库里仍**只有一行** active（换绑 = UPDATE 同一行，不产生第二行）',
    accRows.length === 1 && accRows[0].status === 'active' && accRows[0].phone === '13900139000',
    j(accRows));

  await sleep(400); // operation_log 是异步落库（fire-and-forget），给它一点时间
  const rebindLog = (await q(
    "SELECT action, request_body FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:account:rebind' ORDER BY id DESC LIMIT 1",
  ))[0];
  let rebindAudit = null;
  try {
    rebindAudit = JSON.parse(rebindLog?.request_body ?? 'null');
  } catch {
    /* ignore */
  }
  ok('③-c 换绑写 operation_log（action=withdraw:account:rebind）+ **新旧值摘要**（before/after 都有；均**脱敏**）',
    !!rebindAudit && rebindAudit.before?.phone === '138****8000' && rebindAudit.before?.wechatId === 'wd****01' &&
      rebindAudit.after?.phone === '139****9000' && rebindAudit.after?.wechatId === 'wd****02' && rebindAudit.rebind === true &&
      rebindAudit.before?.realName === '张**' && rebindAudit.after?.realName === '张**',
    j(rebindAudit && { before: rebindAudit.before, after: rebindAudit.after }));
  ok('③-c2 审计摘要里**没有完整手机号/微信号**（operation_log 是不特定管理员可见的面 → 只记脱敏；完整值走详情）',
    !!rebindAudit && !/1[3-9]\d{9}/.test(String(rebindLog?.request_body ?? '')) &&
      !String(rebindLog?.request_body ?? '').includes('wd_test_wx02') &&
      !String(rebindLog?.request_body ?? '').includes('wd_test_wx01'),
    String(rebindLog?.request_body ?? '').slice(0, 160));
  ok('③-d 审计里**不出现**密码/token（只记业务字段）',
    !!rebindLog && !/password|token|secret/i.test(String(rebindLog.request_body)), String(rebindLog?.request_body ?? '').slice(0, 80));

  const bindLog = (await q(
    "SELECT action FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:account:bind' ORDER BY id DESC LIMIT 1",
  ))[0];
  ok('③-e 首次绑定同样留痕（action=withdraw:account:bind）', !!bindLog, j(bindLog));

  // =========================================================================
  // ④ 金额校验：< min / > max / > 余额
  // =========================================================================
  console.log('\n--- ④ 金额三道闸门（服务端权威，客户端提示不可信）---');
  const balNow = await balanceOf(worker1.userId);
  const low = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: 5 });
  ok('④-a 金额 < min(10) → 400 中文「单笔提现不能低于 ¥10.00」',
    low.status === 400 && low.message === '单笔提现不能低于 ¥10.00', `status=${low.status} message=${low.message}`);
  const high = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: 5000 });
  ok('④-b 金额 > max(2000) → 400 中文「单笔提现不能高于 ¥2000.00」',
    high.status === 400 && high.message === '单笔提现不能高于 ¥2000.00', `status=${high.status} message=${high.message}`);
  const overAmount = Math.floor(balNow) + 100 <= 2000 ? Math.floor(balNow) + 100 : 2000;
  const over = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: overAmount });
  ok(`④-c 金额 > 全部余额（余额 ${yuan(balNow)}，申请 ${yuan(overAmount)}）→ 400 中文（含当前余额）`,
    overAmount > balNow ? (over.status === 400 && String(over.message).includes('不能超过当前余额')) : over.status === 400,
    `status=${over.status} message=${over.message}`);
  const badPrecision = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: 10.005 });
  ok('④-d 超过 2 位小数 → 400 中文（DECIMAL(12,2) 精度，不静默改写金额）',
    badPrecision.status === 400 && isChinese(badPrecision.message), `status=${badPrecision.status} message=${badPrecision.message}`);
  ok('④-e 三次被拒都不产生单据（校验在事务/扣款之前）',
    Number((await q('SELECT COUNT(*) AS n FROM withdraw_request WHERE worker_id = ?', [worker1.workerId]))[0].n) === 0 &&
      (await balanceOf(worker1.userId)) === balNow,
    `balance=${await balanceOf(worker1.userId)}`);

  // =========================================================================
  // ⑤ 正常申请 → 余额立即减少 + 流水 withdraw
  // =========================================================================
  console.log('\n--- ⑤ 申请即扣款（同一事务：扣款 + 流水 + 建 pending）---');
  const balanceBefore5 = await balanceOf(worker1.userId);
  const applyKey = idem('wd-apply');
  const apply = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: AMOUNT }, { 'Idempotency-Key': applyKey });
  const p1 = trackReq(apply.data?.id);
  const balanceAfter5 = await balanceOf(worker1.userId);
  console.log(`      [余额快照] 申请前 ${yuan(balanceBefore5)} → 申请后 ${yuan(balanceAfter5)}（差额 ${yuan(balanceBefore5 - balanceAfter5)}）`);
  ok('⑤-a 申请成功 → 201 + status:pending + 返回 balanceAfter（= 申请后余额）',
    apply.status === 201 && apply.data?.status === 'pending' && !!p1 &&
      Number(apply.data?.balanceAfter) === balanceBefore5 - AMOUNT,
    `status=${apply.status} id=${p1} balanceAfter=${apply.data?.balanceAfter}`);
  ok('⑤-b **余额在同一请求内立即减少**（服务端读库复核：before - 100 = after）',
    balanceAfter5 === balanceBefore5 - AMOUNT, `${yuan(balanceBefore5)} → ${yuan(balanceAfter5)}`);
  const txn5 = await txnOf(`withdraw:${p1}`);
  ok('⑤-c 流水里有 withdraw 记录（幂等键 withdraw:<id>；金额为负、含前后余额快照）',
    !!txn5 && txn5.change_type === 'withdraw' && Number(txn5.amount) === -AMOUNT &&
      Number(txn5.balance_before) === balanceBefore5 && Number(txn5.balance_after) === balanceAfter5,
    j(txn5 && { type: txn5.change_type, amount: Number(txn5.amount), before: Number(txn5.balance_before), after: Number(txn5.balance_after), no: txn5.transaction_no }));
  ok('⑤-d 单据回写了 wallet_transaction_id（审计：扣的是哪一笔）',
    String((await reqRow(p1))?.wallet_transaction_id ?? '') === String(txn5?.id ?? ''), `txn=${txn5?.id}`);
  const noti5 = await q("SELECT type, content FROM user_notification WHERE user_id = ? AND type = 'withdraw_applied' ORDER BY id DESC LIMIT 1", [worker1.userId]);
  ok('⑤-e 打手收到站内通知（withdraw_applied，含 ¥ 金额与"已从余额扣除"）',
    noti5.length === 1 && noti5[0].content.includes('已从余额扣除') && noti5[0].content.includes('¥100.00'),
    j(noti5[0]));

  // 幂等：同一 Idempotency-Key 重复提交 → 返回首次结果，不重复扣款
  const balanceBefore5b = await balanceOf(worker1.userId);
  const applyDup = await req('POST', '/worker/withdraw/requests', worker1.token, { amount: AMOUNT }, { 'Idempotency-Key': applyKey });
  ok('⑤-f 同一幂等键重复提交 → 返回**首次单据**（id 相同、duplicated:true、余额不再变化）',
    String(applyDup.data?.id) === p1 && applyDup.data?.duplicated === true &&
      (await balanceOf(worker1.userId)) === balanceBefore5b,
    `id=${applyDup.data?.id} balance=${await balanceOf(worker1.userId)}`);

  // ②-d / ②-e：列表给**完整 + 脱敏两份**、详情给完整（需要先有一张申请单）
  const listAdmin = await req('GET', '/admin/withdraw/requests?status=all&page=1&pageSize=50', adminToken);
  const listItem = (listAdmin.data?.list ?? []).find((x) => String(x.id) === p1);
  ok('②-d 管理端**列表**：打手昵称/工号/金额/状态/申请时间齐全 + 收款信息**两份并存**（完整 `account` + 兼容 `accountMasked`）',
    !!listItem && listItem.workerNo === 'W001' && !!listItem.workerNickname && Number(listItem.amount) === AMOUNT &&
      listItem.status === 'pending' && !!listItem.appliedAt &&
      listItem.account?.realName === '张三丰' && listItem.account?.phone === '13900139000' &&
      listItem.account?.wechatId === 'wd_test_wx02' &&
      listItem.accountMasked?.realName === '张**' && listItem.accountMasked?.phone === '139****9000' &&
      listItem.accountMasked?.wechatId === 'wd****02',
    j(listItem && { no: listItem.workerNo, nick: listItem.workerNickname, amount: listItem.amount, status: listItem.status, account: listItem.account, masked: listItem.accountMasked }));
  const detailAdmin = await req('GET', `/admin/withdraw/requests/${p1}`, adminToken);
  ok('②-e 管理端**详情**：完整姓名/电话/微信号 + 收款码链接（审核必需）',
    detailAdmin.status === 200 && detailAdmin.data?.account?.realName === '张三丰' &&
      detailAdmin.data?.account?.phone === '13900139000' && detailAdmin.data?.account?.wechatId === 'wd_test_wx02' &&
      String(detailAdmin.data?.account?.qrUrl ?? '').includes('/api/v1/media/protected/'),
    j(detailAdmin.data?.account));

  // =========================================================================
  // ⑥ 并发两笔 → 只成功一笔（SQL 证据）
  // =========================================================================
  console.log('\n--- ⑥ 并发两笔（同一打手同时提交）→ 只成功一笔 ---');
  // 前置：W2 也要先绑定收款信息（否则一律 400「请先绑定收款信息」，测不到并发面）
  const w2bind = await bindAccount(worker2, {
    realName: '李四海', phone: '13700137000', wechatId: 'wd_e2e_w2', tag: 'w2', rgb: { r: 205, g: 120, b: 45 },
  });
  ok('⑥-夹具：W2 收款信息已绑定（并发用例的前置条件）',
    w2bind.res.status === 200 && w2bind.res.data?.bound === true,
    `status=${w2bind.res.status} ${w2bind.res.message ?? ''}`);
  const balanceBefore6 = await balanceOf(worker2.userId);
  const [c1, c2] = await Promise.all([
    req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT }),
    req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT }),
  ]);
  const winners = [c1, c2].filter((r) => r.status === 201);
  const losers = [c1, c2].filter((r) => r.status !== 201);
  console.log(`      并发结果：A=${c1.status} ${c1.message ?? ''} ｜ B=${c2.status} ${c2.message ?? ''}`);
  ok('⑥-a 恰好一笔成功（不是两笔都成功）', winners.length === 1, j([c1.status, c2.status]));
  ok('⑥-b 另一笔是**中文 409「你有一笔提现正在处理中…」**（不是 500、不是静默成功）',
    losers.length === 1 && losers[0].status === 409 &&
      String(losers[0].message).includes('你有一笔提现正在处理中'),
    j(losers.map((x) => ({ s: x.status, m: x.message }))));
  const p2 = trackReq(winners[0]?.data?.id);
  const pendingRows2 = await q("SELECT id, amount, status, wallet_transaction_id FROM withdraw_request WHERE worker_id = ? AND status = 'pending'", [worker2.workerId]);
  const allRows2 = await q('SELECT id, status, wallet_transaction_id FROM withdraw_request WHERE worker_id = ? ORDER BY id', [worker2.workerId]);
  const txnRows2 = await q(
    "SELECT id, change_type, amount, idempotency_key FROM wallet_transaction WHERE user_id = ? AND change_type = 'withdraw' AND created_at >= ?",
    [worker2.userId, RUN_START_DB],
  );
  console.log(`      [SQL 证据] SELECT ... WHERE worker_id=${worker2.workerId} AND status='pending' → ${j(pendingRows2)}`);
  console.log(`      [SQL 证据] 本轮（清理后）该打手的全部申请行 → ${j(allRows2)}`);
  console.log(`      [SQL 证据] 本轮该打手的 withdraw 流水 → ${j(txnRows2)}`);
  ok('⑥-c SQL：pending **恰好 1 行**（未结清上限 1 由唯一键 UK_wr_pending_worker 兜底）',
    pendingRows2.length === 1 && String(pendingRows2[0].id) === p2, `pending=${pendingRows2.length}`);
  ok('⑥-c2 SQL：本轮该打手**总共只落了 1 行申请**（两笔并发里失败那笔连单据都没有）',
    allRows2.length === 1 && String(allRows2[0].id) === p2, j(allRows2));
  ok('⑥-d SQL：该打手本轮 withdraw 流水**恰好 1 条**（失败那笔没有扣款）',
    txnRows2.length === 1 && Number(txnRows2[0].amount) === -AMOUNT, j(txnRows2));
  ok('⑥-e 余额只扣了一次', (await balanceOf(worker2.userId)) === balanceBefore6 - AMOUNT,
    `${yuan(balanceBefore6)} → ${yuan(await balanceOf(worker2.userId))}`);

  // 每日次数（dailyLimit=1）的单独验证放在 ⑧ 之后：
  // 必须先解决掉那笔在途单据（否则先命中的是"你有一笔提现正在处理中"那条 409，测不到次数字段）

  // =========================================================================
  // ⑦ 管理端 pay → paid + 凭证可读 + 重复 pay 中文 400（无二次生效）
  // =========================================================================
  console.log('\n--- ⑦ 管理端打款（条件 UPDATE 判 affectedRows；重复调用不二次生效）---');
  const proofUp = await uploadMedia(adminToken, await makePng({ r: 30, g: 90, b: 200 }), 'wd-proof-1.png', 'withdraw_proof');
  const proofMediaId = String(proofUp.data?.id ?? '');
  ok('⑦-a 打款凭证上传（type=withdraw_proof，**protected**：返回的 path 是 /api/v1/media/protected/…）→ 201 + mediaId',
    (proofUp.status === 201 || proofUp.status === 200) && !!proofMediaId &&
      String(proofUp.data?.path ?? '').includes('/api/v1/media/protected/'),
    `status=${proofUp.status} id=${proofMediaId} path=${proofUp.data?.path}`);

  const txnCountBefore7 = Number((await q('SELECT COUNT(*) AS n FROM wallet_transaction WHERE user_id = ?', [worker1.userId]))[0].n);
  const pay1 = await req('POST', `/admin/withdraw/requests/${p1}/pay`, adminToken, { proofMediaId, note: '微信转账尾号 8842' });
  ok('⑦-b pay → 200 + status:paid', pay1.status === 200 && pay1.data?.status === 'paid',
    `status=${pay1.status} ${j(pay1.data ?? pay1.message)}`);
  const row7 = await reqRow(p1);
  /**
   * ⚠️ 2026-10-11：`reqRow()` 在"前置申请没造出来"（如限流 429 导致 p1 为空）时返回 **null** ——
   * 这里以及 ⑦-g / ⑬-②-b 三处原本直接取 `row.status`，会把整个套件**中断在收尾之前**，
   * 于是"自建自清"根本没机会跑（实测：全局限流 300 次/分/IP 被连跑三遍触发 → 一串红后抛
   * `Cannot read properties of null`）。断言级联一律只报红、不许中断收尾 → 全部改可选链。
   */
  ok('⑦-c SQL：单据 → paid、paid_by/paid_at/凭证/备注全部落库（审计三件套齐）',
    row7?.status === 'paid' && String(row7?.paid_by) === adminUserId && !!row7?.paid_at &&
      String(row7?.payout_proof_media_id) === proofMediaId && row7?.payout_note === '微信转账尾号 8842',
    j({ status: row7?.status, paid_by: row7?.paid_by, paid_at: row7?.paid_at, proof: row7?.payout_proof_media_id }));

  const proofRead = await fetchMedia(adminToken, `/admin/withdraw/proof/${p1}?kind=payout`);
  ok('⑦-d 打款凭证**可读**（受保护窄通道 GET /admin/withdraw/proof/:id?kind=payout → 200 图片）',
    proofRead.status === 200 && proofRead.type.startsWith('image/') && proofRead.bytes > 0,
    `status=${proofRead.status} type=${proofRead.type} bytes=${proofRead.bytes}`);
  const qrRead = await fetchMedia(adminToken, `/admin/withdraw/proof/${p1}?kind=qr`);
  ok('⑦-e 收款码也走同一条窄通道可读（kind=qr → 200）',
    qrRead.status === 200 && qrRead.bytes > 0, `status=${qrRead.status} bytes=${qrRead.bytes}`);

  const payAgain = await req('POST', `/admin/withdraw/requests/${p1}/pay`, adminToken, { proofMediaId, note: '重复点击' });
  ok('⑦-f **重复 pay → 中文 400「该申请已打款」**（不是 200、不是 500）',
    payAgain.status === 400 && payAgain.message === '该申请已打款', `status=${payAgain.status} message=${payAgain.message}`);
  const row7b = await reqRow(p1);
  ok('⑦-g 重复 pay **无二次生效**（状态仍 paid；凭证/备注未被覆盖；余额流水条数不变）',
    row7b?.status === 'paid' && String(row7b?.payout_proof_media_id) === proofMediaId &&
      row7b?.payout_note === '微信转账尾号 8842' &&
      Number((await q('SELECT COUNT(*) AS n FROM wallet_transaction WHERE user_id = ?', [worker1.userId]))[0].n) === txnCountBefore7,
    j({ note: row7b.payout_note, txns: txnCountBefore7 }));
  const noti7 = await q("SELECT content FROM user_notification WHERE user_id = ? AND type = 'withdraw_paid' ORDER BY id DESC LIMIT 1", [worker1.userId]);
  ok('⑦-h 打手收到「提现已打款：¥100.00」通知',
    noti7.length === 1 && noti7[0].content.includes('提现已打款') && noti7[0].content.includes('¥100.00'), j(noti7[0]));
  await sleep(400);
  const payLog = (await q("SELECT action, admin_id FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:pay' ORDER BY id DESC LIMIT 1"))[0];
  ok('⑦-i 打款写 operation_log（action=withdraw:pay，带管理员 id）',
    !!payLog && String(payLog.admin_id) === adminUserId, j(payLog));

  // =========================================================================
  // ⑧ reject → 退回余额 + 反向流水
  // =========================================================================
  console.log('\n--- ⑧ 驳回（退回余额 + 反向流水 withdraw_reject）---');
  const balanceBefore8 = await balanceOf(worker2.userId);
  const reject1 = await req('POST', `/admin/withdraw/requests/${p2}/reject`, adminToken, { reason: '收款信息与实名不符，请重新绑定后再提交' });
  const balanceAfter8 = await balanceOf(worker2.userId);
  console.log(`      [余额快照] 驳回前 ${yuan(balanceBefore8)} → 驳回后 ${yuan(balanceAfter8)}（退回 ${yuan(balanceAfter8 - balanceBefore8)}）`);
  ok('⑧-a reject → 200 + status:rejected + refunded:true',
    reject1.status === 200 && reject1.data?.status === 'rejected' && reject1.data?.refunded === true,
    `status=${reject1.status} ${j(reject1.data ?? reject1.message)}`);
  ok('⑧-b **余额退回**（服务端读库复核：驳回前 + 100 = 驳回后）',
    balanceAfter8 === balanceBefore8 + AMOUNT, `${yuan(balanceBefore8)} → ${yuan(balanceAfter8)}`);
  const txn8 = await txnOf(`withdraw_reject:${p2}`);
  ok('⑧-c 反向流水落库（幂等键 withdraw_reject:<id>、change_type=withdraw_reject、金额为正、含前后余额快照）',
    !!txn8 && txn8.change_type === 'withdraw_reject' && Number(txn8.amount) === AMOUNT &&
      Number(txn8.balance_before) === balanceBefore8 && Number(txn8.balance_after) === balanceAfter8,
    j(txn8 && { type: txn8.change_type, amount: Number(txn8.amount), before: Number(txn8.balance_before), after: Number(txn8.balance_after), no: txn8.transaction_no }));
  const row8 = await reqRow(p2);
  ok('⑧-d SQL：单据 → rejected、rejected_by/rejected_at/reject_reason 落库',
    !!row8 && row8.status === 'rejected' && String(row8.rejected_by) === adminUserId && !!row8.rejected_at &&
      String(row8.reject_reason).includes('收款信息与实名不符'),
    j(row8 && { status: row8.status, by: row8.rejected_by, reason: row8.reject_reason }));
  const detail8 = await req('GET', `/admin/withdraw/requests/${p2}`, adminToken);
  ok('⑧-e 详情里能看到退款那条反向流水（transactionNo + 前后余额）',
    !!detail8.data?.rejectTransaction?.transactionNo &&
      Number(detail8.data?.rejectTransaction?.balanceAfter) === balanceAfter8,
    j(detail8.data?.rejectTransaction));
  const noti8 = await q("SELECT content FROM user_notification WHERE user_id = ? AND type = 'withdraw_rejected' ORDER BY id DESC LIMIT 1", [worker2.userId]);
  ok('⑧-f 打手收到「提现被驳回：¥100.00 已退回余额，原因：…」通知',
    noti8.length === 1 && noti8[0].content.includes('已退回余额') && noti8[0].content.includes('¥100.00'), j(noti8[0]));

  const rejectAgain = await req('POST', `/admin/withdraw/requests/${p2}/reject`, adminToken, { reason: '再驳一次' });
  ok('⑧-g **重复 reject → 中文 400「该申请已驳回，不能重复操作」**，且**不会二次退款**',
    rejectAgain.status === 400 && rejectAgain.message === '该申请已驳回，不能重复操作' &&
      (await balanceOf(worker2.userId)) === balanceAfter8,
    `status=${rejectAgain.status} message=${rejectAgain.message} balance=${yuan(await balanceOf(worker2.userId))}`);
  /**
   * ⚠️ 2026-10-11：`pay` 的校验收紧为「**必须带 `proofMediaId`**」（见 ⑬-③），
   * 因此这里必须带上 ⑦-a 上传的那张凭证 —— 否则命中的是"请上传打款凭证"，
   * 测不到"状态机单向"这条（本条要测的是**单据状态**，不是凭证校验）。
   */
  const payRejected = await req('POST', `/admin/withdraw/requests/${p2}/pay`, adminToken, { proofMediaId, note: '已驳回还想打款' });
  ok('⑧-h 已驳回的单据不能再打款 → 中文 400（状态机是单向的）',
    payRejected.status === 400 && String(payRejected.message).includes('已驳回'),
    `status=${payRejected.status} message=${payRejected.message}`);

  // ⑥-f（移到此处执行）：在途单据已解决 → 单独验证「每日次数」这道闸门
  const dailyBlocked = await req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT });
  ok('⑥-f dailyLimit=1：在途已结清后，今日再次申请 → 400 中文「今日提现申请次数已用完」（服务端权威，客户端提示不算数）',
    dailyBlocked.status === 400 && String(dailyBlocked.message).includes('今日提现申请次数已用完'),
    `status=${dailyBlocked.status} message=${dailyBlocked.message}`);

  // =========================================================================
  // ⑨ 权限：非超管（无 withdraw:review / withdraw:pay）→ 403 中文
  // =========================================================================
  console.log('\n--- ⑨ 权限（仅超管；复用既有 operator 角色的夹具账号）---');
  const limited = await fixtures.ensureAdmin(adminToken, { username: LIMITED_ADMIN, password: FIXTURE_ADMIN_PASSWORD, roleCode: 'operator' });
  ok('⑨-a 夹具：非超管管理端账号登录成功（角色 operator，**不带** withdraw:* 任何权限点）',
    !!limited.token && limited.roleCode === 'operator', `role=${limited.roleCode} reused=${limited.reused}`);

  const limitedList = await req('GET', '/admin/withdraw/requests?page=1', limited.token);
  ok('⑨-b 无 `withdraw:review` 读列表 → **403 中文**（不泄漏任何提现数据）',
    limitedList.status === 403 && isChinese(limitedList.message),
    `status=${limitedList.status} message=${limitedList.message}`);

  const freshPending = await (async () => {
    // 造一张新的 pending 单据（用 worker2；先把它今日次数上限放宽，避免 dailyLimit 干扰本用例）
    const cfgNow = await req('GET', '/admin/withdraw/config', adminToken);
    await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: 5 });
    const r = await req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT });
    await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: cfgNow.data?.dailyLimit ?? 1 });
    return r;
  })();
  const p3 = trackReq(freshPending.data?.id);
  ok('⑨-c 夹具：新造一张 pending 单据（供权限用例；dailyLimit 临时放开后已还原）',
    freshPending.status === 201 && !!p3, `id=${p3} status=${freshPending.status}`);

  const limitedPay = await req('POST', `/admin/withdraw/requests/${p3}/pay`, limited.token, { note: '越权打款' });
  ok('⑨-d 无 `withdraw:pay` 调 pay → **403 中文**（且单据仍是 pending，未被越权改动）',
    limitedPay.status === 403 && isChinese(limitedPay.message) && (await reqRow(p3))?.status === 'pending',
    `status=${limitedPay.status} message=${limitedPay.message} dbStatus=${(await reqRow(p3))?.status}`);
  const limitedReject = await req('POST', `/admin/withdraw/requests/${p3}/reject`, limited.token, { reason: '越权驳回' });
  ok('⑨-e 无 `withdraw:pay` 调 reject → 403 中文（退回动作同样拦死）',
    limitedReject.status === 403 && isChinese(limitedReject.message), `status=${limitedReject.status} message=${limitedReject.message}`);
  const limitedCfg = await req('PUT', '/admin/withdraw/config', limited.token, { minAmount: 1 });
  ok('⑨-f 改提现配置 → 403（operator 无 admin:setting:write，且配置行 is_high_security=1 仅超管）',
    limitedCfg.status === 403 && isChinese(limitedCfg.message), `status=${limitedCfg.status} message=${limitedCfg.message}`);
  const limitedSession = await req('GET', '/withdraw/requests', limited.token);
  ok('⑨-g primary 管理员会话打 `/withdraw/*`（App 管理员态专用路径）→ 403 中文（两条入口语义不分叉）',
    limitedSession.status === 403 && isChinese(limitedSession.message),
    `status=${limitedSession.status} message=${limitedSession.message}`);

  // 收尾：把 ⑨-c 造的 pending 单据驳掉（退回余额，避免留下悬空在途）
  const cleanupP3 = p3 ? await req('POST', `/admin/withdraw/requests/${p3}/reject`, adminToken, { reason: 'e2e 收尾清理' }) : null;
  ok('⑨-h 收尾：⑨-c 造的 pending 单据已驳回（余额退回，不留悬空在途）',
    !p3 || (cleanupP3.status === 200 && (await reqRow(p3))?.status === 'rejected'),
    `status=${cleanupP3?.status}`);

  // =========================================================================
  // ⑩ App 内「管理员身份」（受限会话 kind='recharge'）
  // =========================================================================
  console.log('\n--- ⑩ App 内「管理员身份」：/withdraw/* 可用、/admin/withdraw/* 不可用 ---');
  const wlBefore = await req('GET', '/admin/recharge/admins', adminToken);
  const alreadyWhitelisted = (wlBefore.data?.list ?? []).some((x) => String(x.adminUserId) === adminUserId);
  let addedByUs = false;
  if (!alreadyWhitelisted) {
    const add = await req('POST', '/admin/recharge/admins', adminToken, { adminUserId });
    addedByUs = add.status === 201 || add.status === 200;
    console.log(`      （前置：把 ${adminUser} 临时加入充值审核白名单 status=${add.status}）`);
  }
  const bindRecharge = await req('POST', '/user/identity/bind-recharge-admin', adminToken, {
    username: adminUser, password: adminPw,
  });
  const rechargeToken = bindRecharge.data?.rechargeToken;
  ok('⑩-a 绑定管理员身份 → 受限会话令牌（kind=recharge，12h，不顶 primary）',
    bindRecharge.status === 200 && !!rechargeToken, `status=${bindRecharge.status} ${bindRecharge.message ?? ''}`);

  const rcList = await req('GET', '/withdraw/requests?status=all&page=1&pageSize=20', rechargeToken);
  ok('⑩-b 受限会话 GET /withdraw/requests → 200（白名单**显式新增** /withdraw/* 后可用；与 PC 管理端同一服务层）',
    rcList.status === 200 && Array.isArray(rcList.data?.list),
    `status=${rcList.status} ${rcList.message ?? ''} n=${rcList.data?.list?.length}`);
  const rcItem = (rcList.data?.list ?? []).find((x) => String(x.id) === p1);
  ok('⑩-c 受限会话列表与 PC **逐字一致**：同样给完整 `account`（并保留 `accountMasked`）',
    !!rcItem && rcItem.account?.phone === '13900139000' && rcItem.account?.realName === '张三丰' &&
      rcItem.accountMasked?.phone === '139****9000',
    j({ account: rcItem?.account, masked: rcItem?.accountMasked }));
  const rcProof = await fetchMedia(rechargeToken, `/withdraw/proof/${p1}?kind=payout`);
  ok('⑩-d 受限会话走**窄通道**读打款凭证 → 200（白名单里没有 /media/*，这是刻意的收窄）',
    rcProof.status === 200 && rcProof.bytes > 0, `status=${rcProof.status} bytes=${rcProof.bytes}`);
  const rcAdmin = await req('GET', '/admin/withdraw/requests?page=1', rechargeToken);
  ok('⑩-e 受限会话调 `/admin/withdraw/*` → **403 中文**（允许清单默认拒绝；管理端路径必须走 primary 会话）',
    rcAdmin.status === 403 && isChinese(rcAdmin.message), `status=${rcAdmin.status} message=${rcAdmin.message}`);
  const rcSetting = await req('PUT', '/withdraw/config', rechargeToken, { minAmount: 1 });
  ok('⑩-f 受限会话**没有**配置写入路径（/withdraw/config 不存在 → 404；改门槛只走管理端 primary）',
    rcSetting.status === 404, `status=${rcSetting.status}`);
  // =========================================================================
  // ⑬ App 内「管理员身份」上传打款凭证（2026-10-11 新增窄通道）
  //    POST /withdraw/requests/:id/pay-proof（multipart 字段 file；type 固定 withdraw_proof）
  //    —— 白名单**一个字都没改**：新路径落在既有的 `/withdraw/*` 前缀内，也没有放宽 /media/*
  // =========================================================================
  console.log('\n--- ⑬ 受限会话上传打款凭证（新端点；只能给"这张 pending 申请"传图）---');

  /** 新端点的唯一调用姿势：multipart 字段 `file`，**不带 type**（用途由服务端定死） */
  const uploadPayProof = async (token, requestId, buffer, filename, mime = 'image/png') => {
    const fd = new FormData();
    fd.append('file', new File([buffer], filename, { type: mime }));
    const r = await fetch(`${BASE}/withdraw/requests/${requestId}/pay-proof`, {
      method: 'POST',
      headers: token ? { Authorization: 'Bearer ' + token } : {},
      body: fd,
    });
    const text = await r.text();
    SCRAPED.push({ method: 'POST(multipart)', path: `/withdraw/requests/${requestId}/pay-proof`, status: r.status, text });
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      /* ignore */
    }
    return { status: r.status, json, data: json?.data, message: json?.message, text };
  };

  // 前置：临时放开每日次数（W2 今日已用过 2 次），为它造一张新的 pending 单据 p4
  const cfg13 = await req('GET', '/admin/withdraw/config', adminToken);
  await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: 5 });
  const p4res = await req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT });
  const p4 = trackReq(p4res.data?.id);
  ok('⑬-夹具：为 W2 新造一张 pending 单据 p4（dailyLimit 临时放开到 5，本节结束还原）',
    p4res.status === 201 && !!p4, `id=${p4} status=${p4res.status} ${p4res.message ?? ''}`);

  // ---------- ① 受限会话上传 → 200 + mediaId ----------
  const up1 = await uploadPayProof(rechargeToken, p4, await makePng({ r: 20, g: 140, b: 220 }), 'wd-app-proof-1.png');
  const mediaId1 = String(up1.data?.mediaId ?? '');
  ok('⑬-① 受限会话上传凭证 → **200 + mediaId**（type 由服务端固定 withdraw_proof，客户端不传 type）',
    up1.status === 200 && !!mediaId1, `status=${up1.status} mediaId=${mediaId1} ${up1.message ?? ''}`);
  const upMediaRow = await q('SELECT media_type, is_protected, uploader_id FROM media WHERE id = ?', [mediaId1]);
  ok('⑬-①-b 媒体行：用途 withdraw_proof + **is_protected=1**（资金凭证绝不公开直连）',
    upMediaRow.length === 1 && upMediaRow[0].media_type === 'withdraw_proof' && Number(upMediaRow[0].is_protected) === 1,
    j(upMediaRow[0]));
  ok('⑬-①-c 返回体**恰好** `{mediaId, url}`：url 是既有受保护取图约定（/api/v1/media/protected/…），不含磁盘路径',
    j(Object.keys(up1.data ?? {}).sort()) === j(['mediaId', 'url']) &&
      String(up1.data?.url ?? '').startsWith('/api/v1/media/protected/') &&
      !up1.text.includes('uploads') && !/[A-Za-z]:\\/.test(up1.text),
    `keys=${j(Object.keys(up1.data ?? {}).sort())} url=${up1.data?.url}`);
  const boundRow = await reqRow(p4);
  ok('⑬-①-d 凭证已绑到**这张申请**（payout_proof_media_id = mediaId，仍 pending）',
    String(boundRow?.payout_proof_media_id ?? '') === mediaId1 && boundRow?.status === 'pending',
    j({ proof: boundRow?.payout_proof_media_id, status: boundRow?.status }));

  const back1 = await fetchMedia(rechargeToken, `/withdraw/proof/${p4}?kind=payout`);
  ok('⑬-③ 受限会话**立刻读回自己刚传的图**（GET /withdraw/proof/:id?kind=payout → 200 图片；读通道本就在白名单内）',
    back1.status === 200 && back1.type.startsWith('image/') && back1.bytes > 0,
    `status=${back1.status} type=${back1.type} bytes=${back1.bytes}`);

  const up2 = await uploadPayProof(rechargeToken, p4, await makePng({ r: 200, g: 70, b: 40 }), 'wd-app-proof-2.png');
  const mediaId2 = String(up2.data?.mediaId ?? '');
  const reboundRow = await reqRow(p4);
  ok('⑬-幂等：同一申请**重复上传 → 允许**，且**后传的成为新凭证**（每次留痕，见 ⑦）',
    up2.status === 200 && !!mediaId2 && mediaId2 !== mediaId1 &&
      String(reboundRow?.payout_proof_media_id ?? '') === mediaId2,
    `old=${mediaId1} new=${mediaId2} row=${reboundRow?.payout_proof_media_id}`);

  const badFile = await uploadPayProof(rechargeToken, p4, Buffer.from('this is definitely not an image'), 'wd-app-proof.txt', 'text/plain');
  ok('⑬-①-e 非图片文件 → 400 中文（沿用 `MediaService` 既有魔数/用途校验，没有自创第二套）',
    badFile.status === 400 && isChinese(badFile.message), `status=${badFile.status} message=${badFile.message}`);
  const noFile = await uploadPayProof(rechargeToken, p4, Buffer.alloc(0), 'wd-app-empty.png');
  ok('⑬-①-f 空文件 → 400 中文（服务端先拦，不落盘）',
    noFile.status === 400 && isChinese(noFile.message), `status=${noFile.status} message=${noFile.message}`);

  // ---------- ② pay 只带 proofMediaId（不带备注）→ 200 且凭证可读 ----------
  const payApp = await req('POST', `/withdraw/requests/${p4}/pay`, rechargeToken, { proofMediaId: mediaId2 });
  ok('⑬-② 受限会话 pay **只带 proofMediaId**（不传备注）→ 200 + status:paid（App 侧凭证真正可用）',
    payApp.status === 200 && payApp.data?.status === 'paid',
    `status=${payApp.status} ${j(payApp.data ?? payApp.message)}`);
  const paidRow = await reqRow(p4);
  ok('⑬-②-b SQL：paid + paid_by + 凭证 = 刚上传的 mediaId + 备注为空（**备注可选**，不再是凭证的替代品）',
    paidRow?.status === 'paid' && String(paidRow?.paid_by) === adminUserId &&
      String(paidRow?.payout_proof_media_id) === mediaId2 && !paidRow?.payout_note,
    j({ status: paidRow?.status, by: paidRow?.paid_by, proof: paidRow?.payout_proof_media_id, note: paidRow?.payout_note }));
  const back2 = await fetchMedia(rechargeToken, `/withdraw/proof/${p4}?kind=payout`);
  ok('⑬-②-c 打款后受限会话仍能读回该凭证（kind=payout → 200 图片）',
    back2.status === 200 && back2.bytes > 0, `status=${back2.status} bytes=${back2.bytes}`);

  // ---------- ④ 已被 pay 掉的申请再传 → 400 中文 ----------
  const paidUp = await uploadPayProof(rechargeToken, p4, await makePng({ r: 9, g: 9, b: 9 }), 'wd-app-proof-3.png');
  ok('⑬-④ 对**已 paid** 的申请再上传 → **400 中文「该申请已打款」**，且既有凭证不被覆盖',
    paidUp.status === 400 && paidUp.message === '该申请已打款' &&
      String((await reqRow(p4))?.payout_proof_media_id) === mediaId2,
    `status=${paidUp.status} message=${paidUp.message} proof=${(await reqRow(p4))?.payout_proof_media_id}`);

  // ---------- ③ 新规则：只带备注 → 中文 400（凭证必填）----------
  const p5res = await req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT });
  const p5 = trackReq(p5res.data?.id);
  const noteOnly = await req('POST', `/withdraw/requests/${p5}/pay`, rechargeToken, { note: '微信转账尾号 1234' });
  ok('⑬-③ **不传凭证只带备注 → 400 中文「请上传打款凭证」**（新规则：必须至少有 proofMediaId）',
    noteOnly.status === 400 && noteOnly.message === '请上传打款凭证',
    `status=${noteOnly.status} message=${noteOnly.message}`);
  const p5row = await reqRow(p5);
  ok('⑬-③-b 被拒时单据**未发生任何状态变化**（仍 pending、paid_by/凭证/备注全空）',
    p5row?.status === 'pending' && !p5row?.paid_by && !p5row?.payout_proof_media_id && !p5row?.payout_note,
    j({ status: p5row?.status, by: p5row?.paid_by, proof: p5row?.payout_proof_media_id, note: p5row?.payout_note }));
  const pcNoteOnly = await req('POST', `/admin/withdraw/requests/${p5}/pay`, adminToken, { note: '只填备注（PC）' });
  ok('⑬-③-c **同一处校验**：PC 管理端"只带备注"同样 400 中文（收口在 `WithdrawService.pay` → 以更严的为准）',
    pcNoteOnly.status === 400 && pcNoteOnly.message === '请上传打款凭证',
    `status=${pcNoteOnly.status} message=${pcNoteOnly.message}`);

  // ---------- ⑤ 不存在 / 别人的申请：404（不泄漏存在性）----------
  const ghost = await uploadPayProof(rechargeToken, '999999999', await makePng({ r: 1, g: 2, b: 3 }), 'wd-ghost.png');
  ok('⑬-⑤ 对**不存在的**申请上传 → **404 中文「提现申请不存在」**（文案里没有任何业务数据/回显 id）',
    ghost.status === 404 && ghost.message === '提现申请不存在', `status=${ghost.status} message=${ghost.message}`);
  const otherWorkerUp = await uploadPayProof(rechargeToken, p1, await makePng({ r: 3, g: 2, b: 1 }), 'wd-other.png');
  ok('⑬-⑤-b 管理员态对**别的打手（W1）的申请**也可见（审核面本就跨打手）→ 但那张已 paid → 400 中文（收窄点是"这张单子的状态"）',
    otherWorkerUp.status === 400 && otherWorkerUp.message === '该申请已打款',
    `status=${otherWorkerUp.status} message=${otherWorkerUp.message}`);

  // ---------- ⑥ 非受限会话（老板 primary / 管理端 primary）→ 403 中文 ----------
  const bossUp = await uploadPayProof(bossToken, p5, await makePng({ r: 60, g: 60, b: 200 }), 'wd-boss.png');
  ok('⑬-⑥ **老板 primary token** 打这条 → **403 中文**（RechargeSessionGuard：只接受受限管理会话）',
    bossUp.status === 403 && isChinese(bossUp.message), `status=${bossUp.status} message=${bossUp.message}`);
  const bossGhost = await uploadPayProof(bossToken, '999999999', await makePng({ r: 62, g: 62, b: 202 }), 'wd-boss-ghost.png');
  ok('⑬-⑥-b 非受限会话对**不存在的 id** 也是 403（**不是 404**）→ 守卫先于任何存在性查询，没有存在性 oracle',
    bossGhost.status === 403 && isChinese(bossGhost.message), `status=${bossGhost.status} message=${bossGhost.message}`);
  const adminPrimaryUp = await uploadPayProof(adminToken, p5, await makePng({ r: 61, g: 61, b: 201 }), 'wd-admin-primary.png');
  ok('⑬-⑥-c 管理端 primary token 同样 403（双层口径：PC 走 /admin/withdraw/* + /admin/media/upload）',
    adminPrimaryUp.status === 403 && isChinese(adminPrimaryUp.message),
    `status=${adminPrimaryUp.status} message=${adminPrimaryUp.message}`);

  // ---------- 白名单：只开了 pay-proof 这一条，**没有**顺手放宽 /media/* ----------
  const mediaDirect = await uploadMedia(rechargeToken, await makePng({ r: 5, g: 200, b: 5 }), 'wd-wl-check.png', 'withdraw_proof');
  ok('⑬-白名单 受限会话直传 `/media/upload` **仍 403 中文**（新端点落在既有 `/withdraw/*` 前缀内 → 白名单一个字没改）',
    mediaDirect.status === 403 && isChinese(mediaDirect.message),
    `status=${mediaDirect.status} message=${mediaDirect.message}`);

  // ---------- ⑦ operation_log 留痕（每次成功上传一条；被拒的不留痕）----------
  await sleep(800);
  const proofLogs = await q(
    "SELECT admin_id, action, method, path, request_body FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:pay-proof' AND request_body LIKE ? ORDER BY id DESC",
    [`%"requestId":"${p4}"%`],
  );
  console.log(`      [SQL 证据] SELECT admin_id, action, path, request_body FROM operation_log WHERE action='withdraw:pay-proof' → ${j(proofLogs[0] ?? null)}`);
  let proofAudit = null;
  try {
    proofAudit = JSON.parse(proofLogs[0]?.request_body ?? 'null');
  } catch {
    /* ignore */
  }
  ok('⑬-⑦ `operation_log` 留痕：谁传的（admin_id）+ 哪张申请（requestId）+ media id；**2 次成功上传 = 2 条**（失败的不留痕）',
    proofLogs.length === 2 && String(proofLogs[0].admin_id) === adminUserId &&
      String(proofAudit?.requestId) === p4 && String(proofAudit?.mediaId) === mediaId2 &&
      proofLogs.every((x) => String(x.admin_id) === adminUserId && x.path === `/api/v1/withdraw/requests/${p4}/pay-proof`),
    `n=${proofLogs.length} body=${j(proofAudit)}`);
  ok('⑬-⑦-b 留痕**不落文件内容**（无 base64 / data URL / PNG·JPEG 魔数，只有 media id 与元信息）',
    !!proofLogs[0] && !/data:image|base64|iVBORw0KGgo|\/9j\/4AAQ/.test(String(proofLogs[0].request_body)),
    String(proofLogs[0]?.request_body ?? '').slice(0, 150));

  // 本节收尾：驳回 p5（退回余额，不留悬空在途）+ 还原 dailyLimit
  const cleanP5 = p5 ? await req('POST', `/withdraw/requests/${p5}/reject`, rechargeToken, { reason: 'e2e 收尾清理（⑬）' }) : null;
  ok('⑬-收尾 p5 已驳回（余额退回，不留悬空在途）',
    !p5 || (cleanP5.status === 200 && (await reqRow(p5))?.status === 'rejected'),
    `status=${cleanP5?.status}`);
  await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: cfg13.data?.dailyLimit ?? 1 });

  if (addedByUs) {
    const rm = await req('DELETE', `/admin/recharge/admins/${adminUserId}`, adminToken);
    ok('⑩-g 收尾：临时加入的充值审核白名单已移除（不留测试残留）', rm.status === 200 || rm.status === 201, `status=${rm.status}`);
  } else {
    console.log('      （白名单本就在，未改动）');
  }

  // 附加：companion（老板端「打手态」）也能提现 —— /worker/* 白名单天然放行
  console.log('\n--- 附加：companion 打手态（role=worker, kind=companion）---');
  const st0 = await req('GET', '/user/identity', bossToken);
  if (st0.data?.bound) {
    await req('POST', '/user/identity/unbind', bossToken, {});
  }
  const cbind = await req('POST', '/user/identity/bind', bossToken, { username: W1, password: 'password123' });
  const companionToken = cbind.data?.companionToken;
  const cCfg = await req('GET', '/worker/withdraw/config', companionToken);
  ok('附-a companion（打手态）GET /worker/withdraw/config → 200（白名单放行 /worker/*，零改动可用）',
    cbind.status === 200 && !!companionToken && cCfg.status === 200,
    `bind=${cbind.status} cfg=${cCfg.status} ${cCfg.message ?? ''}`);
  const cBossSide = await req('GET', '/user/wallet', companionToken);
  ok('附-b companion 打老板侧接口仍 403（受限会话边界没被提现接口带松）',
    cBossSide.status === 403 && isChinese(cBossSide.message), `status=${cBossSide.status} ${cBossSide.message}`);
  await req('POST', '/user/identity/unbind', bossToken, {});

  // =========================================================================
  // ⑭ 列表下发**完整**收款信息（2026-10-11 负责人要求）
  //
  // 背景：此前列表行只有 `accountMasked`（负责人看到的「陈* · 139****5528 · ay****17」），
  // 核对收款信息必须点进详情；现在列表行**新增** `account: {realName, phone, wechatId}`
  // （与详情**同名同形**，完整值），`accountMasked` **原样保留**（旧客户端仍能跑）。
  // **权限点一个没加**：能读列表 = 有 `withdraw:review` = 审核人本身。
  // 脱敏继续用在**非审核面**（见 ④）：审计摘要 / 站内通知 / 运行日志不得出现完整手机号。
  // =========================================================================
  console.log('\n--- ⑭ 列表下发完整收款信息（account 完整 + accountMasked 兼容；脱敏只留非审核面）---');

  // 前置：造一张**新的 pending** 单据（负责人实际审的就是 pending 列表；沿用 ⑨-c/⑬ 的"临时放开每日次数"姿势）
  const cfg14 = await req('GET', '/admin/withdraw/config', adminToken);
  await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: 5 });
  const p6res = await req('POST', '/worker/withdraw/requests', worker2.token, { amount: AMOUNT });
  const p6 = trackReq(p6res.data?.id);
  await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: cfg14.data?.dailyLimit ?? 1 });
  ok('⑭-夹具：为 W2 造一张新的 **pending** 单据 p6（dailyLimit 临时放开后已还原）',
    p6res.status === 201 && !!p6, `id=${p6} status=${p6res.status} ${p6res.message ?? ''}`);

  /** ⑥ 夹具绑定 W2 时**提交的完整值** —— ①/③ 的"逐字一致"基准 */
  const accExpect = { realName: '李四海', phone: '13700137000', wechatId: 'wd_e2e_w2' };
  /** 同一组值的**脱敏**期望（`maskRealName`/`maskPhone`/`maskWechatId` 的计算结果） */
  const accMaskExpect = { realName: '李**', phone: '137****7000', wechatId: 'wd****w2' };

  // ---------- ① 列表行 account = 完整值（11 位手机号，与绑定提交值逐字一致）----------
  const list14 = await req('GET', '/admin/withdraw/requests?status=pending&page=1&pageSize=50', adminToken);
  const row14 = (list14.data?.list ?? []).find((x) => String(x.id) === p6);
  console.log(`      [真实 JSON 片段] ${j(row14 && { id: row14.id, amount: row14.amount, status: row14.status, account: row14.account, accountMasked: row14.accountMasked })}`);
  ok('⑭-① 列表行 `account.phone` 是**完整 11 位**（正则 ^\\d{11}$）且与绑定时提交的值**逐字一致**',
    !!row14 && /^\d{11}$/.test(String(row14.account?.phone ?? '')) && row14.account?.phone === accExpect.phone,
    `phone=${row14?.account?.phone}`);
  ok('⑭-①-b 列表行 `account.realName` / `account.wechatId` 同样**完整**（不是打码值）',
    row14?.account?.realName === accExpect.realName && row14?.account?.wechatId === accExpect.wechatId,
    j(row14?.account));

  const detail14 = await req('GET', `/admin/withdraw/requests/${p6}`, adminToken);
  ok('⑭-①-c 列表 `account` 与**详情** `account` **同名同形**（三个展示字段逐字相等）→ 详情行为未变',
    detail14.status === 200 && detail14.data?.account?.realName === row14?.account?.realName &&
      detail14.data?.account?.phone === row14?.account?.phone &&
      detail14.data?.account?.wechatId === row14?.account?.wechatId &&
      j(Object.keys(row14?.account ?? {}).sort()) === j(['phone', 'realName', 'wechatId']),
    j({ list: row14?.account, detailKeys: Object.keys(detail14.data?.account ?? {}).sort() }));

  // ---------- ② 兼容性：同一行**同时仍有** accountMasked（且确实含 *）----------
  /**
   * ⚠️ 这里**刻意只测兼容性**（脱敏字段仍在、值正是脱敏结果），不掺"与完整值不同"这类比较 ——
   * 那样会让 ② 随 ① 一起红，变异验证就分不清"① 测完整值、② 测兼容性"了（⑭-⑤ 变异下 ② 必须仍绿）。
   */
  ok('⑭-② 同一行**同时仍有** `accountMasked`（确含 `*`，值与脱敏函数结果一致）→ 旧客户端继续可用',
    !!row14?.accountMasked && j(row14.accountMasked).includes('*') &&
      row14.accountMasked.phone === accMaskExpect.phone &&
      row14.accountMasked.realName === accMaskExpect.realName &&
      row14.accountMasked.wechatId === accMaskExpect.wechatId,
    j(row14?.accountMasked));

  // ---------- ③ App 受限会话的 `/withdraw/requests` 同样给完整 ----------
  /**
   * ⑩ 结束时若把测试超管**移出**了充值审核白名单，⑩ 里那枚受限令牌会**即时失效**
   * （每请求实时校验白名单）→ 本节按同一姿势重新签发一次，跑完再移除。
   */
  const wl14 = await req('GET', '/admin/recharge/admins', adminToken);
  const wlHas14 = (wl14.data?.list ?? []).some((x) => String(x.adminUserId) === adminUserId);
  let added14 = false;
  if (!wlHas14) {
    const add14 = await req('POST', '/admin/recharge/admins', adminToken, { adminUserId });
    added14 = add14.status === 201 || add14.status === 200;
  }
  const bind14 = await req('POST', '/user/identity/bind-recharge-admin', adminToken, {
    username: adminUser, password: adminPw,
  });
  const rc14 = bind14.data?.rechargeToken;
  ok('⑭-夹具：App 内「管理员身份」受限会话可用（⑩ 若已移出白名单 → 这里重建）',
    bind14.status === 200 && !!rc14, `status=${bind14.status} ${bind14.message ?? ''}`);
  const rcList14 = await req('GET', '/withdraw/requests?status=pending&page=1&pageSize=50', rc14);
  const rcRow14 = (rcList14.data?.list ?? []).find((x) => String(x.id) === p6);
  ok('⑭-③ App 受限会话 `GET /withdraw/requests` 那条**同样给完整** `account`（与 PC 逐字一致）',
    rcList14.status === 200 && !!rcRow14 && rcRow14.account?.phone === accExpect.phone &&
      rcRow14.account?.realName === accExpect.realName && rcRow14.account?.wechatId === accExpect.wechatId,
    `status=${rcList14.status} ${j(rcRow14?.account)}`);

  // 收尾：驳回 p6（退回余额，不留悬空在途；顺带多一条 withdraw:reject 审计行参与 ④ 的扫描）
  const cleanP6 = p6 ? await req('POST', `/admin/withdraw/requests/${p6}/reject`, adminToken, { reason: 'e2e 收尾清理（⑭）' }) : null;
  ok('⑭-收尾 p6 已驳回（余额退回，不留悬空在途）',
    !p6 || (cleanP6.status === 200 && (await reqRow(p6))?.status === 'rejected'), `status=${cleanP6?.status}`);

  // ---------- ④ 负向断言：非审核面**不得**出现完整手机号/微信号 ----------
  await sleep(600); // operation_log 是异步落库（fire-and-forget），给它一点时间
  const phones14 = [accExpect.phone, '13900139000']; // W2 / W1 本轮提交的完整手机号
  const wechats14 = [accExpect.wechatId, 'wd_test_wx02'];
  const logs14 = await q(
    "SELECT id, action, request_body FROM operation_log WHERE id > ? AND module = 'withdraw' ORDER BY id",
    [LOG_MARK],
  );
  const hitExact = logs14.filter((x) => phones14.some((p) => String(x.request_body).includes(p)));
  const hitRegex = logs14.filter((x) => /1[3-9]\d{9}/.test(String(x.request_body)));
  const hitWechat = logs14.filter((x) => wechats14.some((w) => String(x.request_body).includes(w)));
  console.log(`      [SQL 证据] 本轮 withdraw 模块 operation_log ${logs14.length} 条 → ${j(logs14.map((x) => `#${x.id} ${x.action}`))}`);
  console.log(`      [SQL 证据] 其中 rebind 摘要原文 → ${String(logs14.find((x) => x.action === 'withdraw:account:rebind')?.request_body ?? '').slice(0, 200)}`);
  ok('⑭-④-a `operation_log`（本轮 withdraw 模块**全部**行）**不含**完整手机号（精确串 0 命中）',
    hitExact.length === 0, hitExact.map((x) => `#${x.id} ${x.action}`).join(' | '));
  ok('⑭-④-a2 同上：正则 `/1[3-9]\\d{9}/` **0 命中** → 不是"恰好躲过这两个号码"',
    hitRegex.length === 0, hitRegex.map((x) => `#${x.id} ${x.action}`).join(' | '));
  ok('⑭-④-a3 同上：不含完整微信号（完整值只在 account / 详情里，不进审计摘要）',
    hitWechat.length === 0, hitWechat.map((x) => `#${x.id} ${x.action}`).join(' | '));

  const noti14 = await q(
    'SELECT id, type, content FROM user_notification WHERE id > ? AND user_id IN (?) ORDER BY id',
    [NOTI_MARK, [worker1.userId, worker2.userId]],
  );
  const notiHit = noti14.filter(
    (x) =>
      phones14.some((p) => String(x.content).includes(p)) ||
      wechats14.some((w) => String(x.content).includes(w)) ||
      /1[3-9]\d{9}/.test(String(x.content)),
  );
  ok(`⑭-④-b \`user_notification\`（本轮两个夹具打手 ${noti14.length} 条）同样不含完整手机号/微信号`,
    notiHit.length === 0, notiHit.map((x) => `#${x.id} ${x.type}`).join(' | ') || j(noti14.map((x) => x.type)));

  const recentAll = await q('SELECT id, module, action, request_body FROM operation_log ORDER BY id DESC LIMIT 30');
  const recentHit = recentAll.filter((x) => phones14.some((p) => String(x.request_body).includes(p)));
  ok('⑭-④-c 兜底扫描：**全模块**最近 30 条 `operation_log` 里也不含本轮夹具的完整手机号（"任何日志面"）',
    recentHit.length === 0, recentHit.map((x) => `#${x.id} ${x.module}/${x.action}`).join(' | '));

  const logTail14 = logTailSince(LOG_MARKS);
  const tailHit = phones14.filter((p) => logTail14.includes(p)).concat(wechats14.filter((w) => logTail14.includes(w)));
  ok(`⑭-④-d 服务端运行日志的**本轮新增部分**（${(Buffer.byteLength(logTail14) / 1024).toFixed(1)}KB）不含完整手机号/微信号`,
    tailHit.length === 0, tailHit.join(' | '));

  if (added14) {
    const rm14 = await req('DELETE', `/admin/recharge/admins/${adminUserId}`, adminToken);
    ok('⑭-收尾：本节临时加入的充值审核白名单已移除（不留测试残留）',
      rm14.status === 200 || rm14.status === 201, `status=${rm14.status}`);
  }

  // =========================================================================
  // ⑪ 全局不出现「积分」
  // =========================================================================
  const badBodies = SCRAPED.filter((x) => x.text.includes('积分'));
  ok(`⑪ 全局不出现「积分」（扫描 ${SCRAPED.length} 个响应体）`,
    badBodies.length === 0, badBodies.map((x) => `${x.method} ${x.path} ${x.status}`).join(' | '));

  // =========================================================================
  // 收尾：自清 + 残留计数
  // =========================================================================
  console.log('\n--- 收尾（自建自清：**按本轮 request id 精确成对删除** + 余额回滚自检 + 账实一致）---');

  // ⓪ 收尾清单 = 脚本记录的 id ∪ 库内本轮新建的 id（双向比对：脚本漏记的行也要清，且要报红）
  const preFin = (await q(
    `SELECT (SELECT COUNT(*) FROM withdraw_request WHERE worker_id IN (?)) AS reqs,
            (SELECT COUNT(*) FROM worker_withdraw_account WHERE worker_id IN (?)) AS accts`,
    [wIds, wIds],
  ))[0];
  const dbNewReqs = (await q('SELECT id FROM withdraw_request WHERE id > ? ORDER BY id', [REQ_MARK])).map((r) => String(r.id));
  const untracked = dbNewReqs.filter((x) => !CREATED_REQ_IDS.includes(x));
  const cleanIds = [...new Set([...CREATED_REQ_IDS, ...dbNewReqs])];
  ok(`清理-0 收尾清单 = 脚本记录 ${CREATED_REQ_IDS.length} 张 ∪ 库内本轮新建 ${dbNewReqs.length} 张（双向一致，无"没记到的申请"）`,
    untracked.length === 0 && cleanIds.length === CREATED_REQ_IDS.length,
    `脚本=${j(CREATED_REQ_IDS)} ｜ 库内=${j(dbNewReqs)}${untracked.length ? ' ｜ ⚠️ 漏记=' + j(untracked) : ''}`);

  const fin = await preciseCleanup({ ids: cleanIds, topupKeys: TOPUP_KEYS, wipeWorkerIds: wIds, label: '收尾' });

  /** ① 成对校验：不成对的**一张都没删**（报红而不是硬删） */
  const shape = fin.pairs.map((p) => `#${p.id} ${p.row?.status ?? '缺失'}${p.deduct ? '+扣款' : ''}${p.refund ? '+退回' : ''}`).join(' ｜ ');
  ok(`清理-c **成对校验**：本轮 ${fin.pairs.length} 张申请逐张成对（扣款必有 + 回写流水号一致 + 金额相符；rejected 有退回、pending/paid 无退回）→ 不成对 **0** 处`,
    fin.bad.length === 0 && fin.pairs.length === cleanIds.length && !fin.txError,
    `${shape}${fin.bad.length ? ' ｜ ⚠️ 不成对（**原地保留、未删**）：' + j(fin.bad.map((b) => `#${b.id} ${b.why}`)) : ''}` +
      `${fin.txError ? ' ｜ ⚠️ 事务已回滚：' + fin.txError : ''}`);

  /** ② 删除量与计划一致（不成对的那半对不会被"补删"） */
  const planRefund = fin.good.filter((p) => p.refund).length;
  const planTopup = fin.rows.filter((r) => String(r.idempotency_key ?? '').startsWith('wd-e2e-fixture-topup:')).length;
  ok(`清理-d 删除量与计划一致：扣款 ${fin.good.length} 条 + 退回 ${planRefund} 条 + 夹具归一 ${planTopup} 条 = ${fin.rows.length} 条流水（实删 ${fin.deletedTxns}）＋申请 ${fin.deletedReqs} 行`,
    fin.deletedTxns === fin.rows.length && fin.rows.length === fin.good.length + planRefund + planTopup &&
      fin.deletedReqs === fin.good.length && !fin.txError,
    `流水 计划/实删 = ${fin.rows.length}/${fin.deletedTxns} ｜ 申请 计划/实删 = ${fin.good.length}/${fin.deletedReqs}`);

  const left = await q(
    `SELECT (SELECT COUNT(*) FROM withdraw_request WHERE worker_id IN (?)) AS reqs,
            (SELECT COUNT(*) FROM worker_withdraw_account WHERE worker_id IN (?)) AS accts,
            (SELECT COUNT(*) FROM withdraw_request WHERE worker_id IN (?) AND status = 'pending') AS pending`,
    [wIds, wIds, wIds],
  );
  ok('清理-a 两个测试打手的提现单据/收款信息已清空（pending 归零，不留悬空在途）',
    Number(left[0].reqs) === 0 && Number(left[0].accts) === 0 && Number(left[0].pending) === 0,
    `清理前 reqs=${preFin.reqs} accts=${preFin.accts} ｜ 清理后 ${j(left[0])}`);

  /** ③ **余额回滚自检（关键）**：逐账号比对「余额 + 流水条数」= 跑前基线 */
  const afterAll = [];
  for (const b of TOUCHED) afterAll.push(await snapshot(b.label, b.userId));
  const rollback = afterAll.map((a) => {
    const b = TOUCHED.find((x) => x.userId === a.userId);
    return { ...a, base: b, same: a.balance === b.balance && a.cnt === b.cnt };
  });
  console.log(
    `      [余额回滚] ${rollback.map((r) => `${r.label}: 跑前 ${yuan(r.base.balance)}/${r.base.cnt} 条 → 跑后 ${yuan(r.balance)}/${r.cnt} 条 ${r.same ? '✓' : '✗'}`).join(' ｜ ')}`,
  );
  ok('清理-e **余额回滚自检**：被触碰账号的余额与流水条数**逐账号回到跑前基线**（任一不回归 → 本套件判 FAIL，绝不静默通过）',
    rollback.every((r) => r.same),
    rollback.map((r) => (r.same ? `${r.label} 回滚 ✓` : `${r.label} ✗ 余额漂移 ${yuan(r.balance - r.base.balance)} / 条数漂移 ${r.cnt - r.base.cnt}`)).join(' ｜ '));

  /** ④ 账实一致：`余额 == Σ 流水`（漂移必须 0） */
  const drift = afterAll.map((a) => ({ ...a, d: Number((a.balance - a.sums).toFixed(2)) }));
  ok('清理-f **账实一致**：逐账号 `wallet.balance == Σ wallet_transaction.amount`（漂移 0.00）',
    drift.every((x) => x.d === 0),
    drift.map((x) => `${x.label}: 余额 ${yuan(x.balance)} = Σ流水 ${yuan(x.sums)}（漂移 ${x.d.toFixed(2)}）`).join(' ｜ '));

  /** ⑤ 零残留：本轮新建的流水/申请一条不剩（水位之后无行） */
  const leftTxns = await q(
    'SELECT id, user_id, idempotency_key FROM wallet_transaction WHERE id > ? AND user_id IN (?) ORDER BY id',
    [TXN_MARK, TOUCHED.map((t) => t.userId)],
  );
  const leftReqs = await q('SELECT id, status FROM withdraw_request WHERE id > ? ORDER BY id', [REQ_MARK]);
  ok(`清理-g 零残留：本轮新建的流水/申请一条不剩（残留流水 ${leftTxns.length} 条、残留申请 ${leftReqs.length} 行）`,
    leftTxns.length === 0 && leftReqs.length === 0 && Number(left[0].reqs) === 0 && Number(left[0].accts) === 0,
    `残留流水=${j(leftTxns)} ｜ 残留申请=${j(leftReqs)}`);

  /** ⑥ 历史孤儿（负责人裁决前**一条不动**）：跑前/跑后 id 集逐条相同 */
  const orphans1 = await orphansOf(worker1.userId);
  const orphanSum0 = ORPHANS0.reduce((a, r) => a + Number(r.amount), 0);
  const orphanSum1 = orphans1.reduce((a, r) => a + Number(r.amount), 0);
  ok(`清理-h ${W1}(user#${worker1.userId}) 的历史孤儿扣款**一条未动**：跑前 ${ORPHANS0.length} 条 → 跑后 ${orphans1.length} 条（id 集逐条相同、Σ 相同）`,
    orphans1.length === ORPHANS0.length && orphans1.every((r, i) => String(r.id) === String(ORPHANS0[i].id)) && orphanSum1 === orphanSum0,
    `Σ 跑前 ${yuan(orphanSum0)} → 跑后 ${yuan(orphanSum1)}（历史问题，等负责人裁决；本套件只负责"以后不再发生"）`);

  const cfgBack = await req('GET', '/admin/withdraw/config', adminToken);
  ok('清理-b 提现配置回到负责人定案默认值（min 10 / max 2000 / daily 1 / fee 0）',
    cfgBack.data?.minAmount === 10 && cfgBack.data?.maxAmount === 2000 &&
      cfgBack.data?.dailyLimit === 1 && cfgBack.data?.feeRate === 0,
    j({ min: cfgBack.data?.minAmount, max: cfgBack.data?.maxAmount, daily: cfgBack.data?.dailyLimit, fee: cfgBack.data?.feeRate }));

  console.log(`\n=== 结果：${pass} PASS / ${fail} FAIL ===`);
  console.log('[变异验证 ⑫] 本轮为**基线（无变异）**运行 → 应全绿；');
  console.log('   变异①「申请即扣 → 审核通过才扣」、变异②「pay 条件 UPDATE → 无条件 UPDATE」、');
  console.log('   变异③「pay 必须带凭证 → 凭证或备注至少一条」（2026-10-11 新增）');
  console.log('   由 scripts/tmp/wd-mutate.js apply1|apply2|apply3 施加到 dist 产物后重跑本脚本：');
  console.log('   ⑤ / ⑦-f / ⑬-③ 必须分别变红（跑完 node scripts/tmp/wd-mutate.js restore + pm2 restart）。');
  console.log('[变异验证 ⑭-⑤] 把列表改回「**只给脱敏**」（dist 里 account 三个字段改成 mask* 结果）');
  console.log('   用 scripts/tmp/wd-mutate.js apply4 → 重跑本脚本：⑭-① / ⑭-①-b / ⑭-①-c / ⑭-③ 必须变红，');
  console.log('   而 ⑭-②（accountMasked 仍在）仍绿 —— 证明 ① 真的在测"完整值"（跑完 restore + pm2 restart）。');

  await db.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch(async (e) => {
  console.error('\n[异常]', e && e.stack ? e.stack : e);
  process.exit(1);
});
