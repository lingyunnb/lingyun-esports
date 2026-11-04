import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { UserLevelLog } from './user-level-log.entity';

export type LevelRule = { level: number; name: string; minSpent: number };

/** 等级规则默认值（docs/06 补充）：按累计实际消费余额划分 5 级，区间有明显区分。
 *  实际生效值以 system_setting 表 `level_rules` 配置为准（负责人 2026-09-25：升级阈值由后台配置，
 *  前端只读后台数据）；表里无配置时回退此默认值。 */
export const LEVEL_RULES_DEFAULT: LevelRule[] = [
  // 负责人 2026-10-17 定名（老板会员等级；打手等级另有一套 初出/立足/扬名/称雄/宗师，互不混用）
  { level: 1, name: '初识会员', minSpent: 0 },
  { level: 2, name: '知交会员', minSpent: 500 },
  { level: 3, name: '尊享会员', minSpent: 2_000 },
  { level: 4, name: '臻享会员', minSpent: 10_000 },
  { level: 5, name: '至尊会员', minSpent: 50_000 },
];

/** 兼容旧引用的默认规则别名（升级判定请用 LevelService.getRules() 读取后台配置） */
export const LEVEL_RULES: LevelRule[] = LEVEL_RULES_DEFAULT;

/** 按累计消费计算应达等级（只升不降语义由调用方保证） */
export function levelForSpent(rules: LevelRule[], spent: number): number {
  let lv = 1;
  for (const r of rules) {
    if (spent >= r.minSpent) lv = r.level;
  }
  return lv;
}

/**
 * 用户等级服务：
 * - 下单事务内累加 total_spent 并自动升级（服务端唯一写入口，客户端不可改）
 * - 退款回退 total_spent（等级不自动降级，避免退款导致等级跳变）
 * - 管理端手动调整（admin:user:level，默认仅超管）：写 user_level_log + operation_log 双重审计
 */
@Injectable()
export class LevelService {
  constructor(
    @InjectRepository(UserLevelLog) private readonly logRepo: Repository<UserLevelLog>,
    private readonly realtime: RealtimeGateway,
    private readonly settings: SystemSettingService,
  ) {}

  /** 读取生效等级规则：优先 system_setting `level_rules`（后台可配），缺省回退默认值 */
  async getRules(): Promise<LevelRule[]> {
    const row = await this.settings.get('level_rules');
    const cfg = row?.cfgValue?.['rules'];
    if (Array.isArray(cfg) && cfg.length) {
      const parsed: LevelRule[] = [];
      for (const r of cfg) {
        const lv = Number(r?.['level']);
        const min = Number(r?.['minSpent']);
        const name = String(r?.['name'] ?? '');
        if (Number.isInteger(lv) && lv >= 1 && lv <= 5 && Number.isFinite(min) && name) {
          parsed.push({ level: lv, name, minSpent: min });
        }
      }
      if (parsed.length) return parsed.sort((a, b) => a.level - b.level);
    }
    return LEVEL_RULES_DEFAULT;
  }

  /** 下单事务内调用：行锁读用户 → 累加消费 → 自动升级（只升不降）；升级后 WS 实时推送 */
  async applySpendInTx(em: EntityManager, userId: string, amount: number): Promise<void> {
    const user = await em.findOne(User, {
      where: { id: userId },
      lock: { mode: 'pessimistic_write' },
    });
    if (!user) throw new NotFoundException('账号不存在');
    const rules = await this.getRules();
    const newSpent = Number(user.totalSpent) + amount;
    const target = levelForSpent(rules, newSpent);
    const newLevel = Math.max(Number(user.level), target);
    await em.update(User, user.id, { totalSpent: String(newSpent), level: newLevel });
    if (newLevel > Number(user.level)) {
      // 升级立即同步（需求 #9）：老板端/工作端/管理端实时刷新，杜绝"库里已升级 App 还是旧等级"
      this.realtime.emitToUser(user.id, 'user:level-changed', { level: newLevel, levelName: rules.find((r) => r.level === newLevel)?.name ?? '', totalSpent: newSpent });
    }
  }

  /** 退款事务内调用：回退累计消费（不低于 0；等级不自动降级） */
  async refundSpentInTx(em: EntityManager, userId: string, amount: number): Promise<void> {
    await em.query(
      `UPDATE user SET total_spent = GREATEST(0, total_spent - ?) WHERE id = ?`,
      [amount, userId],
    );
  }

  /** 管理端手动调整等级（写审计日志 user_level_log） */
  async adminSetLevel(adminUserId: string, userId: string, level: number, reason: string) {
    if (!Number.isInteger(level) || level < 1 || level > 5) {
      throw new BadRequestException('等级必须在 1-5 之间');
    }
    const user = await this.logRepo.manager.findOne(User, { where: { id: userId } });
    if (!user) throw new NotFoundException('账号不存在');
    // 负责人指令：会员等级仅限老板端，工作端不设会员体系
    if (user.role === 'worker') {
      throw new BadRequestException('工作端账号不设会员等级（会员体系仅限老板端）');
    }
    const from = Number(user.level);
    if (from === level) {
      throw new BadRequestException('目标等级与当前等级相同');
    }
    await this.logRepo.manager.transaction(async (em) => {
      await em.update(User, user.id, { level });
      await em.save(
        em.create(UserLevelLog, {
          userId: user.id,
          adminUserId,
          fromLevel: from,
          toLevel: level,
          reason: (reason || '').slice(0, 255),
        }),
      );
    });
    // 管理员调整后实时推送给该用户（需求 #9）
    const rules = await this.getRules();
    this.realtime.emitToUser(user.id, 'user:level-changed', {
      level,
      levelName: rules.find((r) => r.level === level)?.name ?? '',
      totalSpent: Number(user.totalSpent),
    });
    return { ok: true, userId: user.id, fromLevel: from, toLevel: level };
  }

  /** 管理端用户等级详情（等级/累计消费/当前等级名） */
  async adminUserDetail(userId: string) {
    const user = await this.logRepo.manager.findOne(User, { where: { id: userId } });
    if (!user) throw new NotFoundException('账号不存在');
    const rules = await this.getRules();
    return {
      id: user.id,
      username: user.username,
      uid: user.uid,
      nickname: user.nickname,
      role: user.role,
      status: user.status,
      level: Number(user.level),
      levelName: rules.find((r) => r.level === Number(user.level))?.name ?? '',
      totalSpent: Number(user.totalSpent),
    };
  }
}
