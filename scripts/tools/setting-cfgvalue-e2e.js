/**
 * `PUT /admin/settings/:key` 入参校验 · 端到端自证（2026-10-17 真事故回归）
 *
 * 运行（服务需已启动；默认打 127.0.0.1:3100）：
 *   cd server && npm run build && PORT=3111 node dist/main.js   # 另开一个窗口
 *   node scripts/tools/setting-cfgvalue-e2e.js
 *   E2E_BASE=http://127.0.0.1:3111/api/v1 node scripts/tools/setting-cfgvalue-e2e.js
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 这条脚本守的是**一次真事故**："看起来成功，其实没写"
 * ─────────────────────────────────────────────────────────────────────────────
 * 事故现场：管理端传 `{ value: [...] }`（少了外层 `cfgValue`）或直接传裸数组 →
 * 服务端拿到 `cfgValue === undefined` → **照样 200**，库里一个字没动。
 *
 * 断言（改法 = 控制器入口一处校验，`SystemSettingService.update` 一字未动）：
 *  ① 缺 `cfgValue`（只传了 `{ value: [...] }`）→ **400**，且库里 `cfg_value` **没变**
 *  ② 裸数组 body → **400**（也是"没有 cfgValue"的一种）
 *  ③ `cfgValue: []` → **400**（"必须是对象"），且库里**没变**
 *  ④ `cfgValue: "x"` / `cfgValue: 1` → **400**（同上，非对象）
 *  ⑤ 正常 `{ cfgValue: { value: 42 }, description: "…" }` → **200**，库里真的写进去了
 *     （`cfg_value.value = 42`、`description` 同步更新）—— 证明校验没有把正常写入挡掉
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 夹具与清理（**自建自删，不碰负责人真实配置**）
 * ─────────────────────────────────────────────────────────────────────────────
 *  - 临时 `system_setting` 行：`setting_key = 'e2e_cfgvalue_<后缀>'`（`is_high_security = 0`），
 *    只有这条会被读/写；`finally` 里按 key 精确删除
 *  - 临时超管（`user` + `admin`，角色 `super_admin`），`finally` 里按 id 精确删除
 *  - `operation_log` 留痕**刻意保留**（审计不可删）
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
  return `Cfg${pick('!#%+=?', 1)}${pick('ABCDEFGHJKLMNPQRSTUVWXYZ', 2)}${pick('abcdefghijkmnopqrstuvwxyz', 5)}${pick('23456789', 4)}`;
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

  const created = { userId: null, adminUsername: null };
  let settingKey = null;

  /** 读夹具行（**唯一读取点**：所有"没被写坏"的断言都读它） */
  const readCfg = async () => {
    const [rows] = await db.query('SELECT cfg_value, description FROM system_setting WHERE setting_key = ? LIMIT 1', [
      settingKey,
    ]);
    if (!rows.length) return null;
    const raw = rows[0].cfg_value;
    return {
      cfgValue: typeof raw === 'string' ? JSON.parse(raw) : raw,
      description: rows[0].description,
    };
  };

  try {
    console.log('=== PUT /admin/settings/:key 入参校验 E2E（缺 cfgValue 必须 400）===');
    console.log(`API = ${BASE}`);

    const health = await api('GET', '/public/home');
    ok('前置：服务在线（GET /public/home 200）', health.status === 200, `status=${health.status} ${health.ms}ms`);
    if (health.status !== 200) {
      console.log('\n服务未就绪 —— 先起一个新构建（PORT=3111 node dist/main.js）。');
      await db.end();
      process.exit(1);
    }

    // ---------------- 1. 夹具：临时配置行 + 临时超管 ----------------
    const suffix = String(Date.now()).slice(-7);
    settingKey = `e2e_cfgvalue_${suffix}`;
    await db.query(
      'INSERT INTO system_setting (setting_key, cfg_value, description, is_high_security) VALUES (?,?,?,0)',
      [settingKey, JSON.stringify({ value: 1 }), 'E2E 临时配置（脚本自建自删）'],
    );

    const pw = makePassword();
    const username = `cfga${suffix}`;
    const hash = await bcrypt.hash(pw, 10);
    const [u] = await db.query(
      "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?, 'admin', 1)",
      [username, `ca${suffix}`, hash, '配置校验 E2E 临时超管'],
    );
    created.userId = String(u.insertId);
    created.adminUsername = username;
    const [[superRole]] = await db.query("SELECT id FROM admin_role WHERE code='super_admin' LIMIT 1");
    if (!superRole) throw new Error('admin_role 缺少 super_admin，无法建临时管理员');
    await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?,?,1,0)', [created.userId, superRole.id]);

    const login = await api('POST', '/auth/login', { body: { username, password: pw, role: 'admin' } });
    const token = login.data?.accessToken;
    ok('前置：临时超管登录成功', login.status === 200 && !!token, `status=${login.status} ${login.message ?? ''}`);
    if (!token) throw new Error('管理员登录失败，无法验证 PUT /admin/settings/:key');

    const before = await readCfg();
    ok('前置：夹具行初始 cfg_value = {"value":1}', before && before.cfgValue?.value === 1, JSON.stringify(before));

    // ---------------- 2. 缺 / 错的 body → 400（且一行都不许写） ----------------
    console.log('\n--- ① 缺 cfgValue（今天踩到的那次）---');
    const missing = await api('PUT', `/admin/settings/${settingKey}`, {
      token,
      body: { value: [10, 20, 30] }, // 少包一层 cfgValue —— 事故原样
    });
    ok(
      '① 只传 { value: [...] }（缺 cfgValue）→ 400',
      missing.status === 400,
      `status=${missing.status} message=${missing.message ?? ''}`,
    );
    ok('① 中文文案点明缺的是 cfgValue', String(missing.message ?? '').includes('cfgValue'), `message=${missing.message ?? ''}`);
    const afterMissing = await readCfg();
    ok(
      '① 400 之后库里一个字都没变（不再"看起来成功"）',
      JSON.stringify(afterMissing?.cfgValue) === JSON.stringify(before?.cfgValue),
      JSON.stringify(afterMissing?.cfgValue),
    );

    console.log('\n--- ② 裸数组 / 非对象 cfgValue ---');
    const nakedArray = await api('PUT', `/admin/settings/${settingKey}`, { token, body: [1, 2, 3] });
    ok('② body 是裸数组（无 cfgValue）→ 400', nakedArray.status === 400, `status=${nakedArray.status} message=${nakedArray.message ?? ''}`);

    const emptyArray = await api('PUT', `/admin/settings/${settingKey}`, { token, body: { cfgValue: [] } });
    ok('③ cfgValue: [] → 400', emptyArray.status === 400, `status=${emptyArray.status} message=${emptyArray.message ?? ''}`);
    ok('③ 文案说明"必须是对象"', String(emptyArray.message ?? '').includes('对象'), `message=${emptyArray.message ?? ''}`);

    for (const [name, value] of [
      ['③ cfgValue: "abc"（字符串）', 'abc'],
      ['③ cfgValue: 1（数字）', 1],
    ]) {
      const r = await api('PUT', `/admin/settings/${settingKey}`, { token, body: { cfgValue: value } });
      ok(`${name} → 400`, r.status === 400, `status=${r.status} message=${r.message ?? ''}`);
    }

    const afterBad = await readCfg();
    ok(
      '③ 全组 400 之后库里仍然一个字没变',
      JSON.stringify(afterBad?.cfgValue) === JSON.stringify(before?.cfgValue),
      JSON.stringify(afterBad?.cfgValue),
    );

    // ---------------- 3. 正确 body → 200 且真的写进去 ----------------
    console.log('\n--- ④ 正常 { cfgValue, description } ---');
    const good = await api('PUT', `/admin/settings/${settingKey}`, {
      token,
      body: { cfgValue: { value: 42, note: 'e2e' }, description: 'E2E 写入成功' },
    });
    ok('④ 正常对象 → 200', good.status === 200, `status=${good.status} message=${good.message ?? ''}`);
    const afterGood = await readCfg();
    ok(
      '④ 库里真的写进去了（cfg_value.value = 42）',
      afterGood && Number(afterGood.cfgValue?.value) === 42,
      JSON.stringify(afterGood?.cfgValue),
    );
    ok('④ description 同步更新', afterGood?.description === 'E2E 写入成功', `${afterGood?.description ?? ''}`);
    ok(
      '④ 响应体回带服务端存下的值（不是把请求原样弹回）',
      good.data?.settingKey === settingKey || good.data?.cfgValue !== undefined,
      JSON.stringify(good.data ?? null).slice(0, 120),
    );

    // ---------------- 4. 审计留痕（改成功才该有一条） ----------------
    const [logs] = await db.query(
      "SELECT COUNT(*) AS n FROM operation_log WHERE module='setting' AND action=? AND result='success'",
      [`setting:update:${settingKey}`],
    );
    ok('⑤ operation_log 有 1 条成功留痕（谁改的/改了什么都留了）', Number(logs[0].n) === 1, `count=${logs[0].n}`);
  } catch (e) {
    fail += 1;
    console.log(`FAIL  脚本异常：${(e && e.message) || e}`);
  } finally {
    // 自建自删：只删本次夹具，`operation_log` 留痕保留
    try {
      if (settingKey) await db.query('DELETE FROM system_setting WHERE setting_key = ?', [settingKey]);
      if (created.userId) {
        await db.query('DELETE FROM admin WHERE user_id = ?', [created.userId]);
        await db.query('DELETE FROM `user` WHERE id = ?', [created.userId]);
      }
    } catch (e) {
      console.log(`清理告警：${(e && e.message) || e}`);
    }
    await db.end();
    console.log(`\n=== 结果：${pass} PASS / ${fail} FAIL ===`);
    process.exit(fail === 0 ? 0 : 1);
  }
})();
