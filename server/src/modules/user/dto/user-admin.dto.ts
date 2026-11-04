import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsOptional } from 'class-validator';
import { PageQueryDto } from '../../admin/dto/worker-admin.dto';

/**
 * 用户管理列表查询 DTO。
 *
 * 注意：**不能用交叉类型** `PageQueryDto & { role?: string }` ——
 * TS 交叉类型在运行时会被擦除为 Object，NestJS 的 ValidationPipe 拿不到
 * DTO 元数据就会整体跳过校验，导致 page/pageSize 的非法值直达 TypeORM
 * （pageSize=-5 / abc / 1e999 实测 500）。必须声明为具体类。
 */
export class UserPageQueryDto extends PageQueryDto {
  @ApiPropertyOptional({ description: '角色过滤：user 老板端 / worker 工作端（缺省=全部）' })
  @IsOptional()
  @IsIn(['user', 'worker'])
  role?: 'user' | 'worker';
}
