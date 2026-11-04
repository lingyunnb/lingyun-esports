/**
 * 打手提现「真实链路」验证脚本（2026-10-11，**只新增验证脚本、不改业务代码**）
 * ============================================================================
 * 为什么需要它
 * ----------------------------------------------------------------------------
 * `scripts/tools/withdraw-e2e.js`（98/0）覆盖了后端逻辑，但它是**自建自清**的：
 * 跑完把 `withdraw_request` / `worker_withdraw_account` 全删，库里因此**永远是 0 行申请** ——
 * 管理端「提现审核」页与客户端打手态从未在**真数据**上跑过。本脚本补的正是这一环：
 * 走**真实链路**留下一笔**待处理**申请给负责人亲手打款/驳回，并留下收款码图作为证据。
 *
 * 链路（**不做"直接插库"**）
 * ----------------------------------------------------------------------------
 *   ① 夹具打手 `wd_demo_worker`（_demo 后缀；**刻意不复用 wd_e2e_worker** —— 那个账号会被
 *      `withdraw-e2e.js` 跑前跑后连单据一起 wipe 掉，留不住演示数据）→ 确认档案**在职** + 有钱包；
 *      余额不足 ¥10 时按**既有修数口径**（写 `wallet_transaction` + 同步 `wallet.balance`，
 *      账实一致：余额 = Σ 流水）补到 **¥100.00**（`withdraw-e2e.js#normalize` 同一口径的夹具行为）；
 *   ② 夹具老板 `wd_demo_boss`（**不是** kslingyun / opsadmin）调 `POST /user/identity/bind`
 *      绑该打手 → 拿 **companion** 会话（= 真机「我的 → 身份 → 绑定打手账号」那条路）；
 *   ③ companion 上传**真实生成的收款码 PNG**（带姓名，`/media/upload` type=withdraw_qr）
 *      → `POST /worker/withdraw/account` 绑定收款信息；
 *   ④ companion `POST /worker/withdraw/requests { amount: 10, idempotencyKey }`
 *      → 断言 id / status=pending / 余额**精确 -¥10.00** / `wallet_transaction` 有 `withdraw` 且金额 -10.00
 *        / `operation_log` 有痕 / companion 会话 kind=companion；
 *   ⑤ `opsadmin`（`withdraw:review`）`GET /admin/withdraw/requests?status=pending` → 断言这一笔真的查得到
 *      （昵称/工号/¥10.00/申请时间/脱敏收款信息），并顺带断言受保护取图通道能读出收款码。
 *
 * ⚠️ 本脚本**不清理**（这笔申请是留给负责人操作的演示数据）、**不 pay、不 reject**、
 *    不删任何审计与流水、不碰任何真人账号。产物：`docs/验收素材/2026-10-11-提现/real-apply.json`
 *    （给真浏览器断言脚本 `verify-admin-withdraw-real-row.mjs` 读）。
 *
 * 可复跑：若该打手已有一笔 pending → **复用**（不重复扣款、不重复造单）；已绑收款信息 → 跳过换绑
 * （保留原收款码证据）。若当日已被 dailyLimit 挡住 → 临时放开再还原（`withdraw-e2e.js` 同一姿势）。
 *
 * 运行：node scripts/tools/withdraw-real-apply.js
 * 前置：pm2 fish-server（http://127.0.0.1:3100）
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const mysql = require('D:/fish/server/node_modules/mysql2/promise');
const sharp = require('D:/fish/server/node_modules/sharp');
const { adminUser, adminPassword: adminPw } = require('./regression-admin');
const fixtures = require('../tmp/test-fixtures');

const BASE = 'http://127.0.0.1:3100/api/v1';
const ROOT = path.resolve(__dirname, '..', '..');
const ART_DIR = path.join(ROOT, 'docs', '验收素材', '2026-10-11-提现');
const ARTIFACT = path.join(ART_DIR, 'real-apply.json');

/** 测试打手（**带 _demo 后缀**；workerNo 拟真，避免看起来像占位符） */
const WORKER = { username: 'wd_demo_worker', workerNo: 'W-20429', nickname: '阿岩不熬夜' };
/** 测试老板（**不是** kslingyun / opsadmin；只用于拿 companion 会话） */
const BOSS = { username: 'wd_demo_boss', nickname: '演示老板·提现链路' };
/** 收款信息（演示数据；姓名必须与收款码图上的姓名一致 —— 这正是管理员要核对的那件事） */
const PAYEE = { realName: '陈岩', phone: '13907315528', wechatId: 'ayan_chen_0917' };
/** 申请金额（= 负责人定案门槛 minAmount 10） */
const AMOUNT = 10;
/** 夹具余额归一目标（只向上补；**不是**业务路径，是"修数口径"夹具） */
const TARGET_BALANCE = 100;
/**
 * `--rebind-qr`：已绑过收款信息时**强制重新生成并换绑**收款码。
 * 用途：修图/换图后让这笔 pending 的收款码证据也更新（换绑走真实接口，旧值进审计）——
 * 默认不开（幂等复跑时保留原证据图）。
 */
