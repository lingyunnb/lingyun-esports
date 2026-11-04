'use strict';
/**
 * 服务端地址解析（薄壳方案的"寻址"唯一实现）
 * ============================================================================
 * 顺序（**前一档全灭才走下一档**，每一档都必须 `/api/v1/health` 真返回 200 且业务码 code=0 才算可用）：
 *   ① 本机      http://127.0.0.1:3100/                     —— 壳与服务端同一台电脑时最快
 *   ② Gitee 引导 https://gitee.com/lingyunnb666/fish-endpoint/raw/main/client-config.json
 *                 → 取 `api` 去掉 `/api/v1` 得到域名（`preferred` / `candidates` 依次兜底）
 *   ③ 内置候选    ngrok 固定域名 + 上次隧道域名（本文件写死）
 * 全部失败 → 调用方（main.js）显示自家风格错误页（**绝不白屏**）。
 *
 * 为什么"必须先探活再加载"：隧道域名换掉后 DNS 仍可能解析、TCP 仍可能连上（返回 404/502 页面），
 * 直接 loadURL 会得到一个"像是页面但什么都不能用"的壳 —— 只有 health 200 才算真可用。
 */
const HEALTH_PATH = '/api/v1/health';

/** ① 本机（管理端由后端直接托管在 3100） */
const LOCAL_BASE = 'http://127.0.0.1:3100';

/** ② Gitee raw 引导（单一地址真相源；后端隧道换域名后会更新它） */
const GITEE_BOOTSTRAP = 'https://gitee.com/lingyunnb666/fish-endpoint/raw/main/client-config.json';

/** ③ 内置候选（写死的兜底，公网全挂时至少还能试这两个） */
const BUILTIN_CANDIDATES = [
  'https://<your-tunnel-domain>', // ngrok 固定域名
  'https://immediate-assign-nor-bike.trycloudflare.com', // 上次隧道域名（config/client-config.json 归档值）
];

const HEALTH_TIMEOUT_MS = 3500;
const BOOTSTRAP_TIMEOUT_MS = 6000;

/**
 * 测试缝（唯一用途：验收"三档全灭时显示自家错误页、不白屏"这条）。
 * `QLS_SHELL_FORCE_OFFLINE=1` → 所有探活与引导读取强制失败。
 * 为什么需要它：真验这条只能把服务停掉，而服务上还跑着管理端/回归套件 ——
 * 为验一个错误页去停服务，风险远大于收益。
 */
const FORCE_OFFLINE = process.env.QLS_SHELL_FORCE_OFFLINE === '1';
const OFFLINE_DETAIL = '模拟离线（QLS_SHELL_FORCE_OFFLINE=1）';

/**
 * 测试缝之二：`QLS_SHELL_SKIP_LOCAL=1` → 跳过 ① 本机，**逼真地走一遍 ②→③ 公网回退链**。
 * 为什么需要它：本机开发时 ① 永远命中，②/③ 这两档永远不会被真跑到 ——
 * 而 "换一台电脑/公网访问" 恰好只走 ②/③。没有这条缝，回退链就只是"看着像能工作"。
 */
const SKIP_LOCAL = process.env.QLS_SHELL_SKIP_LOCAL === '1';

/**
 * 把各种写法归一成"域名根"（不带尾斜杠、不带 /api/v1）。
 * 能吃：`https://host/api/v1`、`https://host/api/v1/`、`https://host`、`host:3100`、`http://127.0.0.1:3100/`
 * @returns {string|null}
 */
function normalizeBase(input) {
  let s = String(input ?? '').trim();
  if (!s) return null;
  if (!/^https?:\/\//i.test(s)) s = `http://${s}`;
  s = s.replace(/\/+$/, '');
  s = s.replace(/\/api\/v1$/i, ''); // Gitee 引导给的是 api base，要去掉这一段
  s = s.replace(/\/+$/, '');
  try {
    const u = new URL(s);
    if (!u.host) return null;
    return `${u.protocol}//${u.host}`;
  } catch {
    return null;
  }
}

/**
 * 探活一处地址。
 * @param {string} base 域名根
 * @returns {Promise<{base:string,url:string,ok:boolean,ms:number,detail:string}>}
 */
async function probe(base, timeoutMs = HEALTH_TIMEOUT_MS) {
  const root = normalizeBase(base) || base;
  const url = `${root}${HEALTH_PATH}`;
  if (FORCE_OFFLINE) return { base: root, url, ok: false, ms: 0, detail: OFFLINE_DETAIL };
  const started = Date.now();
  try {
    const res = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      signal: AbortSignal.timeout(timeoutMs),
      headers: { Accept: 'application/json', 'Cache-Control': 'no-cache' },
    });
    const text = await res.text();
    const ms = Date.now() - started;
    if (res.status !== 200) return { base: root, url, ok: false, ms, detail: `HTTP ${res.status}` };
    let json = null;
    try { json = JSON.parse(text); } catch { /* 非 JSON */ }
    if (!json || typeof json !== 'object') return { base: root, url, ok: false, ms, detail: '响应不是 JSON' };
    if (json.code !== 0) {
      return { base: root, url, ok: false, ms, detail: `业务码 code=${json.code}${json.message ? ` ${json.message}` : ''}` };
    }
    const svc = json.data?.services ?? {};
    return {
      base: root, url, ok: true, ms,
      detail: `HTTP 200 · code=0 · database=${svc.database ?? '?'} redis=${svc.redis ?? '?'}`,
    };
  } catch (err) {
    const reason = err?.name === 'TimeoutError'
      ? `超时 ${timeoutMs}ms`
      : String(err?.cause?.code || err?.code || err?.message || '连接失败');
    return { base: root, url, ok: false, ms: Date.now() - started, detail: reason };
  }
}

