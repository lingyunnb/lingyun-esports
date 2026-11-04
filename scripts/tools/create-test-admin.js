/**
 * 专用测试超管 · 创建器
 *
 * ① **它是 `fishadmin` 被删后的替代工装**（2026-10-08）：`fishadmin`（user 182）/ `operator`(183) /
 *    `operator2`(196) 已随"清理全部测试数据"删除，`server/.env` 的 `FISHADMIN_*` 成了死凭证；
 *    而回归里有 10 个套件要登录管理端、发版脚本（`release-boss.js` / `release-worker.js`）也要 ——
 *    本脚本负责"再建一个专用测试超管"，供 `REGRESSION_ADMIN_*` / `RELEASE_ADMIN_*` 使用。
 * ② **拒绝用 `.env` 的 `ADMIN_USERNAME` 当账号名**（本机是负责人本人的超管 `kslingyun`）：
 *    拿它建号/覆盖 = 直接踩「单设备铁律」把负责人顶下线，脚本一律报错退出 1。
 * ③ **支持 `--verify-only`**：只做接口自检（真实登录 + `GET /admin/settings` + `GET /admin/admins`
 *    读回自身角色），**不写库、不发写请求** —— 用于事后复核"这个账号还能不能用、权限对不对"。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 为什么要专用测试超管（而不是直接用 `.env` 的账号）
 * ─────────────────────────────────────────────────────────────────────────────
 * 回归套件里 10 个要登录管理端，而 `server/.env` 里的 `ADMIN_USERNAME` 是**负责人本人的超管账号**
 * （`kslingyun`，`is_owner=1`）。按 docs/04「单设备铁律」（primary ↔ primary 互斥），套件一登录
 * 就把负责人在别处的管理端会话顶掉。docs/12 的硬规则因此要求：**跑回归必须用专用测试超管**
 * （`REGRESSION_ADMIN_USER` / `REGRESSION_ADMIN_PASSWORD`）。
 *
 * ⚠️ **登录限流（实测会踩）**：`/auth/login` 是 **5 次/分/IP+账号**（`auth.service.ts` 的
 * `login:${ip}:${username}`）→ **发版与回归背靠背连跑会吃到 429「登录尝试过于频繁」**
 * （2026-10-13 前该限流返回 403，现已按 docs/03 统一为 429），
 * 两者用同一个账号时必须**错峰 ≥60s**（详见 docs/12 / docs/16）。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 建号口径（与仓库既有的临时超管做法**逐条一致**，不自己发明权限）
 * ─────────────────────────────────────────────────────────────────────────────
 * 参照 `scripts/tmp/_fix-recharge-notice.js` / `scripts/tmp/_task3-proof.js` 的既有口径：
 *   ① `user` 一行：`role='admin'`、`status=1`、bcrypt(10) 口令；
 *   ② `admin` 一行：`role_id = admin_role.code='super_admin'`（**按 code 查，不写死 1**）、
 *      `is_owner=0`（**刻意不做 owner**：owner 能管控其它管理端账号，测试不需要这个面）。
 * **不手写任何权限行**：超级管理员的权限来自内置 `super_admin` 角色自带的 `admin_role_permission`
 * （由 `SeedService` 保证），本脚本只把账号挂到该角色上 —— 这与 `SeedService.onApplicationBootstrap()`
 * 建超管账号的那一步是同一件事（只是不经 HTTP，因为建号接口本身就要一个已登录的管理员）。
 *
 * 为什么不用 `POST /admin/admins` 建：那需要**先用一个管理端账号登录**，而唯一现成的账号就是
 * 负责人的 `kslingyun` —— 用它会顶掉负责人的会话，正是本脚本要避免的事。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 用法
 * ─────────────────────────────────────────────────────────────────────────────
 *   node scripts/tools/create-test-admin.js                        # 建 opsadmin（随机强口令）
 *   node scripts/tools/create-test-admin.js --username opsadmin
 *   node scripts/tools/create-test-admin.js --password '<自定口令>'
 *   node scripts/tools/create-test-admin.js --username opsadmin --reset-password   # 已存在则重置口令
 *   node scripts/tools/create-test-admin.js --username opsadmin --dry              # 只看会做什么（不写库、不发请求）
 *   node scripts/tools/create-test-admin.js --username opsadmin --verify-only --password '<口令>'   # 只做接口自检（不写库）
 *
 * 输出：
 *   - 控制台打印账号 / 口令 / 角色 / 权限自检结果；
 *   - 账密落盘 `data/temp/test-admin-credentials.json`（`data/` 已在 .gitignore，**不进 git**）。
 *
 * 安全约束（脚本自己把关，违反直接退出 1）：
 *   - 拒绝 `--username` 等于 `server/.env` 的 `ADMIN_USERNAME`（不得伪造/覆盖负责人账号）；
 *   - 拒绝 `--owner`（本脚本不建 owner）；
 *   - 只写 `user` / `admin` 两张表，**绝不改任何业务数据**。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '..', '..');
const ENV_FILE = path.join(ROOT, 'server', '.env');
const MYSQL_PROMISE = path.join(ROOT, 'server', 'node_modules', 'mysql2', 'promise');
const BCRYPT = path.join(ROOT, 'server', 'node_modules', 'bcryptjs');
const OUT_FILE = path.join(ROOT, 'data', 'temp', 'test-admin-credentials.json');
const BASE = process.env.API_BASE || 'http://127.0.0.1:3100/api/v1';

// ---------- 参数 ----------
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};
const DRY = has('--dry');
const RESET = has('--reset-password');
const VERIFY_ONLY = has('--verify-only');
const USERNAME = val('--username', 'opsadmin');
const NICKNAME = val('--nickname', '专用测试超管（回归/发布用，非 owner）');

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

/** 随机强口令：保证同时含大写/小写/数字/符号，长度 18（政策上限 64） */
function makePassword() {
  const pick = (chars, n) => Array.from({ length: n }, () => chars[crypto.randomInt(chars.length)]).join('');
  const lower = 'abcdefghijkmnopqrstuvwxyz';
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const digit = '23456789';
  const sym = '!#%+=?';
  const all = lower + upper + digit + sym;
  return `Ops${pick(sym, 1)}${pick(upper, 2)}${pick(lower, 5)}${pick(digit, 4)}${pick(all, 5)}`;
}

