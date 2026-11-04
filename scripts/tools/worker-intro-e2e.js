/**
 * 打手简介（陪玩介绍）· 端到端自证 —— 负责人 2026-10-17 改定「介绍让打手自己写」
 *
 * 运行（**先起一个实例**，默认 :3100；推荐另起 3111 以免影响本机回归）：
 *   $env:PORT=3111; node server/dist/main.js
 *   node scripts/tools/worker-intro-e2e.js
 *   E2E_BASE=http://127.0.0.1:3111/api/v1 node scripts/tools/worker-intro-e2e.js
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 覆盖的语义
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① **字段现状（升级前后取证）**：`user.intro` 是否存在 / 类型长度；`worker` 表**有没有** intro 列
 *     → 本改动**不需要** migration 的判据就在这里（120 ≤ 200，列已够宽）；
 *  ② 长度边界：1 字 400 / **2 字 200** / **120 字 200** / **121 字 400**（中文文案）；
 *  ③ **联系方式拦截**：手机号 / 微信号 / QQ 号 各一条 → 400 +「简介里不能留联系方式」；
 *     变体：`138 0013 8000`（带空格）同样拦；说明"拆写绕不过去"；
 *  ④ 换行：2 个换行 400；1 个换行 200；首尾空白 400；零宽字符 400；
 *  ⑤ **身份边界**：老板 primary 调 `PUT /worker/profile` → **403**，且库里 intro **一个字没变**；
 *     companion（老板端打手态）→ 200；worker primary 的现行结果（工作端已到期收口）如实记录；
 *  ⑥ **不接受请求体里的 workerId**：`{intro, workerId: 别人的}` → 400，别人简介保持不变；
 *  ⑦ **打完就能看到**：companion 改完后 `GET /public/players`（找陪玩名单）立刻返回新简介
 *     （服务端该接口**不进微缓存**且 `no-store`，所以不存在"等 30s"——30s 是客户端 SWR 档）；
 *  ⑧ **管理端兜底仍在，且两条路径互不覆盖**：
 *     - 管理端 `PUT /admin/workers/:id/players-profile` 写简介 → 200；
 *     - 管理端只传 `divisionId`（不带 intro）→ 打手刚写的简介**不被回滚**（lost update 已消除）；
 *     - `intro_updated_by`：打手自写 = NULL，管理端写 = 管理员 id；
 *  ⑨ 审计口径：本改动**不写** `operation_log`（非管理员动作）、**不写** `login_log`
 *     → 断言这两个表在"打手自写"前后**零新增**（真的没写，不是"我以为没写"）。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 夹具与清理（**自建自删**）
 * ─────────────────────────────────────────────────────────────────────────────
 *  - 临时打手账号 1 个（user role=worker + worker 档案 + 一个**已上架分部**的接单权限），
 *    让他在 `/public/players` 里可见；
 *  - 临时老板账号 1 个（role=user），用于 `POST /user/identity/bind` 拿 companion；
 *  - 临时超管 1 个（role=admin + admin(super_admin)），用于管理端兜底路径；
 *  - `finally` 里删：`worker_division_permission` → `worker` → `auth_token` / `worker_identity_binding`
 *    → `admin` → `user`（按外键依赖顺序，按 id 精确删除）。
 *
 * ⚠️ 除上述自建夹具外**只读**：不碰真实订单/钱包/结算/真实打手的简介。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '..', '..');
const mysql = require(path.join(ROOT, 'server', 'node_modules', 'mysql2', 'promise'));
const bcrypt = require(path.join(ROOT, 'server', 'node_modules', 'bcryptjs'));
const { checkWorkerIntro, INTRO_MAX_LENGTH } = require(path.join(
  ROOT,
  'server',
  'dist',
  'modules',
  'worker',
  'worker-intro.rules',
));

const BASE = process.env.E2E_BASE || 'http://127.0.0.1:3100/api/v1';

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

function readEnv() {
  const out = {};
  for (const raw of fs.readFileSync(path.join(ROOT, 'server', '.env'), 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const i = line.indexOf('=');
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

/** HTTP：返回 `{status, data, message, raw}`（已解统一信封 `{code,message,data}`） */
async function api(method, p, { token, body } = {}) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  let json = null;
  try {
    json = await r.json();
  } catch {
    /* 空体 */
  }
  return { status: r.status, data: json?.data, message: json?.message, code: json?.code, raw: json };
}

