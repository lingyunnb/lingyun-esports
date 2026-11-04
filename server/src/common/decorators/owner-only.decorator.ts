import { SetMetadata } from '@nestjs/common';

export const OWNER_KEY = 'owner_only';

/**
 * 所有者独占操作（负责人需求 2026-09-23）：
 * 只有 admin.is_owner = 1 的账号可执行（当前为 kslingyun）。
 * 用于「封禁/注销其他管理端账号」这类最高敏感操作 ——
 * super_admin 会跳过权限点校验，故不能用普通权限点实现独占。
 */
export const OwnerOnly = () => SetMetadata(OWNER_KEY, true);
