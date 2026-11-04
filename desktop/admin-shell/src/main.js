'use strict';
/**
 * 祁连山电竞 · 管理端 桌面薄壳 —— 主进程
 * ============================================================================
 * 形态：**壳 + 远程页面**（薄壳方案）
 *   · exe 里只有"寻址 + 窗口 + 菜单 + 错误页"，管理端页面始终从服务端加载
 *     → 页面（admin-web）更新后 **exe 不用重发**，重开一次就是新页面。
 *   · 寻址顺序 ① 本机 3100 → ② Gitee 引导 client-config.json → ③ 内置候选，
 *     每一档都要 /api/v1/health 返回 200（详见 src/resolver.js）。
 *   · 三档全灭 → 自家风格浅色错误页（带"重试"），**不白屏、不裸报 ERR_CONNECTION**。
 *
 * 窗口：默认 1600×1000（下限 1440×900），大小/位置/最大化状态记忆在 userData/window-state.json。
 * 标题：恒为「祁连山电竞 · 管理端」（拦 page-title-updated，不让远端页面标题顶掉）。
 * 菜单：精简三组 —— 管理端（重新连接 / 退出）· 视图（刷新 / 强制刷新 / 开发者工具 / 缩放 / 全屏）· 帮助（关于）。
 */
const { app, BrowserWindow, Menu, ipcMain, shell, dialog, screen } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const R = require('./resolver');

const APP_TITLE = '祁连山电竞 · 管理端';
const DEFAULT_WIDTH = 1600;
const DEFAULT_HEIGHT = 1000;
const MIN_WIDTH = 1440;
const MIN_HEIGHT = 900;
const PAGE_BG = '#f5f7fb';

const SRC_DIR = __dirname;
const ROOT_DIR = path.join(__dirname, '..');
const ICON_PNG = path.join(ROOT_DIR, 'build', 'icon.png');
const LOADING_PAGE = path.join(SRC_DIR, 'loading.html');
const ERROR_PAGE = path.join(SRC_DIR, 'error.html');

/** @type {BrowserWindow|null} */
let win = null;
let currentBase = null;
let currentSource = null;
let attempts = [];
let bootstrapInfo = null;
let statusText = '正在启动…';
let resolving = false;
/** 已经因"加载失败"重解析过一次就不再无限重试，直接给错误页（避免秒级死循环） */
let reloadGuard = 0;
/** 第几轮寻址（错误页「重试」是否真的又跑了一轮，靠它断言，不靠"看起来刷新了"） */
let bootCount = 0;

/* ------------------------------------------------------------------ 窗口状态 */
function statePath() {
  return path.join(app.getPath('userData'), 'window-state.json');
}
function readState() {
  try {
    return JSON.parse(fs.readFileSync(statePath(), 'utf8')) || {};
  } catch {
    return {};
  }
}
function writeState(patch) {
  const next = { ...readState(), ...patch };
  try {
    fs.mkdirSync(path.dirname(statePath()), { recursive: true });
    fs.writeFileSync(statePath(), JSON.stringify(next, null, 2), 'utf8');
  } catch {
    /* 状态存不下来不该影响使用 */
  }
}
/** 记忆的位置必须仍落在某块屏幕的工作区内，否则丢弃（换显示器/拔外接屏后不至于开到看不见的地方） */
function sanitizeBounds(b) {
  if (!b) return null;
  const { x, y, width, height } = b;
  if (![x, y, width, height].every((v) => Number.isFinite(v))) return null;
  const rect = {
    x: Math.round(x),
    y: Math.round(y),
    width: Math.max(MIN_WIDTH, Math.round(width)),
    height: Math.max(MIN_HEIGHT, Math.round(height)),
  };
  const visible = screen.getAllDisplays().some((d) => {
    const a = d.workArea;
    const ox = Math.min(rect.x + rect.width, a.x + a.width) - Math.max(rect.x, a.x);
    const oy = Math.min(rect.y + rect.height, a.y + a.height) - Math.max(rect.y, a.y);
    return ox >= 120 && oy >= 60;
  });
  return visible ? rect : null;
}

