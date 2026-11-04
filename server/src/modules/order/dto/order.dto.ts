import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsInt, IsOptional, IsString, Length, Matches, Max, Min , MaxLength } from 'class-validator';

export class CreateOrderDto {
  @ApiProperty({ description: '商品 ID（价格由服务端查库，客户端不可传 price）' })
  @IsString()
  @Matches(/^\d+$/)
  productId: string;

  @ApiPropertyOptional({ description: '数量（1-99）', default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(99)
  quantity?: number;

  @ApiPropertyOptional({ description: '下单备注' })
  @IsOptional()
  @IsString()
  @Length(0, 500)
  remark?: string;

  @ApiProperty({ description: '游戏分区（QQ区/微信区），下单必填；打手抢单后才可见', enum: ['qq', 'wechat'] })
  @IsString()
  @IsIn(['qq', 'wechat'])
  gameZone: string;

  @ApiProperty({ description: '老板游戏 ID，下单必填；打手抢单后才可见' })
  @IsString()
  @Length(1, 64)
  @Matches(/^[A-Za-z0-9一-龥_-]+$/, { message: '游戏ID仅支持字母/数字/中文/下划线/短横线' })
  gamePlayerId: string;

  @ApiProperty({ description: '幂等键（UUID，重试复用，防重复下单）' })
  @IsString()
  @Length(8, 64)
  idempotencyKey: string;

  @ApiPropertyOptional({ description: '联系方式（选填，下单页可配置）' })
  @IsOptional()
  @IsString()
  @MaxLength(20)
  contactPhone?: string;

  @ApiPropertyOptional({ description: '护航员选择：random 随机安排（默认）/ designated 指定护航员' })
  @IsOptional()
  @IsIn(['random', 'designated'])
  workerMode?: string;

  @ApiPropertyOptional({ description: '指定护航员 worker.id（workerMode=designated 时必填）' })
  @IsOptional()
  @IsString()
  designatedWorkerId?: string;

}

export class ConfirmOrderDto {}

export class CancelOrderDto {
  @ApiPropertyOptional({ description: '取消原因' })
  @IsOptional()
  @IsString()
  @Length(0, 200)
  reason?: string;
}

export class AdminCancelOrderDto extends CancelOrderDto {}

export class OrderPageQueryDto {
  @ApiPropertyOptional({ description: '状态过滤' })
  @IsOptional()
  @IsIn(['pending_take', 'taken', 'in_progress', 'pending_confirm', 'completed', 'canceled', 'abnormal', 'after_sale'])
  status?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 32)
  keyword?: string;

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
}

export class SettlementQueryDto {
  @ApiPropertyOptional({ description: '按订单号模糊' })
  @IsOptional()
  @IsString()
  @Length(0, 32)
  orderNo?: string;

  @ApiPropertyOptional({ description: '按打手（worker.id）过滤' })
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  workerId?: string;

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
}

export class DispatchOrderDto {
  @ApiProperty({ description: '目标工作端档案 id（worker.id）' })
  @IsString()
  @Matches(/^\d+$/)
  workerId: string;
}
