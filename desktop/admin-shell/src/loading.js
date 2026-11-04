'use strict';
/* 加载页：显示主进程推来的探活进度；页面加载完先主动拉一次当前状态（防丢事件） */
(async () => {
  const statusEl = document.getElementById('status');
  const localEl = document.getElementById('local');
  const set = (msg) => { if (msg) statusEl.textContent = String(msg); };

  const shell = window.adminShell;
  if (!shell) {
    set('壳接口未注入（preload 未生效）——请查看开发者工具控制台。');
    return;
  }
  shell.onStatus(set);
  try {
    const info = await shell.info();
    if (info) {
      if (info.localBase && localEl) localEl.textContent = info.localBase;
      set(info.status);
    }
  } catch {
    /* 拉不到就保持 HTML 里的默认文案 */
  }
})();
