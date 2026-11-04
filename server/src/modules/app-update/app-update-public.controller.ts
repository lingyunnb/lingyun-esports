import { Controller, Get, Param, Query, Req, Res } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request, Response } from 'express';
import { createReadStream } from 'fs';
import { pipeline } from 'stream';
import { AppUpdateService } from './app-update.service';

/** 客户端公开接口（老板端专用，服务端版本比较与安全校验） */
@ApiTags('public/app-versions')
@Controller('public/app-versions')
export class AppUpdatePublicController {
  constructor(private readonly service: AppUpdateService) {}

  @Get('latest')
  @ApiOperation({ summary: '查询最新启用版本（服务端比较 currentVersionCode，返回 hasUpdate/force/latest）' })
  async latest(@Query('appType') appType: string, @Query('currentVersionCode') currentVersionCode: string) {
    return this.service.latest(appType ?? 'boss', Number(currentVersionCode ?? 0));
  }

  /**
   * 把安装包（或其中一段）写进响应：流式 + **客户端一断开就回收文件句柄**。
   *
   * 为什么不再用 `createReadStream(...).pipe(res)`（2026-10-17 修）：
   * `pipe` 在**客户端提前断开**时不会 destroy 源流 —— 每次中断都会留下一个没被回收的
   * 读流 + 文件句柄（fd）。而本项目的现场形态恰恰是"链路差 → 手机反复中断重试"，
   * 于是**越是弱网越会堆泄漏**，这是独立于"卡在 75%"的真问题。
   * `pipeline` 在任一侧结束时同时销毁两侧；再加一个 `close` 兜底，保证响应一关就收掉句柄。
   */
  private sendFile(res: Response, filePath: string, opts?: { start?: number; end?: number }): void {
    const src = createReadStream(filePath, opts);
    const onClose = (): void => {
      if (!src.destroyed) src.destroy();
    };
    res.on('close', onClose);
    pipeline(src, res, () => {
      // 正常发完、或客户端中途断开（ERR_STREAM_PREMATURE_CLOSE）都走这里：
      // pipeline 已回收两侧资源，这里只摘掉兜底监听。
      res.off('close', onClose);
    });
  }

  @Get('download/:id')
  @ApiOperation({ summary: '下载安装包（仅启用版本可下载；支持 Range 断点续传）' })
  async download(@Param('id') id: string, @Req() req: Request, @Res() res: Response) {
    const v = await this.service.forDownload(id);
    const fileSize = Number(v.fileSize);
    const range = req.headers.range;
    res.setHeader('Content-Type', 'application/vnd.android.package-archive');
    // 客户端据此判定"能不能分片并行"（拿不到就会退回单连接整包）
    res.setHeader('Accept-Ranges', 'bytes');
    // 显式要求中间代理**不要做任何转换**（尤其压缩）：APK 已被压缩过，再 gzip 既无用
    // 又会破坏 Range 语义（2026-10-06 提速专项）。当前 Content-Type 不在压缩白名单里，
    // 这行是"将来有人加了 compression 白名单也别压"的保险。
    res.setHeader('Cache-Control', 'no-transform');
    // 断点续传（慢速网络/断网重试场景：客户端带 Range 续传）
    if (typeof range === 'string') {
      const m = /bytes=(\d+)-(\d*)/.exec(range);
      if (m) {
        const start = Number(m[1]);
        const end = m[2] ? Math.min(Number(m[2]), fileSize - 1) : fileSize - 1;
        if (start < 0 || start > end || start >= fileSize) {
          res.status(416).setHeader('Content-Range', `bytes */${fileSize}`).end();
          return;
        }
        res.status(206);
        res.setHeader('Content-Range', `bytes ${start}-${end}/${fileSize}`);
        res.setHeader('Content-Length', end - start + 1);
        this.sendFile(res, v.filePath, { start, end });
        return;
      }
    }
    res.setHeader('Content-Length', fileSize);
    res.setHeader('Content-Disposition', `attachment; filename="${encodeURIComponent(v.fileName)}"`);
    this.sendFile(res, v.filePath);
  }
}
