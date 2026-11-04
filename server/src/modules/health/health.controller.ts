import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { HealthService } from './health.service';

@ApiTags('health')
@Controller('health')
export class HealthController {
  constructor(private readonly healthService: HealthService) {}

  /** 公开：存活与依赖检查（数据库/Redis），供 status.ps1 与客户端判断服务可用性 */
  @Get()
  @ApiOperation({ summary: '公开：服务健康检查（数据库/Redis）' })
  check() {
    return this.healthService.check();
  }
}
