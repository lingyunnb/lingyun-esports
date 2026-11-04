/**
 * 打手等级 + 五维评分 · 端到端自证（2026-10-17，负责人已审批制度落地验收）
 *
 * 运行（**必须先跑 migration，再起新构建**）：
 *   cd server && npm run migration:run && npm run build
 *   PORT=3111 node dist/main.js            # 另开一个窗口
 *   node scripts/tools/grade-rating-e2e.js  # 默认打 127.0.0.1:3100
 *   E2E_BASE=http://127.0.0.1:3111/api/v1 node scripts/tools/grade-rating-e2e.js
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 覆盖的语义（期望值**一律从 DB / 接口真实返回值推导**，不写死数字）
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① 一单一评：同一订单重复评 → 400 中文；DB 里该订单只有 1 行 `worker_rating`
 *  ② 五维越界：0 / 11 / 8.5 / 缺字段 → 400；1 与 10 合法（边界都要能收）
 *  ③ 归属：非本人订单 → 403；订单不存在 → 404；未完成订单 → 400；请求体夹带 `workerId` → 400（白名单）
 *  ④ **样本 < 10 不升级**：评到 9 条时等级仍是 LV1，且 `progress.blockers` 只剩"五维样本还差 1 条"
 *  ⑤ 达标升级：第 10 条（完成单 ≥10 / 好评率 100% / 五维均分 10）→ **LV2 立足**，
 *     `worker_grade.upgraded_by IS NULL`（系统自动），`operation_log` 有 `worker_grade:auto-upgrade` 留痕
 *  ⑥ **只升不降**：把 `worker_stats` 调到远低于门槛后再评一条 → 返回 `before=2 after=2 upgraded=false`，库里仍是 LV2
 *  ⑦ **LV5 不自动给**：把指标拉到宗师门槛（300 单 / ¥4000）再评一条 → **升到 LV4 就停**（`after=4`）
 *  ⑧ 超管人工设 LV5 → 200，库里 grade=5、`upgraded_by`=超管 user.id，
 *     `operation_log` 有 `worker_grade:manual-set`（记前后等级 + 操作人）；非超管 → 403；未登录 → 401
 *  ⑨ 查询三处都带 `grade/gradeLabel/gradeName`：
 *     `GET /public/players`（列表，**不带五维**）、`GET /public/workers/:id`（带五维 + 进度）、
 *     `GET /worker/grade`（打手态我的）
 *  ⑩ 受限会话白名单：companion 可调 `/worker/grade`、**不可**调 `/admin/workers/:id/grade`
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 夹具与清理（**自建自删，绝不动负责人真实数据**）
 * ─────────────────────────────────────────────────────────────────────────────
 *  - 临时打手账号 + `worker` 档案 + 分部接单权限 + `worker_stats`（初始 10 单 / ¥300）
 *  - 临时老板账号 2 个（1 个下单、1 个用来验"非本人"）+ 14 笔 completed 订单
 *  - 10 条 `order_review`（satisfied=1）作为**好评率**数据源（直接插库：好评率不是本功能被测对象）
 *  - 临时管理员 2 个（超管 1 + 非超管 1）
 *  - `finally` 里按 id 精确删除上面全部夹具；**`operation_log` 留痕刻意保留**（审计不可删）
 *
 * ⚠️ `evaluate()` 没有对外接口（审批表没要），验收里"再跑一次 evaluate"一律走**真实写入路径**触发：
 *    再提交一条五维评分 → 同一事务内 `evaluate()` 被调用 → 由接口回显的 `grade.before/after/upgraded` 断言。
 *    这比给测试开一个后门接口更能证明"线上真的会这样跑"。
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

/** HTTP：返回 `{status, data, message, ms}`（已解统一信封 `{code,message,data}`） */
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
  return { status: r.status, data: json?.data, message: json?.message, raw: json, ms: Date.now() - t0 };
}

function makePassword() {
  const pick = (chars, n) => Array.from({ length: n }, () => chars[crypto.randomInt(chars.length)]).join('');
  return `Grd${pick('!#%+=?', 1)}${pick('ABCDEFGHJKLMNPQRSTUVWXYZ', 2)}${pick('abcdefghijkmnopqrstuvwxyz', 5)}${pick('23456789', 4)}`;
}

