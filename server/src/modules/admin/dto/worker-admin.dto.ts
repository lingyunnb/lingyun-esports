import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  Length,
  Matches,
  Max,
  Min,
} from 'class-validator';

export class CreateWorkerDto {
  @ApiProperty({ description: '登录账号：3-32 位字母数字下划线' })
  @IsString()
  @Length(3, 32)
  @Matches(/^[a-zA-Z0-9_]+$/)
  username: string;

  @ApiProperty({ description: '初始密码：8-64 位' })
  @IsString()
  @Length(8, 64)
  password: string;

  @ApiProperty({ description: '工号，唯一' })
  @IsString()
  @Length(2, 20)
  workerNo: string;

  @ApiPropertyOptional({ description: '昵称（默认同账号）' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  nickname?: string;

  @ApiPropertyOptional({ description: '真实姓名' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  realName?: string;

  @ApiPropertyOptional({ description: '联系电话' })
  @IsOptional()
  @IsString()
  @Length(5, 20)
  phone?: string;
}

export class UpdateWorkerDto {
  @ApiPropertyOptional({ description: '真实姓名' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  realName?: string;

  @ApiPropertyOptional({ description: '联系电话' })
  @IsOptional()
  @IsString()
  @Length(5, 20)
  phone?: string;

  @ApiPropertyOptional({ description: '状态：1 在职 / 2 停用' })
  @IsOptional()
  @IsIn([1, 2])
  status?: number;
}

export class UpdateWorkerPermissionDto {
  @ApiProperty({ description: 'take_order 接单权限 / customer 客服权限（两个权限完全独立，docs/04）' })
  @IsIn(['take_order', 'customer'])
  type: 'take_order' | 'customer';

  @ApiProperty({ description: '授予 true / 取消 false' })
  @IsBoolean()
  value: boolean;

  /**
   * 分部接单权限（负责人 2026-10-04）：接单权限从「全局开关」下沉到「打手 × 分部」。
   *
   * 三种调用形态（都只影响 take_order，客服权限不区分分部）：
   * 1. `{ type:'take_order', value, divisionId }` —— 只授予/撤销**该分部**（管理端三个分部开关各自调用）
   * 2. `{ type:'take_order', value, divisionIds:[…] }` —— 按勾选集合整体替换（列出的授予、未列出的撤销）
   * 3. `{ type:'take_order', value }` —— 旧的全局语义：授予=当前全部启用分部，撤销=全部撤销
   */
  @ApiPropertyOptional({ description: '（仅 take_order）目标分部 id：只授予/撤销该分部的接单权限' })
  @IsOptional()
  @IsString()
  divisionId?: string;

  @ApiPropertyOptional({ description: '（仅 take_order）按分部勾选的完整集合：列出的授予、未列出的撤销' })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  divisionIds?: string[];
}

export class PageQueryDto {
  @ApiPropertyOptional({ description: '页码', default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ description: '每页数量', default: 20 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(100)
  pageSize?: number;

  @ApiPropertyOptional({ description: '搜索：账号/昵称/工号' })
  @IsOptional()
  @IsString()
  @Length(0, 32)
  keyword?: string;
}

/**
 * 展示值调整（负责人 2026-10-16：「上去的打手只能管理端调接单次数和好评率」）
 *
 * 口径：**数字可调、评价必须真实**
 * - 可调：`completedOrders`（接单次数）、`satisfiedRate`（好评率）；
 * - 不可调：`reviewCount`（评价条数）与评价列表本身 —— 本 DTO 里**没有**这两个字段，
 *   多传会被全局白名单校验直接 400（`whitelist + forbidNonWhitelisted`）。
 *
 * **`null` / 省略 = 恢复「跟随真实」**：请求体是**整体覆盖**，不是局部合并
 * （只传 `completedOrders` 等于同时清空 `satisfiedRate`；两个字段都省略 = 两列都清空）。
 * 这样做是为了让"清空"有一个**唯一且可表达**的写法（`null`），
 * 而不是"字段缺失就保持原值"那种需要额外 GET 才能推断结果的隐式语义。
 *
 * ⚠️ `satisfiedRate` 是**百分数**（`98.2` = 98.2%），**不是 0–1 比率** ——
 * 本项目踩过坑（曾把 `1.0` 渲染成 `100%`），接口两端一律以百分数对话。
 *
 * 宽松处理：JSON 数字与数字字符串都收（`98.2` / `"98.2"` 等价），空串按"清空"处理 ——
 * 管理端表单清空输入框后常见的提交形态是 `""`，把它当 400 只会让运营反复试错。
 */
export class WorkerDisplayStatsDto {
  @ApiPropertyOptional({
    description: '接单次数展示值（0-999999 整数）；null / 省略 = 跟随真实值',
    nullable: true,
    example: 1234,
  })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsInt({ message: '接单次数展示值需为 0-999999 的整数（null = 跟随真实）' })
  @Min(0, { message: '接单次数展示值不能小于 0（0 表示对外显示 0 单；清空请传 null）' })
  @Max(999999, { message: '接单次数展示值不能大于 999999' })
  completedOrders?: number | null;

  @ApiPropertyOptional({
    description: '好评率展示值（百分数 0.0-100.0，最多 1 位小数，如 98.2）；null / 省略 = 跟随真实值',
    nullable: true,
    example: 98.2,
  })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 1 }, { message: '好评率展示值最多保留 1 位小数（如 98.2）' })
  @Min(0, { message: '好评率展示值不能小于 0' })
  @Max(100, { message: '好评率展示值是百分数，不能大于 100（100 = 100%）' })
  satisfiedRate?: number | null;
}

/**
 * 展示值的取值归一（`@Transform`，`transform: true` 下生效）
 *
 * `null` / `undefined` / 空串 / 纯空白 → `null`（= 恢复跟随真实）；数字字符串 → 数字；
 * 其它原样交给 class-validator 去拒绝（**不在这里静默兜底**：非法值必须 400，
 * 否则"设了但没生效"会变成最难查的一类报障）。
 */
function toNumberOrNull({ value }: { value: unknown }): unknown {
  if (value === null || value === undefined) return null;
  if (typeof value === 'string') {
    const t = value.trim();
    if (!t) return null;
    const n = Number(t);
    return Number.isFinite(n) ? n : value;
  }
  return value;
}

