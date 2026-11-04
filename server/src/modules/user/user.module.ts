import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { redisProvider } from '../../common/redis.provider';
import { BindingReleaseModule } from '../auth/binding-release.module';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Media } from '../media/media.entity';
import { ProfileController } from './profile.controller';
import { ProfileService } from './profile.service';
import { User } from './user.entity';
import { UserAdminController } from './user-admin.controller';
import { UserAdminService } from './user-admin.service';

/** 用户模块：个人资料（昵称/头像/背景/中文ID/公开资料页）+ 管理端用户管理（列表/封禁/解封/删除） */
@Module({
  imports: [
    TypeOrmModule.forFeature([User, Media, OperationLog]),
    // 封禁/删除即释放绑定（含 companion 令牌吊销 + identity 审计 + 断开 WS，F1-b/F4）
    BindingReleaseModule,
  ],
  controllers: [ProfileController, UserAdminController],
  providers: [ProfileService, UserAdminService, OperationLogService, redisProvider],
  exports: [ProfileService],
})
export class UserModule {}