/* ------------------------------------------------------------------ 页面切换 */
function pushStatus(msg) {
  statusText = msg;
  if (win && !win.isDestroyed() && !win.webContents.isDestroyed()) {
    win.webContents.send('shell:status', msg);
  }
}
function showPage(file) {
  if (!win || win.isDestroyed()) return Promise.resolve();
  return win.loadFile(file);
}

async function showErrorPage() {
  if (!win || win.isDestroyed()) return;
  await showPage(ERROR_PAGE);
}

/**
 * 解析地址并加载页面。exclude 里的地址本轮跳过（上一轮刚失败过）。
 */
async function boot({ exclude = [] } = {}) {
  if (!win || win.isDestroyed() || resolving) return;
  resolving = true;
  bootCount += 1;
  try {
    pushStatus('正在解析服务端地址…');
    await showPage(LOADING_PAGE);
    const result = await R.resolveServiceUrl({ exclude, onProgress: pushStatus });
    attempts = result.attempts;
    bootstrapInfo = result.bootstrap;
    if (!result.ok) {
      currentBase = null;
      currentSource = null;
      await showErrorPage();
      return;
    }
    currentBase = result.base;
    currentSource = result.source;
    reloadGuard = 0;
    if (String(result.source).startsWith('①')) {
      pushStatus(`已连上本机 ${result.base}，正在加载管理端…`);
    } else {
      pushStatus(`已连上 ${result.base}（${result.source}），正在加载管理端…`);
    }
    await win.loadURL(`${result.base}/`);
  } catch (err) {
    attempts = attempts.concat([{ base: currentBase || '-', url: currentBase || '-', source: '加载', ok: false, ms: 0, detail: String(err?.message || err) }]);
    await showErrorPage();
  } finally {
    resolving = false;
  }
}

