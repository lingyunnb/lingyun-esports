/**
 * 验证 GrantDto 金额精度修复（云端实测）。
 * 覆盖：小数可发放 / 整数可发放 / 3 位小数被拒 / 低于 1 被拒 / 超上限被拒
 * 每个用例都用**唯一幂等键**，且只对测试账号 boss_demo01 操作，跑完打印余额变化。
 */
const API = 'http://YOUR_SERVER_HOST:3100/api/v1';
const fs = require('fs');
const path = require('path');

const env = fs.readFileSync('D:/fish/server/.env', 'utf8');
const g = (k) => (env.match(new RegExp('^' + k + '=(.+)$', 'm')) || [])[1]?.trim();
const ADMIN = g('RELEASE_ADMIN_USER');
const PASS = g('RELEASE_ADMIN_PASSWORD');

async function req(method, p, body, token) {
  const r = await fetch(API + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await r.json(); } catch { /* ignore */ }
  return { status: r.status, json };
}

(async () => {
  const login = await req('POST', '/auth/login', { username: ADMIN, password: PASS, role: 'admin' });
  const token = login.json?.data?.accessToken;
  if (!token) { console.log('❌ 管理员登录失败'); process.exit(1); }
  console.log('已登录云端管理员\n');

  // 目标账号：负责人测试账号（余额变化可追溯）
  const target = '1297';
  const before = (await req('GET', `/admin/wallets?keyword=boss_demo01`, null, token)).json?.data?.list?.[0]?.balance;
  console.log(`目标账号 boss_demo01(${target}) 操作前余额: ¥${before}\n`);

  const cases = [
    { amount: 28.88, expect: 'OK', why: '2 位小数（**本次修复的核心场景**：老板付 28.88 → 管理员发 28.88）' },
    { amount: 1, expect: 'OK', why: '整数（回归：原本就该能发）' },
    { amount: 9.99, expect: 'OK', why: '带小数的商品价（9.9 元档）' },
    { amount: 28.888, expect: 'FAIL', why: '3 位小数 → 应被拒（超契约精度）' },
    { amount: 0.5, expect: 'FAIL', why: '低于 1 → 应被拒（契约下界，未改）' },
    { amount: 10_000_001, expect: 'FAIL', why: '超上限 → 应被拒（契约上界，未改）' },
  ];

  let pass = 0, fail = 0;
  for (const c of cases) {
    const key = `probe-dto-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    const r = await req('POST', '/admin/wallets/grant', { userId: target, amount: c.amount, reason: 'DTO 精度修复验证', idempotencyKey: key }, token);
    const ok = r.json?.code === 0;
    const got = ok ? 'OK' : 'FAIL';
    const good = got === c.expect;
    if (good) pass++; else fail++;
    console.log(`  ${good ? '✅' : '❌'} amount=${String(c.amount).padEnd(10)} 期望=${c.expect.padEnd(5)} 实际=${got.padEnd(5)} ${ok ? '' : '「' + (r.json?.message ?? '') + '」'}`);
    console.log(`       ${c.why}`);
  }

  const after = (await req('GET', `/admin/wallets?keyword=boss_demo01`, null, token)).json?.data?.list?.[0]?.balance;
  const delta = Number(after) - Number(before);
  console.log(`\n操作后余额: ¥${after}   变化: ${delta >= 0 ? '+' : ''}${delta.toFixed(2)}`);
  console.log(`（应为 28.88 + 1 + 9.99 = 39.87）${Math.abs(delta - 39.87) < 0.005 ? ' ✅ 一致' : ' ⚠️ 不一致'}`);

  console.log(`\n=== 判定：${pass} 通过, ${fail} 失败 ===`);
  process.exit(fail === 0 ? 0 : 1);
})();
