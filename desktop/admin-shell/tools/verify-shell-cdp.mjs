/**
 * 桌面壳「真启动 + CDP 断言」验收套件
 * ============================================================================
 * 骨架沿用 scripts/tools/verify-admin-light-grouped-shell.mjs（同一套 CDP 类与断言写法），
 * 差异只在"浏览器"换成了**真的 exe**：本脚本自己拉起桌面壳（默认 dist-desktop 里的 portable exe），
 * 带 `--remote-debugging-port` 连上它，然后按**渲染结果**断言 —— 不看代码、不看日志。
 *
 * 逐项断言（任一 FAIL → exit 1）：
 *   ① exe 真起来了：CDP target 出现，且页面 URL 落在本机服务端（http://127.0.0.1:3100）
 *   ② 地址解析走了第 ① 档：`window.adminShell.info()` 的 base = http://127.0.0.1:3100、
 *      source 以「①」开头、首个探活记录 ok=true（= 真的探过 /api/v1/health 才加载）
 *   ③ 窗口标题是自家的：`window.adminShell.title` = 祁连山电竞 · 管理端，
 *      且操作系统层面的窗口标题（Get-Process MainWindowTitle）逐字相同
 *      —— 远端页面 <title>管理后台</title> 不许顶掉窗口标题
 *   ④ 浅色：body 底色**逐字** rgb(245, 247, 251)、<html data-theme="light">
 *   ⑤ 登录进工作台后：侧栏 8 个顶层项（名字逐条比对）、侧栏白底、主区浅底
 *   ⑥ 截图 2 张（登录页 / 工作台）落到 docs/验收素材/2026-10-11-管理端exe/
 *   ⑦ 收尾：关掉本次拉起的全部桌面壳进程（不留后台残留）
 *
 * 账号：走 scripts/tools/regression-admin.js 的**专用测试超管**（绝不碰真人超管会话）。
 *
 * 运行：
 *   node tools/verify-shell-cdp.mjs                 # 用 dist-desktop 里最新的 exe
 *   node tools/verify-shell-cdp.mjs --dev           # 用 node_modules 里的 electron 跑源码（改代码后快速自检）
 *   node tools/verify-shell-cdp.mjs --exe=<路径> --port=9222 --out=<截图目录>
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const requireCjs = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const REPO = path.resolve(ROOT, '..', '..');

/* 管理端账号唯一入口（与既有回归套件同源；未提供 REGRESSION_ADMIN_* 时会打印醒目告警） */
const { adminUser, adminPassword, adminSource } = requireCjs(path.join(REPO, 'scripts', 'tools', 'regression-admin.js'));
const ADMIN_USER = process.env.VLG_ADMIN_USER || adminUser;
const ADMIN_PASS = process.env.VLG_ADMIN_PASS || adminPassword;

const arg = (name, dflt = null) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : dflt;
};
const DEV = process.argv.includes('--dev');
/** --offline：带 QLS_SHELL_FORCE_OFFLINE=1 启动，验收"三档全灭 → 自家错误页（不白屏）+ 重试真的又跑一轮" */
const OFFLINE = process.argv.includes('--offline');
/** --no-local：带 QLS_SHELL_SKIP_LOCAL=1 启动，验收 ②→③ 公网回退链（本机开发时 ① 永远命中，这两档平时跑不到） */
const NO_LOCAL = process.argv.includes('--no-local');
const PORT = Number(arg('port', '9222'));
const OUT_DIR = arg('out', path.join(REPO, 'docs', '验收素材', '2026-10-11-管理端exe'));
const DIST_DIR = path.join(REPO, 'dist-desktop');
const EXE = arg('exe', null) || (DEV ? null : newestExe());

const EXPECT_TITLE = '祁连山电竞 · 管理端';
const EXPECT_BASE = 'http://127.0.0.1:3100';
const LIGHT_BODY = 'rgb(245, 247, 251)';
const LIGHT_SIDER = 'rgb(255, 255, 255)';
const EXPECT_TOP = ['工作台', '订单与售后', '用户与身份', '资金与抽成', '商品与内容', '客服与消息', '排行榜', '系统管理'];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const hr = (t) => console.log(`\n===== ${t} =====`);

