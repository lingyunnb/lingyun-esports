#!/usr/bin/env node
/** 一次性核对脚本（只读）：账实一致 + 孤儿检查 + 引用计数。 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));
const CFG = { host: '127.0.0.1', port: 3306, user: 'fish_app', password: 'c1c8a698df50860b182493933c5e1cbb3790fe5322b29b15', database: 'fish_platform', charset: 'utf8mb4' };
const LOG = path.join(__dirname, '..', 'tmp', 'wd-demo-verify.log');
fs.writeFileSync(LOG, '');
const log = (s) => fs.appendFileSync(LOG, s + '\n');
const J = (o) => JSON.stringify(o);
const q = async (c, s, p = []) => (await c.query(s, p))[0];

(async () => {
  const c = await mysql.createConnection(CFG);

  log('=== A. 全库账实一致（wallet.balance vs SUM(wallet_transaction.amount)） ===');
  const drift = await q(c, `
    SELECT w.user_id, w.balance, COALESCE(t.s,0) AS txn_sum,
           ROUND(w.balance - COALESCE(t.s,0), 2) AS drift
    FROM wallet w
    LEFT JOIN (SELECT user_id, SUM(amount) s FROM wallet_transaction GROUP BY user_id) t
      ON t.user_id = w.user_id
    WHERE ROUND(w.balance - COALESCE(t.s,0), 2) <> 0
    ORDER BY ABS(w.balance - COALESCE(t.s,0)) DESC`);
  log('漂移行数 = ' + drift.length);
  for (const r of drift) log(J(r));

  log('\n=== B. user 1114 现状（e2e 夹具？） ===');
  for (const r of await q(c, `SELECT id,username,nickname,role,status,created_at FROM user WHERE id=1114`)) log(J(r));
  for (const r of await q(c, `SELECT id,user_id,worker_no,can_take_order,status,created_at FROM worker WHERE user_id=1114`)) log('worker ' + J(r));
  for (const r of await q(c, `SELECT id,user_id,balance FROM wallet WHERE user_id=1114`)) log('wallet ' + J(r));
  const t1144 = await q(c, `SELECT COUNT(*) n, COALESCE(SUM(amount),0) s, MIN(created_at) mn, MAX(created_at) mx FROM wallet_transaction WHERE user_id=1114`);
  log('txn ' + J(t1144[0]));
  for (const r of await q(c, `SELECT id,worker_id,user_id,amount,status,reject_reason,created_at FROM withdraw_request WHERE user_id=1114 OR worker_id=(SELECT id FROM worker WHERE user_id=1114)`)) log('wr ' + J(r));
  for (const r of await q(c, `SELECT id,worker_id,real_name,qr_media_id,status,created_at FROM worker_withdraw_account WHERE worker_id IN (SELECT id FROM worker WHERE user_id=1114)`)) log('wwa ' + J(r));
  for (const r of await q(c, `SELECT id,jti,kind,binding_id,revoked,expire_at FROM auth_token WHERE user_id=1114 ORDER BY id LIMIT 5`)) log('tok ' + J(r));
  log('tok_count ' + J((await q(c, `SELECT COUNT(*) n FROM auth_token WHERE user_id=1114`))[0]));

  log('\n=== C. 孤儿流水（idempotency_key 指向已不存在的 withdraw_request） ===');
  const orph = await q(c, `
    SELECT wt.id, wt.user_id, wt.change_type, wt.amount, wt.idempotency_key, wt.created_at
    FROM wallet_transaction wt
    WHERE wt.idempotency_key LIKE 'withdraw:%' OR wt.idempotency_key LIKE 'withdraw\\_reject:%'
    ORDER BY wt.id`);
  for (const r of orph) log(J(r));

  log('\n=== D. 引用计数：withdraw 用途媒体被谁引用 ===');
  for (const r of await q(c, `SELECT id,file_key,media_type,uploader_id,original_name FROM media WHERE media_type IN ('withdraw_qr','withdraw_proof') ORDER BY id`)) {
    const usedByWwa = await q(c, `SELECT id,worker_id FROM worker_withdraw_account WHERE qr_media_id=?`, [r.id]);
    const usedByWr = await q(c, `SELECT id,status FROM withdraw_request WHERE payout_proof_media_id=?`, [r.id]);
    log(J({ ...r, ref_wwa: usedByWwa, ref_wr: usedByWr }));
  }

  log('\n=== E. 目标账号在其它业务表里的行（查漏） ===');
  const T = [1243, 1244, 1245];
  const checks = [
    ['chat_conversation', 'user_id'], ['chat_conversation_member', 'user_id'], ['chat_conversation_assign', 'worker_user_id'],
    ['order', 'user_id'], ['order', 'worker_id'], ['order_appeal', 'user_id'], ['order_settlement', 'worker_id'],
    ['complaint', 'user_id'], ['user_feedback', 'user_id'], ['user_level_log', 'user_id'], ['user_oauth', 'user_id'],
    ['recharge_request', 'user_id'], ['recharge_admin', 'user_id'], ['refund_request', 'user_id'],
    ['ai_conversation', 'user_id'], ['leaderboard_entry', 'worker_id'], ['leaderboard_adjustment', 'worker_id'],
    ['top_worker', 'worker_id'], ['forum_like', 'user_id'], ['order_tip', 'to_user_id'], ['order_tip', 'from_user_id'],
  ];
  for (const [tbl, col] of checks) {
    const ph = T.map(() => '?').join(',');
    const r = await q(c, `SELECT COUNT(*) n FROM \`${tbl}\` WHERE \`${col}\` IN (${ph})`, T);
    if (r[0].n > 0) log(`${tbl}.${col}: ${r[0].n}`);
  }
  log('(以上未列出的表 = 0 行)');

  log('\n=== F. withdraw_request 表当前全部行 ===');
  for (const r of await q(c, `SELECT id,worker_id,user_id,amount,status,reject_reason FROM withdraw_request`)) log(J(r));

  log('\n=== G. worker_withdraw_account 表当前全部行 ===');
  for (const r of await q(c, `SELECT id,worker_id,real_name,qr_media_id,status FROM worker_withdraw_account`)) log(J(r));

  log('\n=== H. 目标账号 auth_token 计数 ===');
  for (const r of await q(c, `SELECT user_id, kind, revoked, COUNT(*) n FROM auth_token WHERE user_id IN (1243,1244,1245) GROUP BY user_id,kind,revoked ORDER BY user_id`)) log(J(r));

  await c.end();
  console.log('OK -> ' + LOG);
})().catch((e) => { log('FAILED: ' + e.message); console.error(e.message); process.exit(1); });
