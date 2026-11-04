/**
 * 回归套件「管理端账号」唯一入口（2026-10-07，债 1）
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 为什么必须收敛到一处
 * ─────────────────────────────────────────────────────────────────────────────
 * 11 个后端回归套件里有 **10 个**要登录管理端，原先各自硬读 `server/.env` 的
 * `ADMIN_USERNAME` / `ADMIN_PASSWORD`。本机那对值是**负责人本人的超管账号**（`kslingyun`，`is_owner=1`），
 * 而 docs/04 的「单设备铁律」是 **primary ↔ primary 互斥**（新登录把旧令牌置 `revoked=2`）——
 * 于是**跑一次回归就把负责人在浏览器里的管理端会话顶掉**（2026-10-07 他因此被"莫名登出"过）。
 * 只要还有第二处自己读 `.env`，这个坑就会再踩一次 → 所以取账号只允许走这里。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 取值优先级（**唯一判定**，禁止各套件再自己读 `.env` 的 `ADMIN_*`）
 * ─────────────────────────────────────────────────────────────────────────────
 *   ① `REGRESSION_ADMIN_USER` / `REGRESSION_ADMIN_PASSWORD`（环境变量，**推荐**：指向专用测试超管）
 *   ② 回退 `server/.env` 的 `ADMIN_USERNAME` / `ADMIN_PASSWORD` → **打印醒目中文警告**
 *
 * 刻意**不**把回退默认值改成别的账号：擅自换账号会让人以为"已经切到测试账号"，
 * 而实际用的是谁将无从判断 —— 保持"用哪个账号"永远能从输出里一眼看清。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 用法
 * ─────────────────────────────────────────────────────────────────────────────
 *   const { adminUser, adminPassword } = require('../tools/regression-admin');
 *
 *   # 跑套件前先确认"这一次会用哪个管理端账号"（**不登录、不烧会话**）：
 *   node scripts/tmp/xxx-test.js --check-admin
 *
 * `--check-admin` 是刻意做在**本模块**里的：它要在任何登录动作之前就能回答
 * "会用谁的会话"，否则"确认账号"这件事本身就得先顶掉一次真人的登录。
 * 未提供 `REGRESSION_ADMIN_*` 时它会打印与真实运行**逐字相同**的警告。
 *
 * 环境变量：
 *   REGRESSION_ADMIN_USER / REGRESSION_ADMIN_PASSWORD  专用测试超管账密
 *   REGRESSION_ENV_FILE                                覆盖 .env 路径（默认 D:/fish/server/.env）
 *   REGRESSION_QUIET_WARNING=1                         静默回退警告（仅供自动化外层已提示时使用）
 */
const fs = require('fs');
const path = require('path');

const ENV_FILE = process.env.REGRESSION_ENV_FILE || path.join(__dirname, '..', '..', 'server', '.env');

let envCache = null;
function envText() {
  if (envCache === null) {
    try {
      envCache = fs.readFileSync(ENV_FILE, 'utf8');
    } catch (e) {
      throw new Error(`回归账号入口读不到 ${ENV_FILE}：${e.message}（可用 REGRESSION_ENV_FILE 指定）`);
    }
  }
  return envCache;
}

/** 读 `server/.env` 里的任意键（DB_* 之类仍由各套件自己读；这里只服务于管理端账号） */
function envOf(key) {
  const m = envText().match(new RegExp('^' + key + '=(.+)$', 'm'));
  return m ? m[1].trim() : null;
}

let resolved = null;
let warned = false;

/**
 * 解析管理端账号。
 * @returns {{user: string, password: string, source: 'env'|'dotenv', userKey: string}}
 */