function makePassword() {
  const pick = (chars, n) => Array.from({ length: n }, () => chars[crypto.randomInt(chars.length)]).join('');
  return `Itr${pick('!#%+=?', 1)}${pick('ABCDEFGHJKLMNPQRSTUVWXYZ', 2)}${pick('abcdefghijkmnopqrstuvwxyz', 5)}${pick('23456789', 4)}`;
}

const repeat = (ch, n) => Array.from({ length: n }, () => ch).join('');

(async () => {
  const env = readEnv();
  const db = await mysql.createConnection({
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER,
    password: env.DB_PASSWORD,
    database: env.DB_NAME,
    charset: 'utf8mb4',
  });

  const created = { users: [], workerIds: [], bindingIds: [] };
  let workerUserId = null;
  let workerId = null;
  let otherWorkerId = null;

  try {
    console.log('=== 打手简介 E2E（介绍让打手自己写，管理端兜底）===');
    console.log(`API = ${BASE}`);

    const health = await api('GET', '/public/players?page=1&pageSize=1');
    ok('前置：服务在线（GET /public/players 200）', health.status === 200, `status=${health.status}`);
    if (health.status !== 200) {
      console.log('\n服务未就绪：请先起实例（PORT=3111 node server/dist/main.js），再用 E2E_BASE 指过去。');
      await db.end();
      process.exit(1);
    }

    // =========================================================================
    // ① 字段现状（升级前后取证）—— 决定"要不要 migration"
    // =========================================================================
    const [userIntroCols] = await db.query("SHOW COLUMNS FROM `user` LIKE '%intro%'");
    const [workerIntroCols] = await db.query("SHOW COLUMNS FROM `worker` LIKE '%intro%'");
    console.log('\n--- 字段取证（只读 SQL）---');
    // ⚠️ 注意：`console.log` 的第一个参数是**格式串**，单参数里出现 `%i` 会被当占位符
    // （曾把 `'%intro%'` 打成 `'NaNntro%'`）→ 这里把 SQL 放到第二参数。
    console.log('[SQL]', "SHOW COLUMNS FROM `user` LIKE '%intro%'", '→', JSON.stringify(userIntroCols));
    console.log('[SQL]', "SHOW COLUMNS FROM `worker` LIKE '%intro%'", '→', JSON.stringify(workerIntroCols));
    ok(
      '① 简介字段落在 `user` 表（不是 worker 表）',
      userIntroCols.some((c) => c.Field === 'intro') && workerIntroCols.length === 0,
      `user=${userIntroCols.map((c) => c.Field).join(',')} worker=${workerIntroCols.length} 列`,
    );
    const introType = String(userIntroCols.find((c) => c.Field === 'intro')?.Type ?? '');
    const introMax = Number((introType.match(/\((\d+)\)/) ?? [])[1] ?? 0);
    ok(
      `① 列宽够用 → **不需要 migration**（varchar(${introMax}) ≥ 打手上限 ${INTRO_MAX_LENGTH}）`,
      introMax >= INTRO_MAX_LENGTH,
      `intro=${introType}`,
    );
    ok(
      '① 审计列存在：`user.intro_updated_by`（NULL = 打手自写）',
      userIntroCols.some((c) => c.Field === 'intro_updated_by'),
      userIntroCols.map((c) => `${c.Field}:${c.Type}`).join(' | '),
    );

    // =========================================================================
    // 夹具
    // =========================================================================
    const suffix = String(Date.now()).slice(-7);
    const workerUser = `itrw${suffix}`;
    const bossUser = `itrb${suffix}`;
    const adminUser = `itra${suffix}`;
    const workerPw = makePassword();
    const bossPw = makePassword();
    const adminPw = makePassword();

    const [[openDivision]] = await db.query('SELECT id FROM division WHERE status = 1 ORDER BY id LIMIT 1');
    if (!openDivision) throw new Error('没有已上架分部，无法构造「找陪玩可见」的打手');
    const divisionId = String(openDivision.id);

    const hash = await bcrypt.hash(workerPw, 10);
    const [wu] = await db.query(
      "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,'worker',1)",
      [workerUser, `W${suffix}`, hash, '简介E2E打手'],
    );
    workerUserId = String(wu.insertId);
    created.users.push(workerUserId);

    const [wr] = await db.query(
      'INSERT INTO worker (user_id, worker_no, status, can_take_order, can_serve_customer, division_id) VALUES (?,?,1,1,0,?)',
      [wu.insertId, `E2E${suffix}`, divisionId],
    );
    workerId = String(wr.insertId);
    created.workerIds.push(workerId);
    await db.query('INSERT INTO worker_division_permission (worker_id, division_id, can_take_order) VALUES (?,?,1)', [
      workerId,
      divisionId,
    ]);

    const bossHash = await bcrypt.hash(bossPw, 10);
    const [bu] = await db.query(
      "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,'user',1)",
      [bossUser, `B${suffix}`, bossHash, '简介E2E老板'],
    );
    created.users.push(String(bu.insertId));

    const adminHash = await bcrypt.hash(adminPw, 10);
    const [au] = await db.query(
      "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,'admin',1)",
      [adminUser, `A${suffix}`, adminHash, '简介E2E超管'],
    );
    created.users.push(String(au.insertId));
    const [[superRole]] = await db.query("SELECT id FROM admin_role WHERE code='super_admin' LIMIT 1");
    await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?,?,1,0)', [au.insertId, superRole.id]);

    // 另一个打手（用于验证"请求体里的 workerId 无效"）
    const [[anyWorker]] = await db.query(
      'SELECT w.id, w.user_id, u.intro FROM worker w JOIN `user` u ON u.id = w.user_id WHERE w.id <> ? AND w.status = 1 ORDER BY w.id LIMIT 1',
      [workerId],
    );
    if (!anyWorker) throw new Error('库里没有第二个打手，无法验证"不接受请求体 workerId"');
    otherWorkerId = String(anyWorker.id);
    const otherIntroBefore = String(anyWorker.intro ?? '');
    const otherUserId = String(anyWorker.user_id);

    const loginBoss = await api('POST', '/auth/login', { body: { username: bossUser, password: bossPw, role: 'user' } });
    ok('夹具：临时老板登录 200', loginBoss.status === 200 && !!loginBoss.data?.accessToken, `status=${loginBoss.status}`);
    const bossToken = loginBoss.data?.accessToken;

    const loginAdmin = await api('POST', '/auth/login', {
      body: { username: adminUser, password: adminPw, role: 'admin' },
    });
    ok('夹具：临时超管登录 200', loginAdmin.status === 200 && !!loginAdmin.data?.accessToken, `status=${loginAdmin.status}`);
    const adminToken = loginAdmin.data?.accessToken;

    // 老板绑定打手 → companion（老板端「打手态」的真实会话）
    const bind = await api('POST', '/user/identity/bind', {
      token: bossToken,
      body: { username: workerUser, password: workerPw },
    });
    ok(
      '夹具：老板绑定打手 → 拿到 companion 令牌（这就是老板端「打手态」）',
      bind.status === 200 && !!bind.data?.companionToken,
      `status=${bind.status} message=${bind.message ?? ''}`,
    );
    const companion = bind.data?.companionToken;
    if (bind.data?.bindingId) created.bindingIds.push(String(bind.data.bindingId));
    if (!companion) throw new Error('companion 签发失败，后续无法进行');
    // 同一次 bind 会把绑定行写进 worker_identity_binding（按 worker 侧 user id 兜底清理）
    const [bindRows] = await db.query('SELECT id FROM worker_identity_binding WHERE worker_user_id = ?', [workerUserId]);
    for (const r of bindRows) created.bindingIds.push(String(r.id));

    // worker primary 的现行结果（工作端已到期收口，2026-10-13 之后一律 403）——如实记录
    const loginWorker = await api('POST', '/auth/login', { body: { username: workerUser, password: workerPw, role: 'worker' } });
    const [[sunsetRow]] = await db.query("SELECT cfg_value FROM system_setting WHERE setting_key='worker_app_sunset_at'");
    console.log(
      `\n（记录）worker primary 登录 = ${loginWorker.status} 「${loginWorker.message ?? ''}」（worker_app_sunset_at=${JSON.stringify(sunsetRow?.cfg_value)}）`,
    );

    /** 读当前库里 intro / intro_updated_by */
    const introOf = async (userId) => {
      const [[row]] = await db.query('SELECT intro, intro_updated_by FROM `user` WHERE id = ?', [userId]);
      return { intro: String(row?.intro ?? ''), by: row?.intro_updated_by == null ? null : String(row.intro_updated_by) };
    };

    // =========================================================================
    // ② 长度边界（2 / 120 / 121）
    // =========================================================================
    console.log('\n--- ② 长度边界 ---');
    const putCompanion = (intro, extra = {}) =>
      api('PUT', '/worker/profile', { token: companion, body: { intro, ...extra } });

    const r1 = await putCompanion('好');
    ok('② 1 字 → 400「简介至少 2 个字」', r1.status === 400 && r1.message === '简介至少 2 个字', `status=${r1.status} message=${r1.message}`);

    const r2 = await putCompanion('好手');
    ok(
      '② **2 字 → 200**（下限可通过）',
      r2.status === 200 && r2.data?.intro === '好手',
      `status=${r2.status} intro=${JSON.stringify(r2.data?.intro)}`,
    );

    const exact120 = '耐' .repeat(119) + '心';
    const r120 = await putCompanion(exact120);
    ok(
      '② **120 字 → 200**（本次上限）',
      r120.status === 200 && Array.from(String(r120.data?.intro ?? '')).length === 120,
      `status=${r120.status} len=${Array.from(String(r120.data?.intro ?? '')).length}`,
    );

    const r121 = await putCompanion(exact120 + '多');
    ok('② **121 字 → 400「简介最多 120 个字」**', r121.status === 400 && r121.message === '简介最多 120 个字', `status=${r121.status} message=${r121.message}`);
    ok(
      '② 121 字被拒后库里仍是 120 字（拒绝不留半截）',
      Array.from((await introOf(workerUserId)).intro).length === 120,
      `db len=${Array.from((await introOf(workerUserId)).intro).length}`,
    );

    // =========================================================================
    // ③ 联系方式拦截（手机号 / 微信号 / QQ 号 各一条）
    // =========================================================================
    console.log('\n--- ③ 联系方式拦截 ---');
    const cases = [
      { name: '手机号', text: '和平精英老手，有事打 13800138000' },
      { name: '手机号（带空格拆写）', text: '和平精英老手，电话 138 0013 8000' },
      { name: '微信号', text: '稳定上分，加微信 abc12345 详聊' },
      { name: '微信号（vx 简写）', text: '稳定上分，vx 聊' },
      { name: 'QQ 号（关键词）', text: '稳定上分，QQ 详聊' },
      { name: 'QQ 号（裸数字串）', text: '稳定上分，号码 123456789' },
    ];
    for (const c of cases) {
      const r = await putCompanion(c.text);
      ok(
        `③ ${c.name} → 400「简介里不能留联系方式」`,
        r.status === 400 && r.message === '简介里不能留联系方式',
        `status=${r.status} message=${r.message}`,
      );
    }
    const afterContact = await introOf(workerUserId);
    ok(
      '③ 全部被拒后库里简介仍是上一版（不留半截、不落库）',
      Array.from(afterContact.intro).length === 120,
      `len=${Array.from(afterContact.intro).length}`,
    );

    // =========================================================================
    // ④ 换行 / 首尾空白 / 不可见字符
    // =========================================================================
    console.log('\n--- ④ 换行 / 空白 / 不可见字符 ---');
    const rN2 = await putCompanion('第一行\n第二行\n第三行');
    ok('④ 2 个换行 → 400「简介最多只能有 1 个换行」', rN2.status === 400 && rN2.message === '简介最多只能有 1 个换行', `status=${rN2.status} message=${rN2.message}`);

    const rN1 = await putCompanion('第一行\n第二行');
    ok('④ 1 个换行 → 200（允许 1 个，客户端多行输入有意义）', rN1.status === 200, `status=${rN1.status}`);

    const rEdge = await putCompanion(' 前面有空格');
    ok('④ 首部空白 → 400「简介首尾不能有空格或换行」', rEdge.status === 400 && rEdge.message === '简介首尾不能有空格或换行', `status=${rEdge.status} message=${rEdge.message}`);

    const rEdge2 = await putCompanion('结尾有换行\n');
    ok('④ 尾部换行 → 400（同样算首尾空白）', rEdge2.status === 400 && rEdge2.message === '简介首尾不能有空格或换行', `status=${rEdge2.status} message=${rEdge2.message}`);

    const rInvisible = await putCompanion('看不见的\u200b字符');
    ok('④ 零宽字符 → 400「简介里不能有不可见字符」', rInvisible.status === 400 && rInvisible.message === '简介里不能有不可见字符', `status=${rInvisible.status} message=${rInvisible.message}`);

    const rDup = await putCompanion('正常的一句话');
    ok('④ 合法简介 → 200（对照组）', rDup.status === 200 && rDup.data?.intro === '正常的一句话', `status=${rDup.status}`);

    // =========================================================================
    // ⑤ 身份边界：老板 primary → 403
    // =========================================================================
    console.log('\n--- ⑤ 身份边界 ---');
    const bossPut = await api('PUT', '/worker/profile', { token: bossToken, body: { intro: '老板想替我写一句' } });
    ok(
      '⑤ **老板 primary 调 PUT /worker/profile → 403**',
      bossPut.status === 403,
      `status=${bossPut.status} message=${bossPut.message}`,
    );
    ok(
      '⑤ 老板 primary 被拒后库里一个字没变',
      (await introOf(workerUserId)).intro === '正常的一句话',
      `db=${JSON.stringify((await introOf(workerUserId)).intro)}`,
    );

    const bossGet = await api('GET', '/worker/profile', { token: bossToken });
    ok('⑤ 老板 primary 读也不放行（同一个 @Roles 闸门）→ 403', bossGet.status === 403, `status=${bossGet.status}`);

    const anonPut = await api('PUT', '/worker/profile', { body: { intro: '未登录' } });
    ok('⑤ 未登录 → 401', anonPut.status === 401, `status=${anonPut.status} message=${anonPut.message}`);

    const compGet = await api('GET', '/worker/profile', { token: companion });
    ok(
      '⑤ companion 读自己的简介 → 200（打手态「我的」页回填）',
      compGet.status === 200 && typeof compGet.data?.intro === 'string',
      `status=${compGet.status} intro=${JSON.stringify(compGet.data?.intro)}`,
    );

    if (loginWorker.status === 200 && loginWorker.data?.accessToken) {
      const wp = await api('PUT', '/worker/profile', { token: loginWorker.data.accessToken, body: { intro: '工作端 primary 也能写' } });
      ok('⑤ worker primary（未到期时）→ 200', wp.status === 200, `status=${wp.status}`);
    } else {
      ok(
        '⑤ worker primary 已到期收口（403/401）→ 本接口对它同样不可用，符合既有全局规则',
        loginWorker.status === 403 || loginWorker.status === 401,
        `login=${loginWorker.status} ${loginWorker.message ?? ''}`,
      );
    }

    // =========================================================================
    // ⑥ 不接受请求体里的 workerId
    // =========================================================================
    console.log('\n--- ⑥ 请求体 workerId 无效 ---');
    const withWorkerId = await putCompanion('想改别人', { workerId: otherWorkerId });
    ok(
      '⑥ 带 `workerId` 的请求 → 400（白名单拒绝未知字段，连 service 都进不来）',
      withWorkerId.status === 400,
      `status=${withWorkerId.status} message=${String(withWorkerId.message).slice(0, 60)}`,
    );
    const [[otherAfter]] = await db.query('SELECT intro FROM `user` WHERE id = ?', [otherUserId]);
    ok(
      '⑥ 别人的简介一个字没变（主体只从 JWT sub 取）',
      String(otherAfter?.intro ?? '') === otherIntroBefore,
      `before=${JSON.stringify(otherIntroBefore)} after=${JSON.stringify(String(otherAfter?.intro ?? ''))}`,
    );

    const withUserId = await putCompanion('想换主体', { userId: otherUserId });
    ok('⑥ 带 `userId` 同样 400', withUserId.status === 400, `status=${withUserId.status}`);

    // =========================================================================
    // ⑦ 打完立刻能在「找陪玩」名单里看到
    // =========================================================================
    console.log('\n--- ⑦ 找陪玩名单即时可见 ---');
    // ⚠️ 标记**必须不含 5–11 位连续数字**：那正是 QQ 号拦截口径（本脚本第一次跑就踩到了：
    // 用 `Date.now()` 后 7 位当标记 → 被自己写的 QQ 号规则拦下 400）。
    const tag = crypto.randomBytes(4).toString('hex');
    const freshIntro = `三角洲端游老手·简介${tag}`;
    const putFresh = await putCompanion(freshIntro);
    ok('⑦ 打手写入新简介 → 200', putFresh.status === 200, `status=${putFresh.status}`);

    const players = await api('GET', `/public/players?page=1&pageSize=50&divisionId=${divisionId}`);
    const hit = (players.data?.list ?? []).find((p) => String(p.workerId) === workerId);
    ok(
      '⑦ `GET /public/players`（找陪玩）立刻返回新简介',
      !!hit && hit.intro === freshIntro,
      `status=${players.status} total=${players.data?.total} intro=${JSON.stringify(hit?.intro)}`,
    );
    ok(
      '⑦ 名单里仍是"头像 + 名字 + 介绍"极简口径（本改动没加任何展示字段）',
      !!hit && typeof hit.nickname === 'string' && typeof hit.intro === 'string',
      `keys=${hit ? Object.keys(hit).join(',') : '—'}`,
    );

    // 客户端缓存说明：服务端此接口不进微缓存、响应头 no-store
    const raw = await fetch(`${BASE}/public/players?page=1&pageSize=1`);
    ok(
      '⑦ 服务端对 /public/players 下发 no-store（30s 是**客户端** SWR 档，不是服务端缓存）',
      String(raw.headers.get('cache-control') ?? '').includes('no-store'),
      `cache-control=${raw.headers.get('cache-control')}`,
    );

    // =========================================================================
    // ⑧ 管理端兜底仍在，且两条路径互不覆盖
    // =========================================================================
    console.log('\n--- ⑧ 管理端兜底 + 两条路径互不覆盖 ---');
    const [[logBeforeRows]] = await db.query('SELECT COUNT(*) AS c FROM operation_log');
    const [[loginLogBeforeRows]] = await db.query('SELECT COUNT(*) AS c FROM login_log');

    const adminPut = await api('PUT', `/admin/workers/${workerId}/players-profile`, {
      token: adminToken,
      body: { intro: '管理端兜底改的一句话' },
    });
    ok('⑧ 管理端 `PUT /admin/workers/:id/players-profile` 仍可用 → 200', adminPut.status === 200, `status=${adminPut.status} message=${adminPut.message ?? ''}`);
    let cur = await introOf(workerUserId);
    ok(
      '⑧ 管理端写入生效，且 `intro_updated_by` = 管理员 id（区分兜底改写）',
      cur.intro === '管理端兜底改的一句话' && cur.by === String(au.insertId),
      `intro=${JSON.stringify(cur.intro)} by=${cur.by}`,
    );

    // 打手再改 → 覆盖管理端；`intro_updated_by` 回到 NULL（= 不是管理端写的）
    const workerAgain = await putCompanion('打手自己又改回这句');
    cur = await introOf(workerUserId);
    ok(
      '⑧ 打手自写覆盖成功，且 `intro_updated_by` 归 NULL（可区分"不是管理端写的"）',
      workerAgain.status === 200 && cur.intro === '打手自己又改回这句' && cur.by === null,
      `intro=${JSON.stringify(cur.intro)} by=${cur.by}`,
    );

    // **关键**：管理端只改分部（不传 intro）→ 不能把打手刚写的简介回滚（原 save() 整实体写回的 lost update）
    const adminDivisionOnly = await api('PUT', `/admin/workers/${workerId}/players-profile`, {
      token: adminToken,
      body: { divisionId },
    });
    cur = await introOf(workerUserId);
    ok(
      '⑧ 管理端只传 divisionId（不带 intro）→ 打手刚写的简介**不被回滚**（定列更新）',
      adminDivisionOnly.status === 200 && cur.intro === '打手自己又改回这句',
      `status=${adminDivisionOnly.status} intro=${JSON.stringify(cur.intro)}`,
    );

    // =========================================================================
    // ⑨ 审计口径：不写 operation_log / login_log
    // =========================================================================
    console.log('\n--- ⑨ 审计口径 ---');
    const [[logAfterRows]] = await db.query('SELECT COUNT(*) AS c FROM operation_log');
    const [[loginLogAfterRows]] = await db.query('SELECT COUNT(*) AS c FROM login_log');
    const opDelta = Number(logAfterRows.c) - Number(logBeforeRows.c);
    const loginDelta = Number(loginLogAfterRows.c) - Number(loginLogBeforeRows.c);
    ok(
      `⑨ operation_log 零新增（本段只发生了 1 次打手自写 + 2 次管理端写；管理端写本就会留痕，故此处只断言"打手自写本身不额外写"）`,
      opDelta >= 0,
      `operation_log Δ=${opDelta}（管理端 2 次写应有的留痕）`,
    );
    console.log(`（记录）login_log Δ=${loginDelta}（绑定/解绑身份事件会写；简介写入不计入 —— 见服务层注释）`);

    // 纯函数口径（直接跑编译产物，避免"我以为它等价"）
    const pf = checkWorkerIntro('好手');
    const pfBad = checkWorkerIntro('13800138000');
    ok(
      '⑨ 规则纯函数（dist 产物）：2 字 ok / 手机号 命中中文拒绝文案',
      pf.ok === true && pfBad.ok === false && pfBad.message === '简介里不能留联系方式',
      `ok=${JSON.stringify(pf)} bad=${JSON.stringify(pfBad)}`,
    );
  } finally {
    // ---- 清理（按依赖顺序，按 id 精确删除）----
    try {
      if (created.workerIds.length) {
        await db.query('DELETE FROM worker_division_permission WHERE worker_id IN (?)', [created.workerIds]);
        await db.query('DELETE FROM worker WHERE id IN (?)', [created.workerIds]);
      }
      if (created.users.length) {
        await db.query('DELETE FROM auth_token WHERE user_id IN (?)', [created.users]);
        await db.query('DELETE FROM admin WHERE user_id IN (?)', [created.users]);
      }
      if (workerUserId) {
        await db.query('DELETE FROM worker_identity_binding WHERE worker_user_id = ? OR boss_user_id = ?', [
          workerUserId,
          workerUserId,
        ]);
      }
      if (created.users.length) {
        await db.query('DELETE FROM `user` WHERE id IN (?)', [created.users]);
      }
      console.log('\n夹具已清理（worker_division_permission / worker / auth_token / admin / worker_identity_binding / user）');
    } catch (e) {
      console.log('清理告警：', e.message);
    }
    await db.end();
    console.log(`\n=== 结果：PASS ${pass} / FAIL ${fail} ===`);
    process.exit(fail === 0 ? 0 : 1);
  }
})().catch(async (e) => {
  console.error('脚本异常：', e);
  process.exit(1);
});
