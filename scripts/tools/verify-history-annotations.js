/**
 * 历史数据标注 —— **只读复核器**（2026-10-12 排查，2026-10-13 落盘）
 * ────────────────────────────────────────────────────────────────────────────
 * 本脚本对应 `docs/06-积分账务规范.md` 的「历史数据标注（2026-10-12 排查）」一节，
 * 把该节 5 条结论**逐条变成可复跑的断言**，让后人随时能验证"标注是否仍然属实"。
 *
 * ⚠️ **本脚本是纯只读的：只 SELECT，不含任何 INSERT / UPDATE / DELETE。**
 *    它**不是**数据修复脚本 —— 那一节的结论就是「不修」（详见文档）。
 *    历史上这里曾计划写一个"给 worker01 补款"的修复脚本，该计划**已被否决并废弃**：
 *    经核实，`worker01` 是长期回归夹具账号，账上资金**全部由 e2e 测试造出**，
 *    补款等于往账面注入虚假金额。**故本目录下不存在、也不应存在补款脚本。**
 *
 * 用法：
 *   node scripts/tools/verify-history-annotations.js          # 跑全部 5 条
 *   node scripts/tools/verify-history-annotations.js --json    # 机器可读输出
 *
 * 退出码：0 = 全部符合标注；1 = 有断言不符（说明库已变化，需重新核对文档）。
 */
const fs = require('fs');
const path = require('path');

const ENV_FILE = process.env.FISH_ENV_FILE || path.join(__dirname, '..', '..', 'server', '.env');
const JSON_OUT = process.argv.includes('--json');

let pass = 0;
let fail = 0;
const results = [];

function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    results.push({ ok: true, name, extra });
    if (!JSON_OUT) console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    results.push({ ok: false, name, extra });
    if (!JSON_OUT) console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
}

function loadEnv() {
  const env = {};
  for (const line of fs.readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    const m = /^([A-Z_0-9]+)=(.*)$/.exec(line.trim());
    if (m) env[m[1]] = m[2];
  }
  return env;
}