function resolveAdminCredentials() {
  if (resolved) return resolved;

  const envUser = (process.env.REGRESSION_ADMIN_USER ?? '').trim();
  const envPass = process.env.REGRESSION_ADMIN_PASSWORD ?? '';
  const fileUser = envOf('ADMIN_USERNAME');
  const filePass = envOf('ADMIN_PASSWORD');

  if (envUser && envPass) {
    resolved = { user: envUser, password: envPass, source: 'env', userKey: 'REGRESSION_ADMIN_USER' };
    console.log(`[回归账号] 管理端账号 = ${envUser}（来自环境变量 REGRESSION_ADMIN_USER，专用测试超管）`);
    return resolved;
  }

  if (envUser && !envPass) {
    throw new Error(
      '只设置了 REGRESSION_ADMIN_USER，缺少 REGRESSION_ADMIN_PASSWORD —— ' +
        '请成对提供（不要让它回退到 .env 的口令，否则会登错账号）',
    );
  }
  if (!envUser && envPass) {
    throw new Error('只设置了 REGRESSION_ADMIN_PASSWORD，缺少 REGRESSION_ADMIN_USER —— 请成对提供');
  }

  /**
   * ② `.env` 里的 `REGRESSION_ADMIN_*`（**2026-10-08 新增这一档**）
   *
   * 背景：专用测试超管 `fishadmin` 随"清理测试数据"被删除，此后若没人显式给环境变量，
   * 取值就会直接掉到 ③ 的 `ADMIN_*`（= 负责人本人的账号）→ **跑一次回归就把负责人顶下线**。
   * 因此把"专用测试超管"落进 `.env`（`REGRESSION_ADMIN_USER/PASSWORD`），
   * 让**任何一次裸跑**都自动用测试账号，绝不碰真人账号；③ 只作为最后兜底并照旧告警。
   */
  const fileTestUser = envOf('REGRESSION_ADMIN_USER');
  const fileTestPass = envOf('REGRESSION_ADMIN_PASSWORD');
  if (fileTestUser && fileTestPass) {
    resolved = { user: fileTestUser, password: fileTestPass, source: 'dotenv-test', userKey: 'REGRESSION_ADMIN_USER' };
    console.log(`[回归账号] 管理端账号 = ${fileTestUser}（来自 ${ENV_FILE} 的 REGRESSION_ADMIN_USER，专用测试超管）`);
    return resolved;
  }

  if (!fileUser || !filePass) {
    throw new Error(`既未提供 REGRESSION_ADMIN_USER/REGRESSION_ADMIN_PASSWORD，${ENV_FILE} 里也读不到 ADMIN_USERNAME/ADMIN_PASSWORD`);
  }

  resolved = { user: fileUser, password: filePass, source: 'dotenv', userKey: 'ADMIN_USERNAME' };
  if (!warned && process.env.REGRESSION_QUIET_WARNING !== '1') {
    warned = true;
    console.log('');
    console.log('══════════════════════════════════════════════════════════════════════════════');
    console.log('⚠️  回归账号安全警告：未设置 REGRESSION_ADMIN_USER / REGRESSION_ADMIN_PASSWORD');
    console.log('══════════════════════════════════════════════════════════════════════════════');
    console.log(`   将使用 server/.env 里的管理端账号：ADMIN_USERNAME = ${fileUser}`);
    console.log('   该账号可能正是**负责人在用的超管账号**。按「单设备铁律」（primary ↔ primary 互斥），');
    console.log('   跑一次回归就会把它在别处（浏览器管理端 / 手机）的登录顶掉 —— 表现为"莫名被登出"。');
    console.log('   建议改用专用测试超管：');
    console.log("       $env:REGRESSION_ADMIN_USER='fishadmin'");
    console.log("       $env:REGRESSION_ADMIN_PASSWORD='<见 server/.env 里的 FISHADMIN_PASSWORD>'");
    console.log('       node scripts/tmp/<套件>.js');
    console.log('   详见 docs/12-测试规范.md「跑回归必须用 REGRESSION_ADMIN_* 指定专用测试超管」。');
    console.log('');
  }
  return resolved;
}

const creds = resolveAdminCredentials();

/** `--check-admin`：只打印"本次会用哪个管理端账号"，**不登录**，随即退出 */
function maybeCheckAdminAndExit() {
  if (!process.argv.includes('--check-admin')) return;
  const c = resolveAdminCredentials();
  console.log(`[--check-admin] 本次回归将使用的管理端账号 = ${c.user}（来源：${c.userKey}）`);
  console.log(
    c.source === 'env'
      ? '[--check-admin] 已显式指定专用测试超管 → 不会顶掉任何真人会话。'
      : c.source === 'dotenv-test'
        ? '[--check-admin] 用的是 .env 里登记的专用测试超管（REGRESSION_ADMIN_USER）→ 不会顶掉任何真人会话。'
        : '[--check-admin] ⚠️ 回退到 server/.env 的账号（见上方警告）→ 真实运行会顶掉该账号在别处的登录。',
  );
  console.log('[--check-admin] 仅预检，未登录、未发出任何请求。');
  // 只有"真回退到真人账号"这一档才用非零退出码提醒调用方；测试超管两档都是安全路径
  process.exit(c.source === 'dotenv' ? 1 : 0);
}
maybeCheckAdminAndExit();

module.exports = {
  adminUser: creds.user,
  adminPassword: creds.password,
  adminSource: creds.source,
  adminUserKey: creds.userKey,
  envFile: ENV_FILE,
  envText,
  envOf,
  resolveAdminCredentials,
};
