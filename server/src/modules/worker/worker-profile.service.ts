import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { User } from '../user/user.entity';
import { Worker } from './worker.entity';
import { checkWorkerIntro } from './worker-intro.rules';

/**
 * 打手自写简介（负责人 2026-10-17 改定：**介绍让打手自己写**，管理端仍可改作兜底）
 *
 * ============================ 三条硬边界 ============================
 * 1. **主体只从 JWT `sub` 取** —— 本服务的每个方法第一个参数都是 `userId`（守卫注入的会话主体），
 *    接口层**不接受**请求体里的任何 workerId/userId（DTO 里根本没有这两个字段，
 *    全局管道 `forbidNonWhitelisted` 会把它们直接 400 掉）。
 *    因此"改别人的简介"在协议层面就不存在这条路径，不依赖 service 里的 if 判断。
 * 2. **`intro` 落在 `user` 表**（不是 `worker` 表）：`user.intro varchar(200)`，migration
 *    `1789981000000-user-intro` 已建（本轮**无需新 migration**，见交付报告字段取证）。
 * 3. **与管理端兜底路径互不覆盖**：本服务用 `UPDATE user SET intro = ?, intro_updated_by = NULL
 *    WHERE id = ?` 的**定列更新**，绝不 `save()` 整个实体 —— 那样会把管理端刚改的
 *    `worker.division_id` / `worker.status` 连同内存里的旧值一起写回（lost update）。
 *    管理端 `WorkerAdminService.setPlayersProfile()` 同步改成定列更新，两条路径只碰自己那几列。
 *
 * ============================ 审计：为什么不写 operation_log / login_log ============================
 * - `operation_log`：**管理端写接口的留痕**（谁以管理员身份改了什么）。本接口是打手改**自己的**
 *   公开展示文本，不是管理员动作 —— 写进去会把"管理员操作审计"这条线污染成"用户随手改文案"。
 * - `login_log(user_type='identity')`：那是**身份/绑定生命周期**事件（绑定、解绑、系统释放，
 *   见 `modules/auth/worker-binding-release.ts`，`fail_reason` 承载「解绑：<来源>|binding=…」）。
 *   简介既不改权限、也不涉资金、也不是身份事件，塞进去会稀释那份审计，且 `fail_reason` 列语义不符。
 * - 可用的最小痕迹已经在库里，且**零新表新列**：
 *   `user.updated_at`（何时改）+ `user.intro_updated_by`（**谁**改的）——
 *   打手自写时本服务把它置 `NULL`，即「**不是管理端写的**」；管理端改写时写管理员 id。
 *   管理端页面据此就能区分"这行文案是打手写的还是管理员兜底改的"。
 */
