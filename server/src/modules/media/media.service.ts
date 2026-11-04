import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectRepository } from '@nestjs/typeorm';
import { createHash } from 'crypto';
import { promises as fs } from 'fs';
import * as path from 'path';
import sharp from 'sharp';
import { randomUUID } from 'crypto';
import { Repository } from 'typeorm';
import { mediaTypeLabel } from '../../common/pipes/validation-messages';
import { Media } from './media.entity';

/** 上传用途类型与限制（docs/08 校验清单） */
const TYPE_RULES: Record<string, { maxBytes: number; protected?: boolean; kinds: 'image' | 'video' }> = {
  avatar: { maxBytes: 5 * 1024 * 1024, kinds: 'image' },
  bg: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  // 主页背景的**视频版**（2026-10-21，负责人要「实况背景」）
  //
  // 为什么必须单开一个 kind：Android/小米的「动态照片」本质是 JPEG + 内嵌 mp4，
  // 外壳就是一张 JPEG —— 魔数嗅探只能认成静态图，`Image.network` 也只会画封面帧。
  // 想让背景"真动"，素材必须是 mp4。客户端按魔数自动选类型：图片→bg、mp4→bg_video，
  // 两者都写同一个 `user.background_media_id`（不新增数据库列）。
  bg_video: { maxBytes: 30 * 1024 * 1024, kinds: 'video' },
  chat_image: { maxBytes: 5 * 1024 * 1024, protected: true, kinds: 'image' },
  product_image: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  video_cover: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  product_video: { maxBytes: 100 * 1024 * 1024, kinds: 'video' },
  banner: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  top_worker_avatar: { maxBytes: 5 * 1024 * 1024, kinds: 'image' },
  // 分部图标/封面（管理端 DivisionsView 上传时用的就是这两个 type；此前未登记 → 管理端换图必失败）
  division_icon: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  division_cover: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  // 论坛/社区（负责人需求 #26/#29）：多图/视频/封面
  forum_image: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  forum_video: { maxBytes: 200 * 1024 * 1024, kinds: 'video' },
  forum_cover: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  // 投诉截图（负责人 2026-10-04）：**受保护媒体** —— 只有投诉人本人与管理员可读（docs/08 归属校验）
  complaint_image: { maxBytes: 10 * 1024 * 1024, protected: true, kinds: 'image' },
  /**
   * 充值收款码（负责人 2026-10-06）：**公开图片**。
   *
   * 必须公开：老板端要直接 `<img src>` 拉到它扫码（`/media/public/:id`）。
   * 为什么不借用 `banner`：语义会混进"首页宣传位"，污染引用计数与后续清理逻辑
   * （`banner` 的引用计数分支盯的是 `home_banner` 表，收款码不在那里）。
   */
  recharge_qr: { maxBytes: 10 * 1024 * 1024, kinds: 'image' },
  /**
   * 充值转账凭证（负责人 2026-10-06）：**受保护图片** —— 绝不能公开直连。
   *
   * 它是**资金凭证**（含用户付款信息：金额、时间、可能的昵称/单号），
   * 因此 `protected: true`：只有上传者本人与管理员可读（`/media/protected/:id` 的既有归属校验），
   * 受限管理会话另走 `/recharge/proof/:requestId` 这条更窄的通道（只放行"这张申请的那张图"）。
   * 同样刻意不借用 `complaint_image`：那会把凭证落进"投诉"语义。
   */
  recharge_proof: { maxBytes: 10 * 1024 * 1024, protected: true, kinds: 'image' },
  /**
   * 打手提现收款码（负责人 2026-10-11）：**受保护图片** —— 收款码绝不公开直连。
   *
   * 为什么不是 public（与 `recharge_qr` 相反）：老板端的收款码是**给付款人扫的**，
   * 本来就该公开；而打手的收款码是**打款去向**（含姓名/微信号等个人信息），
   * 公开直连等于把"谁该收这笔钱"广播出去 —— 只有本人与持有 `withdraw:review` 的管理员可读，
   * 且管理侧只走 `GET .../withdraw/proof/:id?kind=qr` 这条按申请收窄的通道。
   */
  withdraw_qr: { maxBytes: 10 * 1024 * 1024, protected: true, kinds: 'image' },
  /**
   * 提现打款凭证（负责人 2026-10-11）：**受保护图片** —— 资金凭证绝不公开直连。
   *
   * 与 `recharge_proof` 同性质（转账截图里的金额/时间/昵称都是资金信息），
   * 同样刻意不借用 `recharge_proof`：语义会混进"充值"，污染引用计数与后续清理逻辑。
   */
  withdraw_proof: { maxBytes: 10 * 1024 * 1024, protected: true, kinds: 'image' },
};

