import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { GrantDto, RecoverDto, TxnPageQueryDto, WalletPageQueryDto } from './dto/wallet.dto';
import { WalletService } from './wallet.service';

/** 管理端余额接口（docs/06）：发放/回收默认仅超管（admin:wallet:grant），全部操作留痕 */
@ApiTags('admin/wallets')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class WalletAdminController {
  constructor(
    private readonly service: WalletService,
    private readonly opLog: OperationLogService,
  ) {}

  @Post('wallets/grant')
  @RequirePermission('admin:wallet:grant')
  @ApiOperation({ summary: '权限点 admin:wallet:grant（默认仅超管）：发放余额（事务+行锁+幂等+流水）' })
  async grant(@Body() dto: GrantDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.grant(user.userId, dto, { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'wallet',
      action: 'wallet:grant',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ userId: dto.userId, amount: dto.amount, duplicated: (result as { duplicated?: boolean }).duplicated === true }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Post('wallets/recover')
  @RequirePermission('admin:wallet:grant')
  @ApiOperation({ summary: '权限点 admin:wallet:grant（默认仅超管）：回收余额（余额不足 400，禁负余额）' })
  async recover(@Body() dto: RecoverDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.recover(user.userId, dto, { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'wallet',
      action: 'wallet:recover',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ userId: dto.userId, amount: dto.amount }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Get('wallets')
  @RequirePermission('admin:wallet:read')
  @ApiOperation({ summary: '权限点 admin:wallet:read：钱包列表（分页+搜索）' })
  list(@Query() q: WalletPageQueryDto) {
    return this.service.adminList(q.page ?? 1, q.pageSize ?? 20, q.keyword ?? '');
  }

  @Get('wallet-transactions')
  @RequirePermission('admin:wallet:read')
  @ApiOperation({ summary: '权限点 admin:wallet:read：余额流水（分页+过滤）' })
  transactions(@Query() q: TxnPageQueryDto) {
    return this.service.adminTransactions(q.page ?? 1, q.pageSize ?? 20, q.userId, q.changeType);
  }
}
