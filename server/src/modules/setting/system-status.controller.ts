import { Controller, Get, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import * as os from 'os';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';

/**
 * 后台系统状态面板（docs/待确认事项 #52/53）：CPU/内存/磁盘/运行时长。
 * 仅管理员可读（admin:setting:read），不暴露进程细节（禁泄露路径/环境变量）。
 */
@ApiTags('admin/system')
@Controller('admin/system')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class SystemStatusController {
  @Get('status')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：系统运行状态（CPU/内存/磁盘）' })
  status() {
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    const cpus = os.cpus();
    const load = cpus.map((c) => {
      const t = c.times;
      const total = t.user + t.nice + t.sys + t.idle + t.irq;
      return total > 0 ? Math.round(((total - t.idle) / total) * 1000) / 10 : 0;
    });
    return {
      platform: `${os.type()} ${os.release()}`,
      hostname: os.hostname(),
      uptimeSec: Math.round(process.uptime()),
      cpuCount: cpus.length,
      cpuLoadPercent: Math.round((load.reduce((a, b) => a + b, 0) / cpus.length) * 10) / 10,
      cpuLoadDetail: load,
      memTotalMB: Math.round(totalMem / 1048576),
      memUsedMB: Math.round((totalMem - freeMem) / 1048576),
      memUsagePercent: Math.round(((totalMem - freeMem) / totalMem) * 1000) / 10,
      nodeVersion: process.version,
    };
  }
}
