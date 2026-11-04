#!/usr/bin/env node
/**
 * 一次性：清理后核对（只读，除令牌 401 实测为 HTTP 调用）。
 * 运行：node scripts/tools/wd-demo-postcheck.js
 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));

const CFG = { host: '127.0.0.1', port: 3306, user: 'fish_app', password: 'c1c8a698df50860b182493933c5e1cbb3790fe5322b29b15', database: 'fish_platform', charset: 'utf8mb4' };
const API = 'http://127.0.0.1:3100/api/v1';
const MEDIA_ROOT = 'D:\\fish\\data\\uploads';
const LOG = path.join(__dirname, '..', 'tmp', 'wd-demo-postcheck.log');
fs.writeFileSync(LOG, '');
const log = (s = '') => fs.appendFileSync(LOG, s + '\n');
const J = (o) => JSON.stringify(o);
const q = async (c, s, p = []) => (await c.query(s, p))[0];
const ids = [1243, 1244, 1245];
const PH = ids.map(() => '?').join(',');

(async () => {
  const c = await mysql.createConnection(CFG);

  // ---------- 1. 账实一致 ----------
  log('=== 1. 账实一致（wallet.balance vs Σ wallet_transaction.amount） ===');
  const drift = await q(c, `
    SELECT w.user_id, w.balance, COALESCE(t.s,0) txn_sum, ROUND(w.balance-COALESCE(t.s,0),2) drift
    FROM wallet w LEFT JOIN (SELECT user_id, SUM(amount) s FROM wallet_transaction GROUP BY user_id) t
      ON t.user_id=w.user_id
    WHERE ROUND(w.balance-COALESCE(t.s,0),2) <> 0 ORDER BY ABS(w.balance-COALESCE(t.s,0)) DESC`);
  log('漂移行数 = ' + drift.length + (drift.length ? ' ' + J(drift) : '  ✓'));
  const tot = (await q(c, `SELECT COUNT(*) wallet_rows, ROUND(SUM(balance),2) total_balance FROM wallet`))[0];
  const totT = (await q(c, `SELECT COUNT(*) txn_rows, ROUND(SUM(amount),2) total_txn FROM wallet_transaction`))[0];
  log('全库 wallet: ' + J(tot));
  log('全库 txn   : ' + J(totT));
  log('账实差额 = ' + (Number(tot.total_balance) - Number(totT.total_txn)).toFixed(2));
  log('基线（清理前）: wallet_rows=37 total_balance=131755.62 | txn_rows=447 total_txn=131755.62');

  // ---------- 2. 无孤儿 ----------
  log('\n=== 2. 无孤儿（三张表指向 1243/1244/1245 的行） ===');
  for (const [t, col] of [['withdraw_request', 'user_id'], ['withdraw_request', 'worker_id']]) {
    log(`${t}.${col} = ` + J((await q(c, `SELECT COUNT(*) n FROM \`${t}\` WHERE \`${col}\` IN (${PH})`, ids))[0]));
  }
  log('worker_withdraw_account.worker_id = ' + J((await q(c, `SELECT COUNT(*) n FROM worker_withdraw_account WHERE worker_id IN (SELECT id FROM worker WHERE user_id IN (${PH}))`, ids))[0]));
  log('wallet_transaction.user_id = ' + J((await q(c, `SELECT COUNT(*) n FROM wallet_transaction WHERE user_id IN (${PH})`, ids))[0]));
  log('withdraw_request 总行数 = ' + J((await q(c, `SELECT COUNT(*) n FROM withdraw_request`))[0]));
  log('worker_withdraw_account 总行数 = ' + J((await q(c, `SELECT COUNT(*) n FROM worker_withdraw_account`))[0]));

  // 全表孤儿扫描：任何指向已删账号/已删 worker 的行
  log('\n--- 全库扫描：worker_id/user_id 指向已不存在 worker / user ---');
  for (const [t, col, ref] of [
    ['withdraw_request', 'worker_id', 'worker'], ['withdraw_request', 'user_id', 'user'],
    ['worker_withdraw_account', 'worker_id', 'worker'], ['worker', 'user_id', 'user'],
    ['worker_identity_binding', 'worker_user_id', 'user'], ['worker_identity_binding', 'boss_user_id', 'user'],
    ['worker_division_permission', 'worker_id', 'worker'], ['worker_stats', 'worker_id', 'worker'],
  ]) {
    const r = await q(c, `SELECT COUNT(*) n FROM \`${t}\` x WHERE x.\`${col}\` IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \`${ref}\` r WHERE r.id = x.\`${col}\`)`);
    log(`${t}.${col} → ${ref} 悬空 = ${r[0].n}`);
  }

  // ---------- 3. 账号本体 ----------
  log('\n=== 3. 账号本体 / worker 档案 / 钱包 / 通知 ===');
  log('user 1243/1244/1245 = ' + J(await q(c, `SELECT id,username FROM user WHERE id IN (${PH})`, ids)));
  log('worker 403/402 = ' + J(await q(c, `SELECT id,user_id,worker_no FROM worker WHERE id IN (402,403)`)));
  log('wallet 1024/1025/1026 = ' + J(await q(c, `SELECT id,user_id FROM wallet WHERE id IN (1024,1025,1026)`)));
  log('user_notification 指向三者 = ' + J((await q(c, `SELECT COUNT(*) n FROM user_notification WHERE user_id IN (${PH})`, ids))[0]));
  log('auth_token 指向 1243/1244/1245 = ' + J((await q(c, `SELECT COUNT(*) n FROM auth_token WHERE user_id IN (${PH}) OR binding_id = 341`, ids))[0]));

  // ---------- 4. 绑定 341 ----------
  log('\n=== 4. 绑定 341（须 unbound + 历史行保留） ===');
  log(J(await q(c, `SELECT id,boss_user_id,worker_user_id,status,slot,bound_at,unbound_at,active_boss_user_id,active_worker_user_id FROM worker_identity_binding WHERE id=341`)));
  log('identity 审计（login_log user_type=identity 最近 5 条）:');
  for (const r of await q(c, `SELECT id,user_type,username,fail_reason,created_at FROM login_log WHERE user_type='identity' ORDER BY id DESC LIMIT 5`)) log('  ' + J(r));

  // ---------- 5. 媒体 ----------
  log('\n=== 5. 媒体（withdraw_qr / withdraw_proof 全清点 + 磁盘） ===');
  const wm = await q(c, `SELECT id,file_key,media_type,uploader_id,original_name FROM media WHERE media_type IN ('withdraw_qr','withdraw_proof') ORDER BY id`);
  log('withdraw 用途媒体剩余 ' + wm.length + ' 行:');
  for (const m of wm) log('  ' + J(m));
  for (const id of [267, 268, 269, 270, 271, 272, 273, 274]) {
    const row = await q(c, `SELECT id FROM media WHERE id=?`, [id]);
    log(`  media ${id}: 行 ${row.length ? '仍在' : '已删'}`);
  }
  log('磁盘文件存在性:');
  for (const f of ['e5cdbe69-009c-4681-ab51-7345e94fdf8d.png', 'c2647b24-f5c0-4452-9a8c-b9541e098ca9.png', '940bb557-6f64-48ae-a23b-8b68a8f78267.png', 'f036fa74-fd51-4260-afdc-5afa1bd63d32.png', '19bcdf76-9e8b-4f7b-8bc1-8baaa97c6067.png', '01cfdb91-7c18-4b44-9982-bf2c85d61450.png', 'ff97f780-efc4-4a2f-a7ec-3263774e6412.png']) {
    const abs = path.join(MEDIA_ROOT, '2026', '10', f);
    log(`  ${f}: ${fs.existsSync(abs) ? '存在' : '不存在'}`);
  }

  // ---------- 6. 保留项 ----------
  log('\n=== 6. 保留项（审计 + 既有账号） ===');
  log('operation_log = ' + J((await q(c, `SELECT COUNT(*) n FROM operation_log`))[0]) + '（基线 2125；新增 = 3 次 DELETE /admin/users 留痕）');
  log('login_log = ' + J((await q(c, `SELECT COUNT(*) n FROM login_log`))[0]) + '（基线 1852；新增 = identity 解绑审计 + 登录）');
  log('forum_* 行数: forum_post=' + (await q(c, `SELECT COUNT(*) n FROM forum_post`))[0].n + ' forum_comment=' + (await q(c, `SELECT COUNT(*) n FROM forum_comment`))[0].n + ' forum_like=' + (await q(c, `SELECT COUNT(*) n FROM forum_like`))[0].n);
  for (const n of ['kslingyun', 'lingyun', 'lingyunya', 'platform_account', 'opsadmin', 'worker01', 'worker_test2', 'chat_limited_admin']) {
    const r = await q(c, `SELECT id,username,role,status FROM user WHERE username=?`, [n]);
    log(`  既有账号 ${n}: ${r.length ? J(r[0]) : '!! 不存在 !!'}`);
  }
  log('operation_log 最近 6 条（应含 user:delete）:');
  for (const r of await q(c, `SELECT id,admin_id,module,action,path,created_at FROM operation_log ORDER BY id DESC LIMIT 6`)) log('  ' + J(r));

  // ---------- 7. e2e 残留复扫 ----------
  log('\n=== 7. e2e / demo 残留复扫 ===');
  log('_demo/_e2e/wtest 账号剩余: ' + J(await q(c, `SELECT id,username FROM user WHERE username LIKE '%\\_demo%' OR username LIKE '%\\_e2e%' OR username LIKE 'wtest\\_%'`)));
  log('withdraw: / withdraw_reject: 孤儿流水（指向已不存在申请）:');
  const orph = await q(c, `
    SELECT wt.id, wt.user_id, wt.change_type, wt.amount, wt.idempotency_key
    FROM wallet_transaction wt
    WHERE (wt.idempotency_key LIKE 'withdraw:%' OR wt.idempotency_key LIKE 'withdraw\\_reject:%')
      AND NOT EXISTS (SELECT 1 FROM withdraw_request wr
        WHERE wt.idempotency_key IN (CONCAT('withdraw:',wr.id), CONCAT('withdraw_reject:',wr.id)))
    ORDER BY wt.id`);
  log('  条数 = ' + orph.length);
  const byUser = {};
  for (const r of orph) (byUser[r.user_id] ||= []).push(r);
  for (const [u, rows] of Object.entries(byUser)) {
    const uu = await q(c, `SELECT username FROM user WHERE id=?`, [u]);
    log(`  user ${u} (${uu[0]?.username ?? '已删账号'}): ${rows.length} 行, Σ=${rows.reduce((a, b) => a + Number(b.amount), 0).toFixed(2)}`);
  }
  const wdOrphan = await q(c, `
    SELECT COUNT(*) n FROM worker_withdraw_account wwa
    WHERE wwa.status='active' AND NOT EXISTS (SELECT 1 FROM withdraw_request wr WHERE wr.worker_id = wwa.worker_id AND wr.status='pending')`);
  log('  worker_withdraw_account 现有 active 行: ' + wdOrphan[0].n + '（表总行数见上）');

  await c.end();

  // ---------- 8. 令牌 401 实测 ----------
  log('\n=== 8. 旧 companion / primary 令牌实测（应 401） ===');
  const tokFile = path.join(__dirname, '..', 'tmp', 'wd-demo-tokens.json');
  if (fs.existsSync(tokFile)) {
    const t = JSON.parse(fs.readFileSync(tokFile, 'utf8'));
    log(`（清理前实测：GET /auth/me = ${t.beforeWipe?.authMe}，GET /worker/my-wallet = ${t.beforeWipe?.myWallet}，bindingId=${t.bindingId}）`);
    for (const [label, token] of [['companion(绑定341·打手1244)', t.companionToken], ['primary(老板1245)', t.bossToken]]) {
      for (const url of ['/auth/me', '/worker/my-wallet', '/user/identity', '/user/wallet']) {
        const res = await fetch(API + url, { headers: { Authorization: `Bearer ${token}` } });
        let msg = ''; try { msg = (await res.json())?.message ?? ''; } catch { }
        log(`  ${label} GET ${url} → HTTP ${res.status}${msg ? ' 「' + msg + '」' : ''}`);
      }
    }
    log(`  companion refreshToken POST /user/identity/refresh → HTTP ` + (await (async () => {
      const r = await fetch(API + '/user/identity/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refreshToken: t.companionRefreshToken }) });
      return r.status;
    })()));
  } else log('  （无令牌文件，跳过）');

  // ---------- 9. 健康 ----------
  log('\n=== 9. 服务健康 ===');
  const h = await fetch(API + '/health');
  log(`GET /api/v1/health → HTTP ${h.status} ${J(await h.json().catch(() => ({})))}`);

  log('\nOK -> ' + LOG);
  console.log('OK -> ' + LOG);
})().catch((e) => { log('FAILED: ' + e.message); log(e.stack || ''); console.error('FAILED:', e.message); process.exit(1); });
