/**
 * 「管理端改完、App 还看到旧数据」· 服务端微缓存失效 **端到端自证**（2026-10-08）
 *
 * 运行：node scripts/tools/public-cache-invalidation-e2e.js
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 背景（上游已查实的缺陷）
 * ─────────────────────────────────────────────────────────────────────────────
 * `GET /api/v1/public/clubs` 挂在 `PublicCacheInterceptor` 的 **30s 进程内微缓存**上
 * （缓存键 = `req.url`，见 `server/src/common/interceptors/public-cache.interceptor.ts`），
 * 而 `club` 模块此前**没有写入侧失效钩子**（`division` / `product` / `banner` 都有）
 * → 管理端下架/修改官方馆后，**同一个 URL 最长 30s 仍返回旧数据**。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 断言链（对标验收要求 ①-④）
 * ─────────────────────────────────────────────────────────────────────────────
 *  ① 基线：`GET /public/clubs`（**不带 Authorization**，会进微缓存）→ 记 id 集合、
 *     `requestId`（微缓存命中时 requestId 与 timestamp 会**逐字复用**，这就是"命中微缓存"的铁证）
 *     + `club` 表行数与**全表指纹**（SQL）
 *  ② 管理端新增一条**测试**官方馆（专用测试超管 opsadmin）→ **立刻**（不等 30s）取**同一个 URL**
 *     → 断言新行已出现 **且 requestId 已变**（= 没吃微缓存）
 *  ③ 把它**下架**（`PUT status=0`）→ 立刻取 → 断言已消失；再**恢复上架** → 断言又出现；
 *     最后 `DELETE` → 断言消失
 *  ④ 清理与复核：删掉测试行 → `club` 表行数 == 基线、**全表指纹 == 基线**（负责人原有行一字未改），
 *     并给出行级 md5 证据
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 负向/变异验证（必须亲眼看它变红）
 * ─────────────────────────────────────────────────────────────────────────────
 * 临时注释掉 `server/src/modules/club/club.service.ts` 里 `this.invalidatePublicClubCache();`
 * 的那一行（任一处）→ 本脚本第 ② 步**必然 FAIL**，且输出会指出"requestId 与基线相同 = 命中微缓存、
 * 探针（未缓存键）却已能看到新行 = 写入其实已提交"。恢复该行 → 重新全绿。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 安全约束（硬要求，改脚本前先读）
 * ─────────────────────────────────────────────────────────────────────────────
 *  - 管理端账号**只用专用测试超管 opsadmin**（`data/temp/test-admin-credentials.json`），
 *    **绝不回退 `server/.env` 的 `ADMIN_*`**（那是负责人本人账号，登录会按单设备铁律顶掉他的会话）；
 *    命中黑名单用户名（kslingyun）直接**拒绝运行**。
 *  - **不碰负责人真实的 club / division / product 行**：只新增、修改、删除**本脚本自己创建的那一条**
 *    （名称带唯一标记 `【缓存自证…】`），且 `finally` 里无条件删除。
 *  - 断言的"同一个 URL"与基线**逐字相同**（`/public/clubs`，无任何 query）——
 *    只有失效真的发生，才会立刻看到新值；换成新 key 就变成"缓存本来就没命中"，证明不了任何东西。
 *  - 断言的期望值一律**运行时取**（基线快照 / SQL），**不写死条数**。
 */
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { openDb } = require('./public-catalog-expectation');

const BASE = process.env.E2E_BASE || 'http://127.0.0.1:3100/api/v1';
const ROOT = path.join(__dirname, '..', '..');
const CRED_FILE = path.join(ROOT, 'data', 'temp', 'test-admin-credentials.json');
/** 绝不允许出现在本脚本里的账号（负责人本人；登录会顶掉他的会话） */
const FORBIDDEN_USERS = ['kslingyun'];