/* ------------------------------------------------------------------ 菜单 */
function buildMenu() {
  /** @type {Electron.MenuItemConstructorOptions[]} */
  const template = [
    {
      label: '管理端',
      submenu: [
        {
          label: '重新连接服务端',
          accelerator: 'CmdOrCtrl+Alt+R',
          click: () => { reloadGuard = 0; boot(); },
        },
        {
          label: '在浏览器中打开当前地址',
          enabled: !!currentBase,
          click: () => { if (currentBase) shell.openExternal(`${currentBase}/`); },
        },
        { type: 'separator' },
        { label: '退出', accelerator: 'CmdOrCtrl+Q', click: () => app.quit() },
      ],
    },
    {
      label: '视图',
      submenu: [
        { label: '刷新', accelerator: 'CmdOrCtrl+R', click: () => win && win.webContents.reload() },
        { label: '强制刷新（不用缓存）', accelerator: 'CmdOrCtrl+Shift+R', click: () => win && win.webContents.reloadIgnoringCache() },
        { type: 'separator' },
        {
          label: '开发者工具',
          accelerator: 'F12',
          click: () => {
            if (!win) return;
            if (win.webContents.isDevToolsOpened()) win.webContents.closeDevTools();
            else win.webContents.openDevTools({ mode: 'detach', activate: true });
          },
        },
        { type: 'separator' },
        { label: '实际大小', role: 'resetZoom' },
        { label: '放大', role: 'zoomIn' },
        { label: '缩小', role: 'zoomOut' },
        { type: 'separator' },
        { label: '全屏', accelerator: 'F11', role: 'togglefullscreen' },
      ],
    },
    {
      label: '帮助',
      submenu: [
        {
          label: '关于 / 诊断信息',
          click: () => {
            const lines = [
              `版本：${app.getVersion()}`,
              `当前地址：${currentBase ? `${currentBase}/（${currentSource}）` : '未连接'}`,
              `探活路径：${R.HEALTH_PATH}`,
              '',
              '地址解析顺序：',
              `  ① 本机 ${R.LOCAL_BASE}`,
              `  ② Gitee 引导 ${R.GITEE_BOOTSTRAP}`,
              `  ③ 内置候选 ${R.BUILTIN_CANDIDATES.join(' , ')}`,
              '',
              '本轮探活记录：',
              ...(attempts.length
                ? attempts.map((a) => `  ${a.ok ? '✓' : '✗'} ${a.source} ${a.base} —— ${a.detail}${a.ms ? `（${a.ms}ms）` : ''}`)
                : ['  （暂无）']),
            ];
            dialog.showMessageBox(win, { type: 'info', title: '关于', message: APP_TITLE, detail: lines.join('\n'), buttons: ['知道了'], noLink: true });
          },
        },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

/* ------------------------------------------------------------------ 窗口 */
function createWindow() {
  const st = readState();
  const bounds = sanitizeBounds(st.bounds);
  win = new BrowserWindow({
    title: APP_TITLE,
    width: bounds ? bounds.width : DEFAULT_WIDTH,
    height: bounds ? bounds.height : DEFAULT_HEIGHT,
    ...(bounds ? { x: bounds.x, y: bounds.y } : {}),
    minWidth: MIN_WIDTH,
    minHeight: MIN_HEIGHT,
    show: false,
    backgroundColor: PAGE_BG,
    ...(fs.existsSync(ICON_PNG) ? { icon: ICON_PNG } : {}),
    autoHideMenuBar: false,
    webPreferences: {
      preload: path.join(SRC_DIR, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      devTools: true,
      additionalArguments: [
        `--qls-shell-title=${encodeURIComponent(APP_TITLE)}`,
        `--qls-shell-version=${encodeURIComponent(app.getVersion())}`,
      ],
    },
  });

  /* 标题恒为自家标题：远端页面 <title>管理后台</title> 不许顶掉窗口标题 */
  win.on('page-title-updated', (e) => e.preventDefault());

  win.once('ready-to-show', () => {
    if (st.maximized) win.maximize();
    win.show();
  });

  const saveBounds = () => {
    if (!win || win.isDestroyed() || win.isMinimized()) return;
    writeState({ bounds: win.getNormalBounds(), maximized: win.isMaximized() });
  };
  let saveTimer = null;
  const saveSoon = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveBounds, 400);
  };
  win.on('resize', saveSoon);
  win.on('move', saveSoon);
  win.on('maximize', saveSoon);
  win.on('unmaximize', saveSoon);
  win.on('close', () => { clearTimeout(saveTimer); saveBounds(); });
  win.on('closed', () => { win = null; });

  /* 外链走系统浏览器；窗口内只允许自家地址与本地错误/加载页 */
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    const isLocalPage = url.startsWith('file://');
    const sameBase = currentBase && url.startsWith(`${currentBase}/`);
    if (!isLocalPage && !sameBase) {
      e.preventDefault();
      if (/^https?:/i.test(url)) shell.openExternal(url);
    }
  });
  win.webContents.on('did-fail-load', (e, code, desc, url, isMainFrame) => {
    if (!isMainFrame) return;
    if (code === -3) return; // ERR_ABORTED：正常跳转/主动中断，不算失败
    if (!url || url.startsWith('file://')) return;
    attempts = attempts.concat([{ base: currentBase || url, url, source: '加载', ok: false, ms: 0, detail: `${desc}（${code}）` }]);
    const failed = currentBase;
    currentBase = null;
    if (reloadGuard < 1 && failed) {
      reloadGuard += 1;
      /* 刚探活通过的地址也可能在加载瞬间断掉 → 重解析一次并跳过它，别直接甩错误页 */
      boot({ exclude: [failed] });
    } else {
      showErrorPage();
    }
  });

  buildMenu();
  boot();
}

/* ------------------------------------------------------------------ IPC（供 preload/页面读取与"重试"） */
function diagnostics() {
  return {
    title: APP_TITLE,
    version: app.getVersion(),
    base: currentBase,
    source: currentSource,
    pageUrl: currentBase ? `${currentBase}/` : null,
    status: statusText,
    bootCount,
    healthPath: R.HEALTH_PATH,
    localBase: R.LOCAL_BASE,
    giteeBootstrap: R.GITEE_BOOTSTRAP,
    builtinCandidates: R.BUILTIN_CANDIDATES,
    attempts,
    bootstrap: bootstrapInfo,
    userData: app.getPath('userData'),
  };
}
ipcMain.handle('shell:info', () => diagnostics());
ipcMain.on('shell:retry', () => { reloadGuard = 0; boot(); });
ipcMain.on('shell:open-external', (e, url) => {
  if (typeof url === 'string' && /^https?:\/\//i.test(url)) shell.openExternal(url);
});

/* ------------------------------------------------------------------ 生命周期 */
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });
  app.on('window-all-closed', () => app.quit());
  app.whenReady().then(() => {
    createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });
}
