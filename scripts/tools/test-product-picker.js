/**
 * 测试商品挑选工装（回归套件共用）—— **按「剩余配额」挑商品，不写死 id**
 *
 * ────────────────────────────────────────────────────────────────────────────
 * 为什么需要它（不是"测试写起来方便"，而是**测试可信度**问题）
 *
 * 2026-10-05 起 `product.weekly_limit`（迁移 `1796000000000`）由负责人在管理端设定，
 * 例如商品 137「9.9新人体验单」= **每位用户每周限购 2 单**（口径：`status <> 'canceled'`
 * 且最近 7 天，见 `server/src/modules/order/order.service.ts` 的限购段）。
 *
 * 于是"需要连下 N 单"的套件一旦**写死商品/取列表第一个**，就会在第 N+1 单被服务端中文拒绝：
 *   400 该商品每位用户每周限购 2 单，你本周已下单 2 单，请下周再来
 * —— 那是**环境约束**，不是被测行为，却让套件变红（stage14 / leaderboard / commission-rate
 * 三套件 2026-10-08 就是这么红的）。
 *
 * 三种错误做法（本工装刻意都不做）：
 *   ① 改 `weekly_limit` 配置 / 改商品数据 → **改业务数据**，禁止；
 *   ② 把限购商品换成一个写死的新 id → 下次那个商品也被限购，同样的红再来一遍；
 *   ③ 放宽断言 / 少跑用例 → 假绿，docs/12 铁律禁止。
 *
 * 本工装的做法（照 `scripts/tmp/dispatch-test.js` 2026-10-06 已验证的范式抽出来共用）：
 *   - 公开列表 `GET /public/products` 是**唯一**候选来源（它本身就是"当前可下"的商品集，
 *     且不带鉴权、人人可复现）；
 *   - 限购商品**不自己算窗口**，一律问服务端 `GET /user/orders/weekly-quota?productId=`
 *     （限购规则只有服务端一份实现，脚本自己算必然漂移）；
 *   - 还要满足「本次所需单数 × 单价 ≤ 钱包余额」（测试充值是有限的，别让下单卡在余额上）；
 *   - 候选按**单价升序**排（先试最便宜的，反复跑也不会把测试账号跑穷），逐个真下单探测
 *     （探测失败的单子服务端整单回滚，不留脏数据）。
 *
 * 确实一个都挑不出来时：
 *   - `pickProductForOrders()` **抛错**（中文 + 候选与跳过原因清单）→ 套件必须**明确报错并终止**，
 *     不许抛 `TypeError`、不许当"没事"继续跑（docs/12）；
 *   - 只有在"少跑一个子用例不影响整套结论"的场合（如 app-update 的下载断言），
 *     调用方才用 `noThrow: true` 拿到 `{ ok:false, reason }`，并在终结行写 `SKIP 原因=…`。
 *
 * 用法（三套件的接入点见文件末注释）：
 *   const picker = require('../tools/test-product-picker');
 *   const picked = await picker.pickProductForOrders({ token: bossToken, needed: 4 });
 *   // picked.id / picked.price / picked.limit / picked.remaining / picked.skipped
 *
 * 只读接口、不下单、不改任何业务数据 —— 唯一的写操作由**调用方**用它选出的商品去做。
 */

const BASE = 'http://127.0.0.1:3100/api/v1';

async function req(method, path, body, token) {
  const r = await fetch(BASE + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await r.json(); } catch { /* 非 JSON 响应 */ }
  return { status: r.status, json };
}

/** 读钱包余额（数值）；读不到按 0 处理并由调用方在错误信息里体现 */
async function balanceOf(token) {
  const w = await req('GET', '/user/wallet', null, token);
  const v = Number(w.json?.data?.balance ?? NaN);
  return Number.isFinite(v) ? v : 0;
}

/**
 * 内部：算出**全部**可用候选（按单价升序）与跳过原因清单。
 * 挑一个与"逐个探测"共用它，避免两份会漂移的筛选逻辑。
 */
