/**
 * `PUT /admin/settings/:key` 入口校验 · **可离线跑的单元断言**（2026-10-17 真事故回归）
 *
 * 运行（**不需要起服务、不需要数据库**；exit 0 = 全通过）：
 * ```
 * cd server
 * npx ts-node -T -O '{"module":"commonjs","moduleResolution":"node","esModuleInterop":true,"experimentalDecorators":true,"emitDecoratorMetadata":true,"target":"ES2023"}' \
 *   ../scripts/tools/setting-put-validation-check.ts
 * ```
 *
 * 为什么要有这一条（e2e `setting-cfgvalue-e2e.js` 之外）：
 * 事故是"**看起来成功其实没写**"，而判定就在控制器**入口**、与数据库无关 ——
 * 直接实例化控制器即可把三条分支钉死，随时可跑。
 * e2e 那条覆盖的是"真的写进库 / 真的没写进库"（需要服务 + 库）。
 *
 * 覆盖（与 e2e 一一对应）：
 *  ① 缺 `cfgValue`（只传 `{ value: [...] }`，即今天踩坑的原样）→ 400，**service 一次都没被调**
 *  ② 裸数组 body → 400
 *  ③ `cfgValue: []` / `"abc"` / `null` → 400（"必须是对象" / "缺少 cfgValue"）
 *  ④ 空 body → 400
 *  ⑤ 正常 `{ cfgValue: {value: 42}, description: 'd' }` → 走到 service，参数逐项对齐
 *     （`SystemSettingService.update` 的签名与语义**一字未动**：仍是 5 个参数，第 5 个是审计身份）
 *
 * 实现说明：本文件刻意放在 `scripts/tools/`（与其它 e2e 同处），
 * 所以 **import 一律走** `path.join(仓库根, 'server', ...)` 的绝对路径 **require**
 * —— 这样既不用把测试文件塞进 `server/src`（避免污染 `nest build` 产物），
 * 又能复用 server 的 `node_modules` 与 ts-node 的 .ts 加载器。
 */
'use strict';

/* eslint-disable @typescript-eslint/no-var-requires */
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const SERVER = path.join(ROOT, 'server');
const { BadRequestException } = require(path.join(SERVER, 'node_modules', '@nestjs/common'));
const { SystemSettingController } = require(path.join(
  SERVER,
  'src',
  'modules',
  'setting',
  'system-setting.controller',
));

const PHASE = 'PUT /admin/settings/:key 入口校验';
let pass = 0;
let fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) {
    pass += 1;
    console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
};

/** service 调用记录（**校验必须发生在它之前**：400 分支跑完这里必须还是空数组） */
const serviceCalls = [];
const fakeService = {
  update: (...args) => {
    serviceCalls.push(args);
    return { settingKey: args[0], cfgValue: args[1] };
  },
};
const fakeDataSource = { query: async () => [{ code: 'super_admin' }] };
const controller = new SystemSettingController(fakeService, fakeDataSource);

/** 控制器只用到这几项（`clientIpOf` 要 `header()`） */
const fakeReq = {
  user: { userId: '1' },
  method: 'PUT',
  path: '/admin/settings/e2e_key',
  requestId: 'req-1',
  header: () => undefined,
  headers: {},
  ip: '127.0.0.1',
  socket: { remoteAddress: '127.0.0.1' },
};

async function expect400(label, body, expectInMessage) {
  try {
    await controller.update('e2e_key', body, fakeReq);
    ok(label, false, '期望 400，实际通过（这正是那次事故的行为）');
  } catch (e) {
    const is400 = e instanceof BadRequestException;
    const msg = is400 ? e.message : String(e);
    ok(label, is400 && String(msg).includes(expectInMessage), `400「${msg}」`);
  }
}

(async () => {
  console.log(`=== ${PHASE} ===`);

  await expect400('① 缺 cfgValue（只传 { value: [...] }）', { value: [10, 20, 30] }, '缺少 cfgValue');
  await expect400('② 裸数组 body', [1, 2, 3], '缺少 cfgValue');
  await expect400('③ cfgValue: []', { cfgValue: [] }, '必须是对象');
  await expect400('③ cfgValue: "abc"', { cfgValue: 'abc' }, '必须是对象');
  await expect400('③ cfgValue: null', { cfgValue: null }, '缺少 cfgValue');
  await expect400('④ body 为空', undefined, '缺少 cfgValue');
  ok('⑤ 以上 400 分支一次都没走到 service（不会"静默成功"）', serviceCalls.length === 0, `calls=${serviceCalls.length}`);

  await controller.update('e2e_key', { cfgValue: { value: 42 }, description: 'd' }, fakeReq);
  const args = serviceCalls[0] || [];
  ok('⑤ 正常对象 → 走到 service', serviceCalls.length === 1, `calls=${serviceCalls.length}`);
  ok('⑤ 第 1 个参数 = 配置 key', args[0] === 'e2e_key', String(args[0]));
  ok('⑤ 第 2 个参数 = cfgValue 原样透传', JSON.stringify(args[1]) === '{"value":42}', JSON.stringify(args[1]));
  ok('⑤ 第 3 个参数 = description', args[2] === 'd', String(args[2]));
  ok('⑤ 第 4 个参数 = 管理员角色码（超管判定用）', args[3] === 'super_admin', String(args[3]));
  const actor = args[4] || {};
  ok(
    '⑤ 第 5 个参数 = 审计身份（谁 / 哪个请求）',
    actor.userId === '1' && actor.method === 'PUT' && actor.path === '/admin/settings/e2e_key',
    JSON.stringify(actor),
  );

  console.log(`=== 结果：${pass} PASS / ${fail} FAIL ===`);
  process.exit(fail === 0 ? 0 : 1);
})();
