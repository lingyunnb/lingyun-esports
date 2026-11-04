import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { randomBytes, randomInt } from 'crypto';
import { DataSource, EntityManager, QueryFailedError, Repository } from 'typeorm';
import { User } from '../user/user.entity';
import { Wallet } from './wallet.entity';
import { WalletTransaction } from './wallet-transaction.entity';
import { mapMoney } from '../../common/money.transformer';

export interface WalletOpMeta {
  ip: string;
  requestId: string;
}

/**
 * 余额服务（docs/06 铁律）：
 * - 发放/回收仅 admin:wallet:grant（默认仅超管），客户端金额/余额不可信
 * - 事务内：行锁钱包 → 校验 → 更新余额 → 写流水（前后余额快照）
 * - 幂等键唯一约束兜底；同键重试返回首次结果，绝不重复入账
 * - 回收校验余额充足，禁止负余额
 */
@Injectable()
export class WalletService {
  constructor(
    @InjectRepository(Wallet) private readonly walletRepo: Repository<Wallet>,
    @InjectRepository(WalletTransaction) private readonly txnRepo: Repository<WalletTransaction>,
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  async grant(adminUserId: string, dto: { userId: string; amount: number; reason?: string; idempotencyKey: string }, meta: WalletOpMeta) {
    const target = await this.userRepo.findOne({ where: { id: dto.userId, role: 'user' } });
    if (!target) {
      throw new NotFoundException('用户不存在');
    }
    return this.executeChange({
      userId: dto.userId,
      amount: dto.amount,
      changeType: 'grant',
      operatorType: 'admin',
      operatorId: adminUserId,
      source: 'admin-web',
      reason: dto.reason ?? null,
      idempotencyKey: dto.idempotencyKey,
      meta,
    });
  }

  async recover(adminUserId: string, dto: { userId: string; amount: number; reason?: string; idempotencyKey: string }, meta: WalletOpMeta) {
    const target = await this.userRepo.findOne({ where: { id: dto.userId, role: 'user' } });
    if (!target) {
      throw new NotFoundException('用户不存在');
    }
    return this.executeChange({
      userId: dto.userId,
      amount: -dto.amount,
      changeType: 'recover',
      operatorType: 'admin',
      operatorId: adminUserId,
      source: 'admin-web',
      reason: dto.reason ?? null,
      idempotencyKey: dto.idempotencyKey,
      meta,
      requireSufficient: true,
    });
  }

  /**
   * **事务内**发放余额（充值审核发放专用入口，2026-10-06）。
   *
   * 为什么要有这个方法，而不是让充值模块自己写 UPDATE：
   * 「事务内行锁钱包 → 校验 → 改余额 → 写流水（含前后余额快照）→ 幂等键唯一约束兜底」
   * 这一整段是 docs/06 的铁律，**只能有一份实现**。充值发放需要"发余额"与"回写申请状态 +
   * 写审计"在**同一个事务**里同生共死（否则会出现"余额发了、申请还是 pending"或反之），
   * 所以这里把既有 `executeChange` 开放一个"跑在调用方事务里"的入口 ——
   * 逻辑**逐字复用**（本方法只转发，不改任何判定），没有第二条余额路径。
   *
   * 与 `grant()` 的唯一差别：`executeChange` 用调用方传进来的 `em`（调用方的连接/事务），
   * 而不是自己开一个新事务。`grant()` 本身的行为**逐字节未变**（仍走 `dataSource.transaction`）。
   *
   * @param em 调用方事务的 EntityManager
   */
  grantInTx(
    em: EntityManager,
    adminUserId: string,
    dto: { userId: string; amount: number; reason?: string; idempotencyKey: string },
    meta: WalletOpMeta,
  ) {
    return this.executeChange(
      {
        userId: dto.userId,
        amount: dto.amount,
        changeType: 'grant',
        operatorType: 'admin',
        operatorId: adminUserId,
        source: 'recharge-review',
        reason: dto.reason ?? null,
        idempotencyKey: dto.idempotencyKey,
        meta,
      },
      em,
    );
  }

  /**
   * **事务内扣款**（提现申请专用入口，2026-10-11）。
   *
   * 与 [grantInTx] 完全同构、只是符号与语义相反：提现申请要在**同一事务**里
   * "扣余额 + 写流水 + 建申请单"同生共死（否则会出现"钱扣了、申请没建"或反之）。
   * 复用同一个 `executeChange`：事务内行锁钱包 → 校验余额充足 → 改余额 →
   * 写流水（含前后余额快照）→ `idempotency_key` 唯一约束兜底。
   *
   * 本方法**不新写一套余额逻辑**：提现模块不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`。
   *
   * @param em 调用方事务的 EntityManager
   * @param dto.amount 正数金额（元）；内部取负以表示"减少"
   * @param dto.idempotencyKey 由调用方给出（提现口径：`withdraw:<requestId>`）
   */
  withdrawDeductInTx(
    em: EntityManager,
    dto: { userId: string; amount: number; reason?: string; idempotencyKey: string },
    meta: WalletOpMeta,
  ) {
    return this.executeChange(
      {
        userId: dto.userId,
        amount: -Math.abs(Number(dto.amount)),
        changeType: 'withdraw',
        // 扣款由打手本人发起（不是管理员操作）→ operatorType='user'，便于审计区分
        operatorType: 'user',
        operatorId: dto.userId,
        source: 'withdraw',
        reason: dto.reason ?? null,
        idempotencyKey: dto.idempotencyKey,
        meta,
        // 扣款必须校验余额充足：禁负余额（docs/06 铁律）
        requireSufficient: true,
      },
      em,
    );
  }

  /**
   * **事务内退回**（提现驳回专用入口，2026-10-11）：`change_type='withdraw_reject'`。
   *
   * 驳回走的是"条件 UPDATE 成功后**反向**再记一笔"，因此这里**不置 requireSufficient**
   * （退回只会让余额变大；若误置，会在"余额已被别的支出压到 0 以下"的异常库里静默失败）。
   * 幂等键由调用方给出（提现口径：`withdraw_reject:<requestId>`）→ 唯一约束保证只能退一次。
   */
  withdrawRefundInTx(
    em: EntityManager,
    adminUserId: string | null,
    dto: { userId: string; amount: number; reason?: string; idempotencyKey: string },
    meta: WalletOpMeta,
  ) {
    return this.executeChange(
      {
        userId: dto.userId,
        amount: Math.abs(Number(dto.amount)),
        changeType: 'withdraw_reject',
        operatorType: adminUserId ? 'admin' : 'system',
        operatorId: adminUserId,
        source: 'withdraw',
        reason: dto.reason ?? null,
        idempotencyKey: dto.idempotencyKey,
        meta,
      },
      em,
    );
  }

  /** 管理端：钱包列表（join 用户信息） */
  async adminList(page: number, pageSize: number, keyword: string) {
    const qb = this.dataSource
      .createQueryBuilder(Wallet, 'w')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .select(['w.id AS id', 'w.user_id AS userId', 'w.balance AS balance', 'u.username AS username', 'u.uid AS uid', 'u.nickname AS nickname', 'u.role AS role', 'u.level AS level', 'u.total_spent AS totalSpent', 'w.updated_at AS updatedAt']);
    if (keyword) {
      qb.where('u.username LIKE :kw OR u.uid LIKE :kw OR u.nickname LIKE :kw', { kw: `%${keyword}%` });
    }
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('w.updated_at', 'DESC').offset((page - 1) * pageSize).limit(pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['balance', 'totalSpent'])), total: Number(total?.cnt ?? 0), page, pageSize };
  }

  /** 管理端：余额流水 */
  async adminTransactions(page: number, pageSize: number, userId?: string, changeType?: string) {
    const qb = this.dataSource
      .createQueryBuilder(WalletTransaction, 't')
      .innerJoin(User, 'u', 'u.id = t.user_id')
      .select(['t.id AS id', 't.transaction_no AS transactionNo', 't.user_id AS userId', 'u.username AS username', 't.change_type AS changeType', 't.amount AS amount', 't.balance_before AS balanceBefore', 't.balance_after AS balanceAfter', 't.operator_type AS operatorType', 't.reason AS reason', 't.created_at AS createdAt']);
    if (userId) qb.andWhere('t.user_id = :userId', { userId });
    if (changeType) qb.andWhere('t.change_type = :changeType', { changeType });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('t.id', 'DESC').offset((page - 1) * pageSize).limit(pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['amount', 'balanceBefore', 'balanceAfter'])), total: Number(total?.cnt ?? 0), page, pageSize };
  }

  /** 用户端：自己的余额（主体 id 取自 JWT，docs/04） */
  async userBalance(userId: string) {
    const wallet = await this.walletRepo.findOne({ where: { userId } });
    return { balance: wallet?.balance ?? 0 };
  }

  /** 用户端：自己的流水（只读，永不给增余额入口，docs/06） */
  async userTransactions(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.txnRepo.findAndCount({
      where: { userId },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    return {
      list: list.map((t) => ({
        id: t.id,
        transactionNo: t.transactionNo,
        changeType: t.changeType,
        amount: t.amount,
        balanceBefore: t.balanceBefore,
        balanceAfter: t.balanceAfter,
        reason: t.reason,
        createdAt: t.createdAt,
      })),
      total,
      page,
      pageSize,
    };
  }

  /**
   * 核心变更：事务 + 行锁 + 流水快照 + 幂等（docs/06）
   *
   * @param em 可选：**调用方的事务**（充值审核发放走这条，见 [grantInTx]）。
   *   不传 = 自开事务，行为与历史**逐字节相同**（既有 `grant`/`recover` 都不传）。
   */
  private async executeChange(
    input: {
      userId: string;
      amount: number; // 正=增加（grant），负=减少（recover）
      changeType: string;
      operatorType: string;
      operatorId: string | null;
      source: string;
      reason: string | null;
      idempotencyKey: string;
      meta: WalletOpMeta;
      requireSufficient?: boolean;
    },
    em?: EntityManager,
  ) {
    // 幂等先行检查：同键已有流水直接返回首次结果。
    // 走调用方事务时必须用**它的**仓储（`em`）读，否则读的是另一个连接、看不到本事务未提交的写入。
    const repo = em ? em.getRepository(WalletTransaction) : this.txnRepo;
    const existing = await repo.findOne({ where: { idempotencyKey: input.idempotencyKey } });
    if (existing) {
      return this.duplicateResult(existing);
    }
    const run = async (manager: EntityManager) => {
      const wallet = await manager.findOne(Wallet, {
        where: { userId: input.userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!wallet) {
        throw new NotFoundException('用户钱包不存在');
      }
      const before = wallet.balance;
      if (input.requireSufficient && before < -input.amount) {
        throw new BadRequestException('余额不足');
      }
      const after = before + input.amount;
      await manager.update(Wallet, wallet.id, { balance: after });
      const txn = await manager.save(
        manager.create(WalletTransaction, {
          transactionNo: this.generateTransactionNo(),
          userId: input.userId,
          changeType: input.changeType,
          amount: input.amount,
          balanceBefore: before,
          balanceAfter: after,
          operatorType: input.operatorType,
          operatorId: input.operatorId,
          source: input.source,
          reason: input.reason,
          idempotencyKey: input.idempotencyKey,
          ip: input.meta.ip?.slice(0, 64) ?? null,
          requestId: input.meta.requestId?.slice(0, 64) ?? null,
        }),
      );
      return { transactionNo: txn.transactionNo, balanceBefore: before, balanceAfter: after, amount: input.amount };
    };
    // 调用方事务：直接在其中执行（不新开事务 —— 否则"发余额"与调用方的写入无法同生共死）
    if (em) return run(em);
    try {
      return await this.dataSource.transaction(run);
    } catch (e) {
      // 并发同键：唯一约束兜底，返回首次结果
      if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
        const dup = await this.txnRepo.findOne({ where: { idempotencyKey: input.idempotencyKey } });
        if (dup) {
          return this.duplicateResult(dup);
        }
      }
      throw e;
    }
  }

  private duplicateResult(txn: WalletTransaction) {
    return {
      duplicated: true,
      transactionNo: txn.transactionNo,
      balanceBefore: txn.balanceBefore,
      balanceAfter: txn.balanceAfter,
      amount: txn.amount,
    };
  }

  private generateTransactionNo(): string {
    const ts = Date.now().toString(36).toUpperCase();
    const rand = randomInt(1000, 10000);
    const salt = randomBytes(2).toString('hex').toUpperCase();
    return `T${ts}${salt}${rand}`;
  }

  /** 注册时创建钱包（auth 模块事务内调用） */
  createWalletInTx(em: EntityManager, userId: string): Promise<Wallet> {
    return em.save(em.create(Wallet, { userId, balance: 0 }));
  }

  /** 工作端我的余额/收益（负责人需求 #6，真实流水聚合）：余额 + 累计结算收入 + 结算次数 + 打赏收益 */
  async workerWallet(userId: string) {
    const wallet = await this.walletRepo.findOne({ where: { userId } });
    const rows: Array<{ income: string; reversals: string; settlements: string; granted: string; spent: string; tips: string; tipCount: string }> = await this.dataSource.query(
      `SELECT
         COALESCE(SUM(CASE WHEN change_type = 'order_settlement' THEN amount ELSE 0 END), 0) AS income,
         COALESCE(SUM(CASE WHEN change_type = 'settlement_reversal' THEN -amount ELSE 0 END), 0) AS reversals,
         SUM(CASE WHEN change_type = 'order_settlement' THEN 1 ELSE 0 END) AS settlements,
         COALESCE(SUM(CASE WHEN change_type = 'grant' THEN amount ELSE 0 END), 0) AS granted,
         COALESCE(SUM(CASE WHEN amount < 0 THEN -amount ELSE 0 END), 0) AS spent,
         -- 打赏收益（负责人 2026-10-04）：独立类型 order_tip_income，明确区分于订单结算
         COALESCE(SUM(CASE WHEN change_type = 'order_tip_income' THEN amount ELSE 0 END), 0) AS tips,
         SUM(CASE WHEN change_type = 'order_tip_income' THEN 1 ELSE 0 END) AS tipCount
       FROM wallet_transaction WHERE user_id = ?`,
      [userId],
    );
    const r = rows[0];
    return {
      balance: wallet?.balance ?? 0,
      // 累计获得余额：订单结算 − 结算冲正（负责人 2026-09-25：工作端完整余额入口）
      //
      // ⚠️ 下限夹 0（2026-10-17 修）：`settlement_reversal` 是**冲正**流水，正常必然有对应的
      // `order_settlement`。但订单被整体清空过（2026-10-03 品牌重置、2026-10-17 清库两轮），
      // 冲正行留着、原始结算行没了 → `income(0) - reversals(26.40)` 会把"累计结算"算成 **-26.40**，
      // 而旁边的"结算笔数"是 0，用户看到的是"结算 0 笔却欠了 26 块"。
      // 「累计」是个只增不减的口径，负数在业务上无意义 → 夹到 0。
      // 注意：只夹**展示聚合值**，不动 `wallet.balance`，也不动任何一条流水 —— 钱一分不改。
      totalIncome: Math.max(0, Number(r?.income ?? 0) - Number(r?.reversals ?? 0)),
      totalGranted: Number(r?.granted ?? 0),
      totalSpent: Number(r?.spent ?? 0),
      settlementCount: Number(r?.settlements ?? 0),
      // 打赏收益（老板打赏 100% 到手，平台不抽成）
      tipIncome: Number(r?.tips ?? 0),
      tipCount: Number(r?.tipCount ?? 0),
    };
  }
}
