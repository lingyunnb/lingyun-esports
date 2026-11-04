import { Type } from 'class-transformer';
import { IsNotEmpty, IsNumber, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';

/**
 * 提交充值申请（`POST /user/recharge/requests`）。
 *
 * 校验分两层，刻意不重叠：
 * - **DTO 层**（本文件，由全局 `LenientValidationPipe` 执行）：只拦"形状级"的非法
 *   （不是数字、空字符串、超长文本）→ 中文 400 + `fields[]`，客户端能把提示落到输入框下方；
 * - **服务层**（`RechargeService.createRequest`）：拦"业务级"的非法
 *   （不在档位/不在区间、换算后到账金额为 0、凭证不属于本人、超出待审上限）→ 中文 400。
 *
 * 为什么金额不在 DTO 层做上下限：档位与区间**是可配置的**（管理端随时改），
 * DTO 里的静态装饰器无法感知；把可配置规则写进静态校验 = 两处真相，必然分叉。
 * DTO 这里只保证"它是个正数"，具体区间交给服务层读实时配置判定。
 */
export class CreateRechargeRequestDto {
  /** 申请金额（元）。正数；最多 2 位小数由服务层判定（DECIMAL(10,2) 精度） */
  @Type(() => Number)
  @IsNumber({}, { message: '充值金额必须是数字' })
  @Min(0.01, { message: '充值金额必须大于 0' })
  @Max(1_000_000, { message: '充值金额超出允许范围' })
  amountYuan: number;

  /** 老板扫的那张收款码 id（可空：先付款后回来补单的场景） */
  @IsOptional()
  @IsString({ message: '收款码 id 必须是字符串' })
  qrId?: string;

  /**
   * 转账截图 media id（**必填**；服务层再校验"必须是本人上传的图片"）。
   * 只用 `@IsNotEmpty`：再叠一个 `@IsString` 会让"没传"时同时触发两条消息，
   * 客户端的字段级提示框里会拼成两句（"请上传转账截图；…必须是字符串"）。
   */
  @IsNotEmpty({ message: '请上传转账截图' })
  proofMediaId: string;

  /** 备注（如微信昵称，便于人工核对） */
  @IsOptional()
  @IsString({ message: '备注必须是字符串' })
  @MaxLength(200, { message: '备注最多 200 字' })
  note?: string;
}
