import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, Repository } from 'typeorm';

import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { UserNotification } from '../friend/user-notification.entity';
import { Media } from '../media/media.entity';
import { MediaService } from '../media/media.service';
import { OperationLogService } from '../log/operation-log.service';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { WalletService } from '../wallet/wallet.service';
import { Worker } from '../worker/worker.entity';
import {
  WITHDRAW_CONFIG_DEFAULT,
  WITHDRAW_CONFIG_DESCRIPTION,
  WITHDRAW_CONFIG_KEY,
  WITHDRAW_PENDING_LIMIT,
  WithdrawConfig,
  assertWithdrawConfig,
  fmtYuan,
  maskPhone,
  maskRealName,
  maskWechatId,
  parseWithdrawConfig,
  roundYuan,
  shanghaiDayRange,
} from './withdraw-config';
import { WorkerWithdrawAccount } from './worker-withdraw-account.entity';
import { WithdrawRequest } from './withdraw-request.entity';

/** 打手侧写操作的元信息（IP / requestId 进钱包流水，与 `WalletOpMeta` 同口径） */
export interface WithdrawMeta {
  ip: string;
  requestId: string;
  /** 操作来源（审计用：`admin-web` / `app-admin` / `worker-app`） */
  source?: string;
}

/** 管理端列表筛选（契约：status/keyword/page/pageSize） */
export interface WithdrawReviewQuery {
  status?: string;
  keyword?: string;
  startTime?: string;
  endTime?: string;
}

/** `withdraw_request` 的行锁读取结果（原生查询列名是 snake_case，这里显式声明避免 any） */
interface RequestRow {
  id: string | number;
  workerId: string | number;
  userId: string | number;
  amount: string | number;
  status: string;
  appliedAt: Date | null;
  paidAt: Date | null;
  paidBy: string | number | null;
  payoutProofMediaId: string | number | null;
  payoutNote: string | null;
  rejectedAt: Date | null;
  rejectedBy: string | number | null;
  rejectReason: string | null;
  walletTransactionId: string | number | null;
  idempotencyKey: string | null;
}

/**
 * 打手提现（人工打款）核心服务 —— **管理端 PC 与 App 内「管理员身份」共用同一个服务层**。
 *
 * ## 为什么共用（与充值「双层口径」逐条同构）
 *
 * PC 管理端走 `/admin/withdraw/*`（primary 会话 + `withdraw:review`/`withdraw:pay`），
 * App 内「管理员身份」走 `/withdraw/*`（受限会话 `kind='recharge'` + 同样这两个权限点）。
 * 两条入口**只差"用哪种会话进来"**：幂等、审计、状态机完全一致 —— 因为它们调的是本文件的
 * 同一批方法（`reviewList` / `detail` / `pay` / `reject` / `proofMedia`）。
 *
 * ## 资金安全三件套（缺一不可，实现位置一目了然）
 *
 * | # | 手段 | 本文件落点 |
 * |---|---|---|
 * | ① | 事务 + `SELECT … FOR UPDATE` 锁钱包 | `createRequest`：`SELECT id,balance FROM wallet WHERE user_id=? FOR UPDATE`（同一打手的申请在此**排队**） |
 * | ② | 条件 UPDATE 判 `affectedRows` | `pay` / `reject`：`UPDATE withdraw_request … WHERE id=? AND status='pending'`，**这是"能否打款/驳回"的唯一判定点** |
 * | ③ | 幂等键唯一约束 | `wallet_transaction.idempotency_key`：扣款 `withdraw:<id>`、退回 `withdraw_reject:<id>`（`UQ_wallet_txn_idem`） |
 *
 * ## 扣款与退回都走既有 `WalletService`（**不自己 UPDATE wallet、不自己拼流水**）
 *
 * - 申请：`WalletService.withdrawDeductInTx()`（`change_type='withdraw'`，事务内行锁 + 余额充足校验 + 前后余额快照）；
 * - 驳回：`WalletService.withdrawRefundInTx()`（`change_type='withdraw_reject'`）。
 *
 * 两者都是既有 `executeChange()` 的转发入口 —— 与"管理员发余额"同一份余额逻辑，没有第二条路径。
 * 金额一律 `¥`/两位小数（`fmtYuan`），**全文件不出现"积分"**。
 */
@Injectable()
export class WithdrawService {
  private readonly logger = new Logger('Withdraw');

  constructor(
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(WorkerWithdrawAccount) private readonly accountRepo: Repository<WorkerWithdrawAccount>,
    @InjectRepository(WithdrawRequest) private readonly requestRepo: Repository<WithdrawRequest>,
    @InjectRepository(Media) private readonly mediaRepo: Repository<Media>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
    private readonly wallet: WalletService,
    private readonly media: MediaService,
    private readonly opLog: OperationLogService,
    private readonly realtime: RealtimeGateway,
  ) {}

  // ==========================================================================
  // 配置
  // ==========================================================================

  /**
   * 读配置（**每次实时读库，无缓存**）。
   *
   * 单行主键读（`setting_key` 唯一索引）；换来的语义是"管理端改完**下一次请求**即生效"，
   * 与 `recharge_config` / `worker_app_sunset_at` 同口径。整行被写坏时按字段回落默认值（读侧兜底）。
   */
  async config(): Promise<WithdrawConfig> {
    const row = await this.settings.get(WITHDRAW_CONFIG_KEY);
    if (!row) {
      this.logger.warn(`配置 ${WITHDRAW_CONFIG_KEY} 缺失，本次读侧回落全量默认值`);
      return { ...WITHDRAW_CONFIG_DEFAULT };
    }
    return parseWithdrawConfig(row.cfgValue?.['value']);
  }

  /** 管理端 `GET /admin/withdraw/config`：平铺返回配置 + 展示用元信息 */
  async configView() {
    const cfg = await this.config();
    return {
      ...cfg,
      /** 是否仅超管可改（管理端据此显示标签；权威判定在服务端 `is_high_security`） */
      superAdminOnly: true,
      /** 未结清申请数上限（写死的资金安全不变量，不可配） */
      pendingLimit: WITHDRAW_PENDING_LIMIT,
      /** 恢复默认用 */
      defaultConfig: { ...WITHDRAW_CONFIG_DEFAULT },
    };
  }

  // ==========================================================================
  // 打手端：收款信息
  // ==========================================================================

  /**
   * `GET /worker/withdraw/account` —— 我的收款信息（**脱敏**：姓名/手机号打码，微信号本人可见）。
   *
   * 未绑定返回 `{ bound:false }`（而不是 404）：客户端首屏要能直接渲染"去绑定"的引导态。
   * `qrUrl` 是**我自己的取图链接**（受保护通道 `/api/v1/media/protected/:id`）——
   * 收款码是 `withdraw_qr`（protected），**绝不公开直连**（`/media/public/:id` 会 404）。
   */
  async getAccount(userId: string) {
    const worker = await this.workerOf(userId);
    const row = await this.activeAccountOf(worker.id);
    if (!row) {
      return { bound: false, realName: '', phone: '', wechatId: '', qrUrl: null, updatedAt: null };
    }
    const url = (await this.media.pathsByIds([String(row.qrMediaId)])).get(String(row.qrMediaId)) ?? null;
    return {
      bound: true,
      realName: maskRealName(row.realName),
      phone: maskPhone(row.phone),
      wechatId: row.wechatId,
      qrUrl: url,
      updatedAt: row.updatedAt,
    };
  }

