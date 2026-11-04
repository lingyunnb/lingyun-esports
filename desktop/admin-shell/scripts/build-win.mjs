/**
 * 打包入口（`npm run build`）
 * ============================================================================
 * 只做一件事：**先把国内镜像设进环境变量，再调 electron-builder**。
 * 为什么必须是脚本而不是"记得在命令行里 export"：
 *   electron（≈100MB 的 electron-v33.2.1-win32-x64.zip）与 electron-builder 的
 *   nsis / winCodeSign 二进制都走 GitHub，国内直连会**长时间无输出地卡死**；
 *   镜像只写在文档里 = 下次一定有人忘。
 *   —— 本文件让 `npm run build` 自带镜像，任何人在任何机器上跑都是同一条路。
 *
 * 产物：../../dist-desktop/祁连山电竞-管理端-<version>.exe（portable 单文件，免安装）
 * 用法：npm run build        （等价于 electron-builder --win portable --x64）
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));

/** 国内镜像（负责人铁律：先设镜像再打包） */
const MIRRORS = {
  ELECTRON_MIRROR: 'https://npmmirror.com/mirrors/electron/',
  ELECTRON_BUILDER_BINARIES_MIRROR: 'https://npmmirror.com/mirrors/electron-builder-binaries/',
  npm_config_registry: 'https://registry.npmmirror.com',
  npm_config_electron_mirror: 'https://npmmirror.com/mirrors/electron/',
  npm_config_electron_builder_binaries_mirror: 'https://npmmirror.com/mirrors/electron-builder-binaries/',
};

const cli = path.join(ROOT, 'node_modules', 'electron-builder', 'out', 'cli', 'cli.js');
if (!fs.existsSync(cli)) {
  console.error(`[build] 找不到 electron-builder：${cli}\n        请先在 desktop/admin-shell 里执行 npm install（本工程 .npmrc 已配 npmmirror）。`);
  process.exit(1);
}

const args = process.argv.slice(2);
const finalArgs = args.length ? args : ['--win', 'portable', '--x64'];

console.log(`[build] 版本 ${pkg.version} → 目标 ${finalArgs.join(' ')}`);
console.log('[build] 镜像已设：');
for (const [k, v] of Object.entries(MIRRORS)) console.log(`        ${k}=${v}`);

const started = Date.now();
const r = spawnSync(process.execPath, [cli, ...finalArgs], {
  cwd: ROOT,
  env: { ...process.env, ...MIRRORS },
  stdio: 'inherit', // 实时透传：卡住时能一眼看出卡在哪一步（不要 pipe 攒到最后）
});
const secs = ((Date.now() - started) / 1000).toFixed(1);
if (r.status !== 0) {
  console.error(`[build] 失败：退出码 ${r.status}（耗时 ${secs}s）`);
  process.exit(r.status ?? 1);
}
const outDir = path.resolve(ROOT, pkg.build.directories.output);
console.log(`[build] 完成，耗时 ${secs}s → ${outDir}`);
for (const f of fs.existsSync(outDir) ? fs.readdirSync(outDir) : []) {
  if (f.toLowerCase().endsWith('.exe')) {
    const p = path.join(outDir, f);
    console.log(`        ${f}  ${(fs.statSync(p).size / 1024 / 1024).toFixed(1)} MB`);
  }
}