const IMAGE_EXT_BY_MAGIC: Record<string, { ext: string; mime: string }> = {
  jpg: { ext: 'jpg', mime: 'image/jpeg' },
  png: { ext: 'png', mime: 'image/png' },
  gif: { ext: 'gif', mime: 'image/gif' },
  webp: { ext: 'webp', mime: 'image/webp' },
};

/** 魔数探测（不信任扩展名与客户端 MIME） */
export function sniffType(buf: Buffer): { ext: string; mime: string } | null {
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return IMAGE_EXT_BY_MAGIC.jpg;
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return IMAGE_EXT_BY_MAGIC.png;
  if (buf.length >= 6 && buf.subarray(0, 4).toString('ascii') === 'GIF8') return IMAGE_EXT_BY_MAGIC.gif;
  if (buf.length >= 12 && buf.subarray(0, 4).toString('ascii') === 'RIFF' && buf.subarray(8, 12).toString('ascii') === 'WEBP') return IMAGE_EXT_BY_MAGIC.webp;
  if (buf.length >= 12 && buf.subarray(4, 8).toString('ascii') === 'ftyp') return { ext: 'mp4', mime: 'video/mp4' };
  return null;
}

/**
 * 被删除媒体的**审计快照**（2026-10-13）。
 *
 * 为什么单独定义这个类型、而不是直接返回 `Media` 实体：
 * TypeORM 的 `repo.remove(entity)` 在删除成功后会把实体上的**主键清成 `undefined`**
 * （框架刻意为之，防止删除后误用该实体）。实测踩到：控制器直接读 `removed.id` 写审计，
 * `operation_log.request_body` 里落下的是 `"mediaId":"undefined"` ——
 * **留痕留了个查不到东西的 id**，等于白留。
 * 因此在 `remove()` **之前**把需要的字段摘出来，返回这个不可变快照。
 */
export interface DeletedMediaSnapshot {
  id: string;
  mediaType: string;
  isProtected: number;
  sizeBytes: string;
  sha256: string;
  fileKey: string;
}

@Injectable()
export class MediaService {
  private readonly logger = new Logger('Media');

  constructor(
    @InjectRepository(Media) private readonly mediaRepo: Repository<Media>,
    private readonly config: ConfigService,
  ) {}

  /** MEDIA_ROOT 绝对路径（env 注入，默认 D:\fish\data\uploads） */
  rootDir(): string {
    return (this.config.get<string>('MEDIA_ROOT') || 'D:/fish/data/uploads').replace(/\\/g, '/').replace(/\/$/, '');
  }