  /**
   * `POST /worker/withdraw/account` —— 绑定 / **换绑**（覆盖同一行，旧值进审计）。
   *
   * 校验（全部中文 400）：
   * 1. 姓名/手机号/微信号必填且长度合法；
   * 2. 手机号形态（11 位数字，允许 `+86` 前缀）—— 打款要能联系到人，写错的号会让人白打一次；
   * 3. `qrMediaId` **必须是本人上传的图片**，且用途为 **`withdraw_qr`** ——
   *    用途白名单从源头堵死"拿任意受保护媒体（例如聊天图片）当收款码再从窄通道读出来"的旁路。
   *
   * 换绑 = `UPDATE` 同一行（不新增行、不留"没有 active 行"的窗口），
   * 新旧值摘要写 `operation_log`（**不记密码/token**）。
   */
  async saveAccount(
    userId: string,
    dto: { realName?: string; phone?: string; wechatId?: string; qrMediaId?: string },
    meta: WithdrawMeta,
  ) {
    const worker = await this.workerOf(userId);

    const realName = String(dto?.realName ?? '').trim();
    const phone = String(dto?.phone ?? '').trim().replace(/^\+?86[\s-]?/, '');
    const wechatId = String(dto?.wechatId ?? '').trim();
    const qrMediaId = String(dto?.qrMediaId ?? '').trim();

    if (!realName) throw new BadRequestException('请填写真实姓名');
    if (realName.length > 32) throw new BadRequestException('真实姓名最多 32 字');
    if (!phone) throw new BadRequestException('请填写手机号');
    if (!/^\d{11}$/.test(phone)) throw new BadRequestException('手机号格式不正确（请填写 11 位手机号）');
    if (!wechatId) throw new BadRequestException('请填写微信号');
    if (wechatId.length > 64) throw new BadRequestException('微信号最多 64 字');
    if (!qrMediaId) throw new BadRequestException('请上传微信收款码');

    const media = await this.mediaRepo.findOne({ where: { id: qrMediaId } });
    if (!media) throw new BadRequestException('收款码图片不存在，请重新上传');
    if (String(media.uploaderId ?? '') !== String(userId)) {
      throw new BadRequestException('收款码必须是你本人上传的图片');
    }
    if (!String(media.mimeType ?? '').startsWith('image/')) {
      throw new BadRequestException('收款码必须是图片');
    }
    if (media.mediaType !== 'withdraw_qr') {
      throw new BadRequestException('收款码请使用提现收款码上传（type=withdraw_qr）');
    }

    const before = await this.activeAccountOf(worker.id);
    /**
     * ⚠️ 审计的"旧值"必须在这里**先快照**：下面 `Object.assign(before, ...)` 是**就地改同一个对象**，
     * 若等到写 `operation_log` 时再读 `before`，读到的就是**已经被覆盖后的新值**
     * （实测：审计里 before === after，等于换绑没留痕 —— 这正是审计最该抓住的事）。
     *
     * ⚠️ **写进审计的是脱敏值**（2026-10-11 收紧，与"列表/详情给完整"是**两件事**）：
     * `operation_log` 是**比审核列表更宽的面** —— 能读它的人由「操作日志」权限决定，
     * 不一定是持有 `withdraw:review` 的审核人。PIPL 的合规点是"**不向无关方泄露**"，
     * 所以摘要里只记 `张** / 139****9000 / wd****02`（同一个 `mask*` 实现，见 `withdraw-config.ts`）；
     * 审核人要核对完整值，走 `detail()` 的 `account`（权限点把关）。
     * 换绑仍可审计出"打款去向被改过"（`before`/`after` 两段 + `rebind` 标志都在）。
     */
    const beforeSnapshot = before
      ? {
          realName: maskRealName(before.realName),
          phone: maskPhone(before.phone),
          wechatId: maskWechatId(before.wechatId),
          qrMediaId: String(before.qrMediaId),
        }
      : null;
    const saved = before
      ? await this.accountRepo.save(
          Object.assign(before, { realName, phone, wechatId, qrMediaId, status: 'active' as const }),
        )
      : await this.accountRepo.save(
          this.accountRepo.create({
            workerId: String(worker.id),
            realName,
            phone,
            wechatId,
            qrMediaId,
            status: 'active' as const,
          }),
        );

    const rebind = !!before;
    this.audit({
      adminUserId: null,
      action: rebind ? 'withdraw:account:rebind' : 'withdraw:account:bind',
      method: 'POST',
      path: '/api/v1/worker/withdraw/account',
      requestBody: {
        workerId: String(worker.id),
        userId: String(userId),
        before: beforeSnapshot,
        /** 新值同样**脱敏**（理由见上面 `beforeSnapshot` 的注释：operation_log 是不特定管理员可见的面） */
        after: {
          realName: maskRealName(realName),
          phone: maskPhone(phone),
          wechatId: maskWechatId(wechatId),
          qrMediaId,
        },
        // 明确记录"这是换绑"：审计里最该回答的问题是"打款去向有没有被改过"
        rebind,
      },
      ip: meta.ip,
      requestId: meta.requestId,
    });

    this.logger.log(
      `提现收款信息${rebind ? '换绑' : '绑定'} worker=${worker.id} user=${userId} 收款码=${qrMediaId}`,
    );
    const url = (await this.media.pathsByIds([String(saved.qrMediaId)])).get(String(saved.qrMediaId)) ?? null;
    return {
      ok: true,
      bound: true,
      rebind,
      realName: maskRealName(saved.realName),
      phone: maskPhone(saved.phone),
      wechatId: saved.wechatId,
      qrUrl: url,
      updatedAt: saved.updatedAt,
    };
  }

  // ==========================================================================
  // 打手端：配置 / 申请
  // ==========================================================================

  /**
   * `GET /worker/withdraw/config` —— 提现页首屏数据。
   *
   * 返回 `{ minAmount, maxAmount, dailyLimit, feeRate, noticeText, balance, todayUsed }`。
   * **客户端只用它做提示，服务端仍是权威**（提交时全部重新校验一遍，服务端不信客户端）。
   */
  async workerConfig(userId: string) {
    const cfg = await this.config();
    const worker = await this.workerOf(userId);
    const balance = await this.balanceOf(userId);
    const todayUsed = await this.todayCountOf(worker.id);
    return {
      minAmount: cfg.minAmount,
      maxAmount: cfg.maxAmount,
      dailyLimit: cfg.dailyLimit,
      feeRate: cfg.feeRate,
      noticeText: cfg.noticeText,
      balance,
      todayUsed,
      /** 未结清申请（0/1）—— 客户端据此禁用提交按钮（服务端仍会拦） */
      pendingCount: await this.pendingCountOf(worker.id),
      pendingLimit: WITHDRAW_PENDING_LIMIT,
    };
  }

