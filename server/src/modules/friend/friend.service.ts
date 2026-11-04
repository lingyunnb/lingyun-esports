import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { ChatService } from '../chat/chat.service';
import { LEVEL_RULES } from '../level/level.service';
import { User } from '../user/user.entity';
import { UserFriend } from './user-friend.entity';
import { UserNotification } from './user-notification.entity';

/** 展示 ID 规则（负责人需求 #17）：2-20 位中文/字母/数字/下划线，后端统一校验 */
export const UID_PATTERN = /^[一-龥A-Za-z0-9_]{2,20}$/;

export function uidValid(uid: string): boolean {
  return UID_PATTERN.test(uid);
}

/**
 * 好友系统（负责人需求 #16）：
 * - 好友关系全部由后端处理（申请/同意/拒绝/删除），客户端不能伪造
 * - 重复申请幂等；对方已申请我时自动双向成为好友
 * - 关键动作写系统通知 + WS 实时推送
 */
@Injectable()
export class FriendService {
  constructor(
    @InjectRepository(UserFriend) private readonly friendRepo: Repository<UserFriend>,
    @InjectRepository(UserNotification) private readonly notifRepo: Repository<UserNotification>,
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    private readonly realtime: RealtimeGateway,
    private readonly chat: ChatService,
  ) {}

  /** 申请好友（按展示 ID 精确搜索；支持中文/数字/英文） */
  async request(requesterId: string, uid: string, message: string) {
    if (!uidValid(uid)) throw new BadRequestException('ID 格式非法（2-20 位中文/字母/数字/下划线）');
    const target = await this.userRepo.findOne({ where: { uid, status: 1 } });
    if (!target) throw new NotFoundException('该 ID 不存在');
    if (String(target.id) === String(requesterId)) throw new BadRequestException('不能添加自己为好友');

    const reverse = await this.friendRepo.findOne({
      where: { requesterId: target.id, addresseeId: requesterId },
    });
    if (reverse && reverse.status === 'accepted') throw new BadRequestException('你们已经是好友');
    if (reverse && reverse.status === 'pending') {
      // 对方已申请我：直接双向成为好友
      reverse.status = 'accepted';
      reverse.actedAt = new Date();
      await this.friendRepo.save(reverse);
      await this.notify(target.id, 'friend_accepted', '好友申请已通过', `${await this.nicknameOf(requesterId)} 通过了你的好友申请`, String(requesterId));
      this.realtime.emitToUser(requesterId, 'friend:accepted', { userId: target.id });
      return { autoAccepted: true };
    }

    const existing = await this.friendRepo.findOne({
      where: { requesterId, addresseeId: target.id },
    });
    if (existing) {
      if (existing.status === 'accepted') throw new BadRequestException('你们已经是好友');
      if (existing.status === 'pending') throw new BadRequestException('申请已发送，请等待对方处理');
      if (existing.status === 'rejected' || existing.status === 'removed') {
        // 重新申请：覆盖旧记录
        existing.status = 'pending';
        existing.message = (message || '').slice(0, 255);
        existing.actedAt = null;
        await this.friendRepo.save(existing);
        await this.notify(target.id, 'friend_request', '新的好友申请', `${await this.nicknameOf(requesterId)} 请求添加你为好友`, String(requesterId));
        this.realtime.emitToUser(target.id, 'friend:request', {});
        return { ok: true, retried: true };
      }
    }

    await this.friendRepo.save(
      this.friendRepo.create({
        requesterId,
        addresseeId: target.id,
        status: 'pending',
        message: (message || '').slice(0, 255),
      }),
    );
    await this.notify(target.id, 'friend_request', '新的好友申请', `${await this.nicknameOf(requesterId)} 请求添加你为好友`, String(requesterId));
    this.realtime.emitToUser(target.id, 'friend:request', {});
    return { ok: true };
  }