async function collectCandidates(opts) {
  const { token, needed, minPrice = 0, maxPrice = Infinity, requireFree = false, preferFree = true } = opts ?? {};
  if (!token) throw new Error('[商品挑选] 缺少老板侧 token（工装无法读余额与每周配额）');
  const n = Number(needed);
  if (!Number.isInteger(n) || n < 1) throw new Error(`[商品挑选] needed 必须是 ≥1 的整数，收到 ${needed}`);

  const balance = await balanceOf(token);
  const pr = await req('GET', '/public/products?page=1&pageSize=50');
  const list = pr.json?.data?.list ?? [];
  if (pr.status !== 200 || !list.length) {
    return { balance, candidates: [], skipped: [], error: `公开商品列表不可用（HTTP ${pr.status}，条数 ${list.length}）` };
  }

  const candidates = [];
  const skipped = [];
  for (const p of list) {
    const id = String(p.id);
    const name = String(p.name ?? '');
    const price = Number(p.price ?? 0);
    if (!(price > minPrice)) { skipped.push(`${id}:价格不合法(price=${p.price})`); continue; }
    if (price > maxPrice) { skipped.push(`${id}:单价${price}>上限${maxPrice}`); continue; }
    if (price * n > balance) { skipped.push(`${id}:${price}×${n}>余额${balance}`); continue; }
    const limit = Number(p.weeklyLimit ?? 0);
    let remaining = null;
    if (limit > 0) {
      if (requireFree) { skipped.push(`${id}:配了限购${limit}（本次要求不限购商品）`); continue; }
      // 限购口径只有服务端一份实现 → 必须问它，脚本不自己算窗口
      const q = await req('GET', `/user/orders/weekly-quota?productId=${id}`, null, token);
      const d = q.json?.data;
      if (q.status !== 200 || !d) { skipped.push(`${id}:配额接口 HTTP ${q.status}`); continue; }
      remaining = d.remaining === null || d.remaining === undefined ? null : Number(d.remaining);
      if (remaining === null || remaining < n) {
        // 这就是商品 137 会落到的地方（限购 2、本周已下单 2 → 剩余 0）
        skipped.push(`${id}:限购${limit}剩余${d.remaining}`);
        continue;
      }
    }
    candidates.push({ id, name, price, limit, remaining, salesCount: Number(p.salesCount ?? 0) });
  }

  /**
   * 排序：**先"不限购"再看单价**，理由不是好看而是稳定 ——
   * 限购商品的名额是**滚动 7 天、只数非 canceled** 的有限资源，套件每跑一次就消耗一点，
   * 一旦某商品的额度被历史运行吃掉，本轮就得换商品（商品单价一变，按单价推导的断言值也变）。
   * 不限购商品则是**无限名额**，反复跑都稳定命中同一个。
   * 单价升序是第二关键字（先试最便宜的，跑多少次都不会把测试账号跑穷）。
   */
  candidates.sort((a, b) => (preferFree ? (a.limit > 0 ? 1 : 0) - (b.limit > 0 ? 1 : 0) : 0) || a.price - b.price || Number(a.id) - Number(b.id));
  return { balance, candidates, skipped };
}

/**
 * 挑选一个能承载 [needed] 单的商品（取单价最低的候选）。
 *
 * @param {object} opts
 * @param {string} opts.token            老板侧 accessToken（读余额与配额都要它）
 * @param {number} opts.needed           本次需要连下的单数（≥1）
 * @param {number} [opts.minPrice=0]     单价下限（严格大于；0 元/异常价商品被排除）
 * @param {number} [opts.maxPrice]       单价上限（可选）
 * @param {boolean} [opts.requireFree]   true = 只接受**未配限购**的商品（默认 false：
 *                                       配了限购但服务端说剩余额度够 also 可用 —— 那是权威判定）
 * @param {boolean} [opts.preferFree=true] true = 排序时**优先不限购商品**（名额无限、跨运行稳定），
 *                                       同为不限购时按单价升序
 * @param {boolean} [opts.noThrow]       true = 挑不出时不抛错，返回 { ok:false, reason, ... }
 * @returns {Promise<{ok:true,id:string,price:number,limit:number,remaining:number|null,
 *                    name:string,salesCount:number,balance:number,skipped:string[]}>}
 */