let failCount = 0;
function record(name, fails, extra = {}) {
  const ok = fails.length === 0;
  if (!ok) failCount += 1;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  for (const [k, v] of Object.entries(extra)) console.log(`     ${k}：${v}`);
  for (const f of fails) console.log(`     ✗ ${f}`);
  return ok;
}

/* ------------------------------------------------------------------ 进程工具 */
function newestExe() {
  if (!fs.existsSync(DIST_DIR)) return null;
  const list = fs.readdirSync(DIST_DIR).filter((f) => f.toLowerCase().endsWith('.exe'))
    .map((f) => ({ f, p: path.join(DIST_DIR, f), t: fs.statSync(path.join(DIST_DIR, f)).mtimeMs }))
    .sort((a, b) => b.t - a.t);
  return list.length ? list[0].p : null;
}
const SHELL_PROC_PATTERN = DEV ? 'electron*' : '祁连山电竞*';
function killShells(pattern = SHELL_PROC_PATTERN) {
  const ps = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
    `Get-Process | Where-Object { $_.ProcessName -like '${pattern}' } | Stop-Process -Force -ErrorAction SilentlyContinue; ` +
    'Start-Sleep -Milliseconds 400; (Get-Process | Where-Object { $_.ProcessName -like \'' + pattern + '\' } | Measure-Object).Count',
  ], { encoding: 'utf8' });
  return Number(String(ps.stdout ?? '').trim() || '0');
}
/** 操作系统层面读窗口标题（证明"窗口标题"而不只是"页面里的常量"） */
function nativeWindowTitles() {
  const ps = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
    '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; ' +
    'Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object ProcessName,MainWindowTitle | ConvertTo-Json -Compress',
  ], { encoding: 'utf8' });
  const raw = String(ps.stdout ?? '').trim();
  if (!raw) return [];
  try {
    const j = JSON.parse(raw);
    return (Array.isArray(j) ? j : [j]).map((x) => ({ proc: x.ProcessName, title: x.MainWindowTitle }));
  } catch {
    return [];
  }
}

/**
 * 系统级窗口截图（含标题栏与任务栏图标）—— CDP 的 Page.captureScreenshot 只截**页面视口**，
 * 截不到窗口边框/标题栏，所以"窗口长这样"这件事必须用系统截图补一张。
 * 走临时 .ps1 文件而不是 -Command 内联：脚本里有中文、引号与多行，内联过 spawn 的命令行转义必炸。
 */
function captureWindowShot(outPath, procPattern) {
  const script = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class QlsWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
$p = Get-Process | Where-Object { $_.ProcessName -like '${procPattern}' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output 'NOWIN'; exit 0 }
[void][QlsWin]::ShowWindow($p.MainWindowHandle, 9)
[void][QlsWin]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 900
$r = New-Object QlsWin+RECT
[void][QlsWin]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { Write-Output 'BADRECT'; exit 0 }
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save('${outPath.replace(/'/g, "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output ("OK " + $w + "x" + $h)
`;
  const ps1 = path.join(os.tmpdir(), `qls-window-shot-${Date.now()}.ps1`);
  fs.writeFileSync(ps1, `\uFEFF${script}`, 'utf8'); // BOM：Windows PowerShell 5.1 读 .ps1 默认按 ANSI，中文必须带 BOM
  try {
    const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1], { encoding: 'utf8' });
    return { out: String(r.stdout ?? '').trim(), err: String(r.stderr ?? '').trim().slice(0, 300) };
  } finally {
    try { fs.unlinkSync(ps1); } catch { /* ignore */ }
  }
}

/* ------------------------------------------------------------------ CDP */
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.exceptions = [];
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.method === 'Runtime.exceptionThrown') {
        this.exceptions.push(flat(JSON.stringify(m.params?.exceptionDetails ?? {})).slice(0, 260));
      }
      if (m.id && this.pending.has(m.id)) {
        const q = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? q.reject(new Error(JSON.stringify(m.error))) : q.resolve(m.result);
      }
    });
  }
  send(method, params = {}, timeoutMs = 25000) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); } }, timeoutMs);
    });
  }
  async evalJs(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r?.exceptionDetails) throw new Error('页面执行异常：' + flat(JSON.stringify(r.exceptionDetails)).slice(0, 300));
    return r?.result?.value;
  }
  async shot(name) {
    const r = await this.send('Page.captureScreenshot', { format: 'png' });
    const buf = Buffer.from(r.data, 'base64');
    const p = path.join(OUT_DIR, name);
    fs.writeFileSync(p, buf);
    console.log(`     [SHOT] ${path.basename(p)} (${(buf.length / 1024).toFixed(0)} KB)`);
    return p;
  }
}

async function httpJson(url, timeoutMs = 4000) {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  const text = await res.text();
  return JSON.parse(text);
}

/** 等 CDP 端点出现，并返回满足条件的 page target */
async function waitForTarget(timeoutMs = 120000, match = (t) => String(t.url).startsWith(EXPECT_BASE)) {
  const started = Date.now();
  let last = '(还没连上 9222)';
  while (Date.now() - started < timeoutMs) {
    try {
      const list = await httpJson(`http://127.0.0.1:${PORT}/json/list`);
      const pages = list.filter((t) => t.type === 'page');
      const hit = pages.find(match);
      if (hit) return { target: hit, waited: Date.now() - started, pages };
      last = pages.map((p) => `${p.url}`).join(' | ') || '(没有 page target)';
    } catch (e) {
      last = String(e?.message || e);
    }
    await sleep(600);
  }
  throw new Error(`等待桌面壳页面超时（${timeoutMs}ms）；最后一次看到：${last}`);
}

