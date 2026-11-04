/**
 * 把专用测试超管的账密写进 server/.env（发版/回归两条链路的兜底档）。
 *
 * 为什么用 Node 而不是 PowerShell：凭据文件是 **UTF-8 无 BOM**，Windows PowerShell 5.1
 * 默认按 ANSI 读 → 中文被毁、JSON 解析失败、变量取到空值（2026-10-08 踩过）。
 *
 * 幂等：已有 REGRESSION_ADMIN_USER / RELEASE_ADMIN_USER 就只更新口令，不重复追加块。
 * 口令不打印到 stdout。
 */
import fs from 'node:fs';

const CRED = 'D:\\fish\\data\\temp\\test-admin-credentials.json';
const ENV = 'D:\\fish\\server\\.env';

const parsed = JSON.parse(fs.readFileSync(CRED, 'utf8'));
const cred = Array.isArray(parsed) ? parsed[0] : parsed;
const user = cred.username;
const pass = cred.password ?? cred.pass;
if (!user || !pass) throw new Error('凭据文件缺少 username/password');

let text = fs.readFileSync(ENV, 'utf8');
const has = (k) => new RegExp(`^${k}=`, 'm').test(text);
const setOrAppend = (k, v) => {
  if (has(k)) {
    text = text.replace(new RegExp(`^${k}=.*$`, 'm'), `${k}=${v}`);
  } else {
    if (!text.endsWith('\n')) text += '\n';
    text += `${k}=${v}\n`;
  }
};

const isNew = !has('REGRESSION_ADMIN_USER');
if (isNew) {
  if (!text.endsWith('\n')) text += '\n';
  text +=
    '\n# ── 专用测试超管（发版/回归共用账号；2026-10-08 起替代已删除的 fishadmin）──\n' +
    '# 由 scripts/tools/create-test-admin.js 创建、rotate-test-admin-password.mjs 轮换；\n' +
    '# 口令只落在这里与 data/temp/test-admin-credentials.json，不要在聊天/报告/提交里明文出现。\n';
}
for (const k of ['REGRESSION_ADMIN_USER', 'RELEASE_ADMIN_USER']) setOrAppend(k, user);
for (const k of ['REGRESSION_ADMIN_PASSWORD', 'RELEASE_ADMIN_PASSWORD']) setOrAppend(k, pass);

// 顺手把已失效的 fishadmin 键标注清楚（保留值不删，便于回溯；仅加注释）
if (has('FISHADMIN_USERNAME') && !/FISHADMIN_USERNAME 已失效/.test(text)) {
  text = text.replace(/^FISHADMIN_USERNAME=/m, '# 已失效（2026-10-08 fishadmin 账号随测试数据清理被删除）：FISHADMIN_USERNAME=');
  text = text.replace(/^FISHADMIN_PASSWORD=/m, '# 已失效：FISHADMIN_PASSWORD=');
}

fs.writeFileSync(ENV, text);
console.log(`${isNew ? '已追加' : '已更新'} server/.env：REGRESSION_ADMIN_* / RELEASE_ADMIN_* = ${user}（口令已写入，未打印）`);
console.log(`  .env 现存关键键：${['ADMIN_USERNAME', 'REGRESSION_ADMIN_USER', 'RELEASE_ADMIN_USER', 'FISHADMIN_USERNAME'].filter(has).join(', ')}`);