const api = async (method, p, { token, body } = {}) => {
  const res = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  let json = null;
  try {
    json = await res.json();
  } catch {
    /* 非 JSON */
  }
  return { status: res.status, data: json?.data, message: json?.message };
};

/**
 * ③ 接口自检：真实登录 + 两个**只有超管才拿到结果**的读取接口。
 * 返回是否全通（口径：登录 200 + /admin/settings 里能看到高安全项 + /admin/admins 能读出自身角色）。
 */
async function interfaceSelfCheck(password) {
  const login = await api('POST', '/auth/login', { body: { username: USERNAME, password, role: 'admin' } });
  console.log(`③ 接口复核：POST /auth/login(role=admin) → HTTP ${login.status}${login.status === 200 ? ' 登录成功' : ` ${login.message}`}`);
  if (login.status !== 200 || !login.data?.accessToken) return false;
  const token = login.data.accessToken;
  const settings = await api('GET', '/admin/settings', { token });
  const rows = settings.data?.list ?? settings.data ?? [];
  const hs = rows.filter((s) => Number(s.isHighSecurity ?? s.is_high_security) === 1);
  console.log(`③ 权限自检：GET /admin/settings → HTTP ${settings.status}（${rows.length} 项，其中仅超管可改的高安全项 ${hs.length} 个）`);
  const adminsSelf = await api('GET', '/admin/admins?page=1&pageSize=100', { token });
  // ⚠️ 该接口的 data 是**数组**（不是 {list}）——两者都兜住，避免形状变化时静默取不到
  const adminRows = Array.isArray(adminsSelf.data) ? adminsSelf.data : (adminsSelf.data?.list ?? []);
  const self = adminRows.find((a) => String(a.username) === USERNAME);
  const roleCode = self?.roleCode ?? self?.role?.code ?? self?.role ?? '(未取到)';
  console.log(`③ 权限自检：GET /admin/admins → HTTP ${adminsSelf.status}，行数 ${adminRows.length}，自身角色 = ${roleCode}`);
  return settings.status === 200 && adminsSelf.status === 200 && String(roleCode) === 'super_admin';
}

