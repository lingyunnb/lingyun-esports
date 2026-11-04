import { defineStore } from 'pinia';
import { authApi, setToken, getToken, type Profile } from '@/api';

/**
 * 登录态
 * ============================================================================
 * 令牌存 `localStorage`（与 App 的"持久登录"一致）；`me` 只做展示用缓存，
 * **权限与身份一律以服务端为准**（客户端数据不可信是项目铁律）。
 */
export const useAuthStore = defineStore('auth', {
  state: () => ({
    token: getToken(),
    me: null as Profile | null,
    loading: false,
    ready: false,
  }),

  getters: {
    isLogin: (s) => !!s.token,
    /** 余额（元）—— 服务端下发字符串，这里只做展示格式化 */
    balance: (s) => {
      const raw = (s.me as Record<string, unknown> | null)?.balance;
      if (raw === undefined || raw === null || raw === '') return null;
      return String(raw);
    },
  },

  actions: {
    async login(username: string, password: string) {
      const r = await authApi.login(username, password);
      this.token = r.accessToken;
      setToken(r.accessToken);
      if (r.user) this.me = r.user as Profile;
      await this.fetchMe();
      return r;
    },

    /** 拉取"我是谁"。失败不抛（首屏不该因为一个可选信息卡住） */
    async fetchMe() {
      if (!this.token) {
        this.ready = true;
        return null;
      }
      try {
        this.me = await authApi.me();
      } catch {
        /* 令牌失效由 401 统一处理，这里静默 */
      } finally {
        this.ready = true;
      }
      return this.me;
    },

    logout() {
      // 尽力而为地通知服务端吊销（失败也无所谓，本地已清）
      authApi.logout().catch(() => {});
      this.token = '';
      this.me = null;
      setToken(null);
    },

    /** 被顶掉/过期时由 API 层的 401 回调调用 */
    forceLogout() {
      this.token = '';
      this.me = null;
      setToken(null);
    },
  },
});
