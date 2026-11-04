/**
 * 公开目录「期望值」唯一取数入口（**期望值一律从 DB 推导，禁止在套件里写死数字**）
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 为什么必须存在（2026-10-08 事故）
 * ─────────────────────────────────────────────────────────────────────────────
 * 负责人在管理端**下架了 4 个分部**（三角洲·手游/端游、无畏契约·手游/端游）+ 2 个官方馆，
 * 于是 `/divisions/grouped` 由 5 个分部变 1 个、`/public/clubs` 由 3 条变 1 条。
 * 而回归/冒烟套件里把这些数字**写死**了（`length === 5`、`byDiv['1'] === 9`、`clubs.length === 3`），
 * 结果是「负责人改了业务配置 → 一堆套件变红」，排查时间全花在"到底是我改坏了还是配置变了"。
 *
 * **真正要守的语义只有两条**（与数字无关）：
 *   ① 公开接口**只暴露已上架的行**（`division.status=1` / `club.status=1` / `product.status=1 AND service_status=1`）；
 *   ② 接口返回的**条数与库里该口径的条数一致** —— 不漏已下架行、也不多给未上架行。
 * 所以期望值必须来自 DB（本模块），断言只比较「接口 vs DB」，配置怎么变都不会误报。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 用法
 * ─────────────────────────────────────────────────────────────────────────────
 *   const { openDb, loadExpectation, flattenGroupedDivisions } = require('../tools/public-catalog-expectation');
 *   const db = await openDb();
 *   const exp = await loadExpectation(db);   // ← 取完即可 db.end()，后面全是 HTTP
 *
 * `exp` 提供（每一项都带人类可读的**期望值来源**，用于断言输出）：
 *   exp.activeDivisions / activeDivisionIds / delistedDivisions / delistedDivisionIds
 *   exp.activeClubs     / activeClubIds     / delistedClubs     / delistedClubIds
 *   exp.activeProducts  / activeProductIds  / activeProductCountByDivision
 *   exp.delistedProducts
 *   exp.sources.{activeDivisions, activeClubs, activeProducts, delistedDivisions, delistedProducts, delistedClubs}
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 负向验证开关（**只改断言输入，不碰任何业务数据**）
 * ─────────────────────────────────────────────────────────────────────────────
 *   PUBLIC_EXPECT_INJECT_DELISTED_DIVISION=<id>   把某个"其实会出现在公开返回里"的分部 id 假装成下架行
 *   PUBLIC_EXPECT_INJECT_DELISTED_PRODUCT=<id>    同上（商品）
 * 设了它们以后 `exp.delisted*` 会多出该 id，护栏断言**必然变红** —— 用来证明"已下架不出现"这条护栏
 * 真的在判定（不是永远绿）。运行时打印醒目提示，避免被误当成真实期望值。
 *
 * ⚠️ 本模块**只读** DB（全部 SELECT），不写任何数据；也**不新增依赖**（复用 server/node_modules/mysql2）。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const ENV_FILE = process.env.PUBLIC_EXPECT_ENV_FILE || path.join(ROOT, 'server', '.env');
const MYSQL_PROMISE = path.join(ROOT, 'server', 'node_modules', 'mysql2', 'promise');

/** 读 `server/.env`（只取 DB_*；不碰 ADMIN_*） */
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

/** 只读连接（调用方负责 `await db.end()`） */
async function openDb() {
  const mysql = require(MYSQL_PROMISE);
  const env = readEnv();
  if (!env.DB_USER || !env.DB_NAME) {
    throw new Error(`无法从 ${ENV_FILE} 读到 DB_USER/DB_NAME —— 期望值必须从 DB 推导，不能退回写死数字`);
  }
  return mysql.createConnection({
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER,
    password: env.DB_PASSWORD,
    database: env.DB_NAME,
    charset: 'utf8mb4',
  });
}

