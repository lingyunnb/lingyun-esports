/** pm2 进程编排（docs/11）：后端 + Cloudflare 隧道（Windows fork 模式；OtherProject 服务不受影响） */
module.exports = {
  apps: [
    {
      name: 'fish-server',
      cwd: __dirname,
      script: 'dist/main.js',
      env: { NODE_ENV: 'production' },
      max_restarts: 20,
      restart_delay: 3000,
      out_file: '../data/logs/fish-server-out.log',
      error_file: '../data/logs/fish-server-error.log',
      merge_logs: true,
      time: true,
    },
    {
      name: 'fish-tunnel',
      cwd: '../infra/tunnel',
      script: 'cloudflared.exe',
      args: 'tunnel --url http://localhost:3100 --no-autoupdate',
      max_restarts: 10,
      restart_delay: 5000,
      out_file: '../data/logs/fish-tunnel-out.log',
      error_file: '../data/logs/fish-tunnel-error.log',
      merge_logs: true,
    },
  ],
};