  /**
   * `POST /worker/withdraw/requests` —— **申请即扣款**（本功能最关键的一段）。
   *
   * 事务内顺序（每一步都有理由，改这里之前先读文件头注释）：
   * 1. **锁钱包**：`SELECT id, balance FROM wallet WHERE user_id=? FOR UPDATE`
   *    —— 同一打手的并发申请在这一行上**排队**（串行化点），顺带拿到权威余额快照；
   * 2. **未结清上限**（`FOR UPDATE` 当前读）：`status='pending'` 的条数 `< WITHDRAW_PENDING_LIMIT`
   *    → 否则 **中文 409「你有一笔提现正在处理中」**（并发落败方看到的就是这一条）；
   * 3. **今日次数**（`FOR UPDATE` 当前读）：`created_at ∈ 北京时间当日` 的申请数 `< dailyLimit`；
   * 4. 金额三道闸门：`≥ minAmount`、`≤ maxAmount`、`≤ 全部余额`（用第 1 步锁内读到的余额）；
   * 5. 建 `pending` 申请（先拿 id：幂等键要用它）；
   * 6. `WalletService.withdrawDeductInTx()` **同一事务**扣款 + 写流水（`withdraw:<id>`）；
   * 7. 回读流水 → **条件 UPDATE** 回写 `wallet_transaction_id`（判 affectedRows，不为 1 整体回滚）；
   * 8. 站内通知（同事务）→ 提交后推 `notification:new`。
   *
   * 任何一步抛错 → **整体回滚**：不可能出现"钱扣了、申请没建"或"申请建了、钱没扣"。
   * 客户端重试带同一个 `idempotencyKey` → 返回**首次结果**，不重复扣款。
   */
  async createRequest(
    userId: string,
    amountRaw: unknown,
    idempotencyKey: string | undefined,
    meta: WithdrawMeta,
  ) {
    const cfg = await this.config();
    const worker = await this.workerOf(userId);

    // ---- 金额规整与格式校验（DECIMAL(12,2) 精度：超过 2 位小数直接拒）----
    const amount = roundYuan(Number(amountRaw));
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new BadRequestException('提现金额不正确');
    }
    if (Math.abs(amount - Number(amountRaw)) > 1e-9) {
      throw new BadRequestException('提现金额最多保留 2 位小数');
    }

    // ---- 必须先绑定收款信息（否则管理员拿到申请也不知道打给谁）----
    const account = await this.activeAccountOf(worker.id);
    if (!account) {
      throw new BadRequestException('请先绑定收款信息');
    }

    // ---- 门槛（客户端提示不可信，服务端权威校验）----
    if (amount < cfg.minAmount) {
      throw new BadRequestException(`单笔提现不能低于 ${fmtYuan(cfg.minAmount)}`);
    }
    if (amount > cfg.maxAmount) {
      throw new BadRequestException(`单笔提现不能高于 ${fmtYuan(cfg.maxAmount)}`);
    }

    // ---- 幂等：同一 key 的重复提交直接返回首次结果（不重复扣款）----
    const idemKey = String(idempotencyKey ?? '').trim().slice(0, 64) || null;
    if (idemKey) {
      const dup = await this.requestRepo.findOne({ where: { idempotencyKey: idemKey } });
      if (dup) return this.duplicatedApply(dup);
    }

    const day = shanghaiDayRange();

    let outcome: {
      requestId: string;
      amount: number;
      balanceBefore: number;
      balanceAfter: number;
      transactionNo: string;
      appliedAt: Date;
    };
    try {
      outcome = await this.dataSource.transaction(async (em: EntityManager) => {
        // ---- ① 锁钱包（同一打手的申请在此串行化；余额也以锁内读到的为准）----
        const walletRows: Array<{ id: string | number; balance: string | number }> = await em.query(
          'SELECT `id`, `balance` FROM `wallet` WHERE `user_id` = ? FOR UPDATE',
          [String(userId)],
        );
        const wallet = walletRows?.[0];
        if (!wallet) throw new NotFoundException('用户钱包不存在');
        const balance = Number(wallet.balance);

        // ---- ② 未结清上限（当前读）----
        /**
         * ⚠️ 顺序刻意的：**未结清上限先判，每日次数后判**。
         *
         * 并发两笔时两道理都会命中，但"你有一笔提现正在处理中"才是**准确且可行动**的提示
         * （负责人要求并发落败方必须看到中文 409 而不是别的）——若先判每日次数，
         * 落败方会收到"今日次数已用完"，用户会以为"今天没机会了"，而实际上
         * 这笔钱正在处理中、处理完当天也未必还能再提（`dailyLimit=1` 的语义是"每日申请次数"，
         * 本笔已经占用了这一次）。先报更具体、更接近资金事实的那一条。
         */
        const pendingRows: Array<{ c: number | string }> = await em.query(
          `SELECT COUNT(1) AS c FROM \`withdraw_request\`
            WHERE \`worker_id\` = ? AND \`status\` = 'pending' FOR UPDATE`,
          [String(worker.id)],
        );
        if (Number(pendingRows?.[0]?.c ?? 0) >= WITHDRAW_PENDING_LIMIT) {
          throw new ConflictException('你有一笔提现正在处理中，请等待管理员处理后再提交');
        }

        // ---- ③ 今日次数（当前读：必须用 FOR UPDATE，别用快照读）----
        const todayRows: Array<{ c: number | string }> = await em.query(
          `SELECT COUNT(1) AS c FROM \`withdraw_request\`
            WHERE \`worker_id\` = ? AND \`created_at\` >= ? AND \`created_at\` < ? FOR UPDATE`,
          [String(worker.id), day.start, day.end],
        );
        const todayUsed = Number(todayRows?.[0]?.c ?? 0);
        if (todayUsed >= cfg.dailyLimit) {
          throw new BadRequestException(
            `今日提现申请次数已用完（每日最多 ${cfg.dailyLimit} 次），请明天再试`,
          );
        }

        // ---- ④ 金额 ≤ 全部余额（锁内余额，权威）----
        if (amount > balance) {
          throw new BadRequestException(`提现金额不能超过当前余额（${fmtYuan(balance)}）`);
        }

        // ---- ⑤ 建申请（先拿 id；幂等键要用它）----
        const ins: { insertId?: number | string } = await em.query(
          `INSERT INTO \`withdraw_request\`
             (\`worker_id\`, \`user_id\`, \`amount\`, \`status\`, \`applied_at\`, \`idempotency_key\`,
              \`created_at\`, \`updated_at\`)
           VALUES (?, ?, ?, 'pending', NOW(3), ?, NOW(3), NOW(3))`,
          [String(worker.id), String(userId), amount.toFixed(2), idemKey],
        );
        const requestId = String(ins?.insertId ?? '');
        if (!requestId) throw new BadRequestException('提现申请创建失败，请重试');

        // ---- ⑥ 立即扣款（同一事务；复用既有余额能力，幂等键 withdraw:<id>）----
        const idem = `withdraw:${requestId}`;
        await this.wallet.withdrawDeductInTx(
          em,
          {
            userId: String(userId),
            amount,
            reason: `提现申请扣款：申请 #${requestId}（${fmtYuan(amount)}）`,
            idempotencyKey: idem,
          },
          { ip: meta.ip, requestId: meta.requestId },
        );
        const txn = await this.walletTransactionOf(em, idem);
        if (!txn) throw new BadRequestException('余额流水写入失败，请重试');

        // ---- ⑦ 条件 UPDATE 回写流水 id（判 affectedRows；不为 1 → 整体回滚）----
        const upd: { affectedRows?: number } = await em.query(
          `UPDATE \`withdraw_request\` SET \`wallet_transaction_id\` = ?
            WHERE \`id\` = ? AND \`status\` = 'pending'`,
          [String(txn.id), requestId],
        );
        if (Number(upd?.affectedRows ?? 0) !== 1) {
          throw new BadRequestException('提现申请状态异常，请重试');
        }

        // ---- ⑧ 站内通知（与扣款同事务：扣款成功就一定有一条"已提交"通知）----
        await em.save(
          em.create(UserNotification, {
            userId: String(userId),
            type: 'withdraw_applied',
            title: '提现申请已提交',
            content: `提现申请已提交：${fmtYuan(amount)} 已从余额扣除，管理员核对后会尽快打款`,
            refId: requestId,
          }),
        );

        const appliedRows: Array<{ appliedAt: Date }> = await em.query(
          'SELECT `applied_at` AS appliedAt FROM `withdraw_request` WHERE `id` = ?',
          [requestId],
        );

        return {
          requestId,
          amount,
          balanceBefore: Number(txn.balanceBefore),
          balanceAfter: Number(txn.balanceAfter),
          transactionNo: String(txn.transactionNo),
          appliedAt: appliedRows?.[0]?.appliedAt ?? new Date(),
        };
      });
    } catch (e) {
      /**
       * 数据库级兜底被触发（并发两笔同时越过第 ③ 步的计数）：
       * `UK_wr_pending_worker` / `UK_wr_idem` 撞唯一键 → 翻译成**中文 409**，不是 500。
       * 资金安全性由唯一键保证（不可能真出现两笔 pending），这里只负责把话说清楚。
       */
      const code = this.dupCode(e);
      if (code) {
        if (idemKey) {
          const dup = await this.requestRepo.findOne({ where: { idempotencyKey: idemKey } });
          if (dup) return this.duplicatedApply(dup);
        }
        throw new ConflictException('你有一笔提现正在处理中，请等待管理员处理后再提交');
      }
      throw e;
    }

