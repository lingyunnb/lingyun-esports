/**
 * 打手展示值（接单次数 / 好评率）· 端到端自证（2026-10-16，负责人：「数字可调、评价必须真实」）
 *
 * 运行：
 *   node scripts/tools/worker-display-stats-e2e.js
 *   E2E_BASE=http://127.0.0.1:3111/api/v1 node scripts/tools/worker-display-stats-e2e.js   # 指定实例
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 覆盖的语义（期望值**一律从 DB 推导**，不写死数字）
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① 「无评价 = null」红线：没有任何 `hidden=0` 评价时，真实/生效 `satisfiedRate` 必须是 `null`
 *     （不是 0、更不是 100）；
 *  ② 真实值口径：只算 `hidden=0` 的评价（隐藏行不参与），好评率 = 百分数字符串 1 位小数；
 *  ③ 展示值可调：`PUT /admin/workers/:id/display-stats` 后，**公开接口**（打手详情 / 找陪玩列表 /
 *     首屏聚合的 players 子块）三处**同时**变成展示值；
 *  ④ 恢复跟随真实：`null` 后三处一起回落真实值（且库里两列确实是 NULL）；
 *  ⑤ `reviewCount` 永远是真实值（本接口连字段都不接受 —— 传了会被白名单 400）；
 *  ⑥ 写展示值**不碰真实战绩**（`worker_stats.completed_orders` 前后逐字不变）；
 *  ⑦ 权限：非超管 403；未登录 401；受限会话（companion / recharge）白名单**默认拒绝**；
 *  ⑧ `operation_log` 留痕：`module=worker`、`action=worker:adjust-stats`、`request_body` 含变更前后值；
 *  ⑨ 边界：越界 400、打手不存在 404、未知字段 400。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 测试夹具与清理（**自建自删，绝不动负责人真实数据**）
 * ─────────────────────────────────────────────────────────────────────────────
 *  - 本脚本会为「被选中的打手」临时插入 4 条 `order_review`（3 条可见：好评/好评/差评 + 1 条已隐藏），
 *    用来验证 ②（隐藏行不计入）与 ①⑥（无评价/有评价两种形态）；`finally` 里按 id 精确删除；
 *  - 临时管理员两个（超管 1 + 非超管 1）用于 ⑦，`finally` 里删账号与其 `auth_token` 会话；
 *  - 选中打手优先用"库里已有 `worker_stats` 行且当前无任何评价"的那个（避免误改他人已评价数据）；
 *    该打手的展示值在测试结束时**放回 NULL**（跟随真实）。
 *
 * ⚠️ 本脚本只读业务数据（除上面三类自建夹具），不碰订单/钱包/结算任何一行。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '..', '..');
const ENV_FILE = path.join(ROOT, 'server', '.env');
const mysql = require(path.join(ROOT, 'server', 'node_modules', 'mysql2', 'promise'));
const bcrypt = require(path.join(ROOT, 'server', 'node_modules', 'bcryptjs'));

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
  for (const raw of fs.readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const i = line.indexOf('=');
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

/** HTTP：返回 `{status, data, message, ms, raw}`（已解统一信封 `{code,message,data}`） */
async function api(method, p, { token, body } = {}) {
  const t0 = Date.now();
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  let json = null;
  try {
    json = await r.json();
  } catch {
    /* 非 JSON（例如 401 空体） */
  }
  return { status: r.status, data: json?.data, message: json?.message, ms: Date.now() - t0, raw: json };
}

