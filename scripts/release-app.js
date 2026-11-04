/**
 * 双端云更新发布脚本（负责人要求：老板端 / 工作端每次更新完都必须推送云更新给所有用户）
 *
 * 用法：
 *   node scripts/release-app.js <boss|worker> <版本码> <版本名> "<更新说明>" [--force] [--install]
 *   （等价入口：node scripts/release-boss.js ... / node scripts/release-worker.js ...）
 *
 * 动作（自动完成）：
 *   1. 构建对应端 arm64 APK（--dart-define 注入版本码/版本名/隧道地址）
 *   2. 上传到该端自己的云端版本通道（管理端「版本更新」页按 老板端/工作端 分开可见）
 *   3. 停用该端其他启用中的旧版本（不影响另一端）
 *   4. 可选 --install：手机连接时直接推装对应端 APK
 *   5. 可选 --force：本次设为强制更新（阻止旧版继续使用）
 *
 * 铁律：版本码必须单调递增，且同一端内不与历史记录重复（否则上传会被 400 拒绝）。
 */
const { execSync, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');

const APPS = {
  boss: { label: '老板端', dir: 'D:/fish/apps/boss-app', apk: 'app-arm64-v8a-release.apk', envType: 'boss' },
  worker: { label: '工作端', dir: 'D:/fish/apps/worker-app', apk: 'app-arm64-v8a-release.apk', envType: 'worker' },
};

// 支持两种调用：release-app.js <app> <码> <名> <说明> ｜ 包装入口注入 appType
const args = process.argv.slice(2);
const appKey = process.env.RELEASE_APP_TYPE || args.shift();

/**
 * `--check-admin` 预检（**必须在参数校验之前**）：只回答"这次会用哪个管理端账号"。
 *
 * 放在这里的理由：`node scripts/release-boss.js --check-admin` 没有版本号/版本名，
 * 若先走下面的用法校验就会被判成"参数错"退出（预检根本跑不到）。
 * 账号入口自己打印结论后 `process.exit(0)` —— **不登录、不构建、不发任何请求**。
 * 不写 --check-admin 时这一行不做任何事（模块由下面统一 require，只加载一次）。
 */
if (process.argv.includes('--check-admin')) require('./tools/release-admin');

const app = APPS[appKey];
if (!app) {
  console.error('用法: node scripts/release-app.js <boss|worker> <版本码> <版本名> "<更新说明>" [--force] [--install]');
  process.exit(1);
}

const flag = (name) => args.includes('--' + name);
const versionCode = Number(args[0]);
const versionName = args[1];
const updateDesc = args.slice(2).filter((a) => !a.startsWith('--')).join(' ') || `v${versionName} 版本更新`;

/**
 * 【2026-10-07 编码护栏】更新说明**不许出现替换字符**（U+FFFD "�"）。
 *
 * 背景：本脚本在 Windows 上常被 PowerShell 调用，而中文参数要经过
 * 「PowerShell → CreateProcess 命令行 → node argv」三段编码转换；
 * 任何一段用了非 UTF-8 代码页，中文就会被解成乱码（`淇敼...`）或替换字符，
 * 然后**原样入库**：用户在更新弹窗里看到的就是乱码，而脚本本身不会报错。
 *
 * 这里宁可**发布失败**也不把乱码推给所有存量用户（与"宁可发布失败也不烘死地址"同一条口径）。
 * 正确调用方式见 docs/16：中文说明写进 UTF-8 文件，或按下面的提示改用文件读取。
 */
if (updateDesc.includes('\uFFFD')) {
  console.error('✗ 更新说明里出现替换字符（U+FFFD），说明中文在传参过程中被破坏 —— 已中止发布。');
  console.error('  请改用：`node scripts/release-app.js <码> <名> --desc-file <UTF-8 文件>`（或让调用方用 UTF-8 传参）');
  process.exit(1);
}
// `--desc-file <path>`：从 UTF-8 文件读说明（彻底绕开命令行编码问题，推荐做法）
{
  const di = args.indexOf('--desc-file');
  if (di >= 0) {
    const file = args[di + 1];
    if (!file || !fs.existsSync(file)) {
      console.error(`✗ --desc-file 指定的文件不存在：${file}`);
      process.exit(1);
    }
    const fromFile = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').trim();
    if (!fromFile) {
      console.error('✗ --desc-file 文件为空');
      process.exit(1);
    }
    if (fromFile.includes('\uFFFD')) {
      console.error('✗ --desc-file 文件本身含替换字符（不是 UTF-8？）—— 已中止发布。');
      process.exit(1);
    }
    args[args.indexOf('--desc-file')] = '';
    process.env.__FISH_UPDATE_DESC = fromFile;
  }
}
const finalUpdateDesc = process.env.__FISH_UPDATE_DESC || updateDesc;

/**
 * 安卓构建环境（`ANDROID_HOME` / `JAVA_HOME`）——**未设置时给默认值，已设置时不覆盖**，
 * 且刻意放在**参数校验之前**（2026-10-07 工程护栏：一晚因缺这两个变量失败两次）。
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 为什么必须由脚本自己兜住
 * ─────────────────────────────────────────────────────────────────────────────
 * `flutter build apk` 需要 Android SDK 与 JDK。本机的正确取值是**非默认安装位置**：
 *   ANDROID_HOME = `D:\Android\sdk`
 *   JAVA_HOME    = `C:\Program Files\Android\Android Studio\jbr`（Android Studio 自带 jbr）
 * 而这两个变量**只在"已经配好的那个 shell"里存在**：新开的 shell / 计划任务 / 别的会话里
 * 一律为空，于是 `flutter build apk` 直接失败（`No Android SDK found` / 找不到 java）。
 * 实测代价：2026-10-06 夜里**连着两次**发版因此中断，且报错离"其实是环境变量没设"很远。
 *
 * 为什么放在这里（而不是构建前）：这样**连用法写错时也能先看到**"这次会用哪套 SDK/JDK"，
 * 排查"到底是参数问题还是环境问题"不必猜；`--check-admin` 预检已在上面 exit，不受影响。
 *
 * 口径（与 `scripts/tools/release-admin.js` 的"默认值 + 警告"同一风格，逐条可验证）：
 *   - **未设置** → 注入默认值，并打印一行「使用默认 SDK/JDK 路径」让操作者**知情**
 *     （不是静默替换：日志里看得到这次用的是哪条路径，正式发布时还会再打一行实际值）；
 *   - **已设置** → **一律不覆盖**（开发机/CI 自定义路径必须说了算）；
 *   - 默认路径**不存在** → 直接**明确报错**退出（`✗ …` + 怎么修），**绝不静默略过**
 *     —— 静默略过只会在几分钟后换来一句莫名其妙的 gradle 报错。
 *
 * 覆盖方式：`ANDROID_HOME` / `JAVA_HOME` 环境变量，或
 *           `FISH_ANDROID_HOME` / `FISH_JAVA_HOME`（不动环境变量、只影响本次发布）。
 */
const ANDROID_ENV_DEFAULTS = {
  ANDROID_HOME: { def: 'D:\\Android\\sdk', label: 'Android SDK' },
  JAVA_HOME: { def: 'C:\\Program Files\\Android\\Android Studio\\jbr', label: 'JDK（Android Studio 自带 jbr）' },
};

function ensureAndroidBuildEnv() {
  const used = [];
  for (const [key, { def, label }] of Object.entries(ANDROID_ENV_DEFAULTS)) {
    const override = (process.env['FISH_' + key] ?? '').trim();
    const current = (process.env[key] ?? '').trim();
    if (current) continue; // 已设置 → 不覆盖（零行为变化）
    const value = override || def;
    if (!fs.existsSync(value)) {
      console.error(`✗ ${key} 未设置，且默认路径不存在：${value}`);
      console.error(`  ${label} 的路径不对，或这台机器没按 docs/22-开发环境清单.md 装好环境。`);
      console.error(`  请显式指定后再发版：$env:${key}='<真实路径>'（或 $env:FISH_${key}='<真实路径>'）`);
      process.exit(1);
    }
    process.env[key] = value;
    used.push(`${key}=${value}`);
  }
  if (used.length) {
    console.log(`[发布环境] 使用默认 SDK/JDK 路径（未设置环境变量，已注入子进程）：${used.join('  ')}`);
    console.log('[发布环境] 想用别的路径：设置 ANDROID_HOME / JAVA_HOME（已设置时不覆盖）。');
  }
}

ensureAndroidBuildEnv();

if (!Number.isInteger(versionCode) || versionCode < 1 || !versionName) {
  console.error(`用法: node scripts/release-app.js ${appKey} <版本码> <版本名> "<更新说明>" [--force] [--install]`);
  process.exit(1);
}

/**
 * 发布上传目标（2026-10-13 云迁移后新增可覆盖项）。
 *
 * 背景：生产已迁到云服务器（香港 YOUR_SERVER_HOST，见 config/client-config.json 的 api），
 * 本机 3100 只剩开发/备用角色。发版必须把 APK 与版本记录写到**线上那台**，
 * 否则用户更新通道里拿不到新包。
 *
 * 取值优先级：`FISH_RELEASE_API`（显式指定，如 http://YOUR_SERVER_HOST:3100/api/v1）
 *          → 默认本机 http://127.0.0.1:3100/api/v1（**与改前逐字相同**，本地开发零影响）。
 */
const BASE = process.env.FISH_RELEASE_API || 'http://127.0.0.1:3100/api/v1';
const APK = `${app.dir}/build/app/outputs/flutter-apk/${app.apk}`;

/**
 * 发布用的管理端账号（**唯一入口**：`scripts/tools/release-admin.js`，2026-10-06 技术债收敛）。
 *
 * 取值优先级：`RELEASE_ADMIN_USER` / `RELEASE_ADMIN_PASSWORD`（推荐，专用测试超管）
 *          → 回退 `server/.env` 的 `ADMIN_*` 并打印醒目中文警告。
 *
 * 为什么不能让发布脚本自己读 `.env`：那对值是负责人的超管账号，按单设备铁律
 * （primary ↔ primary 互斥）**每发一次版就可能把他别处的管理端登录顶掉**。
 * 与上传 / 启停旧版本等任何行为无关：这里只决定"用谁登录"，其余一行未改。
 * 发版前可先跑 `node scripts/release-boss.js --check-admin` 预检（不登录、不构建）。
 */
const { releaseAdminUser, releaseAdminPassword } = require('./tools/release-admin');

/**
 * 隧道地址（2026-10-04 起：以 config/client-config.json 为单一真相）。
 * 优先级：
 *   1) 环境变量 FISH_TUNNEL（手动指定，用于固定域名/固定隧道）
 *   2) config/client-config.json 的 api 字段（由 scripts/publish-address.ps1 写入；与 App 动态下发同一份）
 *   3) 从 cloudflared 日志/缓存抓取（旧逻辑兜底）
 *   4) 兜底：报错退出（宁可发布失败，也不能把死地址烘进安装包）
 * 注意：即使 APK 里的地址过期也不再致命 —— App 启动时会从固定引导地址
 *       （AppAddressResolver.bootstrapUrl）拉当前地址，所以本地址只是"首启兜底"。
 */
function resolveTunnel() {
  if (process.env.FISH_TUNNEL) return process.env.FISH_TUNNEL.replace(/\/$/, '');
  const configFile = 'D:/fish/config/client-config.json';
  try {
    if (fs.existsSync(configFile)) {
      const cfg = JSON.parse(fs.readFileSync(configFile, 'utf8'));
      if (cfg.ws) return String(cfg.ws).replace(/\/$/, '');
      if (cfg.api) return String(cfg.api).replace(/\/api\/v1\/?$/, '');
    }
  } catch (_) { /* ignore */ }
  const candidates = [];
  const cacheFile = 'D:/fish/scripts/tmp/.tunnel-url';
  try {
    if (fs.existsSync(cacheFile)) candidates.push(fs.readFileSync(cacheFile, 'utf8').trim());
  } catch (_) { /* ignore */ }
  try {
    const out = execSync('pm2 logs fish-tunnel --lines 400 --nostream', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    for (const m of out.matchAll(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/g)) candidates.push(m[0]);
  } catch (_) { /* ignore */ }
  // 取最新一个（日志按时间顺序，最后一个即当前地址）
  const latest = candidates.filter(Boolean).pop();
  if (!latest) {
    console.error('✗ 无法确定隧道地址：请先跑 scripts/publish-address.ps1，或设置 FISH_TUNNEL');
    process.exit(1);
  }
  try { fs.writeFileSync(cacheFile, latest); } catch (_) { /* ignore */ }
  return latest;
}

// 注意：本脚本在 Windows 上由 cmd.exe 执行（execSync 默认 shell），
// 禁止使用 `VAR=x cmd` 这类 bash 语法，环境变量一律走 env 选项、工作目录走 cwd 选项
const run = (cmd, opts) => execSync(cmd, { stdio: 'inherit', ...opts });
const die = (msg) => { console.error('✗ ' + msg); process.exit(1); };

// 解析当前隧道地址（构建时烘进 APK）
const TUNNEL = resolveTunnel();

/**
 * 内置候选清单（2026-10-06 地址发现韧性专项）。
 *
 * 为什么必须"不止一个"：已发布的 1.11.21 只烧录了 ngrok 固定域名，而该账号
 * 月度流量耗尽 → 403 ERR_NGROK_725；同时 bootstrap 唯一来源 GitHub raw 本机
 * http=000 不可达 → **存量用户无法自动换址**。多烧几个候选，
 * 即便所有引导站都挂，App 仍能靠"并行探活、最快者胜"自己找到活着的入口。
 *
 * 组成（去重、保序）：
 *   1) ngrok 固定域名 —— 唯一稳定的固定入口，额度恢复后自动回到主位（config 里的 preferred）
 *   2) 构建时的当前隧道 —— 首启即用的兜底
 *   3) 局域网 IP:3100 —— 现场调试；可用 FISH_LAN_IPS="" 清空
 * 覆盖：FISH_BUILTIN_CANDIDATES="https://a,http://b"（完全自定义，逗号分隔）
 */
/**
 * Gitee raw 引导站（2026-10-10 接通，App 的 bootstrap 源 #1）。
 *
 * 为什么必须有它：Cloudflare 快速隧道每次重启都换域名，而 GitHub raw 在国内不可达、
 * jsDelivr 需要同名 GitHub 仓库存在 —— 于是"换地址"过去只能靠**重发 APK**。
 * 把 Gitee raw 地址编译进 APK 后，App 启动时会读它拿到当前地址，**换地址不再需要发版**。
 *
 * 地址来源于 server/.env 的 GITEE_OWNER / GITEE_REPO（与
 * scripts/tmp/publish-bootstrap-gitee.ps1 同一份来源，避免两处漂移）；
 * 未配置时不加这个 flag（构建照旧，只是少了这条引导）。
 */
function resolveGiteeBootstrap() {
  if (process.env.FISH_GITEE_BOOTSTRAP !== undefined) return process.env.FISH_GITEE_BOOTSTRAP.trim();
  try {
    const env = fs.readFileSync('D:/fish/server/.env', 'utf8');
    const get = (k) => (env.match(new RegExp('^' + k + '=(.+)$', 'm')) || [])[1]?.trim();
    const owner = get('GITEE_OWNER');
    const repo = get('GITEE_REPO');
    const branch = get('GITEE_BRANCH') || 'main';
    if (owner && repo) return `https://gitee.com/${owner}/${repo}/raw/${branch}/client-config.json`;
  } catch {}
  return '';
}

const GITEE_BOOTSTRAP = resolveGiteeBootstrap();

/**
 * `config/client-config.json` 的 candidates（**地址的单一真相**）。
 *
 * 2026-10-13 云迁移新增：生产固定在云服务器（香港 YOUR_SERVER_HOST，固定 IP），
 * 该文件是"当前该用哪个地址"的唯一出处（与 App 动态下发同一份）。
 * 把它烧进 APK 的意义：**冷启动不必先联网拉引导站**就能拿到生产地址，
 * 引导站全部不可达时也照常可用（此前 builtin 只有 ngrok + 隧道，两者都已失效）。
 */
function readConfigCandidates() {
  try {
    const cfg = JSON.parse(fs.readFileSync('D:/fish/config/client-config.json', 'utf8'));
    const list = Array.isArray(cfg.candidates) ? cfg.candidates : [];
    const out = [];
    for (const c of list) {
      const v = String(c || '').trim().replace(/\/+$/, '');
      if (v && !out.includes(v)) out.push(v);
    }
    return out;
  } catch (_) {
    return [];
  }
}

function resolveBuiltinCandidates() {
  if (process.env.FISH_BUILTIN_CANDIDATES !== undefined) {
    return process.env.FISH_BUILTIN_CANDIDATES.split(',').map((s) => s.trim()).filter(Boolean);
  }
  const out = [];
  const add = (u) => { const v = String(u || '').trim().replace(/\/+$/, ''); if (v && !out.includes(v)) out.push(v); };
  // 0) config/client-config.json 的 candidates（**首位 = 生产地址**，2026-10-13 云迁移）
  for (const c of readConfigCandidates()) add(c);
  // 1) ngrok 固定域名：**仅当 config 没给 candidates 时**才作历史兜底。
  //    该账号月度流量已耗尽（403 ERR_NGROK_725），有生产地址时留着只会白等一次并行探活。
  if (out.length === 0) {
    add(process.env.FISH_NGROK_DOMAIN || 'https://<your-tunnel-domain>');
  }
  // 2) 当前隧道（= config 的 ws/api；云迁移后就是云服务器本身，add 自动去重）
  add(TUNNEL);
  // 3) 局域网 IP（现场调试用；探测会校验 FISH 统一响应契约，误连不会假通过）
  if (process.env.FISH_LAN_IPS !== '') {
    if (process.env.FISH_LAN_IPS) {
      for (const ip of process.env.FISH_LAN_IPS.split(',')) add(`http://${ip.trim()}:3100`);
    } else {
      try {
        for (const list of Object.values(os.networkInterfaces())) {
          for (const ni of list || []) {
            if (ni.family === 'IPv4' && !ni.internal) add(`http://${ni.address}:3100`);
          }
        }
      } catch (_) { /* 拿不到网卡就跳过 */ }
    }
  }
  return out;
}
const BUILTIN_CANDIDATES = resolveBuiltinCandidates();

/**
 * `--split-debug-info`（体积优化，**默认开**，负责人 2026-10-06 收口裁决）。
 *
 * 打开后 Flutter 把 AOT 符号表（`app.android-arm64.symbols`）写到独立目录，
 * `libapp.so` 里的调试信息不再进包 → APK 更小、下载更快。
 * 代价：崩溃堆栈变成裸地址，必须用
 *   `flutter symbolize -i <stack.txt> -d build/symbols`
 * 还原成函数名。所以**符号表必须留档**：固定落在 `<app>/build/symbols`
 * （`build/` 已被各端 .gitignore 忽略，不入 git；也**不要**删，删了老包的崩溃就查不了）。
 * 关掉：`--no-split-debug` 或 `FISH_SPLIT_DEBUG_INFO=0`（`=1` 保持向后兼容）。
 *
 * `--obfuscate` 刻意**不提供**（负责人裁决：保持关闭）：
 *   Dart 符号名混淆对体积的额外收益极小（本工程主要体积是字体/图片/Skia），
 *   却会让崩溃堆栈里的类名/方法名全变成 `a`/`b`/`c` —— 线上排障成本远超收益。
 *   本工程的实际取舍是「**要可读堆栈**」：宁可多几百 KB，也要能看懂崩溃日志。
 */
const SPLIT_DEBUG_INFO = !flag('no-split-debug') && process.env.FISH_SPLIT_DEBUG_INFO !== '0';

(async () => {
  console.log(`▶ 发布 ${app.label} v${versionName}（码${versionCode}）${flag('force') ? '【强制更新】' : ''}`);
  console.log(`  隧道地址: ${TUNNEL}`);
  // 安卓构建环境（ANDROID_HOME / JAVA_HOME）：未设置时用默认值，已设置时不覆盖（见 ensureAndroidBuildEnv）
  console.log(`  构建环境: ANDROID_HOME=${process.env.ANDROID_HOME}  JAVA_HOME=${process.env.JAVA_HOME}`);

  // 1. 构建（--build-number/--build-name 让 Android 清单里的版本码也随发布递增：
  //    Android 要求新包 versionCode ≥ 已安装版本才允许覆盖安装，清单版本码若常年停在 pubspec 里的 0.1.0，
  //    一旦 pubspec 变动或换 ABI，升级安装会被系统拒绝。清单码 = 版本码 + 1000×ABI（arm64 → +2000））
  console.log(`[1/4] 构建 ${app.label}…`);
  console.log(`  内置候选(${BUILTIN_CANDIDATES.length}): ${BUILTIN_CANDIDATES.join(' , ') || '(空)'}`);
  if (SPLIT_DEBUG_INFO) console.log('  --split-debug-info 已开启（符号表落到 build/symbols，崩溃堆栈需 flutter symbolize 还原）');
  const symbolsDir = `${app.dir}/build/symbols`;
  run(
    `flutter build apk --release --split-per-abi --build-number=${versionCode} --build-name=${versionName}` +
    ` --dart-define=API_BASE_URL=${TUNNEL}/api/v1 --dart-define=WS_BASE_URL=${TUNNEL}` +
    ` --dart-define=APP_VERSION_CODE=${versionCode} --dart-define=APP_VERSION_NAME=${versionName}` +
    // 地址发现韧性：把"ngrok 固定域名 + 当前隧道 + 局域网 IP"一并烧进 APK，
    // 全部引导站不可达时 App 还能靠内置多候选并行探活自救（见 core/app_address.dart）
    ` --dart-define=ADDRESS_BUILTIN_CANDIDATES=${BUILTIN_CANDIDATES.join(',')}` +
    // Gitee raw 引导站（2026-10-10 接通）：隧道地址一变，已装 App 从这里自动发现新地址，
    // 从此不需要为"换地址"重发 APK。owner/repo 取自 server/.env 的 GITEE_OWNER / GITEE_REPO
    // （与 scripts/tmp/publish-bootstrap-gitee.ps1 同一份来源）。未配置则不加这个 flag。
    (GITEE_BOOTSTRAP ? ` --dart-define=ADDRESS_BOOTSTRAP_GITEE=${GITEE_BOOTSTRAP}` : '') +
    (SPLIT_DEBUG_INFO ? ` --split-debug-info=${symbolsDir}` : ''),
    { cwd: app.dir, env: { ...process.env, GRADLE_USER_HOME: 'D:/fish/.gradle-home' } },
  );
  if (!fs.existsSync(APK)) die('APK 构建产物不存在');

  // 2. 登录 + 上传
  console.log('[2/4] 上传到云端版本库…');
  const login = await fetch(BASE + '/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: releaseAdminUser, password: releaseAdminPassword, role: 'admin' }),
  });
  const token = (await login.json()).data?.accessToken;
  if (!token) die('管理端登录失败');
  const fd = new FormData();
  fd.append('file', new Blob([fs.readFileSync(APK)], { type: 'application/vnd.android.package-archive' }), `fish-${appKey}-arm64-${versionName}.apk`);
  fd.append('appType', app.envType);
  fd.append('versionCode', String(versionCode));
  fd.append('versionName', versionName);
  fd.append('updateDesc', finalUpdateDesc);
  fd.append('forceUpdate', flag('force') ? 'true' : 'false');
  fd.append('minSupportedVersion', '1');
  const up = await fetch(BASE + '/admin/app-versions/upload', { method: 'POST', headers: { Authorization: 'Bearer ' + token }, body: fd });
  const uj = await up.json();
  if (up.status !== 201) die('上传失败: ' + (uj.message || up.status));

  // 3. 停用该端旧版（另一端的版本不受影响）
  console.log('[3/4] 停用该端旧启用版本…');
  const lr = await fetch(BASE + `/admin/app-versions?appType=${app.envType}`, { headers: { Authorization: 'Bearer ' + token } });
  const rows = (await lr.json()).data.list;
  for (const r of rows.filter((x) => x.status === 1 && x.versionCode !== versionCode)) {
    await fetch(BASE + '/admin/app-versions/' + r.id + '/status', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify({ status: 2 }),
    });
    console.log('  停用 v' + r.versionCode);
  }

  // 4. 验证该端通道
  const lt = await fetch(`${BASE}/public/app-versions/latest?appType=${app.envType}&currentVersionCode=1`);
  const lj = await lt.json();
  if (!lj.data?.hasUpdate || lj.data.latest?.versionCode !== versionCode) die('云端验证失败');
  console.log(`[4/4] ✓ ${app.label}云端最新 = v${versionName}（码${versionCode}），所有旧版用户打开 App 将收到更新`);

  // 可选推装
  if (flag('install')) {
    const dev = execSync('adb devices', { encoding: 'utf8' });
    if (dev.includes('device\t')) {
      // execFileSync 不走 shell：避免路径被 shell 转义/转换
      execFileSync('adb', ['install', '-r', '-t', APK], { stdio: 'inherit' });
    } else {
      console.log('（未检测到手机连接，跳过推装）');
    }
  }
  console.log('发布完成');
})().catch((e) => { console.error('发布失败:', e.message); process.exit(1); });
