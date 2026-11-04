import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectRepository } from '@nestjs/typeorm';
import { createHash } from 'crypto';
import { createReadStream, existsSync } from 'fs';
import { mkdirSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { Repository } from 'typeorm';
import { AppVersion } from './app-version.entity';

/** 安装包存储目录（MEDIA_ROOT/app-versions，与媒体同一数据盘） */
@Injectable()
export class AppUpdateService {
  constructor(
    @InjectRepository(AppVersion) private readonly repo: Repository<AppVersion>,
    private readonly config: ConfigService,
  ) {}

  uploadDir(): string {
    const root = this.config.get<string>('MEDIA_ROOT', 'D:/fish/data/uploads');
    const dir = join(root, 'app-versions');
    mkdirSync(dir, { recursive: true });
    return dir;
  }

  /** 保存上传的 APK：磁盘落盘 + sha256/大小 + 版本记录（同 appType+versionCode 唯一） */
  async createVersion(dto: {
    appType: string;
    versionCode: number;
    versionName: string;
    updateDesc: string;
    forceUpdate: boolean;
    minSupportedVersion?: number;
    fileName: string;
    filePath: string;
    uploadedBy: string;
  }) {
    if (!Number.isInteger(dto.versionCode) || dto.versionCode < 1) {
      throw new BadRequestException('版本号必须为大于 0 的整数');
    }
    if (!dto.versionName?.trim()) throw new BadRequestException('版本名称不能为空');
    if (!existsSync(dto.filePath)) throw new BadRequestException('安装包文件不存在');
    const dup = await this.repo.findOne({
      where: { appType: dto.appType, versionCode: dto.versionCode },
    });
    if (dup) throw new BadRequestException(`版本号 ${dto.versionCode} 已存在（请使用更大的版本号）`);
    const { size, hash } = await this.fileMeta(dto.filePath);
    return this.repo.save(
      this.repo.create({
        appType: dto.appType === 'worker' ? 'worker' : 'boss',
        versionCode: dto.versionCode,
        versionName: dto.versionName.trim().slice(0, 32),
        updateDesc: (dto.updateDesc ?? '').trim().slice(0, 4000),
        forceUpdate: dto.forceUpdate ? 1 : 0,
        minSupportedVersion: Number.isInteger(dto.minSupportedVersion) ? (dto.minSupportedVersion as number) : 1,
        fileName: dto.fileName,
        fileSize: String(size),
        fileHash: hash,
        filePath: dto.filePath,
        status: 1,
        uploadedBy: dto.uploadedBy,
      }),
    );
  }

  private fileMeta(filePath: string): Promise<{ size: number; hash: string }> {
    return new Promise((resolve, reject) => {
      const hash = createHash('sha256');
      let size = 0;
      const stream = createReadStream(filePath);
      stream.on('data', (c) => {
        size += c.length;
        hash.update(c);
      });
      stream.on('end', () => resolve({ size, hash: hash.digest('hex') }));
      stream.on('error', reject);
    });
  }

  /** 管理端列表（含上传人账号） */
  async adminList(appType?: string) {
    const qb = this.repo
      .createQueryBuilder('v')
      .leftJoin('user', 'u', 'u.id = v.uploaded_by')
      .select([
        'v.id AS id', 'v.app_type AS appType', 'v.version_code AS versionCode', 'v.version_name AS versionName',
        'v.update_desc AS updateDesc', 'v.force_update AS forceUpdate', 'v.min_supported_version AS minSupportedVersion',
        'v.file_name AS fileName', 'v.file_size AS fileSize', 'v.file_hash AS fileHash',
        'v.mirror_url AS mirrorUrl',
        'v.status AS status', 'u.username AS uploader', 'v.created_at AS createdAt', 'v.updated_at AS updatedAt',
      ]);
    if (appType) qb.where('v.app_type = :appType', { appType });
    const list = await qb.orderBy('v.version_code', 'DESC').getRawMany();
    return { list };
  }

  /** 启用/停用版本（无删除接口：正在使用的版本不可被物理删除） */
  async setStatus(id: string, status: number) {
    if (status !== 1 && status !== 2) throw new BadRequestException('状态取值须为 1（启用）或 2（停用）');
    const v = await this.repo.findOne({ where: { id } });
    if (!v) throw new NotFoundException('版本记录不存在');
    v.status = status;
    return this.repo.save(v);
  }

  /** 客户端查询：服务端做版本比较与安全校验（客户端传入版本号只用于比较，不返回未启用版本） */
  async latest(appType: string, currentVersionCode: number) {
    const t = appType === 'worker' ? 'worker' : 'boss';
    const v = await this.repo.findOne({
      where: { appType: t, status: 1 },
      order: { versionCode: 'DESC' },
    });
    if (!v) return { hasUpdate: false };
    const cur = Number.isInteger(currentVersionCode) && currentVersionCode > 0 ? currentVersionCode : 0;
    const hasUpdate = v.versionCode > cur;
    return {
      hasUpdate,
      force: hasUpdate && v.forceUpdate === 1,
      latest: hasUpdate
        ? {
            versionCode: v.versionCode,
            versionName: v.versionName,
            updateDesc: v.updateDesc,
            fileSize: Number(v.fileSize),
            fileHash: v.fileHash,
            // 多源：配了镜像就下发**绝对地址**（客户端原样透传），否则走服务端下载接口。
            // 两种形态对客户端是同一个字段，所以换源不需要发版（详见 docs/16 与本次提速报告）。
            downloadUrl: this.mirrorOrLocal(v),
            /** 源类型，便于客户端/排障区分（'mirror' | 'origin'）；老客户端忽略未知字段 */
            downloadSource: this.isUsableMirror(v.mirrorUrl) ? 'mirror' : 'origin',
          }
        : null,
    };
  }

  /** 镜像地址是否可用（必须是 http(s) 绝对地址；空串/相对路径一律视为未配置） */
  private isUsableMirror(url?: string | null): boolean {
    const u = (url ?? '').trim();
    return u.startsWith('https://') || u.startsWith('http://');
  }

  /** 优先用镜像绝对地址；未配置则回落到服务端下载接口（相对路径） */
  private mirrorOrLocal(v: AppVersion): string {
    if (this.isUsableMirror(v.mirrorUrl)) return (v.mirrorUrl ?? '').trim();
    return `/api/v1/public/app-versions/download/${v.id}`;
  }

  /**
   * 设置/清除某版本的镜像下载地址（运维多源切换）。
   *
   * 安全口径：只允许 http(s) 绝对地址或空串（清除）；**禁止**其它协议
   * （避免把 `file://`/`javascript:` 之类塞进来被客户端当下载源）。
   * 不改文件本体、不改 sha256 → 内容一致性仍由客户端 sha256 校验兜底。
   */
  async setMirrorUrl(id: string, mirrorUrl: string | null) {
    const v = await this.repo.findOne({ where: { id } });
    if (!v) throw new NotFoundException('版本记录不存在');
    const raw = (mirrorUrl ?? '').trim();
    if (raw !== '' && !this.isUsableMirror(raw)) {
      throw new BadRequestException('镜像地址必须是 http(s) 绝对地址（留空表示清除镜像）');
    }
    if (raw.length > 512) throw new BadRequestException('镜像地址过长（最多 512 字符）');
    v.mirrorUrl = raw === '' ? null : raw;
    await this.repo.save(v);
    return { ok: true, id: v.id, mirrorUrl: v.mirrorUrl };
  }

  /** 供下载：仅启用中的版本可下载（安全校验：不存在/停用/文件缺失均拒绝） */
  async forDownload(id: string) {
    const v = await this.repo.findOne({ where: { id, status: 1 } });
    if (!v) throw new NotFoundException('安装包不存在或已停用');
    if (!existsSync(v.filePath)) throw new NotFoundException('安装包文件缺失，请联系管理员重新上传');
    return v;
  }

  /** 上传文件名（磁盘随机名，防路径穿越） */
  static storageName(original: string): string {
    const ext = original.toLowerCase().endsWith('.apk') ? '.apk' : '';
    return `${Date.now()}-${randomUUID()}${ext}`;
  }
}
