import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsInt, IsOptional, IsString, Length, Matches, Max, Min } from 'class-validator';

/**
 * 「身份绑定」只读查询 DTO（管理端运营排查用）。
 *
 * 刻意**不继承** `PageQueryDto`：那边 `keyword` 限 32 字、`pageSize` 上限 100，
 * 而本接口要给「用户管理/工作端管理」页做**当前页批量装饰**（一页 20 行 × 上限 10 个绑定），
 * 并接受逗号分隔的多 id 查询，故单独声明（避免悄悄放宽既有接口的约束）。
 *
 * 全部字段都是**读**筛选，没有任何写语义；`pageSize` 上限 200 与 id 白名单正则一起兜住滥用。
 */
export class IdentityBindingQueryDto {
  @ApiPropertyOptional({ description: '页码', default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ description: '每页数量（上限 200，供列表页批量装饰用）', default: 20 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(200)
  pageSize?: number;

  /** all（默认）= 全部；active = 已绑定；unbound = 已解绑（历史行） */
  @ApiPropertyOptional({ description: '状态：all 全部 / active 已绑定 / unbound 已解绑', enum: ['all', 'active', 'unbound'] })
  @IsOptional()
  @IsIn(['all', 'active', 'unbound'])
  status?: 'all' | 'active' | 'unbound';

  @ApiPropertyOptional({ description: '关键词：老板 ID/账号/昵称，或打手工号/账号/昵称' })
  @IsOptional()
  @IsString()
  @Length(0, 32)
  keyword?: string;

  @ApiPropertyOptional({ description: '只看该老板（user.id）的绑定' })
  @IsOptional()
  @Matches(/^\d{1,20}$/)
  bossUserId?: string;

  @ApiPropertyOptional({ description: '只看该打手（user.id）的绑定' })
  @IsOptional()
  @Matches(/^\d{1,20}$/)
  workerUserId?: string;

  /**
   * 批量：老板侧 user.id 逗号分隔（列表页「身份绑定」列的当前页装饰用）。
   * 与 bossUserId 的区别是"一次问一页"，避免 20 行发 20 个请求。
   */
  @ApiPropertyOptional({ description: '批量老板 user.id（逗号分隔，最多 50 个）' })
  @IsOptional()
  @Matches(/^\d{1,20}(,\d{1,20}){0,49}$/)
  bossUserIds?: string;

  @ApiPropertyOptional({ description: '批量打手 user.id（逗号分隔，最多 50 个）' })
  @IsOptional()
  @Matches(/^\d{1,20}(,\d{1,20}){0,49}$/)
  workerUserIds?: string;

  /** 时间范围按 `bound_at`（绑定时间）过滤；接受 ISO 8601 或 'YYYY-MM-DD HH:mm:ss'，非法值 400 中文 */
  @ApiPropertyOptional({ description: '绑定时间起（含）' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  boundFrom?: string;

  @ApiPropertyOptional({ description: '绑定时间止（含）' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  boundTo?: string;
}