    // 提交后再推实时事件（回滚时不该推送）
    this.realtime.emitToUser(userId, 'notification:new', { type: 'withdraw_applied' });
    this.audit({
      adminUserId: null,
      action: 'withdraw:apply',
      method: 'POST',
      path: '/api/v1/worker/withdraw/requests',
      requestBody: {
        requestId: outcome.requestId,
        workerId: String(worker.id),
        userId: String(userId),
        amount: outcome.amount,
        transactionNo: outcome.transactionNo,
        balanceBefore: outcome.balanceBefore,
        balanceAfter: outcome.balanceAfter,
      },
      ip: meta.ip,
      requestId: meta.requestId,
    });
    this.logger.log(
      `提现申请已提交 id=${outcome.requestId} worker=${worker.id} user=${userId} ` +
        `${fmtYuan(outcome.amount)} 余额 ${outcome.balanceBefore}→${outcome.balanceAfter} 流水=${outcome.transactionNo}`,
    );
    return {
      id: outcome.requestId,
      amount: outcome.amount,
      status: 'pending' as const,
      balanceAfter: outcome.balanceAfter,
      appliedAt: outcome.appliedAt,
    };
  }

  /** `GET /worker/withdraw/requests` —— 我的提现记录（金额/状态/申请时间/打款时间/驳回原因） */
  async myRequests(userId: string, page: number, pageSize: number) {
    const worker = await this.workerOf(userId);
    const [list, total] = await this.requestRepo.findAndCount({
      where: { workerId: String(worker.id) },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    const paths = await this.media.pathsByIds(
      list.map((r) => (r.payoutProofMediaId ? String(r.payoutProofMediaId) : '')).filter((x) => x),
    );
    return {
      list: list.map((r) => ({
        id: String(r.id),
        amount: Number(r.amount),
        status: r.status,
        appliedAt: r.appliedAt,
        paidAt: r.paidAt,
        rejectedAt: r.rejectedAt,
        rejectReason: r.rejectReason ?? null,
        /** 打款凭证（本人可见自己的打款凭证；受保护通道） */
        payoutProofUrl: r.payoutProofMediaId ? (paths.get(String(r.payoutProofMediaId)) ?? null) : null,
        payoutNote: r.payoutNote ?? null,
      })),
      total,
      page,
      pageSize,
      pendingCount: await this.pendingCountOf(worker.id),
      balance: await this.balanceOf(userId),
    };
  }

  // ==========================================================================
  // 审核侧（PC 管理端 + App 内「管理员身份」共用）
  // ==========================================================================

  /**
   * 列表（`GET /admin/withdraw/requests` 与 `GET /withdraw/requests` 共用**同一服务层逻辑**）。
   *
   * **收款信息给完整值**（`account`，与详情同名同形；2026-10-11 负责人要求）：
   * 能读到本列表 = 持有 `withdraw:review`（当前只授 `super_admin`），**读取者本身就是审核人**，
   * 向他隐藏完整手机号/微信号只会让"核对收款信息"必须点进详情。
   * `accountMasked` **原样保留**（向后兼容：旧客户端仍只认它）。
   *
   * ⚠️ 合规口径**没有放宽**：**非审核面**（`operation_log.request_body` 摘要、
   * `user_notification` 文案、任何日志）**仍然不得出现完整手机号/微信号** ——
   * PIPL 的合规点是"不向无关方泄露"，不是"向审核人隐藏"。脱敏实现仍是
   * `withdraw-config.ts` 的 `maskPhone` / `maskRealName` / `maskWechatId`（唯一一份）。
   */
  async reviewList(query: WithdrawReviewQuery, page: number, pageSize: number) {
    const qb = this.dataSource
      .createQueryBuilder(WithdrawRequest, 'r')
      .innerJoin(Worker, 'w', 'w.id = r.worker_id')
      .innerJoin(User, 'u', 'u.id = r.user_id');

    const status = String(query.status ?? '').trim();
    if (status && status !== 'all') {
      if (!['pending', 'paid', 'rejected'].includes(status)) {
        throw new BadRequestException('状态筛选值不合法（pending/paid/rejected/all）');
      }
      qb.andWhere('r.status = :status', { status });
    }
    const keyword = String(query.keyword ?? '').trim();
    if (keyword) {
      qb.andWhere('(u.username LIKE :kw OR u.nickname LIKE :kw OR u.uid LIKE :kw OR w.worker_no LIKE :kw)', {
        kw: `%${keyword}%`,
      });
    }
    const start = this.parseTime(query.startTime, '开始时间');
    if (start) qb.andWhere('r.created_at >= :start', { start });
    const end = this.parseTime(query.endTime, '结束时间');
    if (end) qb.andWhere('r.created_at <= :end', { end });

    const total = Number((await qb.clone().select('COUNT(1)', 'cnt').getRawOne())?.cnt ?? 0);
    const list = await qb.orderBy('r.id', 'DESC').offset((page - 1) * pageSize).limit(pageSize).getMany();

    return {
      list: await this.decorate(list),
      total,
      page,
      pageSize,
      pendingTotal: await this.requestRepo.count({ where: { status: 'pending' } }),
    };
  }

  /** `GET .../requests/:id` —— 详情：**完整**姓名/电话/微信号 + 收款码链接 + 打款记录 */
  async detail(requestId: string) {
    const row = await this.requestRepo.findOne({ where: { id: String(requestId) } });
    if (!row) throw new NotFoundException('提现申请不存在');
    const [item] = await this.decorate([row]);
    const account = await this.activeAccountOf(row.workerId);
    const qrUrl = account
      ? ((await this.media.pathsByIds([String(account.qrMediaId)])).get(String(account.qrMediaId)) ?? null)
      : null;
    // 退款反向流水（幂等键确定 → 无需额外列）
    const refundRows: Array<{
      id: string | number;
      transactionNo: string;
      balanceBefore: string | number;
      balanceAfter: string | number;
    }> = await this.dataSource.query(
      `SELECT id, transaction_no AS transactionNo, balance_before AS balanceBefore, balance_after AS balanceAfter
         FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1`,
      [`withdraw_reject:${row.id}`],
    );
    return {
      ...item,
      /** 完整收款信息（与列表行同名同形；读取者持有 `withdraw:review`，本身即审核人） */
      account: account
        ? {
            realName: account.realName,
            phone: account.phone,
            wechatId: account.wechatId,
            qrMediaId: String(account.qrMediaId),
            qrUrl,
            updatedAt: account.updatedAt,
          }
        : null,
      rejectTransaction: refundRows?.[0]
        ? {
            id: String(refundRows[0].id),
            transactionNo: refundRows[0].transactionNo,
            balanceBefore: Number(refundRows[0].balanceBefore),
            balanceAfter: Number(refundRows[0].balanceAfter),
          }
        : null,
    };
  }

  /**
   * 受保护的取图通道（`GET /admin/withdraw/proof/:id?kind=qr|payout` 与
   * `GET /withdraw/proof/:id?kind=…` 共用）。
   *
   * 为什么不直接放行 `/media/*`：`MediaController` 对 `role='admin'` 放行**任意**受保护媒体
   * （聊天图片也在内），而 App 内受限会话的白名单里刻意没有 `/media/*`。
   * 这里把权限面收窄到"这条提现申请对应的收款码 / 打款凭证"（照抄 `/recharge/proof/:requestId`）。
   *
   * - `kind=qr`：该申请**打手当前生效的**收款码（`withdraw_qr`）；
   * - `kind=payout`：该申请的**打款凭证**（`withdraw_proof`，未打款时 404）。
   */
  async proofMedia(requestId: string, kind: string): Promise<Media> {
    const row = await this.requestRepo.findOne({ where: { id: String(requestId) } });
    if (!row) throw new NotFoundException('提现申请不存在');
    const k = String(kind ?? 'qr').trim() || 'qr';
    if (!['qr', 'payout'].includes(k)) {
      throw new BadRequestException('取图类型不合法（kind=qr|payout）');
    }
    if (k === 'qr') {
      const account = await this.activeAccountOf(row.workerId);
      if (!account) throw new NotFoundException('该打手尚未绑定收款信息');
      const media = await this.mediaRepo.findOne({ where: { id: String(account.qrMediaId) } });
      if (!media) throw new NotFoundException('收款码不存在');
      return media;
    }
    if (!row.payoutProofMediaId) throw new NotFoundException('该申请还没有打款凭证');
    const media = await this.mediaRepo.findOne({ where: { id: String(row.payoutProofMediaId) } });
    if (!media) throw new NotFoundException('打款凭证不存在');
    return media;
  }

  /**
   * `POST /withdraw/requests/:id/pay-proof` —— **受限会话也能用的打款凭证上传通道**（2026-10-11 新增）。
   *
   * ## 为什么必须单开一条（而不是复用 `/media/upload`）
   *
   * App 内「管理员身份」= 受限会话 `kind='recharge'`，白名单（`isRechargeAdminAllowedRoute`）
   * **刻意不含 `/media/*`** —— `/media/protected/:id` 对 `role='admin'` 放行**任意**受保护媒体
   * （聊天图片也在内），受限会话不该拿到这个面。于是把上传能力**收窄到"这一张申请"**：
   * 路径落在已被放行的 `/withdraw/*` 前缀内（**白名单一条都不用加**，更没放宽 `/media/*`），
   * 权限面 = `withdraw:pay` + 该申请必须 `pending`。
   *
   * 这与读取侧 `proofMedia()`（`GET /withdraw/proof/:id?kind=payout`）是**同一套取舍**：
   * 一读一写都钉死在"这张申请"上。
   *
   * ## 校验（沿用既有实现，不自创第二套）
   *
   * 1. 会话：`RechargeSessionGuard`（复用**同一个** `checkRechargeSession`）+ `@Roles('admin')`
   *    —— 老板/打手 primary 一律 403；
   * 2. 申请：必须存在（否则中文 404，**不泄漏存在性**）且处于 `pending`
   *    —— 已被 pay 掉的申请再传 → **中文 400「该申请已打款」**（状态机单向）；
   * 3. 文件：**沿用 `MediaService.upload` 的既有校验**（用途白名单 → 大小 → 魔数 → 重编码剥离负载），
   *    用途**固定 `withdraw_proof`（protected）**，客户端不可指定 `type`；
   * 4. 审计：`operation_log` 写"谁传的、哪张申请、media id"——**不落文件内容**。
   *
   * ## 并发/幂等
   *
   * - **同一申请重复上传 → 允许**：后传的成为新凭证（条件 UPDATE 覆盖 `payout_proof_media_id`），
   *   **每次上传都单独留痕**；
   * - 先读状态、再落盘、最后**条件 UPDATE 判 `affectedRows`**（`WHERE id=? AND status='pending'`）：
   *   与 pay/reject 同一条姿势 —— 读的时候还在 pending、写的时候已被 pay 掉 → 命中 0 行 → 中文 400，
   *   **不会**把凭证贴到一张已打款的单子上；
   * - 落盘在校验之后（已打款的申请不会产生文件）；极小概率的"落盘成功但条件 UPDATE 落败"
   *   只会留下一条**未被任何业务引用**的媒体行（受保护、仅上传者与管理员可读），不构成越权面。
   *
   * ## 返回
   *
   * `{ mediaId, url }`：`url` 是**既有的受保护取图约定**（`/api/v1/media/protected/:id`，
   * `MediaService.clientPath()` 一条实现），**绝不返回磁盘路径**；
   * App 侧带受限会话令牌实际取图走按申请收窄的 `GET /withdraw/proof/:id?kind=payout`。
   */
  async uploadPayProof(
    requestId: string,
    adminUserId: string,
    file: { buffer?: Buffer; originalname?: string; size?: number } | undefined,
    meta: WithdrawMeta,
  ) {
    if (!file?.buffer || file.buffer.length === 0) {
      throw new BadRequestException('请选择要上传的打款凭证图片');
    }

    // ① 申请必须存在且仍在 pending（**先判再落盘**：已打款的申请不该产生文件）
    const row = await this.requestRepo.findOne({ where: { id: String(requestId) } });
    if (!row) throw new NotFoundException('提现申请不存在');
    if (row.status !== 'pending') {
      throw new BadRequestException(
        row.status === 'paid' ? '该申请已打款' : '该申请已驳回，不能上传打款凭证',
      );
    }

    // ② 既有媒体校验（用途固定 withdraw_proof / protected；客户端指定的 type 一律不采信）
    const media = await this.media.upload(
      file.buffer,
      String(file.originalname ?? ''),
      'withdraw_proof',
      String(adminUserId),
    );

    // ③ 条件 UPDATE 判 affectedRows ——"这张单子还能不能贴凭证"的唯一判定点
    const upd: { affectedRows?: number } = await this.dataSource.query(
      `UPDATE \`withdraw_request\` SET \`payout_proof_media_id\` = ?, \`updated_at\` = NOW(3)
        WHERE \`id\` = ? AND \`status\` = 'pending'`,
      [String(media.id), String(row.id)],
    );
    if (Number(upd?.affectedRows ?? 0) !== 1) {
      // 复核状态**只为了给准确的中文文案**（判定已在上面的 affectedRows 完成）
      const cur: Array<{ status: string }> = await this.dataSource.query(
        'SELECT `status` FROM `withdraw_request` WHERE `id` = ?',
        [String(row.id)],
      );
      const st = String(cur?.[0]?.status ?? '');
      throw new BadRequestException(
        st === 'paid' ? '该申请已打款' : '该申请状态异常，无法上传打款凭证',
      );
    }

    const url = this.media.clientPath(media);
    this.audit({
      adminUserId: String(adminUserId),
      action: 'withdraw:pay-proof',
      method: 'POST',
      path: `/api/v1/withdraw/requests/${row.id}/pay-proof`,
      requestBody: {
        requestId: String(row.id),
        workerId: String(row.workerId),
        mediaId: String(media.id),
        mediaType: media.mediaType,
        mimeType: media.mimeType,
        sizeBytes: Number(media.sizeBytes ?? 0),
        originalName: String(media.originalName ?? '').slice(0, 120),
        source: meta.source ?? null,
      },
      ip: meta.ip,
      requestId: meta.requestId,
    });
    this.logger.log(
      `提现打款凭证已上传 request=${row.id} media=${media.id} by=${adminUserId}（用途 withdraw_proof/protected）`,
    );
    return { mediaId: String(media.id), url };
  }

  /**
   * `POST .../requests/:id/pay` —— **打款**（资金安全三件套的第 ② ③ 条在这里落地）。
   *
   * 关键设计（**别再退回"先 assertPending 再 UPDATE"的写法**）：
   * `SELECT … FOR UPDATE` 只用于**串行化**与"申请不存在→404"；
   * **"这笔能不能打款"的唯一判定点是那条条件 UPDATE 的 `affectedRows`**
   * （`WHERE id=? AND status='pending'`）。因此：
   * - 并发两个 pay → 行锁排队，后到者的 UPDATE 命中 0 行 → 中文 400「该申请已打款」；
   * - 重复点击 pay → 同上，**不产生第二次打款记录**；
   * - 把这条 UPDATE 的 `AND status='pending'` 去掉（变异验证）→ 重复调用会"成功"，测试立刻变红。
   *
   * 打款本身是**平台外的人工转账**（微信），系统只回填凭证 + 结论：没有代付 API、没有回调。
   */
  async pay(
    requestId: string,
    adminUserId: string,
    dto: { proofMediaId?: string; note?: string },
    meta: WithdrawMeta,
  ) {
    const proofId = String(dto?.proofMediaId ?? '').trim();
    const note = String(dto?.note ?? '').trim().slice(0, 200);
    /**
     * **凭证必填、备注可选**（2026-10-11 收紧；别再退回"凭证或备注至少一条"）。
     *
     * 旧口径的由来是**客观限制**：App 内「管理员身份」是受限会话，白名单里没有 `/media/*`
     * → 传不了图，只好退化成"用备注留证据"。现在 App 有了专用上传通道
     * （`POST /withdraw/requests/:id/pay-proof` → 见本文件 `uploadPayProof()`），
     * "没图"不再是限制，因此校验收紧为**必须有 `proofMediaId`**。
     *
     * ⚠️ **校验收口在唯一一处**（本方法，PC 与 App 两条入口共用）→ **以更严的为准**：
     * `POST /admin/withdraw/requests/:id/pay`（PC）同样要求带凭证 —— 它本来就能传图
     * （`/admin/media/upload`，type=`withdraw_proof`），此前"只填备注"的用法一并关闭。
     */
    if (!proofId) {
      throw new BadRequestException('请上传打款凭证');
    }
    // 凭证媒体校验（用途白名单 + 必须是图片）：与上传通道同一份约束，防止"拿任意图片当凭证"
    const proofMedia = await this.mediaRepo.findOne({ where: { id: proofId } });
    if (!proofMedia) throw new BadRequestException('打款凭证不存在，请重新上传');
    if (!String(proofMedia.mimeType ?? '').startsWith('image/')) {
      throw new BadRequestException('打款凭证必须是图片');
    }
    if (proofMedia.mediaType !== 'withdraw_proof') {
      throw new BadRequestException('打款凭证请使用提现打款凭证上传（type=withdraw_proof）');
    }

    const outcome = await this.dataSource.transaction(async (em: EntityManager) => {
      const row = await this.lockRequest(em, requestId);
      // ⚠️ 刻意**不**在这里判 status：唯一判定点是下面那条条件 UPDATE 的 affectedRows
      const res: { affectedRows?: number } = await em.query(
        `UPDATE \`withdraw_request\`
            SET \`status\` = 'paid', \`paid_at\` = NOW(3), \`paid_by\` = ?,
                \`payout_proof_media_id\` = ?, \`payout_note\` = ?
          WHERE \`id\` = ? AND \`status\` = 'pending'`,
        [String(adminUserId), proofId, note || null, String(row.id)],
      );
      if (Number(res?.affectedRows ?? 0) !== 1) {
        // 复核当前状态**只为了给出准确的中文文案**（判定已在上面的 affectedRows 完成）
        const cur: Array<{ status: string }> = await em.query(
          'SELECT `status` FROM `withdraw_request` WHERE `id` = ?',
          [String(row.id)],
        );
        const st = String(cur?.[0]?.status ?? '');
        throw new BadRequestException(
          st === 'paid'
            ? '该申请已打款'
            : st === 'rejected'
              ? '该申请已驳回，不能打款'
              : '该申请状态异常，无法打款',
        );
      }

      await em.save(
        em.create(UserNotification, {
          userId: String(row.userId),
          type: 'withdraw_paid',
          title: '提现已打款',
          content: `提现已打款：${fmtYuan(Number(row.amount))}，请查收微信转账`,
          refId: String(row.id),
        }),
      );
      return {
        requestId: String(row.id),
        userId: String(row.userId),
        amount: Number(row.amount),
      };
    });

    this.realtime.emitToUser(outcome.userId, 'notification:new', { type: 'withdraw_paid' });
    this.audit({
      adminUserId: String(adminUserId),
      action: 'withdraw:pay',
      method: 'POST',
      path: `/api/v1/*/withdraw/requests/${outcome.requestId}/pay`,
      requestBody: {
        requestId: outcome.requestId,
        amount: outcome.amount,
        proofMediaId: proofId,
        note: note || null,
        source: meta.source ?? null,
      },
      ip: meta.ip,
      requestId: meta.requestId,
    });
    this.logger.log(
      `提现已打款 id=${outcome.requestId} user=${outcome.userId} ${fmtYuan(outcome.amount)} by=${adminUserId}`,
    );
    return {
      ok: true,
      id: outcome.requestId,
      status: 'paid' as const,
      amount: outcome.amount,
      paidAt: new Date(),
    };
  }

  /**
   * `POST .../requests/:id/reject` —— 驳回：**退回余额 + 反向流水**（`withdraw_reject`）。
   *
   * 与 `pay` 同构：条件 UPDATE 是唯一判定点；**通过之后**才在同一事务里退回，
   * 因此"重复驳回"不可能退两次（第二次 affectedRows=0 → 中文 400 → 整体回滚，退款不发生），
   * 外加幂等键 `withdraw_reject:<id>` 的唯一约束兜底。
   */
  async reject(requestId: string, adminUserId: string, reason: string, meta: WithdrawMeta) {
    const trimmed = String(reason ?? '').trim();
    if (!trimmed) throw new BadRequestException('请填写驳回原因');
    if (trimmed.length > 200) throw new BadRequestException('驳回原因最多 200 字');

    const outcome = await this.dataSource.transaction(async (em: EntityManager) => {
      const row = await this.lockRequest(em, requestId);
      const res: { affectedRows?: number } = await em.query(
        `UPDATE \`withdraw_request\`
            SET \`status\` = 'rejected', \`rejected_at\` = NOW(3), \`rejected_by\` = ?, \`reject_reason\` = ?
          WHERE \`id\` = ? AND \`status\` = 'pending'`,
        [String(adminUserId), trimmed, String(row.id)],
      );
      if (Number(res?.affectedRows ?? 0) !== 1) {
        const cur: Array<{ status: string }> = await em.query(
          'SELECT `status` FROM `withdraw_request` WHERE `id` = ?',
          [String(row.id)],
        );
        const st = String(cur?.[0]?.status ?? '');
        throw new BadRequestException(
          st === 'paid'
            ? '该申请已打款，不能驳回'
            : st === 'rejected'
              ? '该申请已驳回，不能重复操作'
              : '该申请状态异常，无法驳回',
        );
      }

      // 退回余额（同一事务；复用既有余额能力，幂等键 withdraw_reject:<id>）
      const amount = Number(row.amount);
      const idem = `withdraw_reject:${row.id}`;
      await this.wallet.withdrawRefundInTx(
        em,
        String(adminUserId),
        {
          userId: String(row.userId),
          amount,
          reason: `提现驳回退回：申请 #${row.id}（${fmtYuan(amount)}）原因：${trimmed}`,
          idempotencyKey: idem,
        },
        { ip: meta.ip, requestId: meta.requestId },
      );
      const txn = await this.walletTransactionOf(em, idem);
      if (!txn) throw new BadRequestException('余额退回流水写入失败，请重试');

      await em.save(
        em.create(UserNotification, {
          userId: String(row.userId),
          type: 'withdraw_rejected',
          title: '提现被驳回',
          content: `提现被驳回：${fmtYuan(amount)} 已退回余额，原因：${trimmed}`,
          refId: String(row.id),
        }),
      );
      return {
        requestId: String(row.id),
        userId: String(row.userId),
        amount,
        transactionNo: String(txn.transactionNo),
        balanceBefore: Number(txn.balanceBefore),
        balanceAfter: Number(txn.balanceAfter),
      };
    });

    this.realtime.emitToUser(outcome.userId, 'notification:new', { type: 'withdraw_rejected' });
    this.audit({
      adminUserId: String(adminUserId),
      action: 'withdraw:reject',
      method: 'POST',
      path: `/api/v1/*/withdraw/requests/${outcome.requestId}/reject`,
      requestBody: {
        requestId: outcome.requestId,
        amount: outcome.amount,
        reason: trimmed,
        refundTransactionNo: outcome.transactionNo,
        balanceBefore: outcome.balanceBefore,
        balanceAfter: outcome.balanceAfter,
        source: meta.source ?? null,
      },
      ip: meta.ip,
      requestId: meta.requestId,
    });
    this.logger.log(
      `提现已驳回 id=${outcome.requestId} user=${outcome.userId} ${fmtYuan(outcome.amount)} 已退回 ` +
        `余额 ${outcome.balanceBefore}→${outcome.balanceAfter} 流水=${outcome.transactionNo} by=${adminUserId}`,
    );
    return {
      ok: true,
      id: outcome.requestId,
      status: 'rejected' as const,
      amount: outcome.amount,
      rejectReason: trimmed,
      refunded: true,
      transactionNo: outcome.transactionNo,
      balanceAfter: outcome.balanceAfter,
    };
  }

  // ==========================================================================
  // 配置写入（仅超管；调用方已按 is_high_security 校验角色）
  // ==========================================================================

  /**
   * `PUT /admin/withdraw/config`：门槛/次数/费率/文案（**仅超管**）。
   *
   * 两步都在：① 本方法先 `assertWithdrawConfig` 做中文 400 校验（给管理端即时反馈）；
   * ② `SystemSettingService.update()` 的 `is_high_security=1` 闸门做**权威**的仅超管判定
   * （且 `validate()` 按 key 再复核一次取值）。读侧无缓存 → 保存即生效，无需失效钩子。
   */
  async saveConfig(
    body: Record<string, unknown>,
    actor: { userId: string; ip: string; requestId: string | null; method: string; path: string },
    roleCode: string | null,
  ) {
    const cur = await this.config();
    const cfg = assertWithdrawConfig({
      minAmount: body['minAmount'] ?? cur.minAmount,
      maxAmount: body['maxAmount'] ?? cur.maxAmount,
      dailyLimit: body['dailyLimit'] ?? cur.dailyLimit,
      feeRate: body['feeRate'] ?? cur.feeRate,
      noticeText: body['noticeText'] ?? cur.noticeText,
    });
    await this.settings.update(WITHDRAW_CONFIG_KEY, { value: cfg }, WITHDRAW_CONFIG_DESCRIPTION, roleCode, actor);
    const changedKeys = (['minAmount', 'maxAmount', 'dailyLimit', 'feeRate', 'noticeText'] as const).filter(
      (k) =>
        JSON.stringify((cur as unknown as Record<string, unknown>)[k]) !==
        JSON.stringify((cfg as unknown as Record<string, unknown>)[k]),
    );
    this.audit({
      adminUserId: actor.userId,
      action: 'withdraw:config:update',
      method: actor.method,
      path: actor.path,
      requestBody: {
        changedKeys,
        before: {
          minAmount: cur.minAmount,
          maxAmount: cur.maxAmount,
          dailyLimit: cur.dailyLimit,
          feeRate: cur.feeRate,
          noticeText: String(cur.noticeText ?? '').slice(0, 200),
        },
        after: {
          minAmount: cfg.minAmount,
          maxAmount: cfg.maxAmount,
          dailyLimit: cfg.dailyLimit,
          feeRate: cfg.feeRate,
          noticeText: String(cfg.noticeText ?? '').slice(0, 200),
        },
      },
      ip: actor.ip,
      requestId: actor.requestId,
    });
    return { ok: true, ...cfg };
  }

  // ==========================================================================
  // 内部
  // ==========================================================================

  /** 打手档案（按 JWT sub 反查）；无档案 / 已停用 → 403 中文（与既有工作端口径一致） */
  private async workerOf(userId: string): Promise<Worker> {
    const worker = await this.workerRepo.findOne({ where: { userId: String(userId) } });
    if (!worker) throw new ForbiddenException('工作端不存在，无法提现');
    if (Number(worker.status) !== 1) throw new ForbiddenException('工作端已停用，无法提现');
    return worker;
  }

  /** 该打手当前生效的收款信息（同一打手最多一行 active，由唯一键保证） */
  private async activeAccountOf(workerId: string): Promise<WorkerWithdrawAccount | null> {
    return this.accountRepo.findOne({ where: { workerId: String(workerId), status: 'active' } });
  }

  /** 余额（权威读库；与钱包同一张表） */
  private async balanceOf(userId: string): Promise<number> {
    const rows: Array<{ balance: string | number }> = await this.dataSource.query(
      'SELECT `balance` FROM `wallet` WHERE `user_id` = ? LIMIT 1',
      [String(userId)],
    );
    return Number(rows?.[0]?.balance ?? 0);
  }

  /** 今日（北京时间）已用申请次数 */
  private async todayCountOf(workerId: string): Promise<number> {
    const day = shanghaiDayRange();
    const rows: Array<{ c: number | string }> = await this.dataSource.query(
      `SELECT COUNT(1) AS c FROM \`withdraw_request\`
        WHERE \`worker_id\` = ? AND \`created_at\` >= ? AND \`created_at\` < ?`,
      [String(workerId), day.start, day.end],
    );
    return Number(rows?.[0]?.c ?? 0);
  }

  /** 未结清（pending）申请数 */
  private async pendingCountOf(workerId: string): Promise<number> {
    return this.requestRepo.count({ where: { workerId: String(workerId), status: 'pending' } });
  }

  /** 幂等命中：返回**首次结果**（余额取首次那笔流水的 after，语义是"这一笔的效果"） */
  private async duplicatedApply(row: WithdrawRequest) {
    const txnRows: Array<{ balanceBefore: string | number; balanceAfter: string | number; transactionNo: string }> =
      row.walletTransactionId
        ? await this.dataSource.query(
            `SELECT balance_before AS balanceBefore, balance_after AS balanceAfter, transaction_no AS transactionNo
               FROM wallet_transaction WHERE id = ? LIMIT 1`,
            [String(row.walletTransactionId)],
          )
        : [];
    return {
      id: String(row.id),
      amount: Number(row.amount),
      status: row.status,
      balanceAfter: Number(txnRows?.[0]?.balanceAfter ?? (await this.balanceOf(row.userId))),
      appliedAt: row.appliedAt,
      duplicated: true,
    };
  }

  /** 行锁 + 取出申请（不存在 → 404 中文） */
  private async lockRequest(em: EntityManager, requestId: string): Promise<RequestRow> {
    const rows: RequestRow[] = await em.query(
      `SELECT id, worker_id AS workerId, user_id AS userId, amount, status,
              applied_at AS appliedAt, paid_at AS paidAt, paid_by AS paidBy,
              payout_proof_media_id AS payoutProofMediaId, payout_note AS payoutNote,
              rejected_at AS rejectedAt, rejected_by AS rejectedBy, reject_reason AS rejectReason,
              wallet_transaction_id AS walletTransactionId, idempotency_key AS idempotencyKey
         FROM \`withdraw_request\` WHERE id = ? FOR UPDATE`,
      [String(requestId)],
    );
    const row = rows?.[0];
    if (!row) throw new NotFoundException('提现申请不存在');
    return row;
  }

  /** 按幂等键回读流水（同一事务内 → 必然是本步刚写的那条） */
  private async walletTransactionOf(
    em: EntityManager,
    idempotencyKey: string,
  ): Promise<
    | { id: string | number; transactionNo: string; balanceBefore: string | number; balanceAfter: string | number }
    | null
  > {
    const rows = await em.query(
      `SELECT id, transaction_no AS transactionNo, balance_before AS balanceBefore, balance_after AS balanceAfter
         FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1`,
      [idempotencyKey],
    );
    return rows?.[0] ?? null;
  }

  /** 列表补展示字段：打手昵称/工号/中文 ID、收款信息（**完整 + 脱敏两份**）、打款人与凭证 url */
  private async decorate(list: WithdrawRequest[]) {
    if (!list.length) return [];
    const workerIds = [...new Set(list.map((r) => String(r.workerId)))];
    const workers: Array<{
      id: string | number;
      userId: string | number;
      workerNo: string;
      username: string;
      nickname: string;
      uid: string;
    }> = await this.dataSource.query(
      `SELECT w.id, w.user_id AS userId, w.worker_no AS workerNo, u.username, u.nickname, u.uid
         FROM worker w JOIN user u ON u.id = w.user_id WHERE w.id IN (?)`,
      [workerIds],
    );
    const workerMap = new Map(workers.map((w) => [String(w.id), w]));
    const accounts = await this.accountRepo
      .createQueryBuilder('a')
      .where('a.worker_id IN (:...ids)', { ids: workerIds })
      .andWhere("a.status = 'active'")
      .getMany();
    const accountMap = new Map(accounts.map((a) => [String(a.workerId), a]));
    const adminIds = [
      ...new Set(
        list
          .flatMap((r) => [r.paidBy, r.rejectedBy])
          .filter((x): x is string => x !== null && x !== undefined)
          .map((x) => String(x)),
      ),
    ];
    const admins: Array<{ id: string | number; nickname: string }> = adminIds.length
      ? await this.dataSource.query('SELECT id, nickname FROM user WHERE id IN (?)', [adminIds])
      : [];
    const adminMap = new Map(admins.map((a) => [String(a.id), a.nickname]));
    const paths = await this.media.pathsByIds(
      list.map((r) => (r.payoutProofMediaId ? String(r.payoutProofMediaId) : '')).filter((x) => x),
    );

    return list.map((r) => {
      const w = workerMap.get(String(r.workerId));
      const a = accountMap.get(String(r.workerId));
      return {
        id: String(r.id),
        workerId: String(r.workerId),
        userId: String(r.userId),
        workerNo: w?.workerNo ?? '',
        workerNickname: w?.nickname ?? '',
        username: w?.username ?? '',
        uid: w?.uid ?? '',
        amount: Number(r.amount),
        /** 字段别名（前端契约用 `amount`；两个名字同值，避免前端猜字段名） */
        amountYuan: Number(r.amount),
        status: r.status,
        appliedAt: r.appliedAt,
        paidAt: r.paidAt,
        paidBy: r.paidBy === null || r.paidBy === undefined ? null : String(r.paidBy),
        payerName: r.paidBy ? (adminMap.get(String(r.paidBy)) ?? '') : '',
        payoutProofMediaId:
          r.payoutProofMediaId === null || r.payoutProofMediaId === undefined
            ? null
            : String(r.payoutProofMediaId),
        payoutProofUrl: r.payoutProofMediaId ? (paths.get(String(r.payoutProofMediaId)) ?? null) : null,
        payoutNote: r.payoutNote ?? null,
        rejectedAt: r.rejectedAt,
        rejectedBy: r.rejectedBy === null || r.rejectedBy === undefined ? null : String(r.rejectedBy),
        rejectReason: r.rejectReason ?? null,
        walletTransactionId:
          r.walletTransactionId === null || r.walletTransactionId === undefined
            ? null
            : String(r.walletTransactionId),
        idempotencyKey: r.idempotencyKey ?? null,
        /**
         * **完整**收款信息（与详情 `account` **同名同形**，只取三个展示字段）。
         *
         * 2026-10-11 负责人要求：列表也要能看到全部收款信息（此前只能看到
         * `陈* · 139****5528 · ay****17`，核对必须点进详情）。**权限点没有任何变化**
         * （能读列表 = 有 `withdraw:review` = 审核人本身），也**没有**新增权限点。
         */
        account: a
          ? {
              realName: a.realName,
              phone: a.phone,
              wechatId: a.wechatId,
            }
          : null,
        /** 收款信息**脱敏**（**原样保留**：旧客户端只认这个字段，向后兼容不破坏） */
        accountMasked: a
          ? {
              realName: maskRealName(a.realName),
              phone: maskPhone(a.phone),
              wechatId: maskWechatId(a.wechatId),
            }
          : null,
        hasAccount: !!a,
      };
    });
  }

  /** ISO 时间解析（管理端 n-date-picker 下发 ISO；非法 → 中文 400，不静默忽略筛选） */
  private parseTime(raw: string | undefined, label: string): Date | null {
    const v = String(raw ?? '').trim();
    if (!v) return null;
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) throw new BadRequestException(`${label}格式不正确`);
    return d;
  }

  /** 唯一键冲突识别（并发撞 `UK_wr_pending_worker` / `UK_wr_idem`） */
  private dupCode(e: unknown): string | null {
    const err = e as { code?: string; driverError?: { code?: string }; errno?: number };
    const code = err?.code ?? err?.driverError?.code ?? null;
    if (code === 'ER_DUP_ENTRY') return code;
    return null;
  }

  /**
   * 审计留痕（`operation_log`）。
   *
   * 打手侧动作（申请/绑定/换绑）`adminUserId` 传 **null**（操作者不是管理员），
   * 但**照样留痕**——`OperationLogInput.adminUserId` 的注释写得很清楚：
   * 拿不到"谁"的场合也宁可写 null 也要写下"改了什么"（留痕缺失比留痕不完整危险得多）。
   * 管理员动作（打款/驳回/改配置）带 `adminUserId`。
   * `requestBody` 只记关键字段与**前后值摘要**，**不记密码/token**（docs/09）。
   */
  private audit(input: {
    adminUserId: string | null;
    action: string;
    method: string;
    path: string;
    requestBody: Record<string, unknown>;
    ip: string;
    requestId: string | null;
  }): void {
    this.opLog.log({
      adminUserId: input.adminUserId,
      adminName: '',
      module: 'withdraw',
      action: input.action.slice(0, 64),
      method: input.method,
      path: input.path,
      requestBody: JSON.stringify(input.requestBody).slice(0, 4000),
      ip: input.ip,
      requestId: input.requestId || null,
      result: 'success',
    });
  }
}