/** 公开接口「运营档」期望缓存头（与服务端 `CACHE_CONTROL` 表逐个前缀逐字一致） */
const EXPECTED_PUBLIC_CACHE_CONTROL = 'private, max-age=60, stale-while-revalidate=300';
/**
 * 公开**字典/运营档**接口的登记（本脚本只做打印，不做改造）
 *
 * ⚠️ 2026-10-16 变更：`/public/home` **已移出本名单**，改为期望 `no-store`（见下 NO_STORE_ENDPOINTS）。
 * 原因：它从"只剩公告"升级为**首屏聚合**（一次给全 banners/divisions/hotProducts/players/leaderboard），
 * 其中 `players` 随**授权状态**实时变化、打手数值随**评价/展示值**实时变化 ——
 * 落在运营档 60s 就会出现"管理端设了展示值/撤了权限，首页仍显示旧值"。
 * 判定与服务端 `public-cache.interceptor.ts` 的同一个前缀登记同源（那边也同时把该路径移出 `PREFIXES` 微缓存）。
 */
const PUBLIC_OPS_ENDPOINTS = [
  '/divisions',
  '/public/clubs',
  '/public/games',
  '/public/categories',
  '/public/levels',
  '/public/site',
  '/public/about',
  '/public/privacy',
  '/public/recharge/config',
];

/** 公开「不可缓存档」（`no-store`）：内容随**授权状态/实时聚合**变化，必须下一次请求即生效 */
const NO_STORE_ENDPOINTS = ['/public/home', '/public/players', '/public/workers/1'];

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
const info = (msg) => console.log(`      ${msg}`);

/** HTTP 请求：返回 body（已解信封）、requestId、Cache-Control、耗时 */
async function http(method, p, { token, body } = {}) {
  const t0 = Date.now();
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try {
    json = await r.json();
  } catch {
    /* 空响应体 */
  }
  return {
    status: r.status,
    json,
    data: json?.data,
    requestId: json?.requestId ?? null,
    cacheControl: r.headers.get('cache-control'),
    ms: Date.now() - t0,
  };
}

/** 管理端账号：只用专用测试超管，命中黑名单直接拒绝运行（**禁止回退 .env 的 ADMIN_***） */
function resolveTestAdmin() {
  const envUser = (process.env.E2E_ADMIN_USER ?? process.env.REGRESSION_ADMIN_USER ?? '').trim();
  const envPass = process.env.E2E_ADMIN_PASSWORD ?? process.env.REGRESSION_ADMIN_PASSWORD ?? '';
  if (envUser && envPass) {
    assertNotForbidden(envUser);
    return { username: envUser, password: envPass, source: '环境变量 E2E_ADMIN_USER/E2E_ADMIN_PASSWORD' };
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(CRED_FILE, 'utf8'));
  } catch (e) {
    throw new Error(
      `读不到专用测试超管凭证 ${CRED_FILE}：${e.message}\n` +
        '→ 按硬要求**先停下问负责人**，绝不要改用负责人账号（server/.env 的 ADMIN_*）。',
    );
  }
  const first = Array.isArray(raw) ? raw[0] : raw;
  if (!first?.username || !first?.password) throw new Error(`${CRED_FILE} 里没有可用的 username/password`);
  assertNotForbidden(first.username);
  return { username: first.username, password: first.password, source: CRED_FILE };
}

function assertNotForbidden(username) {
  if (FORBIDDEN_USERS.includes(String(username).toLowerCase())) {
    throw new Error(`拒绝运行：管理端账号 ${username} 是负责人本人账号（会顶掉他的会话），本脚本只允许专用测试超管`);
  }
}

/** 行 → 稳定字符串（键排序 + Date 归一），用于行级 md5 指纹 */
function canonRow(row) {
  const out = {};
  for (const k of Object.keys(row).sort()) {
    const v = row[k];
    out[k] = v instanceof Date ? v.toISOString() : v;
  }
  return JSON.stringify(out);
}
const md5 = (s) => crypto.createHash('md5').update(s).digest('hex');

/** club 表快照：行数 + 行级 md5 + 全表指纹（**只读 SELECT**） */
async function snapshotClubs(db) {
  // mysql2 的 `query()` 返回 `[rows, fields]` —— 必须解构第一个元素，否则拿到的是 [行数组, 字段元数据]
  const [rows] = await db.query('SELECT * FROM club ORDER BY id ASC');
  const lines = rows.map((r) => ({ id: String(r.id), name: String(r.name ?? ''), md5: md5(canonRow(r)) }));
  return {
    count: rows.length,
    rows: lines,
    tableHash: md5(lines.map((l) => `${l.id}:${l.md5}`).join('|')),
  };
}