  /** 我的好友列表（accepted 双向） */
  async list(meId: string) {
    const rows = await this.friendRepo.manager.query(
      `SELECT f.id AS relId, f.created_at AS friendSince,
              CASE WHEN f.requester_id = ? THEN f.addressee_id ELSE f.requester_id END AS friend_id
       FROM user_friend f WHERE f.status = 'accepted' AND (f.requester_id = ? OR f.addressee_id = ?)
       ORDER BY f.updated_at DESC`,
      [meId, meId, meId],
    );
    const ids: string[] = rows.map((r: { friend_id: string }) => String(r.friend_id));
    if (!ids.length) return { list: [], total: 0 };
    const users = await this.userRepo
      .createQueryBuilder('u')
      .where('u.id IN (:...ids)', { ids })
      .getMany();
    const byId = new Map(users.map((u) => [String(u.id), u]));
    return {
      list: rows.map((r: { relId: string; friendSince: Date; friend_id: string }) => {
        const u = byId.get(String(r.friend_id));
        if (!u) return null;
        // 在线状态（2026-09-25）：任一设备连着 WS 即在线
        return { ...this.profileView(u), online: this.realtime.isOnline(u.id) };
      }).filter(Boolean),
      total: rows.length,
    };
  }

  /** 我收到的待处理申请 */
  async incoming(meId: string) {
    const rows = await this.friendRepo.manager.query(
      `SELECT f.id, f.requester_id, f.message, f.created_at, u.uid, u.nickname, u.avatar_media_id, u.level
       FROM user_friend f JOIN user u ON u.id = f.requester_id
       WHERE f.addressee_id = ? AND f.status = 'pending' ORDER BY f.id DESC`,
      [meId],
    );
    return {
      list: rows.map((r: { id: string; requester_id: string; message: string; created_at: Date; uid: string; nickname: string; avatar_media_id: string | null; level: number }) => ({
        id: String(r.id),
        userId: String(r.requester_id),
        uid: r.uid,
        nickname: r.nickname,
        avatarMediaId: r.avatar_media_id,
        level: Number(r.level),
        message: r.message,
        createdAt: r.created_at,
      })),
    };
  }

  /** 我发出的待处理申请 */
  async outgoing(meId: string) {
    const rows = await this.friendRepo.manager.query(
      `SELECT f.id, f.addressee_id, f.message, f.created_at, u.uid, u.nickname, u.avatar_media_id, u.level
       FROM user_friend f JOIN user u ON u.id = f.addressee_id
       WHERE f.requester_id = ? AND f.status = 'pending' ORDER BY f.id DESC`,
      [meId],
    );
    return {
      list: rows.map((r: { id: string; addressee_id: string; message: string; created_at: Date; uid: string; nickname: string; avatar_media_id: string | null; level: number }) => ({
        id: String(r.id),
        userId: String(r.addressee_id),
        uid: r.uid,
        nickname: r.nickname,
        avatarMediaId: r.avatar_media_id,
        level: Number(r.level),
        message: r.message,
        createdAt: r.created_at,
      })),
    };
  }

  /** 同意申请（仅接收方可操作） */
  async accept(meId: string, requestId: string) {
    const row = await this.friendRepo.findOne({ where: { id: requestId } });
    if (!row) throw new NotFoundException('申请不存在');
    if (String(row.addresseeId) !== String(meId)) throw new ForbiddenException('只能处理发给你的申请');
    if (row.status !== 'pending') throw new BadRequestException('该申请已处理');
    row.status = 'accepted';
    row.actedAt = new Date();
    await this.friendRepo.save(row);
    await this.notify(row.requesterId, 'friend_accepted', '好友申请已通过', `${await this.nicknameOf(meId)} 通过了你的好友申请`, String(meId));
    this.realtime.emitToUser(row.requesterId, 'friend:accepted', { userId: meId });
    return { ok: true };
  }

  /** 拒绝申请 */
  async reject(meId: string, requestId: string) {
    const row = await this.friendRepo.findOne({ where: { id: requestId } });
    if (!row) throw new NotFoundException('申请不存在');
    if (String(row.addresseeId) !== String(meId)) throw new ForbiddenException('只能处理发给你的申请');
    if (row.status !== 'pending') throw new BadRequestException('该申请已处理');
    row.status = 'rejected';
    row.actedAt = new Date();
    await this.friendRepo.save(row);
    return { ok: true };
  }

  /** 删除好友（软删 removed；可重新申请） */
  async remove(meId: string, friendUserId: string) {
    const row = await this.friendRepo.findOne({
      where: [
        { requesterId: meId, addresseeId: friendUserId },
        { requesterId: friendUserId, addresseeId: meId },
      ],
    });
    if (!row || row.status !== 'accepted') throw new BadRequestException('你们不是好友');
    row.status = 'removed';
    row.actedAt = new Date();
    await this.friendRepo.save(row);
    return { ok: true };
  }

