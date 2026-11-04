/**
 * 客服大厅 e2e（负责人 2026-10-08：「有客服权限的人用打手端主动接」）—— **可复跑，自建自清**。
 *
 * 覆盖（对应任务书的 ①…⑦ + ⑨）：
 *   ① 权限：无客服权限 → hall / claim 中文 403；有权限 → 200
 *   ② 池子口径（**2026-10-08 晚修正**）：**只有"老板至少发过一条消息"的会话才进池** ——
 *      老板打开客服页建的空会话**不**出现（不再有 `（暂无消息）` 空条目）；
 *      发首条消息后**立刻**出现；已被指派的不出现；摘要/条数/等待时长/排序/敏感字段
 *   ③ **并发抢占（核心）**：两个有客服权限的账号**同时** claim 同一会话 → 恰好一个成功，
 *      另一个 409 中文「该咨询已被其他客服接入」；库里 active 指派**恰好 1 行**（附 SQL 证据）
 *   ④ 幂等：同一人重复 claim → 不报错、不产生第二行
 *   ⑤ 指派后从大厅消失；release 后重新出现（含"退回池子"开关 0/1 的行为）
 *   ⑥ 管理端改派仍可用（回归；强制改派语义未变）
 *   ⑦ WS 事件：`cs:new` / `cs:claimed` / `chat:assigned` / `chat:unassigned`
 *      —— 含**受众过滤**（无客服权限的在线打手与老板端都收不到 `cs:new`）
 *   ⑧ 打手态（companion）真机路径：绑定 → hall 200 → claim 200 → 解绑即失效
 *   ⑨ **并发：大厅 claim ↔ 管理端 assign**（2026-10-08 晚补）——
 *      两者抢同一把会话行锁，落败一方**中文 409**（不是 500），库里 active **恰好 1 行**
 *
 * 账号（**绝不用负责人账号**）：管理端走 `scripts/tools/regression-admin.js`
 * （= `server/.env` 的 `REGRESSION_ADMIN_USER`，专用测试超管 opsadmin）；
 * 打手/老板用仓库共享夹具 `boss_demo / tuser_634800 / worker01 / worker_test2`
 * （由 `scripts/tmp/test-fixtures.js` 幂等引导，本脚本只 require 它的 ensure* 函数，不复制一份）。
 *
 * 自建自清：跑前跑后都清掉两个测试老板的 `type='cs'` 会话（消息/指派/会话行），
 * 并把 worker_test2 的客服权限与「退回池子」开关**还原到夹具基线**（0 / 1）。
 *
 * 运行：node scripts/tools/cs-hall-e2e.js
 */
const fs = require('fs');
const mysql = require('D:/fish/server/node_modules/mysql2/promise');
const { io } = require('D:/fish/server/node_modules/socket.io-client');
const { adminUser, adminPassword: adminPw } = require('./regression-admin');
const fixtures = require('../tmp/test-fixtures');

const BASE = 'http://127.0.0.1:3100/api/v1';
const WS = 'http://127.0.0.1:3100';
const BOSS_A = 'boss_demo';
const BOSS_B = 'tuser_634800';
const WORKER_A = 'worker01'; // 夹具：接单+客服
const WORKER_B = 'worker_test2'; // 夹具基线：无任何权限（本脚本临时授客服权限，结束时撤销）
const RELEASE_KEY = 'cs_hall_release_enabled';

let pass = 0;
let fail = 0;
/** 断言：cond 为真 → PASS（绿）；否则 FAIL（红）并打印实际值，便于定位 */
function ok(name, cond, extra = '') {
  if (cond) {
    pass += 1;
    console.log(`PASS  ${name}${extra ? ' | ' + extra : ''}`);
  } else {
    fail += 1;
    console.log(`FAIL  ${name}${extra ? ' | ' + extra : ''}`);
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isChinese = (s) => /[\u4e00-\u9fa5]/.test(String(s ?? ''));
const j = (v) => JSON.stringify(v);

/**
 * 单实例锁（**只为防"两个人同时跑"**）：本套件用的是**共享夹具账号**（boss_demo / worker01 …），
 * 两个实例同时跑会互相顶号（单设备铁律 → 401）并互删对方的会话（→ seq=2 / 条数不对 / 摘要是别人的消息）。
 * 2026-10-08 晚实测：客户端那批与本脚本同时跑，两边都花式变红 —— 根因不是断言，是**并发跑**。
 *
 * 口径：拿不到锁时**有界等待**（最多 120s，每 3s 探一次），仍被占用则中文提示 + 退出码 2；
 * 任何读写锁文件的异常都**退化放行**（fail-open：锁只是提醒，不能让套件本身跑不起来）。
 * 进程退出时自动删除（`process.on('exit')` 覆盖所有 exit 路径，包括异常分支）。
 */
const LOCK_FILE = 'D:/fish/data/temp/cs-hall-e2e.lock';
function lockHolderPid() {
  try {
    const info = JSON.parse(fs.readFileSync(LOCK_FILE, 'utf8'));
    const pid = Number(info?.pid ?? 0);
    if (!pid) return null;
    process.kill(pid, 0); // 抛错 = 进程已不在 → 陈旧锁
    return pid;
  } catch {
    return null;
  }
}
async function acquireRunLock() {
  try {
    fs.mkdirSync('D:/fish/data/temp', { recursive: true });
    const deadline = Date.now() + 120_000;
    for (;;) {
      const holder = lockHolderPid();
      if (!holder) break;
      if (Date.now() > deadline) {
        console.error(`\n[锁] 检测到另一个 cs-hall-e2e 实例仍在跑（pid=${holder}）—— 本轮放弃，避免两边互相顶号。`);
        console.error('[锁] 请等它跑完（约 30s）后重跑：node scripts/tools/cs-hall-e2e.js');
        process.exit(2);
      }
      console.log(`[锁] 另一个实例仍在跑（pid=${holder}），等待中…（最多 120s）`);
      await sleep(3000);
    }
    fs.writeFileSync(LOCK_FILE, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }), 'utf8');
    process.on('exit', () => {
      try {
        fs.unlinkSync(LOCK_FILE);
      } catch {
        /* 已被清掉/无权限：忽略 */
      }
    });
  } catch (e) {
    console.log(`[锁] 跳过（读写锁文件失败：${e.message}）—— 不阻塞本轮`);
  }
}

/** 会话的首条**老板**消息（与服务端 `fm` 子查询同一口径：sender_type='user' 且 seq 最小） */
const firstUserMsgSql = `SELECT seq, msg_type, content, recalled FROM chat_message
                          WHERE conversation_id = ? AND sender_type = 'user' ORDER BY seq ASC LIMIT 1`;
/**
 * 首条摘要的**期望值**（把服务端口径写在这里，用"实际首条消息"推导，而不是假设它一定是本次构造的长文本）：
 * 无消息 → 占位；已撤回 → 撤回占位；图片 → 【图片】；其它非文字 → 【消息】；文字 → 折叠空白、>40 字截断补 `…`。
 */
function expectPreview(m) {
  if (!m) return '（暂无消息）';
  if (Number(m.recalled) === 1) return '【消息已撤回】';
  if (m.msg_type === 'image') return '【图片】';
  if (m.msg_type !== 'text') return '【消息】';
  const text = String(m.content ?? '').replace(/\s+/g, ' ').trim();
  if (!text) return '（暂无消息）';
  return text.length > 40 ? `${text.slice(0, 40)}…` : text;
}

