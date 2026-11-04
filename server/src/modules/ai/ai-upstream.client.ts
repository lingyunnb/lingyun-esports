import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { appendFileSync } from 'fs';

export type ChatRole = 'system' | 'user' | 'assistant';

export interface UpstreamMessage {
  role: ChatRole;
  content: string;
}

export interface StreamChatOptions {
  messages: UpstreamMessage[];
  /** 外部中断（/user/ai/stop 或全局取消） */
  signal?: AbortSignal;
  /** 增量回调（每个 SSE delta 一次） */
  onDelta: (delta: string) => void;
  /** 无数据超时（毫秒，默认 20000：这么久没有任何字节到达即中断） */
  idleTimeoutMs?: number;
  /** 整段回复硬上限（毫秒，默认 60000） */
  totalTimeoutMs?: number;
  /**
   * 请求体落盘标签（仅用于**验收取证**：设了它、且 env `AI_DUMP_PROMPT_FILE` 有值时，
   * 本次请求的 messages 全文会追加到该文件）。
   *
   * 为什么这样设计：脱敏要靠可核验的证据，而不是"我保证没喂"。
   * - 默认不落盘（不传 debugTag = 永不落盘），生产日志里不会出现会话内容；
   * - 只有找陪玩推荐传 `'recommend'`，验收脚本读该文件逐条断言不含手机号/真实姓名。
   */
  debugTag?: string;
}

export interface StreamChatResult {
  ok: boolean;
  /** 已流出的全文（中断时是部分文本） */
  content: string;
  /** 上游 HTTP 状态（网络层失败为 null） */
  status: number | null;
  /** 失败原因（仅记日志用，不含用户内容） */
  error?: string;
  /** 无数据超时被中断 */
  timedOut: boolean;
  /** 被外部 signal 中断（用户点了停止） */
  aborted: boolean;
}

/**
 * GLM（智谱）OpenAI 兼容 `/chat/completions` 流式客户端。
 *
 * 约束（负责人要求）：**不加任何 npm 依赖** —— 只用 Node 内置 fetch + 手写 SSE 解析。
 * key / baseUrl / model 全部来自环境变量（server/.env），绝不下发客户端、绝不硬编码。
 */
@Injectable()
export class AiUpstreamClient {
  private readonly logger = new Logger('AiUpstream');

  constructor(private readonly config: ConfigService) {}

  get provider(): string {
    return this.config.get<string>('AI_PROVIDER') ?? 'glm';
  }

  get model(): string {
    return this.config.get<string>('AI_MODEL') ?? '';
  }

  /** key 是否配置（未配置 → 直接走规则兜底，不打网络） */
  get configured(): boolean {
    return !!(this.config.get<string>('AI_API_KEY') ?? '').trim() && !!this.endpoint();
  }

  private endpoint(): string {
    const base = (this.config.get<string>('AI_BASE_URL') ?? '').trim();
    if (!base) return '';
    return `${base.replace(/\/+$/, '')}/chat/completions`;
  }

