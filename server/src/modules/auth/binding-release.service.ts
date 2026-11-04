import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';

import { RealtimeGateway } from '../../realtime/realtime.gateway';
import {
  ReleaseOutcome,
  ReleaseSink,
  SqlRunner,
  releaseBossBindings,
  releaseOneBinding,
  releaseUserBindings,
  releaseWorkerBindings,
} from './worker-binding-release';

/**
 * 绑定释放的**唯一入口**（安全审计 F1-b 修复的收口点）。
 *
 * 为什么要有这一层，而不是让各调用点自己 `releaseXxx() + realtime.disconnectByJti()`：
 * 审计 F1 的教训就是"释放路径各写各的"（`releaseWorkerBindings` 只 UPDATE 绑定行、不吊销令牌），
 * 谁都不主动断开 WS。把"SQL + 令牌吊销 + 审计"与"立即断开 WS 连接"绑成一个原子步骤，
 * 调用方只能拿到一个方法，**没有机会漏掉任何一步**。
 *
 * 事务场景（`UserAdminService.deleteUser` 在既有事务内释放）：
 * 用 [releaseBothInTx] —— SQL 跑在调用方事务里（保证与删除同生共死），
 * **提交后**必须调用 [kickRevoked]（事务回滚时不该踢线：会话仍然有效）。
 */
@Injectable()
export class BindingReleaseService {
  private readonly logger = new Logger('BindingRelease');

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly realtime: RealtimeGateway,
  ) {}

  /** 打手侧释放（该账号被谁绑着）：打手停用入口用 */
  async releaseWorkerSide(workerUserId: string, sink: ReleaseSink): Promise<ReleaseOutcome> {
    return this.finish(await releaseWorkerBindings(this.dataSource, workerUserId, sink), sink);
  }

  /** 老板侧释放（该账号名下绑着谁）：封禁/删除老板时用（保证其 companion 立即失去绑定） */
  async releaseBossSide(bossUserId: string, sink: ReleaseSink): Promise<ReleaseOutcome> {
    return this.finish(await releaseBossBindings(this.dataSource, bossUserId, sink), sink);
  }

  /** 两侧一起释放（封禁 / 删除账号） */
  async releaseBoth(userId: string, sink: ReleaseSink): Promise<ReleaseOutcome> {
    return this.finish(await releaseUserBindings(this.dataSource, userId, sink), sink);
  }

  /** 释放指定的一条绑定（老板主动解绑 `POST /user/identity/unbind`） */
  async releaseBinding(bindingId: string, sink: ReleaseSink): Promise<ReleaseOutcome> {
    return this.finish(await releaseOneBinding(this.dataSource, bindingId, sink), sink);
  }

  /**
   * **事务内**释放两侧绑定（`em` = 调用方事务的 EntityManager）：SQL 与调用方的写入同生共死。
   * ⚠️ 调用方**必须在事务提交成功后**调用 [kickRevoked]（否则事务回滚会把仍然有效的会话踢下线）。
   */
  releaseBothInTx(em: SqlRunner, userId: string, sink: ReleaseSink): Promise<ReleaseOutcome> {
    return releaseUserBindings(em, userId, sink);
  }

  /**
   * 主动断开被吊销会话的 WS 连接（找不到连接返回 0，不算错）。
   *
   * @param payload 随 `auth:expired` 一起下发的载荷（缺省 `{}` = 与历史逐字节一致）。
   *   封禁路径（2026-10-16）用它带上「账号已被封禁：<原因>（…）」+ `errorCode=ACCOUNT_BANNED`，
   *   让**只开着 WS、没在发请求**的被封用户也能立刻看到封禁原因
   *   （文案构造的唯一实现：`modules/auth/account-ban.check.ts` 的 `buildBanMessage()`）。
   */
  kickRevoked(jtis: string[], payload: Record<string, unknown> = {}): number {
    return this.realtime.disconnectByJti(jtis, 'auth:expired', payload);
  }

  /** 非事务路径：SQL 完成即断开（同一请求内同步完成，不留后台任务） */
  private finish(outcome: ReleaseOutcome, sink: ReleaseSink): ReleaseOutcome {
    if (outcome.total > 0) {
      this.logger.log(
        `释放绑定：来源=${sink.source} 绑定=[${outcome.bindings.map((b) => b.bindingId).join(',')}] ` +
          `吊销 companion 会话=${outcome.revokedSessions} 审计行=${outcome.auditRows}`,
      );
    }
    if (outcome.revokedJtis.length > 0) {
      this.kickRevoked(outcome.revokedJtis);
    }
    return outcome;
  }
}