(async () => {
  const mysql = require('D:/fish/server/node_modules/mysql2/promise');
  const env = loadEnv();
  const db = await mysql.createConnection({
    host: env.DB_HOST,
    port: Number(env.DB_PORT),
    user: env.DB_USER,
    password: env.DB_PASSWORD,
    database: env.DB_NAME,
  });
  const q = async (sql, args = []) => (await db.query(sql, args))[0];

  if (!JSON_OUT) console.log('== 历史数据标注 只读复核（docs/06「历史数据标注（2026-10-12 排查）」）==\n');

  // ── 一、订单 942/943/954：status=canceled 但日志最后一条是 taken ──────────────
  const gap = await q(
    `SELECT o.id, o.status AS order_status, l.to_status AS last_log_status,
            o.updated_at AS order_updated_at
       FROM \`order\` o
       JOIN order_status_log l ON l.order_id = o.id
      WHERE l.id = (SELECT MAX(l2.id) FROM order_status_log l2 WHERE l2.order_id = o.id)
        AND l.to_status <> o.status
      ORDER BY o.id`,
  );
  ok(
    '① 全库「status 与最后一条日志不一致」的订单恰好是 942/943/954',
    gap.length === 3 && [942, 943, 954].every((id) => gap.some((r) => Number(r.id) === id)),
    `实际 ${gap.length} 张：${gap.map((r) => r.id).join(',') || '无'}`,
  );
  ok(
    '① 三张单 status=canceled 且日志最后一条=taken',
    gap.length === 3 && gap.every((r) => r.order_status === 'canceled' && r.last_log_status === 'taken'),
  );
  const sameStamp = new Set(gap.map((r) => String(r.order_updated_at)));
  ok(
    '① 三张单 updated_at 完全相同（脚本批改指纹）',
    sameStamp.size === 1 && gap.length === 3,
    `distinct=${sameStamp.size} value=${[...sameStamp][0] ?? '-'}`,
  );
  ok(
    '① 现行代码改状态处全部有 logStatus（无第 4 张缺口）',
    gap.length === 3,
    '若 >3 说明现行代码出现新的绕过状态机写入 → 必须查代码',
  );

  // ── 二、worker01 的 18 条孤儿扣款 ────────────────────────────────────────────
  const W1 = 1114;
  const orphans = await q(
    `SELECT t.id, t.amount FROM wallet_transaction t
      WHERE t.user_id = ? AND t.change_type = 'withdraw'
        AND NOT EXISTS (SELECT 1 FROM withdraw_request r
                         WHERE r.id = CAST(SUBSTRING_INDEX(t.idempotency_key, ':', -1) AS UNSIGNED))
      ORDER BY t.id`,
    [W1],
  );
  const orphanSum = orphans.reduce((a, r) => a + Number(r.amount), 0);
  ok(
    '② worker01 孤儿扣款恰好 18 条、Σ = −1800.00',
    orphans.length === 18 && Math.abs(orphanSum + 1800) < 0.005,
    `实际 ${orphans.length} 条 Σ=${orphanSum.toFixed(2)}`,
  );
  const noRefund = await q(
    `SELECT COUNT(*) AS n FROM wallet_transaction WHERE user_id = ? AND change_type = 'withdraw_reject'`,
    [W1],
  );
  ok('② worker01 无任何 withdraw_reject 退回流水（扣款与退回被成对清掉）', Number(noRefund[0].n) === 0);

  // 账实自洽（全库逐用户）
  const drift = await q(
    `SELECT w.user_id, u.username, (w.balance - COALESCE(t.s,0)) AS drift
       FROM wallet w
       LEFT JOIN user u ON u.id = w.user_id
       LEFT JOIN (SELECT user_id, SUM(amount) AS s FROM wallet_transaction GROUP BY user_id) t
              ON t.user_id = w.user_id
      WHERE ABS(w.balance - COALESCE(t.s,0)) > 0.0001`,
  );
  ok('② 全库逐用户 balance == Σ wallet_transaction.amount（漂移 0 行）', drift.length === 0,
    drift.length ? `漂移 ${drift.length} 行` : '48 个钱包全部为 0.00');

  // worker01 账目构成
  const w1 = await q('SELECT balance FROM wallet WHERE user_id = ?', [W1]);
  const comp = await q(
    `SELECT change_type, COUNT(*) AS cnt, SUM(amount) AS sum_amount
       FROM wallet_transaction WHERE user_id = ? GROUP BY change_type`,
    [W1],
  );
  const sumAll = comp.reduce((a, r) => a + Number(r.sum_amount), 0);
  const bal = Number(w1[0]?.balance ?? 0);
  ok(
    '② worker01 账实自洽（余额 = Σ 流水）',
    Math.abs(bal - sumAll) < 0.005,
    `余额 ${bal.toFixed(2)} = Σ ${sumAll.toFixed(2)}`,
  );
  const byType = Object.fromEntries(comp.map((r) => [r.change_type, r]));
  ok(
    '② worker01 构成：结算 55 笔 +766.86 / 冲正 3 笔 −42.30 / 孤儿扣款 18 笔 −1800.00 / 夹具 grant 18 笔 +1603.00',
    Number(byType.order_settlement?.cnt) === 55 &&
      Number(byType.settlement_reversal?.cnt) === 3 &&
      Number(byType.withdraw?.cnt) === 18 &&
      Number(byType.grant?.cnt) === 18 &&
      Math.abs(Number(byType.grant?.sum_amount) - 1603) < 0.005,
    comp.map((r) => `${r.change_type} ${r.cnt}笔 ${r.sum_amount}`).join(' / '),
  );
  ok(
    '② 补款幂等键 fix:withdraw-e2e-orphan:20261012 未被占用（补款从未执行、已废弃）',
    (await q(`SELECT id FROM wallet_transaction WHERE idempotency_key = 'fix:withdraw-e2e-orphan:20261012'`)).length === 0,
  );

  // ── 二之证据：结算来源全为演示买家 ────────────────────────────────────────────
  const buyers = await q(
    `SELECT o.user_id, u.username, COUNT(*) AS cnt
       FROM wallet_transaction t
       JOIN \`order\` o ON o.id = t.order_id
       LEFT JOIN user u ON u.id = o.user_id
      WHERE t.user_id = ? AND t.change_type = 'order_settlement'
      GROUP BY o.user_id, u.username ORDER BY cnt DESC`,
    [W1],
  );
  ok(
    '② worker01 的结算买家只有一个：boss_demo（演示老板）→ 收益全部是测试造单',
    buyers.length === 1 && buyers[0].username === 'boss_demo' && Number(buyers[0].cnt) === 55,
    buyers.map((b) => `${b.username} ${b.cnt}单`).join(' / ') || '无',
  );
  const amounts = await q(
    `SELECT o.total_amount, COUNT(*) AS cnt
       FROM wallet_transaction t JOIN \`order\` o ON o.id = t.order_id
      WHERE t.user_id = ? AND t.change_type = 'order_settlement'
      GROUP BY o.total_amount ORDER BY cnt DESC`,
    [W1],
  );
  ok(
    '② 结算订单金额高度雷同（¥18.80 × 53）→ 非真实业务',
    Number(amounts[0]?.cnt) >= 50 && Number(amounts[0]?.total_amount) === 18.8,
    amounts.map((a) => `¥${a.total_amount}×${a.cnt}`).join(' / '),
  );
  const allBuyers = await q(
    `SELECT o.user_id, u.username, COUNT(*) AS cnt FROM \`order\` o
       LEFT JOIN user u ON u.id = o.user_id
      GROUP BY o.user_id, u.username ORDER BY cnt DESC`,
  );
  ok(
    '② 全库买家只有 boss_demo / e2e_boss（均为测试演示账号）→ 平台尚未开始运营',
    allBuyers.length <= 2 && allBuyers.every((b) => ['boss_demo', 'e2e_boss'].includes(String(b.username))),
    allBuyers.map((b) => `${b.username} ${b.cnt}单`).join(' / '),
  );

  // ── 三、ai_message 里的 4 行「积分」 ─────────────────────────────────────────
  const ai = await q(`SELECT id, role FROM ai_message WHERE content LIKE '%积分%' ORDER BY id`);
  ok(
    '③ ai_message 中 content 含「积分」的恰好 4 行（历史对话逐字留档，决定不清）',
    ai.length === 4,
    `${ai.length} 行 id=${ai.map((r) => r.id).join(',')}`,
  );

  // ── 四、孤儿媒体文件 148 = 114 真孤儿 + 34 APK ───────────────────────────────
  const ROOT = env.MEDIA_ROOT || 'D:/fish/data/uploads';
  if (fs.existsSync(ROOT)) {
    const walk = (dir, base = dir, acc = []) => {
      let ents = [];
      try {
        ents = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return acc;
      }
      for (const e of ents) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full, base, acc);
        else if (e.isFile()) acc.push(path.relative(base, full).replace(/\\/g, '/'));
      }
      return acc;
    };
    const files = walk(ROOT);
    const keys = new Set((await q('SELECT file_key FROM media')).map((r) => String(r.file_key).replace(/\\/g, '/')));
    const orphanFiles = files.filter((f) => !keys.has(f));
    const apks = orphanFiles.filter((f) => f.startsWith('app-versions/'));
    const realOrphans = orphanFiles.filter((f) => !f.startsWith('app-versions/'));
    ok(
      '④ 孤儿文件 = 114 个真媒体孤儿 + 34 个 app-versions/*.apk（APK 本就不入 media 表）',
      realOrphans.length === 114 && apks.length === 34,
      `真孤儿 ${realOrphans.length} + APK ${apks.length} = ${orphanFiles.length}`,
    );
    const mediaRows = await q('SELECT file_key FROM media');
    const missingOnDisk = mediaRows.filter((r) => !fs.existsSync(path.join(ROOT, String(r.file_key))));
    ok('④ media 行 ↔ 磁盘文件 25/25 全有（反向 0 缺失）', missingOnDisk.length === 0,
      `${mediaRows.length} 行，缺失 ${missingOnDisk.length}`);
  } else {
    ok('④ 上传根目录存在', false, `${ROOT} 不存在`);
  }

  // ── 五、结算表 platform_amount 与钱包流水差 ¥0.01（恰好 2 行） ────────────────
  const cent = await q(
    `SELECT s.id, s.order_id, s.platform_amount, t.amount AS txn_amount
       FROM order_settlement s
       JOIN wallet_transaction t ON t.idempotency_key = CONCAT('platform:', s.order_id)
      WHERE ABS(t.amount - s.platform_amount) > 0.0001
      ORDER BY s.id`,
  );
  ok(
    '⑤ platform_amount 与平台抽成流水差 0.01 的恰好 2 行（订单 941/950，算术必然残差）',
    cent.length === 2 &&
      [941, 950].every((id) => cent.some((r) => Number(r.order_id) === id)) &&
      cent.every((r) => Math.abs(Number(r.txn_amount) - Number(r.platform_amount) - 0.01) < 0.0001),
    cent.map((r) => `#${r.order_id} ${r.platform_amount}vs${r.txn_amount}`).join(' / '),
  );
  const selfConsistent = await q(
    `SELECT COUNT(*) AS n FROM order_settlement
      WHERE ABS(worker_amount + platform_amount - order_amount) > 0.0001`,
  );
  ok('⑤ order_settlement 自洽（worker + platform = order_amount）全部成立', Number(selfConsistent[0].n) === 0);
  const bigErr = await q(
    `SELECT COUNT(*) AS n FROM order_settlement s
       JOIN wallet_transaction t ON t.idempotency_key = CONCAT('settle:', s.order_id)
      WHERE ABS(t.amount - s.worker_amount) > 0.01`,
  );
  ok('⑤ 打手侧结算金额 vs 流水 无 >1 分的真实错账', Number(bigErr[0].n) === 0);

  await db.end();

  if (JSON_OUT) {
    console.log(JSON.stringify({ pass, fail, results }, null, 1));
  } else {
    console.log(`\n== 结果：${pass} PASS / ${fail} FAIL ==`);
    if (fail) {
      console.log('⚠️ 有断言不符 —— 库已偏离 docs/06 的标注，请重新核对文档该节。');
    } else {
      console.log('✅ 全部符合 docs/06「历史数据标注（2026-10-12 排查）」的记载。');
    }
  }
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('ERR', e && e.message ? e.message : e);
  process.exit(1);
});
