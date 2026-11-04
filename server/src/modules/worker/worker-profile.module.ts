import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { User } from '../user/user.entity';
import { Worker } from './worker.entity';
import { WorkerProfileController } from './worker-profile.controller';
import { WorkerProfileService } from './worker-profile.service';

/**
 * 打手简介自写（负责人 2026-10-17：介绍从「管理端填写」改为「打手自己写」，管理端仍可兜底）。
 *
 * 单开一个模块而不是塞进 `WorkerPermissionModule`：那个模块的语义是"分部接单权限"，
 * 且它的 `forFeature` 里没有 `User` 实体（简介写在 `user.intro`，不写在 `worker`）。混装会让
 * "权限模块为什么要依赖 User"变成下一个人的疑问。
 *
 * 校验规则不在这里，也不在服务里内联：`worker-intro.rules.ts` 纯函数（唯一实现，可单测）。
 */
@Module({
  imports: [TypeOrmModule.forFeature([Worker, User])],
  controllers: [WorkerProfileController],
  providers: [WorkerProfileService],
})
export class WorkerProfileModule {}
