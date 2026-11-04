import { Body, Controller, Get, Headers, HttpCode, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { WithdrawService } from './withdraw.service';

/**
 * 打手端「提现」`/worker/withdraw/*`（`role=worker`）。
 *
 * ## 会话口径
 *
 * 打手态是**两种会话**共用的同一族接口（与接单大厅一致）：
 * - **打手 primary 会话**（工作端 App 遗留登录，服务端到期收口前仍可用）；
 * - **companion 会话**（老板端「打手态」，`kind='companion'`）。
 *
 * `JwtAuthGuard` 的 companion 白名单里**已经放行整个 `/worker/*`**（`isCompanionAllowedRoute`
 * 的第一条规则），因此打手态**零改动即可提现** —— 这正是"提现是打手能力"的应有形态。
 *
 * ## 合规（CLAUDE.md「提现走人工打款」）
 *
 * 这里**没有**任何"发起打款/查询通道/回调"接口：只有
 * "绑定收款信息 / 看配置 / 提交申请（立即扣款）/ 看我的记录"。
 * 真正的打款由管理员在微信里人工完成，系统只记账（`paid` 由管理端回填）。
 *
 * 主体 id 只从 JWT `sub` 取，请求体里**没有任何用户标识字段**。
 */
@ApiTags('worker/withdraw')
@Controller('worker/withdraw')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class WithdrawWorkerController {
  constructor(private readonly service: WithdrawService) {}

  /** `GET /worker/withdraw/account` —— 我的收款信息（姓名/手机号**脱敏**，微信号本人可见） */
  @Get('account')
  @ApiOperation({ summary: '我的收款信息（未绑定 → bound:false；姓名/手机号脱敏；qrUrl 走受保护通道）' })
  account(@CurrentUser() user: { userId: string }) {
    return this.service.getAccount(user.userId);
  }

  /**
   * `POST /worker/withdraw/account` —— 绑定 / **换绑**（覆盖同一行，旧值进审计）。
   *
   * `qrMediaId` 必须是**本人上传的** `withdraw_qr` 图片（用途白名单，防拿别人的图/任意受保护媒体）。
   */
  @Post('account')
  @HttpCode(200)
  @ApiOperation({ summary: '绑定/换绑收款信息（qrMediaId 必须为本人上传的 withdraw_qr 图片；换绑旧值写审计）' })
  save(
    @CurrentUser() user: { userId: string },
    @Body() body: { realName?: string; phone?: string; wechatId?: string; qrMediaId?: string },
    @Req() req: Request,
  ) {
    return this.service.saveAccount(user.userId, body ?? {}, {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'worker-app',
    });
  }

  /** `GET /worker/withdraw/config` —— 门槛/次数/费率/说明文案 + 我的余额与今日已用次数 */
  @Get('config')
  @ApiOperation({ summary: '提现页配置（min/max/dailyLimit/feeRate/noticeText + 我的 balance/todayUsed）' })
  config(@CurrentUser() user: { userId: string }) {
    return this.service.workerConfig(user.userId);
  }

  /**
   * `POST /worker/withdraw/requests` —— **申请即扣款**（事务 + 行锁 + 立即扣减 + 写流水 + 建 pending）。
   *
   * 幂等键：请求头 `Idempotency-Key`（或 body.`idempotencyKey`）—— 同一个键重复提交
   * 返回**首次结果**，不重复扣款（客户端网络重试安全）。
   */
  @Post('requests')
  @ApiOperation({
    summary: '提交提现申请（同一事务内校验并立即扣款；未绑定/超门槛/超余额/超次数 → 中文 400；已有在途 → 中文 409）',
  })
  create(
    @CurrentUser() user: { userId: string },
    @Body() body: { amount?: number; idempotencyKey?: string },
    @Headers('idempotency-key') headerKey: string | undefined,
    @Req() req: Request,
  ) {
    return this.service.createRequest(user.userId, body?.amount, headerKey ?? body?.idempotencyKey, {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'worker-app',
    });
  }

  /** `GET /worker/withdraw/requests` —— 我的提现记录（金额/状态/申请时间/打款时间/驳回原因） */
  @Get('requests')
  @ApiOperation({ summary: '我的提现记录（含状态、申请/打款/驳回时间、驳回原因、打款凭证）' })
  mine(
    @CurrentUser() user: { userId: string },
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.myRequests(user.userId, parsePage(page), parsePageSize(pageSize));
  }
}
