'use strict';
/**
 * preload —— 渲染进程（含远端管理端页面）能看到的**唯一**壳接口。
 * contextIsolation + sandbox 打开，这里只用 contextBridge 暴露只读信息与"重试"动作，
 * 不给远端页面任何 Node 能力（薄壳的安全底线）。
 */
const { contextBridge, ipcRenderer } = require('electron');

/** 从 additionalArguments 里取壳信息（sandbox 下 process.argv 可用） */
function argOf(prefix) {
  const hit = (process.argv || []).find((a) => a.startsWith(prefix));
  if (!hit) return null;
  try {
    return decodeURIComponent(hit.slice(prefix.length));
  } catch {
    return hit.slice(prefix.length);
  }
}

const SHELL_TITLE = argOf('--qls-shell-title=') || '祁连山电竞 · 管理端';
const SHELL_VERSION = argOf('--qls-shell-version=') || '0.0.0';

contextBridge.exposeInMainWorld('adminShell', {
  /* 壳身份（CDP 验收据此断言"窗口标题是自家的、不是远端页面标题"） */
  title: SHELL_TITLE,
  version: SHELL_VERSION,
  isShell: true,
  /* 诊断：当前地址 / 来源 / 本次探活记录 */
  info: () => ipcRenderer.invoke('shell:info'),
  /* 错误页「重试」 */
  retry: () => ipcRenderer.send('shell:retry'),
  /* 加载页状态文本订阅 */
  onStatus: (cb) => {
    if (typeof cb !== 'function') return;
    ipcRenderer.on('shell:status', (_e, msg) => cb(String(msg)));
  },
  openExternal: (url) => ipcRenderer.send('shell:open-external', url),
});
