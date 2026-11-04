/**
 * 「分部下架 = 其内容不再公开」· 公开读路径收口自证（2026-10-08）
 *
 * 运行：node scripts/tools/public-division-scope-e2e.js
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 背景（负责人报障的同一类问题）
 * ─────────────────────────────────────────────────────────────────────────────
 * 负责人已在管理端下架 4 个分部（`division.status = 0`、`under_construction = 1`：三角洲手游/端游、
 * 无畏契约手游/端游），但 `/api/v1/public/products` **仍返回挂在已下架分部的上架商品**
 * —— 公开查询只过滤 `product.status / service_status`，不看所属分部状态。
 *
 * 收口语义（**唯一一处** `server/src/modules/division/public-division-scope.ts`）：
 * **分部下架 = 其名下内容不再公开**；未挂分部（`division_id IS NULL`）不受约束。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 断言（期望值**一律从 DB 推导**，禁止写死 5/31 这类数字）
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① `/public/products` 全量：**不得出现**任何属于已下架分部的商品；
 *  ② 已上架分部的商品条数与 DB 同口径一致（逐分部 + 合计）；请求已下架分部 → 空列表；
 *  ③ `/public/players`：只在已下架分部有接单权限的打手不得出现；请求已下架分部 → 空列表；
 *  ④ `/public/leaderboard`：请求已下架分部 → 空榜；全站榜接口仍 200（语义不变）；
 *  ⑤ `/divisions`、`/divisions/grouped`：本就只下发 `status=1` → 断言"无泄漏"（对照物）。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 负向/变异验证
 * ─────────────────────────────────────────────────────────────────────────────
 * 注释掉 `ProductService.publicList()` 里 `where.divisionId = publicDivisionFindWhere(...)`
 * 那一行 → 断言①**必然变红**（脚本会打印"泄漏条数 + 泄漏分部 id"）。恢复 → 绿。
 *
 * ⚠️ 本脚本**只读**（全部 GET + SELECT），不创建/修改/删除任何数据。
 */
'use strict';

const path = require('path');
const { openDb } = require('./public-catalog-expectation');

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

async function get(p) {
  const r = await fetch(BASE + p);
  let json = null;
  try {
    json = await r.json();
  } catch {
    /* 空响应体 */
  }
  return { status: r.status, data: json?.data, message: json?.message };
}

/** 取全量公开商品（自动翻页；期望值来自 DB，页大小不写死断言） */
async function fetchAllPublicProducts(query = '') {
  const all = [];
  let total = null;
  for (let page = 1; page <= 50; page += 1) {
    const sep = query ? '&' : '?';
    const r = await get(`/public/products${query}${sep}page=${page}&pageSize=100`);
    if (r.status !== 200) return { status: r.status, list: all, total, message: r.message };
    const list = r.data?.list ?? [];
    total = Number(r.data?.total ?? all.length + list.length);
    all.push(...list);
    if (list.length === 0 || all.length >= total) break;
  }
  return { status: 200, list: all, total };
}