/** 临时账号：随机强口令（只在本脚本生命周期内存在） */
function makePassword() {
  const pick = (chars, n) => Array.from({ length: n }, () => chars[crypto.randomInt(chars.length)]).join('');
  return `Adj${pick('!#%+=?', 1)}${pick('ABCDEFGHJKLMNPQRSTUVWXYZ', 2)}${pick('abcdefghijkmnopqrstuvwxyz', 5)}${pick('23456789', 4)}`;
}

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

  const created = { users: [], reviewIds: [] };
  let workerId = null;

  try {
    console.log('=== 打手展示值 E2E（数字可调、评价必须真实）===');
    console.log(`API = ${BASE}`);

    // ---------------- 0. 前置 ----------------
    const health = await api('GET', '/public/home');
    ok('前置：服务在线（GET /public/home 200）', health.status === 200, `status=${health.status} ${health.ms}ms`);
    if (health.status !== 200) {
      console.log('\n服务未就绪 —— 请先在本地起一个新构建实例（例如 PORT=3111 node dist/main.js）。');
      await db.end();
      process.exit(1);
    }

    // 目标打手：有 worker_stats 行、当前**无任何 hidden=0 评价**、且公开可见（worker.status=1 AND user.status=1）
    const [cand] = await db.query(
      `SELECT w.id AS workerId, u.nickname, s.completed_orders AS completedOrders
         FROM worker w
         JOIN user u ON u.id = w.user_id
         JOIN worker_stats s ON s.worker_id = w.id
        WHERE w.status = 1 AND u.status = 1
          AND NOT EXISTS (SELECT 1 FROM order_review r WHERE r.worker_id = w.id AND r.hidden = 0)
        ORDER BY s.completed_orders DESC, w.id ASC
        LIMIT 1`,
    );
    if (!cand.length) throw new Error('找不到"有 worker_stats 行且无评价"的公开打手，无法验证');
    workerId = String(cand[0].workerId);
    const realCompleted = Number(cand[0].completedOrders);
    console.log(`目标打手 workerId=${workerId}（${cand[0].nickname}）真实 completed_orders=${realCompleted}，当前评价数=0`);

    const [ceiling] = await db.query('SELECT COUNT(*) AS c FROM order_review');
    console.log(`（DB 现有 order_review 行数 = ${ceiling[0].c}；脚本自建的 4 行稍后按 id 精确删除）`);

    // ---------------- 1. 「无评价 = null」红线 ----------------
    const pubBefore = await api('GET', `/public/workers/${workerId}`);
    ok(
      '① 无评价时公开 satisfiedRate = null（不是 0、不是 100）',
      pubBefore.status === 200 && pubBefore.data?.satisfiedRate === null && pubBefore.data?.reviewCount === 0,
      `status=${pubBefore.status} reviewCount=${pubBefore.data?.reviewCount} satisfiedRate=${JSON.stringify(pubBefore.data?.satisfiedRate)}`,
    );

    // ---------------- 2. 临时超管 / 临时非超管 ----------------
    const superPw = makePassword();
    const opsPw = makePassword();
    const suffix = String(Date.now()).slice(-7);
    const superUser = `opsadj${suffix}`;
    const opsUser = `ops403${suffix}`;

    const [[superRole]] = await db.query("SELECT id FROM admin_role WHERE code='super_admin' LIMIT 1");
    const [[opsRole]] = await db.query("SELECT id FROM admin_role WHERE code='operator' LIMIT 1");
    if (!superRole || !opsRole) throw new Error('admin_role 缺少 super_admin / operator，无法建临时账号');
    // `operator` 角色不得拥有 worker:adjust（否则 403 用例失效）——这是运行时校验，不是假设
    const [[opsHasAdj]] = await db.query(
      `SELECT COUNT(*) AS c FROM admin_role_permission rp JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = ? AND p.code = 'worker:adjust'`,
      [opsRole.id],
    );
    ok('前置：operator 角色**没有** worker:adjust（403 用例成立的前提）', Number(opsHasAdj.c) === 0, `holds=${opsHasAdj.c}`);

    const mkAdmin = async (username, pw, roleId) => {
      const hash = await bcrypt.hash(pw, 10);
      const [u] = await db.query(
        "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,'admin',1)",
        [username, `adj${Date.now().toString().slice(-9)}`, hash, '展示值 E2E 临时账号'],
      );
      await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?,?,1,0)', [u.insertId, roleId]);
      created.users.push(u.insertId);
      return String(u.insertId);
    };
    await mkAdmin(superUser, superPw, superRole.id);
    await mkAdmin(opsUser, opsPw, opsRole.id);

    const loginSuper = await api('POST', '/auth/login', { body: { username: superUser, password: superPw, role: 'admin' } });
    const loginOps = await api('POST', '/auth/login', { body: { username: opsUser, password: opsPw, role: 'admin' } });
    ok('前置：临时超管登录成功', loginSuper.status === 200 && !!loginSuper.data?.accessToken, `status=${loginSuper.status}`);
    ok('前置：临时非超管（operator）登录成功', loginOps.status === 200 && !!loginOps.data?.accessToken, `status=${loginOps.status}`);
    const superToken = loginSuper.data?.accessToken;
    const opsToken = loginOps.data?.accessToken;
    if (!superToken) throw new Error('临时超管登录失败，后续无法进行');

    // ---------------- 3. 真实值口径（插入含隐藏的夹具评价） ----------------
    const [[anyUser]] = await db.query("SELECT id FROM `user` WHERE role='user' ORDER BY id LIMIT 1");
    const bossId = anyUser?.id ?? 1;
    const fixtures = [
      { satisfied: 1, hidden: 0 },
      { satisfied: 1, hidden: 0 },
      { satisfied: 0, hidden: 0 },
      { satisfied: 1, hidden: 1 }, // 隐藏行：**不得**计入真实值
    ];
    /**
     * 夹具用的 `order_id`：本表有 `UK_review_order(order_id)`，且**没有外键**指向 `order`。
     * 因此用一个"远离真实订单 id 段"的随机基址 + 序号构造唯一值：
     * 真实订单 id 如今是 4 位数（1126 左右），这里取 9 亿段，既不可能撞上真实数据，
     * 也保证同一次运行内 4 行互不重复（重复会撞唯一键 —— 首次跑就是这么失败的）。
     */
    const orderBase = 900000000 + crypto.randomInt(1, 90000000);
    for (let i = 0; i < fixtures.length; i += 1) {
      const f = fixtures[i];
      const [r] = await db.query(
        `INSERT INTO order_review (order_id, user_id, worker_id, satisfied, remark, hidden, hidden_reason, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NOW(3))`,
        [orderBase + i, bossId, workerId, f.satisfied, null, f.hidden, f.hidden ? 'E2E 夹具' : null],
      );
      created.reviewIds.push(r.insertId);
    }
    const [realRows] = await db.query(
      `SELECT COUNT(*) AS cnt, SUM(CASE WHEN satisfied=1 THEN 1 ELSE 0 END) AS ok
         FROM order_review WHERE worker_id = ? AND hidden = 0`,
      [workerId],
    );
    const expCount = Number(realRows[0].cnt);
    const expRate = ((Number(realRows[0].ok) / expCount) * 100).toFixed(1);
    console.log(`夹具就绪：可见 ${expCount} 条（其中好评 ${realRows[0].ok}）→ DB 推导真实好评率 = "${expRate}"`);

    const statsReal = await api('GET', `/admin/workers/${workerId}/stats`, { token: superToken });
    ok(
      '② 真实值只算 hidden=0（隐藏行不计入）',
      statsReal.status === 200 &&
        statsReal.data?.real?.reviewCount === expCount &&
        statsReal.data?.real?.satisfiedRate === expRate,
      `real=${JSON.stringify(statsReal.data?.real)} 期望 reviewCount=${expCount} satisfiedRate="${expRate}"`,
    );
    ok(
      '② 真实值 completedOrders 与 worker_stats 同源',
      Number(statsReal.data?.real?.completedOrders) === Number(realCompleted),
      `real.completedOrders=${statsReal.data?.real?.completedOrders} vs DB ${realCompleted}`,
    );
    const pubReal = await api('GET', `/public/workers/${workerId}`);
    ok(
      '② 公开详情与真实值一致（口径唯一）',
      pubReal.data?.satisfiedRate === expRate && pubReal.data?.reviewCount === expCount,
      `public satisfiedRate="${pubReal.data?.satisfiedRate}" reviewCount=${pubReal.data?.reviewCount}`,
    );

    // 纯函数口径（真实值与展示值**同一个出口**）——直接跑编译产物，避免"我以为它等价"
    const review = require(path.join(ROOT, 'server', 'dist', 'modules', 'review', 'review.service'));
    ok(
      '② 真实值文案函数：satisfiedRateText(3,2) = "66.7"、无评价 = null',
      review.satisfiedRateText(3, 2) === '66.7' && review.satisfiedRateText(0, 0) === null,
      `(3,2)=${review.satisfiedRateText(3, 2)} (0,0)=${JSON.stringify(review.satisfiedRateText(0, 0))}`,
    );
    ok(
      '② 展示值文案函数（同一出口）：98.2 → "98.2"、100 → "100.0"',
      review.satisfiedRatePercentText(98.2) === '98.2' && review.satisfiedRatePercentText(100) === '100.0',
      `98.2→${review.satisfiedRatePercentText(98.2)} 100→${review.satisfiedRatePercentText(100)}`,
    );

    // ---------------- 4. 设置展示值 ----------------
    const putSet = await api('PUT', `/admin/workers/${workerId}/display-stats`, {
      token: superToken,
      body: { completedOrders: 1234, satisfiedRate: 98.2 },
    });
    ok(
      '③ PUT 设展示值 200 且返回三联（真实/展示/生效）',
      putSet.status === 200 &&
        putSet.data?.display?.completedOrders === 1234 &&
        putSet.data?.display?.satisfiedRate === '98.2' &&
        putSet.data?.effective?.completedOrders === 1234 &&
        putSet.data?.effective?.satisfiedRate === '98.2',
      `status=${putSet.status} display=${JSON.stringify(putSet.data?.display)} effective=${JSON.stringify(putSet.data?.effective)}`,
    );
    ok(
      '③ 生效值的 reviewCount 仍是真实值（不提供覆盖）',
      Number(putSet.data?.effective?.reviewCount) === expCount,
      `effective.reviewCount=${putSet.data?.effective?.reviewCount} 期望 ${expCount}`,
    );

    const pubAfterSet = await api('GET', `/public/workers/${workerId}`);
    ok(
      '③ 公开打手详情返回展示值',
      pubAfterSet.data?.completedOrders === 1234 && pubAfterSet.data?.satisfiedRate === '98.2',
      `completedOrders=${pubAfterSet.data?.completedOrders} satisfiedRate="${pubAfterSet.data?.satisfiedRate}"`,
    );

    const players = await api('GET', '/public/players?page=1&pageSize=50');
    const rowP = (players.data?.list ?? []).find((x) => String(x.workerId) === workerId);
    ok(
      '③ 找陪玩列表返回同一展示值（列表/详情同步）',
      !!rowP && rowP.completedOrders === 1234 && rowP.satisfiedRate === '98.2',
      rowP ? `list completedOrders=${rowP.completedOrders} satisfiedRate="${rowP.satisfiedRate}"` : '该打手不在首页 50 条内',
    );

    const home = await api('GET', '/public/home');
    const rowH = (home.data?.players ?? []).find((x) => String(x.workerId) === workerId);
    ok(
      '③ 首屏聚合 players 子块同值（复用 PlayersService，无第二份实现）',
      !!rowH && rowH.completedOrders === 1234 && rowH.satisfiedRate === '98.2',
      rowH ? `home.players completedOrders=${rowH.completedOrders} satisfiedRate="${rowH.satisfiedRate}"` : '该打手不在首页 10 条内',
    );

    const [dbAfterSet] = await db.query(
      'SELECT completed_orders, display_completed_orders, display_satisfied_rate FROM worker_stats WHERE worker_id = ?',
      [workerId],
    );
    ok(
      '⑥ 展示值落库正确，且**真实战绩未被改写**',
      dbAfterSet.length === 1 &&
        Number(dbAfterSet[0].display_completed_orders) === 1234 &&
        String(dbAfterSet[0].display_satisfied_rate) === '98.2' &&
        Number(dbAfterSet[0].completed_orders) === Number(realCompleted),
      `display=${dbAfterSet[0]?.display_completed_orders}/${dbAfterSet[0]?.display_satisfied_rate} real completed_orders=${dbAfterSet[0]?.completed_orders}（DB 原值 ${realCompleted}）`,
    );

    // ---------------- 5. 恢复「跟随真实」 ----------------
    const putNull = await api('PUT', `/admin/workers/${workerId}/display-stats`, {
      token: superToken,
      body: { completedOrders: null, satisfiedRate: null },
    });
    ok(
      '④ PUT null = 恢复跟随真实（display 归 NULL，effective 回落真实值）',
      putNull.status === 200 &&
        putNull.data?.display?.completedOrders === null &&
        putNull.data?.display?.satisfiedRate === null &&
        putNull.data?.effective?.completedOrders === Number(realCompleted) &&
        putNull.data?.effective?.satisfiedRate === expRate,
      `display=${JSON.stringify(putNull.data?.display)} effective=${JSON.stringify(putNull.data?.effective)}`,
    );
    const pubAfterNull = await api('GET', `/public/workers/${workerId}`);
    ok(
      '④ 公开打手详情回落真实值',
      pubAfterNull.data?.completedOrders === Number(realCompleted) && pubAfterNull.data?.satisfiedRate === expRate,
      `completedOrders=${pubAfterNull.data?.completedOrders} satisfiedRate="${pubAfterNull.data?.satisfiedRate}"`,
    );
    const [dbAfterNull] = await db.query(
      'SELECT display_completed_orders, display_satisfied_rate FROM worker_stats WHERE worker_id = ?',
      [workerId],
    );
    ok(
      '④ 库里两列确实为 NULL',
      dbAfterNull[0]?.display_completed_orders === null && dbAfterNull[0]?.display_satisfied_rate === null,
      `display=${dbAfterNull[0]?.display_completed_orders}/${dbAfterNull[0]?.display_satisfied_rate}`,
    );

    // ---------------- 6. 权限 ----------------
    const opsPut = await api('PUT', `/admin/workers/${workerId}/display-stats`, {
      token: opsToken,
      body: { completedOrders: 1, satisfiedRate: 1 },
    });
    ok(
      '⑦ 非超管（operator，无 worker:adjust）调 PUT → 403 中文',
      opsPut.status === 403,
      `status=${opsPut.status} message=${opsPut.message ?? ''}`,
    );
    const opsGet = await api('GET', `/admin/workers/${workerId}/stats`, { token: opsToken });
    ok('⑦ 非超管调 GET stats → 403', opsGet.status === 403, `status=${opsGet.status} message=${opsGet.message ?? ''}`);
    const anonPut = await api('PUT', `/admin/workers/${workerId}/display-stats`, { body: { completedOrders: 1 } });
    ok('⑦ 未登录调 PUT → 401', anonPut.status === 401, `status=${anonPut.status} message=${anonPut.message ?? ''}`);

    // 受限会话白名单（纯函数，来自编译产物 —— 与守卫实际使用的是同一份实现）
    const guard = require(path.join(ROOT, 'server', 'dist', 'common', 'guards', 'jwt-auth.guard'));
    ok(
      '⑦ companion 受限会话对新管理端接口**默认拒绝**',
      guard.isCompanionAllowedRoute('PUT', '/api/v1/admin/workers/1/display-stats') === false &&
        guard.isCompanionAllowedRoute('GET', '/api/v1/admin/workers/1/stats') === false,
      'isCompanionAllowedRoute(admin/workers/*) = false',
    );
    ok(
      '⑦ recharge 受限会话对新管理端接口**默认拒绝**',
      guard.isRechargeAdminAllowedRoute('PUT', '/api/v1/admin/workers/1/display-stats') === false &&
        guard.isRechargeAdminAllowedRoute('GET', '/api/v1/admin/workers/1/stats') === false,
      'isRechargeAdminAllowedRoute(admin/workers/*) = false',
    );

    // ---------------- 7. 边界与白名单字段 ----------------
    const cases = [
      ['completedOrders = -1 → 400', { completedOrders: -1, satisfiedRate: null }],
      ['completedOrders = 1000000 → 400（上限 999999）', { completedOrders: 1000000, satisfiedRate: null }],
      ['completedOrders = 12.5 → 400（必须整数）', { completedOrders: 12.5, satisfiedRate: null }],
      ['satisfiedRate = 100.5 → 400（上限 100）', { completedOrders: null, satisfiedRate: 100.5 }],
      ['satisfiedRate = 98.25 → 400（最多 1 位小数）', { completedOrders: null, satisfiedRate: 98.25 }],
      ['satisfiedRate = "abc" → 400', { completedOrders: null, satisfiedRate: 'abc' }],
      ['未知字段 reviewCount → 400（白名单拒绝，评价条数不提供覆盖）', { completedOrders: 1, satisfiedRate: null, reviewCount: 999 }],
    ];
    for (const [name, body] of cases) {
      const r = await api('PUT', `/admin/workers/${workerId}/display-stats`, { token: superToken, body });
      ok(`⑨ ${name}`, r.status === 400, `status=${r.status} message=${r.message ?? ''}`);
    }
    const notFound = await api('GET', '/admin/workers/99999999/stats', { token: superToken });
    ok('⑨ 打手不存在 → 404', notFound.status === 404, `status=${notFound.status} message=${notFound.message ?? ''}`);

    // 宽松：数字字符串与空串（管理端表单常见形态）
    const strForm = await api('PUT', `/admin/workers/${workerId}/display-stats`, {
      token: superToken,
      body: { completedOrders: '4321', satisfiedRate: '97.5' },
    });
    ok(
      '⑨ 数字字符串 / 空串宽松处理（"4321"→4321；""→null）',
      strForm.status === 200 && strForm.data?.display?.completedOrders === 4321 && strForm.data?.display?.satisfiedRate === '97.5',
      `display=${JSON.stringify(strForm.data?.display)}`,
    );
    await api('PUT', `/admin/workers/${workerId}/display-stats`, { token: superToken, body: { completedOrders: '', satisfiedRate: '' } });
    const cleared = await api('GET', `/admin/workers/${workerId}/stats`, { token: superToken });
    ok(
      '⑨ 空串 = 清空（display 回到 null）',
      cleared.data?.display?.completedOrders === null && cleared.data?.display?.satisfiedRate === null,
      `display=${JSON.stringify(cleared.data?.display)}`,
    );

    // ---------------- 8. operation_log 留痕 ----------------
    const [logs] = await db.query(
      `SELECT id, admin_id, admin_name, module, action, method, path, request_body, result, ip, request_id, created_at
         FROM operation_log WHERE action = 'worker:adjust-stats' ORDER BY id DESC LIMIT 6`,
    );
    const parsed = logs.map((l) => {
      let a = null;
      try {
        a = JSON.parse(l.request_body);
      } catch {
        /* 非 JSON 也算失败（下面的断言会红） */
      }
      return { row: l, audit: a };
    });
    // 取"设展示值 1234 / 98.2"与"清空（两列都 NULL）"两条，覆盖 before→after 两种形态
    const setLog = parsed.find((p) => p.audit?.after?.completedOrders === 1234) ?? null;
    const clearLog = parsed.find((p) => p.audit?.before?.completedOrders === 1234 && p.audit?.after?.completedOrders === null) ?? null;
    const latest = parsed[0] ?? null;
    ok(
      '⑧ operation_log 有留痕（module=worker / action=worker:adjust-stats）',
      !!latest?.row && latest.row.module === 'worker' && latest.row.action === 'worker:adjust-stats',
      latest?.row
        ? `id=${latest.row.id} admin_id=${latest.row.admin_id} method=${latest.row.method} path=${latest.row.path} result=${latest.row.result} ip=${latest.row.ip} request_id=${latest.row.request_id} at=${latest.row.created_at?.toISOString?.() ?? latest.row.created_at}`
        : '无记录',
    );
    ok(
      '⑧ request_body 记了变更前后值（before/after），且不含手机号/token 等隐私字段',
      !!setLog?.audit &&
        setLog.audit.workerId === workerId &&
        'before' in setLog.audit &&
        'after' in setLog.audit &&
        JSON.stringify(setLog.audit).indexOf('phone') === -1 &&
        JSON.stringify(setLog.audit).indexOf('token') === -1,
      setLog ? `设值时 id=${setLog.row.id} audit=${JSON.stringify(setLog.audit)}` : '未找到"设展示值"那条留痕',
    );
    ok(
      '⑧ 清空动作也留痕（before=1234/98.2 → after=null/null）',
      !!clearLog,
      clearLog ? `清空 id=${clearLog.row.id} audit=${JSON.stringify(clearLog.audit)}` : '未找到"清空"那条留痕',
    );

    console.log(`\n=== 汇总：PASS ${pass} / FAIL ${fail} ===`);
  } finally {
    // ---------- 清理：夹具评价 + 展示值归 NULL + 临时账号与会话 ----------
    try {
      if (created.reviewIds.length) {
        await db.query(`DELETE FROM order_review WHERE id IN (${created.reviewIds.map(() => '?').join(',')})`, created.reviewIds);
        console.log(`清理：删除夹具评价 ${created.reviewIds.length} 行（id=${created.reviewIds.join(',')}）`);
      }
      if (workerId) {
        await db.query(
          'UPDATE worker_stats SET display_completed_orders = NULL, display_satisfied_rate = NULL WHERE worker_id = ?',
          [workerId],
        );
        console.log(`清理：worker ${workerId} 展示值归 NULL（跟随真实）`);
      }
      if (created.users.length) {
        await db.query(`DELETE FROM auth_token WHERE user_id IN (${created.users.map(() => '?').join(',')})`, created.users);
        await db.query(`DELETE FROM admin WHERE user_id IN (${created.users.map(() => '?').join(',')})`, created.users);
        await db.query(`DELETE FROM \`user\` WHERE id IN (${created.users.map(() => '?').join(',')})`, created.users);
        console.log(`清理：删除临时管理员账号 ${created.users.length} 个（user_id=${created.users.join(',')}）及其会话`);
      }
      const [left] = await db.query('SELECT COUNT(*) AS c FROM order_review');
      const [leftLog] = await db.query("SELECT COUNT(*) AS c FROM operation_log WHERE action='worker:adjust-stats'");
      console.log(`清理后：order_review ${left[0].c} 行；operation_log(worker:adjust-stats) ${leftLog[0].c} 行（留痕**刻意保留**：审计不可删）`);
    } catch (e) {
      console.error(`清理失败（需人工核对）：${e?.message || e}`);
    }
    await db.end();
  }

  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => {
  console.error(`\n脚本异常中止：${e?.stack || e}`);
  process.exit(1);
});
