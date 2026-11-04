import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsInt, IsNumber, IsOptional, IsString, Length, Matches, Max, Min } from 'class-validator';

/** 发放/回收公共字段（docs/06：金额服务端校验，幂等键必填） */
export class GrantDto {
  @ApiProperty({ description: '目标用户 ID（服务端校验存在且为 user 角色，客户端不可信）' })
  @IsString()
  @Matches(/^\d+$/, { message: '用户 ID 非法' })
  userId: string;

  /**
   * 金额（元）。
   *
   * ⚠️ 2026-10-13 修正：此前是 `@IsInt()` —— 与它自己的 `@ApiProperty` 描述
   * （「金额（元，**最多 2 位小数**，1 ~ 10000000）」）**直接矛盾**，导致
   * **管理员无法按实际收款金额发放**：老板微信付 ¥28.88，只能发 28 或 29。
   *
   * 为什么是"与契约矛盾"而不是"设计如此"：
   *  - 2026-10-09 计价单位已由「积分」改为「元」（1 元 = 1 元），商品价一律含小数（9.9 / 28.88 / 36.6）；
   *  - 同一职能的另一条路径（充值审核发放）走 `WalletService.grantInTx`，**本来就支持 2 位小数**
   *    （`recharge_request.points` 是 decimal(12,2)）—— 两条入口口径必须一致；
   *  - 钱包与流水列本身就是 `decimal(12,2)`，下游对小数无任何阻碍。
   *
   * 故改为 `@IsNumber({ maxDecimalPlaces: 2 })`：**只放宽到契约已经承诺的精度**，
   * 下界 `@Min(1)` 与上界 `@Max(10000000)` 一字未动（与充值配置 `minYuan=1` 一致）。
   */
  @ApiProperty({ description: '金额（元，最多 2 位小数，1 ~ 10000000）' })
  @IsNumber({ maxDecimalPlaces: 2 }, { message: '最多 2 位小数' })
  @Min(1)
  @Max(10_000_000)
  amount: number;

  @ApiPropertyOptional({ description: '原因说明' })
  @IsOptional()
  @IsString()
  @Length(1, 100)
  reason?: string;

  @ApiProperty({ description: '幂等键（UUID，重试复用；同键只生效一次，docs/06）' })
  @IsString()
  @Length(8, 64)
  idempotencyKey: string;
}

export class RecoverDto extends GrantDto {}

export class WalletPageQueryDto {
  @ApiPropertyOptional({ default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(50)
  pageSize?: number;

  @ApiPropertyOptional({ description: '搜索：账号/ID/昵称' })
  @IsOptional()
  @IsString()
  @Length(0, 32)
  keyword?: string;
}

export class TxnPageQueryDto {
  @ApiPropertyOptional({ default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(50)
  pageSize?: number;

  @ApiPropertyOptional({ description: '按用户过滤（用户 ID）' })
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  userId?: string;

  @ApiPropertyOptional({ description: '按类型过滤：grant/recover/order_pay/order_refund' })
  @IsOptional()
  @IsIn(['grant', 'recover', 'order_pay', 'order_refund'])
  changeType?: string;
}
