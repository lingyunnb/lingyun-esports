import {
  BadRequestException,
  ForbiddenException,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, Repository } from 'typeorm';

import { RateLimitService } from '../../common/rate-limit.service';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { AuthService } from '../auth/auth.service';
import { UserNotification } from '../friend/user-notification.entity';
import { Media } from '../media/media.entity';
import { MediaService } from '../media/media.service';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { WalletService } from '../wallet/wallet.service';
import {
  RECHARGE_ADMIN_LIMIT_MAX,
  RECHARGE_BIND_RATE_LIMIT,
  RECHARGE_BIND_RATE_WINDOW_SECONDS,
  RECHARGE_CONFIG_DEFAULT,
  RECHARGE_CONFIG_KEY,
  RechargeConfig,
  parseRechargeConfig,
} from './recharge-config';
import { RechargeAdmin } from './recharge-admin.entity';
import { RechargeQrCode } from './recharge-qr-code.entity';
import { RechargeRequest } from './recharge-request.entity';

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
export const RECHARGE_CONFIG_PUBLIC_PATH = '/api/v1/public/recharge/config';

/** 一条申请最多能提交的待审核数量统计口径：只数 `status='pending'`（已发放/已驳回不占额度） */
const PENDING_STATUS = 'pending';

/** 数据库行（原生查询的列名是 snake_case，这里显式声明避免 any） */
interface RequestRow {
  id: string | number;
  userId: string | number;
  amountYuan: string | number;
  points: number | string;
  qrId: string | number | null;
  proofMediaId: string | number;
  note: string;
  status: string;
  rejectReason: string | null;
  reviewedBy: string | number | null;
  reviewedAt: Date | null;
  walletTransactionId: string | number | null;
  createdAt: Date;
}

/** 管理端/受限会话列表项（含老板昵称与中文 ID、凭证 url） */
export interface ReviewListItem {
  id: string;
  userId: string;
  username: string;
  nickname: string;
  uid: string;
  amountYuan: number;
  /** 与管理端前端 `RechargeRequestRow.amount` 同名别名（值 = amountYuan） */
  amount: number;
  points: number;
  qrId: string | null;
  qrLabel: string | null;
  /** 凭证媒体 id（管理端用它走 `/media/protected/:id`；受限会话走 `/recharge/proof/:id`） */
  proofMediaId: string;
  /** 前端契约别名（= proofMediaId，避免前端再猜字段名） */
  voucherMediaId: string;
  proofUrl: string | null;
  note: string;
  status: string;
  rejectReason: string | null;
  reviewedBy: string | null;
  /** 审核人展示名（管理端表格"审核人"列；用户端不下发） */
  reviewerName: string;
  reviewedAt: Date | null;
  walletTransactionId: string | null;
  createdAt: Date;
}

/** 审核侧列表筛选（管理端契约：status/keyword/startTime/endTime/page/pageSize） */
export interface ReviewQuery {
  status?: string;
  keyword?: string;
  startTime?: string;
  endTime?: string;
}

/** 发放/驳回操作元信息（IP / requestId 进钱包流水，与既有 `WalletOpMeta` 同口径） */
export interface ReviewMeta {
  ip: string;
  requestId: string;
}

/**
 * 充值（线下收款 + 人工审核）核心服务 —— **合规红线见 CLAUDE.md 结构规则 12**。
 *
 * ## 这个服务**不做**什么（与"做了什么"同等重要）
 *
 * - **不接任何支付通道**：没有支付 SDK/下单/回调/查询接口，代码里没有"支付成功"这类状态；
 * - **不做自动到账**：`status='granted'` **只能**由管理员在 `grant()` 里手工触发；
 * - **不做提现**：没有任何"余额兑回现金"的路径（用户不能自行充值、不能自行提现，docs/06 铁律不变）；
 * - **平台不经手资金**：金额是老板**自己填的**，平台既不收款也不退款，只根据人工核对结果记账。
 *
 * ## 幂等（一张申请只能发放一次）—— 三层，缺一不可
 *
 * 1. **事务 + 行锁**：`SELECT ... FROM recharge_request WHERE id=? FOR UPDATE`，
 *    拿到锁后校验 `status='pending'`；并发两个 grant 会被串行化，后者看到 granted → 中文 400；
 * 2. **条件 UPDATE 判 affectedRows**：`UPDATE ... WHERE id=? AND status='pending'`，
 *    `affectedRows !== 1` → 回滚 + 中文 400「该申请已发放」（防"锁之外"的写路径）；
 * 3. **唯一约束兜底**：`wallet_transaction.idempotency_key = 'recharge:' + requestId`（唯一）
 *    + `recharge_request.UK_rqr_wallet_txn`（唯一）—— 即便前两层都被绕过，数据库也不允许重复加分。
 *
 * ## 审计（谁、什么时候、发了多少、对应哪笔流水）
 *
 * `reviewed_by`（发放人）+ `reviewed_at`（时间）+ `wallet_transaction_id`（流水 id）
 * → 顺着流水还能拿到**前后余额快照**（`wallet_transaction.balance_before/after`）。
 *
 * ## 余额逻辑复用（**不新写一套**）
 *
 * 走 `WalletService.grantInTx()` —— 与超管在管理端发余额**同一个函数、同一条流水实现**
 * （事务内行锁钱包 → 校验 → 改余额 → 写前后余额快照 → 幂等键唯一约束兜底）。
 * 本服务不自己 UPDATE `wallet`，也不自己拼 `wallet_transaction`。
 */
