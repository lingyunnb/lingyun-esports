import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { TipService } from './tip.service';

/** 工作端打赏收益（负责人：打手端「我的收益」能看到打赏明细，流水 type=order_tip_income） */
@ApiTags('worker/tips')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class TipWorkerController {
  constructor(private readonly service: TipService) {}

  @Get('tips')
  @ApiOperation({ summary: '我收到的打赏明细（分页）' })
  received(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.receivedTips(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Get('tips/summary')
  @ApiOperation({ summary: '打赏收益聚合（笔数 + 总额）' })
  summary(@CurrentUser() user: { userId: string }) {
    return this.service.receivedSummary(user.userId);
  }
}