(async () => {
  console.log('=== 「分部下架 = 内容不再公开」公开读路径收口自证（只读）===');
  const db = await openDb();
  try {
    // ---------- DB 期望值（全部运行时取数） ----------
    const [divRows] = await db.query('SELECT id, code, name, status FROM division ORDER BY id');
    const activeDivs = divRows.filter((d) => Number(d.status) === 1).map((d) => String(d.id));
    const delistedDivs = divRows.filter((d) => Number(d.status) !== 1).map((d) => String(d.id));
    console.log(`    DB 分部：上架 [${activeDivs.join(', ')}] / 已下架 [${delistedDivs.join(', ')}]（期望值全部来自 DB）`);

    const [expProductRows] = await db.query(
      `SELECT p.division_id AS divisionId, COUNT(*) AS c
         FROM product p LEFT JOIN division d ON d.id = p.division_id
        WHERE p.status = 1 AND p.service_status = 1 AND (p.division_id IS NULL OR d.status = 1)
        GROUP BY p.division_id`,
    );
    const expProductTotal = expProductRows.reduce((s, r) => s + Number(r.c), 0);
    const [leakRows] = await db.query(
      `SELECT COUNT(*) AS c FROM product p JOIN division d ON d.id = p.division_id
        WHERE p.status = 1 AND p.service_status = 1 AND d.status <> 1`,
    );
    const dbLeakCount = Number(leakRows[0]?.c ?? 0);
    console.log(`    DB 期望：公开商品应 ${expProductTotal} 条（其中"属于已下架分部"的 ${dbLeakCount} 条**必须不出现**）`);
    console.log(`    DB 逐分部期望：${expProductRows.map((r) => `${r.divisionId ?? 'NULL'}=${r.c}`).join(' / ')}`);

    const [expPlayerRows] = await db.query(
      `SELECT w.id AS workerId FROM worker w
         JOIN user u ON u.id = w.user_id
        WHERE w.status = 1 AND u.status = 1 AND w.can_take_order = 1
          AND EXISTS (SELECT 1 FROM worker_division_permission p JOIN division d ON d.id = p.division_id
                       WHERE p.worker_id = w.id AND p.can_take_order = 1 AND d.status = 1)
        ORDER BY w.id`,
    );
    const expPlayerIds = expPlayerRows.map((r) => String(r.workerId));
    const [onlyDelistedRows] = await db.query(
      `SELECT w.id AS workerId FROM worker w
        WHERE w.status = 1 AND w.can_take_order = 1
          AND NOT EXISTS (SELECT 1 FROM worker_division_permission p JOIN division d ON d.id = p.division_id
                           WHERE p.worker_id = w.id AND p.can_take_order = 1 AND d.status = 1)`,
    );
    const onlyDelistedIds = onlyDelistedRows.map((r) => String(r.workerId));
    console.log(`    DB 期望：找陪玩应 ${expPlayerIds.length} 人 [${expPlayerIds.join(', ')}]；只在已下架分部有权限的 ${onlyDelistedIds.length} 人 [${onlyDelistedIds.join(', ')}] 必须不出现`);

    // ---------- ① /public/products：不得泄漏已下架分部的商品 ----------
    const all = await fetchAllPublicProducts();
    ok('① /public/products 200', all.status === 200, `status=${all.status} 返回 ${all.list.length} 条 / total=${all.total}`);
    const leaked = all.list.filter((p) => delistedDivs.includes(String(p.divisionId ?? '')));
    ok(
      '① 已下架分部名下商品**不出现在**公开列表',
      leaked.length === 0,
      leaked.length
        ? `泄漏 ${leaked.length} 条：${leaked.slice(0, 5).map((p) => `id=${p.id}(div=${p.divisionId})`).join(', ')}${leaked.length > 5 ? ' …' : ''}`
        : `已下架分部 [${delistedDivs.join(',')}] 零泄漏`,
    );
    ok('② 公开商品条数与 DB 同口径一致', all.list.length === expProductTotal && Number(all.total) === expProductTotal, `接口 ${all.list.length}/total ${all.total} vs DB ${expProductTotal}`);

    // 逐分部一致（只对已上架分部断言"数量一致"；已下架分部必须是 0）
    for (const d of activeDivs) {
      const exp = Number(expProductRows.find((r) => String(r.divisionId) === d)?.c ?? 0);
      const r = await fetchAllPublicProducts(`?divisionId=${d}`);
      ok(`② 已上架分部 ${d} 商品数与 DB 一致`, r.list.length === exp && r.list.every((p) => String(p.divisionId) === d), `接口 ${r.list.length} vs DB ${exp}`);
    }
    for (const d of delistedDivs) {
      const r = await fetchAllPublicProducts(`?divisionId=${d}`);
      ok(`② 请求已下架分部 ${d} → 空列表`, r.list.length === 0 && Number(r.total ?? 0) === 0, `接口 ${r.list.length} 条 / total ${r.total}`);
    }

    // ---------- ③ /public/players ----------
    const players = await get('/public/players?page=1&pageSize=50');
    const playerIds = (players.data?.list ?? []).map((w) => String(w.workerId));
    const leakedPlayers = playerIds.filter((id) => onlyDelistedIds.includes(id));
    ok('③ /public/players 200', players.status === 200, `status=${players.status} 返回 ${playerIds.length} 人`);
    ok(
      '③ 只在已下架分部有接单权限的打手**不出现**在找陪玩',
      leakedPlayers.length === 0,
      leakedPlayers.length ? `泄漏 workerId=${leakedPlayers.join(',')}` : `候选 [${onlyDelistedIds.join(',') || '无'}] 未出现`,
    );
    ok('③ 找陪玩名单与 DB 同口径一致', playerIds.length === expPlayerIds.length && playerIds.every((id) => expPlayerIds.includes(id)), `接口 [${playerIds.join(',')}] vs DB [${expPlayerIds.join(',')}]`);
    for (const d of delistedDivs) {
      const r = await get(`/public/players?divisionId=${d}&page=1&pageSize=50`);
      const n = (r.data?.list ?? []).length;
      ok(`③ 请求已下架分部 ${d} 的找陪玩 → 空列表`, r.status === 200 && n === 0, `status=${r.status} 返回 ${n} 人`);
    }

    // ---------- ④ /public/leaderboard ----------
    for (const d of delistedDivs) {
      const r = await get(`/public/leaderboard?divisionId=${d}`);
      const n = (r.data?.list ?? []).length;
      ok(`④ 请求已下架分部 ${d} 的榜单 → 空榜`, r.status === 200 && n === 0, `status=${r.status} 返回 ${n} 行`);
    }
    const globalBoard = await get('/public/leaderboard');
    ok('④ 全站榜接口仍 200（本次**未改**全站榜口径）', globalBoard.status === 200, `status=${globalBoard.status} 返回 ${(globalBoard.data?.list ?? []).length} 行`);

    // ---------- ⑤ /divisions 对照物 ----------
    const divs = await get('/divisions');
    const divIds = (Array.isArray(divs.data) ? divs.data : []).map((d) => String(d.id));
    const grouped = await get('/divisions/grouped');
    const groupedIds = [];
    for (const g of Array.isArray(grouped.data) ? grouped.data : []) {
      for (const d of g.divisions ?? []) groupedIds.push(String(d.id));
    }
    ok(
      '⑤ /divisions 只下发已上架分部（对照物：无泄漏）',
      divIds.every((id) => activeDivs.includes(id)) && divIds.length === activeDivs.length,
      `接口 [${divIds.join(',')}] vs DB 上架 [${activeDivs.join(',')}]`,
    );
    ok(
      '⑤ /divisions/grouped 只下发已上架分部（对照物：无泄漏）',
      groupedIds.every((id) => activeDivs.includes(id)) && groupedIds.length === activeDivs.length,
      `接口 [${groupedIds.join(',')}] vs DB 上架 [${activeDivs.join(',')}]`,
    );
  } finally {
    await db.end();
  }

  console.log(`\n=== 汇总：PASS ${pass} / FAIL ${fail} ===`);
  if (fail > 0) {
    console.log('（断言①红 = 公开商品仍在泄漏已下架分部的商品：检查 ProductService.publicList 的分部可见性条件；');
    console.log('  本次收口唯一一处定义在 server/src/modules/division/public-division-scope.ts。）');
  }
  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => {
  console.error(`\n脚本异常中止：${e?.stack || e}`);
  process.exit(1);
});
