import { Body, Controller, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { ProfileService } from './profile.service';

/** 个人资料（负责人需求 #17/#18/#19）：修改资料/改 ID/公开资料页（主体 id 只取 JWT） */
@ApiTags('user/profile')
@Controller('user')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class ProfileController {
  constructor(private readonly service: ProfileService) {}

  @Put('profile')
  @ApiOperation({ summary: '修改个人资料（昵称/头像/背景；媒体须为本人上传且类型匹配）' })
  update(@CurrentUser() user: { userId: string }, @Body() dto: { nickname?: string; avatarMediaId?: string | null; backgroundMediaId?: string | null }) {
    return this.service.updateProfile(user.userId, dto);
  }

  @Post('profile/uid')
  @ApiOperation({ summary: '修改展示 ID（中文/字母/数字/下划线；唯一；24h 限 3 次）' })
  changeUid(@CurrentUser() user: { userId: string }, @Body() dto: { uid: string }) {
    return this.service.changeUid(user.userId, dto.uid ?? '');
  }

  @Get('profile/:uid')
  @ApiOperation({ summary: '公开资料页（按展示 ID 查看其他用户资料）' })
  publicProfile(@Param('uid') uid: string) {
    return this.service.publicProfileByUid(uid);
  }
}
