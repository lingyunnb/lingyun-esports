import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { FeedbackService } from './feedback.service';

/** 用户意见反馈（设置页入口） */
@ApiTags('user/feedback')
@Controller('user')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class FeedbackUserController {
  constructor(private readonly service: FeedbackService) {}

  @Post('feedback')
  @ApiOperation({ summary: '提交意见反馈' })
  submit(@CurrentUser() user: { userId: string }, @Body() dto: { content: string; contact?: string }) {
    return this.service.submit(user.userId, dto);
  }
}
