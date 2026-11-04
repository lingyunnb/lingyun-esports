import { Body, Controller, Delete, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { FriendService } from './friend.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 好友系统（负责人需求 #16）+ 系统通知（#24）：全部经后端处理，主体 id 只取 JWT */
@ApiTags('user/friends')
@Controller('user')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class FriendController {
  constructor(private readonly service: FriendService) {}

  @Get('friends')
  @ApiOperation({ summary: '我的好友列表（含资料）' })
  list(@CurrentUser() user: { userId: string }) {
    return this.service.list(user.userId);
  }

  @Get('friends/search')
  @ApiOperation({ summary: '搜索用户（按展示 ID 精确/昵称模糊，中文 ID 与昵称均可）' })
  search(@CurrentUser() user: { userId: string }, @Query('uid') kw: string) {
    return this.service.search(user.userId, kw ?? '');
  }

  @Get('friends/requests/incoming')
  @ApiOperation({ summary: '我收到的待处理好友申请' })
  incoming(@CurrentUser() user: { userId: string }) {
    return this.service.incoming(user.userId);
  }

  @Get('friends/requests/outgoing')
  @ApiOperation({ summary: '我发出的待处理好友申请' })
  outgoing(@CurrentUser() user: { userId: string }) {
    return this.service.outgoing(user.userId);
  }

  @Post('friends/requests')
  @ApiOperation({ summary: '申请添加好友（按展示 ID）' })
  request(@CurrentUser() user: { userId: string }, @Body() dto: { uid: string; message?: string }) {
    return this.service.request(user.userId, dto.uid ?? '', dto.message ?? '');
  }

  @Post('friends/requests/:id/accept')
  @ApiOperation({ summary: '同意好友申请' })
  accept(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.accept(user.userId, id);
  }

  @Post('friends/requests/:id/reject')
  @ApiOperation({ summary: '拒绝好友申请' })
  reject(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.reject(user.userId, id);
  }

  @Delete('friends/:userId')
  @ApiOperation({ summary: '删除好友' })
  remove(@CurrentUser() user: { userId: string }, @Param('userId') friendUserId: string) {
    return this.service.remove(user.userId, friendUserId);
  }

  @Post('friends/:userId/conversation')
  @ApiOperation({ summary: '打开与好友的会话（返回共享会话 id）' })
  conversation(@CurrentUser() user: { userId: string }, @Param('userId') friendUserId: string) {
    return this.service.openConversation(user.userId, friendUserId);
  }

  @Get('notifications')
  @ApiOperation({ summary: '系统通知（分页 + 未读数）' })
  notifications(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.notifications(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Post('notifications/read')
  @ApiOperation({ summary: '标记通知已读（空 body 全部已读）' })
  read(@CurrentUser() user: { userId: string }, @Body() dto: { ids?: string[] }) {
    return this.service.markNotificationsRead(user.userId, dto.ids);
  }
}
