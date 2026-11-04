'use strict';
/* 错误页：渲染"本轮探活了哪些地址、各自为什么失败"，并把「重试」接回主进程 */
(() => {
  const $ = (id) => document.getElementById(id);
  const retryBtn = $('retry');
  const hintEl = $('hint');

  function render(info) {
    if (!info) return;
    $('version').textContent = `v${info.version}`;
    const list = $('attempts');
    list.innerHTML = '';
    const rows = Array.isArray(info.attempts) ? info.attempts : [];
    if (!rows.length) {
      const li = document.createElement('li');
      li.innerHTML = '<span class="mark bad">✗</span><span class="addr">（没有探活记录）</span>';
      list.appendChild(li);
      return;
    }
    for (const a of rows) {
      const li = document.createElement('li');
      const mark = document.createElement('span');
      mark.className = `mark ${a.ok ? 'ok' : 'bad'}`;
      mark.textContent = a.ok ? '✓' : '✗';
      const where = document.createElement('span');
      where.className = 'where';
      where.textContent = a.source || '—';
      const addr = document.createElement('span');
      addr.className = 'addr';
      addr.textContent = a.base || a.url || '—';
      const why = document.createElement('span');
      why.className = 'why';
      why.textContent = `${a.detail || ''}${a.ms ? ` · ${a.ms}ms` : ''}`;
      li.append(mark, where, addr, why);
      list.appendChild(li);
    }
    const tried = rows.length;
    hintEl.textContent = `已试 ${tried} 处地址，全部不可用`;
  }

  retryBtn.addEventListener('click', async () => {
    retryBtn.disabled = true;
    hintEl.textContent = '正在重新探活…';
    try {
      await window.adminShell.retry();
    } catch {
      /* 主进程会切到加载页，这里不需要处理 */
    }
    setTimeout(() => { retryBtn.disabled = false; }, 1500);
  });

  (async () => {
    try {
      render(await window.adminShell.info());
    } catch {
      hintEl.textContent = '读不到壳诊断信息（preload 未生效）';
    }
  })();
})();