async function pickProductForOrders(opts) {
  const { needed, noThrow = false } = opts ?? {};
  const { balance, candidates, skipped, error } = await collectCandidates(opts);
  if (error || !candidates.length) {
    const reason = error
      ? `${error}：无法挑选承载 ${needed} 单的商品`
      : `没有任何商品能承载本次 ${needed} 单（余额=${balance}）：${skipped.join(' / ') || '公开列表为空'}`;
    if (noThrow) return { ok: false, reason, skipped, balance };
    throw new Error(`[商品挑选] ${reason}`);
  }
  return { ok: true, ...candidates[0], balance, candidateCount: candidates.length, skipped };
}

/**
 * 连下 N 单的套件专用：把**全部**候选逐个真下单探测，返回第一个下单成功的商品与首单响应。
 *
 * 为什么要探测：工装只能按服务端下发的配额筛选，"这个商品此刻能不能真的下单"仍可能
 * 被别的约束拒绝（限流、并发套件刚好吃掉最后一个名额…）。探测失败的单子服务端整单回滚，
 * 不留脏数据（`createOrder` 由调用方提供，幂等键也由调用方生成）。
 *
 * @param {object} opts 同 [pickProductForOrders]，外加：
 * @param {(productId:string)=>Promise<{status:number,json:any}>} opts.createOrder 调用方的下单函数
 * @returns {Promise<{ok:true,id,price,limit,remaining,first:{status,json},
 *                    tried:string[],skipped:string[],balance:number}>}
 */
async function pickProductAndProbe(opts) {
  const { createOrder, noThrow = false, ...rest } = opts ?? {};
  if (typeof createOrder !== 'function') throw new Error('[商品挑选] pickProductAndProbe 需要 createOrder 回调');
  const { balance, candidates, skipped, error } = await collectCandidates(rest);
  if (error || !candidates.length) {
    const reason = error
      ? `${error}：无法挑选承载 ${rest?.needed} 单的商品`
      : `没有任何商品能承载本次 ${rest?.needed} 单（余额=${balance}）：${skipped.join(' / ') || '公开列表为空'}`;
    if (noThrow) return { ok: false, reason, skipped, balance };
    throw new Error(`[商品挑选] ${reason}`);
  }
  const tried = [];
  for (const c of candidates) {
    const rr = await createOrder(c.id);
    if (rr.status === 201) {
      return { ok: true, id: c.id, price: c.price, limit: c.limit, remaining: c.remaining, first: rr, tried, skipped, balance, candidateCount: candidates.length };
    }
    tried.push(`${c.id}(${c.price})→${rr.status} ${rr.json?.message ?? ''}`);
  }
  const reason = `候选商品全部无法下单（余额=${balance}）：${tried.join(' / ')}`;
  if (noThrow) return { ok: false, reason, tried, skipped, balance };
  throw new Error(`[商品挑选] ${reason}`);
}

module.exports = { pickProductForOrders, pickProductAndProbe, collectCandidates, balanceOf, req, BASE };

/**
 * ────────────────────────────────────────────────────────────────────────────
 * 三套件的接入点（2026-10-08 收口）
 *
 * · `stage14-settlement-test.js` —— 一次运行最多占用 **4 个**名额（订单1 主链路 + 订单2 并发抢单
 *   + 订单3 并发确认 + 订单4 取消退款），故 `needed = 4`；
 * · `leaderboard-test.js` —— worker01 完成 3 单 + worker_test2 完成 1 单 = **4 单**同商品；
 * · `commission-rate-test.js` —— A/B/C 各结算 1 单 = **3 单**同商品（单价还要 ×4 预充值）。
 *
 * 三套件都**不再**写死 `137`、也不再用「公告/商品列表第一个」当商品。
 * ────────────────────────────────────────────────────────────────────────────
 */
