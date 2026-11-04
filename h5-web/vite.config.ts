import { fileURLToPath, URL } from 'node:url';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

/**
 * 网页版（H5）构建配置
 * ============================================================================
 * ## 为什么 `base: '/h5/'`
 * 生产环境的静态产物由**同一个 NestJS 服务**托管（照抄 `admin-web` 的模式，
 * 见 `server/src/main.ts` 的 `express.static(adminDist)`）。
 * 管理端占了根路径 `/`，所以 H5 挂在 **`/h5/`** 下 —— 好处是
 * **页面与 API 同源**（`/api/v1` 相对路径直接可用），**零 CORS、零额外端口、零额外证书**。
 *
 * ## 开发期代理
 * 与 `admin-web` 同款：默认指向**云端**（本机 Docker 未开时也能直接开发，见 `admin-web/vite.config.ts` 的说明）。
 * 想连本地就设 `VITE_PROXY_TARGET=http://127.0.0.1:3100` 再起 dev。
 */
const PROXY_TARGET = process.env.VITE_PROXY_TARGET || 'http://YOUR_SERVER_HOST:3100';

export default defineConfig({
  base: '/h5/',
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5174,
    host: true,
    proxy: {
      '/api': { target: PROXY_TARGET, changeOrigin: true },
      '/media': { target: PROXY_TARGET, changeOrigin: true },
    },
  },
  build: {
    outDir: 'dist',
    // 移动端首屏优先：把 Vant 与业务代码分开，Vant 那坨可长期缓存
    rollupOptions: {
      output: {
        manualChunks: {
          vant: ['vant'],
          vue: ['vue', 'vue-router', 'pinia'],
        },
      },
    },
    chunkSizeWarningLimit: 900,
  },
});