/* ------------------------------------------------------------------ 页面内探针 */
const SIDER_PROBE = `(() => {
  const txt = (el) => (el ? (el.innerText || '').replace(/\\s+/g, ' ').trim() : '');
  const parents = [...document.querySelectorAll('.sider-menu .nav-parent')];
  return {
    path: location.pathname,
    topCount: parents.length,
    names: parents.map((p) => txt(p.querySelector('.nav-label')) || p.getAttribute('data-nav-group')),
    siderW: Math.round((document.querySelector('.n-layout-sider') || document.body).getBoundingClientRect().width),
    siderBg: (() => { const s = document.querySelector('.n-layout-sider'); return s ? getComputedStyle(s).backgroundColor : null; })(),
    bodyBg: getComputedStyle(document.body).backgroundColor,
    themeAttr: document.documentElement.getAttribute('data-theme'),
    pageTitle: document.title,
  };
})()`;

/** 填登录表单（走原生 setter，绕开 Vue 的 value 劫持） */
const fillAndSubmit = (user, pass) => `(() => {
  const setVal = (el, v) => {
    const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    d.set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  };
  const inputs = [...document.querySelectorAll('.login-card input')];
  if (inputs.length < 2) return 'NO_INPUTS';
  setVal(inputs[0], ${JSON.stringify(user)});
  setVal(inputs[1], ${JSON.stringify(pass)});
  const b = [...document.querySelectorAll('.login-card button')].find((x) => x.innerText.replace(/\\s+/g, '').includes('登录'));
  if (!b) return 'NO_BUTTON';
  b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return 'OK';
})()`;

/* ------------------------------------------------------------------ 主流程 */
let child = null;

/** 拉起桌面壳（dev = node_modules 里的 electron 跑源码；否则跑 exe） */
function launchShell() {
  const env = { ...process.env };
  /*
   * ⚠️ 必须清掉 ELECTRON_RUN_AS_NODE：DSH 会话（以及任何"把 electron 当 node 用"的工具链）
   * 会把这个变量注入子进程环境，electron.exe 一旦读到它就以**纯 Node** 运行 ——
   * 表现是"进程活着、窗口不开、9222 不通、require('electron') 返回一个字符串路径"。
   * 这不是壳的 bug（用户从资源管理器双击不会带这个变量），但自动化里必须显式剔除。
   */
  delete env.ELECTRON_RUN_AS_NODE;
  if (OFFLINE) env.QLS_SHELL_FORCE_OFFLINE = '1';
  if (NO_LOCAL) env.QLS_SHELL_SKIP_LOCAL = '1';

  const leftover = killShells();
  if (leftover) console.log(`     [清理] 仍有 ${leftover} 个残留壳进程（名字匹配 ${SHELL_PROC_PATTERN}）`);
  if (!DEV && !EXE) throw new Error(`dist-desktop 里没有 exe：${DIST_DIR}（先跑 npm run build）`);
  if (!DEV && !fs.existsSync(EXE)) throw new Error(`exe 不存在：${EXE}`);
  console.log(`     [模式] ${DEV ? '源码（node_modules/electron）' : '打包产物 exe'}${OFFLINE ? ' + QLS_SHELL_FORCE_OFFLINE=1' : ''}`);
  console.log(`     [目标] ${DEV ? path.join(ROOT, 'node_modules', 'electron', 'dist', 'electron.exe') : EXE}`);
  console.log(`     [参数] --remote-debugging-port=${PORT}`);

  const bin = DEV ? path.join(ROOT, 'node_modules', 'electron', 'dist', 'electron.exe') : EXE;
  const args = DEV ? [ROOT, `--remote-debugging-port=${PORT}`] : [`--remote-debugging-port=${PORT}`];
  child = spawn(bin, args, { detached: true, stdio: 'ignore', env });
  child.unref();
}

