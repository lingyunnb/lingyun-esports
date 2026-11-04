/**
 * 部署到云服务器（2026-10-13 云迁移后新增）。
 *
 * 用法：
 *   node scripts/tools/deploy-cloud.js server       # 只发服务端 dist（改后端时）
 *   node scripts/tools/deploy-cloud.js admin-web    # 只发管理端 dist（改后台时）
 *   node scripts/tools/deploy-cloud.js all          # 两个都发
 *
 * 做四件事：① 本地打包 dist → ② SFTP 上传 → ③ 远端解包覆盖 → ④ pm2 重启 + health 自检
 * 凭据读 data/temp/cloud-ssh.json（data/ 不入 git）。
 *
 * 为什么需要它：生产已在云服务器（香港），本机只剩开发/备用角色。
 * 以前改完代码本机 `pm2 restart` 就生效，现在**必须显式部署**，否则线上代码不动（且不会报错，最难查）。
 */
const { Client } = require('D:/fish/data/temp/sshtool/node_modules/ssh2');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = 'D:/fish';
const CRED = path.join(ROOT, 'data/temp/cloud-ssh.json');
if (!fs.existsSync(CRED)) { console.error('缺少凭据文件:', CRED); process.exit(1); }
const cred = JSON.parse(fs.readFileSync(CRED, 'utf8'));
const REMOTE = cred.appDir || '/opt/fish';

const TARGETS = {
  server: { local: 'server/dist', remote: `${REMOTE}/server/dist`, label: '服务端' },
  'admin-web': { local: 'admin-web/dist', remote: `${REMOTE}/admin-web/dist`, label: '管理端' },
  // 网页版 H5（2026-10-15）：由服务端在 `/h5/` 下托管（见 server/src/main.ts），
  // 所以发完这个目录**不需要重启服务端** —— 静态资源直接生效。
  'h5-web': { local: 'h5-web/dist', remote: `${REMOTE}/h5-web/dist`, label: '网页版 H5', noRestart: true },
};

const which = (process.argv[2] || 'all').toLowerCase();
const names = which === 'all' ? Object.keys(TARGETS) : [which];
for (const n of names) {
  if (!TARGETS[n]) { console.error(`未知目标 ${n}；可选：server / admin-web / h5-web / all`); process.exit(1); }
}

function connect() {
  return new Promise((resolve, reject) => {
    const c = new Client();
    c.on('ready', () => resolve(c)).on('error', reject);
    c.connect({ host: cred.host, port: cred.port || 22, username: cred.username, password: cred.password, readyTimeout: 30000 });
  });
}

function exec(c, cmd) {
  return new Promise((resolve, reject) => {
    c.exec(cmd, (err, stream) => {
      if (err) return reject(err);
      let out = '';
      stream.on('data', (d) => { out += d.toString('utf8'); });
      stream.stderr.on('data', (d) => { out += d.toString('utf8'); });
      stream.on('close', (code) => (code === 0 ? resolve(out) : reject(new Error(`exit ${code}\n${out}`))));
    });
  });
}

function upload(c, local, remote) {
  return new Promise((resolve, reject) => {
    c.sftp((err, sftp) => {
      if (err) return reject(err);
      const total = fs.statSync(local).size;
      const rs = fs.createReadStream(local);
      const ws = sftp.createWriteStream(remote);
      let sent = 0;
      rs.on('data', (d) => { sent += d.length; });
      ws.on('close', () => resolve(sent));
      ws.on('error', reject);
      rs.on('error', reject);
      rs.pipe(ws);
    });
  });
}

(async () => {
  console.log(`=== 部署到云服务器 ${cred.host} ===\n`);

  // ① 本地打包（相对路径避免 GNU tar 把 D: 当远程主机）
  const tars = [];
  for (const n of names) {
    const t = TARGETS[n];
    const localDir = path.join(ROOT, t.local);
    if (!fs.existsSync(localDir)) { console.error(`✗ 本地不存在: ${t.local}（先构建）`); process.exit(1); }
    const tarPath = path.join(ROOT, 'data/temp', `deploy-${n}.tar.gz`);
    if (fs.existsSync(tarPath)) fs.unlinkSync(tarPath);
    execFileSync('tar', ['-czf', path.join('..', '..', 'data', 'temp', `deploy-${n}.tar.gz`), '.'], { cwd: localDir });
    const size = (fs.statSync(tarPath).size / 1024).toFixed(0);
    console.log(`  ① 本地打包 ${t.label}: ${size} KB`);
    tars.push({ n, t, tarPath });
  }

  const c = await connect();
  console.log(`  ② 已连接 ${cred.host}\n`);

  for (const { n, t, tarPath } of tars) {
    const remoteTar = `/tmp/deploy-${n}.tar.gz`;
    await upload(c, tarPath, remoteTar);
    // 远端：清空旧目录再解包（避免残留被删文件的旧副本）
    await exec(c, `mkdir -p ${t.remote} && rm -rf ${t.remote}/* && tar -xzf ${remoteTar} -C ${t.remote} && rm -f ${remoteTar} && echo OK`);
    const count = (await exec(c, `find ${t.remote} -type f | wc -l`)).trim();
    console.log(`  ③ 远端覆盖 ${t.label}: ${t.remote}（${count} 个文件）`);
  }

  // ④ 重启 + 自检（容器不需要重启）
  console.log('\n  ④ 重启服务端并自检…');
  await exec(c, 'pm2 restart fish-server >/dev/null 2>&1 && echo restarted');
  let health = '000';
  for (let i = 1; i <= 15; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    health = (await exec(c, `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/api/v1/health || echo 000`)).trim();
    if (health === '200') break;
  }
  console.log(`     health = ${health} ${health === '200' ? '✅' : '❌'}`);
  const detail = await exec(c, `curl -s http://127.0.0.1:3100/api/v1/health`);
  console.log(`     ${detail.trim()}`);

  // 外部可见性自检（从本机再看一次）
  // ⚠️ 输出重定向必须用平台正确的空设备：Windows 是 NUL，类 Unix 是 /dev/null
  const nullDev = process.platform === 'win32' ? 'NUL' : '/dev/null';
  const ext = execFileSync('curl', ['-s', '-o', nullDev, '-w', '%{http_code}', '-m', '20', `http://${cred.host}:3100/api/v1/health`], { encoding: 'utf8', shell: false });
  console.log(`     外网 health = ${ext} ${ext === '200' ? '✅' : '❌'}`);

  c.end();
  console.log('\n=== 部署完成 ===');
})().catch((e) => { console.error('✗ 部署失败:', e.message); process.exit(1); });