  /**
   * 上传（docs/08 校验清单全量）：类型白名单→大小→魔数→重编码剥离负载→哈希去重→UUID 落盘
   * @param buffer 文件内容
   * @param originalName 客户端原始文件名（只用于取扩展名与记录）
   * @param mediaType 上传用途类型
   * @param uploaderId 上传者 user id
   */
  async upload(buffer: Buffer, originalName: string, mediaType: string, uploaderId: string | null): Promise<Media> {
    const rule = TYPE_RULES[mediaType];
    if (!rule) {
      throw new BadRequestException(`不支持该上传用途（${mediaTypeLabel(mediaType)}）`);
    }
    if (!buffer || buffer.length === 0) {
      throw new BadRequestException('文件内容为空');
    }
    if (buffer.length > rule.maxBytes) {
      throw new BadRequestException(`文件超出大小限制（最大 ${Math.round(rule.maxBytes / 1024 / 1024)}MB）`);
    }

    // 魔数探测真实类型（防改扩展名伪装）
    const sniffed = sniffType(buffer);
    if (!sniffed) {
      throw new BadRequestException('无法识别的文件类型（仅支持 JPG、PNG、GIF、WebP 图片与 MP4 视频）');
    }
    if (rule.kinds === 'image' && sniffed.mime === 'video/mp4') {
      throw new BadRequestException('该用途仅支持图片文件');
    }
    if (rule.kinds === 'video' && sniffed.mime !== 'video/mp4') {
      throw new BadRequestException('该用途仅支持 mp4 视频文件');
    }
    // 扩展名一致性（原始文件名扩展名必须与魔数一致，防伪装）
    const claimedExt = (path.extname(originalName || '') || '').toLowerCase().replace('.', '');
    if (claimedExt && claimedExt !== sniffed.ext && !(claimedExt === 'jpeg' && sniffed.ext === 'jpg')) {
      throw new BadRequestException(`扩展名与文件内容不一致（${claimedExt} ≠ ${sniffed.ext}）`);
    }

    // 内容哈希去重（相同文件 + 相同用途复用已有记录；类型不同则各自建记录，保证保护级别/生命周期独立）
    const sha256 = createHash('sha256').update(buffer).digest('hex');
    const existing = await this.mediaRepo.findOne({ where: { sha256, mediaType } });
    if (existing) {
      return existing;
    }

    // 图片：重编码剥离恶意负载；>1920px 等比缩放；JPEG/WebP q85；gif 保持原样（重编码丢动画）
    let stored = buffer;
    let width: number | null = null;
    let height: number | null = null;
    if (sniffed.mime !== 'video/mp4' && sniffed.ext !== 'gif') {
      try {
        let pipe = sharp(buffer);
        const meta = await pipe.metadata();
        if ((meta.width ?? 0) > 1920) {
          pipe = pipe.resize({ width: 1920, withoutEnlargement: true });
        }
        if (sniffed.ext === 'png') {
          stored = await pipe.png({ compressionLevel: 9 }).toBuffer();
        } else if (sniffed.ext === 'webp') {
          stored = await pipe.webp({ quality: 85 }).toBuffer();
        } else {
          stored = await pipe.jpeg({ quality: 85 }).toBuffer();
        }
        const finalMeta = await sharp(stored).metadata();
        width = finalMeta.width ?? null;
        height = finalMeta.height ?? null;
      } catch (e) {
        // 重编码失败 = 内容无法被图片库解析（伪造/损坏文件），按 docs/08 拒绝，禁止原样存储
        this.logger.warn(`图片内容校验失败，拒绝上传: ${(e as Error).message}`);
        throw new BadRequestException('图片内容无法解析（文件可能损坏或伪造）');
      }
    }

    // 落盘 YYYY/MM/uuid.ext（MEDIA_ROOT 即上传根目录；路径服务端拼接，杜绝 ../ 穿越）
    const now = new Date();
    const subDir = `${now.getFullYear()}/${String(now.getMonth() + 1).padStart(2, '0')}`;
    const absDir = path.join(this.rootDir(), subDir);
    await fs.mkdir(absDir, { recursive: true });
    const fileName = `${randomUUID()}.${sniffed.ext}`;
    const fileKey = `${subDir}/${fileName}`.replace(/\\/g, '/');
    await fs.writeFile(path.join(this.rootDir(), fileKey), stored);

    try {
      const media = await this.mediaRepo.save(
        this.mediaRepo.create({
          fileKey,
          mediaType,
          originalName: (originalName || '').slice(0, 255),
          mimeType: sniffed.mime,
          extension: sniffed.ext,
          sizeBytes: String(stored.length),
          width,
          height,
          sha256,
          uploaderId,
          isProtected: rule.protected ? 1 : 0,
        }),
      );
      this.logger.log(`媒体入库 mediaId=${media.id} type=${mediaType} size=${stored.length}`);
      return media;
    } catch (e) {
      // 并发同内容上传：唯一键冲突兜底，回查已有记录（幂等）；TypeORM 把 mysql2 错误包在 driverError
      const driver = (e as { driverError?: { code?: string; errno?: number } }).driverError;
      if (driver?.code === 'ER_DUP_ENTRY' || driver?.errno === 1062) {
        const dup = await this.mediaRepo.findOne({ where: { sha256, mediaType } });
        if (dup) return dup;
      }
      throw e;
    }
  }

  /** 绝对磁盘路径（仅服务端内部使用） */
  absPath(media: Media): string {
    return path.join(this.rootDir(), media.fileKey);
  }

