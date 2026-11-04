import { Body, Controller, Delete, Get, Param, Post, Req, Res, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBearerAuth, ApiConsumes, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request, Response } from 'express';
import { memoryStorage } from 'multer';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { MediaService } from './media.service';

const MAX_UPLOAD = 100 * 1024 * 1024;

/** 媒体上传与访问（docs/08：公开通道 /media/public/:id，受保护通道 /media/protected/:id） */
@ApiTags('media')
@Controller('media')
export class MediaController {
  constructor(private readonly service: MediaService) {}

  /** 登录用户上传（头像 avatar / 背景 bg / 聊天图片 chat_image） */
  @Post('upload')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiConsumes('multipart/form-data')
  @ApiOperation({ summary: '用户上传媒体（avatar/bg/chat_image）' })
  @UseInterceptors(FileInterceptor('file', { storage: memoryStorage(), limits: { fileSize: MAX_UPLOAD } }))
  async upload(@UploadedFile() file: Express.Multer.File | undefined, @Body('type') type: string, @Req() req: { user: { userId: string } }) {
    const media = await this.service.upload(file?.buffer ?? Buffer.alloc(0), file?.originalname ?? '', type, req.user.userId);
    return {
      id: media.id,
      path: this.service.clientPath(media),
      mimeType: media.mimeType,
      width: media.width,
      height: media.height,
      sizeBytes: Number(media.sizeBytes),
    };
  }

  /** 公开资源（商品图/Banner/头像等） */
  @Get('public/:id')
  @ApiOperation({ summary: '公开媒体访问' })
  async publicDownload(@Param('id') id: string, @Res() res: Response) {
    const media = await this.service.findPublic(id);
    res.setHeader('Content-Type', media.mimeType);
    /**
     * 缓存头（2026-10-06 省流量专项：TTL 从 1 天加长到 30 天并声明 immutable）。
     *
     * 为什么 `immutable` 在这里是**安全**的（不是"图省事加个长 TTL"）：
     *   - 落盘文件名是 `YYYY/MM/<uuid>.<ext>`（media.service.ts 的 `randomUUID()`），
     *     **同 id 永远不会被写入不同内容** —— 换图 = 新上传 = 新 id；旧行只能被删除；
     *   - 内容按 sha256 去重：哈希相同才复用同一行，而复用意味着**内容本来就一样**；
     *   - 因此 `/media/public/:id` 是一个真正的"内容寻址不可变资源"，
     *     `immutable` 让客户端/中间层**连条件请求都不用发**（省掉的正是隧道流量）。
     *   - `res.sendFile` 走 Express 的 send，默认附带 `ETag` + `Last-Modified`：
     *     即便有客户端忽略 immutable，也仍有条件请求兜底（不会重复下载正文）。
     *
     * `no-transform`：显式要求中间代理**不要做任何转换**（尤其图片重压缩/格式转换）。
     * 与 APK 下载端点同一条理由 —— 前置代理（Cloudflare 的 Polish/WebP 之类）
     * 一旦转码，客户端可能拿到解码不了的字节，且"看起来只是图糊了"，极难排查。
     */
    res.setHeader('Cache-Control', 'public, max-age=2592000, immutable, no-transform');
    res.sendFile(this.service.absPath(media));
  }

  /** 受保护资源（聊天图片：上传者/会话成员/管理员可读，防 IDOR） */
  @Get('protected/:id')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: '受保护媒体访问（归属/会话成员校验）' })
  async protectedDownload(@Param('id') id: string, @Req() req: { user: { userId: string; role: string } }, @Res() res: Response) {
    const media = await this.service.findProtected(id);
    // 归属校验：上传者本人 / admin / 图片所在会话成员（docs/07 补充）
    const isOwner = String(media.uploaderId ?? '') === String(req.user.userId);
    const isAdmin = req.user.role === 'admin';
    const isMember = media.mediaType === 'chat_image' && (await this.service.isChatImageMember(id, req.user.userId));
    if (!isOwner && !isAdmin && !isMember) {
      res.status(404).send();
      return;
    }
    res.setHeader('Content-Type', media.mimeType);
    res.setHeader('Cache-Control', 'no-store');
    res.sendFile(this.service.absPath(media));
  }
}

/** 管理端媒体（上传商品图/视频/Banner/打手头像；删除） */
@ApiTags('admin/media')
@Controller('admin/media')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class MediaAdminController {
  constructor(
    private readonly service: MediaService,
    private readonly opLog: OperationLogService,
  ) {}

  @Post('upload')
  @RequirePermission('admin:media:write')
  @ApiConsumes('multipart/form-data')
  @ApiOperation({ summary: '管理端上传媒体（product_image/product_video/video_cover/banner/top_worker_avatar）' })
  @UseInterceptors(FileInterceptor('file', { storage: memoryStorage(), limits: { fileSize: MAX_UPLOAD } }))
  async upload(@UploadedFile() file: Express.Multer.File | undefined, @Body('type') type: string, @Req() req: { user: { userId: string } }) {
    const media = await this.service.upload(file?.buffer ?? Buffer.alloc(0), file?.originalname ?? '', type, req.user.userId);
    return {
      id: media.id,
      path: this.service.clientPath(media),
      mimeType: media.mimeType,
      width: media.width,
      height: media.height,
      sizeBytes: Number(media.sizeBytes),
    };
  }

  @Delete(':id')
  @RequirePermission('admin:media:write')
  @ApiOperation({ summary: '删除媒体（被引用时拒绝）' })
  async remove(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const removed = await this.service.deleteById(id);
    /**
     * 审计留痕（2026-10-13，负责人铁律）：删除媒体是**破坏性且不可逆**的动作
     * （删 `media` 行 + 物理删磁盘文件），必须记录"谁、什么时候、删了哪个 mediaId、
     * 什么用途、多大、sha256、原文件键"。实测改前真库 `operation_log` 里
     * **没有任何 media 动作**（`module='media'` / `path LIKE '%media%'` 均为 0 行）。
     *
     * **只给 DELETE 补，`upload` 刻意不补**（高频动作，逐张留痕会把 `operation_log` 淹没；
     * 审计的价值在"异常动作可回溯"）—— 取舍理由与完整说明写在 `media.module.ts`。
     *
     * `requestBody` 只记关键字段：不落文件内容、不落上传者令牌。
     * 记 `sha256` 是为了事后能证明"删掉的确实是哪一份内容"（内容寻址，同 id 内容永不变）。
     */
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'media',
      action: 'media:delete',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        mediaId: String(removed.id),
        mediaType: removed.mediaType,
        isProtected: removed.isProtected === 1,
        sizeBytes: Number(removed.sizeBytes),
        sha256: removed.sha256,
        fileKey: removed.fileKey,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { deleted: true };
  }
}
