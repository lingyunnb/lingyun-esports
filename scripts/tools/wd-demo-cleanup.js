#!/usr/bin/env node
/**
 * 一次性数据清理脚本（可重复执行，幂等）——清掉「打手提现」演示/验证过程中造出的账号与数据。
 *
 * 口径（严格照父任务清单，不越界）：
 *   主清单  A. wd_demo_worker(user 1244) / wd_demo_boss(user 1245)
 *           B. withdraw_request 45 → worker_withdraw_account 26 → wallet_transaction 2776/2777 → wallet 1025
 *           C. media 272/273（+ 磁盘实体文件）
 *           D. user_notification 386/387
 *           E. auth_token（1244/1245 全部，含 companion binding 341）+ binding 341 置 unbound（保留历史行）
 *           F. worker 档案 403 及其从属行
 *   e2e 残留 G. wd_e2e_worker(user 1243) 及其全部从属行 + 其自建媒体 269 + 临时通知
 *            H. 无人引用的 withdraw 用途临时媒体 267 / 270 / 271
 *
 * 账号删除走**正规路径** `DELETE /admin/users/:id`（opsadmin 登录）——它自带
 * 释放绑定 / 吊销令牌 / 断 WS / 写审计 / 清 wallet+流水+通知+worker 档案。
 * 本脚本只补它**不覆盖**的部分：withdraw_request、worker_withdraw_account、
 * media（行 + 磁盘文件，走引用计数口径）、worker_division_permission。
 *
 * 禁止（本脚本硬编码拒绝）：kslingyun/lingyun/lingyunya/platform_account/opsadmin/
 * worker01/worker_test2/chat_limited_admin 等既有账号；operation_log / login_log 一律不动；
 * forum_* 一律不动；任何非本清单行一律不动。
 *
 * 运行：node scripts/tools/wd-demo-cleanup.js            # 真删
 *       node scripts/tools/wd-demo-cleanup.js --dry-run  # 只打印计划
 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));

const DRY = process.argv.includes('--dry-run');
/** --users-only：只跑第 6 步（账号删除）。用于子行已清理、仅账号接口需重试的场景。 */
const USERS_ONLY = process.argv.includes('--users-only');
const ROOT = path.join(__dirname, '..', '..');
const API = 'http://127.0.0.1:3100/api/v1';

// ---------- 环境（从 server/.env 读，不硬编码密钥） ----------
function readEnv() {
  const txt = fs.readFileSync(path.join(ROOT, 'server', '.env'), 'utf8');
  const env = {};
  for (const line of txt.split(/\r?\n/)) {
    const m = /^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$/.exec(line);
    if (m) env[m[1]] = m[2].trim();
  }
  return env;
}
const ENV = readEnv();
const CFG = {
  host: ENV.DB_HOST || '127.0.0.1', port: Number(ENV.DB_PORT || 3306),
  user: ENV.DB_USER, password: ENV.DB_PASSWORD, database: ENV.DB_NAME,
  charset: 'utf8mb4',
};
const MEDIA_ROOT = ENV.MEDIA_ROOT || path.join(ROOT, 'data', 'uploads');

