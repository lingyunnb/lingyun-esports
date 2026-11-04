/**
 * 分页参数边界回归（docs/03、docs/09）
 *
 * 背景：查询参数不可信。历史实现 `Number(page) || 1` 只挡 NaN，挡不住负数与
 * Infinity（负数 truthy 不回落默认值），非法值直达 TypeORM skip/take → 500。
 * 已复现 9 个端点全部 500（含公开未认证的 /public/products）。
 *
 * 本脚本断言：任何畸形分页输入都不得产生 5xx。
 * 用法：node scripts/test-pagination.js   （需后端已在 3100 运行）
 */
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 3100;

/** 从 server/.env 读取管理员凭据（不硬编码，docs/09） */
function env(key) {
  const txt = fs.readFileSync(path.join(__dirname, '..', 'server', '.env'), 'utf8');
  const m = txt.match(new RegExp(`^${key}=(.*)$`, 'm'));
  return m ? m[1].trim() : '';
}

function req(method, p, body, token) {
  return new Promise((resolve) => {
    const data = body ? JSON.stringify(body) : null;
    const r = http.request(
      { host: '127.0.0.1', port: PORT, path: '/api/v1' + p, method,
        headers: { 'Content-Type': 'application/json',
          ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
          ...(token ? { Authorization: 'Bearer ' + token } : {}) } },
      (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => {
        let j; try { j = JSON.parse(b); } catch { j = b.slice(0, 100); }
        resolve({ status: res.statusCode, body: j });
      }); },
    );
    r.on('error', (e) => resolve({ status: 0, body: String(e) }));
    if (data) r.write(data);
    r.end();
  });
}

(async () => {
  const login = async (username, password, role) =>
    (await req('POST', '/auth/login', { username, password, role })).body?.data?.accessToken;

  const admin = await login(env('ADMIN_USERNAME'), env('ADMIN_PASSWORD'), 'admin');
  const worker = await login('worker01', 'password123', 'worker');
  const user = await login('boss_demo', 'password123', 'user');
  if (!admin || !worker || !user) { console.error('✗ 登录失败，无法测试'); process.exit(1); }

  // [方法, 路径, token, 说明] —— 全部是畸形输入，任何 5xx 都算失败
  const cases = [
    ['GET', '/admin/users?page=1&pageSize=abc', admin, '非数字 pageSize'],
    ['GET', '/admin/users?page=1&pageSize=-5', admin, '负数 pageSize'],
    ['GET', '/admin/users?page=abc', admin, '非数字 page'],
    ['GET', '/admin/users?page=1e999&pageSize=10', admin, 'Infinity page'],
    ['GET', '/admin/users?page=1&pageSize=10.5', admin, '小数 pageSize'],
    ['GET', '/admin/chat/conversations?page=-1&pageSize=-1', admin, '双负数（管理端聊天）'],
    ['GET', '/admin/forum/posts?page=-1&pageSize=10', admin, '负数 page（论坛管理）'],
    ['GET', '/admin/orders?page=-1&pageSize=-1', admin, '负数（订单管理）'],
    ['GET', '/admin/products?page=1e999&pageSize=abc', admin, 'Infinity + 非数字'],
    ['GET', '/worker/order-hall?page=-5&pageSize=10', worker, '负数 page（接单大厅）'],
    ['GET', '/worker/order-hall?page=1&pageSize=-5', worker, '负数 pageSize（接单大厅）'],
    ['GET', '/worker/order-hall?page=1e999&pageSize=10', worker, 'Infinity page（接单大厅）'],
    ['GET', '/worker/orders?page=-5&pageSize=10.9', worker, '负数+小数（工作端订单）'],
    ['GET', '/user/orders?page=1&pageSize=-5', user, '负数 pageSize（老板端订单）'],
    ['GET', '/user/orders?page=1e999&pageSize=10', user, 'Infinity page（老板端订单）'],
    ['GET', '/user/wallet/transactions?page=-1&pageSize=-1', user, '负数（钱包流水）'],
    ['GET', '/user/friends?page=0&pageSize=0', user, '零值'],
    ['GET', '/user/notifications?page=-1&pageSize=abc', user, '负数+非数字（通知）'],
    ['GET', '/public/products?page=-1&pageSize=10', null, '公开端点负数（未认证）'],
    ['GET', '/public/products?page=1e999&pageSize=10', null, '公开端点 Infinity（未认证）'],
    // 正常值必须仍然工作（防过度修复）
    ['GET', '/admin/users?page=1&pageSize=20', admin, '正常值（用户列表）'],
    ['GET', '/admin/users?page=2&pageSize=5', admin, '第 2 页'],
    ['GET', '/worker/order-hall?page=1&pageSize=10', worker, '正常值（大厅）'],
    ['GET', '/user/orders?page=1&pageSize=10', user, '正常值（订单）'],
  ];

  let pass = 0, fail = 0;
  for (const [m, p, tk, label] of cases) {
    const r = await req(m, p, null, tk);
    const isNormal = label.startsWith('正常值') || label === '第 2 页';
    const ok = r.status > 0 && r.status < 500 && (!isNormal || r.status === 200);
    if (ok) pass++; else fail++;
    if (!ok) console.log(`✗ ${label.padEnd(24)} ${p} → ${r.status} ${JSON.stringify(r.body).slice(0, 80)}`);
  }

  console.log(`\n分页边界回归：${pass}/${cases.length} 通过${fail ? `，${fail} 失败` : ''}`);
  process.exit(fail ? 1 : 0);
})();