  /**
   * 流式对话。永不抛异常：网络/HTTP/解析错误一律以 `ok:false` 返回，由调用方降级。
   * 超时策略：idle 计时器每收到一段数据重置（"20 秒无响应即中断"）；
   * 另有 totalTimeoutMs 硬上限兜底（防上游极慢但仍持续吐字节）。
   */
  async streamChat(opts: StreamChatOptions): Promise<StreamChatResult> {
    const idleTimeoutMs = opts.idleTimeoutMs ?? 20000;
    const totalTimeoutMs = opts.totalTimeoutMs ?? 60000;
    const apiKey = (this.config.get<string>('AI_API_KEY') ?? '').trim();
    const url = this.endpoint();
    const model = this.model;

    const out: StreamChatResult = { ok: false, content: '', status: null, timedOut: false, aborted: false };
    if (!apiKey || !url || !model) {
      out.error = 'not_configured';
      return out;
    }

    // 内部中断源：idle/total 超时 + 外部 signal 都会 abort 它（fetch 的中断只能由自己创建）
    const ctrl = new AbortController();
    let idleTimer: NodeJS.Timeout | null = null;
    let totalTimer: NodeJS.Timeout | null = null;
    let timedOut = false;
    const onExternalAbort = () => ctrl.abort();
    if (opts.signal) {
      if (opts.signal.aborted) {
        out.aborted = true;
        out.error = 'aborted_before_start';
        return out;
      }
      opts.signal.addEventListener('abort', onExternalAbort, { once: true });
    }
    const armIdle = () => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        timedOut = true;
        ctrl.abort();
      }, idleTimeoutMs);
    };
    totalTimer = setTimeout(() => {
      timedOut = true;
      ctrl.abort();
    }, totalTimeoutMs);
    armIdle();

    try {
      if (opts.debugTag) this.dumpPrompt(opts.debugTag, opts.messages);
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'text/event-stream',
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model,
          messages: opts.messages,
          stream: true,
          temperature: 0.6,
          max_tokens: 512,
        }),
        signal: ctrl.signal,
      });
      out.status = res.status;
      if (!res.ok || !res.body) {
        const detail = await res.text().catch(() => '');
        // 只记状态码与上游错误摘要（不含用户消息、不含 key）
        out.error = `http_${res.status}: ${detail.replace(/\s+/g, ' ').slice(0, 200)}`;
        return out;
      }

      const reader = (res.body as ReadableStream<Uint8Array>).getReader();
      const decoder = new TextDecoder('utf-8');
      let buffer = '';
      let done = false;
      while (!done) {
        const { value, done: streamDone } = await reader.read();
        if (streamDone) break;
        if (!value) continue;
        armIdle(); // 有数据到达 → 重置"无响应"计时
        buffer += decoder.decode(value, { stream: true });
        // 按行切分，最后一段留在 buffer 里等下一块（手写 SSE：只认 data: 行）
        let nl = buffer.indexOf('\n');
        while (nl >= 0) {
          const line = buffer.slice(0, nl).replace(/\r$/, '');
          buffer = buffer.slice(nl + 1);
          if (line.startsWith('data:')) {
            const payload = line.slice(5).trim();
            if (payload === '[DONE]') {
              done = true;
              break;
            }
            if (payload) {
              const delta = this.extractDelta(payload);
              if (delta === null) {
                // 上游在流里回错误对象（GLM 偶发）：记摘要并中断
                out.error = `stream_error: ${payload.replace(/\s+/g, ' ').slice(0, 200)}`;
                done = true;
                break;
              }
              if (delta) {
                out.content += delta;
                opts.onDelta(delta);
              }
            }
          }
          nl = buffer.indexOf('\n');
        }
      }
      out.ok = !out.error;
      return out;
    } catch (e) {
      const err = e as { name?: string; message?: string };
      if (timedOut) out.error = 'timeout';
      else if (err?.name === 'AbortError') {
        out.aborted = !!opts.signal?.aborted;
        out.error = out.aborted ? 'stopped' : 'aborted';
      } else {
        out.error = `fetch_failed: ${(err?.message ?? String(e)).slice(0, 160)}`;
      }
      return out;
    } finally {
      if (idleTimer) clearTimeout(idleTimer);
      if (totalTimer) clearTimeout(totalTimer);
      opts.signal?.removeEventListener('abort', onExternalAbort);
      out.content = out.content.trim();
    }
  }

  /** 从一条 SSE data 载荷里取 delta 文本；null = 上游错误对象 */
  private extractDelta(payload: string): string | null {
    let json: {
      error?: unknown;
      choices?: Array<{ delta?: { content?: unknown } }>;
    };
    try {
      json = JSON.parse(payload) as typeof json;
    } catch {
      return ''; // 非 JSON 的心跳/注释行，忽略
    }
    if (json.error) return null;
    const c = json.choices?.[0]?.delta?.content;
    return typeof c === 'string' ? c : '';
  }

  /**
   * 验收取证：把**将要发给上游的 messages 全文**追加到 `AI_DUMP_PROMPT_FILE`。
   *
   * - 只有显式传 `debugTag` 的调用才会走这里（当前只有找陪玩推荐），且必须显式配置 env 文件路径；
   * - 未配置 / 写失败一律忽略（绝不能因为取证影响正常问答）；
   * - 落盘内容就是请求体里的 messages（不含 apiKey），验收脚本据此断言"上游请求里没有敏感字段"。
   */
  private dumpPrompt(tag: string, messages: UpstreamMessage[]): void {
    const file = (this.config.get<string>('AI_DUMP_PROMPT_FILE') ?? '').trim();
    if (!file) return;
    try {
      appendFileSync(file, `${JSON.stringify({ at: new Date().toISOString(), tag, messages })}\n`, 'utf8');
    } catch (e) {
      this.logger.warn(`prompt dump failed: ${(e as Error).message}`);
    }
  }
}
