import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { LevelService } from './level.service';

/** 等级公共接口（2026-09-25）：升级阈值由后台配置，前端只读后台数据，禁止前端写死 */
@ApiTags('public')
@Controller('public/levels')
export class LevelPublicController {
  constructor(private readonly service: LevelService) {}

  @Get()
  @ApiOperation({ summary: '会员等级规则（等级名/升级所需累计消费余额），双端展示进度统一从本接口读取' })
  rules() {
    return this.service.getRules();
  }
}
