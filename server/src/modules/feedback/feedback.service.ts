import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { User } from '../user/user.entity';
import { UserFeedback } from './user-feedback.entity';

/** 意见反馈服务：提交（10 条/天限流语义留待后续；基础校验）+ 管理端列表/处理留痕 */
@Injectable()
export class FeedbackService {
  constructor(
    @InjectRepository(UserFeedback) private readonly repo: Repository<UserFeedback>,
  ) {}

  async submit(userId: string, dto: { content: string; contact?: string }) {
    const content = (dto.content ?? '').trim();
    if (!content) throw new BadRequestException('反馈内容不能为空');
    if (content.length > 1000) throw new BadRequestException('反馈内容过长（最多 1000 字）');
    const fb = await this.repo.save(
      this.repo.create({ userId, content, contact: (dto.contact ?? '').slice(0, 100) }),
    );
    return { ok: true, id: fb.id };
  }

  async adminList(page: number, pageSize: number, status: number | undefined) {
    const qb = this.repo
      .createQueryBuilder('f')
      .leftJoin(User, 'u', 'u.id = f.user_id')
      .select(['f.id AS id', 'f.user_id AS userId', 'u.nickname AS nickname', 'u.uid AS uid', 'f.content AS content', 'f.contact AS contact', 'f.status AS status', 'f.handler_remark AS handlerRemark', 'f.created_at AS createdAt']);
    if (status !== undefined && status !== null && !Number.isNaN(status)) qb.andWhere('f.status = :status', { status });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('f.id', 'DESC').offset((page - 1) * pageSize).limit(pageSize).getRawMany();
    return {
      list: list.map((r: { id: string; userId: string; nickname: string; uid: string; content: string; contact: string; status: number; handlerRemark: string; createdAt: Date }) => ({
        id: String(r.id),
        userId: String(r.userId),
        nickname: r.nickname ?? '',
        uid: r.uid ?? '',
        content: r.content,
        contact: r.contact,
        status: Number(r.status),
        handlerRemark: r.handlerRemark,
        createdAt: r.createdAt,
      })),
      total: Number(total?.cnt ?? 0),
      page,
      pageSize,
    };
  }

  async handle(adminUserId: string, id: string, remark: string) {
    const fb = await this.repo.findOne({ where: { id } });
    if (!fb) throw new NotFoundException('反馈不存在');
    if (fb.status === 2) throw new BadRequestException('该反馈已处理');
    fb.status = 2;
    fb.handlerId = adminUserId;
    fb.handlerRemark = (remark ?? '').slice(0, 500);
    fb.handledAt = new Date();
    await this.repo.save(fb);
    return { ok: true };
  }
}
