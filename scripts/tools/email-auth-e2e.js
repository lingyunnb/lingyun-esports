/**
 * 邮箱绑定/换绑 + 邮箱验证码登录 + QQ 登录服务端接线 · 端到端自证（2026-10-10）
 *
 * 运行（**只用自己的临时账号**，跑完自清）：
 *   node scripts/tools/email-auth-e2e.js                 # 默认打 127.0.0.1:3199（测试实例）
 *   E2E_BASE=http://127.0.0.1:3199/api/v1 node scripts/tools/email-auth-e2e.js
 *
 * 「未绑定不发信」的**线上投递级**证据：脚本自带一个桩 SMTP（默认 127.0.0.1:3252）。
 * 测试实例指向它时（`MAIL_DRIVER=smtp MAIL_HOST=127.0.0.1 MAIL_PORT=3252 MAIL_SECURE=false MAIL_ENABLED=true`），
 * ② 用"桩上真实投递计数"断言未绑定侧 **0 封**，并用已绑定侧 ≥1 封做正向对照；实例未指向桩时
 * 自动退化为等价证据（未绑定侧从未生成过码 ⟹ 未走到发信分支）并打印 NOTE，不会静默变绿。
 * 测试实例启动示例（2s 重发窗口是本套件的前提，脚本会自适应 pttl）：
 *   cd server && PORT=3199 MAIL_DRIVER=smtp MAIL_HOST=127.0.0.1 MAIL_PORT=3252 MAIL_SECURE=false \
 *     MAIL_ENABLED=true MAIL_ALLOW_TEST_ENDPOINTS=true MAIL_CODE_RESEND_SECONDS=2 node dist/main.js
 *
 * QQ 模式（脚本自己探测服务端配置，两种配置下各自全绿；两种都要跑一遍）：
 *   QQ_MODE=auto（默认）→ 若 /auth/qq/login 返回 503 则按「未配置」分支断言，否则按「打桩」分支断言
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 覆盖（对应任务书的 ①–⑧ + 变异验证 + 额外不变量）
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① 发码（scene=bind，测试端点读码）→ ② 绑定成功（DB email/email_verified_at + GET /user/email 脱敏）
 *  ③ 同一邮箱绑到另一个账号 → **409 中文**；④ 换绑（密码 + 新码）→ 成功、verified_at 刷新、审计留痕
 *  ⑤ 密码错误 → **400「密码错误」**（且验证码未被消耗：先验密码后验码）
 *  ⑥ 邮箱验证码登录 → JWT + /auth/me + /user/wallet 可用；单设备：旧 primary 立刻 401「账号已在其他设备登录」
 *  ⑦ 防枚举：未绑定邮箱发登录码 → 与已绑定**响应逐字相同**、**确实没发信**（无码键；桩 SMTP 上 0 投递）；
 *     登录侧「邮箱没绑」与「码不对」文案/状态码逐字相同
 *  ⑦d **账号枚举 oracle 回归（2026-10-10 缺陷）**：同一邮箱连发第二次 —— 未绑定与已绑定**同为 429 且文案逐字相同**；
 *     未绑定侧**同样消耗 `email:last` / `email:cnt` 额度**（不再只有已绑定侧有键）；未绑定侧**依然 0 发信**
 *  ⑦e **同款 oracle 的 `scene=reset` 回归（2026-10-10 第二批修复）**：找回密码取码 —— 未注册邮箱与已注册邮箱
 *     ① 首次响应**逐字相同**；② 未注册侧**同样消耗** `email:last:reset:*` / `email:cnt:reset:*`（与已注册侧等值）；
 *     ③ 第二次请求**同为 429 且逐字相同**（修复前：未注册侧恒 200）；④ 未注册侧**依然 0 发信**
 *     （桩 SMTP 真实投递计数 = 0 + 已注册侧真投递作正向对照 + 从未生成过码）；⑤ `register` 场景逐字未变（见 ⑨）
 *  ⑧ 未登录调绑定接口 → 401 中文；companion（打手态）白名单**不含** /user/email/*（纯函数断言）
 *  ⑨ 旧路径逐字不变：scene=register 仍 400「该邮箱已被注册…」；密码登录照常；缺字段仍被 DTO 拦下
 *  ⑩ 审计：login_log 有 via=email_code 行；operation_log 有 email_bind/email_rebind/login_by_email_code；
 *     **任何审计行都不含明文验证码**
 *  QQ（打桩模式）：服务端自己调 `oauth2.0/me` 复核 openid（请求形状断言）+ 建号/复用/伪造 openid 被拒/
 *     他人 token 被拒/无效 token/限流生效/绑定 + 冲突 + 幂等
 *  QQ（未配置模式）：/auth/qq/login|bind → **503「QQ 登录未配置」**，且**零网络调用**（打桩服务器 0 命中）
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 变异验证（跑完本脚本后用同样的命令复跑，必须变红）
 * ─────────────────────────────────────────────────────────────────────────────
 *  M1 去掉邮箱唯一判断（EmailBindingService.bind 的 `taken` 分支）→ 用例③ 必须红；
 *  M2 把"服务端复核 openid"改成信任入参（loginByQq 用 dto.openid 当权威）→ 伪造 openid 用例必须红；
 *  M3 **把 `scene=login` 的限流判定/额度消耗挪回「是否已绑定」判断之后**（AuthService.sendEmailCode，
 *     即未绑定分支直接 return）→ ⑦d 的三条「额度对称 / ① 同为 429 / ① 逐字相同」必须红
 *     （实测：未绑定第 2 次变回 200，已绑定仍是 429 → 账号枚举 oracle 复活）。
 *  M4 **把 `scene=reset` 的限流判定/额度消耗挪回「邮箱是否已注册」判断之后**（AuthService.sendEmailCode，
 *     即未注册分支直接 return，恢复修复前的控制流）→ ⑦e 必须红
 *     （实测：未注册侧第 2 次变回 200、`email:last/cnt:reset:*` 未注册侧无键 → 找回密码侧的账号枚举 oracle 复活；
 *     未注册侧的 ③「首次逐字相同」仍然为真 —— 泄漏只发生在**重复请求窗口**与"Redis 里有没有键"两条旁路上）。
 *
 * ⚠️ 本脚本**只碰自己建的临时账号**（用户名/邮箱都带时间戳），结束时删除：user / wallet / auth_token /
 *    login_log / operation_log / user_oauth 中的这些行 + 自己用掉的 Redis 键（含本人 IP 的取码计数，
 *    避免把共享 IP 额度占满影响别的套件）。**不使用 kslingyun 等任何既有账号**。
 */
'use strict';

const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const { openDb } = require('./public-catalog-expectation');

const ROOT = path.join(__dirname, '..', '..');
const SERVER_DIR = path.join(ROOT, 'server');
const IOREDIS_PATH = path.join(SERVER_DIR, 'node_modules', 'ioredis');
const BASE = process.env.E2E_BASE || 'http://127.0.0.1:3199/api/v1';
const STUB_PORT = Number(process.env.QQ_STUB_PORT || 3197);
/** 桩 SMTP 端口：测试实例配 `MAIL_HOST=127.0.0.1 MAIL_PORT=3252 MAIL_DRIVER=smtp` 即把真发信投到这里 */
const MAIL_STUB_PORT = Number(process.env.MAIL_STUB_PORT || 3252);
const QQ_MODE = String(process.env.QQ_MODE || 'auto').toLowerCase();

// ---- QQ 打桩常量（服务端 .env 里的测试配置必须与这里一致：QQ_APP_ID / QQ_GRAPH_BASE_URL）----
const APP_ID = process.env.QQ_TEST_APP_ID || '100000001';
const TOKEN_GOOD = 'TEST-TOKEN-GOOD-1';
const TOKEN_GOOD2 = 'TEST-TOKEN-GOOD-2';
const TOKEN_CALLBACK = 'TEST-TOKEN-CALLBACK';
const TOKEN_OTHER_APP = 'TEST-TOKEN-OTHER-APP';
const TOKEN_BAD = 'TEST-TOKEN-BAD';
const OPENID_1 = 'A1B2C3D4E5F607182930415263748596';
const OPENID_2 = 'FFEEDDCCBBAA99887766554433221100';
const OPENID_CALLBACK = '0123456789ABCDEF0123456789ABCDEF';
const OPENID_FORGED = 'DEADBEEFDEADBEEFDEADBEEFDEADBEEF';
const QQ_NICK = 'QQ测试昵称';
const UNIONID_1 = 'UNION-TEST-0001';