/**
 * 读 Gitee 引导文件，抽出可用的域名根（顺序：api → preferred → candidates）。
 * @returns {Promise<{ok:boolean,bases:string[],reason:string|null,updatedAt:string|null,source:string|null}>}
 */
async function fetchBootstrap(timeoutMs = BOOTSTRAP_TIMEOUT_MS) {
  if (FORCE_OFFLINE) return { ok: false, bases: [], reason: OFFLINE_DETAIL, updatedAt: null, source: null };
  try {
    const res = await fetch(GITEE_BOOTSTRAP, {
      method: 'GET',
      redirect: 'follow',
      signal: AbortSignal.timeout(timeoutMs),
      headers: { Accept: 'application/json', 'Cache-Control': 'no-cache' },
    });
    if (res.status !== 200) return { ok: false, bases: [], reason: `HTTP ${res.status}`, updatedAt: null, source: null };
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* 非 JSON */ }
    if (!json || typeof json !== 'object') return { ok: false, bases: [], reason: '引导文件不是 JSON', updatedAt: null, source: null };
    const bases = [];
    const push = (raw) => {
      const b = normalizeBase(raw);
      if (b && !bases.includes(b)) bases.push(b);
    };
    push(json.api);
    push(json.preferred);
    for (const c of Array.isArray(json.candidates) ? json.candidates : []) push(c);
    return {
      ok: bases.length > 0,
      bases,
      reason: bases.length ? null : '引导文件里没有可用地址',
      updatedAt: json.updatedAt ?? null,
      source: json.source ?? null,
    };
  } catch (err) {
    const reason = err?.name === 'TimeoutError'
      ? `超时 ${timeoutMs}ms`
      : String(err?.cause?.code || err?.code || err?.message || '连接失败');
    return { ok: false, bases: [], reason, updatedAt: null, source: null };
  }
}

/**
 * 按 ① → ② → ③ 顺序解析出一处**已验证可用**的服务端地址。
 * @param {{exclude?:string[], onProgress?:(msg:string)=>void}} opts exclude = 本轮跳过（上一轮刚失败过）的地址
 * @returns {Promise<{ok:boolean,base:string|null,source:string|null,attempts:Array<object>,bootstrap:object|null}>}
 */
async function resolveServiceUrl({ exclude = [], onProgress = () => {} } = {}) {
  const skip = new Set(exclude.map(normalizeBase).filter(Boolean));
  const tried = new Set();
  const attempts = [];

  const tryBase = async (base, source) => {
    const root = normalizeBase(base);
    if (!root || tried.has(root)) return null;
    tried.add(root);
    if (skip.has(root)) {
      attempts.push({ base: root, url: `${root}${HEALTH_PATH}`, source, ok: false, ms: 0, detail: '跳过（上一轮已判定失败）' });
      return null;
    }
    onProgress(`探活 ${root}${HEALTH_PATH} …`);
    const r = await probe(root);
    attempts.push({ ...r, source });
    return r.ok ? r : null;
  };

  /* ---------------------------------------------------------------- ① 本机 */
  if (SKIP_LOCAL) {
    attempts.push({ base: LOCAL_BASE, url: `${LOCAL_BASE}${HEALTH_PATH}`, source: '① 本机', ok: false, ms: 0, detail: '跳过（QLS_SHELL_SKIP_LOCAL=1，强制走公网回退链）' });
  } else {
    onProgress(`① 本机 ${LOCAL_BASE} …`);
    const local = await tryBase(LOCAL_BASE, '① 本机');
    if (local) return { ok: true, base: local.base, source: '① 本机', attempts, bootstrap: null };
  }

  /* ---------------------------------------------------------- ② Gitee 引导 */
  onProgress('② 读取 Gitee 引导 client-config.json …');
  const bootstrap = await fetchBootstrap();
  if (bootstrap.ok) {
    for (const b of bootstrap.bases) {
      const hit = await tryBase(b, '② Gitee 引导');
      if (hit) return { ok: true, base: hit.base, source: '② Gitee 引导', attempts, bootstrap };
    }
  } else {
    attempts.push({
      base: GITEE_BOOTSTRAP, url: GITEE_BOOTSTRAP, source: '② Gitee 引导',
      ok: false, ms: 0, detail: bootstrap.reason || '引导读取失败',
    });
  }

  /* ------------------------------------------------------------ ③ 内置候选 */
  for (const b of BUILTIN_CANDIDATES) {
    const hit = await tryBase(b, '③ 内置候选');
    if (hit) return { ok: true, base: hit.base, source: '③ 内置候选', attempts, bootstrap };
  }

  return { ok: false, base: null, source: null, attempts, bootstrap };
}

module.exports = {
  HEALTH_PATH,
  LOCAL_BASE,
  GITEE_BOOTSTRAP,
  BUILTIN_CANDIDATES,
  HEALTH_TIMEOUT_MS,
  BOOTSTRAP_TIMEOUT_MS,
  normalizeBase,
  probe,
  fetchBootstrap,
  resolveServiceUrl,
};