  /**
   * 客户端访问路径（相对路径，客户端按自身 API 主机解析，docs/11 环境无关）
   *
   * ⚠️ 两条通道的**前缀刻意不同**，这是 2026-10-06 修掉"付款凭证永久转圈"的根因：
   *   - 公开媒体：`main.ts` 的 `setGlobalPrefix` **排除了** `media/public/(.*)` → 真实路径就是根路径 `/media/public/:id`；
   *   - 受保护媒体：**没有**被排除 → 真实路由挂在全局前缀下，即 `/api/v1/media/protected/:id`。
   *
   * 此前这里对受保护资源也返回 `/media/protected/:id`（少了 `/api/v1`）→ 实测 404
   * `Cannot GET /media/protected/201` → 充值审核的付款凭证图永远刷不出来（App 与管理端回退路径一起坏）。
   *
   * 为什么选"改 URL"而不是"把 `media/protected/(.*)` 也加进 exclude"：
   *   PC 管理端 `admin-web/src/api/client.ts` 早已用绝对路径 `/api/v1/media/protected/${id}` 取图（线上可用），
   *   加 exclude 等于**新开一条平行路由 + 还要改管理端**；改 URL 只动这一行，且与既有真实路由一字不差。
   * 鉴权语义**零变化**：仍走 `MediaController.protectedDownload`（无令牌 401 / 归属校验 404）。
   */
  clientPath(media: Media): string {
    return media.isProtected ? `/api/v1/media/protected/${media.id}` : `/media/public/${media.id}`;
  }

