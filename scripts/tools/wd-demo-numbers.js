#!/usr/bin/env node
/** 一次性：取报告所需的精确数字。 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));
const CFG = { host: '127.0.0.1', port: 3306, user: 'fish_app', password: 'c1c8a698df50860b182493933c5e1cbb3790fe5322b29b15', database: 'fish_platform', charset: 'utf8mb4' };
(async () => {
  const c = await mysql.createConnection(CFG);
  const o = [];
  const rows = async (s, p = []) => (await c.query(s, p))[0];
  const one = async (s, p = []) => (await c.query(s, p))[0][0];

  o.push('--- 1114(worker01) 今日新增流水 ---');
  for (const r of await rows(`SELECT change_type, COUNT(*) n, SUM(amount) s FROM wallet_transaction
      WHERE user_id=1114 AND created_at>='2026-10-10 22:00:00' GROUP BY change_type`)) o.push('  ' + JSON.stringify(r));
  const t = await one(`SELECT COUNT(*) n, SUM(amount) s FROM wallet_transaction WHERE user_id=1114 AND created_at>='2026-10-10 22:00:00'`);
  o.push('  今日合计 n=' + t.n + ' sum=' + t.s);
  o.push('  目前钱包余额 = ' + (await one(`SELECT balance FROM wallet WHERE user_id=1114`)).balance);
  o.push('  该用户流水总条数(含历史) = ' + (await one(`SELECT COUNT(*) n FROM wallet_transaction WHERE user_id=1114`)).n);
  o.push('  该用户全流水之和 = ' + (await one(`SELECT SUM(amount) s FROM wallet_transaction WHERE user_id=1114`)).s);

  o.push('--- 悬空行 ---');
  for (const r of await rows(`SELECT id,worker_id,division_id FROM worker_division_permission
      WHERE NOT EXISTS (SELECT 1 FROM worker w WHERE w.id=worker_division_permission.worker_id)`)) o.push('  wdp ' + JSON.stringify(r));
  for (const r of await rows(`SELECT id,boss_user_id,worker_user_id,status FROM worker_identity_binding
      WHERE NOT EXISTS (SELECT 1 FROM user u WHERE u.id=worker_identity_binding.worker_user_id)
         OR NOT EXISTS (SELECT 1 FROM user u2 WHERE u2.id=worker_identity_binding.boss_user_id)`)) o.push('  binding ' + JSON.stringify(r));

  o.push('--- 今日(10-11)创建且仍在的账号 ---');
  for (const r of await rows(`SELECT id,username,role,created_at FROM user WHERE created_at>='2026-10-10 16:00:00' ORDER BY id`)) o.push('  ' + JSON.stringify(r));

  o.push('--- 媒体 268 / 274 详情 ---');
  for (const r of await rows(`SELECT id,file_key,media_type,original_name,uploader_id,size_bytes,created_at FROM media WHERE id IN (268,274)`)) o.push('  ' + JSON.stringify(r));

  fs.writeFileSync(path.join(__dirname, '..', 'tmp', 'final-numbers.txt'), o.join('\n'));
  console.log(o.join('\n'));
  await c.end();
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
