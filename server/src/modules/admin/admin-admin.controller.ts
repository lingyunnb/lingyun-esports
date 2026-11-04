import { Body, Controller, Delete, Get, Param, Post, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { OwnerOnly } from '../../common/decorators/owner-only.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { AdminAdminService } from './admin-admin.service';

/** 管理员与角色管理（docs/04）：创建/编辑管理员、角色与权限分配；全部操作留痕 */
@ApiTags('admin/admins')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class AdminAdminController {
  constructor(
    private readonly service: AdminAdminService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('admins')
  @RequirePermission('admin:admin:read')
  @ApiOperation({ summary: '权限点 admin:admin:read：管理员列表' })
  list() {
    return this.service.listAdmins();
  }

  @Post('admins')
  @RequirePermission('admin:admin:write')
  @ApiOperation({ summary: '权限点 admin:admin:write：创建管理员（账号+角色）' })
  async create(
    @Body() dto: { username: string; password: string; nickname?: string; roleCode: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.createAdmin(user.userId, dto);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:create',
      method: req.method, path: req.path,
      requestBody: JSON.stringify({ username: dto.username, roleCode: dto.roleCode }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Put('admins/:id')
  @RequirePermission('admin:admin:write')
  @ApiOperation({ summary: '权限点 admin:admin:write：编辑管理员（昵称/状态/角色，含防自锁保护）' })
  async update(
    @Param('id') id: string,
    @Body() dto: { nickname?: string; status?: number; roleCode?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateAdmin(user.userId, id, dto);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:update',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id, ...dto }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Post('admins/:id/ban')
  @OwnerOnly()
  @ApiOperation({ summary: '所有者独占：封禁管理员账号（禁用 + 立即吊销全部会话；不能封自己/最后一个超管）' })
  async ban(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.banAdmin(user.userId, id);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:ban',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id, username: result.username }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Post('admins/:id/unban')
  @OwnerOnly()
  @ApiOperation({ summary: '所有者独占：解封管理员账号' })
  async unban(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.unbanAdmin(id);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:unban',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Delete('admins/:id')
  @OwnerOnly()
  @ApiOperation({ summary: '所有者独占：注销管理员账号（防自锁：不能删自己/最后一个超管）' })
  async remove(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteAdmin(user.userId, id);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:delete',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id, username: result.username }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Post('admins/:id/reset-password')
  @RequirePermission('admin:admin:write')
  @ApiOperation({ summary: '权限点 admin:admin:write：重置管理员密码（吊销其全部会话）' })
  async resetPassword(@Param('id') id: string, @Body() dto: { password: string }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.resetPassword(id, dto.password);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'admin:reset-password',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  // ---------------- 角色与权限点 ----------------

  @Get('roles')
  @RequirePermission('admin:admin:read')
  @ApiOperation({ summary: '权限点 admin:admin:read：角色列表（含权限点）' })
  listRoles() {
    return this.service.listRoles();
  }

  @Get('permissions')
  @RequirePermission('admin:admin:read')
  @ApiOperation({ summary: '权限点 admin:admin:read：全部权限点（UI 分配用）' })
  listPermissions() {
    return this.service.listPermissions();
  }

  @Post('roles')
  @RequirePermission('admin:role:write')
  @ApiOperation({ summary: '权限点 admin:role:write：创建角色（含权限点分配）' })
  async createRole(@Body() dto: { code: string; name: string; permissions: string[] }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.createRole(user.userId, dto);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'role:create',
      method: req.method, path: req.path, requestBody: JSON.stringify({ code: dto.code, name: dto.name, permissions: dto.permissions }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }

  @Put('roles/:id')
  @RequirePermission('admin:role:write')
  @ApiOperation({ summary: '权限点 admin:role:write：更新角色（名称/权限点；内置角色不可改）' })
  async updateRole(@Param('id') id: string, @Body() dto: { name?: string; permissions?: string[] }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.updateRole(user.userId, id, dto);
    this.opLog.log({
      adminUserId: user.userId, adminName: '', module: 'admin', action: 'role:update',
      method: req.method, path: req.path, requestBody: JSON.stringify({ id, ...dto }),
      ip: req.ip, requestId: req.requestId,
    });
    return result;
  }
}