/** --offline：三档全灭 → 自家错误页；再点「重试」必须真的又跑一轮寻址 */
async function runOffline(cdp, firstPages) {
  hr('① 三档全灭 → 自家浅色错误页（不白屏）');
  const e = await cdp.evalJs(`(() => ({
    url: location.href,
    bodyBg: getComputedStyle(document.body).backgroundColor,
    h1: (document.querySelector('h1') || {}).innerText || null,
    lead: (document.querySelector('p.lead') || {}).innerText || null,
    steps: [...document.querySelectorAll('ol.steps li')].map((x) => x.innerText.trim()),
    retry: !!document.getElementById('retry'),
    rows: [...document.querySelectorAll('#attempts li')].map((x) => x.innerText.replace(/\\s+/g, ' ').trim()),
    textLen: (document.body.innerText || '').trim().length,
    shellTitle: window.adminShell ? window.adminShell.title : null,
  }))()`);
  const ef = [];
  if (!String(e.url).includes('error.html')) ef.push(`当前页不是错误页：${e.url}`);
  if (e.bodyBg !== LIGHT_BODY) ef.push(`错误页底色 = ${e.bodyBg}，期望浅色 ${LIGHT_BODY}`);
  if (!e.h1 || !e.h1.includes('连不上服务端')) ef.push(`标题不含「连不上服务端」：${e.h1}`);
  if (!e.lead || !e.lead.includes('请先启动服务')) ef.push(`正文没写清"请先启动服务"：${e.lead}`);
  if (!e.retry) ef.push('没有「重试」按钮');
  if (e.rows.length < 4) ef.push(`探活记录只有 ${e.rows.length} 条，期望 ≥4（① + Gitee + 2 内置候选）`);
  if (e.rows.some((r) => !r.includes('✗'))) ef.push('探活记录里出现了"成功"行（强制离线模式下不该有）');
  if (e.textLen < 60) ef.push(`页面文字太少（${e.textLen} 字）→ 疑似白屏`);
  if (e.shellTitle !== EXPECT_TITLE) ef.push(`壳标题 = ${e.shellTitle}，期望 ${EXPECT_TITLE}`);
  const shot = path.join(OUT_DIR, '04-管理端exe-错误页-三档全灭.png');
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(shot, Buffer.from(r.data, 'base64'));
  console.log(`     [SHOT] ${path.basename(shot)} (${(fs.statSync(shot).size / 1024).toFixed(0)} KB)`);
  record('① 错误页（浅色 / 标题 / 启动步骤 / 探活记录 / 重试按钮 / 不白屏）', ef, {
    地址: e.url, 底色: e.bodyBg, 标题: e.h1,
    探活记录: e.rows.length ? `${e.rows.length} 条` : '(空)',
    首条: e.rows[0] || '-',
  });

  hr('② 「重试」真的又跑了一轮寻址（不是假刷新）');
  const before = await cdp.evalJs('window.adminShell.info()');
  await cdp.evalJs(`document.getElementById('retry').dispatchEvent(new MouseEvent('click', { bubbles: true })); 'ok'`);
  let after = null;
  for (let i = 0; i < 40; i += 1) {
    await sleep(250);
    try {
      after = await cdp.evalJs('window.adminShell.info()');
      if (after && after.bootCount > (before?.bootCount ?? 0) && String(after.url || '').includes('error.html')) break;
    } catch { /* 页面正在切换时 evaluate 可能失败，继续等 */ }
  }
  const again = await cdp.evalJs(`(() => ({ url: location.href, retryDisabled: document.getElementById('retry')?.disabled === true }))()`);
  const rf = [];
  if (!after || !(after.bootCount > (before?.bootCount ?? 0))) {
    rf.push(`bootCount 没有增长：${before?.bootCount} → ${after?.bootCount}`);
  }
  if (!String(again.url).includes('error.html')) rf.push(`重试后当前页 = ${again.url}，期望仍是错误页（本模式仍离线）`);
  if (again.retryDisabled) rf.push('重试按钮仍处于 disabled（点完没恢复）');
  record('② 重试 → 新一轮寻址（bootCount+1）→ 仍离线则回到错误页', rf, {
    轮次: `${before?.bootCount} → ${after?.bootCount}`,
    当前页: again.url,
  });

  hr('结论（--offline）');
  console.log(failCount === 0 ? 'GREEN：全部断言通过（FAIL 0 组）' : `RED：FAIL ${failCount} 组`);
  process.exitCode = failCount === 0 ? 0 : 1;
}

