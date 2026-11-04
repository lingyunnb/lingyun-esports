import { BadRequestException, Body, Controller, Get, Param, Post, Query, Req, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { ApiBearerAuth, ApiConsumes, ApiOperation, ApiTags } from '@nestjs/swagger';
import { FileInterceptor } from '@nestjs/platform-express';
import { Request } from 'express';
import { diskStorage } from 'multer';
import { mkdirSync } from 'fs';
import { join } from 'path';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { AppUpdateService } from './app-update.service';

const MAX_APK = 500 * 1024 * 1024; // 500MB 上限

/** 安装包磁盘目录（与媒体同一数据盘 MEDIA_ROOT；同步函数供 multer 使用） */
function appVersionsDir(): string {
  const root = process.env.MEDIA_ROOT || 'D:/fish/data/uploads';
  const dir = join(root, 'app-versions');
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** 管理端：老板端版本更新（负责人云端更新需求） */
@ApiTags('admin/app-versions')
@Controller('admin/app-versions')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class AppUpdateAdminController {
  constructor(
    private readonly service: AppUpdateService,
    private readonly opLog: OperationLogService,
  ) {}

  @Post('upload')
  @RequirePermission('admin:app:write')
  @ApiConsumes('multipart/form-data')
  @ApiOperation({ summary: '权限点 admin:app:write：上传 APK（磁盘落盘 + sha256 + 版本记录）' })
  @UseInterceptors(
    FileInterceptor('file', {
      storage: diskStorage({
        destination: (req, file, cb) => {
          try {
            cb(null, appVersionsDir());
          } catch (e) {
            cb(e as Error, '');
          }
        },
        filename: (req, file, cb) => cb(null, AppUpdateService.storageName(file.originalname)),
      }),
      limits: { fileSize: MAX_APK },
      fileFilter: (req, file, cb) => {
        if (!/\.apk$/i.test(file.originalname)) {
          return cb(new Error('仅支持 .apk 安装包'), false);
        }
        cb(null, true);
      },
    }),
  )
  async upload(
    @UploadedFile() file: Express.Multer.File | undefined,
    @Body() body: { appType?: string; versionCode?: string; versionName?: string; updateDesc?: string; forceUpdate?: string; minSupportedVersion?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    if (!file) throw new BadRequestException('未接收到安装包文件');
    const result = await this.service.createVersion({
      appType: body.appType ?? 'boss',
      versionCode: Number(body.versionCode ?? 0),
      versionName: body.versionName ?? '',
      updateDesc: body.updateDesc ?? '',
      forceUpdate: body.forceUpdate === 'true' || body.forceUpdate === '1',
      minSupportedVersion: body.minSupportedVersion ? Number(body.minSupportedVersion) : undefined,
      fileName: file.originalname,
      filePath: file.path,
      uploadedBy: user.userId,
    });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'app-update',
      action: 'app-version:upload',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        appType: body.appType ?? 'boss',
        versionCode: body.versionCode,
        versionName: body.versionName,
        forceUpdate: body.forceUpdate,
        fileName: file.originalname,
        fileSize: file.size,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { id: result.id, fileHash: result.fileHash, fileSize: result.fileSize };
  }

  @Get()
  @RequirePermission('admin:app:write')
  @ApiOperation({ summary: '版本历史列表（含哈希/大小/上传人/状态）' })
  list(@Query('appType') appType?: string) {
    return this.service.adminList(appType);
  }

  @Post(':id/mirror')
  @RequirePermission('admin:app:write')
  @ApiOperation({ summary: '设置/清除版本的镜像(CDN)下载地址（多源提速；留空=清除，回落服务端下载接口）' })
  async setMirror(
    @Param('id') id: string,
    @Body() dto: { mirrorUrl?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.setMirrorUrl(id, dto.mirrorUrl ?? null);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'app-update',
      action: 'app-version:mirror',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ id, mirrorUrl: result.mirrorUrl }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Post(':id/status')
  @RequirePermission('admin:app:write')
  @ApiOperation({ summary: '启用/停用版本（无删除接口，保护使用中的版本）' })
  async setStatus(
    @Param('id') id: string,
    @Body() dto: { status: number },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.setStatus(id, dto.status);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'app-update',
      action: `app-version:${dto.status === 1 ? 'enable' : 'disable'}`,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ id, status: dto.status, versionCode: result.versionCode }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { ok: true };
  }
}
