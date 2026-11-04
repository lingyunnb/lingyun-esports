import { defineStore } from 'pinia';
import { AdminMe, getToken, request, setToken } from '@/api/client';

/** 登录态（docs/04：按权限点渲染菜单，权限以服务端为准） */
export const useAuthStore = defineStore('auth', {
  state: () => ({
    me: null as AdminMe | null,
    loaded: false,
  }),
  getters: {
    loggedIn: (s) => getToken() !== null,
    permissions: (s) => s.me?.admin?.permissions ?? [],
    isSuperAdmin: (s) => s.me?.admin?.roleCode === 'super_admin',
    // 所有者账号：独占「封禁/注销其他管理员」操作（服务端二次校验）
    isOwner: (s) => s.me?.admin?.isOwner === true,
    hasPermission(state): (code: string) => boolean {
      return (code: string) => this.isSuperAdmin || this.permissions.includes(code);
    },
    /**
     * 独占权限点（负责人 2026-10-04 权限收口）：
     * 退款审批 `admin:refund:handle` / 打赏金额配置 `admin:tip:config` 只给「超管 + 所有者」。
     * 与后端 `PermissionsGuard` 的 SUPER_ONLY_PERMISSIONS 白名单一致（前端只做隐藏，服务端才是权威）。
     */
    hasExclusivePermission(): (code: string) => boolean {
      return (code: string) => this.isSuperAdmin || this.isOwner || this.permissions.includes(code);
    },
  },
  actions: {
    async login(username: string, password: string) {
      const data = await request<{ accessToken: string }>('POST', '/auth/login', {
        username,
        password,
        role: 'admin',
      });
      setToken(data.accessToken);
      await this.fetchMe();
    },
    async fetchMe() {
      this.me = await request<AdminMe>('GET', '/auth/me');
      this.loaded = true;
    },
    async logout() {
      try {
        await request('POST', '/auth/logout', {});
      } catch {
        // 服务端失败也继续本地清理
      }
      setToken(null);
      this.me = null;
      this.loaded = false;
    },
  },
});