/** 等页面真正挂载（公网隧道首次加载比本机慢得多；不等就会量到"还没上色的白页"= 假红） */
async function waitForApp(cdp, timeoutMs = 25000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const r = await cdp.evalJs(`(() => {
        const app = document.getElementById('app');
        return { mounted: !!app && app.children.length > 0, bg: getComputedStyle(document.body).backgroundColor };
      })()`);
      if (r?.mounted && r.bg && r.bg !== 'rgba(0, 0, 0, 0)') return { ...r, waited: Date.now() - started };
    } catch { /* 导航中 evaluate 可能失败，继续等 */ }
    await sleep(400);
  }
  return null;
}

/** --no-local：验收公网回退链（② Gitee 引导 → ③ 内置候选） */
async function runNoLocal(cdp, pages) {
  hr('① 跳过 ① 本机 → ② Gitee 引导 → ③ 内置候选（公网回退链）');
  const ready = await waitForApp(cdp);
  console.log(`     [挂载] ${ready ? `${(ready.waited / 1000).toFixed(1)}s 后页面已挂载（底色 ${ready.bg}）` : '等待挂载超时'}`);
  const info = await cdp.evalJs('window.adminShell.info()');
  const att = info?.attempts ?? [];
  const localRow = att.find((a) => String(a.source).startsWith('①'));
  const giteeRow = att.find((a) => String(a.source).startsWith('②'));
  const builtinRows = att.filter((a) => String(a.source).startsWith('③'));
  const url = await cdp.evalJs('location.href');
  const onErrorPage = String(url).includes('error.html');
  const probe = await cdp.evalJs(`(() => ({
    bodyBg: getComputedStyle(document.body).backgroundColor,
    pageTitle: document.title,
    themeAttr: document.documentElement.getAttribute('data-theme'),
    shellTitle: window.adminShell ? window.adminShell.title : null,
  }))()`);

  const f = [];
  if (!localRow || !String(localRow.detail).includes('跳过')) f.push('① 本机 没有留下"跳过"记录（测试缝没生效？）');
  if (!giteeRow) f.push('没有 ② Gitee 引导 这一档的记录');
  if (!builtinRows.length) f.push('没有 ③ 内置候选 的探活记录（② 失败后没继续往下走）');
  if (onErrorPage && info?.base !== null) f.push(`显示的是错误页，但 base = ${info?.base}（状态不一致）`);
  if (!onErrorPage) {
    if (!String(info?.source || '').startsWith('③')) f.push(`公网命中档位 = ${info?.source}（② 若可用应显示 ②；实测 ② 的两个域名当前均不可用）`);
    if (!String(url).startsWith(String(info?.base))) f.push(`页面 URL ${url} 没落在解析出的 base ${info?.base}`);
    if (probe.bodyBg !== LIGHT_BODY) f.push(`公网页面底色 = ${probe.bodyBg}，期望浅色 ${LIGHT_BODY}`);
  }
  if (probe.shellTitle !== EXPECT_TITLE) f.push(`壳标题 = ${probe.shellTitle}，期望 ${EXPECT_TITLE}`);
  if (!onErrorPage && probe.pageTitle !== '管理后台') f.push(`页面标题 = ${probe.pageTitle}，期望「管理后台」`);

  const shot = path.join(OUT_DIR, '05-管理端exe-公网回退链.png');
  fs.mkdirSync(OUT_DIR, { recursive: true });
  await sleep(2500); // 让登录卡与网格底纹画完再截（刚挂载就截会得到一张近乎空白的图）
  const r = await cdp.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(shot, Buffer.from(r.data, 'base64'));
  console.log(`     [SHOT] ${path.basename(shot)} (${fs.statSync(shot).size / 1024 | 0} KB)`);

  record('① 公网回退链：① 跳过 → ② 引导 → ③ 内置候选（命中则真加载公网页面）', f, {
    结果: onErrorPage ? '公网全灭 → 落到自家错误页（符合预期）' : `公网命中 ${info?.base}`,
    页面URL: url, 页面标题: probe.pageTitle, 底色: probe.bodyBg,
    探活链: att.map((a) => `${a.ok ? '✓' : '✗'}${String(a.source).slice(0, 1)} ${a.base}（${a.detail}）`).join('  →  '),
  });

  hr('结论（--no-local）');
  console.log(failCount === 0 ? 'GREEN：全部断言通过（FAIL 0 组）' : `RED：FAIL ${failCount} 组`);
  process.exitCode = failCount === 0 ? 0 : 1;
}