/**
 * 摊平 `/divisions/grouped` 的响应体。
 *
 * ⚠️ 该接口的 `data` 是**按游戏分组的数组**：`[{ gameId, gameName, platformCount, divisions: [...] }]`，
 * 不是 `{ groups: [...] }`。历史套件里的 `data.groups ?? data.list` 取不到东西、随后落到
 * "把分组本身当分部"的兜底分支（分组数与分部数恰好相同才看不出来）—— 这里只认一种形状：
 * 依次尝试 分组数组 → `.divisions` 摊平 → `data.list` → `data` 本身。
 */
function flattenGroupedDivisions(data) {
  if (Array.isArray(data)) {
    const flat = data.flatMap((g) => (Array.isArray(g?.divisions) ? g.divisions : []));
    return flat.length ? flat : data.filter((d) => d && d.id !== undefined);
  }
  if (Array.isArray(data?.groups)) return flattenGroupedDivisions(data.groups);
  if (Array.isArray(data?.list)) return flattenGroupedDivisions(data.list);
  return [];
}

/** 命令行传入的负向验证注入（逗号分隔可多个） */
function injectedIds(envKey) {
  return String(process.env[envKey] ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function banner(lines) {
  console.log('');
  console.log('═'.repeat(78));
  for (const l of lines) console.log(`⚠️  ${l}`);
  console.log('═'.repeat(78));
  console.log('');
}

/**
 * 从 DB 读出全部期望值（**只读**）。
 * 口径与公开接口一一对应：
 *   /divisions、/divisions/grouped → `division.status = 1`
 *   /public/clubs                  → `club.status = 1`
 *   /public/products               → `product.status = 1 AND product.service_status = 1`
 *                                    **AND 所属分部已上架**（`division.status = 1`；
 *                                    `division_id IS NULL` 不受约束 —— 与
 *                                    `server/src/modules/division/public-division-scope.ts` 同口径）
 *   /public/players、/public/leaderboard 同理：分部下架 = 其内容不再公开
 *
 * ⚠️ 分部下架这条口径是 2026-10-08 服务端收口后才成立的（负责人："下架了为啥还显示"）：
 *    此前公开商品只过滤商品自身状态，导致 26 条属于已下架分部的商品仍在接口里。
 *    本模块必须与服务端**同一口径**，否则断言会把"已收口"误判成"漏了"。
 */
async function loadExpectation(db) {
  const [divisions] = await db.query(
    'SELECT id, code, name, status FROM division ORDER BY id',
  );
  const [clubs] = await db.query('SELECT id, name, status FROM club ORDER BY id');
  const [products] = await db.query(
    'SELECT id, name, division_id AS divisionId, status, service_status AS serviceStatus FROM product ORDER BY id',
  );

  const num = (v) => Number(v);
  const activeDivisions = divisions.filter((d) => num(d.status) === 1);
  const delistedDivisions = divisions.filter((d) => num(d.status) !== 1);
  const activeClubs = clubs.filter((c) => num(c.status) === 1);
  const delistedClubs = clubs.filter((c) => num(c.status) !== 1);
  /** 已上架分部 id 集合（公开可见性的唯一依据） */
  const publicDivisionIds = new Set(activeDivisions.map((d) => String(d.id)));
  /**
   * 公开可见的商品 = 自身已上架 **且所属分部已上架**。
   * `division_id IS NULL`（未挂分部）不受约束 —— 与服务端
   * `publicDivisionFindWhere()` 的 NULL 宽松语义逐字一致（一刀切 INNER JOIN 会吞掉 NULL 行）。
   */
  const isPubliclyVisibleProduct = (p) =>
    num(p.status) === 1 &&
    num(p.serviceStatus) === 1 &&
    (p.divisionId === null || p.divisionId === undefined || publicDivisionIds.has(String(p.divisionId)));
  const activeProducts = products.filter(isPubliclyVisibleProduct);
  const delistedProducts = products.filter((p) => !isPubliclyVisibleProduct(p));

  const activeProductCountByDivision = {};
  for (const p of activeProducts) {
    const key = String(p.divisionId);
    activeProductCountByDivision[key] = (activeProductCountByDivision[key] ?? 0) + 1;
  }

  // ---------- 负向验证注入（只影响"期望值"，不动 DB）----------
  const injDiv = injectedIds('PUBLIC_EXPECT_INJECT_DELISTED_DIVISION');
  const injProd = injectedIds('PUBLIC_EXPECT_INJECT_DELISTED_PRODUCT');
  for (const id of injDiv) {
    if (!delistedDivisions.some((d) => String(d.id) === String(id))) {
      delistedDivisions.push({ id, code: '(负向验证注入)', name: '(注入的假下架分部)', status: '注入' });
    }
  }
  for (const id of injProd) {
    if (!delistedProducts.some((p) => String(p.id) === String(id))) {
      delistedProducts.push({ id, divisionId: '(注入)', status: '注入' });
    }
  }
  if (injDiv.length || injProd.length) {
    banner([
      '负向验证模式（PUBLIC_EXPECT_INJECT_*）：把下列 id 当作「已下架行」注入期望值',
      `  假下架分部 id = ${injDiv.join(',') || '（无）'}`,
      `  假下架商品 id = ${injProd.join(',') || '（无）'}`,
      '它**不存在于 DB**，只用来证明「已下架不出现」的护栏真的会红；业务数据一行未动。',
      '未设置该环境变量时不会有任何注入 —— 正常跑请忽略本提示。',
    ]);
  }

  const ids = (rows) => rows.map((r) => String(r.id));
  const named = (rows, field = 'name') =>
    rows.map((r) => `${r.id}${r[field] ? `=${String(r[field]).trim()}` : ''}`).join(' / ') || '（无）';

  return {
    activeDivisions,
    activeDivisionIds: ids(activeDivisions),
    delistedDivisions,
    delistedDivisionIds: ids(delistedDivisions),
    activeClubs,
    activeClubIds: ids(activeClubs),
    delistedClubs,
    delistedClubIds: ids(delistedClubs),
    activeProducts,
    activeProductIds: ids(activeProducts),
    activeProductCountByDivision,
    delistedProducts,
    /** DB 原始计数（诊断用） */
    raw: { divisions: divisions.length, clubs: clubs.length, products: products.length },
    /** 期望值来源（直接拼进断言文案，失败时一眼看出"是接口漏了/多了"还是"配置变了"） */
    sources: {
      activeDivisions: `DB division.status=1（${activeDivisions.length} 个：${named(activeDivisions)}）`,
      delistedDivisions: `DB division.status≠1（${delistedDivisions.length} 个：${named(delistedDivisions)}）`,
      activeClubs: `DB club.status=1（${activeClubs.length} 个：${named(activeClubs)}）`,
      delistedClubs: `DB club.status≠1（${delistedClubs.length} 个：${named(delistedClubs)}）`,
      activeProducts: `DB product.status=1 AND service_status=1 AND 所属分部已上架（${activeProducts.length} 条；已上架分部=${[...publicDivisionIds].join(',') || '（无）'}）`,
      delistedProducts: `DB product.status≠1 或 service_status≠1 或所属分部已下架（${delistedProducts.length} 条）`,
      countInDivision: (divisionId) =>
        `DB product.status=1 AND service_status=1 AND division_id=${divisionId}（${activeProductCountByDivision[String(divisionId)] ?? 0} 条）`,
    },
  };
}

/** 已下架 id 里"却出现在公开返回集合中"的那些（护栏判定的唯一实现） */
function leakedIds(publicIds, delistedIds) {
  const pub = new Set(publicIds.map(String));
  return delistedIds.map(String).filter((id) => pub.has(id));
}

/** 集合差：`a` 中不在 `b` 里的（用于 /public/products 的"漏了/多了"） */
function missingFrom(publicIds, dbIds) {
  const pub = new Set(publicIds.map(String));
  return dbIds.map(String).filter((id) => !pub.has(id));
}

module.exports = {
  ENV_FILE,
  readEnv,
  openDb,
  loadExpectation,
  flattenGroupedDivisions,
  leakedIds,
  missingFrom,
};