// ---------- 目标（唯一事实来源） ----------
const USER_DEMO_WORKER = 1244; // wd_demo_worker
const USER_DEMO_BOSS = 1245;   // wd_demo_boss
const USER_E2E_WORKER = 1243;  // wd_e2e_worker（今天的 e2e 残留；_e2e 后缀）
const BINDING_ID = 341;
const WITHDRAW_REQUEST_ID = 45;
const WITHDRAW_ACCOUNT_ID = 26;
const WALLET_TXN_IDS = [2776, 2777];       // withdraw:45 / withdraw_reject:45（按 idempotency_key 精确锁定）
const WALLET_TXN_KEYS = ['withdraw:45', 'withdraw_reject:45'];
const MEDIA_DEMO = [272, 273];             // uploader=1244 的收款码
const MEDIA_E2E_ORPHAN = [269];            // uploader=1243 的 e2e 收款码
const MEDIA_UNREF_WD = [267, 270, 271];    // 无人引用的 withdraw 用途临时媒体（e2e/refund 流程产物）
const NOTIFICATION_DEMO = [386, 387];
const NOTIFICATION_E2E = [291, 293, 294, 295, 298, 300, 301, 302, 305, 307, 308, 309, 312, 314, 315, 316, 319, 322, 323, 324, 325, 328, 330, 331, 332, 335, 337, 338, 339, 342, 344, 345, 346, 347, 348, 349, 350, 353, 355, 356, 357, 358, 359, 360, 361, 364, 366, 367, 368, 369, 370, 371, 372, 376, 378, 379, 380, 381, 382, 383, 384, 389, 391, 392, 393, 394, 395, 396, 397, 399, 400, 403, 405, 406, 407, 408, 409, 410, 411, 413, 414, 417, 419, 421, 422, 423, 424, 425, 426, 427, 429, 430, 433, 435, 436, 437, 438, 439, 440, 443, 444];
// 绝不触碰的既有账号（防呆：脚本对任何目标 id 都要先过这一关）
const FORBIDDEN_USERNAMES = ['kslingyun', 'lingyun', 'lingyunya', 'platform_account', 'opsadmin', 'worker01', 'worker_test2', 'chat_limited_admin'];
// 媒体删除的用途白名单（只删 withdraw 用途；其余一律不碰）
const MEDIA_TYPE_WHITELIST = ['withdraw_qr', 'withdraw_proof'];

const LOG = path.join(ROOT, 'scripts', 'tmp', 'wd-demo-cleanup.log');
fs.writeFileSync(LOG, '');
const log = (s = '') => { fs.appendFileSync(LOG, s + '\n'); console.log(s); };
const J = (o) => JSON.stringify(o);
const q = async (c, s, p = []) => (await c.query(s, p))[0];

/** 媒体引用计数：扫全部 `*media_id` / `media_id` 列，统计指向该媒体的行数 */
async function mediaRefCount(c, mediaId) {
  const cols = await q(c, `SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = ? AND (COLUMN_NAME = 'media_id' OR COLUMN_NAME LIKE '%\\_media\\_id')`, [CFG.database]);
  const refs = [];
  for (const col of cols) {
    // 媒体表自身不算引用
    if (col.TABLE_NAME === 'media') continue;
    const rows = await q(c, `SELECT COUNT(*) n FROM \`${col.TABLE_NAME}\` WHERE \`${col.COLUMN_NAME}\` = ?`, [mediaId]);
    if (rows[0].n > 0) refs.push({ table: col.TABLE_NAME, column: col.COLUMN_NAME, n: rows[0].n });
  }
  return refs;
}

