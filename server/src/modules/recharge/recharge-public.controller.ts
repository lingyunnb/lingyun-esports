import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';

import { RechargeService } from './recharge.service';

/**
 * 充值**公开**配置（老板端「充值」页首屏）。
 *
 * `GET /public/recharge/config` → 金额档位 / 自定义开关与上下限 / 1 元 = 多少余额 /
 * 每人待审上限 / 说明文案 / 启用中的收款码（含图片 url）。
 *
 * ## 合规边界（负责人定案，逐条可验证）
 *
 * 这个接口**只下发"展示什么、换算多少、能提交几笔"**，不下发也不存在任何支付能力：
 * 没有支付通道号、没有下单接口、没有回调地址、没有"支付成功"状态。
 * 收款码就是一个图片地址；老板扫的是自己微信/支付宝里的收款码，**平台不经手资金**。
 *
 * ## 缓存
 *
 * 已登记进 `PublicCacheInterceptor`（进程内 30s 微缓存 + `Cache-Control` 60s 档，与
 * `/public/purchase-hint` 同档：内容随**运营**变化，不是"半年不动"的字典数据）。
 * **所有写路径都带失效钩子**（`RechargeService.invalidatePublicConfigCache()`，
 * 收款码增删改 + 配置保存四处全调）→ 运营改完**下一次请求即生效**。
 */
@ApiTags('public')
@Controller('public/recharge')
export class RechargePublicController {
  constructor(private readonly service: RechargeService) {}

  @Get('config')
  @ApiOperation({
    summary: '公开：充值配置（金额档位/换算比例/自定义区间/待审上限/说明文案/启用中的收款码）',
  })
  config() {
    return this.service.publicConfig();
  }
}
