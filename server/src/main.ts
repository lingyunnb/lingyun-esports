import { Logger, RequestMethod } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { IoAdapter } from '@nestjs/platform-socket.io';
import compression from 'compression';
import * as express from 'express';
import { existsSync } from 'fs';
import { join } from 'path';
import { AppModule } from './app.module';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';
import { PublicCacheInterceptor } from './common/interceptors/public-cache.interceptor';
import { ResponseInterceptor } from './common/interceptors/response.interceptor';
import { LenientValidationPipe } from './common/pipes/lenient-validation.pipe';

async function bootstrap() {
  // 生产安全闸（负责人 2026-10-05 邮箱验证）：console 发信驱动**不发真信**，只允许开发/自动化测试使用。
  // 若生产环境误配 MAIL_DRIVER=console，用户会看到「验证码已发送」但永远收不到邮件 —— 这是最隐蔽的故障，
  // 因此在启动阶段直接拒绝启动（fail fast），而不是留到线上靠用户投诉发现。
  //
  // 注意：pm2 的 ecosystem.config.js 会注入 NODE_ENV=production（本项目"生产"= 本机 pm2 常驻）。
  // 因此自动化测试需要 console 驱动时，必须**显式**加 MAIL_ALLOW_CONSOLE=true 这道第二把钥匙：
  // 单靠 MAIL_DRIVER=console 起不来，避免"误配一行就静默不发信"。
  if (
    process.env.NODE_ENV === 'production' &&
    String(process.env.MAIL_DRIVER ?? 'smtp').toLowerCase() === 'console' &&
    String(process.env.MAIL_ALLOW_CONSOLE ?? 'false').toLowerCase() !== 'true'
  ) {
    throw new Error(
      'MAIL_DRIVER=console 禁止在生产环境使用（它不会真的发信，请改为 smtp）；' +
        '确需在测试中启用请显式设置 MAIL_ALLOW_CONSOLE=true',
    );
  }

  const app = await NestFactory.create(AppModule);

  // Socket.IO 适配器（docs/07：/ws/chat 实时网关，派单通知与聊天共用）
  app.useWebSocketAdapter(new IoAdapter(app));

  // 响应压缩（负责人 2026-10-04：继续更快）——JSON/文本走 gzip，隧道带宽占用降到约 1/5
  //
  // threshold 从 1024 下调到 512（2026-10-04 性能专项实测）：
  // 8 个关键公开接口里只有 `/public/products`（2.5KB）超过 1KB，其余（`/divisions` 1276B、
  // `/public/home` 877B、`/public/players` 403B…）**全部不低于阈值也全部没压缩**。
  // 而"是否压缩"由客户端是否发 Accept-Encoding 决定（Express compression 只看请求头），
  // 客户端侧已统一补上该请求头，这里把门槛降低让中小响应也吃上压缩。
  // 512 是权衡值：更小的响应（<512B，如 `/public/leaderboard` 245B）压缩后反而更大
  // （gzip 头约 20 字节 + CPU），不值得。
  app.use(compression({ threshold: 512 }));

  // 全局前缀 /api/v1；公开媒体排除在外：客户端统一使用 /media/public/:id 直链
  // （修复：此前全部媒体 URL 生成时不含前缀，真机/隧道访问 404 导致头像/背景/商品图/论坛媒体全部加载失败）
  app.setGlobalPrefix('api/v1', {
    exclude: [{ path: 'media/public/(.*)', method: RequestMethod.GET }],
  });
  app.enableCors({
    origin: process.env.CORS_ORIGINS ? process.env.CORS_ORIGINS.split(',') : true,
    credentials: true,
  });

  // 全局管道：白名单校验，拒绝未知字段（docs/03 安全铁律）
  // 更新类/简介类 DTO 继承 LenientUpdateDto 后，本管道会对其放宽为「未知字段静静忽略」
  // （见 common/pipes/lenient-validation.pipe.ts；其余接口行为完全不变）
  app.useGlobalPipes(new LenientValidationPipe());
  // 公开字典类接口服务端微缓存（30s）——挡掉大部分重复查询
  app.useGlobalInterceptors(new PublicCacheInterceptor());
  app.useGlobalInterceptors(new ResponseInterceptor());
  app.useGlobalFilters(new AllExceptionsFilter());

  // 托管管理端（admin-web/dist）：一个地址同时提供管理端页面 + API + 媒体，
  // 外网（Cloudflare 隧道/局域网）访问根路径即为管理后台，无需单独部署前端（docs/11）
  const adminDist = join(__dirname, '..', '..', 'admin-web', 'dist');
  // 请求日志（2026-09-25 排查消息页空白问题加入，注释写"定位后移除"但一直留着）
  //
  // 2026-10-04 性能专项：生产环境（NODE_ENV=production，pm2 当前就是这个）**每个 API 请求**
  // 都同步写一行日志 —— 高频轮询（聊天 sync、订单列表 SWR 回源）下这是实打实的额外开销，
  // 且线上日志没有排查价值（本地开发才有）。因此仅在非生产环境保留。
  if (process.env.NODE_ENV !== 'production') {
    app.use((req: express.Request, res: express.Response, next: express.NextFunction) => {
      const t0 = Date.now();
      res.on('finish', () => {
        if (req.path.startsWith('/api/')) {
          Logger.log(`${req.method} ${req.path} → ${res.statusCode} (${Date.now() - t0}ms)`, 'HTTP');
        }
      });
      next();
    });
  }

  // 官网静态页（负责人 2026-09-25：俱乐部官网，内容由 /api/v1/public/site 驱动）
  const siteDist = join(__dirname, '..', '..', 'site');
  if (existsSync(join(siteDist, 'index.html'))) {
    app.use('/site', express.static(siteDist));
  }

  // UI 设计稿评审页（2026-10-03：改版设计图供负责人在线审批，纯静态，不进数据库）
  const designDist = join(__dirname, '..', '..', 'site', 'design');
  if (existsSync(join(designDist, 'index.html'))) {
    app.use('/design', express.static(designDist));
    // 已撤下的设计图必须返回 404，**不能**被下面的 SPA 回退成管理端 HTML
    // （否则浏览器里显示 200 + HTML，表现为破图/空白，极难排查）
    app.use('/design', (req: express.Request, res: express.Response) => {
      res.status(404).json({ code: 404, message: 'Not Found', data: null });
    });
  }

  // 网页版 H5（2026-10-15 负责人定案：另写 Vue3 H5，覆盖 iOS / PC / 不想装 App 的用户）
  //
  // 为什么挂在 `/h5/` 而不是单独开端口/域名：
  //   · 与管理端**同源同进程** → 前端一律走相对路径 `/api/v1`，**零 CORS、零额外证书、零额外运维**；
  //   · 管理端已占根路径 `/`，H5 让一位即可（`vite.config.ts` 的 `base: '/h5/'` 与此对应）。
  // ⚠️ 必须注册在**管理端 SPA 回退之前**：Express 按注册顺序匹配，放后面会被管理端的兜底抢走。
  const h5Dist = join(__dirname, '..', '..', 'h5-web', 'dist');
  if (existsSync(join(h5Dist, 'index.html'))) {
    // ⚠️ **不要写 `{ index: true }`**：`send` 只接受"字符串数组或 false"，
    //    传布尔 true 会在**每次请求时**抛 `TypeError: index option must be array of strings or false`
    //    → 表现为 `/h5/` 恒 500（而健康检查仍 200，因为那是另一个路由）。
    //    省略 `index` 即用默认值 `'index.html'`，正是我们要的行为。
    app.use('/h5', express.static(h5Dist));
    // SPA 回退：`/h5/orders/123` 这类**前端路由**直接刷新时要回 index.html，否则 404
    app.use('/h5', (req: express.Request, res: express.Response) => {
      res.sendFile(join(h5Dist, 'index.html'));
    });
  }

  if (existsSync(adminDist)) {
    app.use(express.static(adminDist, { index: false }));
    app.use((req: express.Request, res: express.Response, next: express.NextFunction) => {
      if (req.method !== 'GET' && req.method !== 'HEAD') return next();
      const p = req.path;
      // API / 媒体 / WebSocket / Swagger 交给 Nest 处理，不做 SPA 回退
      if (p.startsWith('/api/') || p.startsWith('/media/') || p.startsWith('/socket.io') || p.startsWith('/api-docs')) {
        return next();
      }
      // 敏感路径防护（docs/09）：点文件段（/.env、/.git…）与常见配置文件名不做 SPA 回退，一律 404
      const sensitiveFiles = new Set([
        '.env', 'package.json', 'package-lock.json', 'yarn.lock', 'composer.json',
        'dockerfile', 'docker-compose.yml', 'docker-compose.yaml', '.gitignore', '.npmrc', 'server.key', 'server.crt',
      ]);
      const segs = p.split('/').filter(Boolean).map((s) => s.toLowerCase());
      if (segs.some((s) => s.startsWith('.')) || segs.some((s) => sensitiveFiles.has(s))) {
        res.status(404).json({ code: 404, message: 'Not Found', data: null });
        return;
      }
      res.sendFile(join(adminDist, 'index.html'));
    });
  }

  // Swagger 仅非生产环境开启（docs/03）
  if (process.env.NODE_ENV !== 'production') {
    const config = new DocumentBuilder()
      .setTitle('平台 API')
      .setDescription('老板端 / 工作端 / 管理后台统一 API（/api/v1）。规范见 docs/03。')
      .setVersion('0.1.0')
      .addBearerAuth()
      .build();
    const document = SwaggerModule.createDocument(app, config);
    SwaggerModule.setup('api-docs', app, document);
  }

  // 3100 为 FISH 专属端口（3000 被本机 OtherProject nssm 服务占用，docs/11 铁律）
  const port = Number(process.env.PORT ?? 3100);
  // 监听 0.0.0.0：手机真机与 Cloudflare Tunnel 均依赖
  await app.listen(port, '0.0.0.0');
  console.log(`[server] listening on http://0.0.0.0:${port} (NODE_ENV=${process.env.NODE_ENV ?? 'development'})`);
}
void bootstrap();