/** 五维全 10 的评分体（升级用） */
const FULL_10 = { skill: 10, emotion: 10, stress: 10, voice: 10, shop: 10 };
const FULL_1 = { skill: 1, emotion: 1, stress: 1, voice: 1, shop: 1 };

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

  const created = {
    users: [], // 所有临时账号（老板/打手/管理员）
    adminRows: [], // 其中建了 admin 行的
    orderIds: [],
    reviewIds: [],
    workerId: null,
    bindingIds: [],
  };

  try {
    console.log('=== 打手等级 + 五维评分 E2E（负责人已审批制度）===');
    console.log(`API = ${BASE}`);

    // ---------------- 0. 前置 ----------------
    const health = await api('GET', '/public/home');
    ok('前置：服务在线（GET /public/home 200）', health.status === 200, `status=${health.status} ${health.ms}ms`);
    if (health.status !== 200) {
      console.log('\n服务未就绪 —— 先跑 migration 再起一个新构建（PORT=3111 node dist/main.js）。');
      await db.end();
      process.exit(1);
    }

    // ---------------- 1. 夹具：打手 + 老板 + 订单 + 好评率数据 ----------------
    const suffix = String(Date.now()).slice(-7);
    const workerUsername = `grdw${suffix}`;
    const bossUsername = `grdb${suffix}`;
    const boss2Username = `grdo${suffix}`;
    const superUsername = `grds${suffix}`;
    const opsUsername = `grdn${suffix}`;
    const pw = makePassword();

    const mkUser = async (username, uid, nickname, role) => {
      const hash = await bcrypt.hash(pw, 10);
      const [u] = await db.query(
        "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,?,1)",
        [username, uid, hash, nickname, role],
      );
      created.users.push(u.insertId);
      return String(u.insertId);
    };

    const workerUserId = await mkUser(workerUsername, `gw${suffix}`, '等级 E2E 临时打手', 'worker');
    const bossUserId = await mkUser(bossUsername, `gb${suffix}`, '等级 E2E 临时老板', 'user');
    const boss2UserId = await mkUser(boss2Username, `go${suffix}`, '等级 E2E 临时老板2', 'user');

    // 打手档案：在职 + 有接单权限 + 挂已上架分部 1（这样它会出现在 /public/players 里）
    const [[division]] = await db.query('SELECT id FROM division WHERE status = 1 ORDER BY id LIMIT 1');
    if (!division) throw new Error('库里没有已上架分部，无法验证 /public/players 的等级字段');
    const [workerRow] = await db.query(
      'INSERT INTO worker (user_id, worker_no, real_name, can_take_order, can_serve_customer, status, division_id) VALUES (?,?,?,1,0,1,?)',
      [workerUserId, `WG${suffix}`, '等级 E2E', division.id],
    );
    created.workerId = String(workerRow.insertId);
    const workerId = created.workerId;
    await db.query(
      'INSERT INTO worker_division_permission (worker_id, division_id, can_take_order) VALUES (?,?,1)',
      [workerId, division.id],
    );
    // worker_stats：初始 10 单 / ¥300（正好够 LV2 的完成单门槛，不够 LV3 的 40 单）
    await db.query(
      'INSERT INTO worker_stats (worker_id, total_orders, completed_orders, total_amount) VALUES (?,10,10,300.00)',
      [workerId],
    );

    // 订单：14 笔（1..12 用于评分，13 = 未完成，14 = 五维全 1 边界）
    const [[product]] = await db.query(
      'SELECT id, game_id, category_id, division_id, price FROM product ORDER BY id LIMIT 1',
    );
    const mkOrder = async (n, status) => {
      const [r] = await db.query(
        `INSERT INTO \`order\`
           (order_no, idempotency_key, user_id, product_id, game_id, division_id, category_id,
            quantity, unit_price, total_amount, status, worker_id, contact_phone, worker_mode)
         VALUES (?,?,?,?,?,?,?,1,?,?,?,?,'','random')`,
        [
          `E2EGR${suffix}${String(n).padStart(2, '0')}`,
          `e2e-grade-${suffix}-${n}`,
          bossUserId,
          product.id,
          product.game_id,
          product.division_id,
          product.category_id,
          product.price,
          product.price,
          status,
          workerId,
        ],
      );
      created.orderIds.push(r.insertId);
      return String(r.insertId);
    };
    const orderIds = [];
    for (let i = 1; i <= 12; i += 1) orderIds.push(await mkOrder(i, 'completed'));
    const pendingOrderId = await mkOrder(13, 'pending_take');
    const lowScoreOrderId = await mkOrder(14, 'completed');

    // 好评率数据源：order_review 10 条全好评（hidden=0）→ 100%（好评率不是本功能被测对象，直接插库）
    for (let i = 0; i < 10; i += 1) {
      const [r] = await db.query(
        'INSERT INTO order_review (order_id, user_id, worker_id, satisfied, remark, hidden, created_at) VALUES (?,?,?,1,NULL,0,NOW(3))',
        [orderIds[i], bossUserId, workerId],
      );
      created.reviewIds.push(r.insertId);
    }
    console.log(
      `夹具：worker=${workerId}（user=${workerUserId}） 老板=${bossUserId} 订单=${created.orderIds.length} 笔 好评=${created.reviewIds.length} 条`,
    );

    // 登录（老板 / 打手 companion）
    const loginBoss = await api('POST', '/auth/login', { body: { username: bossUsername, password: pw, role: 'user' } });
    const loginBoss2 = await api('POST', '/auth/login', {
      body: { username: boss2Username, password: pw, role: 'user' },
    });
    ok('前置：临时老板登录成功', loginBoss.status === 200 && !!loginBoss.data?.accessToken, `status=${loginBoss.status}`);
    ok('前置：临时老板2登录成功', loginBoss2.status === 200 && !!loginBoss2.data?.accessToken, `status=${loginBoss2.status}`);
    const bossToken = loginBoss.data?.accessToken;
    const boss2Token = loginBoss2.data?.accessToken;
    if (!bossToken || !boss2Token) throw new Error('老板登录失败，后续无法进行');

    // 打手态：老板绑定打手账号 → 拿 companion（worker primary 已被 sunset 收口，不能用来测）
    const bind = await api('POST', '/user/identity/bind', {
      token: bossToken,
      body: { username: workerUsername, password: pw },
    });
    ok(
      '前置：老板绑定打手账号成功并取得伴随会话（companion）',
      bind.status === 200 && !!bind.data?.companionToken,
      `status=${bind.status} ${bind.message ?? ''}`,
    );
    const workerToken = bind.data?.companionToken;
    if (!workerToken) throw new Error('companion 会话获取失败，/worker/grade 无法验证');
    const [[bindingRow]] = await db.query(
      'SELECT id FROM worker_identity_binding WHERE boss_user_id = ? AND worker_user_id = ? ORDER BY id DESC LIMIT 1',
      [bossUserId, workerUserId],
    );
    if (bindingRow) created.bindingIds.push(bindingRow.id);

    // 临时管理员（超管 + 非超管）
    const [[superRole]] = await db.query("SELECT id FROM admin_role WHERE code='super_admin' LIMIT 1");
    const [[opsRole]] = await db.query("SELECT id FROM admin_role WHERE code='operator' LIMIT 1");
    if (!superRole || !opsRole) throw new Error('admin_role 缺少 super_admin / operator，无法建临时管理员');
    const mkAdmin = async (username, uid, roleId) => {
      const userId = await mkUser(username, uid, '等级 E2E 临时管理员', 'admin');
      await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?,?,1,0)', [userId, roleId]);
      created.adminRows.push(userId);
      return userId;
    };
    const superUserId = await mkAdmin(superUsername, `gs${suffix}`, superRole.id);
    await mkAdmin(opsUsername, `gn${suffix}`, opsRole.id);
    const loginSuper = await api('POST', '/auth/login', {
      body: { username: superUsername, password: pw, role: 'admin' },
    });
    const loginOps = await api('POST', '/auth/login', { body: { username: opsUsername, password: pw, role: 'admin' } });
    const superToken = loginSuper.data?.accessToken;
    const opsToken = loginOps.data?.accessToken;
    ok('前置：临时超管 / 非超管登录成功', !!superToken && !!opsToken, `super=${loginSuper.status} ops=${loginOps.status}`);
    if (!superToken || !opsToken) throw new Error('管理员登录失败');

    // ---------------- 2. 五维越界 / 白名单（400 家族）----------------
    console.log('\n--- ① 入参校验（越界 / 缺字段 / 夹带 workerId）---');
    const boundaryCases = [
      ['五维 skill=0 → 400', { ...FULL_10, skill: 0 }],
      ['五维 skill=11 → 400', { ...FULL_10, skill: 11 }],
      ['五维 stress=8.5 → 400（必须整数）', { ...FULL_10, stress: 8.5 }],
      ['五维 voice="abc" → 400', { ...FULL_10, voice: 'abc' }],
      ['缺 shop 字段 → 400', { skill: 10, emotion: 10, stress: 10, voice: 10 }],
      ['夹带 workerId（白名单）→ 400', { ...FULL_10, workerId: '999' }],
    ];
    for (const [name, body] of boundaryCases) {
      const r = await api('POST', `/user/orders/${orderIds[0]}/rating`, { token: bossToken, body });
      ok(`② ${name}`, r.status === 400, `status=${r.status} message=${r.message ?? ''}`);
    }
    const tooLongComment = await api('POST', `/user/orders/${orderIds[0]}/rating`, {
      token: bossToken,
      body: { ...FULL_10, comment: 'x'.repeat(201) },
    });
    ok('② 评价正文 201 字 → 400', tooLongComment.status === 400, `status=${tooLongComment.status} message=${tooLongComment.message ?? ''}`);

    // ---------------- 3. 归属与状态 ----------------
    console.log('\n--- ③ 归属 / 状态（403 / 404 / 400）---');
    const notMine = await api('POST', `/user/orders/${orderIds[0]}/rating`, { token: boss2Token, body: FULL_10 });
    ok(
      '③ 非本人订单 → 403（不是 500、不落库）',
      notMine.status === 403 && String(notMine.message ?? '').includes('只能评价自己的订单'),
      `status=${notMine.status} message=${notMine.message ?? ''}`,
    );
    const notExist = await api('POST', '/user/orders/999999999/rating', { token: bossToken, body: FULL_10 });
    ok('③ 订单不存在 → 404', notExist.status === 404, `status=${notExist.status} message=${notExist.message ?? ''}`);
    const notCompleted = await api('POST', `/user/orders/${pendingOrderId}/rating`, { token: bossToken, body: FULL_10 });
    ok(
      '③ 未完成订单 → 400',
      notCompleted.status === 400 && String(notCompleted.message ?? '').includes('完成后'),
      `status=${notCompleted.status} message=${notCompleted.message ?? ''}`,
    );
    const anon = await api('POST', `/user/orders/${orderIds[0]}/rating`, { body: FULL_10 });
    ok('③ 未登录 → 401', anon.status === 401, `status=${anon.status}`);
    // 打手不能自评：打手态是 companion（role=worker），`/user/orders/*` 不在 companion 允许清单里 → 403
    const selfRating = await api('POST', `/user/orders/${orderIds[0]}/rating`, { token: workerToken, body: FULL_10 });
    ok(
      '③ 打手态（companion）不能自评 → 403',
      selfRating.status === 403,
      `status=${selfRating.status} message=${selfRating.message ?? ''}`,
    );

    // ---------------- 4. 样本 < 10 不升级 ----------------
    console.log('\n--- ④ 五维样本 < 10 不参与升级判定 ---');
    let last = null;
    for (let i = 0; i < 9; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      last = await api('POST', `/user/orders/${orderIds[i]}/rating`, {
        token: bossToken,
        body: { ...FULL_10, comment: i === 0 ? '打得很稳，节奏舒服' : undefined },
      });
      ok(
        `④ 第 ${i + 1} 条评分落库（201/200）`,
        last.status === 201 || last.status === 200,
        `status=${last.status} samples=${last.data?.agg?.samples} grade=${last.data?.grade?.after}`,
      );
    }
    const [[agg9]] = await db.query(
      'SELECT skill, emotion, stress, voice, shop, sample_count FROM worker_rating_agg WHERE worker_id = ?',
      [workerId],
    );
    ok(
      '④ 9 条样本均分 = 10.00（五列 AVG 都对）',
      Number(agg9.skill) === 10 && Number(agg9.emotion) === 10 && Number(agg9.stress) === 10 &&
        Number(agg9.voice) === 10 && Number(agg9.shop) === 10,
      `agg=${agg9.skill}/${agg9.emotion}/${agg9.stress}/${agg9.voice}/${agg9.shop} samples=${agg9.sample_count}`,
    );
    const [[grade9]] = await db.query('SELECT grade FROM worker_grade WHERE worker_id = ?', [workerId]);
    ok('④ 9 条样本 → **不升级**（worker_grade 无行 = 仍是 LV1）', !grade9, `grade9=${JSON.stringify(grade9)}`);
    const grade9Api = await api('GET', '/worker/grade', { token: workerToken });
    ok(
      '④ 打手态看得到进度：LV1 + 只差 1 条五维样本',
      grade9Api.status === 200 &&
        grade9Api.data?.grade === 1 &&
        grade9Api.data?.progress?.nextGrade === 2 &&
        Array.isArray(grade9Api.data?.progress?.blockers) &&
        grade9Api.data.progress.blockers.length === 1 &&
        String(grade9Api.data.progress.blockers[0]).includes('五维样本'),
      `grade=${grade9Api.data?.grade} next=${grade9Api.data?.progress?.nextGrade} blockers=${JSON.stringify(grade9Api.data?.progress?.blockers)}`,
    );

    // ---------------- 5. 达标升级到 LV2 ----------------
    console.log('\n--- ⑤ 样本达标 + 门槛满足 → 自动升 LV2 ---');
    const tenth = await api('POST', `/user/orders/${orderIds[9]}/rating`, { token: bossToken, body: FULL_10 });
    ok(
      '⑤ 第 10 条评分触发自动升级 1 → 2',
      (tenth.status === 201 || tenth.status === 200) &&
        tenth.data?.grade?.before === 1 &&
        tenth.data?.grade?.after === 2 &&
        tenth.data?.grade?.upgraded === true,
      `status=${tenth.status} grade=${JSON.stringify(tenth.data?.grade)}`,
    );
    const [[grade10]] = await db.query(
      'SELECT grade, upgraded_by, upgraded_at, note FROM worker_grade WHERE worker_id = ?',
      [workerId],
    );
    ok(
      '⑤ 库里 worker_grade.grade=2 且 upgraded_by IS NULL（系统自动）',
      Number(grade10?.grade) === 2 && grade10?.upgraded_by === null && !!grade10?.upgraded_at,
      `row=${JSON.stringify(grade10)}`,
    );
    ok(
      '⑤ note 记了命中指标（可读中文摘要，≤100 字）',
      String(grade10?.note ?? '').includes('自动升级') && String(grade10?.note ?? '').length <= 100,
      `note=${grade10?.note ?? ''}`,
    );
    const [[autoLog]] = await db.query(
      `SELECT id, admin_id, admin_name, module, action, method, path, request_body
         FROM operation_log WHERE module='worker_grade' AND action='worker_grade:auto-upgrade'
          AND request_body LIKE ? ORDER BY id DESC LIMIT 1`,
      [`%"workerId":"${workerId}"%`],
    );
    ok(
      '⑤ operation_log 有自动升级留痕（module=worker_grade / admin_id 为空 / 正文注明系统自动）',
      !!autoLog && autoLog.admin_id === null && String(autoLog.request_body).includes('系统自动判定'),
      autoLog ? `id=${autoLog.id} admin_id=${autoLog.admin_id} admin_name=${autoLog.admin_name} path=${autoLog.path}` : '无记录',
    );
    let autoBody = null;
    try {
      autoBody = JSON.parse(autoLog?.request_body ?? 'null');
    } catch {
      autoBody = null;
    }
    ok(
      '⑤ 留痕 request_body 记了前后等级 + 命中指标',
      !!autoBody && autoBody.before === 1 && autoBody.after === 2 && Array.isArray(autoBody.hits) && autoBody.hits.length > 0,
      `before=${autoBody?.before} after=${autoBody?.after} hits=${JSON.stringify(autoBody?.hits)}`,
    );

    // ---------------- 6. 一单一评 ----------------
    console.log('\n--- ⑥ 一单一评 ---');
    const dup = await api('POST', `/user/orders/${orderIds[9]}/rating`, { token: bossToken, body: FULL_10 });
    ok(
      '① 同一订单重复评 → 400 中文（不落第二行）',
      dup.status === 400 && String(dup.message ?? '').includes('已评价过'),
      `status=${dup.status} message=${dup.message ?? ''}`,
    );
    const [[dupCount]] = await db.query('SELECT COUNT(*) AS c FROM worker_rating WHERE order_id = ?', [orderIds[9]]);
    ok('① 该订单在 worker_rating 里只有 1 行（表级唯一键兜住）', Number(dupCount.c) === 1, `count=${dupCount.c}`);
    const mineGet = await api('GET', `/user/orders/${orderIds[9]}/rating`, { token: bossToken });
    ok(
      '① 回显接口 GET /user/orders/:id/rating 给得出五维',
      mineGet.status === 200 && mineGet.data?.skill === 10 && mineGet.data?.shop === 10,
      `status=${mineGet.status} data=${JSON.stringify(mineGet.data)}`,
    );

    // ---------------- 7. 只升不降 ----------------
    console.log('\n--- ⑦ 只升不降（把统计调低后再跑 evaluate）---');
    await db.query('UPDATE worker_stats SET completed_orders = 1, total_amount = 0 WHERE worker_id = ?', [workerId]);
    const stillTwo = await api('POST', `/user/orders/${orderIds[10]}/rating`, { token: bossToken, body: FULL_10 });
    ok(
      '⑥ 统计被调低 → evaluate 仍跑过，但等级保持 2（before=2 after=2 upgraded=false）',
      (stillTwo.status === 201 || stillTwo.status === 200) &&
        stillTwo.data?.grade?.before === 2 &&
        stillTwo.data?.grade?.after === 2 &&
        stillTwo.data?.grade?.upgraded === false,
      `status=${stillTwo.status} grade=${JSON.stringify(stillTwo.data?.grade)}`,
    );
    const [[gradeAfterDown]] = await db.query('SELECT grade FROM worker_grade WHERE worker_id = ?', [workerId]);
    ok('⑥ 库里等级没有回退（仍 2）', Number(gradeAfterDown?.grade) === 2, `grade=${gradeAfterDown?.grade}`);

    // ---------------- 8. LV5 不自动给 ----------------
    console.log('\n--- ⑧ 宗师门槛满足也只到 LV4（LV5 只能人工）---');
    await db.query('UPDATE worker_stats SET completed_orders = 300, total_amount = 4000.00 WHERE worker_id = ?', [
      workerId,
    ]);
    const maxAuto = await api('POST', `/user/orders/${orderIds[11]}/rating`, { token: bossToken, body: FULL_10 });
    ok(
      '⑦ 指标达宗师门槛 → 自动判定停在 **4**（不是 5）',
      (maxAuto.status === 201 || maxAuto.status === 200) &&
        maxAuto.data?.grade?.after === 4 &&
        maxAuto.data?.grade?.upgraded === true,
      `status=${maxAuto.status} grade=${JSON.stringify(maxAuto.data?.grade)}`,
    );
    const [[gradeFour]] = await db.query('SELECT grade FROM worker_grade WHERE worker_id = ?', [workerId]);
    ok('⑦ 库里 grade=4（LV4 称雄）', Number(gradeFour?.grade) === 4, `grade=${gradeFour?.grade}`);
    const pubFour = await api('GET', `/public/workers/${workerId}`);
    ok(
      '⑦ 公开详情：grade=4 / gradeLabel=LV4 / gradeName=称雄，且 next=5 标了"需人工审核"',
      pubFour.status === 200 &&
        pubFour.data?.grade === 4 &&
        pubFour.data?.gradeLabel === 'LV4' &&
        pubFour.data?.gradeName === '称雄' &&
        pubFour.data?.progress?.nextGrade === 5 &&
        pubFour.data?.progress?.needManualReview === true &&
        pubFour.data?.progress?.readyNow === true,
      `grade=${pubFour.data?.grade}/${pubFour.data?.gradeLabel}/${pubFour.data?.gradeName} progress=${JSON.stringify(pubFour.data?.progress?.nextGrade)}/${pubFour.data?.progress?.needManualReview}/${pubFour.data?.progress?.readyNow}`,
    );

    // ---------------- 9. 管理端：仅超管可设 LV5 ----------------
    console.log('\n--- ⑨ 管理端人工设 LV5（仅超管）---');
    const opsPut = await api('PUT', `/admin/workers/${workerId}/grade`, {
      token: opsToken,
      body: { grade: 5, note: '非超管尝试' },
    });
    ok('⑧ 非超管 → 403 中文', opsPut.status === 403, `status=${opsPut.status} message=${opsPut.message ?? ''}`);
    const anonPut = await api('PUT', `/admin/workers/${workerId}/grade`, { body: { grade: 5 } });
    ok('⑧ 未登录 → 401', anonPut.status === 401, `status=${anonPut.status}`);
    const badGrades = [
      ['grade=0 → 400', 0],
      ['grade=6 → 400', 6],
      ['grade="abc" → 400', 'abc'],
    ];
    for (const [name, grade] of badGrades) {
      // eslint-disable-next-line no-await-in-loop
      const r = await api('PUT', `/admin/workers/${workerId}/grade`, { token: superToken, body: { grade } });
      ok(`⑧ ${name}`, r.status === 400, `status=${r.status} message=${r.message ?? ''}`);
    }

    const setFive = await api('PUT', `/admin/workers/${workerId}/grade`, {
      token: superToken,
      body: { grade: 5, note: '人工审核通过：履约记录与口碑均达标' },
    });
    ok(
      '⑧ 超管设 LV5 → 200，回显 before=4 after=5 / LV5 / 宗师',
      setFive.status === 200 &&
        setFive.data?.before === 4 &&
        setFive.data?.after === 5 &&
        setFive.data?.gradeLabel === 'LV5' &&
        setFive.data?.gradeName === '宗师',
      `status=${setFive.status} data=${JSON.stringify(setFive.data)}`,
    );
    const [[gradeFive]] = await db.query(
      'SELECT grade, upgraded_by, note FROM worker_grade WHERE worker_id = ?',
      [workerId],
    );
    ok(
      '⑧ 库里 grade=5 且 upgraded_by = 超管 user.id（人工操作可追溯）',
      Number(gradeFive?.grade) === 5 && String(gradeFive?.upgraded_by) === String(superUserId),
      `row=${JSON.stringify(gradeFive)} superUserId=${superUserId}`,
    );
    const [[manualLog]] = await db.query(
      `SELECT id, admin_id, module, action, method, path, request_body, ip
         FROM operation_log WHERE module='worker_grade' AND action='worker_grade:manual-set'
          AND request_body LIKE ? ORDER BY id DESC LIMIT 1`,
      [`%"workerId":"${workerId}"%`],
    );
    let manualBody = null;
    try {
      manualBody = JSON.parse(manualLog?.request_body ?? 'null');
    } catch {
      manualBody = null;
    }
    ok(
      '⑧ operation_log 记了人工设置（admin_id=操作人 / 前后等级 / 备注）',
      !!manualLog &&
        String(manualLog.admin_id) === String(superUserId) &&
        manualBody?.before === 4 &&
        manualBody?.after === 5 &&
        String(manualBody?.note ?? '').length > 0,
      manualLog
        ? `id=${manualLog.id} admin_id=${manualLog.admin_id} before=${manualBody?.before} after=${manualBody?.after}`
        : '无记录',
    );
    const sameAgain = await api('PUT', `/admin/workers/${workerId}/grade`, { token: superToken, body: { grade: 5 } });
    ok(
      '⑧ 目标等级与当前相同 → 400（不乱写库）',
      sameAgain.status === 400,
      `status=${sameAgain.status} message=${sameAgain.message ?? ''}`,
    );
    const adminGet = await api('GET', `/admin/workers/${workerId}/grade`, { token: superToken });
    ok(
      '⑧ 超管可读等级详情（含五维）',
      adminGet.status === 200 && adminGet.data?.grade === 5 && adminGet.data?.rating?.samples >= 12,
      `status=${adminGet.status} grade=${adminGet.data?.grade} samples=${adminGet.data?.rating?.samples}`,
    );
    const adminGetOps = await api('GET', `/admin/workers/${workerId}/grade`, { token: opsToken });
    ok('⑧ 非超管读等级详情 → 403', adminGetOps.status === 403, `status=${adminGetOps.status}`);

    // ---------------- 10. 查询三处的字段 ----------------
    console.log('\n--- ⑩ 查询接口（列表 / 公开详情 / 打手态）---');
    const players = await api('GET', `/public/players?divisionId=${division.id}&pageSize=50`);
    const meInList = (players.data?.list ?? []).find((x) => String(x.workerId) === String(workerId));
    ok(
      '⑨ /public/players 列表项带 grade / gradeLabel / gradeName',
      players.status === 200 &&
        !!meInList &&
        meInList.grade === 5 &&
        meInList.gradeLabel === 'LV5' &&
        meInList.gradeName === '宗师',
      meInList ? `item.grade=${meInList.grade}/${meInList.gradeLabel}/${meInList.gradeName}` : `未在列表中找到 worker=${workerId}`,
    );
    ok(
      '⑨ /public/players **不返回五维**（列表极简：无 rating / progress / ratingAvg / ratingSamples）',
      !!meInList &&
        !('rating' in meInList) &&
        !('progress' in meInList) &&
        !('ratingAvg' in meInList) &&
        !('ratingSamples' in meInList),
      `keys=${meInList ? Object.keys(meInList).join(',') : '—'}`,
    );
    const workerDetail = await api('GET', `/public/workers/${workerId}`);
    ok(
      '⑨ /public/workers/:id 带 grade + 五维均分 + 样本数 + 升级进度',
      workerDetail.status === 200 &&
        workerDetail.data?.grade === 5 &&
        workerDetail.data?.gradeLabel === 'LV5' &&
        workerDetail.data?.gradeName === '宗师' &&
        workerDetail.data?.rating?.avg === 10 &&
        workerDetail.data?.rating?.samples >= 12 &&
        workerDetail.data?.progress?.nextGrade === null,
      workerDetail.status === 200
        ? `grade=${workerDetail.data?.grade} rating=${JSON.stringify(workerDetail.data?.rating)} progress.next=${workerDetail.data?.progress?.nextGrade}`
        : `status=${workerDetail.status}`,
    );
    ok(
      '⑨ 公开详情的**既有字段一个没少**（昵称/介绍/接单次数/评价条数/好评率/最近评价）',
      workerDetail.status === 200 &&
        typeof workerDetail.data?.nickname === 'string' &&
        typeof workerDetail.data?.intro === 'string' &&
        typeof workerDetail.data?.completedOrders === 'number' &&
        typeof workerDetail.data?.reviewCount === 'number' &&
        'satisfiedRate' in workerDetail.data &&
        Array.isArray(workerDetail.data?.reviews),
      `keys=${Object.keys(workerDetail.data ?? {}).join(',')}`,
    );
    const myGrade = await api('GET', '/worker/grade', { token: workerToken });
    ok(
      '⑨ /worker/grade 带 grade / gradeLabel / gradeName + 五维 + 进度',
      myGrade.status === 200 &&
        myGrade.data?.grade === 5 &&
        myGrade.data?.gradeLabel === 'LV5' &&
        myGrade.data?.gradeName === '宗师' &&
        myGrade.data?.rating?.samples >= 12 &&
        myGrade.data?.progress?.currentGrade === 5,
      `status=${myGrade.status} grade=${myGrade.data?.grade}/${myGrade.data?.gradeLabel}/${myGrade.data?.gradeName}`,
    );
    ok(
      '⑨ 打手态与公开详情**同一份口径**（五维与样本数逐字相等）',
      myGrade.data?.rating?.avg === workerDetail.data?.rating?.avg &&
        myGrade.data?.rating?.samples === workerDetail.data?.rating?.samples,
      `worker=${JSON.stringify(myGrade.data?.rating)} public=${JSON.stringify(workerDetail.data?.rating)}`,
    );

    // ---------------- 11. LV5 之后再压低评分：仍不降级 ----------------
    console.log('\n--- ⑪ LV5 后再压低评分（只升不降的又一次压力测试）---');
    const lowScore = await api('POST', `/user/orders/${lowScoreOrderId}/rating`, { token: bossToken, body: FULL_1 });
    ok(
      '⑩ 五维全 1 仍可落库（1 是合法下界），且等级 5 不被拉低',
      (lowScore.status === 201 || lowScore.status === 200) &&
        lowScore.data?.agg?.samples >= 13 &&
        lowScore.data?.grade?.before === 5 &&
        lowScore.data?.grade?.after === 5 &&
        lowScore.data?.grade?.upgraded === false,
      `status=${lowScore.status} samples=${lowScore.data?.agg?.samples} grade=${JSON.stringify(lowScore.data?.grade)}`,
    );
    const [[gradeFiveAgain]] = await db.query('SELECT grade FROM worker_grade WHERE worker_id = ?', [workerId]);
    ok('⑩ 均分被拉低后库里仍是 LV5（永不自动降级）', Number(gradeFiveAgain?.grade) === 5, `grade=${gradeFiveAgain?.grade}`);

    // ---------------- 12. 受限会话白名单 ----------------
    console.log('\n--- ⑫ 受限会话白名单（companion / recharge）---');
    const guard = require(path.join(ROOT, 'server', 'dist', 'common', 'guards', 'jwt-auth.guard'));
    ok(
      '⑫ companion 可调 /worker/grade（打手态天然可用）',
      guard.isCompanionAllowedRoute('GET', '/api/v1/worker/grade') === true,
      'isCompanionAllowedRoute(GET /worker/grade) = true',
    );
    ok(
      '⑫ companion **不可**调 /admin/workers/:id/grade（默认拒绝）',
      guard.isCompanionAllowedRoute('PUT', '/api/v1/admin/workers/1/grade') === false,
      'isCompanionAllowedRoute(PUT /admin/workers/:id/grade) = false',
    );
    ok(
      '⑫ recharge 受限会话同样不可调 /admin/workers/:id/grade',
      guard.isRechargeAdminAllowedRoute('PUT', '/api/v1/admin/workers/1/grade') === false,
      'isRechargeAdminAllowedRoute(...) = false',
    );

    console.log(`\n=== 汇总：PASS ${pass} / FAIL ${fail} ===`);
  } finally {
    // ---------- 清理：按 id 精确删除全部夹具（operation_log 留痕刻意保留）----------
    try {
      if (created.workerId) {
        await db.query('DELETE FROM worker_rating WHERE worker_id = ?', [created.workerId]);
        await db.query('DELETE FROM worker_rating_agg WHERE worker_id = ?', [created.workerId]);
        await db.query('DELETE FROM worker_grade WHERE worker_id = ?', [created.workerId]);
        await db.query('DELETE FROM worker_division_permission WHERE worker_id = ?', [created.workerId]);
        await db.query('DELETE FROM worker_stats WHERE worker_id = ?', [created.workerId]);
        await db.query('DELETE FROM worker WHERE id = ?', [created.workerId]);
        console.log(`清理：worker ${created.workerId} 的评分/聚合/等级/权限/统计/档案已删`);
      }
      if (created.reviewIds.length) {
        await db.query(
          `DELETE FROM order_review WHERE id IN (${created.reviewIds.map(() => '?').join(',')})`,
          created.reviewIds,
        );
        console.log(`清理：夹具好评 ${created.reviewIds.length} 行`);
      }
      if (created.bindingIds.length) {
        await db.query(
          `DELETE FROM worker_identity_binding WHERE id IN (${created.bindingIds.map(() => '?').join(',')})`,
          created.bindingIds,
        );
        console.log(`清理：夹具绑定 ${created.bindingIds.length} 行`);
      }
      if (created.orderIds.length) {
        await db.query(
          `DELETE FROM \`order\` WHERE id IN (${created.orderIds.map(() => '?').join(',')})`,
          created.orderIds,
        );
        console.log(`清理：夹具订单 ${created.orderIds.length} 笔`);
      }
      if (created.users.length) {
        const ph = created.users.map(() => '?').join(',');
        await db.query(`DELETE FROM auth_token WHERE user_id IN (${ph})`, created.users);
        if (created.adminRows.length) {
          await db.query(`DELETE FROM admin WHERE user_id IN (${created.adminRows.map(() => '?').join(',')})`, created.adminRows);
        }
        await db.query(`DELETE FROM \`user\` WHERE id IN (${ph})`, created.users);
        console.log(`清理：临时账号 ${created.users.length} 个（含管理员 ${created.adminRows.length} 个）及其会话`);
      }
      const [[left]] = await db.query('SELECT COUNT(*) AS c FROM worker_grade');
      const [[leftRating]] = await db.query('SELECT COUNT(*) AS c FROM worker_rating');
      const [[leftLog]] = await db.query("SELECT COUNT(*) AS c FROM operation_log WHERE module='worker_grade'");
      console.log(
        `清理后：worker_grade ${left.c} 行；worker_rating ${leftRating.c} 行；operation_log(worker_grade) ${leftLog.c} 行（留痕**刻意保留**：审计不可删）`,
      );
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
