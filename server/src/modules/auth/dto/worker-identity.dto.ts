import { ApiProperty } from '@nestjs/swagger';
import { IsOptional, IsString, Length } from 'class-validator';

/**
 * 绑定打手账号（合并双端·身份切换，方案甲）——`POST /user/identity/bind`。
 *
 * 身份只从 JWT `sub` 取（谁是老板），本 DTO 里**只有"绑谁"的定位信息 + 打手账密**，
 * 绝不接受任何用户标识（userId/role 之类）——客户端数据一律不可信（CLAUDE.md 硬约束）。
 *
 * "绑谁"三种定位方式**任选其一**（都是打手账号的公开标识，由老板从打手处获得）：
 * - `username`：登录名（管理端创建打手账号时设定，最常用）；
 * - `uid`：展示 ID（老板端可在资料页看到）；
 * - `workerNo`：工号（管理端/工作端展示的 W0xx，线下沟通最顺手）。
 * 三者都不传 → 400 中文（服务层判定，文案统一为"请填写打手账号（登录名 / 展示 ID / 工号）"）。
 */
export class BindWorkerIdentityDto {
  @ApiProperty({ description: '打手登录名（与 uid / workerNo 三选一）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 32, { message: '须为 1-32 位' })
  username?: string;

  @ApiProperty({ description: '打手展示 ID（与 username / workerNo 三选一）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 20, { message: '须为 1-20 位' })
  uid?: string;

  @ApiProperty({ description: '打手工号（与 username / uid 三选一）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 20, { message: '须为 1-20 位' })
  workerNo?: string;

  @ApiProperty({ description: '打手账号密码（复用既有 bcrypt 校验，不在服务端留存）' })
  @IsString()
  @Length(1, 64, { message: '须为 1-64 位' })
  password: string;
}

/** 解绑（`POST /user/identity/unbind`）：上限>1 时用 bindingId 指定解哪一条 */
export class UnbindWorkerIdentityDto {
  @ApiProperty({ description: '绑定 id（上限为 1 时可省略；多个绑定时必填）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 20, { message: '须为 1-20 位' })
  bindingId?: string;
}

/** 伴随会话续期（`POST /user/identity/refresh`）：只接受 companion 的 refresh token */
export class RefreshCompanionDto {
  @ApiProperty({ description: '伴随会话的 refreshToken（绑定接口下发）' })
  @IsString()
  @Length(1, 512, { message: '长度非法' })
  refreshToken: string;
}