/** 从公开接口响应里取 id 集合（`/public/clubs` 返回 `{code,data:[...]}`） */
function idSetOf(res) {
  const list = Array.isArray(res.data) ? res.data : [];
  return new Set(list.map((c) => String(c.id)));
}

(async () => {
  console.log('=== 管理端写入 → 公开接口微缓存失效 · 端到端自证 ===');
  console.log(`    目标：${BASE}`);

  const cred = resolveTestAdmin();
  console.log(`    [管理端账号] ${cred.username}（来源：${cred.source}）`);
  ok('账号安全闸：不是负责人本人账号', !FORBIDDEN_USERS.includes(cred.username.toLowerCase()), `user=${cred.username}`);

  const health = await http('GET', '/health');
  ok('前置：/health 200', health.status === 200, `status=${health.status} ${health.ms}ms`);
  if (health.status !== 200) {
    console.log('\n服务未就绪，后续步骤无法进行（pm2 status fish-server / pm2 restart fish-server）。');
    process.exit(1);
  }

  // ---------- §3 缓存头口径核对（公开运营档 = max-age=60，与会话类无关）----------
  console.log('\n--- 缓存头口径（公开运营档；期望 response header === 客户端 ttlOps=60s）---');
  console.log('接口'.padEnd(28) + '| Cache-Control');
  const headerFails = [];
  for (const p of PUBLIC_OPS_ENDPOINTS) {
    const r = await http('GET', p);
    console.log(`${p.padEnd(28)}| ${r.status} ${r.cacheControl ?? '(无)'}`);
    if (r.status !== 200) headerFails.push(`${p} → HTTP ${r.status}`);
    else if (r.cacheControl !== EXPECTED_PUBLIC_CACHE_CONTROL) {
      headerFails.push(`${p} → ${r.cacheControl ?? '(无)'}（期望 ${EXPECTED_PUBLIC_CACHE_CONTROL}）`);
    }
  }
  ok(
    `缓存头：${PUBLIC_OPS_ENDPOINTS.length} 个公开运营档接口全部 = max-age=60`,
    headerFails.length === 0,
    headerFails.length ? headerFails.join(' ; ') : '逐字一致',
  );
  /**
   * 反向核对（2026-10-16 新增）：**不可缓存档**必须是 `no-store`。
   *
   * 这些路径的内容随"授权状态 / 实时聚合 / 管理端刚设的展示值"变化 ——
   * 一旦被套上 60s 或 600s 的 max-age，就等于"实时算完给你看旧的"。
   * 只断言响应头，不断言 HTTP 状态（`/public/workers/:id` 那个 id 可能已被删除/停用 → 404 也算正常，
   * 头仍然必须存在且为 no-store）。
   */
  const noStoreFails = [];
  for (const p of NO_STORE_ENDPOINTS) {
    const r = await http('GET', p);
    console.log(`${p.padEnd(28)}| ${r.status} ${r.cacheControl ?? '(无)'}`);
    if (String(r.cacheControl ?? '') !== 'no-store') {
      noStoreFails.push(`${p} → ${r.cacheControl ?? '(无)'}（期望 no-store）`);
    }
  }
  ok(
    `缓存头：${NO_STORE_ENDPOINTS.length} 个实时档接口全部 = no-store`,
    noStoreFails.length === 0,
    noStoreFails.length ? noStoreFails.join(' ; ') : '逐字一致',
  );
  // 反向护栏：会话类接口**不得**被下发公共缓存头（本轮"一个都不要动"）
  const adminLogin = await http('POST', '/auth/login', { body: { username: cred.username, password: cred.password, role: 'admin' } });
  ok('管理端登录成功（专用测试超管）', adminLogin.status === 200 && adminLogin.json?.code === 0, `status=${adminLogin.status} msg=${adminLogin.json?.message ?? ''}`);
  if (adminLogin.status !== 200) {
    console.log('\n登录失败：请确认 opsadmin 可用（不要改用负责人账号）。');
    process.exit(1);
  }
  const token = adminLogin.data.accessToken;
  const me = await http('GET', '/auth/me', { token });
  ok(
    '反向护栏：会话/鉴权类接口(/auth/me)不带公共缓存头',
    !me.cacheControl || String(me.cacheControl).includes('no-store'),
    `cache-control=${me.cacheControl ?? '(无)'}`,
  );

  // ---------- ① 基线 ----------
  const db = await openDb();
  let createdId = null;
  let baseline = null;
  let sqlBefore = null;
  let second = null;
  let probe = null;
  try {
    sqlBefore = await snapshotClubs(db);
    baseline = await http('GET', '/public/clubs');
    ok('① 基线：GET /public/clubs 200', baseline.status === 200, `status=${baseline.status} ${baseline.ms}ms`);
    const baseIds = idSetOf(baseline);
    console.log(`      基线 id 集合 = [${[...baseIds].join(', ')}]（${baseIds.size} 条，运行时取自接口，未写死）`);
    console.log(`      基线 requestId = ${baseline.requestId}`);
    console.log(`      SQL 基线：SELECT * FROM club → ${sqlBefore.count} 行，全表指纹 ${sqlBefore.tableHash}`);
    for (const r of sqlBefore.rows) console.log(`        id=${r.id}  name=${r.name}  row_md5=${r.md5}`);

    // 再取一次同一个 URL：应当命中微缓存（requestId/timestamp 逐字复用）→ 证明"缓存确实已填上"
    second = await http('GET', '/public/clubs');
    ok(
      '① 预热确认：同一 URL 第二次请求命中微缓存（requestId 复用）',
      second.requestId === baseline.requestId,
      `requestId ${baseline.requestId} → ${second.requestId}`,
    );

    // ---------- ② 管理端新增测试行 → 立刻取同一 URL ----------
    const marker = `【缓存自证-勿用】${Date.now().toString(36)}`;
    const created = await http('POST', '/admin/clubs', {
      token,
      body: { name: marker, subTitle: '微缓存失效自证', description: '本行由 public-cache-invalidation-e2e.js 创建，用后即删', badge: '官方', sortOrder: 9999, status: 1 },
    });
    ok('② 管理端新增测试官方馆 200', created.status === 200 || created.status === 201, `status=${created.status} id=${created.data?.id ?? '?'}`);
    createdId = created.data?.id != null ? String(created.data.id) : null;
    if (!createdId) throw new Error(`新增未拿到 id：${JSON.stringify(created.json)}`);

    const after = await http('GET', '/public/clubs');
    const afterIds = idSetOf(after);
    const seen = afterIds.has(createdId);
    const cacheBypassed = after.requestId !== baseline.requestId;
    console.log(`      新增 id=${createdId}（${marker}）`);
    console.log(`      新增后立刻 GET /public/clubs（同一 URL，${after.ms}ms）→ requestId=${after.requestId}`);
    console.log(`      诊断：新行出现=${seen ? '是' : '否'}；requestId 与基线${cacheBypassed ? '不同（未吃微缓存）' : '相同（= 命中微缓存，拿到的是旧 body）'}`);
    // 探针：换一个**从未缓存过**的 key → 用来说明"写入其实已提交、缺口只在微缓存"
    probe = await http('GET', `/public/clubs?_probe=${Date.now()}`);
    const probeSeen = idSetOf(probe).has(createdId);
    console.log(`      探针（未缓存键 ?_probe=…）新行出现=${probeSeen ? '是' : '否'} → ${probeSeen ? '证明写入已提交，问题只在微缓存' : '连数据库都没写上（与本缺口无关）'}`);
    ok(
      '② 失效生效：新增后**同一 URL** 立刻包含新行（不再等 30s）',
      seen && cacheBypassed,
      `seen=${seen} requestIdChanged=${cacheBypassed}`,
    );

    // ---------- ③ 下架 → 立刻取；恢复上架 → 立刻取；删除 → 立刻取 ----------
    const off = await http('PUT', `/admin/clubs/${createdId}`, { token, body: { status: 0 } });
    ok('③ 管理端下架测试行 200', off.status === 200 && off.data?.ok !== false, `status=${off.status}`);
    const afterOff = await http('GET', '/public/clubs');
    const goneAfterOff = !idSetOf(afterOff).has(createdId);
    console.log(`      下架后立刻 GET（同一 URL，${afterOff.ms}ms）→ requestId=${afterOff.requestId} 已消失=${goneAfterOff ? '是' : '否'}`);
    ok('③ 下架后**同一 URL** 立刻消失', seen && goneAfterOff, `wasSeen=${seen} goneNow=${goneAfterOff}`);

    const on = await http('PUT', `/admin/clubs/${createdId}`, { token, body: { status: 1 } });
    ok('③ 恢复上架 200', on.status === 200 && on.data?.ok !== false, `status=${on.status}`);
    const afterOn = await http('GET', '/public/clubs');
    const backAgain = idSetOf(afterOn).has(createdId);
    console.log(`      恢复上架后立刻 GET（同一 URL，${afterOn.ms}ms）→ requestId=${afterOn.requestId} 又出现=${backAgain ? '是' : '否'}`);
    ok('③ 恢复上架后**同一 URL** 立刻又出现', backAgain, `seen=${backAgain}`);

    const del = await http('DELETE', `/admin/clubs/${createdId}`, { token });
    ok('③ 管理端删除测试行 200', del.status === 200, `status=${del.status}`);
    const afterDel = await http('GET', '/public/clubs');
    const afterDelList = Array.isArray(afterDel.data) ? afterDel.data : [];
    const goneAfterDel = !afterDelList.some((c) => String(c.id) === createdId);
    const stillHasMarker = afterDelList.some((c) => String(c.name ?? '').startsWith('【缓存自证'));
    console.log(`      删除后立刻 GET（同一 URL，${afterDel.ms}ms）→ requestId=${afterDel.requestId} 已消失=${goneAfterDel ? '是' : '否'}，标记行残留=${stillHasMarker ? '是' : '否'}`);
    ok('③ 删除后**同一 URL** 立刻消失', goneAfterDel && !stillHasMarker, `gone=${goneAfterDel} markerLeft=${stillHasMarker}`);
    createdId = null; // 已删除，finally 无需再删

    // ---------- ④ 清理复核（SQL 基线证据）----------
    const sqlAfter = await snapshotClubs(db);
    console.log('\n--- ④ 清理复核（SQL 证据）---');
    console.log(`      SQL 复核：SELECT * FROM club → ${sqlAfter.count} 行（基线 ${sqlBefore.count} 行），全表指纹 ${sqlAfter.tableHash}`);
    console.log(`      基线全表指纹 ${sqlBefore.tableHash}`);
    for (const r of sqlAfter.rows) {
      const b = sqlBefore.rows.find((x) => x.id === r.id);
      console.log(`        id=${r.id}  name=${r.name}  row_md5=${r.md5}${b ? (b.md5 === r.md5 ? '  （与基线逐字一致）' : `  ⚠️ 与基线不同（基线 ${b.md5}）`) : '  ⚠️ 基线里没有这一行'}`);
    }
    ok('④ club 表行数与基线一致', sqlAfter.count === sqlBefore.count, `${sqlAfter.count} vs ${sqlBefore.count}`);
    ok('④ 负责人原有 club 行一字未改（全表指纹一致）', sqlAfter.tableHash === sqlBefore.tableHash, `${sqlAfter.tableHash}`);
    ok('④ 测试行已彻底清除（无 【缓存自证】残留）', !sqlAfter.rows.some((r) => r.name.includes('【缓存自证')), '');
  } finally {
    // 无条件清理：任何断言失败/抛异常都不留测试行
    if (createdId) {
      try {
        await http('DELETE', `/admin/clubs/${createdId}`, { token });
        console.log(`      [finally] 已删除测试行 id=${createdId}`);
      } catch (e) {
        console.log(`      [finally] 删除测试行失败（需人工检查）：${e.message}`);
      }
    }
    try {
      const final = await snapshotClubs(db);
      if (sqlBefore) {
        console.log(`      [finally] club 表最终 ${final.count} 行，全表指纹 ${final.tableHash}（基线 ${sqlBefore.count} 行 / ${sqlBefore.tableHash}）`);
      }
    } catch {
      /* ignore */
    }
    await db.end();
  }

  console.log(`\n=== 汇总：PASS ${pass} / FAIL ${fail} ===`);
  if (fail > 0) {
    console.log('（若有 FAIL：先看"诊断"行 —— requestId 与基线相同 = 命中了 30s 微缓存；');
    console.log('  探针 key 能看到新行 = 写入已提交 → 结论就是"该模块缺写入侧失效钩子"。）');
  }
  process.exit(fail > 0 ? 1 : 0);
})().catch(async (e) => {
  console.error(`\n脚本异常中止：${e?.stack || e}`);
  process.exit(1);
});
