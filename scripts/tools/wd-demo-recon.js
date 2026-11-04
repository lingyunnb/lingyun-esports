#!/usr/bin/env node
/**
 * 一次性侦察脚本（只读，流式写日志）：清掉「打手提现」演示账号前，把全部关联行摸清楚。
 * 运行：node scripts/tools/wd-demo-recon.js
 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));

const CFG = {
  host: '127.0.0.1', port: 3306, user: 'fish_app',
  password: 'c1c8a698df50860b182493933c5e1cbb3790fe5322b29b15',
  database: 'fish_platform', charset: 'utf8mb4',
};

const LOG = path.join(__dirname, '..', 'tmp', 'wd-demo-recon.log');
fs.writeFileSync(LOG, '');
const log = (s) => { fs.appendFileSync(LOG, s + '\n'); };
const J = (o) => JSON.stringify(o);

const TARGET = [1243, 1244, 1245];

async function q(conn, sql, params = []) {
  const [rows] = await conn.query(sql, params);
  return rows;
}

(async () => {
  const conn = await mysql.createConnection(CFG);
  const PH = TARGET.map(() => '?').join(',');

  log('=== 1. 目标账号 ===');
  for (const u of await q(conn, `SELECT id,username,nickname,role,status,created_at FROM user WHERE id IN (${PH}) ORDER BY id`, TARGET)) log(J(u));

  log('\n=== 1b. 全部 _demo/_e2e/wtest 账号 ===');
  for (const u of await q(conn, `SELECT id,username,nickname,role,status,created_at FROM user WHERE username LIKE '%\\_demo%' OR username LIKE '%\\_e2e%' OR username LIKE 'wtest\\_%' ORDER BY id`)) log(J(u));

  log('\n=== 1c. 今天(2026-10-11)创建的账号 ===');
  for (const u of await q(conn, `SELECT id,username,nickname,role,status,created_at FROM user WHERE created_at >= '2026-10-11 00:00:00' ORDER BY id`)) log(J(u));

  log('\n=== 2. worker 档案（目标 user + 今天创建） ===');
  for (const w of await q(conn, `SELECT * FROM worker WHERE user_id IN (${PH}) OR created_at >= '2026-10-11 00:00:00' ORDER BY id`, TARGET)) log(J(w));

  log('\n=== 3. wallet 行（目标 user） ===');
  for (const w of await q(conn, `SELECT * FROM wallet WHERE user_id IN (${PH}) ORDER BY id`, TARGET)) log(J(w));

  log('\n=== 3b. wallet_transaction（目标 user） ===');
  for (const t of await q(conn, `SELECT id,transaction_no,user_id,change_type,amount,balance_before,balance_after,operator_type,operator_id,reason,idempotency_key,created_at FROM wallet_transaction WHERE user_id IN (${PH}) ORDER BY id`, TARGET)) log(J(t));

  log('\n=== 3c. 今天全部 wallet_transaction（找其它夹具流水） ===');
  for (const t of await q(conn, `SELECT id,user_id,change_type,amount,idempotency_key,created_at FROM wallet_transaction WHERE created_at >= '2026-10-11 00:00:00' ORDER BY id`)) log(J(t));

  log('\n=== 4. withdraw_request 全表 ===');
  for (const r of await q(conn, `SELECT id,worker_id,user_id,amount,status,reject_reason,idempotency_key,wallet_transaction_id,payout_proof_media_id,created_at FROM withdraw_request ORDER BY id`)) log(J(r));

  log('\n=== 5. worker_withdraw_account 全表 ===');
  for (const r of await q(conn, `SELECT id,worker_id,real_name,phone,wechat_id,qr_media_id,status,created_at FROM worker_withdraw_account ORDER BY id`)) log(J(r));

  log('\n=== 6. media（目标 uploader / 今天 / withdraw 用途） ===');
  for (const m of await q(conn, `SELECT id,file_key,media_type,original_name,mime_type,size_bytes,uploader_id,is_protected,created_at FROM media WHERE uploader_id IN (${PH}) OR media_type IN ('withdraw_qr','withdraw_proof') OR created_at >= '2026-10-11 00:00:00' ORDER BY id`, TARGET)) log(J(m));

  log('\n=== 6b. withdraw_qr / withdraw_proof 全清点 ===');
  for (const m of await q(conn, `SELECT id,file_key,media_type,uploader_id,is_protected,created_at FROM media WHERE media_type IN ('withdraw_qr','withdraw_proof') ORDER BY id`)) log(J(m));

  log('\n=== 7. user_notification（目标） ===');
  for (const n of await q(conn, `SELECT id,user_id,type,title,is_read,ref_id,created_at FROM user_notification WHERE user_id IN (${PH}) ORDER BY id`, TARGET)) log(J(n));

  log('\n=== 7b. user_notification 今天创建 ===');
  for (const n of await q(conn, `SELECT id,user_id,type,title,created_at FROM user_notification WHERE created_at >= '2026-10-11 00:00:00' ORDER BY id`)) log(J(n));

  log('\n=== 8. worker_identity_binding（涉及目标） ===');
  for (const b of await q(conn, `SELECT * FROM worker_identity_binding WHERE boss_user_id IN (${PH}) OR worker_user_id IN (${PH}) ORDER BY id`, [...TARGET, ...TARGET])) log(J(b));

  log('\n=== 8b. auth_token（目标 user 或 binding 341） ===');
  for (const t of await q(conn, `SELECT id,jti,user_id,role,kind,binding_id,revoked,expire_at,created_at FROM auth_token WHERE user_id IN (${PH}) OR binding_id = 341 ORDER BY id`, TARGET)) log(J(t));

  log('\n=== 9. worker_division_permission / worker_stats ===');
  const wids = (await q(conn, `SELECT id FROM worker WHERE user_id IN (${PH})`, TARGET)).map((r) => r.id);
  if (wids.length) {
    const wp = wids.map(() => '?').join(',');
    for (const r of await q(conn, `SELECT * FROM worker_division_permission WHERE worker_id IN (${wp})`, wids)) log('wdp ' + J(r));
    for (const r of await q(conn, `SELECT * FROM worker_stats WHERE worker_id IN (${wp})`, wids)) log('wstats ' + J(r));
  } else log('(无 worker 档案)');

  log('\n=== 10. 含归属列的所有表（查漏） ===');
  const cols = await q(conn, `SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='fish_platform' AND COLUMN_NAME IN
    ('user_id','worker_user_id','boss_user_id','uploader_id','worker_id','binding_id','to_user_id','from_user_id','operator_id','admin_id','paid_by','rejected_by')
    ORDER BY TABLE_NAME`);
  const bt = {};
  for (const c of cols) (bt[c.TABLE_NAME] ||= []).push(c.COLUMN_NAME);
  for (const [t, cs] of Object.entries(bt)) log(`${t}: ${cs.join(',')}`);

  log('\n=== 11. 钱包守恒基线 ===');
  log(J((await q(conn, `SELECT COUNT(*) AS wallet_rows, ROUND(SUM(balance),2) AS total_balance FROM wallet`))[0]));
  log(J((await q(conn, `SELECT COUNT(*) AS txn_rows, ROUND(SUM(amount),2) AS total_txn FROM wallet_transaction`))[0]));

  log('\n=== 12. 审计基线（不得变化） ===');
  log(J((await q(conn, `SELECT COUNT(*) AS operation_log_rows FROM operation_log`))[0]));
  log(J((await q(conn, `SELECT COUNT(*) AS login_log_rows FROM login_log`))[0]));

  log('\n=== 13. withdraw_request 总行数 ===');
  log(J((await q(conn, `SELECT COUNT(*) AS n FROM withdraw_request`))[0]));

  await conn.end();
  console.log('OK -> ' + LOG);
})().catch((e) => { log('FAILED: ' + e.message + '\n' + e.stack); console.error('FAILED:', e.message); process.exit(1); });