async function req(method, path, token, body) {
  const r = await fetch(BASE + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try {
    json = await r.json();
  } catch {
    /* 空响应体 */
  }
  return { status: r.status, json, message: json?.message, data: json?.data };
}
const login = (username, password, role) => req('POST', '/auth/login', null, { username, password, role });
const wsConnect = (token) => io(WS + '/ws/chat', { auth: { token }, transports: ['websocket', 'polling'] });

(async () => {
  await acquireRunLock();
  const env = fs.readFileSync('D:/fish/server/.env', 'utf8');
  const g = (k) => env.match(new RegExp('^' + k + '=(.+)$', 'm'))[1].trim();
  const db = await mysql.createConnection({
    host: g('DB_HOST'),
    port: Number(g('DB_PORT')),
    user: g('DB_USER'),
    password: g('DB_PASSWORD'),
    database: g('DB_NAME'),
  });
  const q = async (sql, args) => (await db.query(sql, args))[0];

  // ---------- 自建自清：清掉两个测试老板的客服会话 + 还原夹具基线 ----------
  const testBossIds = (await q('SELECT id FROM user WHERE username IN (?, ?)', [BOSS_A, BOSS_B])).map((r) => String(r.id));
  const wipeCs = async () => {
    if (!testBossIds.length) return 0;
    const convs = (await q("SELECT id FROM chat_conversation WHERE user_id IN (?) AND type = 'cs'", [testBossIds])).map((r) => String(r.id));
    if (!convs.length) return 0;
    await q('DELETE FROM chat_message WHERE conversation_id IN (?)', [convs]);
    await q('DELETE FROM chat_conversation_assign WHERE conversation_id IN (?)', [convs]);
    await q('DELETE FROM chat_conversation WHERE id IN (?)', [convs]);
    return convs.length;
  };
  /**
   * 夹具基线还原：worker_test2 客服权限 = 0、退回开关 = 1。
   * 直接走 SQL 而不是管理端接口是**刻意**的：清理动作必须在脚本异常退出时也尽量可预期，
   * 而管理端接口要额外登录（登录限流 5 次/分/账号）。**只动这两处夹具字段，不碰业务数据**。
   */
  const restoreBaseline = async () => {
    await q(
      "UPDATE worker w JOIN user u ON u.id = w.user_id SET w.can_serve_customer = 0 WHERE u.username = ?",
      [WORKER_B],
    );
    await q("UPDATE system_setting SET cfg_value = JSON_OBJECT('value', 1) WHERE setting_key = ?", [RELEASE_KEY]);
  };
  /** 两个测试老板名下的客服会话残留计数（跑前/跑后各断言一次；**只看测试账号自己**，不碰真实数据） */
  const csLeft = async () =>
    (
      await q(
        `SELECT (SELECT COUNT(*) FROM chat_conversation WHERE user_id IN (?) AND type='cs') AS cs_convs,
                (SELECT COUNT(*) FROM chat_conversation_assign a JOIN chat_conversation c ON c.id=a.conversation_id WHERE c.user_id IN (?) AND c.type='cs') AS assigns,
                (SELECT COUNT(*) FROM chat_message m JOIN chat_conversation c ON c.id=m.conversation_id WHERE c.user_id IN (?) AND c.type='cs') AS msgs,
                (SELECT can_serve_customer FROM worker w JOIN user u ON u.id=w.user_id WHERE u.username=?) AS cs_perm`,
        [testBossIds, testBossIds, testBossIds, WORKER_B],
      )
    )[0];

  console.log('=== 客服大厅 e2e（抢占式接入 + 管理端改派兜底）===');
  console.log(`[清理] 跑前清掉测试老板客服会话 ${await wipeCs()} 条；基线还原 worker_test2 客服权限=0、退回开关=1`);
  await restoreBaseline();
  // 夹具前置断言：**每次跑都从干净状态出发**（这是 2026-10-08 晚 6 条"状态残留型"假红的根因防线）
  const leftBefore = await csLeft();
  ok('夹具-前置：两个测试老板的 cs 会话/消息/指派已清零（造样本前先清干净）',
    leftBefore.cs_convs === 0 && leftBefore.msgs === 0 && leftBefore.assigns === 0 && Number(leftBefore.cs_perm) === 0,
    j(leftBefore));

  // ---------- 登录（每个账号恰好一次：登录限流 5 次/分/账号） ----------
  const al = await login(adminUser, adminPw, 'admin');
  if (al.status !== 200) throw new Error(`管理端登录失败（${adminUser}）：${al.status} ${al.message}`);
  const adminToken = al.data.accessToken;

  let bossAToken = await fixtures.ensureBoss(BOSS_A, '演示老板');
  const bossBToken = await fixtures.ensureBoss(BOSS_B, '测试用户');
  /**
   * 打手 token = **companion**（2026-10-13 改造，**不要改回 worker primary**）
   *
   * 工作端到期收口已生效（产品既定行为）：`POST /auth/login`（role=worker）**一律 403**。
   * 旧实现走的是 `ensureWorker` 内部那次 worker primary 登录 → 恒 403 → 落到创建分支撞
   * 「用户名已存在」→ 脚本自杀（本套件基线的 81 条断言因此长期跑不到）。
   *
   * 打手态真实入口 = 老板端「我的 → 身份 → 绑定打手账号」：夹具 `ensureWorker` 建号（管理员接口）
   * → 指定老板 `POST /user/identity/bind` → 返回 **companion** token。
   * 这里**显式把老板指成 BOSS_A / BOSS_B**（不传就用默认派生老板 `wfx_<打手名>`）：
   * 本套件里 boss_demo / tuser_634800 **就是** worker01 / worker_test2 的接单老板，
   * 绑定走自己人 → 既不额外造账号，也让"老板侧的会话"与"打手侧的客服口径"落在同一对账号上。
   *
   * 本套件要打的 `/worker/cs/hall`、`/worker/cs/hall/:id/claim`、`/worker/cs/conversations*` 全在
   * companion 白名单内（`jwt-auth.guard.ts#isCompanionAllowedRoute` 的 `/worker/*` 整族）。
   */
  const wa = await fixtures.ensureWorker(adminToken, {
    username: WORKER_A, workerNo: 'W001', nickname: '演示工作端', takeOrder: true, serveCustomer: true,
    bossUsername: BOSS_A,
  });
  const wb = await fixtures.ensureWorker(adminToken, {
    username: WORKER_B, workerNo: 'W002', nickname: '测试工作端2', takeOrder: false, serveCustomer: false,
    bossUsername: BOSS_B,
  });
  let workerAToken = wa.token;
  const workerBToken = wb.token;
  const workerAUserId = String(wa.userId);
  const workerBUserId = String(wb.userId);
  await q("UPDATE worker w JOIN user u ON u.id = w.user_id SET w.can_serve_customer = 0 WHERE u.username = ?", [WORKER_B]);
  console.log(`[账号] 管理端=${adminUser}（专用测试超管）｜ boss=${BOSS_A}/${BOSS_B} ｜ worker=${WORKER_A}#${workerAUserId}(客服) / ${WORKER_B}#${workerBUserId}(无客服权限)`);

  const workerIds = (await q(
    "SELECT w.id, u.username, w.can_serve_customer FROM worker w JOIN user u ON u.id = w.user_id WHERE u.username IN (?, ?)",
    [WORKER_A, WORKER_B],
  ));
  const workerRowId = (username) => String(workerIds.find((r) => r.username === username).id);
  const setCsPerm = (username, value) =>
    req('POST', `/admin/workers/${workerRowId(username)}/permission`, adminToken, { type: 'customer', value });
  /** 该会话此刻是否在大厅里（worker01 视角）—— 池子口径断言统一走它 */
  const hallHas = async (conversationId) =>
    ((await req('GET', '/worker/cs/hall', workerAToken)).data?.list ?? []).some(
      (x) => x.conversationId === String(conversationId),
    );
  /** 库里该会话的 active 指派行（SQL 证据统一走它） */
  const activeAssignRows = (conversationId) =>
    q("SELECT id, conversation_id, worker_user_id, status, assigned_by FROM chat_conversation_assign WHERE conversation_id = ? AND status = 'active'", [conversationId]);

  // =========================================================================
  // ① 权限：无客服权限 → 中文拒绝；有权限 → 200
  // =========================================================================
  console.log('\n--- ① 权限（每请求实时查库 worker.can_serve_customer）---');
  const convARes = await req('GET', '/user/conversation', bossAToken);
  const convA = convARes.data;
  if (!convA?.id) console.log(`      [诊断] GET /user/conversation → HTTP ${convARes.status} ${convARes.message ?? ''}（boss_demo 客服会话没拿到）`);
  ok('①-夹具：boss_demo 客服会话已创建（未指派任何人）', !!convA?.id && convA.assigned === false, `conv=${convA?.id} assigned=${convA?.assigned}`);

  const hallDenied = await req('GET', '/worker/cs/hall', workerBToken);
  ok('①-a 无客服权限 GET /worker/cs/hall → 403 中文', hallDenied.status === 403 && hallDenied.message === '无客服权限',
    `status=${hallDenied.status} message=${hallDenied.message}`);
  const claimDenied = await req('POST', `/worker/cs/hall/${convA.id}/claim`, workerBToken, {});
  ok('①-b 无客服权限 POST claim → 403 中文', claimDenied.status === 403 && claimDenied.message === '无客服权限',
    `status=${claimDenied.status} message=${claimDenied.message}`);

  const hallA = await req('GET', '/worker/cs/hall', workerAToken);
  ok('①-c 有客服权限 GET hall → 200 + list 数组', hallA.status === 200 && Array.isArray(hallA.data?.list),
    `status=${hallA.status} n=${hallA.data?.list?.length}`);
  // ⚠️ 2026-10-08 晚**新口径**：老板打开客服页建的空会话**不进池**（旧用例断言的"空会话也进池"已作废）
  // 断言只锁"这条会话不在池里"（环境无关）；**不断言 total===0** —— 池子里可能有别人的会话（别的老板/别的套件），
  // 那是环境，不是被测行为（2026-10-08 晚实测：客户端那批同时跑时 total=1 让旧断言假红）
  ok('①-d 空会话（老板只打开客服页、还没发消息）**不进池** —— 产品口径修正：不出现（暂无消息）空条目',
    !(hallA.data?.list ?? []).some((x) => x.conversationId === String(convA.id)),
    j({ list: (hallA.data?.list ?? []).map((x) => x.conversationId), total: hallA.data?.total }));
  // 同源不变量：'（暂无消息）' 这一格在新口径下不该再出现（有它 = 池子里混进了没消息的会话）
  ok('①-e 大厅里不存在 `（暂无消息）` 条目（与池子口径同源的不变量）',
    (hallA.data?.list ?? []).every((x) => x.preview !== '（暂无消息）'),
    j((hallA.data?.list ?? []).map((x) => x.preview)));

  // =========================================================================
  // ② 池子口径：**发首条消息 → 进池**；摘要 / 图片占位 / 条数 / 等待时长 / 排序 / 已指派不出现
  // =========================================================================
  console.log('\n--- ② 池子口径与摘要（首条消息才进池）---');
  const longText = '你好，我想问一下今晚八点还有没有位置，我这边三个人一起下单，需要能开麦的，预算大概两百左右，谢谢！';
  const sendTxt = await req('POST', '/user/conversation/messages', bossAToken, { clientMsgId: 'hall1', content: longText });
  // 只看"发出去了、且 seq 从 1 起递增"（不提"必须 ==1"：那是"会话必须是新建的"这一**夹具前置**的推论，
  // 前置由下面的 ②-夹具 断言把关；正常净态下这里就是 1）
  ok('②-夹具：老板首条咨询已发送（201 + seq ≥ 1）', sendTxt.status === 201 && Number(sendTxt.data?.seq) >= 1, `status=${sendTxt.status} seq=${sendTxt.data?.seq}`);
  const firstA = (await q(firstUserMsgSql, [convA.id]))[0] ?? null;
  ok('②-夹具（净态前置）：该会话的首条老板消息**就是本次构造的长文本**（清理生效 → 环境无关）',
    !!firstA && String(firstA.content) === longText,
    `first=${j(String(firstA?.content ?? '').slice(0, 24))} len=${String(firstA?.content ?? '').length}`);

  const hallAfterFirst = await req('GET', '/worker/cs/hall', workerAToken);
  const listAfterFirst = hallAfterFirst.data?.list ?? [];
  const totalAfterFirst = Number(hallAfterFirst.data?.total ?? -1);
  const firstItem = listAfterFirst.find((x) => x.conversationId === String(convA.id));
  // 同源不变量：total === waitingTotal 且与分页契约自洽（list.length === min(total, 默认每页 20)）
  // —— 不写死 total 的具体数字（池子里可能有别人的会话）
  ok('②-0 发首条消息后**立刻进池**（新口径的正向面）+ total/waitingTotal 同源、与分页自洽',
    !!firstItem &&
      hallAfterFirst.data?.total === hallAfterFirst.data?.waitingTotal &&
      listAfterFirst.length === Math.min(totalAfterFirst, 20) &&
      totalAfterFirst >= 1,
    j({ inList: !!firstItem, total: hallAfterFirst.data?.total, waitingTotal: hallAfterFirst.data?.waitingTotal, n: listAfterFirst.length }));
  ok('②-0b 等待起点 = **首条老板消息时刻**（waitingSince 与首条消息时间一致、不早于会话创建时刻）',
    !!firstItem?.waitingSince && !!firstItem?.createdAt && new Date(firstItem.waitingSince) >= new Date(firstItem.createdAt),
    `waitingSince=${firstItem?.waitingSince} createdAt=${firstItem?.createdAt}`);
  // 敏感字段：只断言"本条会话那一行"的形状（大厅里可能有别人的行，形状一致即可）
  ok('②-0c 大厅不泄漏敏感字段（无 username/phone/email/password/userId）',
    !!firstItem &&
      (hallAfterFirst.data?.list ?? []).every((x) =>
        !('username' in x) && !('phone' in x) && !('email' in x) && !('password' in x) && !('userId' in x)),
    j(Object.keys(firstItem ?? {})));

  const convB = (await req('GET', '/user/conversation', bossBToken)).data;
  const sendImg = await req('POST', '/user/conversation/messages', bossBToken, { clientMsgId: 'hall2', msgType: 'image', content: '123' });
  ok('②-夹具：第二个老板的图片咨询已发送（图片消息也算"有消息" → 同样进池）', sendImg.status === 201 && sendImg.data?.msgType === 'image', `status=${sendImg.status} type=${sendImg.data?.msgType}`);

  const hall2 = await req('GET', '/worker/cs/hall', workerAToken);
  const items = hall2.data?.list ?? [];
  const itemA = items.find((x) => x.conversationId === String(convA.id));
  const itemB = items.find((x) => x.conversationId === String(convB.id));
  ok('②-a 两条待接入都在列表里', !!itemA && !!itemB, j(items.map((x) => x.conversationId)));
  // 排序只看**两者相对次序**（A 的第一条消息早于 B）——不假设 A 一定排第 0（池子里可能有别人的会话）
  ok('②-b 排序：等待最久的在前（convA 先于 convB）',
    items.findIndex((x) => x.conversationId === String(convA.id)) >= 0 &&
      items.findIndex((x) => x.conversationId === String(convA.id)) < items.findIndex((x) => x.conversationId === String(convB.id)),
    j(items.map((x) => `${x.conversationId}:${x.waitedSeconds}s`)));
  // 摘要：用**库里实际的首条老板消息**推导期望值（不假设首条一定是本次那条长文本 —— 那是 ②-夹具 的职责）
  ok('②-c 首条咨询摘要 = 服务端口径（≤40 字原文原样；超长截断为 40 字 + …；不含换行）',
    !!itemA && !!firstA && itemA.preview === expectPreview(firstA) && itemA.preview.length <= 41 && !/\n/.test(itemA.preview),
    j({ first: String(firstA?.content ?? '').slice(0, 16), preview: itemA?.preview }));
  ok('②-c2 本次构造的长文本（>40 字）走的确实是**截断路径**（40 字 + …）',
    !!firstA && String(firstA.content).length > 40 && !!itemA && itemA.preview.endsWith('…') && itemA.preview.length === 41,
    j({ len: String(firstA?.content ?? '').length, preview: itemA?.preview }));
  ok('②-d 首条是图片 → 占位「【图片】」', itemB?.preview === '【图片】', j(itemB?.preview));
  // 条数与**库里实际条数**对齐（不写死 1：并发跑/重复跑都不该假红）
  const msgCountA = Number((await q('SELECT COUNT(*) AS n FROM chat_message WHERE conversation_id = ?', [convA.id]))[0]?.n ?? -1);
  const msgCountB = Number((await q('SELECT COUNT(*) AS n FROM chat_message WHERE conversation_id = ?', [convB.id]))[0]?.n ?? -1);
  ok('②-e 消息条数正确（= 各会话在库里的真实条数，且 ≥1）',
    itemA?.msgCount === msgCountA && itemB?.msgCount === msgCountB && msgCountA >= 1 && msgCountB >= 1,
    `A=${itemA?.msgCount}/${msgCountA} B=${itemB?.msgCount}/${msgCountB}`);
  ok('②-f 等待时长（秒 + 人读）且量级合理（DB 时钟计算，未受宿主/容器时钟差影响）',
    typeof itemA?.waitedSeconds === 'number' && itemA.waitedSeconds >= 0 && itemA.waitedSeconds < 3600 && typeof itemA?.waitedText === 'string' && itemA.waitedText.length > 0,
    `waitedSeconds=${itemA?.waitedSeconds} waitedText=${itemA?.waitedText}`);
  ok('②-g 老板昵称/中文 ID 下发给客服（且不含登录名）',
    !!itemA?.userNickname && !!itemA?.userUid && !j(itemA).includes(BOSS_A), `nickname=${itemA?.userNickname} uid=${itemA?.userUid}`);
  // total / waitingTotal 同源 + 与分页契约自洽；**不写死 2**（池子里可能有别人的会话）
  ok('②-h 统计：total / waitingTotal 同源同值、≥2（含本套件两条）、与分页契约自洽',
    hall2.data?.total === hall2.data?.waitingTotal && Number(hall2.data?.total) >= 2 && items.length === Math.min(Number(hall2.data?.total), 20),
    `total=${hall2.data?.total} waitingTotal=${hall2.data?.waitingTotal} n=${items.length}`);
  // onlineCsCount：用**权威表推导的上下界**（有客服权限且在职的打手数），不写死 0 ——
  // 此刻可能真有别的客服在线（2026-10-08 晚实测：并发跑时它是 1，旧断言"此刻未连 WS → 0"就是假红）
  const csWorkerTotal = Number((await q('SELECT COUNT(*) AS n FROM worker WHERE status = 1 AND can_serve_customer = 1'))[0]?.n ?? -1);
  ok('②-i 统计：onlineCsCount 为数字且落在 [0, 有客服权限的在职打手数]（与权威表推导的上下界一致）',
    typeof hall2.data?.onlineCsCount === 'number' && hall2.data.onlineCsCount >= 0 && hall2.data.onlineCsCount <= csWorkerTotal,
    `onlineCsCount=${hall2.data?.onlineCsCount} csWorkerTotal=${csWorkerTotal}`);

  const assignA = await req('POST', `/admin/chat/conversations/${convA.id}/assign`, adminToken, { workerUserId: workerAUserId });
  ok('②-夹具：管理端把 convA 指派给 worker01（201）', assignA.status === 201, `status=${assignA.status} ${assignA.message ?? ''}`);
  const hall3 = await req('GET', '/worker/cs/hall', workerAToken);
  ok('②-j 已指派的会话从大厅消失（另一条待接入仍在）',
    !(hall3.data?.list ?? []).some((x) => x.conversationId === String(convA.id)) &&
      (hall3.data?.list ?? []).some((x) => x.conversationId === String(convB.id)),
    j({ list: (hall3.data?.list ?? []).map((x) => x.conversationId), total: hall3.data?.total }));
  const myConvs = await req('GET', '/worker/cs/conversations', workerAToken);
  ok('②-k 既有接口语义未变：GET /worker/cs/conversations 仍只返回已指派给自己的',
    (myConvs.data?.list ?? []).some((c) => String(c.id) === String(convA.id)) &&
      !(myConvs.data?.list ?? []).some((c) => String(c.id) === String(convB.id)),
    j((myConvs.data?.list ?? []).map((c) => c.id)));

  // =========================================================================
  // ③④⑤⑥⑦ 需要 WS：先连上（同时验证"无客服权限的在线打手收不到 cs:new"这一受众过滤）
  // =========================================================================
  console.log('\n--- ⑦ WS 实时事件（含受众过滤）---');
  const events = { bossA: [], bossB: [], workerA: [], workerB: [] };
  const socks = {
    bossA: wsConnect(bossAToken),
    bossB: wsConnect(bossBToken),
    workerA: wsConnect(workerAToken),
    workerB: wsConnect(workerBToken),
  };
  for (const [who, s] of Object.entries(socks)) {
    for (const ev of ['cs:new', 'cs:claimed', 'chat:assigned', 'chat:unassigned', 'chat:closed']) {
      s.on(ev, (d) => events[who].push({ ev, ...(d ?? {}) }));
    }
  }
  await sleep(1600);
  ok('⑦-夹具：四个 WS 连接建立（老板 A/B + 客服 A/B）',
    Object.values(socks).every((s) => s.connected), j(Object.fromEntries(Object.entries(socks).map(([k, s]) => [k, s.connected]))));
  // onlineCsCount 的**正向**同源断言：worker01 此刻确实连着 WS 且有客服权限 → 在线客服数 ≥1（而不是写死 0）
  await sleep(300);
  const hallOnline = await req('GET', '/worker/cs/hall', workerAToken);
  ok('⑦-0 onlineCsCount 与真实 WS 在线同源（worker01 已连且有客服权限 → ≥1）',
    typeof hallOnline.data?.onlineCsCount === 'number' && hallOnline.data.onlineCsCount >= 1,
    `onlineCsCount=${hallOnline.data?.onlineCsCount}`);

  // ⑦-1 新建会话 → cs:new{created}（⚠️ 新口径：**建会话不进池**，这条只是"有老板打开了客服页"的刷新提示）
  const closedA = await req('POST', '/user/conversation/close', bossAToken, {});
  ok('⑦-夹具：老板结束 convA（需求 #7）', closedA.status === 201 && closedA.data?.ok === true, `status=${closedA.status}`);
  const convA2 = (await req('GET', '/user/conversation', bossAToken)).data;
  ok('⑦-夹具：再咨询自动开新会话（convA2、未指派；此刻**还没进池**）', !!convA2?.id && String(convA2.id) !== String(convA.id) && convA2.assigned === false,
    `convA=${convA?.id} → convA2=${convA2?.id}`);
  await sleep(900);
  ok('⑦-a 新建客服会话 → 在线客服（worker01）收到 cs:new{reason:created}（刷新信号；reason 区分"建会话"与"进池"）',
    events.workerA.some((e) => e.ev === 'cs:new' && e.conversationId === String(convA2.id) && e.reason === 'created'),
    j(events.workerA.filter((e) => e.ev === 'cs:new')));
  ok('⑦-a2 新口径：此刻 convA2 **不在**大厅里（建会话 ≠ 进池）', !(await hallHas(convA2.id)), '空会话不进池（等首条消息）');
  ok('⑦-b 受众过滤：**无客服权限**的在线打手收不到 cs:new',
    !events.workerB.some((e) => e.ev === 'cs:new'), j(events.workerB));
  ok('⑦-c 受众过滤：老板端收不到 cs:new / cs:claimed（不把"有人申请客服"推给全体在线连接）',
    !events.bossA.some((e) => e.ev === 'cs:new') && !events.bossB.some((e) => e.ev === 'cs:new'),
    j({ bossA: events.bossA, bossB: events.bossB }));

  // ⑦-2 授予 worker_test2 客服权限（走管理端接口，实时生效）→ 首条消息 → cs:new{first-message}
  const granted = await setCsPerm(WORKER_B, true);
  ok('⑦-夹具：管理端授予 worker_test2 客服权限（201）', granted.status === 201, `status=${granted.status} ${granted.message ?? ''}`);
  const firstMsg = await req('POST', '/user/conversation/messages', bossAToken, { clientMsgId: 'hall3', content: '客服在吗？我想问一下今晚的单' });
  ok('⑦-夹具：convA2 首条消息已发送（seq ≥ 1）', firstMsg.status === 201 && Number(firstMsg.data?.seq) >= 1, `status=${firstMsg.status} seq=${firstMsg.data?.seq}`);
  await sleep(900);
  ok('⑦-d 首次发消息 → cs:new{reason:first-message}（worker01 与 worker_test2 都收到）',
    events.workerA.some((e) => e.ev === 'cs:new' && e.reason === 'first-message') &&
      events.workerB.some((e) => e.ev === 'cs:new' && e.reason === 'first-message'),
    j({ workerA: events.workerA.filter((e) => e.ev === 'cs:new'), workerB: events.workerB.filter((e) => e.ev === 'cs:new') }));

  // =========================================================================
  // ③ 并发抢占（核心）：两个有客服权限的账号同时 claim 同一会话
  // =========================================================================
  console.log('\n--- ③ 并发抢占（核心）---');
  const raceConv = String(convA2.id);
  const [ra, rb] = await Promise.all([
    req('POST', `/worker/cs/hall/${raceConv}/claim`, workerAToken, {}),
    req('POST', `/worker/cs/hall/${raceConv}/claim`, workerBToken, {}),
  ]);
  const results = [
    { who: `${WORKER_A}#${workerAUserId}`, r: ra },
    { who: `${WORKER_B}#${workerBUserId}`, r: rb },
  ];
  const winners = results.filter((x) => x.r.status >= 200 && x.r.status < 300);
  const losers = results.filter((x) => !(x.r.status >= 200 && x.r.status < 300));
  console.log(`      A=${ra.status} ${ra.message ?? ''} | B=${rb.status} ${rb.message ?? ''}`);
  ok('③-a 恰好一个成功（不是两个都成功）', winners.length === 1, j(results.map((x) => `${x.who}:${x.r.status}`)));
  ok('③-b 另一个是 409 + 中文「该咨询已被其他客服接入」（不静默成功）',
    losers.length === 1 && losers[0].r.status === 409 && losers[0].r.message === '该咨询已被其他客服接入',
    j(losers.map((x) => `${x.who}:${x.r.status}:${x.r.message}`)));
  const activeRows = await q(
    'SELECT id, conversation_id, worker_user_id, status, assigned_by, created_at FROM chat_conversation_assign WHERE conversation_id = ? AND status = ?',
    [raceConv, 'active'],
  );
  const allRows = await q('SELECT id, worker_user_id, status FROM chat_conversation_assign WHERE conversation_id = ? ORDER BY id', [raceConv]);
  console.log(`      [SQL 证据] SELECT ... WHERE conversation_id=${raceConv} AND status='active' → ${j(activeRows)}`);
  console.log(`      [SQL 证据] 该会话全部指派行 → ${j(allRows)}`);
  ok('③-c 库里 active 指派**恰好 1 行**', activeRows.length === 1, `activeRows=${activeRows.length}`);
  ok('③-d 且该行的 worker_user_id == 唯一成功者',
    activeRows.length === 1 && String(activeRows[0].worker_user_id) === String(winners[0]?.who.split('#')[1]),
    `db=${activeRows[0]?.worker_user_id} winner=${winners[0]?.who}`);
  const hallAfterRace = await req('GET', '/worker/cs/hall', workerAToken);
  const hallAfterRaceB = await req('GET', '/worker/cs/hall', workerBToken);
  ok('③-e 被接走后两个客服的大厅里都不再出现该会话',
    !(hallAfterRace.data?.list ?? []).some((x) => x.conversationId === raceConv) &&
      !(hallAfterRaceB.data?.list ?? []).some((x) => x.conversationId === raceConv),
    j({ A: (hallAfterRace.data?.list ?? []).map((x) => x.conversationId), B: (hallAfterRaceB.data?.list ?? []).map((x) => x.conversationId) }));
  await sleep(900);
  const winnerIsA = String(activeRows[0]?.worker_user_id) === workerAUserId;
  ok('⑦-e 抢到的人收到 chat:assigned（既有事件名，打手端已监听）',
    (winnerIsA ? events.workerA : events.workerB).some((e) => e.ev === 'chat:assigned' && e.conversationId === raceConv),
    j({ workerA: events.workerA.filter((e) => e.ev === 'chat:assigned'), workerB: events.workerB.filter((e) => e.ev === 'chat:assigned') }));
  ok('⑦-f 大厅其他人收到 cs:claimed{conversationId, byNickname}',
    (winnerIsA ? events.workerB : events.workerA).some((e) => e.ev === 'cs:claimed' && e.conversationId === raceConv && !!e.byNickname),
    j({ workerA: events.workerA.filter((e) => e.ev === 'cs:claimed'), workerB: events.workerB.filter((e) => e.ev === 'cs:claimed') }));
  ok('⑦-g 老板侧收到 chat:assigned（含客服昵称/工号 → 「客服 X 已接入」）',
    events.bossA.some((e) => e.ev === 'chat:assigned' && e.conversationId === raceConv && !!e.workerNickname && !!e.workerNo),
    j(events.bossA.filter((e) => e.ev === 'chat:assigned')));

  // =========================================================================
  // ④ 幂等：同一个人重复 claim
  // =========================================================================
  console.log('\n--- ④ 幂等（同一人重复点）---');
  const winnerToken = winnerIsA ? workerAToken : workerBToken;
  const winnerId = winnerIsA ? workerAUserId : workerBUserId;
  const again1 = await req('POST', `/worker/cs/hall/${raceConv}/claim`, winnerToken, {});
  const again2 = await req('POST', `/worker/cs/hall/${raceConv}/claim`, winnerToken, {});
  ok('④-a 重复 claim 不报错（200）', again1.status === 200 && again2.status === 200, `s1=${again1.status} s2=${again2.status}`);
  ok('④-b 重复 claim 回 alreadyClaimed=true（客户端不会看到红字）',
    again1.data?.alreadyClaimed === true && again2.data?.alreadyClaimed === true, j([again1.data, again2.data]));
  const activeRows2 = await q(
    "SELECT id FROM chat_conversation_assign WHERE conversation_id = ? AND status = 'active'", [raceConv],
  );
  const rows2 = await q('SELECT id FROM chat_conversation_assign WHERE conversation_id = ?', [raceConv]);
  ok('④-c 不产生第二行（active 仍 1 行、该会话总行数也仍 1 行）',
    activeRows2.length === 1 && rows2.length === 1, `active=${activeRows2.length} all=${rows2.length}`);
  ok('④-d winner 幂等调用后 DB 里仍是我自己',
    String(activeRows2[0]?.id) === String(activeRows[0]?.id) && String(activeRows[0]?.worker_user_id) === winnerId,
    `row=${activeRows2[0]?.id} winner=${winnerId}`);

  // =========================================================================
  // ⑤ release：退回池子（历史保留）+ 重新出现 + 开关 0/1
  // =========================================================================
  console.log('\n--- ⑤ 退回池子（release）---');
  const rel1 = await req('POST', `/worker/cs/hall/${raceConv}/release`, winnerToken, {});
  ok('⑤-a 接入客服退回池子 → 200', rel1.status === 200 && rel1.data?.alreadyReleased === false, `status=${rel1.status} ${j(rel1.data)}`);
  const relRow = await q(
    'SELECT id, worker_user_id, status FROM chat_conversation_assign WHERE conversation_id = ? ORDER BY id', [raceConv],
  );
  console.log(`      [SQL 证据] 退回后该会话指派行 → ${j(relRow)}`);
  ok('⑤-b 历史行保留（status=released，不是删除、不是 inactive）',
    relRow.length === 1 && relRow[0].status === 'released' && String(relRow[0].worker_user_id) === winnerId, j(relRow));
  const hallAfterRel = await req('GET', '/worker/cs/hall', workerAToken);
  const hallAfterRelB = await req('GET', '/worker/cs/hall', workerBToken);
  ok('⑤-c 退回后重新出现在大厅（两个客服都看到）',
    (hallAfterRel.data?.list ?? []).some((x) => x.conversationId === raceConv) &&
      (hallAfterRelB.data?.list ?? []).some((x) => x.conversationId === raceConv),
    j({ A: (hallAfterRel.data?.list ?? []).map((x) => x.conversationId), B: (hallAfterRelB.data?.list ?? []).map((x) => x.conversationId) }));
  await sleep(900);
  ok('⑦-h 退回后大厅其他人收到 cs:new{reason:released}；老板收到 chat:unassigned',
    (winnerIsA ? events.workerB : events.workerA).some((e) => e.ev === 'cs:new' && e.conversationId === raceConv && e.reason === 'released') &&
      events.bossA.some((e) => e.ev === 'chat:unassigned' && e.conversationId === raceConv),
    j({ csNew: (winnerIsA ? events.workerB : events.workerA).filter((e) => e.ev === 'cs:new'), bossUnassigned: events.bossA.filter((e) => e.ev === 'chat:unassigned') }));
  const rel2 = await req('POST', `/worker/cs/hall/${raceConv}/release`, winnerToken, {});
  ok('⑤-d 重复退回幂等（200 + alreadyReleased=true）', rel2.status === 200 && rel2.data?.alreadyReleased === true, `status=${rel2.status} ${j(rel2.data)}`);
  const relByOther = await req('POST', `/worker/cs/hall/${raceConv}/release`, winnerIsA ? workerBToken : workerAToken, {});
  ok('⑤-e 非接入客服退回 → 中文 400（不是静默成功）',
    relByOther.status === 400 && isChinese(relByOther.message), `status=${relByOther.status} message=${relByOther.message}`);

  // 开关：管理端置 0 → 立刻 403 中文；置回 1 → 恢复
  const claimAgain = await req('POST', `/worker/cs/hall/${raceConv}/claim`, winnerToken, {});
  ok('⑤-夹具：重新接入（供开关验证）', claimAgain.status === 200, `status=${claimAgain.status}`);
  const offSwitch = await req('PUT', `/admin/settings/${RELEASE_KEY}`, adminToken, { cfgValue: { value: 0 } });
  ok('⑤-f 管理端把退回开关置 0（200）', offSwitch.status === 200, `status=${offSwitch.status} ${offSwitch.message ?? ''}`);
  const relOff = await req('POST', `/worker/cs/hall/${raceConv}/release`, winnerToken, {});
  ok('⑤-g 开关=0 → 退回接口 403 中文「客服退回功能未开放」（读侧实时读库无缓存）',
    relOff.status === 403 && relOff.message === '客服退回功能未开放', `status=${relOff.status} message=${relOff.message}`);
  const onSwitch = await req('PUT', `/admin/settings/${RELEASE_KEY}`, adminToken, { cfgValue: { value: 1 } });
  const relOn = await req('POST', `/worker/cs/hall/${raceConv}/release`, winnerToken, {});
  ok('⑤-h 开关置回 1 → 退回立刻恢复可用（200）', onSwitch.status === 200 && relOn.status === 200 && relOn.data?.alreadyReleased === false,
    `switch=${onSwitch.status} release=${relOn.status} ${j(relOn.data)}`);
  const cfgBack = await q('SELECT cfg_value FROM system_setting WHERE setting_key = ?', [RELEASE_KEY]);
  ok('⑤-i 开关已还原为 1（不留测试残留）', Number(cfgBack[0]?.cfg_value?.value) === 1, j(cfgBack[0]?.cfg_value));

  // =========================================================================
  // ⑥ 管理端改派仍可用（回归；admin/chat 一行未改）
  // =========================================================================
  console.log('\n--- ⑥ 管理端改派兜底（回归）---');
  const reAssign = await req('POST', `/admin/chat/conversations/${raceConv}/assign`, adminToken, { workerUserId: workerBUserId });
  ok('⑥-a 管理端改派仍可用（201）', reAssign.status === 201, `status=${reAssign.status} ${reAssign.message ?? ''}`);
  const convsA2 = await req('GET', '/worker/cs/conversations', workerAToken);
  const convsB2 = await req('GET', '/worker/cs/conversations', workerBToken);
  ok('⑥-b 改派后：新客服（worker_test2）列表里有它，原客服列表里没有',
    (convsB2.data?.list ?? []).some((c) => String(c.id) === raceConv) && !(convsA2.data?.list ?? []).some((c) => String(c.id) === raceConv),
    j({ workerA: (convsA2.data?.list ?? []).map((c) => c.id), workerB: (convsB2.data?.list ?? []).map((c) => c.id) }));
  const sendByOld = await req('POST', `/worker/cs/conversations/${raceConv}/messages`, workerAToken, { content: '改派后原客服应失败' });
  ok('⑥-c 改派后原客服发送被拒（403/404）', sendByOld.status === 403 || sendByOld.status === 404, `status=${sendByOld.status} ${sendByOld.message ?? ''}`);
  const sendByNew = await req('POST', `/worker/cs/conversations/${raceConv}/messages`, workerBToken, { content: '新客服可以回复' });
  ok('⑥-d 新客服可正常回复（201）', sendByNew.status === 201, `status=${sendByNew.status} ${sendByNew.message ?? ''}`);
  const adminList = await req('GET', '/admin/chat/conversations?page=1&pageSize=20', adminToken);
  const adminRow = (adminList.data?.list ?? []).find((c) => String(c.id) === raceConv);
  ok('⑥-e 管理端会话列表仍在（csWorkerUserId = 新客服）',
    !!adminRow && String(adminRow.csWorkerUserId) === workerBUserId, j(adminRow));
  const hallAssigned = await req('GET', '/worker/cs/hall', workerAToken);
  ok('⑥-f 改派后该会话不在大厅（池子口径 = 无 active 指派）',
    !(hallAssigned.data?.list ?? []).some((x) => x.conversationId === raceConv),
    j((hallAssigned.data?.list ?? []).map((x) => x.conversationId)));
  await sleep(900);
  ok('⑦-i 原客服收到 chat:unassigned（管理端改派的既有行为未变）',
    (winnerIsA ? events.workerA : events.workerB).some((e) => e.ev === 'chat:unassigned' && e.conversationId === raceConv),
    j({ workerA: events.workerA.filter((e) => e.ev === 'chat:unassigned'), workerB: events.workerB.filter((e) => e.ev === 'chat:unassigned') }));

  // =========================================================================
  // ⑧ 打手态（companion）：负责人要的就是"打手端主动接" —— 白名单天然放行 /worker/*
  // =========================================================================
  console.log('\n--- ⑧ 打手态（companion）真机路径 ---');
  const st0 = await req('GET', '/user/identity', bossAToken);
  if (st0.data?.bound) {
    const pre = await req('POST', '/user/identity/unbind', bossAToken, {});
    console.log(`      （前置：boss_demo 原有一条 active 绑定，已先解绑 status=${pre.status}）`);
  }
  const bind = await req('POST', '/user/identity/bind', bossAToken, { username: WORKER_A, password: 'password123' });
  const companionToken = bind.data?.companionToken;
  ok('⑧-a 老板绑定打手账号 → companion 令牌（HTTP 200）', bind.status === 200 && !!companionToken,
    `status=${bind.status} ${bind.message ?? ''}`);
  const cHall = await req('GET', '/worker/cs/hall', companionToken);
  ok('⑧-b companion（打手态）→ GET /worker/cs/hall 200（白名单 /worker/* 零改动即放行）',
    cHall.status === 200 && Array.isArray(cHall.data?.list), `status=${cHall.status} ${cHall.message ?? ''} n=${cHall.data?.list?.length}`);
  const cClaim = await req('POST', `/worker/cs/hall/${convB.id}/claim`, companionToken, {});
  ok('⑧-c companion → claim 200（打手态确实能**主动接**，不只是能看列表）',
    cClaim.status === 200 && cClaim.data?.alreadyClaimed === false, `status=${cClaim.status} ${j(cClaim.data ?? cClaim.message)}`);
  const cBossSide = await req('GET', '/user/orders', companionToken);
  ok('⑧-d companion 打老板侧接口仍 403（受限会话边界没被新接口带松）',
    cBossSide.status === 403 && isChinese(cBossSide.message), `status=${cBossSide.status} ${cBossSide.message ?? ''}`);
  const cUnbind = await req('POST', '/user/identity/unbind', bossAToken, {});
  const cAfterUnbind = await req('GET', '/worker/cs/hall', companionToken);
  ok('⑧-e 解绑 → companion 立即失效（hall 401 中文；绑定历史行保留不删）',
    cUnbind.status === 200 && cAfterUnbind.status === 401 && isChinese(cAfterUnbind.message),
    `unbind=${cUnbind.status} after=${cAfterUnbind.status} ${cAfterUnbind.message ?? ''}`);

  /**
   * ⑧ 段**故意把绑定解掉了**（⑧-e 验的就是"解绑即刻失效"），所以打手 token 到这里必然失效：
   * `workerAToken`（夹具发的 companion）已被按 binding 吊销 → 下面第 ⑨ 段若继续用它，
   * claim 会 401「伴随身份已失效」而不是走进并发锁（实测：3 条红）。
   * 这里**走夹具同一条真实路径重新绑定**（重登老板 primary → `POST /user/identity/bind` → companion），
   * 让 ⑨ 段拿到的是一枚**有效**的 companion —— 断言一个字没放宽，只是把前置恢复干净。
   * 用夹具入口（而不是本文件自己再写一遍）的原因：它自带**绑定限流退避**（5 次/分/IP+账号）。
   */
  const reWa = await fixtures.ensureWorker(adminToken, {
    username: WORKER_A, workerNo: 'W001', nickname: '演示工作端', takeOrder: true, serveCustomer: true,
    bossUsername: BOSS_A,
  });
  if (!reWa.token) throw new Error(`⑧ 段后重新绑定 ${WORKER_A} 失败`);
  // ⚠️ **覆盖** 这两个变量（而不是另起新变量）：第 ⑨ 段有 4 处调用点、hallHas() 也闭包引用了
  // `workerAToken`，覆盖才能保证它们全部用上**当前有效**的令牌 —— 实测漏掉一处就会得到
  // 空大厅（hall@old=[]），于是夹具判定"新会话没进池"而假红。
  // 覆盖 bossAToken 同理：夹具为拿"当前有效 primary"重新登录过，旧 primary 已被顶掉（单设备铁律）。
  workerAToken = reWa.token;
  bossAToken = reWa.bossToken;
  console.log(`      （⑧ 段解绑收尾 → 已按真实路径重新绑定 ${WORKER_A}，第 ⑨ 段用新 companion）`);

  // =========================================================================
  // ⑨ 并发：大厅 claim ↔ 管理端 assign（同一把会话行锁；2026-10-08 晚补）
  // =========================================================================
  console.log('\n--- ⑨ 并发：大厅 claim ↔ 管理端改派（同一把会话行锁）---');

  /** 起一个"已进池、无 active 指派"的新会话：老板结束当前会话 → 自动重开 → 发首条消息（= 进池） */
  const freshPoolConv = async (token, label) => {
    await req('POST', '/user/conversation/close', token, {});
    const conv = (await req('GET', '/user/conversation', token)).data;
    const sent = await req('POST', '/user/conversation/messages', token, { content: `${label}：这条用来抢` });
    return { conv, sent };
  };

  /**
   * ⑨-1 **确定性并发窗口**（不依赖调度运气，也是"管理端行锁被去掉 → 本用例必红"的关键）：
   *
   * 用 e2e 自己那条 MySQL 连接开一个**独立事务**，在该会话的指派行区间上加锁：
   *   `SELECT * FROM chat_conversation_assign WHERE conversation_id = ? FOR UPDATE`
   * 命中**空范围** → InnoDB 在 `IDX_assign_conv` 上留下 gap lock。于是：
   *   ① claim 请求进来：先拿住**会话行锁**，走到 `INSERT ... assign` 时**卡在我的 gap lock 上**
   *      （事务开着、会话行锁还握着、active 行还没落库）；
   *   ② 管理端 assign 随后进来：它的"请求开始观测"读到的是**没有 active 行**（claim 未提交），
   *      接着在 `SELECT ... FOR UPDATE` 上**排队等 claim 的会话行锁**（有行锁时必然排队）；
   *   ③ 我 COMMIT 放行 → claim 的 INSERT 先拿到插入意向锁 → 提交；管理端这才读到 active 行，
   *      锁内复核发现"我以为没人接、其实刚被接走" → **中文 409**。
   *
   * 把管理端的**会话行锁**去掉（变异验证 ②）：第 ② 步它**不会排队**，会拿着过期状态（"无 active 行"）
   * 抢在 claim 前面落库 → 结果是**管理端 201、claim 409**（顺序被抢）→ ⑨-a 立刻变红。
   * 若把 assign 整个退回旧实现（无事务、复核也用普通读，即修复前那份代码）：管理端的 INSERT 没有
   * 自己的 gap lock 保护，就会撞唯一键 `UK_cca_active` → **500** → ⑨-b 也变红（这正是本次要修的 bug）。
   */
  const fA = await freshPoolConv(bossAToken, '并发A');
  const raceConv2 = String(fA.conv.id);
  const beforeRace2 = await activeAssignRows(raceConv2);
  const hallHasRace2 = await hallHas(raceConv2);
  const hallList2 = (await req('GET', '/worker/cs/hall', workerAToken)).data?.list ?? [];
  if (!(Number(fA.sent.data?.seq) >= 1 && fA.conv.assigned === false && beforeRace2.length === 0 && hallHasRace2)) {
    console.log(
      `      [诊断] ⑨-夹具 条件拆解：seq=${fA.sent.data?.seq} assigned=${fA.conv.assigned} active=${beforeRace2.length} ` +
        `hallHas=${hallHasRace2}（hall=${j(hallList2.map((x) => `${x.conversationId}/${x.msgCount}`))}，` +
        `sent=${fA.sent.status} ${fA.sent.message ?? ''}）`,
    );
  }
  ok('⑨-夹具：新会话已进池且无 active 指派（claim 的起跑条件）',
    Number(fA.sent.data?.seq) >= 1 && fA.conv.assigned === false && beforeRace2.length === 0 && hallHasRace2,
    `conv=${raceConv2} seq=${fA.sent.data?.seq} active=${beforeRace2.length}`);

  await q('START TRANSACTION');
  await q('SELECT * FROM chat_conversation_assign WHERE conversation_id = ? FOR UPDATE', [raceConv2]);
  const raceT0 = Date.now();
  const pClaim = req('POST', `/worker/cs/hall/${raceConv2}/claim`, workerAToken, {});
  await sleep(300);
  const pAdmin = req('POST', `/admin/chat/conversations/${raceConv2}/assign`, adminToken, { workerUserId: workerBUserId });
  await sleep(300); // 两个请求此刻都停在事务里（claim 卡在 INSERT、管理端卡在会话行锁）
  await q('COMMIT');
  const [rClaim, rAdmin] = await Promise.all([pClaim, pAdmin]);
  const raceWindowMs = Date.now() - raceT0;
  console.log(`      人工窗口 ${raceWindowMs}ms ｜ claim=${rClaim.status} ${rClaim.message ?? ''} ｜ adminAssign=${rAdmin.status} ${rAdmin.message ?? ''}`);
  const claimWon = rClaim.status === 200 || rClaim.status === 201;
  const adminWon = rAdmin.status === 200 || rAdmin.status === 201;
  // 窗口成立性（不是空跑）：claim 先发 300ms、管理端后发，两个请求都被卡在同一事务窗口里 → 总耗时必然 > 500ms
  ok('⑨-0 并发窗口确实成立（两个请求都被卡在同一窗口内，而不是各跑各的）',
    raceWindowMs >= 500,
    `window=${raceWindowMs}ms claim=${rClaim.status} admin=${rAdmin.status}`);
  // 这个窗口里 **claim 先到且已握住会话行锁**（它比管理端早 300ms 发起、且锁一直握到自己提交），
  // 所以管理端**必然排在它后面**：等锁 → 读到 active 行 → 中文 409。
  // 断言"谁赢"而不是"两者之一"是刻意的：**把管理端的会话行锁去掉，管理端就不再排队**，
  // 会用过期状态抢在 claim 前面落库（201）→ 本条立刻变红（变异验证 ②）。
  ok('⑨-a claim 先到先得（200）；管理端排在后面 → 中文 409「该咨询已被其他客服接入」（**不是 500**）',
    claimWon && !adminWon && rAdmin.status === 409 && rAdmin.message === '该咨询已被其他客服接入',
    j({ claim: { s: rClaim.status, m: rClaim.message }, admin: { s: rAdmin.status, m: rAdmin.message } }));
  ok('⑨-b 没有任何一方是 5xx（唯一键冲突不该冒成"服务器内部错误"）',
    rClaim.status < 500 && rAdmin.status < 500, `claim=${rClaim.status} admin=${rAdmin.status}`);
  const raceActive = await activeAssignRows(raceConv2);
  const raceAll = await q('SELECT id, worker_user_id, status, assigned_by FROM chat_conversation_assign WHERE conversation_id = ? ORDER BY id', [raceConv2]);
  console.log(`      [SQL 证据] SELECT ... WHERE conversation_id=${raceConv2} AND status='active' → ${j(raceActive)}`);
  console.log(`      [SQL 证据] 该会话全部指派行 → ${j(raceAll)}`);
  ok('⑨-c 库里 active 指派**恰好 1 行**（不会出现两行 active）', raceActive.length === 1, `activeRows=${raceActive.length}`);
  ok('⑨-d 且那行 active 的接单人 == 成功的一方（本窗口 = 先到的 claim 者 worker01）',
    raceActive.length === 1 && String(raceActive[0].worker_user_id) === workerAUserId,
    `db=${raceActive[0]?.worker_user_id} claimWon=${claimWon} adminWon=${adminWon}`);

  // ⑨-2 裸并发（**不做任何人工窗口**）：两边同时发出 —— 断言"不崩、不脏"这条底线
  const fB = await freshPoolConv(bossAToken, '并发B');
  const raceConv3 = String(fB.conv.id);
  const [cB, aB] = await Promise.all([
    req('POST', `/worker/cs/hall/${raceConv3}/claim`, workerBToken, {}),
    req('POST', `/admin/chat/conversations/${raceConv3}/assign`, adminToken, { workerUserId: workerAUserId }),
  ]);
  console.log(`      裸并发 ｜ claim=${cB.status} ${cB.message ?? ''} ｜ adminAssign=${aB.status} ${aB.message ?? ''}`);
  const activeB = await activeAssignRows(raceConv3);
  console.log(`      [SQL 证据] SELECT ... WHERE conversation_id=${raceConv3} AND status='active' → ${j(activeB)}`);
  const bareFails = [cB, aB].filter((x) => !(x.status >= 200 && x.status < 300));
  ok('⑨-e 裸并发：无 5xx、至少一方成功、active 恰好 1 行、落败方是中文 409（同一把锁下不脏、不崩）',
    cB.status < 500 && aB.status < 500 &&
      [cB, aB].some((x) => x.status >= 200 && x.status < 300) &&
      activeB.length === 1 &&
      bareFails.every((x) => x.status === 409 && x.message === '该咨询已被其他客服接入'),
    j({ claim: { s: cB.status, m: cB.message }, admin: { s: aB.status, m: aB.message }, activeRows: activeB.length }));

  // =========================================================================
  // 收尾：自清（会话 + 权限 + 开关），并打印残留计数
  // =========================================================================
  console.log('\n--- 收尾（自建自清）---');
  for (const s of Object.values(socks)) s.close();
  const revoked = await setCsPerm(WORKER_B, false);
  ok('清理-a worker_test2 客服权限已撤销（回到夹具基线 0）', revoked.status === 201,
    `status=${revoked.status}`);
  const wiped = await wipeCs();
  await restoreBaseline();
  const left = await csLeft();
  console.log(`      清理 ${wiped} 条客服会话；残留 → ${j(left)}`);
  ok('清理-b 测试会话/指派/消息全部清零、客服权限已还原',
    left.cs_convs === 0 && left.assigns === 0 && left.msgs === 0 && Number(left.cs_perm) === 0,
    j(left));

  await db.end();
  console.log(`\nRESULT: ${pass} pass / ${fail} fail`);
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('脚本异常:', e);
  process.exit(2);
});