async function main() {
  const c = await mysql.createConnection(CFG);
  const report = { deleted: {}, media: { rowsDeleted: [], filesDeleted: [], kept: [] }, users: [] };

  log(`### 打手提现演示数据清理 ${DRY ? '（DRY-RUN，不写库）' : ''}   ${new Date().toISOString()}`);
  log('');

  // ---------- 0. 防呆：目标账号必须是本清单里的，且不得是既有账号 ----------
  log('## 0. 防呆校验');
  const tgt = await q(c, `SELECT id, username, role FROM user WHERE id IN (?,?,?) ORDER BY id`,
    [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS]);
  const found = new Map(tgt.map((r) => [r.id, r]));
  for (const id of [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS]) {
    const u = found.get(id);
    if (!u) { log(`  user ${id}: 已不存在（跳过）`); continue; }
    const bad = FORBIDDEN_USERNAMES.includes(u.username);
    log(`  user ${id}: ${u.username} (${u.role}) ${bad ? '!!! 命中禁删名单，中止 !!!' : 'OK'}`);
    if (bad) throw new Error(`user ${id} = ${u.username} 在禁删名单内，中止`);
  }
  for (const r of await q(c, `SELECT id, username FROM user WHERE username IN (${FORBIDDEN_USERNAMES.map(() => '?').join(',')})`, FORBIDDEN_USERNAMES)) {
    if ([USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS].includes(r.id)) throw new Error(`目标 id 与既有账号冲突: ${J(r)}`);
  }
  log('  禁删名单账号均未被选为目标 ✓');
  log('');

  // ---------- 1. 业务单据：子 → 父 ----------
  if (USERS_ONLY) {
    log('## 1-5. 跳过（--users-only：子行已清理，只重试账号删除）');
  } else {
  log('## 1. 业务单据（先子后父）');

  // 1a. withdraw_request 45（子：引用 wallet_transaction 2776 与 media）
  const wr45 = await q(c, `SELECT id, worker_id, user_id, amount, status, reject_reason, wallet_transaction_id, idempotency_key
      FROM withdraw_request WHERE id = ?`, [WITHDRAW_REQUEST_ID]);
  if (wr45.length) {
    log(`  withdraw_request 45: ${J(wr45[0])}`);
    if (!DRY) { const r = await c.query('DELETE FROM withdraw_request WHERE id = ?', [WITHDRAW_REQUEST_ID]); report.deleted['withdraw_request'] = r[0].affectedRows; }
    else report.deleted['withdraw_request'] = 1;
    log(`  → 删除 ${report.deleted['withdraw_request']} 行`);
  } else { log('  withdraw_request 45: 已不存在'); report.deleted['withdraw_request'] = 0; }

  // 1b. 提现申请表里是否还有指向 1243/1244/1245 的行（查漏；按 id 排除已处理的 45，避免重复计数）
  const wrLeft = await q(c, `SELECT id, user_id, worker_id FROM withdraw_request
      WHERE user_id IN (?,?,?) AND id <> ?`, [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS, WITHDRAW_REQUEST_ID]);
  if (wrLeft.length) {
    log(`  额外发现 withdraw_request: ${J(wrLeft)}`);
    for (const r of wrLeft) {
      if (!DRY) { const rr = await c.query('DELETE FROM withdraw_request WHERE id = ?', [r.id]); report.deleted['withdraw_request'] += rr[0].affectedRows; }
      else report.deleted['withdraw_request'] += 1;
    }
  } else log('  无额外 withdraw_request（行 45 已处理）');

  // 1c. worker_withdraw_account 26（父：media 273 引用者）
  const wwa = await q(c, `SELECT id, worker_id, qr_media_id FROM worker_withdraw_account WHERE id = ?`, [WITHDRAW_ACCOUNT_ID]);
  if (wwa.length) {
    log(`  worker_withdraw_account 26: ${J(wwa[0])}（引用 media ${wwa[0].qr_media_id}）`);
    if (!DRY) { const r = await c.query('DELETE FROM worker_withdraw_account WHERE id = ?', [WITHDRAW_ACCOUNT_ID]); report.deleted['worker_withdraw_account'] = r[0].affectedRows; }
    else report.deleted['worker_withdraw_account'] = 1;
    log(`  → 删除 ${report.deleted['worker_withdraw_account']} 行（先解引用，media 才能删）`);
  } else { log('  worker_withdraw_account 26: 已不存在'); report.deleted['worker_withdraw_account'] = 0; }

  // 1d. 该打手钱包流水的精确锁定校验（按 idempotency_key，不按金额）
  log('');
  log('## 2. 钱包流水（按 idempotency_key 精确定位，不按金额）');
  const txns = await q(c, `SELECT id, user_id, change_type, amount, idempotency_key FROM wallet_transaction
      WHERE idempotency_key IN (?,?) ORDER BY id`, WALLET_TXN_KEYS);
  for (const t of txns) log(`  ${J(t)}`);
  const idsMatch = txns.map((t) => t.id).join(',') === WALLET_TXN_IDS.join(',');
  log(`  期望 id ${WALLET_TXN_IDS.join(',')} → 实际 ${txns.map((t) => t.id).join(',') || '(无)'} ${idsMatch ? '✓ 一致' : '（注意：将由 DELETE /admin/users/:id 连带清理）'}`);
  log('  注：2776/2777 由 `DELETE /admin/users/1244` 的既有实现（`DELETE FROM wallet_transaction WHERE user_id`）连带删除');

  // ---------- 3. 媒体（行 + 磁盘文件，走引用计数口径） ----------
  log('');
  log('## 3. 媒体（引用计数口径：仍被引用的禁止删）');
  const mediaIds = [...MEDIA_DEMO, ...MEDIA_E2E_ORPHAN, ...MEDIA_UNREF_WD, 274];
  const mediaRows = await q(c, `SELECT id, file_key, media_type, original_name, uploader_id FROM media WHERE id IN (${mediaIds.map(() => '?').join(',')})`, mediaIds);
  const byId = new Map(mediaRows.map((r) => [r.id, r]));
  const toDeleteMedia = [];
  for (const id of mediaIds) {
    const m = byId.get(id);
    if (!m) { log(`  media ${id}: 已不存在`); continue; }
    const refs = await mediaRefCount(c, id);
    const typeOk = MEDIA_TYPE_WHITELIST.includes(m.media_type);
    const allowed = [...MEDIA_DEMO, ...MEDIA_E2E_ORPHAN, ...MEDIA_UNREF_WD].includes(id);
    const verdict = !typeOk ? 'KEEP（用途不在白名单）' : !allowed ? 'KEEP（不在本清单）' : refs.length === 0 ? 'DELETE' : 'KEEP（仍被引用）';
    log(`  media ${id} type=${m.media_type} uploader=${m.uploader_id} name=${m.original_name} refs=${refs.length ? J(refs) : '[]'} → ${verdict}`);
    if (verdict === 'DELETE') toDeleteMedia.push(m);
    else report.media.kept.push({ id, reason: verdict, media_type: m.media_type, uploader_id: m.uploader_id, original_name: m.original_name });
  }
  for (const m of toDeleteMedia) {
    const abs = path.join(MEDIA_ROOT, m.file_key);
    const exists = fs.existsSync(abs);
    const size = exists ? fs.statSync(abs).size : 0;
    if (!DRY) {
      await c.query('DELETE FROM media WHERE id = ?', [m.id]);
      if (exists) fs.unlinkSync(abs);
    }
    report.media.rowsDeleted.push(m.id);
    if (exists) report.media.filesDeleted.push({ file: abs, size });
    log(`  → media ${m.id} 行已删；文件 ${abs} ${exists ? `已删（${size}B）` : '不存在'}`);
  }
  report.deleted['media'] = report.media.rowsDeleted.length;

  // ---------- 4. 站内通知 ----------
  log('');
  log('## 4. 站内通知');
  // 4a. 先按显式 id 清单删（demo 386/387 + e2e 明确清单），用于核对命中数
  const notiIds = [...NOTIFICATION_DEMO, ...NOTIFICATION_E2E];
  const notiRows = await q(c, `SELECT id, user_id, type, ref_id FROM user_notification WHERE id IN (${notiIds.map(() => '?').join(',')})`, notiIds);
  log(`  显式清单命中 ${notiRows.length} 行（demo ${NOTIFICATION_DEMO.length} + e2e ${NOTIFICATION_E2E.length} 期望）`);
  let notiDeleted = 0;
  if (notiRows.length) {
    if (!DRY) { const r = await c.query(`DELETE FROM user_notification WHERE id IN (${notiRows.map(() => '?').join(',')})`, notiRows.map((x) => x.id)); notiDeleted += r[0].affectedRows; }
    else notiDeleted += notiRows.length;
  }
  // 4b. 兜底扫尾：1243/1244 名下**全部**通知（演示/e2e 账号，不成遗漏；不用手抄 id 清单）
  const restRows = await q(c, `SELECT id FROM user_notification WHERE user_id IN (?,?)`, [USER_E2E_WORKER, USER_DEMO_WORKER]);
  if (restRows.length) {
    log(`  兜底扫尾：1243/1244 名下其余通知 ${restRows.length} 行`);
    if (!DRY) { const r = await c.query(`DELETE FROM user_notification WHERE user_id IN (?,?)`, [USER_E2E_WORKER, USER_DEMO_WORKER]); notiDeleted += r[0].affectedRows; }
    else notiDeleted += restRows.length;
  }
  report.deleted['user_notification'] = notiDeleted;
  log(`  → 删除 ${notiDeleted} 行`);
  const notiLeft = await q(c, `SELECT COUNT(*) n FROM user_notification WHERE user_id IN (?,?,?)`, [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS]);
  log(`  剩余指向 1243/1244/1245 的通知 = ${notiLeft[0].n}（1245 无通知）`);

  // ---------- 5. worker_division_permission（DELETE /admin/users 不覆盖） ----------
  log('');
  log('## 5. worker_division_permission（账号接口未覆盖，脚本补删）');
  const wdp = await q(c, `SELECT wdp.id FROM worker_division_permission wdp
      JOIN worker w ON w.id = wdp.worker_id WHERE w.user_id IN (?,?,?)`, [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS]);
  if (!DRY && wdp.length) {
    const r = await c.query(`DELETE FROM worker_division_permission WHERE id IN (${wdp.map(() => '?').join(',')})`, wdp.map((x) => x.id));
    report.deleted['worker_division_permission'] = r[0].affectedRows;
  } else report.deleted['worker_division_permission'] = wdp.length;
  log(`  → 删除 ${report.deleted['worker_division_permission']} 行`);

  await c.end();
  } // end if (!USERS_ONLY)

  // ---------- 6. 账号删除：走正规路径 DELETE /admin/users/:id ----------
  log('');
  log('## 6. 账号删除（正规路径 DELETE /admin/users/:id，opsadmin 登录）');
  if (DRY) { log('  DRY-RUN：跳过账号删除'); report.media.filesDeleted = report.media.filesDeleted; }
  else {
    const loginRes = await fetch(`${API}/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: ENV.REGRESSION_ADMIN_USER, password: ENV.REGRESSION_ADMIN_PASSWORD, role: 'admin' }),
    });
    const loginBody = await loginRes.json();
    if (loginRes.status !== 200 && loginRes.status !== 201) throw new Error(`opsadmin 登录失败 ${loginRes.status}: ${J(loginBody)}`);
    const adminToken = loginBody?.data?.accessToken ?? loginBody?.data?.access_token ?? loginBody?.data?.token;
    if (!adminToken) throw new Error('登录响应里拿不到 accessToken: ' + J(Object.keys(loginBody?.data ?? {})));
    const adminId = loginBody?.data?.user?.id;
    log(`  opsadmin 登录成功（adminId=${adminId}）`);
    report.adminId = adminId;

    for (const id of [USER_E2E_WORKER, USER_DEMO_WORKER, USER_DEMO_BOSS]) {
      const res = await fetch(`${API}/admin/users/${id}`, { method: 'DELETE', headers: { Authorization: `Bearer ${adminToken}` } });
      const body = await res.json().catch(() => ({}));
      log(`  DELETE /admin/users/${id} → HTTP ${res.status} ${J(body)}`);
      report.users.push({ id, status: res.status, body });
    }
  }

  log('');
  log('## 删除行数明细');
  for (const [k, v] of Object.entries(report.deleted)) log(`  ${k}: ${v}`);
  log(`  media 行: ${report.media.rowsDeleted.length} [${report.media.rowsDeleted.join(',')}]`);
  log(`  media 磁盘文件: ${report.media.filesDeleted.length}`);
  for (const f of report.media.filesDeleted) log(`    ${f.file} (${f.size}B)`);
  log('  账号本体/令牌/钱包/流水/worker 档案/绑定释放：由 DELETE /admin/users/:id 在事务内完成（见上）');
  fs.writeFileSync(path.join(ROOT, 'scripts', 'tmp', 'wd-demo-cleanup.json'), JSON.stringify(report, null, 2));
  log('');
  log('OK -> ' + LOG);
}

main().catch((e) => { log('FAILED: ' + e.message); log(e.stack || ''); console.error('FAILED:', e.message); process.exit(1); });