const FORCE_REBIND_QR = process.argv.includes('--rebind-qr');

let pass = 0;
let fail = 0;
/** 证据收集：给真浏览器脚本与最终报告用 */
const evidence = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const j = (v) => JSON.stringify(v);
const yuan = (n) => `¥${Number(n).toFixed(2)}`;
const isChinese = (s) => /[\u4e00-\u9fa5]/.test(String(s ?? ''));

function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
  return !!cond;
}

async function req(method, p, token, body, extraHeaders = {}) {
  const r = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
      ...extraHeaders,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const text = await r.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* 空/二进制 */
  }
  return { status: r.status, json, text, message: json?.message, data: json?.data };
}

/** 受保护取图（验证"收款码在管理端可取"）：返回 { status, type, bytes } */
async function fetchMedia(token, p) {
  const r = await fetch(BASE + p, { headers: { Authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(20000) });
  const buf = Buffer.from(await r.arrayBuffer());
  return { status: r.status, type: r.headers.get('content-type') ?? '', bytes: buf.length };
}

/** JWT payload（**只解码，不验签**：只为把 companion 会话的 jti/kind 写进证据） */
function jwtPayload(token) {
  try {
    return JSON.parse(Buffer.from(String(token).split('.')[1], 'base64url').toString('utf8'));
  } catch {
    return {};
  }
}

/**
 * 生成一张**真实的微信收款码风格 PNG**（sharp 渲染 SVG，中文用系统字体）。
 *
 * 为什么不写占位符 / 不用别人的图：这张图就是"管理员要核对的打款去向"，
 * 上面的姓名必须与 `PAYEE.realName` 一致，否则这笔演示单反而演示了一个错的审核动作。
 * 二维码点阵由 seed（含生成时间）确定 —— 每次运行内容都不同（媒体层按 sha256 去重，
 * 相同内容会复用旧 media 行，这里刻意避开）。
 */
function qrSvg(seed, generatedAt) {
  const N = 33;
  const cell = 11;
  const quiet = 3;
  const px = (N + quiet * 2) * cell; // 429：含静默区的方阵边长
  const W = 640;
  const headerH = 96;
  const cardX = 40;
  const cardW = W - 80;
  const cardY = 128;
  const qrX = Math.round((W - px) / 2);
  const qrY = cardY + 44;
  const nameY = qrY + px + 58;
  const capY = nameY + 38;
  const genY = capY + 28;
  const cardH = genY - cardY + 30;
  const H = cardY + cardH + 40;
  let s = seed >>> 0;
  const rnd = () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  };
  const finder = (r, c) => (r < 7 && c < 7) || (r < 7 && c >= N - 7) || (r >= N - 7 && c < 7);
  const rects = [];
  for (let r = 0; r < N; r += 1) {
    for (let c = 0; c < N; c += 1) {
      if (finder(r, c)) continue;
      if (rnd() > 0.52) {
        rects.push(`<rect x="${(c + quiet) * cell}" y="${(r + quiet) * cell}" width="${cell}" height="${cell}"/>`);
      }
    }
  }
  /** 三个定位角：7×7 实心 + 5×5 白 + 3×3 实心（QR 的视觉标志，一眼能认出是收款码） */
  const eyes = [
    [0, 0],
    [0, N - 7],
    [N - 7, 0],
  ]
    .map(([r, c]) => {
      const x = (c + quiet) * cell;
      const y = (r + quiet) * cell;
      return (
        `<rect x="${x}" y="${y}" width="${cell * 7}" height="${cell * 7}" fill="#111"/>` +
        `<rect x="${x + cell}" y="${y + cell}" width="${cell * 5}" height="${cell * 5}" fill="#fff"/>` +
        `<rect x="${x + cell * 2}" y="${y + cell * 2}" width="${cell * 3}" height="${cell * 3}" fill="#111"/>`
      );
    })
    .join('');
  /**
   * 版式（**必须整体 translate 到卡片里**：方阵与卡片各画各的会互相压住 —— 首版就踩了这个，
   * 二维码盖到绿色标题条上，图上是一片糊的方块）：
   * 灰底 → 绿色标题条 → 白色卡片 → 方阵（translate 到 qrX/qrY）→ 定位角 → 姓名 → 说明。
   */
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <rect width="${W}" height="${H}" fill="#EDEDED"/>
  <rect x="0" y="0" width="${W}" height="${headerH}" fill="#07C160"/>
  <text x="${W / 2}" y="60" font-family="Microsoft YaHei, SimHei, sans-serif" font-size="32" font-weight="bold" text-anchor="middle" fill="#ffffff">微信收款码</text>
  <rect x="${cardX}" y="${cardY}" width="${cardW}" height="${cardH}" rx="18" fill="#ffffff"/>
  <g transform="translate(${qrX},${qrY})" fill="#111">${rects.join('')}</g>
  <g transform="translate(${qrX},${qrY})">${eyes}</g>
  <text x="${W / 2}" y="${nameY}" font-family="Microsoft YaHei, SimHei, sans-serif" font-size="40" font-weight="bold" text-anchor="middle" fill="#111">${PAYEE.realName}</text>
  <text x="${W / 2}" y="${capY}" font-family="Microsoft YaHei, SimHei, sans-serif" font-size="21" text-anchor="middle" fill="#888">演示收款码 · 仅用于打手提现链路验收</text>
  <text x="${W / 2}" y="${genY}" font-family="Microsoft YaHei, SimHei, sans-serif" font-size="19" text-anchor="middle" fill="#aaa">生成于 ${generatedAt}</text>
</svg>`;
}

(async () => {
  fs.mkdirSync(ART_DIR, { recursive: true });
  const env = fs.readFileSync(path.join(ROOT, 'server', '.env'), 'utf8');
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
  const one = async (sql, args) => (await q(sql, args))[0] ?? null;

  console.log('=== 打手提现「真实链路」验证（留下一笔 pending 给负责人操作）===');

  // ---------------------------------------------------------------- 管理端登录（专用测试超管）
  const al = await req('POST', '/auth/login', null, { username: adminUser, password: adminPw, role: 'admin' });
  if (al.status !== 200 || !al.data?.accessToken) throw new Error(`管理端登录失败（${adminUser}）：${al.status} ${al.message}`);
  const adminToken = al.data.accessToken;
  const adminUserId = String((await req('GET', '/auth/me', adminToken)).data?.id ?? '');
  console.log(`[账号] 管理端 = ${adminUser}（专用测试超管，id=${adminUserId}）`);

  const meAdmin = await req('GET', '/auth/me', adminToken);
  const perms = [
    ...(meAdmin.data?.admin?.permissions ?? []),
    ...(meAdmin.data?.permissions ?? []),
    ...(meAdmin.data?.permCodes ?? []),
  ].map(String);
  ok('①-a opsadmin 带 `withdraw:review`（管理端能看到这一笔的前提）',
    perms.includes('withdraw:review'),
    `perms(withdraw:*) = ${j([...new Set(perms.filter((p) => p.startsWith('withdraw')))])}`);

  // ---------------------------------------------------------------- 夹具：打手 + 老板
  /**
   * ⚠️ 2026-10-13：`ensureWorker` 现在**自己就把打手绑到「这个打手固定的老板」**（默认派生
   * `wfx_wd_demo_worker`，见 test-fixtures.js#fixtureBossFor）并返回 **companion** token ——
   * 它不再做 worker primary 登录（到期收口后恒 403，那是产品既定行为）。
   * 下面第 ② 步的 `wd_demo_boss` 绑定因此要**复用同一个老板**（本文件顶部 `BOSS.username` 与
   * `worker_identity_binding` 的唯一约束都要求"一个打手同时只被一个老板绑"）：
   * 已存在同一 active 行 → 服务端按设计**复用该绑定并重新签发 companion**（`rebound:true`），
   * 所以 ②-a 的 `bind.status===200 + bossTokenUnchanged` 断言口径**一个字都没改**。
   */
  const w = await fixtures.ensureWorker(adminToken, {
    username: WORKER.username, workerNo: WORKER.workerNo, nickname: WORKER.nickname,
    takeOrder: false, serveCustomer: false, bossUsername: BOSS.username,
  });
  const workerUserId = String(w.userId);
  const workerId = String(w.workerRow?.id ?? '');
  if (!workerId) throw new Error(`夹具打手 ${WORKER.username} 没有打手档案（workerId 为空）`);

  const bossToken = await fixtures.ensureBoss(BOSS.username, BOSS.nickname);
  const bossUserId = String((await req('GET', '/auth/me', bossToken)).data?.id ?? '');
  console.log(`[账号] 测试打手 = ${WORKER.username}#${workerUserId}（workerId=${workerId}，工号 ${WORKER.workerNo}）`);
  console.log(`[账号] 测试老板 = ${BOSS.username}#${bossUserId}（**不是** kslingyun / opsadmin）`);

  const wrow = await one('SELECT w.id, w.worker_no, w.status AS workerStatus, u.status AS userStatus, u.nickname FROM worker w JOIN user u ON u.id = w.user_id WHERE w.id = ?', [workerId]);
  ok('①-b 打手档案**在职**（worker.status=1）+ 账号可用（user.status=1）',
    Number(wrow?.workerStatus) === 1 && Number(wrow?.userStatus) === 1,
    `workerNo=${wrow?.worker_no} workerStatus=${wrow?.workerStatus} userStatus=${wrow?.userStatus} nickname=${wrow?.nickname}`);

  // ---------------------------------------------------------------- ① 钱包 + 余额归一到 ¥100.00（修数口径，账实一致）
  const walletRow = await one('SELECT id, balance FROM wallet WHERE user_id = ?', [workerUserId]);
  if (!walletRow) {
    await q('INSERT INTO wallet (user_id, balance) VALUES (?, 0.00)', [workerUserId]);
    console.log(`[夹具] 打手无钱包行 → 建行（balance=0.00）`);
  }
  const balBeforeTopup = Number((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance ?? 0);
  if (balBeforeTopup < 10) {
    const add = Number((TARGET_BALANCE - balBeforeTopup).toFixed(2));
    const after = Number((balBeforeTopup + add).toFixed(2));
    await q(
      `INSERT INTO wallet_transaction
         (transaction_no, user_id, change_type, amount, balance_before, balance_after,
          operator_type, operator_id, source, reason, idempotency_key, ip, created_at)
       VALUES (?, ?, 'grant', ?, ?, ?, 'admin', ?, 'admin-web', '提现真实链路夹具：余额归一（账实一致）', ?, '127.0.0.1', NOW(3))`,
      [
        `WDREAL${Date.now().toString(36).toUpperCase()}${crypto.randomBytes(2).toString('hex').toUpperCase()}`.slice(0, 32),
        workerUserId, add, balBeforeTopup, after, adminUserId,
        `wd-real-topup:${workerUserId}:${Date.now()}`,
      ],
    );
    await q('UPDATE wallet SET balance = ? WHERE user_id = ?', [after, workerUserId]);
    console.log(`[夹具] 余额 ${yuan(balBeforeTopup)} → ${yuan(after)}（补 ${yuan(add)}；写 grant 流水 + 同步 wallet.balance）`);
  } else {
    console.log(`[夹具] 余额 ${yuan(balBeforeTopup)} ≥ ¥10，无需补足（不动钱）`);
  }
  const walletBalance = Number((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance ?? 0);
  const txnSum = Number((await one('SELECT COALESCE(SUM(amount),0) AS s FROM wallet_transaction WHERE user_id = ?', [workerUserId]))?.s ?? 0);
  ok('①-c 钱包存在且账实一致（wallet.balance = Σ wallet_transaction.amount）',
    Math.abs(walletBalance - txnSum) < 0.005, `balance=${yuan(walletBalance)} Σ流水=${yuan(txnSum)}`);

  // ---------------------------------------------------------------- ② 老板绑定打手 → companion（真实会话）
  const bind = await req('POST', '/user/identity/bind', bossToken, { username: WORKER.username, password: 'password123' });
  const companionToken = bind.data?.companionToken;
  ok('②-a `POST /user/identity/bind` → companion 会话（老板 token 不变；绑定不顶任何 primary）',
    bind.status === 200 && !!companionToken && bind.data?.bossTokenUnchanged === true,
    `status=${bind.status} bindingId=${bind.data?.bindingId} rebound=${bind.data?.rebound} max=${bind.data?.maxPerBoss} ${bind.message ?? ''}`);
  if (!companionToken) throw new Error(`绑定失败，无法继续：${bind.status} ${bind.message}`);

  const cPayload = jwtPayload(companionToken);
  const cTokenRow = await one('SELECT kind, role, binding_id, user_id, revoked FROM auth_token WHERE jti = ?', [String(cPayload.jti ?? '')]);
  ok('②-b companion 会话在库里就是 `kind=companion`（role=worker、绑定到这条 binding、未吊销）',
    cTokenRow?.kind === 'companion' && cTokenRow?.role === 'worker' &&
      String(cTokenRow?.binding_id) === String(bind.data?.bindingId) && Number(cTokenRow?.revoked) === 0,
    `kind=${cTokenRow?.kind} role=${cTokenRow?.role} binding=${cTokenRow?.binding_id} revoked=${cTokenRow?.revoked}`);
  evidence.companion = { jti: String(cPayload.jti ?? ''), kind: cTokenRow?.kind, bindingId: String(bind.data?.bindingId ?? '') };

  // ---------------------------------------------------------------- ③ 收款码上传 + 绑定收款信息
  const existingAcc = await one(
    "SELECT id, real_name, phone, wechat_id, qr_media_id, status FROM worker_withdraw_account WHERE worker_id = ? AND status = 'active'",
    [workerId],
  );
  const accountBefore = await req('GET', '/worker/withdraw/account', companionToken);
  ok('③-a companion 可读 `GET /worker/withdraw/account`（打手态白名单 `/worker/*` 放行）',
    accountBefore.status === 200 && typeof accountBefore.data?.bound === 'boolean',
    `status=${accountBefore.status} bound=${accountBefore.data?.bound}`);

  let qrMediaId = existingAcc ? String(existingAcc.qr_media_id) : '';
  if (existingAcc && !FORCE_REBIND_QR) {
    console.log(`[收款码] 该打手已绑定收款信息（active 行 id=${existingAcc.id}，media=${qrMediaId}）→ 跳过换绑，保留原证据图`);
  } else {
    if (existingAcc) console.log(`[收款码] --rebind-qr：重新生成并**换绑**收款码（走真实接口 POST /worker/withdraw/account，换绑写审计）`);
    const now = new Date();
    const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ` +
      `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
    const seed = (Date.now() ^ Math.floor(Math.random() * 0xffff)) >>> 0;
    const png = await sharp(Buffer.from(qrSvg(seed, stamp))).png().toBuffer();
    // 本地留一份原始图（验收素材目录，不入 git）：与上传到平台的那张**同一份字节**
    const localCopy = path.join(ART_DIR, `收款码-${WORKER.nickname}-${WORKER.workerNo}.png`);
    fs.writeFileSync(localCopy, png);
    evidence.qrLocalCopy = localCopy;

    const fd = new FormData();
    fd.append('type', 'withdraw_qr');
    fd.append('file', new File([png], `wd-real-qr-${WORKER.workerNo}.png`, { type: 'image/png' }));
    const up = await fetch(`${BASE}/media/upload`, {
      method: 'POST', headers: { Authorization: 'Bearer ' + companionToken }, body: fd, signal: AbortSignal.timeout(30000),
    });
    const upText = await up.text();
    let upJson = null;
    try { upJson = JSON.parse(upText); } catch { /* ignore */ }
    qrMediaId = String(upJson?.data?.id ?? '');
    ok('③-b companion 上传**真实生成的收款码 PNG**（type=withdraw_qr，protected）→ 201/200 + mediaId',
      (up.status === 201 || up.status === 200) && !!qrMediaId &&
        String(upJson?.data?.path ?? '').includes('/api/v1/media/protected/'),
      `status=${up.status} mediaId=${qrMediaId} path=${upJson?.data?.path} bytes=${png.length} ${upJson?.message ?? ''}`);
    if (!qrMediaId) throw new Error(`收款码上传失败：${up.status} ${upText.slice(0, 200)}`);

    const acc = await req('POST', '/worker/withdraw/account', companionToken, {
      realName: PAYEE.realName, phone: PAYEE.phone, wechatId: PAYEE.wechatId, qrMediaId,
    });
    ok('③-c 绑定收款信息成功 → 回显**脱敏**（姓名 陈*、手机号 139****5528）+ qrUrl 走受保护通道',
      acc.status === 200 && acc.data?.bound === true &&
        acc.data?.realName === '陈*' && acc.data?.phone === '139****5528' &&
        String(acc.data?.qrUrl ?? '').includes('/api/v1/media/protected/') &&
        (!existingAcc || acc.data?.rebind === true),
      j({ realName: acc.data?.realName, phone: acc.data?.phone, wechatId: acc.data?.wechatId, qrUrl: acc.data?.qrUrl, rebind: acc.data?.rebind }));
  }

  const accRow = await one(
    "SELECT id, real_name, phone, wechat_id, qr_media_id, status FROM worker_withdraw_account WHERE worker_id = ? AND status = 'active'",
    [workerId],
  );
  const mediaRow = await one('SELECT id, media_type, is_protected, uploader_id, mime_type FROM media WHERE id = ?', [String(accRow?.qr_media_id ?? '')]);
  ok('③-d 库里收款信息 active 一行、字段与提交一致；收款码媒体**用途=withdraw_qr + is_protected=1 + 上传者=本人**',
    !!accRow && accRow.real_name === PAYEE.realName && accRow.phone === PAYEE.phone && accRow.wechat_id === PAYEE.wechatId &&
      mediaRow?.media_type === 'withdraw_qr' && Number(mediaRow?.is_protected) === 1 &&
      String(mediaRow?.uploader_id) === workerUserId,
    j({ accountId: accRow?.id, realName: accRow?.real_name, phone: accRow?.phone, media: mediaRow }));
  qrMediaId = String(accRow?.qr_media_id ?? qrMediaId);
  evidence.qrMediaId = qrMediaId;

  // ---------------------------------------------------------------- ④ 提交申请（申请即扣款）
  const pendingRow = await one(
    "SELECT * FROM withdraw_request WHERE worker_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 1",
    [workerId],
  );
  let requestId = pendingRow ? String(pendingRow.id) : '';
  let balanceBefore = Number((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance ?? 0);
  let balanceAfter = balanceBefore;
  let applyRes = null;
  const idempotencyKey = crypto.randomUUID();

  if (pendingRow) {
    console.log(`[复用] 该打手已有一笔 pending（id=${requestId}，${yuan(pendingRow.amount)}）→ 不重复扣款、不重复造单`);
    const t = await one('SELECT balance_before, balance_after FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1', [`withdraw:${requestId}`]);
    balanceBefore = Number(t?.balance_before ?? Number(pendingRow.amount));
    balanceAfter = Number(t?.balance_after ?? balanceBefore - Number(pendingRow.amount));
    console.log(`[余额快照]（复用单）申请前 ${yuan(balanceBefore)} → 申请后 ${yuan(balanceAfter)}（差额 ${yuan(balanceBefore - balanceAfter)}）`);
  } else {
    const cfgNow = await req('GET', '/admin/withdraw/config', adminToken);
    const dailyLimitWas = cfgNow.data?.dailyLimit;
    applyRes = await req('POST', '/worker/withdraw/requests', companionToken, { amount: AMOUNT, idempotencyKey });
    if (applyRes.status === 400 && String(applyRes.message).includes('今日提现申请次数已用完')) {
      // 当日次数已用完（此前有人操作过演示单）→ 临时放开再还原（withdraw-e2e.js 同一姿势）
      console.log(`[夹具] 命中每日次数上限（dailyLimit=${dailyLimitWas}）→ 临时放开到 ${Number(dailyLimitWas) + 1} 后重试，随后还原`);
      await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: Number(dailyLimitWas) + 1 });
      applyRes = await req('POST', '/worker/withdraw/requests', companionToken, { amount: AMOUNT, idempotencyKey });
      await req('PUT', '/admin/withdraw/config', adminToken, { dailyLimit: dailyLimitWas });
      const cfgBack = await req('GET', '/admin/withdraw/config', adminToken);
      ok('④-夹具 临时放开的 dailyLimit 已还原为原值',
        Number(cfgBack.data?.dailyLimit) === Number(dailyLimitWas), `daily=${cfgBack.data?.dailyLimit}`);
    }
    requestId = String(applyRes.data?.id ?? '');
    balanceAfter = Number((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance ?? 0);
    console.log(`[余额快照] 申请前 ${yuan(balanceBefore)} → 申请后 ${yuan(balanceAfter)}（差额 ${yuan(balanceBefore - balanceAfter)}）`);
    ok('④-a `POST /worker/withdraw/requests {amount:10, idempotencyKey}` → 201 + status=pending + 返回 id 与 balanceAfter',
      applyRes.status === 201 && applyRes.data?.status === 'pending' && !!requestId &&
        Number(applyRes.data?.balanceAfter) === Number((balanceBefore - AMOUNT).toFixed(2)),
      `status=${applyRes.status} id=${requestId} balanceAfter=${applyRes.data?.balanceAfter} ${applyRes.message ?? ''}`);
    ok('④-b 余额**在同一请求内立即减少 ¥10.00**（读库复核：before - 10.00 = after）',
      Number((balanceBefore - AMOUNT).toFixed(2)) === Number(balanceAfter.toFixed(2)),
      `${yuan(balanceBefore)} → ${yuan(balanceAfter)}`);
    if (!requestId) throw new Error(`申请失败：${applyRes.status} ${applyRes.message}`);
  }

  const reqRow = await one('SELECT * FROM withdraw_request WHERE id = ?', [requestId]);
  const txn = await one('SELECT * FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1', [`withdraw:${requestId}`]);
  ok('④-c 库内单据：status=pending、金额 ¥10.00、打了 applied_at、回写 wallet_transaction_id',
    reqRow?.status === 'pending' && Number(reqRow?.amount) === AMOUNT && !!reqRow?.applied_at &&
      String(reqRow?.wallet_transaction_id) === String(txn?.id),
    j({ id: requestId, status: reqRow?.status, amount: Number(reqRow?.amount), appliedAt: reqRow?.applied_at, txnId: String(txn?.id) }));
  ok('④-d `wallet_transaction`：change_type=withdraw、金额 **-10.00**、含前后余额快照（幂等键 withdraw:<id>）',
    txn?.change_type === 'withdraw' && Number(txn?.amount) === -AMOUNT &&
      Number(txn?.balance_after) === Number((Number(txn?.balance_before) - AMOUNT).toFixed(2)),
    j({ txnId: String(txn?.id), txnNo: txn?.transaction_no, type: txn?.change_type, amount: Number(txn?.amount), before: Number(txn?.balance_before), after: Number(txn?.balance_after) }));
  ok('④-d2 钱包当前余额 = 该笔流水的 balance_after（账实一致，钱真的扣了）',
    Number((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance) === Number(txn?.balance_after),
    `wallet=${yuan((await one('SELECT balance FROM wallet WHERE user_id = ?', [workerUserId]))?.balance)} txnAfter=${yuan(txn?.balance_after)}`);

  await sleep(600); // operation_log 是 fire-and-forget
  let applyLog = await one(
    "SELECT id, admin_id, action, method, path, request_body, created_at FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:apply' AND request_body LIKE ? ORDER BY id DESC LIMIT 1",
    [`%"requestId":"${requestId}"%`],
  );
  for (let i = 0; i < 5 && !applyLog; i += 1) {
    await sleep(500);
    applyLog = await one(
      "SELECT id, admin_id, action, method, path, request_body, created_at FROM operation_log WHERE module = 'withdraw' AND action = 'withdraw:apply' AND request_body LIKE ? ORDER BY id DESC LIMIT 1",
      [`%"requestId":"${requestId}"%`],
    );
  }
  let applyAudit = null;
  try { applyAudit = JSON.parse(applyLog?.request_body ?? 'null'); } catch { /* ignore */ }
  ok('④-e `operation_log` 有痕（action=withdraw:apply，含 requestId/金额/前后余额/流水号，不记密码 token）',
    !!applyLog && String(applyAudit?.requestId) === requestId && Number(applyAudit?.amount) === AMOUNT &&
      !/password|token|secret/i.test(String(applyLog.request_body)),
    `logId=${applyLog?.id} body=${j(applyAudit)}`);

  const bindLog = await one(
    "SELECT id, action, request_body FROM operation_log WHERE module = 'withdraw' AND action IN ('withdraw:account:bind','withdraw:account:rebind') ORDER BY id DESC LIMIT 1",
  );
  ok('④-f 收款信息绑定/换绑同样留痕（action=withdraw:account:bind|rebind）',
    !!bindLog && String(bindLog.request_body ?? '').includes(String(qrMediaId)),
    `action=${bindLog?.action} logId=${bindLog?.id}`);

  // ---------------------------------------------------------------- ⑤ 管理端 API 看得到（opsadmin / withdraw:review）
  const list = await req('GET', '/admin/withdraw/requests?status=pending&page=1&pageSize=50', adminToken);
  const row = (list.data?.list ?? []).find((x) => String(x.id) === requestId);
  ok('⑤-a `GET /admin/withdraw/requests?status=pending` → 这一笔**真的查到**（昵称/工号/¥10.00/待处理/申请时间齐全）',
    !!row && row.workerNickname === WORKER.nickname && row.workerNo === WORKER.workerNo &&
      Number(row.amount) === AMOUNT && row.status === 'pending' && !!row.appliedAt,
    j(row && { id: row.id, nickname: row.workerNickname, workerNo: row.workerNo, amount: row.amount, status: row.status, appliedAt: row.appliedAt }));
  ok('⑤-b 列表里收款信息**脱敏**（完整姓名/手机号不出现在响应体里）',
    !!row && row.accountMasked?.realName === '陈*' && row.accountMasked?.phone === '139****5528' &&
      !String(list.text).includes(PAYEE.realName) && !String(list.text).includes(PAYEE.phone),
    j(row?.accountMasked));
  const detail = await req('GET', `/admin/withdraw/requests/${requestId}`, adminToken);
  ok('⑤-c 详情给**完整**收款信息 + 收款码走受保护通道（审核必需）',
    detail.status === 200 && detail.data?.account?.realName === PAYEE.realName &&
      detail.data?.account?.phone === PAYEE.phone && detail.data?.account?.wechatId === PAYEE.wechatId &&
      String(detail.data?.account?.qrUrl ?? '').includes('/api/v1/media/protected/'),
    j(detail.data?.account));
  const qrRead = await fetchMedia(adminToken, `/admin/withdraw/proof/${requestId}?kind=qr`);
  ok('⑤-d 管理端按申请取收款码图（窄通道 `GET /admin/withdraw/proof/:id?kind=qr`）→ 200 真图片',
    qrRead.status === 200 && qrRead.type.startsWith('image/') && qrRead.bytes > 1000,
    `status=${qrRead.status} type=${qrRead.type} bytes=${qrRead.bytes}`);

  // ---------------------------------------------------------------- 证据落盘（给真浏览器断言脚本读）
  Object.assign(evidence, {
    generatedAt: new Date().toISOString(),
    adminUser,
    worker: { username: WORKER.username, userId: workerUserId, workerId, workerNo: WORKER.workerNo, nickname: WORKER.nickname },
    boss: { username: BOSS.username, userId: bossUserId },
    payee: { realName: PAYEE.realName, phone: PAYEE.phone, wechatId: PAYEE.wechatId, masked: row?.accountMasked ?? null },
    requestId,
    status: reqRow?.status,
    amount: AMOUNT,
    amountLabel: yuan(AMOUNT),
    balanceBefore: Number(txn?.balance_before ?? 0),
    balanceAfter: Number(txn?.balance_after ?? 0),
    appliedAt: reqRow?.applied_at ?? null,
    walletTransaction: {
      id: String(txn?.id ?? ''), transactionNo: txn?.transaction_no ?? '', changeType: txn?.change_type ?? '',
      amount: Number(txn?.amount ?? 0), balanceBefore: Number(txn?.balance_before ?? 0), balanceAfter: Number(txn?.balance_after ?? 0),
    },
    operationLog: { applyLogId: String(applyLog?.id ?? ''), bindLogId: String(bindLog?.id ?? ''), bindAction: bindLog?.action ?? '' },
    reusedExistingPending: !!pendingRow,
    pass, fail,
  });
  fs.writeFileSync(ARTIFACT, JSON.stringify(evidence, null, 2), 'utf8');

  console.log('\n=== 证据汇总（留给负责人操作的那一笔）===');
  console.log(`  申请 id      = ${requestId}（status=${reqRow?.status}，${yuan(reqRow?.amount)}，applied_at=${reqRow?.applied_at}）`);
  console.log(`  余额快照     = ${yuan(evidence.balanceBefore)} → ${yuan(evidence.balanceAfter)}（精确 -${yuan(AMOUNT)}）`);
  console.log(`  流水         = #${txn?.id} ${txn?.transaction_no} type=${txn?.change_type} amount=${yuan(txn?.amount)}`);
  console.log(`  收款码 media = #${qrMediaId}（withdraw_qr / protected / uploader=${workerUserId}）`);
  console.log(`  打手         = ${WORKER.nickname}（${WORKER.username}，工号 ${WORKER.workerNo}）`);
  console.log(`  产物         = ${ARTIFACT}`);
  console.log(`\n=== 结果：${pass} PASS / ${fail} FAIL ===`);

  await db.end();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('\n[异常]', e && e.stack ? e.stack : e);
  process.exit(1);
});