  /** 按展示 ID 搜索（好友搜索入口，负责人需求 #14/#46） */
  async search(meId: string, kw: string) {
    // 2026-09-25：支持按展示 ID 精确搜索或昵称模糊搜索（中文 ID/昵称均可）
    const keyword = (kw ?? '').trim();
    if (!keyword || keyword.length > 50) throw new BadRequestException('请输入要搜索的 ID 或昵称');
    let target = await this.userRepo.findOne({ where: { uid: keyword } });
    if (!target) {
      target = await this.userRepo
        .createQueryBuilder('u')
        .where('u.nickname LIKE :like', { like: `%${keyword}%` })
        .orderBy('u.id', 'ASC')
        .getOne();
    }
    if (!target) throw new NotFoundException('未找到该用户');
    const me = await this.userRepo.findOne({ where: { id: meId } });
    let friendStatus = 'none';
    if (String(target.id) === String(meId)) friendStatus = 'self';
    else {
      const rel = await this.friendRepo.findOne({
        where: [
          { requesterId: meId, addresseeId: target.id },
          { requesterId: target.id, addresseeId: meId },
        ],
      });
      if (rel?.status === 'accepted') friendStatus = 'accepted';
      else if (rel?.status === 'pending') friendStatus = rel.requesterId === String(meId) ? 'pending_out' : 'pending_in';
    }
    return {
      ...this.profileView(target),
      myUid: me?.uid ?? '',
      friendStatus,
    };
  }

  /** 打开与好友的会话（仅 accepted 好友；返回共享会话 id，双方 seq 同一流） */
  async openConversation(meId: string, friendUserId: string) {
    const rel = await this.friendRepo.findOne({
      where: [
        { requesterId: meId, addresseeId: friendUserId, status: 'accepted' },
        { requesterId: friendUserId, addresseeId: meId, status: 'accepted' },
      ],
    });
    if (!rel) throw new BadRequestException('你们不是好友');
    const conv = await this.chat.getOrCreateFriendConversation(meId, friendUserId);
    return { conversationId: conv.id };
  }

  // ---------------- 通知 ----------------

  async notify(userId: string, type: string, title: string, content: string, refId: string | null) {
    await this.notifRepo.save(this.notifRepo.create({ userId, type, title, content: content.slice(0, 500), refId }));
  }

  async notifications(meId: string, page: number, pageSize: number) {
    const [list, total] = await this.notifRepo.findAndCount({
      where: { userId: meId },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    const unread = await this.notifRepo.count({ where: { userId: meId, isRead: 0 } });
    return {
      list: list.map((n) => ({
        id: n.id,
        type: n.type,
        title: n.title,
        content: n.content,
        refId: n.refId,
        isRead: n.isRead === 1,
        createdAt: n.createdAt,
      })),
      total,
      unread,
      page,
      pageSize,
    };
  }

  async markNotificationsRead(meId: string, ids?: string[]) {
    if (ids?.length) {
      await this.notifRepo
        .createQueryBuilder()
        .update()
        .set({ isRead: 1 })
        .where('user_id = :meId AND id IN (:...ids)', { meId, ids })
        .execute();
    } else {
      await this.notifRepo.update({ userId: meId, isRead: 0 }, { isRead: 1 });
    }
    return { ok: true };
  }

  // ---------------- 内部 ----------------

  private async nicknameOf(userId: string): Promise<string> {
    const u = await this.userRepo.findOne({ where: { id: userId } });
    return u?.nickname ?? u?.uid ?? '用户';
  }

  private profileView(u: User) {
    return {
      userId: u.id,
      uid: u.uid,
      nickname: u.nickname,
      avatarMediaId: u.avatarMediaId,
      level: Number(u.level),
      levelName: LEVEL_RULES.find((r) => r.level === Number(u.level))?.name ?? '',
      createdAt: u.createdAt,
    };
  }

  /** 供事务场景复用（预留）：通知写入管理器 */
  notifyInTx(em: EntityManager, userId: string, type: string, title: string, content: string, refId: string | null) {
    return em.save(em.create(UserNotification, { userId, type, title, content: content.slice(0, 500), refId }));
  }
}