async function main() {
  if (!ADMIN_PASS) { console.error('缺少管理端口令（VLG_ADMIN_PASS 或 server/.env 的 REGRESSION_ADMIN_PASSWORD）'); process.exit(2); }
  fs.mkdirSync(OUT_DIR, { recursive: true });

  hr('准备：拉起桌面壳');
  console.log(`     [账号] ${ADMIN_USER}（来源 ${adminSource}）—— 仅在线模式用得到；--offline 不登录`);
  launchShell();

  const isOfflinePage = (t) => String(t.url).includes('error.html');
  const wantMatch = OFFLINE
    ? isOfflinePage
    : NO_LOCAL
      ? (t) => /^https?:\/\//.test(String(t.url)) || isOfflinePage(t)
      : (t) => String(t.url).startsWith(EXPECT_BASE);
  const { target, waited, pages } = await waitForTarget(120000, wantMatch);
  console.log(`     [CDP] ${(waited / 1000).toFixed(1)}s 后拿到 page target：${target.url}`);
  console.log(`     [CDP] 当时全部 target：${pages.map((p) => p.url).join(' | ')}`);
  const cdp = new CDP(new WebSocket(target.webSocketDebuggerUrl));
  await sleep(400);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');

  if (OFFLINE || NO_LOCAL) {
    try {
      if (OFFLINE) await runOffline(cdp, pages);
      else await runNoLocal(cdp, pages);
    } finally {
      hr('收尾：关掉本次拉起的桌面壳');
      const left = killShells();
      console.log(`     关闭后仍存在的壳进程：${left}`);
    }
    return;
  }

  const shots = [];
  const fails = [];

  // ================================================================ ① 壳身份 / 地址解析
  hr('① 地址解析走第 ① 档（本机 3100）且真探活过 /api/v1/health');
  const info = await cdp.evalJs('window.adminShell ? window.adminShell.info() : null');
  const firstAttempt = info?.attempts?.[0] ?? null;
  if (!info) fails.push('页面里没有 window.adminShell（preload 没注入）');
  else {
    if (info.base !== EXPECT_BASE) fails.push(`解析出的 base = ${info.base}，期望 ${EXPECT_BASE}`);
    if (!String(info.source || '').startsWith('①')) fails.push(`命中档位 = ${info.source}，期望 ① 本机`);
    if (!firstAttempt || firstAttempt.ok !== true) fails.push(`首个探活记录不是成功：${JSON.stringify(firstAttempt)}`);
    if (firstAttempt && firstAttempt.base !== EXPECT_BASE) fails.push(`首个探活地址 = ${firstAttempt.base}，期望 ${EXPECT_BASE}`);
    if (info.healthPath !== '/api/v1/health') fails.push(`探活路径 = ${info.healthPath}，期望 /api/v1/health`);
    if (info.version !== JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version) {
      fails.push(`壳版本 = ${info.version}，与 package.json 不一致`);
    }
  }
  record('① 地址解析 = ① 本机（health 200 才加载）', fails, {
    地址: info?.base, 档位: info?.source,
    首条探活: firstAttempt ? `${firstAttempt.ok ? '✓' : '✗'} ${firstAttempt.base} —— ${firstAttempt.detail}（${firstAttempt.ms}ms）` : '(无)',
  });

  // ================================================================ ② 标题 + URL
  hr('② 窗口标题（自家）/ 页面 URL / 页面标题');
  const url = await cdp.evalJs('location.href');
  const shellTitle = await cdp.evalJs('window.adminShell ? window.adminShell.title : null');
  const pageTitle = await cdp.evalJs('document.title');
  const native = nativeWindowTitles().filter((t) => /祁连山/.test(t.title || ''));
  const tf = [];
  if (!/^http:\/\/127\.0\.0\.1:3100\//.test(url)) tf.push(`页面 URL = ${url}，期望落在 ${EXPECT_BASE}/`);
  if (shellTitle !== EXPECT_TITLE) tf.push(`壳标题 = ${shellTitle}，期望 ${EXPECT_TITLE}`);
  if (pageTitle !== '管理后台') tf.push(`页面标题 = ${pageTitle}，期望「管理后台」（远端页面没加载完？）`);
  const nativeHit = native.some((t) => t.title === EXPECT_TITLE);
  if (!nativeHit) tf.push(`操作系统窗口标题里找不到「${EXPECT_TITLE}」，实测：${JSON.stringify(native)}`);
  record('② 标题 + URL', tf, {
    页面URL: url, 壳标题: shellTitle, 页面标题: pageTitle,
    系统窗口标题: native.map((t) => `${t.proc} ⇒ ${t.title}`).join(' ; ') || '(没读到)',
  });

  // ================================================================ ③ 浅色（登录页）
  hr('③ 浅色：body 底色逐字比对');
  /*
   * 必须先清会话再回登录页：壳的 userData 里存着上一次的令牌（本套件可重复跑，
   * 上一轮登录过的会话会让路由守卫直接把人送到 /dashboard —— 那时量不到登录页，
   * 断言 ③ 会"假红"）。清完 localStorage 再显式导航回 /login。
   */
  await cdp.evalJs(`localStorage.clear(); sessionStorage.clear(); 'ok'`);
  await cdp.send('Page.navigate', { url: `${EXPECT_BASE}/login` });
  await sleep(3000);
  const loginProbe = await cdp.evalJs(`(() => ({
    bodyBg: getComputedStyle(document.body).backgroundColor,
    themeAttr: document.documentElement.getAttribute('data-theme'),
    hasLoginCard: !!document.querySelector('.login-card'),
    stored: localStorage.getItem('fish_admin_theme_mode'),
    path: location.pathname,
  }))()`);
  const lf = [];
  if (loginProbe.bodyBg !== LIGHT_BODY) lf.push(`body 底色 = ${loginProbe.bodyBg}，期望逐字 ${LIGHT_BODY}`);
  if (loginProbe.themeAttr !== 'light') lf.push(`<html data-theme> = ${loginProbe.themeAttr}，期望 light`);
  if (!loginProbe.hasLoginCard) lf.push(`没有 .login-card（登录页没渲染出来，当前路径 ${loginProbe.path}）`);
  shots.push(await cdp.shot('01-管理端exe-登录页-浅色.png'));
  record('③ 浅色 = body rgb(245, 247, 251) + data-theme=light', lf, {
    底色: loginProbe.bodyBg, 主题: loginProbe.themeAttr, 主题偏好: String(loginProbe.stored),
  });

  // ================================================================ ④ 登录 → 工作台 / 侧栏 8 项
  hr('④ 登录（专用测试超管）→ 工作台 → 侧栏 8 个顶层项');
  const fill = await cdp.evalJs(fillAndSubmit(ADMIN_USER, ADMIN_PASS));
  const df = [];
  if (fill !== 'OK') df.push(`登录表单填充失败：${fill}`);
  let dash = null;
  if (fill === 'OK') {
    for (let i = 0; i < 80; i += 1) {
      await sleep(200);
      const p = await cdp.evalJs('location.pathname');
      if (p && p !== '/login') break;
    }
    await sleep(1400);
    dash = await cdp.evalJs(SIDER_PROBE);
    if (dash.path !== '/dashboard') df.push(`登录后地址 = ${dash.path}，期望 /dashboard`);
    if (dash.topCount !== EXPECT_TOP.length) df.push(`侧栏顶层项 = ${dash.topCount} 个，期望 ${EXPECT_TOP.length} 个`);
    if (JSON.stringify(dash.names) !== JSON.stringify(EXPECT_TOP)) {
      df.push(`顶层项名字/顺序不吻合：实际 ${JSON.stringify(dash.names)}，期望 ${JSON.stringify(EXPECT_TOP)}`);
    }
    if (dash.bodyBg !== LIGHT_BODY) df.push(`工作台 body 底色 = ${dash.bodyBg}，期望 ${LIGHT_BODY}`);
    if (dash.siderBg !== LIGHT_SIDER) df.push(`侧栏底色 = ${dash.siderBg}，期望白底 ${LIGHT_SIDER}`);
    if (dash.themeAttr !== 'light') df.push(`工作台 data-theme = ${dash.themeAttr}，期望 light`);
    shots.push(await cdp.shot('02-管理端exe-工作台-浅色.png'));
  }
  record('④ 工作台 + 侧栏 8 个顶层项 + 浅色白底侧栏', df, {
    地址: dash?.path, 顶层项: (dash?.names || []).join(' · '),
    侧栏底色: dash?.siderBg, 主区底色: dash?.bodyBg, 侧栏宽: dash ? `${dash.siderW}px` : '-',
  });

  // ================================================================ ⑤ 页面无 JS 异常
  hr('⑤ 渲染进程无未捕获异常');
  const exFails = cdp.exceptions.length ? cdp.exceptions.slice(0, 3) : [];
  record('⑤ 无未捕获异常', exFails, { 异常数: cdp.exceptions.length });

  // ================================================================ ⑥ 截图
  hr('⑥ 截图');
  const missing = shots.filter((p) => !fs.existsSync(p) || fs.statSync(p).size < 4096);
  record('⑥ 截图 2 张（登录页 / 工作台）', missing.map((p) => `缺图或过小：${p}`), {
    目录: OUT_DIR, 清单: shots.map((p) => `${path.basename(p)}(${Math.round(fs.statSync(p).size / 1024)}KB)`).join(' '),
  });
  /* 系统级窗口截图（含标题栏）：CDP 截不到窗口边框，这部分只能靠系统截图 */
  const winShot = path.join(OUT_DIR, '03-管理端exe-窗口截图-含标题栏.png');
  const shotRes = captureWindowShot(winShot, DEV ? 'electron*' : '祁连山电竞-管理端*');
  const shotOk = shotRes.out.startsWith('OK') && fs.existsSync(winShot) && fs.statSync(winShot).size > 4096;
  console.log(`     [系统截图] ${shotRes.out || shotRes.err || '(无输出)'} → ${shotOk ? `${path.basename(winShot)}(${Math.round(fs.statSync(winShot).size / 1024)}KB)` : '未生成'}`);
  if (!shotOk) console.log('     [系统截图] 未生成不算失败（无桌面会话/被遮挡时属正常），CDP 页面截图仍然有效');

  // ================================================================ 收尾
  hr('⑦ 收尾：关掉本次拉起的桌面壳');
  try { await cdp.send('Browser.close', {}, 3000); } catch { /* 有的版本不支持 */ }
  await sleep(1200);
  const left = killShells();
  console.log(`     关闭后仍存在的壳进程：${left}`);
  if (left) record('⑦ 关闭桌面壳', [`仍有 ${left} 个壳进程未退出`]); else record('⑦ 关闭桌面壳（无残留）', []);

  hr('结论');
  console.log(failCount === 0 ? `GREEN：全部断言通过（FAIL 0 组）` : `RED：FAIL ${failCount} 组`);
  console.log(`exe：${DEV ? '(源码模式，未用 exe)' : EXE}`);
  console.log(`截图：${OUT_DIR}`);
  process.exitCode = failCount === 0 ? 0 : 1;
}

main().catch((e) => {
  console.error(`\n[套件异常] ${e?.stack || e}`);
  try { killShells(); } catch { /* ignore */ }
  process.exitCode = 2;
});
