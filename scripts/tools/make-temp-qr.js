/**
 * 生成临时入口二维码（自包含，不联网）+ 用 jsQR 回读自证。
 *
 * 输出（覆盖式）：
 *   site/download/download-temp-qr.png        → <TUNNEL>/site/                （稳定：页面自读 latest）
 *   site/download/download-temp-apk-boss.png  → <TUNNEL>/api/v1/public/app-versions/download/<bossId>  （一次到位）
 *   site/download/download-temp-apk-worker.png→ 同上 worker
 *
 * 为什么会话要有 APK 直链版：/site/ 版**跟着隧道换域名**但"扫一次就能到下载页"；
 * APK 直链版**扫一次直接下 APK**（少一跳），代价是下载 id 会随版本变，下次发布要重生成。
 * 两个都给，README 里写清各自的有效期。
 *
 * 用法：
 *   set NODE_PATH=%TEMP%\fish-qr-tools\node_modules
 *   node scripts/tools/make-temp-qr.js
 */
const fs = require('fs');
const path = require('path');
const { encodeQR, matrixToPng } = require('./qr-encode.js');

const REPO = 'D:/fish';
const OUT = path.join(REPO, 'site', 'download');
const BASE = 'http://127.0.0.1:3100/api/v1';

const sha256 = (buf) => require('crypto').createHash('sha256').update(buf).digest('hex');

async function latestId(appType) {
  const r = await fetch(`${BASE}/public/app-versions/latest?appType=${appType}&currentVersionCode=1`);
  const j = await r.json();
  return j.data?.latest?.downloadUrl || null;
}

(async () => {
  const tunnel = (process.env.FISH_TUNNEL ||
    JSON.parse(fs.readFileSync(path.join(REPO, 'config', 'client-config.json'), 'utf8')).ws ||
    '').replace(/\/+$/, '');
  if (!tunnel) { console.error('!! 无法确定隧道地址（config/client-config.json 的 ws 为空）'); process.exit(1); }

  const bossUrl = await latestId('boss');
  const workerUrl = await latestId('worker');
  const targets = [
    { file: 'download-temp-qr.png', payload: `${tunnel}/site/`, label: 'temp-entry (site page)' },
  ];
  if (bossUrl) targets.push({ file: 'download-temp-apk-boss.png', payload: tunnel + bossUrl, label: 'temp-direct (boss apk)' });
  if (workerUrl) targets.push({ file: 'download-temp-apk-worker.png', payload: tunnel + workerUrl, label: 'temp-direct (worker apk)' });

  console.log(`TUNNEL = ${tunnel}`);
  let fail = 0;
  for (const t of targets) {
    const qr = encodeQR(t.payload);
    // scale=16：模块 16px，33 模块版 → 528+128 = 656px，手机扫码更稳（打印/远距离也不糊）
    const png = matrixToPng(qr.modules, { scale: 16, quiet: 4 });
    const out = path.join(OUT, t.file);
    fs.writeFileSync(out, png);
    console.log('');
    console.log(`[${t.label}]`);
    console.log(`  payload : ${t.payload}`);
    console.log(`  version : ${qr.version} (${qr.size}x${qr.size})  mask=${qr.mask}  ecc=M`);
    console.log(`  file    : ${out}`);
    console.log(`  bytes   : ${png.length}   sha256: ${sha256(png)}`);
  }

  // ---- 回读自证（必须在新进程/新读取里做才可靠；同进程读取刚写完的文件在 Windows 上偶发读到旧内容）
  console.log('');
  console.log('=== 回读校验（jsQR）===');
  const { PNG } = require('pngjs');
  const jsQR = require('jsqr');
  for (const t of targets) {
    const out = path.join(OUT, t.file);
    const png = PNG.sync.read(fs.readFileSync(out));
    const res = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
    if (!res) { console.log(`  DECODE_FAIL ${t.file} (${png.width}x${png.height})`); fail++; continue; }
    const ok = res.data === t.payload;
    console.log(`  ${ok ? 'OK  ' : 'FAIL'} ${t.file} | ${png.width}x${png.height} | ${res.data}`);
    if (!ok) { console.log(`       期望: ${t.payload}`); fail++; }
  }
  console.log('');
  console.log(fail === 0 ? '结论：全部二维码回读成功且 payload 逐字一致 ✓' : `结论：${fail} 项失败 ✗`);
  process.exit(fail === 0 ? 0 : 1);
})();
