import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Inject } from '@nestjs/common';
import Redis from 'ioredis';
import { Repository } from 'typeorm';
import { REDIS_CLIENT } from '../../common/redis.provider';
import { mediaTypeLabel } from '../../common/pipes/validation-messages';
import { LEVEL_RULES } from '../level/level.service';
import { Media } from '../media/media.entity';
import { User } from './user.entity';

/** 展示 ID 修改限流：3 次/24 小时（防批量占号/撞库） */
const UID_CHANGE_LIMIT = 3;

/**
 * 个人资料服务（负责人需求 #17/#18/#19）：
 * - 昵称/头像/背景修改：媒体必须为本人上传且类型匹配（服务端校验归属）
 * - 展示 ID 支持中文/数字/英文/下划线，后端统一格式校验 + 唯一 + 限频
 * - 公开资料页：其他用户可见字段白名单
 */
@Injectable()
export class ProfileService {
  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(Media) private readonly mediaRepo: Repository<Media>,
    @Inject(REDIS_CLIENT) private readonly redis: Redis,
  ) {}

  async updateProfile(userId: string, dto: { nickname?: string; avatarMediaId?: string | null; backgroundMediaId?: string | null }) {
    const user = await this.userRepo.findOne({ where: { id: userId } });
    if (!user) throw new NotFoundException('账号不存在');
    const patch: Partial<User> = {};
    if (dto.nickname !== undefined) {
      const nickname = (dto.nickname ?? '').trim();
      if (!nickname) throw new BadRequestException('昵称不能为空');
      if (nickname.length > 32) throw new BadRequestException('昵称最长 32 字');
      patch.nickname = nickname;
    }
    if (dto.avatarMediaId !== undefined) {
      patch.avatarMediaId = await this.assertOwnMedia(dto.avatarMediaId, userId, 'avatar');
    }
    if (dto.backgroundMediaId !== undefined) {
      patch.backgroundMediaId = await this.assertOwnMedia(dto.backgroundMediaId, userId, 'bg');
    }
    await this.userRepo.update(user.id, patch);
    const fresh = await this.userRepo.findOne({ where: { id: userId } });
    return this.publicProfile(fresh!);
  }

  /** 修改展示 ID（中文/字母/数字/下划线 2-20；唯一；24h 限 3 次） */
  async changeUid(userId: string, uid: string) {
    const clean = (uid ?? '').trim();
    if (!/^[一-龥A-Za-z0-9_]{2,20}$/.test(clean)) {
      throw new BadRequestException('ID 须为 2-20 位中文、字母、数字或下划线');
    }
    const limitKey = `profile:uid-change:${userId}`;
    const used = await this.redis.incr(limitKey);
    if (used === 1) await this.redis.expire(limitKey, 24 * 3600);
    if (used > UID_CHANGE_LIMIT) {
      throw new BadRequestException(`24 小时内最多修改 ${UID_CHANGE_LIMIT} 次 ID`);
    }
    const exists = await this.userRepo.findOne({ where: { uid: clean } });
    if (exists) {
      // 撞号：回滚计数（不消耗次数）
      await this.redis.decr(limitKey);
      throw new ConflictException('该 ID 已被使用');
    }
    await this.userRepo.update(userId, { uid: clean });
    return { ok: true, uid: clean };
  }

  /** 公开资料页（其他用户查看；白名单字段，不含用户名/手机等） */
  async publicProfileByUid(uid: string) {
    const user = await this.userRepo.findOne({ where: { uid } });
    if (!user) throw new NotFoundException('该 ID 不存在');
    return this.publicProfile(user);
  }

  private async assertOwnMedia(mediaId: string | null, userId: string, type: 'avatar' | 'bg'): Promise<string | null> {
    if (!mediaId) return null;
    const media = await this.mediaRepo.findOne({ where: { id: mediaId } });
    if (!media) throw new BadRequestException('媒体不存在');
    if (String(media.uploaderId) !== String(userId)) throw new BadRequestException('只能使用自己上传的媒体');
    if (media.mediaType !== type) throw new BadRequestException(`该素材不是${mediaTypeLabel(type)}，请重新上传`);
    return media.id;
  }

  private publicProfile(user: User) {
    return {
      userId: user.id,
      uid: user.uid,
      nickname: user.nickname,
      avatarMediaId: user.avatarMediaId,
      backgroundMediaId: user.backgroundMediaId,
      level: Number(user.level),
      levelName: LEVEL_RULES.find((r) => r.level === Number(user.level))?.name ?? '',
      totalSpent: Number(user.totalSpent),
      createdAt: user.createdAt,
    };
  }
}
