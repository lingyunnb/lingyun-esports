import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { LeaderboardAdjustment } from './leaderboard-adjustment.entity';
import { LeaderboardEntry } from './leaderboard-entry.entity';
import { LeaderboardAdminController, LeaderboardWorkerController } from './leaderboard.controller';
import { PublicLeaderboardController } from './public-leaderboard.controller';
import { LeaderboardService } from './leaderboard.service';
import { WorkerStats } from './worker-stats.entity';

@Module({
  imports: [TypeOrmModule.forFeature([WorkerStats, LeaderboardEntry, LeaderboardAdjustment, OperationLog])],
  controllers: [LeaderboardWorkerController, LeaderboardAdminController, PublicLeaderboardController],
  providers: [LeaderboardService, OperationLogService],
  exports: [LeaderboardService],
})
export class LeaderboardModule {}
