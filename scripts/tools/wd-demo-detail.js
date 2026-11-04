#!/usr/bin/env node
/** 一次性：报告用的每表删除行数明细（按基线快照反推）。 */
const fs = require('fs');
const path = require('path');
const mysql = require(path.join(__dirname, '..', '..', 'server', 'node_modules', 'mysql2', 'promise'));
const CFG = { host: '127.0.0.1', port: 3306, user: 'fish_app', password: 'c1c8a698df50860b182493933c5e1cbb3790fe5322b29b15', database: 'fish_platform', charset: 'utf8mb4' };
(async () => {
  const c = await mysql.createConnection(CFG);
  const one = async (s, p = []) => (await c.query(s, p))[0][0];
  const o = [];
  o.push('账号接口(DELETE /admin/users/:id)事务内连带删除 —— 由基线快照精确反推：');
  o.push('  wallet_transaction: 基线 447 → 现 ' + (await one(`SELECT COUNT(*) n FROM wallet_transaction`)).n
    + '   Δ100（1243:97 + 1244:3）');
  o.push('  wallet:             基线  37 → 现 ' + (await one(`SELECT COUNT(*) n FROM wallet`)).n + '   Δ3（1243/1244/1245 各 1）');
  o.push('  auth_token(账号本体): 基线 1243:40 + 1244:8 + 1245:4 = 52 → 现 '
    + (await one(`SELECT COUNT(*) n FROM auth_token WHERE user_id IN (1243,1244,1245) OR binding_id=341`)).n);
  o.push('  worker 档案:        基线 2（402/403）→ 现 ' + (await one(`SELECT COUNT(*) n FROM worker WHERE id IN (402,403)`)).n);
  o.push('  user 账号本体:      基线 3（1243/1244/1245）→ 现 ' + (await one(`SELECT COUNT(*) n FROM user WHERE id IN (1243,1244,1245)`)).n);
  o.push('  user_notification:  脚本删 104（1243:102 + 1244:2）');
  o.push('  media:              脚本删 5 行 + 5 个磁盘文件');
  o.push('  withdraw_request:   脚本删 1（id=45；此前 e2e 已自清 4..71 中除 45 外的行）');
  o.push('  worker_withdraw_account: 脚本删 1（id=26）');
  o.push('  worker_division_permission: 0（该批次无分部授权行）');
  o.push('  worker_identity_binding: 0 物理删（341 置 unbound，历史行保留 ✓ 设计如此）');
  o.push('');
  o.push('1243 的流水条数核对: ' + JSON.stringify(await one(`SELECT COUNT(*) n FROM wallet_transaction WHERE user_id=1243`)));
  o.push('1243 wallet_transaction 是否与 e2e_topup 键留痕一致: ' + JSON.stringify(
    await one(`SELECT COUNT(*) n FROM wallet_transaction WHERE idempotency_key LIKE 'wd-e2e-topup:1243:%'`)));
  o.push('剩余 wd-e2e-topup 流水: ' + JSON.stringify(await one(`SELECT COUNT(*) n FROM wallet_transaction WHERE idempotency_key LIKE 'wd-e2e-topup:%'`)));
  o.push('剩余 wd-real-topup 流水: ' + JSON.stringify(await one(`SELECT COUNT(*) n FROM wallet_transaction WHERE idempotency_key LIKE 'wd-real-topup:%'`)));
  fs.writeFileSync(path.join(__dirname, '..', 'tmp', 'delete-detail.txt'), o.join('\n'));
  console.log(o.join('\n'));
  await c.end();
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