@Injectable()
export class RechargeService {
  private readonly logger = new Logger('Recharge');

  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(RechargeQrCode) private readonly qrRepo: Repository<RechargeQrCode>,
    @InjectRepository(RechargeRequest) private readonly requestRepo: Repository<RechargeRequest>,
    @InjectRepository(RechargeAdmin) private readonly adminRepo: Repository<RechargeAdmin>,
    @InjectRepository(Media) private readonly mediaRepo: Repository<Media>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
    private readonly wallet: WalletService,
    private readonly media: MediaService,
    private readonly auth: AuthService,
    private readonly rateLimit: RateLimitService,
    private readonly realtime: RealtimeGateway,
  ) {}

  // ==========================================================================
  // 配置
  // ==========================================================================

  /**
   * 读配置（**每次实时读库，无缓存**）。
   *
   * 单行主键读（`setting_key` 唯一索引），实测约 2ms；换来的语义是"管理端改完**下一次请求**即生效"，
   * 与 `worker_binding_max_per_boss` / `platform_commission_rate` 同口径。
   * 库里那一行被写坏时按字段回落默认值（读侧兜底），不把运营手误放大成整页 500。
   */
  async config(): Promise<RechargeConfig> {
    const row = await this.settings.get(RECHARGE_CONFIG_KEY);
    if (!row) {
      this.logger.warn(`配置 ${RECHARGE_CONFIG_KEY} 缺失，本次读侧回落全量默认值`);
      return { ...RECHARGE_CONFIG_DEFAULT };
    }
    return parseRechargeConfig(row.cfgValue?.['value']);
  }

  /**
   * `GET /public/recharge/config` —— 老板端「充值」页的数据源。
   *
   * 只回**展示与校验所需**的字段：金额档位、是否允许自定义、自定义上下限、换算比例、
   * 每人待审上限、说明文案、启用中的收款码（含 url）。
   * **不回的字段**：`adminLimit`（受限管理员上限是内部治理参数，与老板无关，不下发）。
   */
  async publicConfig() {
    const cfg = await this.config();
    const qrCodes = await this.qrRepo.find({
      where: { enabled: 1 },
      order: { sort: 'ASC', id: 'ASC' },
    });
    const paths = await this.media.pathsByIds(qrCodes.map((q) => String(q.mediaId)));
    return {
      amountOptions: cfg.amountOptions,
      customEnabled: cfg.customEnabled,
      minYuan: cfg.minYuan,
      maxYuan: cfg.maxYuan,
      pointsPerYuan: cfg.pointsPerYuan,
      pendingLimitPerUser: cfg.pendingLimitPerUser,
      noticeText: cfg.noticeText,
      qrCodes: qrCodes.map((q) => ({
        id: String(q.id),
        channel: q.channel,
        label: q.label,
        // 相对路径（与既有媒体口径一致：客户端按自身 API 主机解析，docs/11 环境无关）
        url: paths.get(String(q.mediaId)) ?? null,
      })),
    };
  }

  /** 失效公开配置的进程内微缓存（写路径必须调用，否则运营"改完像没生效"） */
  invalidatePublicConfigCache(): void {
    PublicCacheInterceptor.invalidate(RECHARGE_CONFIG_PUBLIC_PATH);
  }

  // ==========================================================================
  // 用户侧（老板态）
  // ==========================================================================

  /**
   * `POST /user/recharge/requests` —— 提交充值申请。
   *
   * 校验顺序（全部中文 400，**主体 id 只取 JWT sub**）：
   * 1. 金额：必须命中档位，或（开了自定义时）落在 [minYuan, maxYuan]；
   * 2. 换算：`points = round(amountYuan × pointsPerYuan, 2)`，必须 > 0；
   * 3. 凭证：`proofMediaId` 必填，且**必须是本人上传的图片**（复用媒体归属校验，防拿别人的截图）；
   * 4. 收款码：`qrId` 若传了必须存在且启用（不强制：老板可能先付款后回来补单）；
   * 5. 待审核上限：`status='pending'` 的条数 `< pendingLimitPerUser`。
   *
   * **换算口径（2026-10-09 计价单位变更后重写）**：`points = round(金额 × pointsPerYuan, 2)`。
   *
   * ⚠️ **旧实现在 1:1 口径下会丢用户的钱**：旧式是 `Math.floor(金额 × pointsPerYuan)`。
   * 在 `pointsPerYuan = 10` 时它无害（整数档位 × 10 永远是整数，`floor` 不生效）；
   * 但改成 **1** 之后，`pointsPerYuan` 不再起放大作用，`floor` 就直接砍掉用户的分 ——
   * **充 6.5 元只会到账 6 元，白丢 0.5 元**。这不是"取整风格"问题，是资金差错。
   * 因此改为**按比例精确换算并保留 2 位小数**（与 `recharge_request.points decimal(12,2)`、
   * `wallet.balance decimal(14,2)` 的精度一致），换算结果 **≤ 0** 仍按中文拒绝。
   *
   * 注：`Math.round` 对 `.005` 这类二进制表示不精确的边界，用「先放大 100 倍再取整」规避
   * 浮点累积误差（与文件内金额校验同一套写法）。
   */
  async createRequest(
    userId: string,
    dto: { amountYuan: number; qrId?: string; note?: string; proofMediaId: string },
  ) {
    const cfg = await this.config();

    // ---- ① 金额校验 ----
    const amount = Number(dto.amountYuan);
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new BadRequestException('充值金额不正确');
    }
    // DECIMAL(10,2) 精度：超过 2 位小数直接拒（避免"填 6.999 存成 7.00"的静默改写）
    const amountRounded = Math.round(amount * 100) / 100;
    if (Math.abs(amountRounded - amount) > 1e-9) {
      throw new BadRequestException('充值金额最多保留 2 位小数');
    }
    const options = cfg.amountOptions;
    const inOptions = options.includes(amountRounded);
    if (!inOptions) {
      if (!cfg.customEnabled) {
        throw new BadRequestException(`请从金额档位中选择：${options.join(' / ')} 元`);
      }
      if (amountRounded < cfg.minYuan) {
        throw new BadRequestException(`充值金额不能低于 ${cfg.minYuan} 元`);
      }
      if (amountRounded > cfg.maxYuan) {
        throw new BadRequestException(`充值金额不能高于 ${cfg.maxYuan} 元`);
      }
    }

    // ---- ② 换算到账余额（按比例精确换算、保留 2 位小数；见方法注释的丢钱 bug 说明）----
    // 先放大 100 倍再取整，避免 6.5 * 1 这类二进制浮点表示带来的 0.005 边界抖动。
    const points = Math.round(amountRounded * cfg.pointsPerYuan * 100) / 100;
    if (!Number.isFinite(points) || points <= 0) {
      throw new BadRequestException('换算后到账金额为 0，请提高充值金额或联系管理员');
    }

    // ---- ③ 凭证归属校验（复用既有媒体归属口径：uploaderId 必须等于本人）----
    const proofId = String(dto.proofMediaId ?? '').trim();
    if (!proofId) {
      throw new BadRequestException('请上传转账截图');
    }
    const proof = await this.mediaRepo.findOne({ where: { id: proofId } });
    if (!proof) {
      throw new BadRequestException('转账截图不存在，请重新上传');
    }
    if (String(proof.uploaderId ?? '') !== String(userId)) {
      throw new BadRequestException('转账截图必须是你本人上传的图片');
    }
    if (proof.mimeType && !String(proof.mimeType).startsWith('image/')) {
      throw new BadRequestException('转账截图必须是图片');
    }
    /**
     * **必须是充值专用用途**（`recharge_proof`），不接受任意受保护媒体。
     *
     * 为什么这条是必要的（不只是"写法好看"）：受限会话读凭证走的是
     * `GET /recharge/proof/:requestId`（白名单里刻意没有 `/media/*`）。
     * 若允许拿**任意**受保护媒体当凭证（例如 `chat_image` —— 别人发的聊天图片），
     * 就等于给受限管理员开了一条"把任意受保护媒体挂成充值凭证、再从窄通道读出来"的旁路，
     * 白名单里不放行 `/media/*` 的收窄就白做了。用途白名单从源头堵死。
     */
    if (proof.mediaType !== 'recharge_proof') {
      throw new BadRequestException('转账截图请使用充值凭证上传（type=recharge_proof）');
    }

    // ---- ④ 收款码（可选）----
    let qrId: string | null = null;
    if (dto.qrId !== undefined && dto.qrId !== null && String(dto.qrId).trim() !== '') {
      const qr = await this.qrRepo.findOne({ where: { id: String(dto.qrId) } });
      if (!qr) throw new BadRequestException('收款码不存在，请刷新后重试');
      if (qr.enabled !== 1) throw new BadRequestException('该收款码已停用，请刷新后重新选择');
      qrId = String(qr.id);
    }

    // ---- ⑤ 待审核上限 ----
    const pending = await this.requestRepo.count({ where: { userId: String(userId), status: PENDING_STATUS } });
    if (pending >= cfg.pendingLimitPerUser) {
      throw new BadRequestException(
        `你还有 ${pending} 笔充值申请待审核（最多 ${cfg.pendingLimitPerUser} 笔），请等待管理员处理后再次提交`,
      );
    }

    const row = await this.requestRepo.save(
      this.requestRepo.create({
        userId: String(userId),
        amountYuan: amountRounded.toFixed(2),
        points,
        qrId,
        proofMediaId: proofId,
        note: (dto.note ?? '').slice(0, 200),
        status: 'pending',
      }),
    );
    this.logger.log(
      `充值申请已提交 id=${row.id} user=${userId} amount=${amountRounded} points=${points} proof=${proofId}`,
    );
    return { id: String(row.id), points, status: 'pending' as const };
  }

  /** `GET /user/recharge/requests` —— 我的申请（含状态/驳回原因/发放时间） */
  async myRequests(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.requestRepo.findAndCount({
      where: { userId: String(userId) },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    const qrLabels = await this.qrLabelMap(list.map((r) => (r.qrId ? String(r.qrId) : '')));
    const paths = await this.media.pathsByIds(list.map((r) => String(r.proofMediaId)));
    return {
      list: list.map((r) => ({
        id: String(r.id),
        amountYuan: Number(r.amountYuan),
        points: r.points,
        status: r.status,
        rejectReason: r.rejectReason ?? null,
        // 发放信息：老板要能看到"什么时候到账的"（发放人不下发给用户，属内部审计信息）
        reviewedAt: r.reviewedAt ?? null,
        qrId: r.qrId ? String(r.qrId) : null,
        qrLabel: r.qrId ? (qrLabels.get(String(r.qrId)) ?? null) : null,
        proofUrl: paths.get(String(r.proofMediaId)) ?? null,
        note: r.note,
        createdAt: r.createdAt,
      })),
      total,
      page,
      pageSize,
      pendingCount: await this.requestRepo.count({ where: { userId: String(userId), status: PENDING_STATUS } }),
      pendingLimitPerUser: (await this.config()).pendingLimitPerUser,
    };
  }

  // ==========================================================================
  // 审核侧（受限会话 + 管理端共用同一服务层逻辑）
  // ==========================================================================

  /**
   * 待审/全部申请列表（`GET /recharge/requests` 与 `GET /admin/recharge/requests` 共用**同一服务层逻辑**）。
   *
   * @param query.status `pending` 只看待审 / `granted` / `rejected` / `all` 或空 = 全部
   * @param query.keyword 老板账号/昵称/中文 ID 模糊匹配（管理端搜索框）
   * @param query.startTime/endTime 提交时间区间（ISO 字符串，管理端 n-date-picker 直接下发）
   */
  async reviewList(query: ReviewQuery, page: number, pageSize: number) {
    const qb = this.dataSource
      .createQueryBuilder(RechargeRequest, 'r')
      .innerJoin(User, 'u', 'u.id = r.user_id');

    const status = String(query.status ?? '').trim();
    if (status && status !== 'all') {
      if (!['pending', 'granted', 'rejected'].includes(status)) {
        throw new BadRequestException('状态筛选值不合法（pending/granted/rejected/all）');
      }
      qb.andWhere('r.status = :status', { status });
    }
    const keyword = String(query.keyword ?? '').trim();
    if (keyword) {
      qb.andWhere('(u.username LIKE :kw OR u.nickname LIKE :kw OR u.uid LIKE :kw)', { kw: `%${keyword}%` });
    }
    const start = this.parseTime(query.startTime, '开始时间');
    if (start) qb.andWhere('r.created_at >= :start', { start });
    const end = this.parseTime(query.endTime, '结束时间');
    if (end) qb.andWhere('r.created_at <= :end', { end });

    const total = Number((await qb.clone().select('COUNT(1)', 'cnt').getRawOne())?.cnt ?? 0);
    const list = await qb
      .orderBy('r.id', 'DESC')
      .offset((page - 1) * pageSize)
      .limit(pageSize)
      .getMany();

    return {
      list: await this.decorate(list),
      total,
      page,
      pageSize,
      pendingTotal: await this.requestRepo.count({ where: { status: PENDING_STATUS } }),
    };
  }

  /** 受限会话身份卡片：`GET /recharge/me` */
  async adminMe(userId: string) {
    const user = await this.userRepo.findOne({ where: { id: String(userId) } });
    if (!user) throw new NotFoundException('账号不存在');
    return {
      admin: {
        id: String(user.id),
        nickname: user.nickname || user.username,
        username: user.username,
      },
      kind: 'recharge' as const,
      pendingTotal: await this.requestRepo.count({ where: { status: PENDING_STATUS } }),
    };
  }

  /**
   * `POST /recharge/requests/:id/grant` —— **幂等发放**（本功能最关键的一段）。
   *
   * 事务内顺序（每一步都有理由，改这里之前先读 CLAUDE.md 结构规则 12）：
   * 1. `SELECT ... FOR UPDATE` 锁住这张申请 → 并发/重复点击在此串行化；
   * 2. `status !== 'pending'` → 中文 400（已发放/已驳回都不允许再动）；
   * 3. `WalletService.grantInTx(em, ...)` —— **复用既有超管发余额能力**，同一个事务：
   *    行锁钱包 → 改余额 → 写流水（含 `balance_before/after` 快照）；
   *    幂等键 `recharge:<requestId>` 由 `wallet_transaction.idempotency_key` 唯一约束兜底；
   * 4. 回读该流水（拿 id 与前后余额）→ 是**同一事务**里读的，看到的一定是自己这一步写的值；
   * 5. **条件 UPDATE** 回写 `status='granted' / reviewed_by / reviewed_at / wallet_transaction_id`，
   *    判 `affectedRows === 1`；不为 1（理论上不可能：行锁还在手上）→ 抛错整体回滚，**绝不留半成品**；
   * 6. 通知用户（站内通知与授予同事务，提交后推实时事件）。
   *
   * 重复调用会发生什么（负责人要求的证据点）：第 2 步命中 `granted` → 中文 400「该申请已发放」，
   * **不进第 3 步，余额一分不加**。
   */
  async grant(requestId: string, adminUserId: string, meta: ReviewMeta) {
    const outcome = await this.dataSource.transaction(async (em: EntityManager) => {
      const row = await this.lockRequest(em, requestId);
      this.assertPending(row.status);

      const idempotencyKey = `recharge:${row.id}`;
      // ③ 复用既有发余额能力（同一事务；不新写一套余额逻辑）
      await this.wallet.grantInTx(
        em,
        String(adminUserId),
        {
          userId: String(row.userId),
          amount: Number(row.points),
          reason: `充值审核发放：申请 #${row.id}（${Number(row.amountYuan)} 元）`,
          idempotencyKey,
        },
        meta,
      );

      // ④ 回读流水（同一事务内，必然是本步刚写的那条）
      const txn = await this.walletTransactionOf(em, idempotencyKey);
      if (!txn) {
        throw new BadRequestException('余额流水写入失败，请重试');
      }

      // ⑤ 条件 UPDATE 判 affectedRows
      const res: { affectedRows?: number } = await em.query(
        `UPDATE \`recharge_request\`
            SET \`status\` = 'granted', \`reviewed_by\` = ?, \`reviewed_at\` = NOW(3),
                \`wallet_transaction_id\` = ?, \`reject_reason\` = NULL
          WHERE \`id\` = ? AND \`status\` = 'pending'`,
        [String(adminUserId), String(txn.id), String(row.id)],
      );
      if (Number(res?.affectedRows ?? 0) !== 1) {
        throw new BadRequestException('该申请已发放');
      }

      // ⑥ 站内通知（与授予同事务：授予成功就一定有一条"已到账"通知，不会漏）
      await em.save(
        em.create(UserNotification, {
          userId: String(row.userId),
          type: 'recharge_granted',
          title: '充值申请已到账',
          content: `充值申请已到账：+${Number(row.points).toFixed(2)} 元`,
          refId: String(row.id),
        }),
      );

      return {
        requestId: String(row.id),
        userId: String(row.userId),
        points: Number(row.points),
        amountYuan: Number(row.amountYuan),
        transactionNo: txn.transactionNo,
        walletTransactionId: String(txn.id),
        balanceBefore: Number(txn.balanceBefore),
        balanceAfter: Number(txn.balanceAfter),
      };
    });

    // 事务提交后再推实时事件（回滚时不该推送）
    this.realtime.emitToUser(outcome.userId, 'notification:new', { type: 'recharge_granted' });
    this.realtime.emitToUser(outcome.userId, 'recharge:granted', {
      requestId: outcome.requestId,
      points: outcome.points,
    });
    this.logger.log(
      `充值发放 requestId=${outcome.requestId} user=${outcome.userId} +${Number(outcome.points).toFixed(2)} 元 ` +
        `流水=${outcome.transactionNo} 余额 ${outcome.balanceBefore}→${outcome.balanceAfter} by=${adminUserId}`,
    );
    return {
      ok: true,
      id: outcome.requestId,
      status: 'granted' as const,
      points: outcome.points,
      transactionNo: outcome.transactionNo,
      walletTransactionId: outcome.walletTransactionId,
      balanceBefore: outcome.balanceBefore,
      balanceAfter: outcome.balanceAfter,
    };
  }

  /**
   * `POST /recharge/requests/:id/reject` —— 驳回（同样事务 + 行锁 + 条件 UPDATE，防重复处理）。
   * 驳回**不触碰余额**（没有可回滚的东西：pending 申请从未加过款）。
   */
  async reject(requestId: string, adminUserId: string, reason: string) {
    const trimmed = String(reason ?? '').trim();
    if (!trimmed) throw new BadRequestException('请填写驳回原因');
    if (trimmed.length > 200) throw new BadRequestException('驳回原因最多 200 字');

    const outcome = await this.dataSource.transaction(async (em: EntityManager) => {
      const row = await this.lockRequest(em, requestId);
      this.assertPending(row.status);

      const res: { affectedRows?: number } = await em.query(
        `UPDATE \`recharge_request\`
            SET \`status\` = 'rejected', \`reviewed_by\` = ?, \`reviewed_at\` = NOW(3), \`reject_reason\` = ?
          WHERE \`id\` = ? AND \`status\` = 'pending'`,
        [String(adminUserId), trimmed, String(row.id)],
      );
      if (Number(res?.affectedRows ?? 0) !== 1) {
        throw new BadRequestException('该申请已处理，不能重复操作');
      }

      await em.save(
        em.create(UserNotification, {
          userId: String(row.userId),
          type: 'recharge_rejected',
          title: '充值申请被驳回',
          content: `你的充值申请（${Number(row.amountYuan)} 元）被驳回：${trimmed}`,
          refId: String(row.id),
        }),
      );
      return { requestId: String(row.id), userId: String(row.userId), amountYuan: Number(row.amountYuan) };
    });

    this.realtime.emitToUser(outcome.userId, 'notification:new', { type: 'recharge_rejected' });
    this.logger.log(`充值驳回 requestId=${outcome.requestId} user=${outcome.userId} by=${adminUserId} 原因=${trimmed}`);
    return { ok: true, id: outcome.requestId, status: 'rejected' as const, rejectReason: trimmed };
  }

  /**
   * `GET /recharge/proof/:requestId` —— 受限会话读取"这张申请的那张转账截图"。
   *
   * 为什么不复用 `/media/protected/:id`：那个接口对 `role='admin'` 放行**任意**受保护媒体
   * （聊天图片也在内），而受限会话的白名单里刻意没有 `/media/*`。
   * 这里把权限面收窄到"这条充值申请对应的这一张图"，且必须持有 `recharge:review`（Controller 层校验）。
   */
  async proofMedia(requestId: string): Promise<Media> {
    const row = await this.requestRepo.findOne({ where: { id: String(requestId) } });
    if (!row) throw new NotFoundException('充值申请不存在');
    const media = await this.mediaRepo.findOne({ where: { id: String(row.proofMediaId) } });
    if (!media) throw new NotFoundException('转账截图不存在');
    return media;
  }

  // ==========================================================================
  // 收款码（管理端）
  // ==========================================================================

  /** `GET /admin/recharge/qr-codes`：`enabled` 不传 = 全部（管理端要看停用的） */
  async listQrCodes(enabled?: string) {
    const where = enabled === '1' || enabled === '0' ? { enabled: Number(enabled) } : {};
    const list = await this.qrRepo.find({ where, order: { sort: 'ASC', id: 'ASC' } });
    const paths = await this.media.pathsByIds(list.map((q) => String(q.mediaId)));
    return {
      list: list.map((q) => ({
        id: String(q.id),
        mediaId: String(q.mediaId),
        url: paths.get(String(q.mediaId)) ?? null,
        channel: q.channel,
        label: q.label,
        sort: q.sort,
        enabled: q.enabled === 1,
        createdAt: q.createdAt,
        updatedAt: q.updatedAt,
      })),
      total: list.length,
    };
  }

  /**
   * `POST /admin/recharge/qr-codes`：新增收款码（图片先走既有媒体上传拿 mediaId）。
   *
   * 入参兼容 `imageMediaId`（管理端前端 `api/recharge.ts` 的契约字段名）与 `mediaId`（后端列名）
   * —— 两个名字指同一个东西，收敛在一处，避免"前后端各叫一个名字"变成线上 400。
   */
  async createQrCode(dto: {
    mediaId?: string;
    imageMediaId?: string;
    channel?: string;
    label?: string;
    sort?: number;
    enabled?: boolean;
  }) {
    const mediaId = String(dto.imageMediaId ?? dto.mediaId ?? '').trim();
    await this.assertMediaImage(mediaId, '收款码图片');
    const row = await this.qrRepo.save(
      this.qrRepo.create({
        mediaId,
        channel: this.normalizeChannel(dto.channel),
        label: (dto.label ?? '').slice(0, 64),
        sort: Number.isFinite(Number(dto.sort)) ? Number(dto.sort) : 0,
        enabled: dto.enabled === false ? 0 : 1,
      }),
    );
    this.invalidatePublicConfigCache();
    this.logger.log(`收款码已新增 id=${row.id} channel=${row.channel} media=${row.mediaId}`);
    return {
      id: String(row.id),
      mediaId: String(row.mediaId),
      imageMediaId: String(row.mediaId),
      channel: row.channel,
      label: row.label,
      sort: row.sort,
      enabled: row.enabled === 1,
    };
  }

  /** `PUT /admin/recharge/qr-codes/:id`：改图/渠道/名称/排序/启停（部分提交；接受两种图片字段名） */
  async updateQrCode(
    id: string,
    dto: {
      mediaId?: string;
      imageMediaId?: string;
      channel?: string;
      label?: string;
      sort?: number;
      enabled?: boolean;
    },
  ) {
    const row = await this.qrRepo.findOne({ where: { id: String(id) } });
    if (!row) throw new NotFoundException('收款码不存在');
    const nextMediaId = dto.imageMediaId ?? dto.mediaId;
    if (nextMediaId !== undefined) {
      await this.assertMediaImage(nextMediaId, '收款码图片');
      row.mediaId = String(nextMediaId);
    }
    if (dto.channel !== undefined) row.channel = this.normalizeChannel(dto.channel);
    if (dto.label !== undefined) row.label = String(dto.label).slice(0, 64);
    if (dto.sort !== undefined && Number.isFinite(Number(dto.sort))) row.sort = Number(dto.sort);
    if (dto.enabled !== undefined) row.enabled = dto.enabled ? 1 : 0;
    const saved = await this.qrRepo.save(row);
    this.invalidatePublicConfigCache();
    return {
      id: String(saved.id),
      mediaId: String(saved.mediaId),
      imageMediaId: String(saved.mediaId),
      channel: saved.channel,
      label: saved.label,
      enabled: saved.enabled === 1,
      sort: saved.sort,
    };
  }

  /**
   * `DELETE /admin/recharge/qr-codes/:id`：**物理删除**。
   *
   * 与"停用不删"的口径区分：停用（`enabled=0`）用于"暂时不收这张码"，行保留；
   * 删除用于"传错了/作废了"。历史申请引用的是 `qr_id`（可空），删码不会破坏历史 ——
   * 列表侧对已删的码回落为 `qrLabel=null`，不会 500。
   */
  async deleteQrCode(id: string) {
    const row = await this.qrRepo.findOne({ where: { id: String(id) } });
    if (!row) throw new NotFoundException('收款码不存在');
    await this.qrRepo.remove(row);
    this.invalidatePublicConfigCache();
    this.logger.log(`收款码已删除 id=${id} media=${row.mediaId}`);
    return { deleted: true, id: String(id) };
  }

  // ==========================================================================
  // 受限管理员白名单（管理端；仅超管可增删）
  // ==========================================================================

  /** `GET /admin/recharge/admins`：白名单 + 上限 + 可选账号（角色必须是 admin） */
  async listAdmins() {
    const cfg = await this.config();
    const rows: Array<{
      userId: string | number;
      username: string;
      nickname: string;
      uid: string;
      status: number;
      grantedBy: string | number | null;
      createdAt: Date | null;
      roleCode: string | null;
      isOwner: number | null;
    }> = await this.dataSource.query(
      `SELECT u.id AS userId, u.username, u.nickname, u.uid, u.status,
              ra.granted_by AS grantedBy, ra.created_at AS createdAt,
              ar.code AS roleCode, a.is_owner AS isOwner
         FROM recharge_admin ra
         JOIN user u ON u.id = ra.user_id
         LEFT JOIN admin a ON a.user_id = u.id
         LEFT JOIN admin_role ar ON ar.id = a.role_id
        ORDER BY ra.created_at ASC, u.id ASC`,
    );
    return {
      list: rows.map((r) => ({
        /** 前端删条目用这个键；`recharge_admin` 没有代理主键，故 id === adminUserId */
        id: String(r.userId),
        adminUserId: String(r.userId),
        userId: String(r.userId),
        username: r.username,
        nickname: r.nickname,
        uid: r.uid,
        status: Number(r.status),
        roleCode: r.roleCode ?? null,
        isOwner: Number(r.isOwner ?? 0) === 1,
        grantedBy: r.grantedBy === null ? null : String(r.grantedBy),
        createdAt: r.createdAt,
      })),
      total: rows.length,
      /** 当前生效上限（= min(配置, 硬上限 5)） */
      adminLimit: cfg.adminLimit,
      /** 硬上限（负责人定案：最多 5 个账号；配置只能在本值以内收紧） */
      adminLimitMax: RECHARGE_ADMIN_LIMIT_MAX,
    };
  }

  /**
   * `POST /admin/recharge/admins` —— 加入白名单（**仅超管**，调用方已校验）。
   *
   * 入参兼容 `adminUserId`（管理端前端契约字段名）/ `targetUserId` / `userId`。
   *
   * 并发安全（负责人明确要求"唯一约束 + 事务 + 行锁"）：
   * - **事务**：计数与插入必须在同一临界区；
   * - **行锁**：`SELECT setting_key FROM system_setting WHERE setting_key='recharge_config' FOR UPDATE`
   *   —— 所有"加入/移出白名单"的操作在这**同一行**上排队，因此"读到的条数"与"插入"之间
   *   不可能插入另一个并发加入。为什么锁配置行而不是锁 user 行：要防的是"两个**不同**账号
   *   同时加入把总数顶过上限"，锁目标账号各自的行起不到串行化作用；
   * - **唯一约束**：`recharge_admin.user_id` 是主键 → 同一账号不可能加两次；
   * - 撞唯一键（并发加同一账号）→ 中文 400，而不是 500。
   */
  async addAdmin(callerUserId: string, targetUserId: string) {
    const targetId = String(targetUserId ?? '').trim();
    if (!targetId) throw new BadRequestException('请选择要授权的管理员账号');

    const result = await this.dataSource.transaction(async (em: EntityManager) => {
      // 配置行行锁：白名单的增删全部在这一行上排队（并发安全的关键）
      await em.query('SELECT `setting_key` FROM `system_setting` WHERE `setting_key` = ? FOR UPDATE', [
        RECHARGE_CONFIG_KEY,
      ]);

      const target = await em.findOne(User, { where: { id: targetId } });
      if (!target) throw new NotFoundException('账号不存在');
      // 只允许 role=admin 的账号（负责人定案：白名单里只能是管理员账号）
      if (target.role !== 'admin') throw new BadRequestException('该账号不是管理员账号，无法授权充值审核');
      const profile = await em.query(
        `SELECT a.status, ar.code AS roleCode FROM admin a LEFT JOIN admin_role ar ON ar.id = a.role_id
          WHERE a.user_id = ? LIMIT 1`,
        [targetId],
      );
      if (!profile.length) throw new BadRequestException('该账号没有管理员档案，无法授权充值审核');
      if (Number(profile[0].status) !== 1) throw new BadRequestException('该管理员账号已停用，请先启用');

      const existing = await em.findOne(RechargeAdmin, { where: { userId: targetId } });
      if (existing) throw new BadRequestException('该账号已在充值审核白名单中');

      // 上限：配置值（读侧已按硬上限 5 收敛）+ 再兜一次硬上限（不依赖配置正确性）
      const cfg = await this.config();
      const limit = Math.min(cfg.adminLimit, RECHARGE_ADMIN_LIMIT_MAX);
      const countRows: Array<{ c: number | string }> = await em.query(
        'SELECT COUNT(1) AS c FROM recharge_admin',
      );
      const current = Number(countRows[0]?.c ?? 0);
      if (current >= limit) {
        throw new BadRequestException(
          `充值审核管理员已达上限（${limit} 个，最多 ${RECHARGE_ADMIN_LIMIT_MAX} 个），请先移除后再添加`,
        );
      }

      try {
        await em.save(em.create(RechargeAdmin, { userId: targetId, grantedBy: String(callerUserId) }));
      } catch (e) {
        // 并发撞主键：翻译成中文 400（而不是 500）
        const code = (e as { code?: string; driverError?: { code?: string } })?.code
          ?? (e as { driverError?: { code?: string } })?.driverError?.code;
        if (code === 'ER_DUP_ENTRY') throw new BadRequestException('该账号已在充值审核白名单中');
        throw e;
      }
      return { userId: targetId, username: target.username, count: current + 1, limit };
    });

    this.logger.log(`充值审核白名单 +1 user=${result.userId} by=${callerUserId}（${result.count}/${result.limit}）`);
    return {
      ok: true,
      userId: result.userId,
      username: result.username,
      total: result.count,
      adminLimit: result.limit,
    };
  }

  /**
   * `DELETE /admin/recharge/admins/:userId` —— 移出白名单（**仅超管**，调用方已校验）。
   *
   * **移出即失效**（负责人要求的验证点 5）：删白名单行 + **立即吊销该账号全部 `kind='recharge'` 会话**
   * + 断开其 WS（若有）。下一次请求 `checkRechargeSession` 查不到白名单行 → **401 中文**。
   * **绝不动 primary**：管理员在管理端的登录照常可用（`AuthService.revokeRechargeTokens` 只命中 recharge）。
   */
  async removeAdmin(callerUserId: string, targetUserId: string) {
    const targetId = String(targetUserId ?? '').trim();
    if (!targetId) throw new BadRequestException('请选择要移除的管理员账号');

    const row = await this.adminRepo.findOne({ where: { userId: targetId } });
    if (!row) throw new NotFoundException('该账号不在充值审核白名单中');
    await this.adminRepo.remove(row);

    // 立即吊销受限会话（只吊销 recharge）+ 主动断开其 WS（当前握手阶段就拒绝 recharge，
    // 因此正常情况下踢到 0 个；保留这一步是为了"将来若有人放开 WS，踢线不会漏"）
    const revoked = await this.auth.revokeRechargeTokens(targetId);
    const kicked = this.realtime.disconnectByJti(revoked.jtis, 'auth:expired');
    // 通知被移除的管理员（站内通知；不改动其 primary 任何东西）
    await this.notify(targetId, {
      type: 'recharge_admin_removed',
      title: '充值审核权限已收回',
      content: '你的充值审核（受限管理）权限已被超级管理员收回，如需继续请重新申请。',
      refId: null,
    });

    const countRows: Array<{ c: number | string }> = await this.dataSource.query('SELECT COUNT(1) AS c FROM recharge_admin');
    this.logger.log(
      `充值审核白名单 -1 user=${targetId} by=${callerUserId} 吊销受限会话=${revoked.affected} 断开WS=${kicked}`,
    );
    return {
      ok: true,
      userId: targetId,
      total: Number(countRows[0]?.c ?? 0),
      revokedSessions: revoked.affected,
      message: '已移出白名单，该账号的受限管理身份立即失效',
    };
  }

  // ==========================================================================
  // 绑定受限管理员态（老板端「身份」）
  // ==========================================================================

  /**
   * `POST /user/identity/bind-recharge-admin` —— 用**管理员账密**换取受限管理会话。
   *
   * 与 `/user/identity/bind`（打手态）逐条同构，差别只在"校验对象是 admin 白名单"：
   * 1. 限流（5 次/分/IP+账号，防管理员账密爆破）→ 429 中文；
   * 2. 定位账号 → 查不到：**与密码错逐字同一句**「账号或密码错误」（防账号枚举，安全审计 F2 口径）；
   * 3. bcrypt 校验（`AuthService.comparePassword`，与登录同一实现）→ 错：同一句；
   * 4. 角色必须是 `admin` → 否则 403「该账号不是管理员账号，无法进入管理员态」；
   * 5. 封禁（复用 `AuthService.assertNotBanned`：到期自动解封 / 封禁中 403 + ACCOUNT_BANNED）；
   * 6. **必须在 `recharge_admin` 白名单内** → 否则 403 中文（**先验密码再看白名单**：
   *    不知道密码的人得不到任何"某账号是否被授权"的情报）；
   * 7. 签发 `kind='recharge'` 受限会话（**不顶 primary**；TTL 12h，与 companion 一致）。
   *
   * 主体 id 只取 JWT sub（调用方是谁不影响签发结果——签发对象永远是"被验证账密的那个管理员账号"）。
   */
  async bindRechargeAdmin(
    callerUserId: string,
    dto: { username?: string; password?: string },
    ip: string,
    userAgent: string,
  ) {
    const account = String(dto?.username ?? '').trim();
    if (!account) throw new BadRequestException('请填写管理员账号');
    if (!dto?.password) throw new BadRequestException('请填写密码');

    if (!(await this.rateLimit.allow(`recharge-bind:${ip}:${account}`, RECHARGE_BIND_RATE_LIMIT, RECHARGE_BIND_RATE_WINDOW_SECONDS))) {
      await this.auth.recordIdentityEvent(null, account, ip, userAgent, 'fail', '受限管理绑定：触发限流');
      throw new HttpException(
        { message: '尝试过于频繁，请稍后再试', errorCode: 'RATE_LIMITED' },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    const target = await this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.username = :account OR u.uid = :account', { account })
      .getOne();
    if (!target) {
      await this.auth.recordIdentityEvent(null, account, ip, userAgent, 'fail', '受限管理绑定：账号不存在');
      throw new BadRequestException('账号或密码错误');
    }
    if (!(await this.auth.comparePassword(target, dto.password))) {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '受限管理绑定：密码错误');
      throw new BadRequestException('账号或密码错误');
    }
    if (target.role !== 'admin') {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '受限管理绑定：角色不是管理员');
      throw new ForbiddenException('该账号不是管理员账号，无法进入管理员态');
    }
    await this.auth.assertNotBanned(target, 'identity', target.username, ip, userAgent);

    const whitelisted = await this.adminRepo.findOne({ where: { userId: String(target.id) } });
    if (!whitelisted) {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '受限管理绑定：不在白名单');
      throw new ForbiddenException('该账号未获授权进行充值审核，请联系超级管理员');
    }

    const tokens = await this.auth.issueRechargeTokens(target);
    await this.auth.recordIdentityEvent(
      target.id,
      target.username,
      ip,
      userAgent,
      'success',
      `受限管理绑定：by=${callerUserId}`,
    );
    this.logger.log(`受限管理身份已绑定 admin=${target.id} by=${callerUserId}`);
    return {
      admin: { id: String(target.id), nickname: target.nickname || target.username, username: target.username },
      rechargeToken: tokens.accessToken,
      rechargeRefreshToken: tokens.refreshToken,
      /** 与 companion 一致 12h（access 与 refresh 同 TTL） */
      expiresIn: tokens.expiresIn,
    };
  }

  /** `POST /user/identity/refresh-recharge-admin`：受限管理会话续期（只吃 recharge refreshToken） */
  async refreshRechargeAdmin(refreshToken: string, ip: string) {
    const pair = await this.auth.refresh(refreshToken, ip, { requireRecharge: true });
    return {
      rechargeToken: pair.accessToken,
      rechargeRefreshToken: pair.refreshToken,
      expiresIn: pair.expiresIn,
      ttlSeconds: 12 * 60 * 60,
    };
  }

  // ==========================================================================
  // 内部
  // ==========================================================================

  /** 行锁 + 取出申请（不存在 → 404 中文） */
  private async lockRequest(em: EntityManager, requestId: string): Promise<RequestRow> {
    const rows: RequestRow[] = await em.query(
      `SELECT id, user_id AS userId, amount_yuan AS amountYuan, points, qr_id AS qrId,
              proof_media_id AS proofMediaId, note, status, reject_reason AS rejectReason,
              reviewed_by AS reviewedBy, reviewed_at AS reviewedAt,
              wallet_transaction_id AS walletTransactionId, created_at AS createdAt
         FROM recharge_request WHERE id = ? FOR UPDATE`,
      [String(requestId)],
    );
    const row = rows?.[0];
    if (!row) throw new NotFoundException('充值申请不存在');
    return row;
  }

  private assertPending(status: string): void {
    if (status === 'granted') throw new BadRequestException('该申请已发放');
    if (status === 'rejected') throw new BadRequestException('该申请已驳回，不能再次发放');
    if (status !== 'pending') throw new BadRequestException('该申请状态异常，无法处理');
  }

  /** 按幂等键回读流水（同一事务内） */
  private async walletTransactionOf(
    em: EntityManager,
    idempotencyKey: string,
  ): Promise<{ id: string | number; transactionNo: string; balanceBefore: string | number; balanceAfter: string | number } | null> {
    const rows = await em.query(
      `SELECT id, transaction_no AS transactionNo, balance_before AS balanceBefore, balance_after AS balanceAfter
         FROM wallet_transaction WHERE idempotency_key = ? LIMIT 1`,
      [idempotencyKey],
    );
    return rows?.[0] ?? null;
  }

  /** 列表补展示字段：老板昵称/中文 ID、收款码名、凭证 url/媒体 id、审核人昵称 */
  private async decorate(list: RechargeRequest[]): Promise<ReviewListItem[]> {
    if (!list.length) return [];
    const userIds = [...new Set(list.map((r) => String(r.userId)))];
    const users: Array<{ id: string | number; username: string; nickname: string; uid: string }> =
      await this.dataSource.query(`SELECT id, username, nickname, uid FROM user WHERE id IN (?)`, [userIds]);
    const userMap = new Map(users.map((u) => [String(u.id), u]));
    const qrLabels = await this.qrLabelMap(list.map((r) => (r.qrId ? String(r.qrId) : '')));
    const paths = await this.media.pathsByIds(list.map((r) => String(r.proofMediaId)));
    const reviewerNames = await this.reviewerNameMap(
      list.map((r) => (r.reviewedBy === null || r.reviewedBy === undefined ? '' : String(r.reviewedBy))),
    );

    return list.map((r) => {
      const u = userMap.get(String(r.userId));
      const proofMediaId = String(r.proofMediaId);
      const reviewedBy = r.reviewedBy === null || r.reviewedBy === undefined ? null : String(r.reviewedBy);
      return {
        id: String(r.id),
        userId: String(r.userId),
        username: u?.username ?? '',
        nickname: u?.nickname ?? '',
        uid: u?.uid ?? '',
        amountYuan: Number(r.amountYuan),
        // 前端字段别名：管理端表格直接用 `amount`（与 amountYuan 同值，避免前端猜字段）
        amount: Number(r.amountYuan),
        points: r.points,
        qrId: r.qrId ? String(r.qrId) : null,
        qrLabel: r.qrId ? (qrLabels.get(String(r.qrId)) ?? null) : null,
        proofMediaId,
        voucherMediaId: proofMediaId,
        proofUrl: paths.get(proofMediaId) ?? null,
        note: r.note,
        status: r.status,
        rejectReason: r.rejectReason ?? null,
        reviewedBy,
        reviewerName: reviewedBy ? (reviewerNames.get(reviewedBy) ?? '') : '',
        reviewedAt: r.reviewedAt ?? null,
        walletTransactionId:
          r.walletTransactionId === null || r.walletTransactionId === undefined
            ? null
            : String(r.walletTransactionId),
        createdAt: r.createdAt,
      };
    });
  }

  /** 审核人昵称（管理端"审核人"列展示；按 id 批量取，避免 N+1） */
  private async reviewerNameMap(ids: string[]): Promise<Map<string, string>> {
    const uniq = [...new Set(ids.filter((x) => x))];
    if (!uniq.length) return new Map();
    const rows: Array<{ id: string | number; username: string; nickname: string }> = await this.dataSource.query(
      `SELECT id, username, nickname FROM user WHERE id IN (?)`,
      [uniq],
    );
    return new Map(rows.map((r) => [String(r.id), r.nickname || r.username]));
  }

  /** ISO 时间解析（管理端 n-date-picker 下发 ISO；非法 → 中文 400，不静默忽略筛选） */
  private parseTime(raw: string | undefined, label: string): Date | null {
    const v = String(raw ?? '').trim();
    if (!v) return null;
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) throw new BadRequestException(`${label}格式不正确`);
    return d;
  }

  private async qrLabelMap(ids: string[]): Promise<Map<string, string>> {
    const uniq = [...new Set(ids.filter((x) => x))];
    if (!uniq.length) return new Map();
    const rows: Array<{ id: string | number; label: string }> = await this.dataSource.query(
      `SELECT id, label FROM recharge_qr_code WHERE id IN (?)`,
      [uniq],
    );
    return new Map(rows.map((r) => [String(r.id), r.label]));
  }

  /** 收款码图片校验：必须存在且是图片（复用 media 表口径，不信任客户端声明的类型） */
  private async assertMediaImage(mediaId: unknown, label: string): Promise<void> {
    const id = String(mediaId ?? '').trim();
    if (!id) throw new BadRequestException(`请上传${label}`);
    const media = await this.mediaRepo.findOne({ where: { id } });
    if (!media) throw new BadRequestException(`${label}不存在，请重新上传`);
    if (!String(media.mimeType ?? '').startsWith('image/')) {
      throw new BadRequestException(`${label}必须是图片`);
    }
  }

  private normalizeChannel(channel: unknown): 'wechat' | 'alipay' | 'other' {
    const v = String(channel ?? 'other');
    return v === 'wechat' || v === 'alipay' ? v : 'other';
  }

  /** 站内通知（与既有 notification 同一张表 + 同一实时事件名） */
  private async notify(
    userId: string,
    n: { type: string; title: string; content: string; refId: string | null },
  ): Promise<void> {
    await this.dataSource.getRepository(UserNotification).save(
      this.dataSource.getRepository(UserNotification).create({
        userId: String(userId),
        type: n.type,
        title: n.title,
        content: n.content,
        refId: n.refId,
      }),
    );
    this.realtime.emitToUser(userId, 'notification:new', { type: n.type });
  }
}