@Injectable()
export class WorkerProfileService {
  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
  ) {}

  /** 读自己的简介（打手态「我的」页进入编辑页时回填当前值） */
  async getIntro(userId: string) {
    const worker = await this.requireWorker(userId);
    const user = await this.userRepo.findOne({ where: { id: worker.userId } });
    if (!user) throw new NotFoundException('账号不存在');
    return {
      intro: user.intro ?? '',
      // 头像 / 主页背景（负责人 2026-10-18：打手可自定义）
      avatarMediaId: user.avatarMediaId ?? null,
      backgroundMediaId: user.backgroundMediaId ?? null,
    };
  }

  /**
   * 改自己的简介。**没有 workerId 参数** —— 主体是谁由守卫钉死在会话登记上。
   *
   * @param userId 会话主体（JWT `sub` → `auth_token.user_id`，见 JwtAuthGuard）
   * @param rawIntro 请求体里的原文（`unknown`：不可信输入，交给纯函数校验）
   */
  async setIntro(userId: string, rawIntro: unknown) {
    const worker = await this.requireWorker(userId);
    if (Number(worker.status) !== 1) {
      // 停用档案不该还能改公开展示文案（管理端停用后它也早已从找陪玩列表消失）
      throw new ForbiddenException('打手档案已停用，暂不能修改简介');
    }
    const checked = checkWorkerIntro(rawIntro);
    if (!checked.ok) {
      // 400 + 中文原文：客户端直接把这句话显示给打手（不分类、不改写）
      throw new BadRequestException(checked.message);
    }
    /**
     * 定列更新（见类注释 3）。`introUpdatedBy = null` = 「本次不是管理端写的」，
     * 管理端「陪玩资料」页据此区分兜底改动；`updated_at` 由 `@UpdateDateColumn` 自动维护。
     */
    await this.userRepo
      .createQueryBuilder()
      .update(User)
      .set({ intro: checked.intro, introUpdatedBy: null })
      .where('id = :id', { id: worker.userId })
      .execute();
    return { ok: true, intro: checked.intro };
  }

  /**
   * 改自己的**头像 / 主页背景**（负责人 2026-10-18：打手可自定义）
   *
   * ## 三态语义（与简介一致，别改成"缺省即清空"）
   * - 字段**不传**（`undefined`）→ 不动这一列
   * - 传 `null` → 清除（回默认字标 / 默认场）
   * - 传 mediaId → 换成这张图
   *
   * ## 校验
   * 媒体必须**属于自己**（`media.user_id = 本人`）且用途对（`avatar` / `bg`），
   * 否则 400 中文。**不接受任意 mediaId** —— 否则能把别人的图挂到自己主页上。
   *
   * ## 为什么用定列更新
   * 与 [setIntro] 同一个理由：`save()` 整实体会把管理端刚改的 `worker.*` 用内存旧值写回（lost update）。
   */
  async setMedia(
    userId: string,
    raw: { avatarMediaId?: string | null; backgroundMediaId?: string | null },
  ) {
    const worker = await this.requireWorker(userId);
    if (Number(worker.status) !== 1) {
      throw new ForbiddenException('打手档案已停用，暂不能修改头像与背景');
    }

    const set: Record<string, unknown> = {};
    const out: Record<string, unknown> = { ok: true };

    // 头像：用途 avatar
    if (raw.avatarMediaId !== undefined) {
      const id = raw.avatarMediaId;
      if (id === null) {
        set.avatarMediaId = null;
        out.avatarMediaId = null;
      } else {
        await this.assertOwnMedia(id, worker.userId, 'avatar', '头像');
        set.avatarMediaId = id;
        out.avatarMediaId = id;
      }
    }

    // 主页背景：用途 bg
    if (raw.backgroundMediaId !== undefined) {
      const id = raw.backgroundMediaId;
      if (id === null) {
        set.backgroundMediaId = null;
        out.backgroundMediaId = null;
      } else {
        await this.assertOwnMedia(id, worker.userId, 'bg', '主页背景');
        set.backgroundMediaId = id;
        out.backgroundMediaId = id;
      }
    }

    // 两个都没传 → 什么都不做（不写库、不报错）
    if (Object.keys(set).length === 0) return out;

    await this.userRepo
      .createQueryBuilder()
      .update(User)
      .set(set)
      .where('id = :id', { id: worker.userId })
      .execute();

    return out;
  }

  /** 媒体归属 + 用途校验（不通过就 400 中文，不吞） */
  private async assertOwnMedia(
    mediaId: string,
    ownerUserId: string,
    purpose: string,
    label: string,
  ): Promise<void> {
    // ⚠️ 列名以 `media` 实体为准：`uploader_id`（不是 user_id）、`media_type`（不是 purpose）。
    // 2026-10-18 修：上一版写成 `user_id` / `purpose` → MySQL 报"未知列" → 整个请求 500
    // （真机表现就是"服务器内部错误" / "上传失败，请重试"）。
    const rows: Array<{ uploader_id: string | null; media_type: string }> =
      await this.userRepo.manager.query(
        'SELECT uploader_id, media_type FROM media WHERE id = ? LIMIT 1',
        [mediaId],
      );
    const row = rows[0];
    if (!row) throw new BadRequestException(`${label}图片不存在，请重新上传`);
    if (String(row.media_type) !== purpose) {
      throw new BadRequestException(`${label}图片用途不正确，请重新上传`);
    }
    if (String(row.uploader_id ?? '') !== String(ownerUserId)) {
      throw new BadRequestException(`${label}图片不属于当前账号，请重新上传`);
    }
  }

  /**
   * 找到会话主体对应的打手档案。
   *
   * companion 会话（老板端打手态）在 `checkCompanionSession` 里已校验过"档案在职"，
   * 这里再查一次**不是重复校验**：worker **primary** 会话（旧工作端/脚本）不会被那条路径覆盖，
   * 而本接口两个会话类型都要能用。
   */
  private async requireWorker(userId: string): Promise<Worker> {
    const worker = await this.workerRepo.findOne({ where: { userId } });
    if (!worker) {
      throw new ForbiddenException('该账号没有打手档案，不能修改陪玩介绍');
    }
    return worker;
  }
}
