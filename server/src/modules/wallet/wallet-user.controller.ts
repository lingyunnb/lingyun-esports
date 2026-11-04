import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WalletService } from './wallet.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 用户端余额只读接口（docs/06）：只查自己的钱包与流水，永不存在增加余额的入口 */
@ApiTags('user/wallet')
@Controller('user/wallet')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class WalletUserController {
  constructor(private readonly service: WalletService) {}

  @Get()
  @ApiOperation({ summary: '我的余额（主体 id 取自 JWT）' })
  balance(@CurrentUser() user: { userId: string }) {
    return this.service.userBalance(user.userId);
  }

  @Get('transactions')
  @ApiOperation({ summary: '我的余额流水（分页）' })
  transactions(
    @CurrentUser() user: { userId: string },
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.userTransactions(user.userId, parsePage(page), parsePageSize(pageSize));
  }
}
