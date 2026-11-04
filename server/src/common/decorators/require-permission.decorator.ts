import { SetMetadata } from '@nestjs/common';

export const PERMISSION_KEY = 'permission';

/** 接口要求的管理员权限点（docs/04）：如 @RequirePermission('admin:wallet:grant') */
export const RequirePermission = (code: string) => SetMetadata(PERMISSION_KEY, code);
