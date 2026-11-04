import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Response } from 'express';
import {
  isChineseMessage,
  toChineseFallbackMessage,
  type ValidationFieldError,
} from '../pipes/validation-messages';

/**
 * 全局异常过滤器：统一错误响应结构；500 不向客户端泄露堆栈（docs/03、docs/09）
 *
 * 2026-10-04 中文化加固（负责人报障"英文校验文案"）：
 * - 校验类 400 的 `fields[]`（字段级中文错误）**原样透传**，客户端据此把提示落到输入框下方；
 * - 任何**纯英文**的 HTTP 错误消息（body-parser 的 JSON 解析失败、
 *   `Validation failed (uuid is expected)` 之类）一律换成中文兜底文案，
 *   并把原文打 warn 供排查 —— 保证客户端永远不会看到英文原文。
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Exception');

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest();
    const requestId: string = request.requestId ?? '';

    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    let message = '服务器内部错误';
    let errorCode: string | undefined;
    let fields: ValidationFieldError[] | undefined;

    if (exception instanceof HttpException) {
      status = exception.getStatus();
      const body = exception.getResponse();
      if (typeof body === 'string') {
        message = body;
      } else if (body && typeof body === 'object') {
        const msg = (body as Record<string, unknown>).message;
        message = Array.isArray(msg) ? msg.join('；') : String(msg ?? exception.message);
        // 业务错误码透传（如 ACCOUNT_BANNED），客户端据此做差异化处理（弹窗等）
        const ec = (body as Record<string, unknown>).errorCode;
        if (typeof ec === 'string') errorCode = ec;
        // 校验字段明细透传（中文化在 LenientValidationPipe.exceptionFactory 里已完成）
        const rawFields = (body as Record<string, unknown>).fields;
        if (Array.isArray(rawFields)) {
          fields = rawFields.filter((f): f is ValidationFieldError => !!f && typeof f === 'object');
        }
      }
      // 纯英文消息 → 中文兜底（保留原文到日志）
      if (!isChineseMessage(message)) {
        this.logger.warn(
          `HTTP 错误消息为纯英文，已替换中文兜底 requestId=${requestId} method=${request.method} path=${request.path} status=${status} raw=${this.clip(message)}`,
        );
        message = toChineseFallbackMessage(message, status);
      }
    } else {
      // 未预期异常：记录完整堆栈供排查，客户端只看到通用文案
      this.logger.error(
        `未捕获异常 requestId=${requestId} method=${request.method} path=${request.path}`,
        exception instanceof Error ? exception.stack : String(exception),
      );
    }

    response.status(status).json({
      code: status,
      message,
      data: null,
      requestId,
      timestamp: Date.now(),
      ...(errorCode ? { errorCode } : {}),
      ...(fields && fields.length > 0 ? { fields } : {}),
    });
  }

  /** 日志里保留原文但截断，避免 SQL/堆栈把日志刷爆 */
  private clip(text: string, max = 300): string {
    const t = String(text ?? '');
    return t.length > max ? `${t.slice(0, max)}…` : t;
  }
}
