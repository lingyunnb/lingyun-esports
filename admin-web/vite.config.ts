import { fileURLToPath, URL } from 'node:url';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

/**
 * 后端代理目标（唯一出处）
 * ============================================================================
 * 2026-10-15 负责人定案：「**指到云端**」—— 本机跑的管理端 dev server 直接连**生产云端**。
 *
 * ## 为什么改（本机踩过的真实故障）
 * 本机 `fish-server`（:3100）依赖 Docker 提供的 MySQL/Redis。Docker Desktop 没开时，
 * 它会**崩溃重启循环**（实测 pm2 记到 3128 次重启），于是：
 *   · 本地管理端页面**照常画得出来**（前端只是静态资源）
 *   · 但 `/api/*` 全部失败 → 登录报「登录失败，请稍后重试」
 * 这条文案是 `LoginView.vue` 里 **`ApiException` 之外的兜底**（网络层失败），
 * **极容易被误读成"账号或密码错了"** —— 而密码其实没错，请求根本没到服务端。
 * 把代理指向云端后，本机窗口立刻可用（2026-10-15 实测：登录 200）。
 *
 * ## ⚠️ 代价（必须知道）
 * 这么配之后，**本机管理端的读写全部落在生产库**：
 *   · 适合「用管理端看/操作线上真实数据」；
 *   · **不适合**"改坏了不怕"的本地开发 —— 那要先 `npm run infra:start` 起 Docker，
 *     再起本地 `fish-server`，并把这个变量切回 `http://127.0.0.1:3100`。
 *
 * ## 怎么切换（不需要改代码）
 * 设环境变量后重启 dev server：
 *   · 回本地：`VITE_PROXY_TARGET=http://127.0.0.1:3100`
 *   · 换环境：`VITE_PROXY_TARGET=http://<其他IP>:3100`
 *
 * ## 为什么用环境变量而不是写死
 * 本机既是"开发机"也是"操作线上的终端"，两种用法都要保留；写死会把另一种堵掉。
 */
const PROXY_TARGET = process.env.VITE_PROXY_TARGET || 'http://YOUR_SERVER_HOST:3100';

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5173,
    proxy: {
      // 前端统一使用相对路径 /api/...（打包后同源，dev 期由这里转发）
      // 注意：3000 被本机已有 nssm 服务占用，本项目后端用 3100（见 docs/11）
      '/api': { target: PROXY_TARGET, changeOrigin: true },
      // 媒体文件（阶段13：/media/public|protected 相对路径直接回源）
      '/media': { target: PROXY_TARGET, changeOrigin: true },
    },
  },
});
