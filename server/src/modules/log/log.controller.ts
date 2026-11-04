import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';

/** mysql2 原始结果为 [rows, fields] 双元素结构，统一解出 rows */
function unwrapRows(raw: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(raw) && raw.length >= 1 && Array.isArray(raw[0])) {
    return raw[0] as Array<Record<string, unknown>>;
  }
  return raw as Array<Record<string, unknown>>;
}

/** 日志与安全审计（docs/09）：登录日志 + 操作日志查询（admin:log:read / admin:audit:read） */
@ApiTags('admin/logs')
@Controller('admin/logs')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class LogController {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  @Get('logins')
  @RequirePermission('admin:log:read')
  @ApiOperation({ summary: '权限点 admin:log:read：登录日志（含失败原因/触发限流审计）' })
  async logins(@Query('page') page?: string, @Query('pageSize') pageSize?: string, @Query('failOnly') failOnly?: string) {
    const p = parsePage(page);
    const size = parsePageSize(pageSize, 20, 100);
    const where = failOnly === '1' ? "WHERE l.result = 'fail'" : '';
    const rows = unwrapRows(await this.dataSource.query(
      `SELECT l.id, l.user_type, l.user_id, l.username, l.ip, l.user_agent, l.result, l.fail_reason, l.created_at
       FROM login_log l ${where} ORDER BY l.id DESC LIMIT ? OFFSET ?`,
      [size, (p - 1) * size],
    ));
    const cntRows = unwrapRows(await this.dataSource.query(`SELECT COUNT(*) AS cnt FROM login_log l ${where}`));
    return { list: rows, total: Number(cntRows[0]?.cnt ?? 0), page: p, pageSize: size };
  }

  @Get('operations')
  @RequirePermission('admin:audit:read')
  @ApiOperation({ summary: '权限点 admin:audit:read：操作日志（安全审计：高危操作/失败记录）' })
  async operations(@Query('page') page?: string, @Query('pageSize') pageSize?: string, @Query('module') module?: string) {
    const p = parsePage(page);
    const size = parsePageSize(pageSize, 20, 100);
    const where = module ? 'WHERE o.module = ?' : '';
    const params: unknown[] = module ? [module, size, (p - 1) * size] : [size, (p - 1) * size];
    const rows = unwrapRows(await this.dataSource.query(
      `SELECT o.id, o.admin_name, o.module, o.action, o.method, o.path, o.request_body, o.ip, o.result, o.error_msg, o.request_id, o.created_at
       FROM operation_log o ${where} ORDER BY o.id DESC LIMIT ? OFFSET ?`,
      params,
    ));
    const cntRows = unwrapRows(await this.dataSource.query(`SELECT COUNT(*) AS cnt FROM operation_log o ${where}`, module ? [module] : []));
    return { list: rows, total: Number(cntRows[0]?.cnt ?? 0), page: p, pageSize: size };
  }
}
