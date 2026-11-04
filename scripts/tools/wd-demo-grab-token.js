#!/usr/bin/env node
/**
 * 一次性：清理前抓一枚**真实 companion 令牌**（binding 341），用于清理后实测 401。
 * 运行：node scripts/tools/wd-demo-grab-token.js
 */
const fs = require('fs');
const path = require('path');

const API = 'http://127.0.0.1:3100/api/v1';
const OUT = path.join(__dirname, '..', 'tmp', 'wd-demo-tokens.json');

async function req(method, url, token, body) {
  const res = await fetch(API + url, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  let json = null;
  try { json = await res.json(); } catch { /* ignore */ }
  return { status: res.status, body: json };
}

(async () => {
  // 1. 老板 1245 登录
  const boss = await req('POST', '/auth/login', null, { username: 'wd_demo_boss', password: 'password123', role: 'user' });
  if (boss.status >= 400) throw new Error(`wd_demo_boss 登录失败 ${boss.status}: ${JSON.stringify(boss.body)}`);
  const bossToken = boss.body?.data?.accessToken;
  console.log('boss login OK, status=' + boss.status + ' userId=' + (boss.body?.data?.user?.id ?? '?'));

  // 2. 绑定打手 1244 → 拿 companion 令牌
  const bind = await req('POST', '/user/identity/bind', bossToken, { username: 'wd_demo_worker', password: 'password123' });
  console.log('bind status=' + bind.status + ' bindingId=' + (bind.body?.data?.bindingId ?? bind.body?.data?.id ?? '?'));
  const d = bind.body?.data ?? {};
  const companionToken = d.companionToken ?? d.accessToken;
  const companionRefresh = d.companionRefreshToken ?? d.refreshToken;
  if (!companionToken) throw new Error('拿不到 companionToken: ' + JSON.stringify(bind.body));

  // 3. 证明清理前可用（companion 白名单：GET /auth/me）
  const me = await req('GET', '/auth/me', companionToken);
  console.log('companion GET /auth/me (before wipe) = ' + me.status);
  // 4. 证明 companion 确实受限于打手族：/worker/* 可用
  const wallet = await req('GET', '/worker/my-wallet', companionToken);
  console.log('companion GET /worker/my-wallet (before wipe) = ' + wallet.status);

  fs.writeFileSync(OUT, JSON.stringify({
    bindingId: d.bindingId ?? null,
    companionToken,
    companionRefreshToken: companionRefresh,
    bossToken,
    beforeWipe: { authMe: me.status, myWallet: wallet.status },
    capturedAt: new Date().toISOString(),
  }, null, 2));
  console.log('saved -> ' + OUT);
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