  /** 批量解析 mediaId → 客户端访问路径（供首页聚合等场景，避免 N+1） */
  async pathsByIds(ids: string[]): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    if (!ids.length) return map;
    const rows = await this.mediaRepo.createQueryBuilder('m').where('m.id IN (:...ids)', { ids }).getMany();
    for (const m of rows) map.set(m.id, this.clientPath(m));
    return map;
  }

  /** 批量取实体（业务模块校验引用合法性用） */
  async findByIds(ids: string[]): Promise<Media[]> {
    if (!ids.length) return [];
    return this.mediaRepo.createQueryBuilder('m').where('m.id IN (:...ids)', { ids }).getMany();
  }

  async findPublic(id: string): Promise<Media> {
    const media = await this.mediaRepo.findOne({ where: { id } });
    if (!media) throw new NotFoundException('资源不存在');
    if (media.isProtected) throw new NotFoundException('资源不存在'); // 受保护资源必须走 protected 通道
    return media;
  }

  async findProtected(id: string): Promise<Media> {
    const media = await this.mediaRepo.findOne({ where: { id } });
    if (!media || !media.isProtected) throw new NotFoundException('资源不存在');
    return media;
  }

  /**
   * 聊天图片授权（docs/07 补充）：上传者本人 / admin / 该图片所在会话的成员
   * （好友会话双成员、客服会话属主与 active 授权客服、订单群成员）均可读——修复"对方看不到我发的图"问题
   */
  async isChatImageMember(mediaId: string, userId: string): Promise<boolean> {
    const raw: unknown = await this.mediaRepo.manager.query(
      `SELECT 1 FROM chat_message m
       JOIN chat_conversation c ON c.id = m.conversation_id
       LEFT JOIN chat_conversation_assign a ON a.conversation_id = c.id AND a.status = 'active'
       LEFT JOIN chat_conversation_member gm ON gm.conversation_id = c.id
       WHERE m.msg_type = 'image' AND m.content = ?
         AND (c.user_id = ? OR c.peer_user_id = ? OR a.worker_user_id = ? OR gm.user_id = ?)
       LIMIT 1`,
      [mediaId, userId, userId, userId, userId],
    );
    const rows = (Array.isArray(raw) && raw.length >= 1 && Array.isArray(raw[0]) ? raw[0] : raw) as unknown[];
    return rows.length > 0;
  }

  /**
   * 删除（被业务引用时禁止；删记录同步删文件，docs/08）
   *
   * 返回**被删除媒体的审计快照**（2026-10-13 由 `Promise<void>` 改为
   * `Promise<DeletedMediaSnapshot>`）：管理端 `DELETE /admin/media/:id` 必须写 `operation_log`，
   * 而"删了什么"只有在行被删掉**之前**才拿得到。
   *
   * ⚠️ 必须在 `remove()` **之前**摘字段：`repo.remove()` 成功后会把实体的主键置为 `undefined`
   * （实测踩到 → 审计里写成 `"mediaId":"undefined"`）。详见 `DeletedMediaSnapshot` 注释。
   * 既有唯一调用方（控制器）此前忽略返回值，故本改动**不改变任何删除语义**。
   */
  async deleteById(id: string): Promise<DeletedMediaSnapshot> {
    const media = await this.mediaRepo.findOne({ where: { id } });
    if (!media) throw new NotFoundException('资源不存在');
    const refs = await this.referenceCount(id);
    if (refs > 0) {
      throw new BadRequestException(`资源被 ${refs} 处业务数据引用，禁止删除（请先移除引用）`);
    }
    // 先摘快照（remove 之后 id 会变成 undefined）
    const snapshot: DeletedMediaSnapshot = {
      id: String(media.id),
      mediaType: media.mediaType,
      isProtected: media.isProtected,
      sizeBytes: String(media.sizeBytes),
      sha256: media.sha256,
      fileKey: media.fileKey,
    };
    await this.mediaRepo.remove(media);
    try {
      await fs.unlink(this.absPath(media));
    } catch {
      this.logger.warn(`删除文件失败（可能已不存在）: ${media.fileKey}`);
    }
    this.logger.log(`媒体已删除 mediaId=${id}`);
    return snapshot;
  }

  /**
   * 引用计数：product 主图(cover)/视频/封面 + product_media + banner + top_worker + user 头像背景
   *
   * 【2026-10-05 复核：`home_banner` / `top_worker` 两条分支**保留不删**】
   *
   * 背景：这两个表的接口已标废弃（`/admin/home/banners*`、`/admin/home/top-workers*`，
   * 无任何调用方），公开字段 `banners` / `topWorkers` 也已从 `GET /public/home` 删除。
   *
   * 为什么仍然保留这两条 COUNT：
   * 1. **负责人明确要求表与列一律不删**，本次只清"代码路径与废弃接口"，不删数据。
   * 2. 引用计数的语义是"这个媒体文件还被任何表引用吗"，不是"还被接口暴露吗"。
   *    表还在、行还在，说明文件就**仍被持久化数据引用**：此时若不算这两条，
   *    管理端就能删掉一个仍被 `home_banner.image_media_id` 指向的媒体，
   *    而**该表的 DELETE 路由并未删除**（只是标废弃）—— 一旦有人（或遗留脚本）调用
   *    「删除 Banner」，删除动作会成功，但它本应参照的文件已被物理删除 → 悬空引用。
   * 3. 计数是"多算无害、少算有害"的不对称逻辑：多算只会更严格地拒绝删除（可人工强制），
   *    少算则会静默删掉仍被引用的文件。
   *
   * 因此本分支**随表一起保留**；将来负责人拍板删表时，这两条必须与表同时下线。
   */
  async referenceCount(id: string): Promise<number> {
    const queries: string[] = [
      `SELECT COUNT(*) c FROM product WHERE cover_media_id=? OR video_media_id=? OR video_cover_media_id=?`,
      `SELECT COUNT(*) c FROM product_media WHERE media_id=?`,
      `SELECT COUNT(*) c FROM home_banner WHERE image_media_id=?`,
      `SELECT COUNT(*) c FROM top_worker WHERE avatar_media_id=?`,
      `SELECT COUNT(*) c FROM user WHERE avatar_media_id=? OR background_media_id=?`,
      // 充值（负责人 2026-10-06）：收款码图 + 转账凭证。两者都必须参与引用计数 ——
      // 少了它们，"删除媒体"就能删掉一张仍被 `recharge_qr_code.media_id` 或
      // `recharge_request.proof_media_id` 指向的图，而那张申请/那张码仍指向它 → 悬空引用
      // （凭证尤其严重：资金凭证被物理删除，事后无法复核）。多算无害、少算有害。
      `SELECT COUNT(*) c FROM recharge_qr_code WHERE media_id=?`,
      `SELECT COUNT(*) c FROM recharge_request WHERE proof_media_id=?`,
      // 提现（负责人 2026-10-11）：收款码图 + 打款凭证。同 recharge 的理由 ——
      // 少了它们，"删除媒体"就能删掉一张仍被 `worker_withdraw_account.qr_media_id` 或
      // `withdraw_request.payout_proof_media_id` 指向的图 → 悬空引用。
      // 收款码尤其严重：管理端正在核对打款时图被删掉，等于打款去向无法复核。
      `SELECT COUNT(*) c FROM worker_withdraw_account WHERE qr_media_id=?`,
      `SELECT COUNT(*) c FROM withdraw_request WHERE payout_proof_media_id=?`,
    ];
    let total = 0;
    for (const q of queries) {
      const rows: Array<{ c: number | string }> = await this.mediaRepo.manager.query(q, [id, id, id]);
      total += Number(rows[0]?.c ?? 0);
    }
    return total;
  }
}
