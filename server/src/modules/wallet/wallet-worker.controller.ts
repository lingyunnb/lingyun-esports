import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WalletService } from './wallet.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 工作端余额/收益（负责人需求 #6 + 2026-09-25 完整余额入口）：余额 + 累计获得/消费 + 流水明细
 *  （流水聚合全部来自服务端 wallet_transaction，非客户端自报） */
@ApiTags('worker/wallet')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class WalletWorkerController {
  constructor(private readonly service: WalletService) {}

  @Get('my-wallet')
  @ApiOperation({ summary: '我的余额（余额/累计获得/累计消费/结算次数）' })
  myWallet(@CurrentUser() user: { userId: string }) {
    return this.service.workerWallet(user.userId);
  }

  @Get('wallet/transactions')
  @ApiOperation({ summary: '我的余额流水（分页：订单结算/管理员发放等）' })
  transactions(
    @CurrentUser() user: { userId: string },
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.userTransactions(user.userId, parsePage(page), parsePageSize(pageSize));
  }
}
