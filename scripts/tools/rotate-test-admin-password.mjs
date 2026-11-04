/**
 * 轮换专用测试超管 opsadmin 的口令（用其自身会话，绝不用负责人账号）。
 *
 * 背景：2026-10-08 清理测试数据时 fishadmin 被删，opsadmin 成为发版/回归的共用账号；
 * 它当晚被某个 worker 在聊天报告里明文贴过一次 → 做一次口令轮换（安全卫生）。
 *
 * 步骤：① 用旧口令登录 → ② POST /admin/admins/:id/reset-password 换新口令
 *      ③ 用新口令登录自证 → ④ 更新 data/temp/test-admin-credentials.json
 * 注意：登录限流 5 次/分/IP+账号 —— 本脚本只登录 2 次。
 */
import fs from 'node:fs';
import crypto from 'node:crypto';

const API = 'http://127.0.0.1:3100/api/v1';
const CRED = 'D:\\fish\\data\\temp\\test-admin-credentials.json';

const raw = JSON.parse(fs.readFileSync(CRED, 'utf8'));
// 文件形态是**数组**（既有工具 create-test-admin.js 写的）：要么整体是数组，要么含 accounts 数组
const isArr = Array.isArray(raw);
const list = isArr ? raw : (raw.accounts ?? [raw]);
const idx = list.findIndex((x) => String(x.username) === 'opsadmin');
if (idx < 0) {
  console.error('拒绝执行：凭据文件里找不到 opsadmin');
  process.exit(2);
}
const cred = list[idx];
const username = cred.username;
const oldPassword = cred.password ?? cred.pass;
if (username !== 'opsadmin') {
  console.error(`拒绝执行：目标账号是 ${username}（仅允许轮换 opsadmin）`);
  process.exit(2);
}

/** 生成一个 20 位强口令（大小写+数字+符号，避开易混字符与 shell 特殊字符） */
function newPassword() {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghijkmnopqrstuvwxyz';
  const digit = '23456789';
  const sym = '!@#%^&*-_=+';
  const all = upper + lower + digit + sym;
  const pick = (s) => s[crypto.randomInt(s.length)];
  let out = pick(upper) + pick(lower) + pick(digit) + pick(sym);
  while (out.length < 20) out += pick(all);
  return out.split('').sort(() => crypto.randomInt(3) - 1).join('');
}

async function post(path, body, token) {
  const res = await fetch(API + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text.slice(0, 200) }; }
  return { status: res.status, json };
}

const login = (password) => post('/auth/login', { username, password, role: 'admin' });

// ① 旧口令登录
const l1 = await login(oldPassword);
if (l1.status !== 200 || l1.json.code !== 0) {
  console.error(`旧口令登录失败：status=${l1.status} code=${l1.json.code} message=${l1.json.message}`);
  process.exit(1);
}
const token = l1.json.data.accessToken ?? l1.json.data.access_token;
const d = l1.json.data ?? {};
const userId = d.user?.id ?? d.userId ?? d.user?.userId ?? cred.userId;
const adminId = cred.adminId ?? d.admin?.id;
console.log(`① 旧口令登录成功（userId=${userId} / adminId=${adminId}）`);

// ② 换口令（该接口按 admin 档案 id 查；两个候选都试一次，避免猜错）
const next = newPassword();
const candidates = [adminId, userId].filter((x) => x !== undefined && x !== null);
let r = null;
for (const id of candidates) {
  r = await post(`/admin/admins/${id}/reset-password`, { password: next }, token);
  console.log(`② reset-password id=${id} → status=${r.status} code=${r.json.code} message=${r.json.message ?? ''}`);
  if (r.status === 200 || r.status === 201) break;
}
if (!r || (r.status !== 200 && r.status !== 201)) {
  console.error('轮换失败，未改动凭据文件');
  process.exit(1);
}

// ③ 新口令自证
const l2 = await login(next);
const ok = l2.status === 200 && l2.json.code === 0;
console.log(`③ 新口令登录自证 → status=${l2.status} code=${l2.json.code}（${ok ? '通过' : '失败'}）`);
if (!ok) {
  console.error('新口令不可用！请人工介入（旧口令可能已失效）');
  process.exit(1);
}

// ④ 落盘（保留旧口令到 previousPassword 便于回溯；文件在 data/temp，不入 git）
const updated = {
  ...cred,
  password: next,
  rotatedAt: new Date().toISOString(),
  rotatedReason: '2026-10-08 口令曾在会话报告中明文出现，做一次轮换（安全卫生）',
  previousPassword: oldPassword,
};
delete updated.pass;
if (isArr) {
  list[idx] = updated;
  fs.writeFileSync(CRED, JSON.stringify(list, null, 2));
} else if (raw.accounts) {
  raw.accounts = list;
  fs.writeFileSync(CRED, JSON.stringify(raw, null, 2));
} else {
  fs.writeFileSync(CRED, JSON.stringify(updated, null, 2));
}
console.log('④ 凭据文件已更新（data/temp/test-admin-credentials.json，保留 previousPassword 便于回溯）');
console.log('   新口令不在本输出中打印 —— 需要时请读该文件。');
