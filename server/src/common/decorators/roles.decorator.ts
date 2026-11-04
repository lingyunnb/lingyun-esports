import { SetMetadata } from '@nestjs/common';

export const ROLES_KEY = 'roles';

/** 接口要求的角色（docs/04）：如 @Roles('user')、@Roles('worker')、@Roles('admin') */
export const Roles = (...roles: string[]) => SetMetadata(ROLES_KEY, roles);
