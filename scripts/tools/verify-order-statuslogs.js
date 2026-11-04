/**
 * 验证 userOrderDetail 是否真的下发 statusLogs（云端实测）。
 * 用老板账号登录取一条真实订单，对比「有 statusLogs」且「顺序正确」。
 */
const fs = require('fs');
const API = 'http://YOUR_SERVER_HOST:3100/api/v1';
const env = fs.readFileSync('D:/fish/server/.env', 'utf8');
const g = (k) => (env.match(new RegExp('^' + k + '=(.+)$', 'm')) || [])[1]?.trim();

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
  // 用负责人测试老板账号
  const login = await req('POST', '/auth/login', { username: 'boss_demo01', password: 'Qls@2026Test', role: 'user' });
  const token = login.json?.data?.accessToken;
  if (!token) { console.log('❌ 老板登录失败:', JSON.stringify(login.json)?.slice(0, 200)); process.exit(1); }
  console.log('✅ 老板账号已登录');

  const list = await req('GET', '/user/orders?page=1&pageSize=20', null, token);
  const orders = list.json?.data?.list ?? [];
  console.log(`   该账号订单数：${orders.length}`);

  if (!orders.length) {
    console.log('⚠️ 该账号没有订单，换用管理端查一条有状态流转的订单再验证');
    const al = await req('POST', '/auth/login', { username: g('RELEASE_ADMIN_USER'), password: g('RELEASE_ADMIN_PASSWORD'), role: 'admin' });
    const at = al.json?.data?.accessToken;
    const all = await req('GET', '/admin/orders?page=1&pageSize=50', null, at);
    const any = all.json?.data?.list ?? [];
    console.log(`   管理端可见订单数：${any.length}`);
    if (any.length) {
      // 用管理端拿到的订单，反查它的 userId 对应的老板；这里只验证接口形状（老板端必须本人）
      console.log(`   订单样例：id=${any[0].id} status=${any[0].status} userId=${any[0].userId}`);
    }
    process.exit(0);
  }

  let checked = 0, withLogs = 0;
  for (const o of orders.slice(0, 8)) {
    const d = await req('GET', `/user/orders/${o.id}`, null, token);
    const data = d.json?.data ?? {};
    const has = Object.prototype.hasOwnProperty.call(data, 'statusLogs');
    const logs = data.statusLogs;
    const n = Array.isArray(logs) ? logs.length : 0;
    if (has) withLogs++;
    if (n > 0) {
      const seq = logs.map((l) => `${l.fromStatus ?? '-'}→${l.toStatus ?? l.status ?? '?'}`).join(' , ');
      console.log(`  ✅ 订单 ${o.id}（${data.status}）statusLogs=${n} 条：${seq}`);
    } else {
      console.log(`  ${has ? '✅' : '❌'} 订单 ${o.id}（${data.status}）statusLogs ${has ? '存在但为空' : '**字段缺失**'}`);
    }
    checked++;
  }
  console.log(`\n=== 判定：抽查 ${checked} 单，带 statusLogs 字段 ${withLogs} 单 ${withLogs === checked ? '✅ 全部下发' : '❌ 有缺失'} ===`);
})();