(async () => {
  const env = readEnv();
  if (!env.DB_NAME) throw new Error(`读不到 ${ENV_FILE} 的 DB_NAME`);
  if (env.ADMIN_USERNAME && USERNAME === env.ADMIN_USERNAME) {
    throw new Error(
      `拒绝执行：--username=${USERNAME} 正是 server/.env 里的 ADMIN_USERNAME（负责人账号）——` +
        '专用测试超管必须是另一个账号名',
    );
  }
  if (has('--owner')) throw new Error('拒绝执行：本脚本不建 owner（is_owner 恒为 0）');

  if (VERIFY_ONLY) {
    const pw = val('--password', '');
    if (!pw) throw new Error('--verify-only 需要同时给 --password');
    console.log(`=== 专用测试超管 · 只读自检（不写库）：${USERNAME} ===`);
    const okAll = await interfaceSelfCheck(pw);
    console.log(okAll ? '\n✅ 自检通过（专用测试超管可用，权限=super_admin、非 owner）' : '\n❌ 自检未通过');
    process.exit(okAll ? 0 : 1);
  }

  const mysql = require(MYSQL_PROMISE);
  const bcrypt = require(BCRYPT);
  const db = await mysql.createConnection({
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER,
    password: env.DB_PASSWORD,
    database: env.DB_NAME,
    charset: 'utf8mb4',
  });

  try {
    // ---------- ① 角色：按 code 查内置 super_admin（不写死 id） ----------
    const [[role]] = await db.query("SELECT id, code, name FROM admin_role WHERE code = 'super_admin' LIMIT 1");
    if (!role) throw new Error("库里没有 admin_role.code='super_admin'（服务端 SeedService 未跑过？）");
    const [[permCount]] = await db.query(
      'SELECT COUNT(*) AS n FROM admin_role_permission WHERE role_id = ?',
      [role.id],
    );

    // ---------- ② 账号 ----------
    const [users] = await db.query('SELECT id, username, role, status FROM `user` WHERE username = ?', [USERNAME]);
    const [admins] = await db.query(
      'SELECT a.id, a.user_id, a.role_id, a.status, a.is_owner, r.code FROM admin a JOIN admin_role r ON r.id=a.role_id WHERE a.user_id = ?',
      [users[0]?.id ?? -1],
    );
    const existed = users.length > 0;
    const password = RESET || !existed ? val('--password', '') || makePassword() : '(未改动：账号已存在，未加 --reset-password)';

    console.log('=== 专用测试超管创建器 ===');
    console.log(`DB=${env.DB_NAME}@${env.DB_HOST}:${env.DB_PORT}  API=${BASE}`);
    console.log(`目标账号 = ${USERNAME}  已存在 = ${existed ? '是' : '否'}  角色 = super_admin(id=${role.id}, 权限点 ${permCount.n} 个)  is_owner=0`);
    if (users[0]) console.log(`现有 user 行：id=${users[0].id} role=${users[0].role} status=${users[0].status}｜admin 行：${admins.length ? JSON.stringify(admins[0]) : '（无）'}`);

    if (DRY) {
      console.log('[--dry] 不写库、不发请求。实际会做：' + (existed ? '确保 admin 档案存在（+ 可选重置口令）' : 'INSERT user + INSERT admin'));
      await db.end();
      return;
    }

    let userId = users[0]?.id;
    if (!existed) {
      const hash = await bcrypt.hash(password, 10);
      const [r] = await db.query(
        "INSERT INTO `user` (username, uid, password_hash, nickname, role, status) VALUES (?,?,?,?,'admin',1)",
        [USERNAME, `ops${Date.now().toString().slice(-9)}`, hash, NICKNAME],
      );
      userId = r.insertId;
      console.log(`① user 行已建：id=${userId} role=admin status=1`);
    } else {
      if (RESET) {
        await db.query('UPDATE `user` SET password_hash = ? WHERE id = ?', [await bcrypt.hash(password, 10), userId]);
        console.log(`① user 行已存在（id=${userId}）→ 已重置口令`);
      } else {
        console.log(`① user 行已存在（id=${userId}）→ 未改口令（需要重置加 --reset-password）`);
      }
      await db.query("UPDATE `user` SET role='admin', status=1 WHERE id = ?", [userId]);
    }

    if (admins.length === 0) {
      const [r] = await db.query('INSERT INTO admin (user_id, role_id, status, is_owner) VALUES (?,?,1,0)', [userId, role.id]);
      console.log(`② admin 行已建：id=${r.insertId} role_id=${role.id}(super_admin) is_owner=0`);
    } else {
      await db.query('UPDATE admin SET role_id=?, status=1, is_owner=0 WHERE user_id=?', [role.id, userId]);
      console.log(`② admin 行已存在 → 已归位（role_id=${role.id} super_admin / status=1 / is_owner=0）`);
    }

    // ---------- ③ 复核（DB + 真实接口） ----------
    const [[chk]] = await db.query(
      'SELECT a.id, a.is_owner, r.code FROM admin a JOIN admin_role r ON r.id=a.role_id WHERE a.user_id=?',
      [userId],
    );
    console.log(`③ DB 复核：admin.id=${chk.id} role=${chk.code} is_owner=${chk.is_owner}（本脚本恒为 0）`);

    let selfCheckOk = null;
    if (RESET || !existed) {
      selfCheckOk = await interfaceSelfCheck(password);
    } else {
      console.log('③ 接口复核：已存在且未重置口令 → 跳过登录（避免多余会话）');
    }

    fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
    let store = [];
    try {
      store = JSON.parse(fs.readFileSync(OUT_FILE, 'utf8'));
      if (!Array.isArray(store)) store = [];
    } catch {
      /* 首次或文件损坏 → 重建 */
    }
    store = store.filter((x) => x.username !== USERNAME);
    store.push({
      username: USERNAME,
      password: existed && !RESET ? '(未改动：见上一次记录)' : password,
      role: 'super_admin',
      isOwner: 0,
      userId: String(userId),
      adminId: String(chk.id),
      createdAt: new Date().toISOString(),
      note: '专用测试超管（非 owner）。回归用法：$env:REGRESSION_ADMIN_USER / REGRESSION_ADMIN_PASSWORD',
    });
    fs.writeFileSync(OUT_FILE, JSON.stringify(store, null, 2) + '\n', 'utf8');

    console.log('');
    console.log(
      `✅ 专用测试超管就绪：${USERNAME} / ${existed && !RESET ? '(口令未改动)' : password}` +
        (selfCheckOk === null ? '' : selfCheckOk ? '（接口自检通过：super_admin、非 owner）' : '（⚠️ 接口自检未通过，见上方 ③）'),
    );
    console.log(`   账密已落盘（data/ 不入 git）：${OUT_FILE}`);
    console.log('   回归用法：');
    console.log(`     $env:REGRESSION_ADMIN_USER='${USERNAME}'`);
    console.log(`     $env:REGRESSION_ADMIN_PASSWORD='<见上/见落盘文件>'`);
    console.log('     node scripts/tmp/<套件>.js');
  } finally {
    await db.end();
  }
})().catch((e) => {
  console.error(`ERR ${e?.message || e}`);
  process.exit(1);
});
