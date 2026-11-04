/**
 * 发布脚本「管理端账号」唯一入口（2026-10-06，技术债收敛）
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 为什么必须收敛到一处
 * ─────────────────────────────────────────────────────────────────────────────
 * `scripts/release-app.js`（老板端/工作端发布共用实现，`release-boss.js` / `release-worker.js`
 * 只是固定 appType 的入口）原先**只能**读 `server/.env` 的 `ADMIN_USERNAME` / `ADMIN_PASSWORD`
 * 登录管理端上传 APK。本机那对值是**负责人本人的超管账号**（`kslingyun`，`is_owner=1`），
 * 而 docs/04 的「单设备铁律」是 **primary ↔ primary 互斥**（新登录把旧令牌置 `revoked=2`）——
 * 于是**每发一次版都可能把负责人在别处（浏览器管理端 / 手机）的登录顶掉**。
 * 这与 2026-10-06 回归套件收敛到 `scripts/tools/regression-admin.js` 是**同一个坑、同一种修法**：
 * 只要还有第二处自己读 `.env` 的 `ADMIN_*`，这个坑就会再踩一次 → 所以取账号只允许走这里。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 取值优先级（**唯一判定**，禁止发布路径再自己读 `.env` 的 `ADMIN_*`）
 * ─────────────────────────────────────────────────────────────────────────────
 *   ① `RELEASE_ADMIN_USER` / `RELEASE_ADMIN_PASSWORD`（环境变量，**推荐**：指向专用测试超管）
 *   ② 回退 `server/.env` 的 `ADMIN_USERNAME` / `ADMIN_PASSWORD` → **打印醒目中文警告**
 *
 * 刻意**不**改回退账号（不悄悄换成别的账号）：擅自换账号会让人以为"已经切到测试账号"，
 * 而实际用的是谁将无从判断 —— 保持"用哪个账号发版"永远能从输出里一眼看清。
 * **账号只从环境变量 / .env 取，和上传、启停旧版本等任何行为无关**（本模块不发任何请求）。
 *
 * 与回归入口的关系：两者**刻意分开**（`REGRESSION_ADMIN_*` vs `RELEASE_ADMIN_*`）——
 * 回归跑得勤、发布跑得少，把"哪一次动作用了谁的会话"分开命名，事后审计不会互相污染；
 * 想两边共用同一个专用测试超管，把那两个变量都设成同一个账号即可。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 用法
 * ─────────────────────────────────────────────────────────────────────────────
 *   const { releaseAdminUser, releaseAdminPassword } = require('./tools/release-admin');
 *
 *   # 发版前先确认"这一次会用哪个管理端账号"（**不登录、不烧会话、不构建**）：
 *   node scripts/tools/release-admin.js --check-admin
 *   node scripts/release-boss.js --check-admin      # 包装入口同样支持（它转发到本模块）
 *
 * `--check-admin` 刻意做在**本模块**里：它要在任何登录动作之前就能回答"会用谁的会话"，
 * 否则"确认账号"这件事本身就得先顶掉一次真人的登录。未提供 `RELEASE_ADMIN_*` 时
 * 它打印的警告与真实发版时**逐字相同**。
 *
 * 环境变量：
 *   RELEASE_ADMIN_USER / RELEASE_ADMIN_PASSWORD   专用测试超管账密（推荐）
 *   RELEASE_ENV_FILE                              覆盖 .env 路径（默认 D:/fish/server/.env）
 *   RELEASE_QUIET_WARNING=1                       静默回退警告（仅供外层已提示时使用）
 */
const fs = require('fs');
const path = require('path');

const ENV_FILE = process.env.RELEASE_ENV_FILE || path.join(__dirname, '..', '..', 'server', '.env');

let envCache = null;
function envText() {
  if (envCache === null) {
    try {
      envCache = fs.readFileSync(ENV_FILE, 'utf8');
    } catch (e) {
      throw new Error(`发布账号入口读不到 ${ENV_FILE}：${e.message}（可用 RELEASE_ENV_FILE 指定）`);
    }
  }
  return envCache;
}

/** 读 `server/.env` 里的任意键（这里只服务于管理端账号；其它键不归本模块管） */
function envOf(key) {
  const m = envText().match(new RegExp('^' + key + '=(.+)$', 'm'));
  return m ? m[1].trim() : null;
}

let resolved = null;
let warned = false;

/**
 * 解析发布用的管理端账号。
 * @returns {{user: string, password: string, source: 'env'|'dotenv', userKey: string}}
 */
