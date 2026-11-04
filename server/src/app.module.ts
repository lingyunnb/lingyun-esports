import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { TypeOrmModule } from '@nestjs/typeorm';
import { MailModule } from './common/mail/mail.module';
import { GlobalRateLimitMiddleware } from './common/middleware/global-rate-limit.middleware';
import { RequestIdMiddleware } from './common/middleware/request-id.middleware';
import { validateEnv } from './config/env.validation';
import { AdminModule } from './modules/admin/admin.module';
import { AiModule } from './modules/ai/ai.module';
import { AppUpdateModule } from './modules/app-update/app-update.module';
import { AuthModule } from './modules/auth/auth.module';
import { GameModule } from './modules/game/game.module';
import { ClubModule } from './modules/club/club.module';
import { DivisionModule } from './modules/division/division.module';
import { PlayersModule } from './modules/worker/players.module';
import { WorkerPermissionModule } from './modules/worker/worker-permission.module';
import { WorkerProfileModule } from './modules/worker/worker-profile.module';
import { HealthModule } from './modules/health/health.module';
import { HomeContentModule } from './modules/home/home.module';
import { IdentityBindingModule } from './modules/identity-binding/identity-binding.module';
import { ChatModule } from './modules/chat/chat.module';
import { ComplaintModule } from './modules/complaint/complaint.module';
import { FeedbackModule } from './modules/feedback/feedback.module';
import { FriendModule } from './modules/friend/friend.module';
import { GameAccountModule } from './modules/game-account/game-account.module';
import { LeaderboardModule } from './modules/leaderboard/leaderboard.module';
import { LevelModule } from './modules/level/level.module';
import { LogModule } from './modules/log/log.module';
import { MediaModule } from './modules/media/media.module';
import { SystemSettingModule } from './modules/setting/system-setting.module';
import { RealtimeModule } from './realtime/realtime.module';
import { OrderModule } from './modules/order/order.module';
import { ProductModule } from './modules/product/product.module';
import { RechargeModule } from './modules/recharge/recharge.module';
import { RatingModule } from './modules/rating/rating.module';
import { RefundModule } from './modules/refund/refund.module';
import { ReviewModule } from './modules/review/review.module';
import { TipModule } from './modules/tip/tip.module';
import { UserModule } from './modules/user/user.module';
import { WalletModule } from './modules/wallet/wallet.module';
import { WithdrawModule } from './modules/withdraw/withdraw.module';
import { SiteModule } from './modules/site/site.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnv }),
    // 全局 JWT（守卫跨模块使用；签发时按 access/refresh 显式指定密钥，docs/04）
    JwtModule.register({ global: true }),
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        type: 'mysql',
        host: config.get<string>('DB_HOST'),
        port: config.get<number>('DB_PORT'),
        username: config.get<string>('DB_USER'),
        password: config.get<string>('DB_PASSWORD'),
        database: config.get<string>('DB_NAME'),
        autoLoadEntities: true, // 各模块 forFeature 自动注册实体
        charset: 'utf8mb4',
        timezone: 'Z',
        synchronize: false, // 铁律：一律走 migration（docs/10）
      }),
    }),
    HealthModule,
    AuthModule,
    // 邮件通道（负责人 2026-10-05：邮箱验证替代短信验证；全局提供 MailerService）
    MailModule,
    AdminModule,
    // AI 咨询「祁小山」（负责人 2026-10-04）：老板端底部中间按钮入口
    AiModule,
    AppUpdateModule,
    WalletModule,
    GameModule,
    DivisionModule,
    ClubModule,
    PlayersModule,
    WorkerPermissionModule,
    WorkerProfileModule,
    ProductModule,
    OrderModule,
    HomeContentModule,
    MediaModule,
    SystemSettingModule,
    SiteModule,
    RealtimeModule,
    ChatModule,
    FriendModule,
    FeedbackModule,
    // 顶部导航三入口（负责人 2026-10-04）：打赏（余额）/ 退款申请 / 投诉工单
    TipModule,
    RefundModule,
    ComplaintModule,
    UserModule,
    // 身份绑定（老板 ↔ 打手，负责人 2026-10-06 方案甲）：管理端**只读**查询接口（运营排查）
    IdentityBindingModule,
    // 充值（线下收款 + 人工审核，负责人 2026-10-06）：老板端提交申请 + 受限管理态审核 + 管理端配置。
    // **合规红线**：不接任何支付通道、不做自动到账、不做提现、平台不经手资金 —— 见 CLAUDE.md 结构规则 12。
    RechargeModule,
    // 打手提现（人工打款）—— 负责人 2026-10-11；与充值同源的"双层口径"（管理端 + App 管理员态）
    WithdrawModule,
    // 评价体系（负责人 2026-10-15）：老板提交/回显 + 管理端治理（窄权限点 review:moderate）。
    // 公开侧打手信息（接单次数 + 好评率 + 最近评价）由 PlayersModule 的 PublicWorkersController 暴露
    ReviewModule,
    // 打手等级 + 五维评分（负责人已审批 2026-10-17）：老板评分（/user/orders/:id/rating）→
    // 同事务重算五维聚合 → 自动判级（只升不降，宗师仅人工）→ 打手态 /worker/grade
    // + 管理端 /admin/workers/:id/grade（仅超管）。等级名与门槛的唯一出处：
    // modules/worker/worker-grade.constants.ts
    RatingModule,
    // 记住我的游戏 ID（负责人 2026-10-15）：下单成功时服务端自动 upsert，客户端只调 GET 回填
    GameAccountModule,
    LeaderboardModule,
    LevelModule,
    LogModule,
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    // 请求 ID 先行（限流响应也要带 requestId），再全局限流（docs/09）
    consumer.apply(RequestIdMiddleware, GlobalRateLimitMiddleware).forRoutes('*');
  }
}