let pass = 0;
let fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) {
    pass += 1;
    console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
};
const section = (t) => console.log(`\n──── ${t} ────`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 读 server/.env（只用于 Redis 连接参数；DB 由 openDb 负责） */
function readServerEnv() {
  const out = {};
  for (const raw of fs.readFileSync(path.join(SERVER_DIR, '.env'), 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const i = line.indexOf('=');
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

async function api(method, p, body, token) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    /* 非 JSON（理论不会发生） */
  }
  return { status: res.status, code: json?.code, message: json?.message, data: json?.data, raw: text };
}

/** 响应体比较用：去掉 requestId/timestamp 这类每次不同的字段 */
const envelope = (r) => JSON.stringify({ code: r.code, message: r.message, data: r.data });

// ─────────────────────────────── 桩 SMTP（发信投递计数） ───────────────────────────────
/**
 * 最小 SMTP 服务器（只为**数信封**，不做投递）：测试实例把 MAIL_DRIVER 指到 smtp + 本端口后，
 * `MailerService.send()` 每真发一封这里就多一条 `messages` —— 于是"未绑定邮箱 0 发信"可以按**投递计数**断言
 * （而不是只靠"Redis 里没有码"这种间接证据）。已绑定侧必然 ≥1 封，天然是这道桩的**正向对照**。
 * 不广告 AUTH / STARTTLS（否则 nodemailer 会去认证），空 auth 也就不会被用到。
 */
function startMailStub() {
  const messages = [];
  const server = net.createServer((sock) => {
    let buf = '';
    let inData = false;
    let data = '';
    let cur = { from: '', rcpt: [], data: '' };
    const send = (line) => sock.write(line + '\r\n');
    sock.setEncoding('utf8');
    sock.on('error', () => {});
    send('220 mail-stub ESMTP ready');
    sock.on('data', (chunk) => {
      buf += chunk;
      for (;;) {
        const idx = buf.indexOf('\r\n');
        if (idx < 0) break;
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        if (inData) {
          if (line === '.') {
            inData = false;
            cur.data = data;
            messages.push(cur);
            cur = { from: '', rcpt: [], data: '' };
            data = '';
            send('250 2.0.0 Ok: queued');
          } else {
            data += (line.startsWith('..') ? line.slice(1) : line) + '\n';
          }
          continue;
        }
        const cmd = line.split(/[ :]/)[0].toUpperCase();
        if (cmd === 'EHLO' || cmd === 'HELO') {
          send('250-mail-stub');
          send('250-8BITMIME');
          send(`250 SIZE ${10 * 1024 * 1024}`);
        } else if (cmd === 'MAIL') {
          cur.from = line;
          send('250 2.1.0 Ok');
        } else if (cmd === 'RCPT') {
          cur.rcpt.push(line);
          send('250 2.1.5 Ok');
        } else if (cmd === 'DATA') {
          inData = true;
          send('354 End data with <CR><LF>.<CR><LF>');
        } else if (cmd === 'QUIT') {
          send('221 2.0.0 Bye');
          sock.end();
        } else if (cmd === 'RSET') {
          cur = { from: '', rcpt: [], data: '' };
          send('250 2.0.0 Ok');
        } else {
          send('250 2.0.0 Ok');
        }
      }
    });
  });
  return new Promise((resolve) => {
    server.listen(MAIL_STUB_PORT, '127.0.0.1', () =>
      resolve({
        messages,
        /** 某收件人一共被投递了几封（实例未指向本桩时恒 0） */
        countFor: (addr) => messages.filter((m) => m.rcpt.some((r) => String(r).includes(addr))).length,
        close: () => new Promise((r) => server.close(() => r())),
      }),
    );
  });
}

// ─────────────────────────────── QQ 打桩服务器 ───────────────────────────────
function startQqStub() {
  const hits = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${STUB_PORT}`);
    hits.push({ path: url.pathname, query: Object.fromEntries(url.searchParams) });
    const json = (obj) => {
      res.setHeader('content-type', 'application/json; charset=utf-8');
      res.end(JSON.stringify(obj));
    };
    if (url.pathname === '/oauth2.0/me') {
      const token = url.searchParams.get('access_token');
      if (token === TOKEN_GOOD) return json({ client_id: APP_ID, openid: OPENID_1, unionid: UNIONID_1 });
      if (token === TOKEN_GOOD2) return json({ client_id: APP_ID, openid: OPENID_2, unionid: 'UNION-TEST-0002' });
      if (token === TOKEN_CALLBACK) {
        // 腾讯不带 fmt=json 时的 callback(...) 包裹形态（服务端必须也能解析）
        res.setHeader('content-type', 'text/javascript; charset=utf-8');
        return res.end(`callback( {"client_id":"${APP_ID}","openid":"${OPENID_CALLBACK}"} );`);
      }
      if (token === TOKEN_OTHER_APP) return json({ client_id: '999999999', openid: OPENID_1, unionid: UNIONID_1 });
      return json({ error: 100016, error_description: 'access token check failed' });
    }
    if (url.pathname === '/user/get_user_info') {
      return json({ ret: 0, msg: '', nickname: QQ_NICK, figureurl_qq_2: 'https://example.invalid/qq-avatar.png' });
    }
    res.statusCode = 404;
    res.end('{}');
  });
  return new Promise((resolve) => {
    server.listen(STUB_PORT, '127.0.0.1', () =>
      resolve({
        hits,
        close: () => new Promise((r) => server.close(() => r())),
      }),
    );
  });
}

// ─────────────────────────────── 主流程 ───────────────────────────────
(async () => {
  const env = readServerEnv();
  const Redis = require(IOREDIS_PATH);
  const redis = new Redis({
    host: env.REDIS_HOST || '127.0.0.1',
    port: Number(env.REDIS_PORT || 6380),
    password: env.REDIS_PASSWORD || undefined,
    lazyConnect: true,
  });
  const db = await openDb();
  const stub = await startQqStub();
  const mailStub = await startMailStub();

  const suffix = Date.now().toString(36);
  const usernameA = `e2ea${suffix}`;
  const usernameB = `e2eb${suffix}`;
  const password = `E2ePass!${suffix}`;
  const emailA = `e2e-${suffix}-a@example.com`;
  const emailA2 = `e2e-${suffix}-a2@example.com`;
  const emailA3 = `e2e-${suffix}-a3@example.com`;
  const emailFree = `e2e-${suffix}-nobody@example.com`;
  /** `scene=reset`（找回密码）用的**未注册**邮箱：与 login 用的 emailFree 分开，避免两个场景的键互相干扰 */
  const emailResetFree = `e2e-${suffix}-nreset@example.com`;

  const createdUserIds = [];
  const usedCodes = [];
  /** 清理用的"标识"集合（会随用例追加，例如 >32 字符邮箱在 login_log 里被截断后的值） */
  const identifiers = [usernameA, usernameB, emailA, emailA2, emailA3, emailFree, emailResetFree];
  const usedRedisKeys = new Set([
    `email:code:bind:${emailA}`,
    `email:try:bind:${emailA}`,
    `email:last:bind:${emailA}`,
    `email:cnt:bind:${emailA}`,
    `email:code:bind:${emailA2}`,
    `email:try:bind:${emailA2}`,
    `email:last:bind:${emailA2}`,
    `email:cnt:bind:${emailA2}`,
    `email:code:bind:${emailA3}`,
    `email:try:bind:${emailA3}`,
    `email:last:bind:${emailA3}`,
    `email:cnt:bind:${emailA3}`,
    `email:code:login:${emailA2}`,
    `email:try:login:${emailA2}`,
    `email:last:login:${emailA2}`,
    `email:cnt:login:${emailA2}`,
    `email:code:login:${emailFree}`,
    `email:try:login:${emailFree}`,
    `email:last:login:${emailFree}`,
    `email:cnt:login:${emailFree}`,
    // scene=reset（找回密码）：已注册侧（emailA2）与未注册侧（emailResetFree）都登记，跑完一律清
    `email:code:reset:${emailA2}`,
    `email:try:reset:${emailA2}`,
    `email:last:reset:${emailA2}`,
    `email:cnt:reset:${emailA2}`,
    `email:code:reset:${emailResetFree}`,
    `email:try:reset:${emailResetFree}`,
    `email:last:reset:${emailResetFree}`,
    `email:cnt:reset:${emailResetFree}`,
    `email:test:forcefail`,
  ]);
  const rateKeys = new Set([
    `rl:login:127.0.0.1:qq`,
    `rl:qqbind:127.0.0.1`,
    `rl:login:127.0.0.1:${usernameA}`,
    `rl:login:127.0.0.1:${usernameB}`,
    `rl:login:127.0.0.1:${emailA2}`,
    `rl:login:127.0.0.1:${emailFree}`,
  ]);

  /** 读验证码：优先用测试端点（MAIL_ALLOW_TEST_ENDPOINTS=true）；404 时退回直接读 Redis */
  let peekMode = null;
  async function readCode(email, scene) {
    const r = await api('GET', `/auth/email/_test/peek?email=${encodeURIComponent(email)}&scene=${scene}`);
    if (r.status === 200) {
      if (peekMode === null) {
        peekMode = 'test-endpoint';
        console.log('    读码通道：/auth/email/_test/peek（MAIL_ALLOW_TEST_ENDPOINTS=true）');
      }
      return r.data?.code ?? null;
    }
    if (peekMode === null) {
      peekMode = 'redis';
      console.log(`    读码通道：直读 Redis（测试端点返回 ${r.status}）`);
    }
    const raw = await redis.get(`email:code:${scene}:${email}`);
    if (!raw) return null;
    try {
      return JSON.parse(raw).code ?? null;
    } catch {
      return null;
    }
  }

  const registerUser = async (username) => {
    const r = await api('POST', '/auth/register', { username, password, nickname: username });
    if (r.status !== 201 && r.status !== 200) throw new Error(`注册失败 ${username}: ${r.status} ${r.raw}`);
    createdUserIds.push(String(r.data.id));
    return r.data;
  };
  const passwordLogin = async (username) =>
    api('POST', '/auth/login', { username, password, role: 'user' });

  /**
   * 取码（自动等过「同邮箱重发间隔」）。
   * 等待时长不写死：直接看服务端写的 `email:last:{scene}:{email}` 剩余 TTL ——
   * 测试实例配 2s、生产配 60s 都能自适应，不会因为实例配置不同而偶发 429。
   */
  async function requestCode(email, scene) {
    const ttl = await redis.pttl(`email:last:${scene}:${email}`);
    if (ttl > 0) await sleep(ttl + 250);
    const r = await api('POST', '/auth/email/code', { email, scene });
    if (r.status !== 200) throw new Error(`取码失败 ${email}/${scene}: ${r.status} ${r.message}`);
    return r;
  }

  console.log(`=== 邮箱绑定/换绑 + 邮箱验证码登录 + QQ 登录服务端接线 · e2e（${BASE}）===`);
  console.log(`    临时账号：${usernameA} / ${usernameB}；邮箱：${emailA} / ${emailA2} / ${emailA3} / ${emailFree} / ${emailResetFree}`);

  try {
    // ══════════════════════════════ 准备 ══════════════════════════════
    section('准备：自建两个临时账号（A/B）+ 各取一次登录令牌');
    const accA = await registerUser(usernameA);
    const accB = await registerUser(usernameB);
    const [[roleA]] = await db.query('SELECT role, email FROM user WHERE id = ?', [accA.id]);
    const [[roleB]] = await db.query('SELECT role, email FROM user WHERE id = ?', [accB.id]);
    ok('临时账号 A 注册成功（role=user，无邮箱）', roleA.role === 'user' && roleA.email === null, `id=${accA.id}`);
    ok('临时账号 B 注册成功（role=user，无邮箱）', roleB.role === 'user' && roleB.email === null, `id=${accB.id}`);
    const loginA = await passwordLogin(usernameA);
    const loginB = await passwordLogin(usernameB);
    ok('A 密码登录成功（旧路径照常可用）', loginA.status === 200 && !!loginA.data?.accessToken);
    ok('B 密码登录成功', loginB.status === 200 && !!loginB.data?.accessToken);
    let tokenA = loginA.data.accessToken;
    const tokenB = loginB.data.accessToken;

    // ══════════════════════════════ ① 发码 ══════════════════════════════
    section('① 发码：POST /auth/email/code（scene=bind）');
    const codeReq1 = await requestCode(emailA, 'bind');
    ok('① 发码 200 且**不回显验证码**', codeReq1.status === 200 && codeReq1.data?.ok === true && !/code/i.test(codeReq1.raw.replace(/"[^"]*code[^"]*"/g, '')), codeReq1.message);
    const codeA = await readCode(emailA, 'bind');
    ok('① 测试端点读到 6 位码', /^\d{6}$/.test(String(codeA)), `code=${codeA}`);
    usedCodes.push(String(codeA));

    // ══════════════════════════════ ①b 重发间隔 ══════════════════════════════
    section('①b 重发间隔：同邮箱窗口内第二次取码 → 429 中文（测试实例 MAIL_CODE_RESEND_SECONDS=2）');
    const tooSoon = await api('POST', '/auth/email/code', { email: emailA, scene: 'bind' });
    ok('①b 立即重发 → 429', tooSoon.status === 429, `${tooSoon.status} ${tooSoon.message}`);
    ok('①b 中文文案「请求过于频繁，请 N 秒后再试」', /^请求过于频繁，请 \d+ 秒后再试$/.test(String(tooSoon.message)), tooSoon.message);
    const codeAStill1 = await readCode(emailA, 'bind');
    ok('①b 被限流不影响已发出的码', codeAStill1 === codeA, `before=${codeA} after=${codeAStill1}`);

    // ══════════════════════════════ ② 绑定成功 ══════════════════════════════
    section('② 绑定：POST /user/email/bind（当前密码 + 新邮箱码）');
    const bind1 = await api('POST', '/user/email/bind', { email: emailA, emailCode: codeA, password }, tokenA);
    ok('② 绑定成功 200', bind1.status === 200 && bind1.data?.ok === true, `${bind1.status} ${bind1.message}`);
    ok('② 首次绑定 rebound=false', bind1.data?.rebound === false);
    ok('② 响应里邮箱**已脱敏**（不含完整地址）', !!bind1.data?.email && !bind1.raw.includes(emailA) && bind1.data.email.includes('@example.com'), bind1.data?.email);
    let rowA = (await db.query('SELECT email, email_verified_at FROM user WHERE id = ?', [accA.id]))[0][0];
    ok('② DB 写入 email', rowA.email === emailA, rowA.email);
    ok('② DB 写入 email_verified_at', !!rowA.email_verified_at, String(rowA.email_verified_at));
    const verifiedAt1 = new Date(rowA.email_verified_at).getTime();
    const statusA = await api('GET', '/user/email', undefined, tokenA);
    ok('② GET /user/email 返回脱敏邮箱 + verified', statusA.status === 200 && statusA.data?.bound === true && statusA.data?.verified === true && !statusA.raw.includes(emailA), JSON.stringify(statusA.data));

    // ══════════════════════════════ ③ 邮箱唯一 → 409 ══════════════════════════════
    section('③ 唯一性：同一邮箱绑到另一个账号 → 409 中文');
    const codeOther = await requestCode(emailA, 'bind');
    ok('③（前置）B 也能为该邮箱取到码（bind 场景不静默丢信）', codeOther.status === 200);
    const codeTaken = await readCode(emailA, 'bind');
    usedCodes.push(String(codeTaken));
    const bindB = await api('POST', '/user/email/bind', { email: emailA, emailCode: codeTaken, password }, tokenB);
    ok('③ 绑到 B → **409**', bindB.status === 409, `${bindB.status} ${bindB.message}`);
    ok('③ 中文文案「该邮箱已被其他账号绑定」', bindB.message === '该邮箱已被其他账号绑定', bindB.message);
    const rowB = (await db.query('SELECT email FROM user WHERE id = ?', [accB.id]))[0][0];
    ok('③ B 的 email 未被写入（仍是 NULL）', rowB.email === null, String(rowB.email));
    const rowA2 = (await db.query('SELECT email FROM user WHERE id = ?', [accA.id]))[0][0];
    ok('③ A 的邮箱未被抢走', rowA2.email === emailA, String(rowA2.email));
    // 留痕证据（不是断言）：正常代码下是服务层拦的；把服务层判断去掉（变异 M1a）后，
    // 这里会变成"并发撞唯一索引" —— 直接看出到底是哪一层拦住的。
    const [[failRow]] = await db.query(
      `SELECT fail_reason FROM login_log WHERE user_id = ? AND result = 'fail' ORDER BY id DESC LIMIT 1`,
      [accB.id],
    );
    console.log(`    （留痕）③ B 的失败原因：${failRow?.fail_reason ?? '(无)'}`);
    /**
     * 数据库层才是「一个邮箱只能绑一个账号」的**权威约束**（服务层的"先查后写"会被并发绕过）。
     * 这里在**事务内**制造一次重复写入再回滚 —— 不改任何真实数据，只证明唯一索引确实在拦。
     * 变异验证 M1a（只去掉服务层判断）时本断言仍是绿的：正是它兜住了 409。
     */
    let dupErr = null;
    try {
      await db.query('START TRANSACTION');
      await db.query('UPDATE `user` SET email = ? WHERE id = ?', [emailA, accB.id]);
      await db.query('ROLLBACK');
    } catch (e) {
      dupErr = e;
      try {
        await db.query('ROLLBACK');
      } catch {
        /* 连接已回滚 */
      }
    }
    ok(
      '③ DB 权威约束：UQ_user_email 拦住重复邮箱（事务内制造冲突，随后回滚）',
      !!dupErr && (dupErr.code === 'ER_DUP_ENTRY' || Number(dupErr.errno) === 1062),
      dupErr ? `${dupErr.code}/${dupErr.errno}` : '**更新竟然成功 → 唯一索引失效！**',
    );

    // ══════════════════════════════ ⑤ 密码错误（放在换绑前，验证"先密码后验码"）══════════════════════════════
    section('⑤ 密码错误：400「密码错误」且**不消耗验证码**');
    await requestCode(emailA3, 'bind');
    const codeA3 = await readCode(emailA3, 'bind');
    usedCodes.push(String(codeA3));
    const bindWrongPwd = await api('POST', '/user/email/bind', { email: emailA3, emailCode: codeA3, password: `${password}-wrong` }, tokenA);
    ok('⑤ 密码错误 → 400', bindWrongPwd.status === 400, `${bindWrongPwd.status} ${bindWrongPwd.message}`);
    ok('⑤ 中文文案「密码错误」', bindWrongPwd.message === '密码错误', bindWrongPwd.message);
    const codeA3Still = await readCode(emailA3, 'bind');
    ok('⑤ 验证码未被消耗（密码先于验码）', codeA3Still === codeA3, `before=${codeA3} after=${codeA3Still}`);
    const rowA3 = (await db.query('SELECT email FROM user WHERE id = ?', [accA.id]))[0][0];
    ok('⑤ 邮箱未被改动', rowA3.email === emailA, String(rowA3.email));

    // ══════════════════════════════ ④ 换绑 ══════════════════════════════
    section('④ 换绑：（原 emailA → emailA2）密码 + 新邮箱码');
    await requestCode(emailA2, 'bind');
    const codeA2bind = await readCode(emailA2, 'bind');
    usedCodes.push(String(codeA2bind));
    const rebind = await api('POST', '/user/email/bind', { email: emailA2, emailCode: codeA2bind, password }, tokenA);
    ok('④ 换绑成功 200', rebind.status === 200 && rebind.data?.ok === true, `${rebind.status} ${rebind.message}`);
    ok('④ rebound=true', rebind.data?.rebound === true);
    ok('④ 响应脱敏且为**新**邮箱', !!rebind.data?.email && !rebind.raw.includes(emailA2), rebind.data?.email);
    rowA = (await db.query('SELECT email, email_verified_at FROM user WHERE id = ?', [accA.id]))[0][0];
    ok('④ DB email 覆盖为新邮箱', rowA.email === emailA2, rowA.email);
    const verifiedAt2 = new Date(rowA.email_verified_at).getTime();
    ok('④ email_verified_at 已刷新（> 首次绑定时间）', verifiedAt2 > verifiedAt1, `${verifiedAt1} → ${verifiedAt2}`);
    const statusA2 = await api('GET', '/user/email', undefined, tokenA);
    ok('④ GET /user/email 显示新邮箱（脱敏）', statusA2.data?.bound === true && !statusA2.raw.includes(emailA2), JSON.stringify(statusA2.data));
    const unusedFree = await api('GET', '/user/email', undefined, tokenB);
    ok('④ 未绑邮箱的账号 GET /user/email → bound=false', unusedFree.data?.bound === false && unusedFree.data?.email === null);

    // ══════════════════════════════ ⑦ 防枚举 ══════════════════════════════
    section('⑦ 防枚举：未绑定邮箱取登录码 = 已绑定**逐字相同**，但确实没发信');
    const codeReqBound = await requestCode(emailA2, 'login');
    const codeLoginA2 = await readCode(emailA2, 'login');
    usedCodes.push(String(codeLoginA2));
    ok('⑦（对照）已绑定邮箱：真发信（Redis 里有码）', /^\d{6}$/.test(String(codeLoginA2)), codeLoginA2);
    ok('⑦（对照）已绑定邮箱：响应 200', codeReqBound.status === 200);
    const codeReqFree = await requestCode(emailFree, 'login');
    ok('⑦ 未绑定邮箱：响应 200（与已绑定一致）', codeReqFree.status === 200);
    ok(
      '⑦ **响应体逐字相同**（去 requestId/timestamp）',
      envelope(codeReqBound) === envelope(codeReqFree),
      `bound=${envelope(codeReqBound).slice(0, 90)} free=${envelope(codeReqFree).slice(0, 90)}`,
    );
    const freeKeys = await Promise.all(
      ['code', 'try', 'last', 'cnt'].map((k) => redis.exists(`email:${k}:login:${emailFree}`)),
    );
    ok('⑦ 未绑定邮箱：**没有发信**（email:code/login 无键）', freeKeys[0] === 0);
    /**
     * ⚠️ 口径更新（2026-10-10 账号枚举修复）：未绑定侧**不再"不占额度"** —— 它照样写 `email:last` / `email:cnt`
     * （与已绑定侧同键同语义），否则"第二次请求 429 / 200 的差异"与"Redis 里只有已绑定侧有键"就是枚举 oracle。
     * 仍必须为空的是"真发信才会产生"的两个键：码（code）与错误次数（try）。旧断言 `try/last/cnt 全无键`
     * 记录的是**修复前**的行为，已按新口径改写（对称性与重复请求见 ⑦d）。
     */
    ok('⑦ 未绑定邮箱：没有码、没有错误计数（code/try 无键）', freeKeys[0] === 0 && freeKeys[1] === 0, JSON.stringify(freeKeys));
    const freeCodeInRedis = await readCode(emailFree, 'login');
    ok('⑦ 未绑定邮箱：读码为空（确实没生成码）', freeCodeInRedis === null, String(freeCodeInRedis));

    // ══════════════════════ ⑦d 账号枚举 oracle：重复请求窗口（2026-10-10 修复回归） ══════════════════════
    /**
     * 实测确认的缺陷：未绑定分支曾在限流判定 `assertRateLimits` **之前**就 return —— 既不校验也不消费额度。
     * 于是"同一邮箱连发第二次"这一维度上出现 oracle：
     *   已绑定 → 429「请求过于频繁，请 N 秒后再试」；未绑定 → **恒 200**（且 `email:last:login:*` /
     *   `email:cnt:login:*` 只有已绑定侧存在，可旁路探测）→ 可判断"某邮箱是否已注册/已绑定本平台账号"。
     * 修法：`scene=login` 的限流判定与额度消耗**前置**到"是否已绑定"之前，未绑定分支同样 `consumeQuota()`
     * （**仍然绝不发信**：不生成码、不调 MailerService）。本节把这条不变量钉死。
     * 变异验证 M3：把限流/额度挪回绑定判断之后 → 本节"额度对称"与 ① 必须红。
     */
    section('⑦d 重复请求窗口不再泄漏「是否已绑定」（账号枚举 oracle 回归）');
    ok(
      '⑦d ③ 首次请求：状态码 + 响应体**逐字相同**（回归原有防枚举不变量）',
      codeReqBound.status === codeReqFree.status && envelope(codeReqBound) === envelope(codeReqFree),
      `status=${codeReqBound.status}/${codeReqFree.status}`,
    );
    const lastBound = Number(await redis.get(`email:last:login:${emailA2}`)) || 0;
    const lastFree = Number(await redis.get(`email:last:login:${emailFree}`)) || 0;
    const cntBound = Number(await redis.get(`email:cnt:login:${emailA2}`)) || 0;
    const cntFree = Number(await redis.get(`email:cnt:login:${emailFree}`)) || 0;
    ok(
      '⑦d 未绑定邮箱**同样写 email:last（重发锁）**（不再只有已绑定侧有键）',
      lastFree > 0,
      `bound=${lastBound || '(无键)'} free=${lastFree || '(无键)'}`,
    );
    ok(
      '⑦d 未绑定邮箱**同样消耗 email:cnt（小时额度）**且与已绑定侧等值',
      cntFree > 0 && cntFree === cntBound,
      `bound=${cntBound} free=${cntFree}`,
    );
    /**
     * 第二次请求：60s 限制的文案含倒计时，而倒计时按"距上次发码过了几秒"取整 ——
     * 两侧必须落在**同一个秒桶**才谈得上"逐字相同"。做法：读服务端写下的两个 `email:last` 时间戳，
     * 等到 `max(last) + 1.1s` 再发（两侧 elapsed 同为 1.x 秒 → 倒计时同为 N-1 秒）。
     * 对 2s（测试实例）与 60s（生产）两种窗口都成立，且留 ~0.9s 余量不越出窗口。
     */
    const fireAt = Math.max(lastBound, lastFree) + 1100;
    if (fireAt > Date.now()) await sleep(fireAt - Date.now());
    const secondBound = await api('POST', '/auth/email/code', { email: emailA2, scene: 'login' });
    const secondFree = await api('POST', '/auth/email/code', { email: emailFree, scene: 'login' });
    ok(
      '⑦d ① 第二次请求：两种邮箱**同为 429**（不是"未绑定恒 200"）',
      secondBound.status === 429 && secondFree.status === 429,
      `bound=${secondBound.status} ${secondBound.message} | free=${secondFree.status} ${secondFree.message}`,
    );
    ok(
      '⑦d ① 第二次请求：状态码 + 响应体**逐字相同**',
      secondBound.status === secondFree.status && envelope(secondBound) === envelope(secondFree),
      `bound=${envelope(secondBound)} free=${envelope(secondFree)}`,
    );
    ok(
      '⑦d ① 第二次请求：文案同为「请求过于频繁，请 N 秒后再试」',
      /^请求过于频繁，请 \d+ 秒后再试$/.test(String(secondFree.message)) && secondFree.message === secondBound.message,
      `${secondBound.message} | ${secondFree.message}`,
    );
    /**
     * ④ 限流确实生效：被限流期间再连发两次仍是 429（且与第 2 次逐字同码同文案）——
     * 证明"对称"不是靠"两边都放开刷"换来的。这三条都在重发窗口内发（测试实例 2s / 生产 60s 都够）。
     */
    const laterFree = [];
    for (let i = 0; i < 2; i += 1) {
      laterFree.push(await api('POST', '/auth/email/code', { email: emailFree, scene: 'login' }));
    }
    ok(
      '⑦d ④ 连发第 3/4 次仍 429（限流真的在拦，不是"放开了刷"）',
      laterFree.every((r) => r.status === 429),
      JSON.stringify(laterFree.map((r) => `${r.status} ${r.message}`)),
    );
    ok(
      '⑦d ④ 第 3/4 次与第 2 次逐字同码同文案',
      laterFree.every((r) => envelope(r) === envelope(secondFree)),
      envelope(laterFree[0]),
    );
    /**
     * ② 未绑定邮箱**依然 0 发信**：优先按桩 SMTP 的**真实投递计数**断言（已绑定侧 ≥1 封作正向对照）；
     * 实例未指向桩（console 驱动 / 真实 SMTP）时退化为等价证据（未绑定侧从未生成过码 ⟹ 未走到发信分支），
     * 并打印 NOTE —— 明确是"这一档证据拿不到"，而不是静默变绿。
     */
    const mailBound = mailStub.countFor(emailA2);
    const mailFree = mailStub.countFor(emailFree);
    if (mailBound > 0) {
      ok(
        '⑦d ② 未绑定邮箱：**MailerService 命中数 = 0**（桩 SMTP 真实投递计数）',
        mailFree === 0,
        `bound=${mailBound} free=${mailFree}`,
      );
      ok('⑦d ② 正向对照：已绑定侧在同一桩上确实投递了 ≥1 封（证明这道计数不是恒 0）', mailBound >= 1, `bound=${mailBound}`);
    } else {
      console.log(
        '    NOTE 桩 SMTP（127.0.0.1:' +
          MAIL_STUB_PORT +
          '）上未见已绑定侧的投递 → 本实例不是"桩 smtp 模式"，② 退化为等价证据（可加 MAIL_HOST/MAIL_PORT 指向桩以取得投递级证据）',
      );
      ok(
        '⑦d ② 未绑定邮箱：从未生成过码 ⟹ 未调用发信（等价证据，非投递计数）',
        (await redis.exists(`email:code:login:${emailFree}`)) === 0,
      );
    }
    ok(
      '⑦d ② 未绑定邮箱被限流期间也没有生成码（限流分支不写码）',
      (await redis.exists(`email:code:login:${emailFree}`)) === 0,
    );

    // ══════════════ ⑦e 同款 oracle：scene=reset（邮箱找回密码）重复请求窗口（2026-10-10 第二批修复） ══════════════
    /**
     * 与 ⑦d **同款**的缺陷，这次发生在 `scene=reset`（邮箱找回密码）：
     * 未注册分支曾在限流判定 `assertRateLimits` **之前**就 return —— 既不校验也不消费额度。于是：
     *   已注册邮箱 60s 内第二次请求 → **429**「请求过于频繁，请 N 秒后再试」
     *   未注册邮箱第二次请求        → **恒 200**（且 Redis 里 `email:last:reset:*` / `email:cnt:reset:*`
     *   只有已注册侧存在）→ 对同一邮箱连发两次即可判断"该邮箱是否已注册本平台账号"。
     * 修法：`reset` 与 `login` 共用同一处**前置**判定（`if (scene === 'login' || scene === 'reset')`），
     * 未注册分支同样 `consumeQuota()`（写与已注册侧相同的 last/cnt 键），**仍然绝不发信**
     * （不生成码、不调 MailerService）。`register` 场景按设计显式告知"该邮箱已被注册"，**不动**（见 ⑨）。
     * 变异验证 M4：把限流判定/额度消耗挪回「邮箱是否已注册」判断之后 → 本节 ②（额度对称）与 ③（同为 429）
     * 必须红（本题 ①「首次逐字相同」在变异下仍绿 —— 泄漏只在**重复请求窗口**与"Redis 里有没有键"两条旁路上）。
     */
    section('⑦e 找回密码（scene=reset）同款回归：未注册邮箱不再"第 2 次恒 200"');
    const [[regResetRow]] = await db.query('SELECT COUNT(*) c FROM user WHERE email = ?', [emailA2]);
    const [[unregResetRow]] = await db.query('SELECT COUNT(*) c FROM user WHERE email = ?', [emailResetFree]);
    ok(
      '⑦e（对照前置）已注册侧 emailA2 在库、未注册侧 nreset 邮箱不在库',
      Number(regResetRow.c) === 1 && Number(unregResetRow.c) === 0,
      `registered=${regResetRow.c} unregistered=${unregResetRow.c}`,
    );
    const resetMailBefore = mailStub.countFor(emailA2);
    const resetCodeReqReg = await api('POST', '/auth/email/code', { email: emailA2, scene: 'reset' });
    const resetCodeReqFree = await api('POST', '/auth/email/code', { email: emailResetFree, scene: 'reset' });
    ok('⑦e 已注册邮箱：响应 200（真发信）', resetCodeReqReg.status === 200, `${resetCodeReqReg.status} ${resetCodeReqReg.message}`);
    ok('⑦e 未注册邮箱：响应 200（与已注册侧一致）', resetCodeReqFree.status === 200, `${resetCodeReqFree.status} ${resetCodeReqFree.message}`);
    ok(
      '⑦e ① 首次请求：状态码 + 响应体**逐字相同**（回归原有防枚举不变量）',
      resetCodeReqReg.status === resetCodeReqFree.status && envelope(resetCodeReqReg) === envelope(resetCodeReqFree),
      `reg=${envelope(resetCodeReqReg).slice(0, 80)} free=${envelope(resetCodeReqFree).slice(0, 80)}`,
    );
    const lastResetReg = Number(await redis.get(`email:last:reset:${emailA2}`)) || 0;
    const lastResetFree = Number(await redis.get(`email:last:reset:${emailResetFree}`)) || 0;
    const cntResetReg = Number(await redis.get(`email:cnt:reset:${emailA2}`)) || 0;
    const cntResetFree = Number(await redis.get(`email:cnt:reset:${emailResetFree}`)) || 0;
    ok(
      '⑦e ② 未注册邮箱**同样写 email:last:reset（重发锁）**（不再只有已注册侧有键）',
      lastResetFree > 0,
      `reg=${lastResetReg || '(无键)'} free=${lastResetFree || '(无键)'}`,
    );
    ok(
      '⑦e ② 未注册邮箱**同样消耗 email:cnt:reset（小时额度）**且与已注册侧等值',
      cntResetFree > 0 && cntResetFree === cntResetReg,
      `reg=${cntResetReg} free=${cntResetFree}`,
    );
    const resetFreeKeys = await Promise.all(
      ['code', 'try'].map((k) => redis.exists(`email:${k}:reset:${emailResetFree}`)),
    );
    ok(
      '⑦e ② 未注册邮箱：没有码、没有错误计数（code/try 无键 ⟹ 确实没走到发信分支）',
      resetFreeKeys[0] === 0 && resetFreeKeys[1] === 0,
      JSON.stringify(resetFreeKeys),
    );
    // 第二次请求：与 ⑦d 同法，等两侧 elapsed 落进同一个秒桶（倒计时文案才可能逐字相同）
    const resetFireAt = Math.max(lastResetReg, lastResetFree) + 1100;
    if (resetFireAt > Date.now()) await sleep(resetFireAt - Date.now());
    const resetSecondReg = await api('POST', '/auth/email/code', { email: emailA2, scene: 'reset' });
    const resetSecondFree = await api('POST', '/auth/email/code', { email: emailResetFree, scene: 'reset' });
    ok(
      '⑦e ③ 第二次请求：两种邮箱**同为 429**（不是"未注册恒 200"）',
      resetSecondReg.status === 429 && resetSecondFree.status === 429,
      `reg=${resetSecondReg.status} ${resetSecondReg.message} | free=${resetSecondFree.status} ${resetSecondFree.message}`,
    );
    ok(
      '⑦e ③ 第二次请求：状态码 + 响应体**逐字相同**',
      resetSecondReg.status === resetSecondFree.status && envelope(resetSecondReg) === envelope(resetSecondFree),
      `reg=${envelope(resetSecondReg)} free=${envelope(resetSecondFree)}`,
    );
    ok(
      '⑦e ③ 第二次请求：文案同为「请求过于频繁，请 N 秒后再试」',
      /^请求过于频繁，请 \d+ 秒后再试$/.test(String(resetSecondFree.message)) &&
        resetSecondFree.message === resetSecondReg.message,
      `${resetSecondReg.message} | ${resetSecondFree.message}`,
    );
    const resetLaterFree = [
      await api('POST', '/auth/email/code', { email: emailResetFree, scene: 'reset' }),
      await api('POST', '/auth/email/code', { email: emailResetFree, scene: 'reset' }),
    ];
    ok(
      '⑦e ④ 连发第 3/4 次仍 429（限流真的在拦，不是"放开了刷"）',
      resetLaterFree.every((r) => r.status === 429),
      JSON.stringify(resetLaterFree.map((r) => `${r.status} ${r.message}`)),
    );
    ok(
      '⑦e ④ 第 3/4 次与第 2 次逐字同码同文案',
      resetLaterFree.every((r) => envelope(r) === envelope(resetSecondFree)),
      envelope(resetLaterFree[0]),
    );
    /**
     * ⑤ 未注册邮箱**依然 0 发信**：桩 SMTP 真实投递计数（已注册侧本次 Δ ≥1 作正向对照，
     * 用 Δ 而不是累计值 —— emailA2 在前面 ⑦ 已经投递过）。
     */
    const resetMailReg = mailStub.countFor(emailA2) - resetMailBefore;
    const resetMailFree = mailStub.countFor(emailResetFree);
    if (resetMailReg > 0) {
      ok(
        '⑦e ⑤ 未注册邮箱：**MailerService 命中数 = 0**（桩 SMTP 真实投递计数）',
        resetMailFree === 0,
        `regΔ=${resetMailReg} free=${resetMailFree}`,
      );
      ok(
        '⑦e ⑤ 正向对照：已注册侧在同一桩上确实投递了 ≥1 封（证明这道计数不是恒 0）',
        resetMailReg >= 1,
        `regΔ=${resetMailReg}`,
      );
    } else {
      console.log(
        `    NOTE 桩 SMTP（127.0.0.1:${MAIL_STUB_PORT}）上未见 reset 场景已注册侧的投递 → 本实例不是"桩 smtp 模式"，⑤ 退化为等价证据`,
      );
      ok(
        '⑦e ⑤ 未注册邮箱：从未生成过码 ⟹ 未调用发信（等价证据，非投递计数）',
        (await redis.exists(`email:code:reset:${emailResetFree}`)) === 0,
      );
    }
    ok(
      '⑦e ⑤ 未注册邮箱在被限流期间也没有生成码（限流分支不写码）',
      (await redis.exists(`email:code:reset:${emailResetFree}`)) === 0,
    );

    section('⑦b 登录侧：未绑定与码不对**同一句话**');
    const wrongCode = codeLoginA2 === '000000' ? '111111' : '000000';
    const loginUnbound = await api('POST', '/auth/login', { email: emailFree, emailCode: wrongCode, role: 'user' });
    const loginBadCode = await api('POST', '/auth/login', { email: emailA2, emailCode: wrongCode, role: 'user' });
    ok('⑦b 未绑定邮箱登录 → 400', loginUnbound.status === 400, `${loginUnbound.status} ${loginUnbound.message}`);
    ok('⑦b 文案「邮箱或验证码错误」', loginUnbound.message === '邮箱或验证码错误', loginUnbound.message);
    ok('⑦b 已绑定邮箱 + 错码 → **与未绑定逐字相同**', envelope(loginUnbound) === envelope(loginBadCode), `${envelope(loginUnbound)} vs ${envelope(loginBadCode)}`);

    /**
     * ⑦c 长邮箱回归（2026-10-10 实测缺陷）：`login_log.username` 是 varchar(32)，而邮箱路径往这一列写的是**邮箱**。
     * 一个 35 字符的邮箱会把 INSERT 撑爆 → 未捕获 QueryFailedError → **500**（本该是中文 400）。
     * 修法：`AuthService.writeLoginLog` 统一按 32 位截断（与同行 ip/userAgent 的 slice 同一写法）。
     * 这里同时盯住邮箱码登录与找回密码（找回那条是**既有**路径，同样会被长邮箱打爆）。
     */
    const longEmail = `e2e-${suffix}-${'x'.repeat(36)}-nobody@example.com`;
    identifiers.push(longEmail.slice(0, 32));
    // 长邮箱的登录限流键也是自己写的，一并登记清理（否则会留一枚 rl:login:… 键到 TTL 到期）
    rateKeys.add(`rl:login:127.0.0.1:${longEmail}`);
    const longUnbound = await api('POST', '/auth/login', { email: longEmail, emailCode: wrongCode, role: 'user' });
    ok(
      `⑦c ${longEmail.length} 字符邮箱登录 → 400「邮箱或验证码错误」（不是 500）`,
      longUnbound.status === 400 && longUnbound.message === '邮箱或验证码错误',
      `${longUnbound.status} ${longUnbound.message}`,
    );
    ok('⑦c 与短邮箱响应逐字相同', envelope(longUnbound) === envelope(loginUnbound), envelope(longUnbound));
    const longReset = await api('POST', '/auth/password/reset', {
      email: longEmail,
      emailCode: wrongCode,
      newPassword: `${password}-new`,
    });
    ok(
      '⑦c 长邮箱走找回密码 → 400 中文（既有路径同一处截断修复生效）',
      longReset.status === 400 && !!longReset.message,
      `${longReset.status} ${longReset.message}`,
    );

    // ══════════════════════════════ ⑥ 邮箱验证码登录 ══════════════════════════════
    section('⑥ 邮箱验证码登录：POST /auth/login（email + emailCode）');
    await requestCode(emailA2, 'login');
    const codeLogin = await readCode(emailA2, 'login');
    usedCodes.push(String(codeLogin));
    const loginByEmail = await api('POST', '/auth/login', { email: emailA2, emailCode: codeLogin, role: 'user' });
    ok('⑥ 登录成功 200 + 令牌对结构与其他登录一致', loginByEmail.status === 200 && !!loginByEmail.data?.accessToken && !!loginByEmail.data?.refreshToken, `${loginByEmail.status} ${loginByEmail.message}`);
    tokenA = loginByEmail.data?.accessToken;
    const meA = await api('GET', '/auth/me', undefined, tokenA);
    ok('⑥ 新令牌可访问 /auth/me（主体正确）', meA.status === 200 && String(meA.data?.id) === String(accA.id), `me.id=${meA.data?.id}`);
    const walletA = await api('GET', '/user/wallet', undefined, tokenA);
    ok('⑥ 新令牌可访问 /user/wallet', walletA.status === 200, `status=${walletA.status} ${walletA.message ?? ''}`);
    ok('⑥ 邮箱码一次性作废（同码再用一次 → 400）', (await api('POST', '/auth/login', { email: emailA2, emailCode: codeLogin, role: 'user' })).status === 400);

    section('⑥b 单设备铁律：邮箱码登录 = primary 登录（顶掉旧会话）');
    const oldMe = await api('GET', '/auth/me', undefined, loginA.data.accessToken);
    ok('⑥b 邮箱码登录后，之前那次密码登录的 access 立刻 401', oldMe.status === 401, `${oldMe.status} ${oldMe.message}`);
    ok('⑥b 中文文案「账号已在其他设备登录」', oldMe.message === '账号已在其他设备登录', oldMe.message);

    // ══════════════════════════════ ⑧ 未登录 / companion ══════════════════════════════
    section('⑧ 未登录调用绑定接口 → 401 中文；companion 白名单不含 /user/email/*');
    const anonBind = await api('POST', '/user/email/bind', { email: emailFree, emailCode: '123456', password });
    ok('⑧ 未登录绑定 → 401', anonBind.status === 401, `${anonBind.status} ${anonBind.message}`);
    ok('⑧ 中文文案「未登录」', anonBind.message === '未登录', anonBind.message);
    const anonStatus = await api('GET', '/user/email');
    ok('⑧ 未登录查邮箱状态 → 401', anonStatus.status === 401, `${anonStatus.status} ${anonStatus.message}`);
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const guard = require(path.join(SERVER_DIR, 'dist', 'common', 'guards', 'jwt-auth.guard.js'));
    ok(
      '⑧ companion（打手态）白名单**默认拒绝** /user/email/bind 与 /user/email',
      guard.isCompanionAllowedRoute('POST', '/api/v1/user/email/bind') === false &&
        guard.isCompanionAllowedRoute('GET', '/api/v1/user/email') === false,
    );

    // ══════════════════════════════ ⑨ 旧路径逐字不变 ══════════════════════════════
    section('⑨ 旧路径照旧（register 场景 / 密码登录 / DTO 校验）');
    const regScene = await api('POST', '/auth/email/code', { email: emailA2, scene: 'register' });
    ok('⑨ scene=register 对已注册邮箱仍 400 且文案未变', regScene.status === 400 && regScene.message === '该邮箱已被注册，请直接登录或使用找回密码', `${regScene.status} ${regScene.message}`);
    const reloginA = await passwordLogin(usernameA);
    ok('⑨ 密码登录照常可用（未被邮箱功能锁死）', reloginA.status === 200 && !!reloginA.data?.accessToken);
    tokenA = reloginA.data.accessToken;
    const shortPwd = await api('POST', '/auth/login', { username: usernameA, role: 'user' });
    ok('⑨ 未传 email 时 username/password 仍是必填（DTO 逐字未放松）', shortPwd.status === 400 && /密码/.test(String(shortPwd.message)), `${shortPwd.status} ${shortPwd.message}`);
    const emailLoginNoCode = await api('POST', '/auth/login', { email: emailA2, role: 'user' });
    ok('⑨ 传 email 但不传 emailCode → 400「邮箱或验证码错误」', emailLoginNoCode.status === 400 && emailLoginNoCode.message === '邮箱或验证码错误', `${emailLoginNoCode.status} ${emailLoginNoCode.message}`);

    // ══════════════════════════════ ⑩ 审计 ══════════════════════════════
    section('⑩ 审计：operation_log + login_log 留痕，且**不含明文验证码**');
    const auditRows = async (action) => {
      for (let i = 0; i < 10; i++) {
        const [rows] = await db.query(
          `SELECT action, request_body FROM operation_log WHERE admin_id = ? AND action = ? ORDER BY id`,
          [accA.id, action],
        );
        if (rows.length > 0) return rows;
        await sleep(200); // opLog 是 fire-and-forget，轮询等落库
      }
      return [];
    };
    const bindAudit = await auditRows('email_bind');
    ok('⑩ operation_log 有 email_bind 行', bindAudit.length >= 1, JSON.stringify(bindAudit.slice(0, 1)));
    ok(
      '⑩ email_bind 记了脱敏邮箱 + oldEmail=null',
      bindAudit.some((r) => String(r.request_body).includes('oldEmail":null') && /"email":"[^"]*\*\*\*/.test(String(r.request_body))),
      String(bindAudit[0]?.request_body ?? ''),
    );
    const rebindAudit = await auditRows('email_rebind');
    ok('⑩ operation_log 有 email_rebind 行（换绑）', rebindAudit.length >= 1);
    ok(
      '⑩ email_rebind 有**新旧邮箱脱敏对比**',
      rebindAudit.some((r) => /"email":"[^"]*\*\*\*/.test(String(r.request_body)) && /"oldEmail":"[^"]*\*\*\*/.test(String(r.request_body))),
      String(rebindAudit[0]?.request_body ?? ''),
    );
    const loginAudit = await auditRows('login_by_email_code');
    ok('⑩ operation_log 有 login_by_email_code 行', loginAudit.length >= 1);
    ok('⑩ 该行标明 via=email_code', loginAudit.some((r) => String(r.request_body).includes('"via":"email_code"')), String(loginAudit[0]?.request_body ?? ''));
    const [logRows] = await db.query(
      `SELECT user_type, result, fail_reason FROM login_log WHERE user_id = ? ORDER BY id DESC LIMIT 30`,
      [accA.id],
    );
    ok(
      '⑩ login_log 成功行标明「邮箱验证码登录（via=email_code）」',
      logRows.some((r) => r.result === 'success' && String(r.fail_reason).includes('via=email_code')),
      JSON.stringify(logRows.filter((r) => r.result === 'success').slice(0, 3)),
    );
    const [auditAll] = await db.query(
      `SELECT CONCAT(COALESCE(request_body,''), '|', COALESCE(action,'')) t FROM operation_log WHERE admin_id IN (?)
       UNION ALL SELECT CONCAT(COALESCE(fail_reason,''), '|', COALESCE(username,'')) FROM login_log WHERE user_id IN (?)`,
      [createdUserIds, createdUserIds],
    );
    const realCodes = usedCodes.filter((c) => /^\d{6}$/.test(String(c)));
    const codeLeak = auditAll.filter((r) => realCodes.some((c) => String(r.t).includes(c)));
    ok(
      '⑩ **任何审计行都不含明文验证码**',
      codeLeak.length === 0,
      `检查了 ${realCodes.length} 个真实码，leak=${JSON.stringify(codeLeak.slice(0, 2))}`,
    );

    // ══════════════════════════════ QQ ══════════════════════════════
    section('QQ 登录（服务端接线）');
    const probe = await api('POST', '/auth/qq/login', { accessToken: TOKEN_BAD, openid: OPENID_1 });
    const qqConfigured = QQ_MODE === 'stub' || (QQ_MODE === 'auto' && probe.status !== 503);
    console.log(`    QQ 模式：${qqConfigured ? '打桩（已配置 QQ_APP_ID/QQ_APP_KEY + QQ_GRAPH_BASE_URL）' : '未配置'}`);

    if (!qqConfigured) {
      ok('QQ#1 未配置时 /auth/qq/login → **503**', probe.status === 503, `${probe.status} ${probe.message}`);
      ok('QQ#1 中文文案「QQ 登录未配置」', probe.message === 'QQ 登录未配置', probe.message);
      const bind503 = await api('POST', '/auth/qq/bind', { accessToken: TOKEN_GOOD, openid: OPENID_1 }, tokenA);
      ok('QQ#2 未配置时 /auth/qq/bind（已登录）→ **503**', bind503.status === 503, `${bind503.status} ${bind503.message}`);
      ok('QQ#2 中文文案「QQ 登录未配置」', bind503.message === 'QQ 登录未配置', bind503.message);
      ok('QQ#3 未配置时**零网络调用**（打桩服务器 0 命中）', stub.hits.length === 0, `hits=${stub.hits.length}`);
    } else {
      // ---------- 无效 token（探测请求本身就是这一条） ----------
      ok('QQ#1 无效 access_token → 400 中文「QQ 授权已失效，请重新授权后登录」', probe.status === 400 && probe.message === 'QQ 授权已失效，请重新授权后登录', `${probe.status} ${probe.message}`);

      // ---------- 新账号 ----------
      const qqLogin1 = await api('POST', '/auth/qq/login', { accessToken: TOKEN_GOOD, openid: OPENID_1 });
      ok('QQ#2 首次 QQ 登录 → 200 + 令牌 + isNewUser=true', qqLogin1.status === 200 && qqLogin1.data?.isNewUser === true && !!qqLogin1.data?.accessToken, `${qqLogin1.status} ${qqLogin1.message}`);
      const qqUserId1 = String(qqLogin1.data?.user?.id ?? '');
      createdUserIds.push(qqUserId1);
      ok('QQ#2 响应带账号摘要（id/username/uid/nickname）', !!qqLogin1.data?.user?.username && qqLogin1.data?.user?.nickname === QQ_NICK, JSON.stringify(qqLogin1.data?.user));
      const [[oauthRow1]] = await db.query('SELECT provider, openid, unionid, user_id FROM user_oauth WHERE provider=? AND openid=?', ['qq', OPENID_1]);
      ok('QQ#2 user_oauth 落库（provider=qq + 服务端 openid + unionid）', !!oauthRow1 && String(oauthRow1.user_id) === qqUserId1 && oauthRow1.unionid === UNIONID_1, JSON.stringify(oauthRow1));
      const [[qqUserRow]] = await db.query('SELECT username, uid, role, password_hash FROM user WHERE id=?', [qqUserId1]);
      ok('QQ#2 新账号 role=user、有展示 ID（注册同款生成器）、无密码', qqUserRow.role === 'user' && /^U\d{10}$/.test(qqUserRow.uid) && qqUserRow.password_hash === '', JSON.stringify(qqUserRow));
      const [[walletRow]] = await db.query('SELECT COUNT(*) c FROM wallet WHERE user_id=?', [qqUserId1]);
      ok('QQ#2 与账号同事务建了钱包', Number(walletRow.c) === 1);
      const pwLoginQq = await api('POST', '/auth/login', { username: qqUserRow.username, password: 'whatever-123', role: 'user' });
      ok('QQ#2 QQ 账号无密码 → 密码登录 401「账号或密码错误」', pwLoginQq.status === 401 && pwLoginQq.message === '账号或密码错误', `${pwLoginQq.status} ${pwLoginQq.message}`);
      // 服务端复核请求形状（打桩侧逐条断言）
      const meHit = stub.hits.find((h) => h.path === '/oauth2.0/me' && h.query.access_token === TOKEN_GOOD);
      ok('QQ#2 服务端自己调 oauth2.0/me（access_token + fmt=json + unionid=1）', !!meHit && meHit.query.fmt === 'json' && meHit.query.unionid === '1', JSON.stringify(meHit?.query));
      const infoHit = stub.hits.find((h) => h.path === '/user/get_user_info' && h.query.access_token === TOKEN_GOOD);
      ok('QQ#2 服务端调 get_user_info（oauth_consumer_key + **服务端** openid）', !!infoHit && infoHit.query.oauth_consumer_key === APP_ID && infoHit.query.openid === OPENID_1, JSON.stringify(infoHit?.query));

      // ---------- 已绑定 → 复用账号 ----------
      const qqLogin2 = await api('POST', '/auth/qq/login', { accessToken: TOKEN_GOOD, openid: OPENID_1 });
      ok('QQ#3 再次登录 → 200 + isNewUser=false + 同一账号', qqLogin2.status === 200 && qqLogin2.data?.isNewUser === false && String(qqLogin2.data?.user?.id) === qqUserId1, `${qqLogin2.status} ${JSON.stringify(qqLogin2.data?.user)}`);
      const [[oauthCount]] = await db.query('SELECT COUNT(*) c FROM user_oauth WHERE provider=? AND openid=?', ['qq', OPENID_1]);
      ok('QQ#3 user_oauth 仍只有 1 行（不重复建绑定）', Number(oauthCount.c) === 1, String(oauthCount.c));

      // ---------- 伪造 openid → 拒绝（变异验证 M2 的靶子） ----------
      const forged = await api('POST', '/auth/qq/login', { accessToken: TOKEN_GOOD, openid: OPENID_FORGED });
      ok('QQ#4 伪造 openid → **403**（服务端复核结果为准）', forged.status === 403, `${forged.status} ${forged.message}`);
      ok('QQ#4 中文文案点名不一致', /openid/.test(String(forged.message)) && /不一致/.test(String(forged.message)), forged.message);
      const [[forgedRow]] = await db.query('SELECT COUNT(*) c FROM user_oauth WHERE provider=? AND openid=?', ['qq', OPENID_FORGED]);
      ok('QQ#4 伪造 openid **没有**被写进 user_oauth', Number(forgedRow.c) === 0);
      const [[forgedUser]] = await db.query('SELECT COUNT(*) c FROM user WHERE username LIKE ?', ['qq_%DEADBEEF%']);
      ok('QQ#4 也没有为伪造 openid 建账号', Number(forgedUser.c) === 0);

      // ---------- callback(...) 包裹形态也能解析 ----------
      const cb = await api('POST', '/auth/qq/login', { accessToken: TOKEN_CALLBACK, openid: OPENID_CALLBACK });
      ok('QQ#5 `callback({...})` 形态也能解析 → 200 建号', cb.status === 200 && cb.data?.isNewUser === true, `${cb.status} ${cb.message}`);
      createdUserIds.push(String(cb.data?.user?.id ?? ''));

      // ---------- 限流（5 次/分/IP）确实生效：先清掉本用例前面用掉的计数，得到干净的 5 次额度 ----------
      await redis.del(`rl:login:127.0.0.1:qq`);
      const allowed = [];
      for (let i = 0; i < 5; i += 1) {
        allowed.push(await api('POST', '/auth/qq/login', { accessToken: TOKEN_BAD, openid: OPENID_1 }));
      }
      const sixth = await api('POST', '/auth/qq/login', { accessToken: TOKEN_BAD, openid: OPENID_1 });
      ok('QQ#6 窗口内前 5 次都被放行（未被误伤）', allowed.every((r) => r.status === 400), JSON.stringify(allowed.map((r) => r.status)));
      // 2026-10-13 口径统一：QQ 登录限流与密码登录同一档，均为 **429**（docs/03 第 35 行）
      ok('QQ#6 第 6 次同 IP QQ 登录 → 429「登录尝试过于频繁，请稍后再试」', sixth.status === 429 && sixth.message === '登录尝试过于频繁，请稍后再试', `${sixth.status} ${sixth.message}`);
      // 清掉自己刚用满的限流键，避免影响后续用例与别的套件（不影响被测逻辑：限流已在上一条被证明生效）
      for (const k of rateKeys) await redis.del(k);
      console.log('    NOTE 已清理本人限流键（rl:login:…:qq / rl:qqbind:…），供后续用例继续');

      // ---------- 别家应用的 token（client_id 不匹配）→ 拒绝 ----------
      const otherApp = await api('POST', '/auth/qq/login', { accessToken: TOKEN_OTHER_APP, openid: OPENID_1 });
      ok('QQ#7 别家应用 token（client_id 不匹配）→ 400 中文', otherApp.status === 400 && otherApp.message === 'QQ 授权已失效，请重新授权后登录', `${otherApp.status} ${otherApp.message}`);

      // ---------- 绑定到当前账号 / 冲突 / 幂等 ----------
      const freshA = await passwordLogin(usernameA);
      tokenA = freshA.data.accessToken;
      const bindOk = await api('POST', '/auth/qq/bind', { accessToken: TOKEN_GOOD2, openid: OPENID_2 }, tokenA);
      ok('QQ#8 已登录 + 服务端复核通过 → 绑定成功', bindOk.status === 200 && bindOk.data?.bound === true && bindOk.data?.alreadyBound === false, `${bindOk.status} ${JSON.stringify(bindOk.data)}`);
      ok('QQ#8 绑定响应 openid 脱敏', !!bindOk.data?.openid && !bindOk.raw.includes(OPENID_2), bindOk.data?.openid);
      const [[bindRow]] = await db.query('SELECT user_id FROM user_oauth WHERE provider=? AND openid=?', ['qq', OPENID_2]);
      ok('QQ#8 user_oauth 记到当前账号', String(bindRow?.user_id) === String(accA.id), JSON.stringify(bindRow));
      const bindAgain = await api('POST', '/auth/qq/bind', { accessToken: TOKEN_GOOD2, openid: OPENID_2 }, tokenA);
      ok('QQ#9 重复绑同一个 QQ 到自己 → 幂等成功', bindAgain.status === 200 && bindAgain.data?.alreadyBound === true, `${bindAgain.status} ${JSON.stringify(bindAgain.data)}`);
      const freshB = await passwordLogin(usernameB);
      const bindConflict = await api('POST', '/auth/qq/bind', { accessToken: TOKEN_GOOD2, openid: OPENID_2 }, freshB.data.accessToken);
      ok('QQ#10 同一 QQ 绑到别的账号 → 409 中文「该 QQ 已被其他账号绑定」', bindConflict.status === 409 && bindConflict.message === '该 QQ 已被其他账号绑定', `${bindConflict.status} ${bindConflict.message}`);
      const bindForged = await api('POST', '/auth/qq/bind', { accessToken: TOKEN_GOOD, openid: OPENID_FORGED }, tokenA);
      ok('QQ#11 绑定也复核 openid（伪造 → 403，不落库）', bindForged.status === 403, `${bindForged.status} ${bindForged.message}`);
      const qqBindAudit = await auditRows('qq_bind');
      ok('QQ#12 operation_log 有 qq_bind 行且 openid 脱敏', qqBindAudit.length >= 1 && /"openid":"[^"]*\*\*\*/.test(String(qqBindAudit[0]?.request_body)), String(qqBindAudit[0]?.request_body ?? ''));
    }

    // ══════════════════════════════ 汇总 ══════════════════════════════
    section('汇总');
    console.log(`PASS=${pass}  FAIL=${fail}`);
  } catch (e) {
    fail += 1;
    console.error(`\n[EXCEPTION] ${e && e.stack ? e.stack : String(e)}`);
  } finally {
    // ─────────────── 自清：DB 行 + Redis 键 ───────────────
    section('清理（自己建的临时账号与键）');
    try {
      const ids = createdUserIds.filter(Boolean).map(String);      const deleted = {};
      const q = async (sql, params) => (await db.query(sql, params))[0].affectedRows ?? 0;
      if (ids.length) {
        deleted.user_oauth = await q('DELETE FROM user_oauth WHERE user_id IN (?)', [ids]);
        deleted.auth_token = await q('DELETE FROM auth_token WHERE user_id IN (?)', [ids]);
        deleted.wallet = await q('DELETE FROM wallet WHERE user_id IN (?)', [ids]);
        deleted.operation_log = await q('DELETE FROM operation_log WHERE admin_id IN (?)', [ids]);
        deleted.user = await q('DELETE FROM `user` WHERE id IN (?)', [ids]);
      }
      /**
       * login_log 收尾三路并集（缺一都会留痕）：
       * ① 本脚本账号的行；② username 恰好是我的临时账号/邮箱的行；
       * ③ `username='qq'` 的 QQ 登录行 —— **时间比较必须用 UTC**：`created_at` 由 TypeORM 以 UTC 写入，
       *    而 mysql2 把 JS Date 按**本地时区**格式化，直接用 `new Date(...)` 比较会整体差 8 小时（实测漏删 80 行）。
       */
      deleted.login_log = await q(
        `DELETE FROM login_log
          WHERE user_id IN (?)
             OR username IN (?)
             OR (username = 'qq' AND created_at >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3 HOUR))`,
        [ids.length ? ids : [0], identifiers],
      );
      // Redis：显式键（保险）+ 按本次邮箱前缀扫描（覆盖"限流计数/重发锁"等一切派生键）
      let keyCount = 0;
      for (const k of [...usedRedisKeys, ...rateKeys]) keyCount += await redis.del(k);
      for (const prefix of [emailA, emailA2, emailA3, emailFree, emailResetFree]) {
        for (const pattern of [`email:*:bind:${prefix}`, `email:*:login:${prefix}`, `email:*:${prefix}`]) {
          const found = await redis.keys(pattern);
          if (found.length) keyCount += await redis.del(...found);
        }
      }
      // 自己占用的「同 IP 取码额度」也清掉：否则会把共享 IP 的 10 次/小时额度吃掉一半（别的套件会莫名 429）
      keyCount += await redis.del('email:cnt:ip:127.0.0.1');
      console.log(`    DB 删除：${JSON.stringify(deleted)}`);
      console.log(`    Redis 删除键数：${keyCount}`);
      const [[leftUser]] = await db.query('SELECT COUNT(*) c FROM `user` WHERE username IN (?)', [identifiers]);
      const [[leftOauth]] = await db.query('SELECT COUNT(*) c FROM user_oauth WHERE openid IN (?)', [[OPENID_1, OPENID_2, OPENID_CALLBACK, OPENID_FORGED]]);
      const leftoverKeys = await redis.keys(`email:*:${emailA}`);
      ok('清理：临时账号已删除', Number(leftUser.c) === 0, `left=${leftUser.c}`);
      ok('清理：user_oauth 测试行已删除', Number(leftOauth.c) === 0, `left=${leftOauth.c}`);
      ok('清理：Redis 取码/限流键已删除', leftoverKeys.length === 0, `leftKeys=${leftoverKeys.length}`);
    } catch (e) {
      fail += 1;
      console.error(`    [清理失败] ${e && e.message ? e.message : String(e)}`);
    }
    await stub.close();
    await mailStub.close();
    await db.end();
    redis.disconnect();
    console.log(`\n=== 结果：PASS=${pass} FAIL=${fail} ===`);
    process.exit(fail === 0 ? 0 : 1);
  }
})();