function resolveReleaseAdminCredentials() {
  if (resolved) return resolved;

  const envUser = (process.env.RELEASE_ADMIN_USER ?? '').trim();
  const envPass = process.env.RELEASE_ADMIN_PASSWORD ?? '';
  const fileUser = envOf('ADMIN_USERNAME');
  const filePass = envOf('ADMIN_PASSWORD');

  if (envUser && envPass) {
    resolved = { user: envUser, password: envPass, source: 'env', userKey: 'RELEASE_ADMIN_USER' };
    console.log(`[发布账号] 管理端账号 = ${envUser}（来自环境变量 RELEASE_ADMIN_USER，专用测试超管）`);
    return resolved;
  }

  if (envUser && !envPass) {
    throw new Error(
      '只设置了 RELEASE_ADMIN_USER，缺少 RELEASE_ADMIN_PASSWORD —— ' +
        '请成对提供（不要让它回退到 .env 的口令，否则会登错账号）',
    );
  }
  if (!envUser && envPass) {
    throw new Error('只设置了 RELEASE_ADMIN_PASSWORD，缺少 RELEASE_ADMIN_USER —— 请成对提供');
  }

  /**
   * ② `.env` 里的 `RELEASE_ADMIN_*`（**2026-10-08 新增这一档**）
   *
   * 背景：专用测试超管 `fishadmin` 随"清理测试数据"被删除；若没人显式给环境变量，
   * 取值会直接掉到 ③ 的 `ADMIN_*`（= 负责人本人账号）→ **发一次版就把负责人顶下线**。
   * 把专用测试超管落进 `.env`（`RELEASE_ADMIN_USER/PASSWORD`），让任何一次裸发版都用测试账号。
   */
  const fileTestUser = envOf('RELEASE_ADMIN_USER');
  const fileTestPass = envOf('RELEASE_ADMIN_PASSWORD');
  if (fileTestUser && fileTestPass) {
    resolved = { user: fileTestUser, password: fileTestPass, source: 'dotenv-test', userKey: 'RELEASE_ADMIN_USER' };
    console.log(`[发布账号] 管理端账号 = ${fileTestUser}（来自 ${ENV_FILE} 的 RELEASE_ADMIN_USER，专用测试超管）`);
    return resolved;
  }

  if (!fileUser || !filePass) {
    throw new Error(`既未提供 RELEASE_ADMIN_USER/RELEASE_ADMIN_PASSWORD，${ENV_FILE} 里也读不到 ADMIN_USERNAME/ADMIN_PASSWORD`);
  }

  resolved = { user: fileUser, password: filePass, source: 'dotenv', userKey: 'ADMIN_USERNAME' };
  if (!warned && process.env.RELEASE_QUIET_WARNING !== '1') {
    warned = true;
    console.log('');
    console.log('══════════════════════════════════════════════════════════════════════════════');
    console.log('⚠️  发布账号安全警告：未设置 RELEASE_ADMIN_USER / RELEASE_ADMIN_PASSWORD');
    console.log('══════════════════════════════════════════════════════════════════════════════');
    console.log(`   将使用 server/.env 里的管理端账号：ADMIN_USERNAME = ${fileUser}`);
    console.log('   该账号通常正是**负责人在用的超管账号**。按「单设备铁律」（primary ↔ primary 互斥），');
    console.log('   发一次版就会把它在别处（浏览器管理端 / 手机端）的登录顶掉 —— 表现为"莫名被登出"。');
    console.log('   建议改用专用测试超管（有版本上传权限即可）：');
    console.log("       $env:RELEASE_ADMIN_USER='fishadmin'");
    console.log("       $env:RELEASE_ADMIN_PASSWORD='<见 server/.env 里的 FISHADMIN_PASSWORD>'");
    console.log('       node scripts/release-boss.js <版本码> <版本名> "<更新说明>"');
    console.log('   详见 docs/16-版本发布规范.md「发布脚本的管理端账号必须走 RELEASE_ADMIN_*」。');
    console.log('');
  }
  return resolved;
}

const creds = resolveReleaseAdminCredentials();

/** `--check-admin`：只打印"本次发版会用哪个管理端账号"，**不登录、不构建、不发任何请求**，随即退出 */
function maybeCheckAdminAndExit() {
  if (!process.argv.includes('--check-admin')) return;
  const c = resolveReleaseAdminCredentials();
  console.log(`[--check-admin] 本次发布将使用的管理端账号 = ${c.user}（来源：${c.userKey}）`);
  console.log(
    c.source === 'env'
      ? '[--check-admin] 已显式指定专用测试超管 → 不会顶掉任何真人会话。'
      : c.source === 'dotenv-test'
        ? '[--check-admin] 用的是 .env 里登记的专用测试超管（RELEASE_ADMIN_USER）→ 不会顶掉任何真人会话。'
        : '[--check-admin] ⚠️ 回退到 server/.env 的账号（见上方警告）→ 真实发布时会顶掉该账号在别处的登录。',
  );
  console.log('[--check-admin] 仅预检，未登录、未构建、未发出任何请求。');
  // 只有"真回退到真人账号"这一档才用非零退出码提醒调用方；测试超管两档都是安全路径
  process.exit(c.source === 'dotenv' ? 1 : 0);
}
maybeCheckAdminAndExit();

module.exports = {
  releaseAdminUser: creds.user,
  releaseAdminPassword: creds.password,
  releaseAdminSource: creds.source,
  releaseAdminUserKey: creds.userKey,
  envFile: ENV_FILE,
  envText,
  envOf,
  resolveReleaseAdminCredentials,
};
