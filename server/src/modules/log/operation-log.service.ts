import { Injectable } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import { OperationLog } from './operation-log.entity';

export interface OperationLogInput {
  /**
   * 操作者 user id。
   *
   * `null` 是**合法值**（2026-10-06 放宽）：有些配置写入走的是服务层内部路径
   * （如 `TipService` 保存预设、定时/内部调用），拿不到请求上下文里的管理员身份；
   * 这种情况下**宁可不写「谁」，也要写下「改了什么」**——留痕缺失比留痕不完整危险得多
   * （`operation_log.admin_id` 本来就是 nullable 列）。
   * 传 `''` 这类空串会让 bigint 列插入失败并被 catch 静默吞掉，所以**必须传 null**。
   */
  adminUserId: string | null;
  adminName: string;
  module: string;
  action: string;
  method: string;
  path: string;
  /** 调用方负责脱敏后的请求体摘要 */
  requestBody?: string | null;
  ip?: string | null;
  requestId?: string | null;
  result?: 'success' | 'fail';
  errorMsg?: string | null;
}

/** 操作日志写入（docs/09：管理员敏感操作全量审计） */
@Injectable()
export class OperationLogService {
  constructor(
    @InjectRepository(OperationLog) private readonly repo: Repository<OperationLog>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /** 异步写入，不阻塞主流程（失败仅告警）；未传 adminName 时按 adminUserId 查库补全 */
  log(input: OperationLogInput): void {
    void (async () => {
      try {
        let name: string | null = input.adminName ?? null;
        if (!name && input.adminUserId) {
          const rows: { nickname?: string }[] = await this.dataSource.query(
            'SELECT nickname FROM user WHERE id = ? LIMIT 1',
            [input.adminUserId],
          );
          name = rows[0]?.nickname ?? null;
        }
        await this.repo.save(
          this.repo.create({
            adminId: input.adminUserId,
            adminName: name?.slice(0, 32) ?? null,
            module: input.module,
            action: input.action,
            method: input.method,
            path: input.path.slice(0, 255),
            requestBody: input.requestBody?.slice(0, 4000) ?? null,
            ip: input.ip?.slice(0, 64) ?? null,
            requestId: input.requestId?.slice(0, 64) ?? null,
            result: input.result ?? 'success',
            errorMsg: input.errorMsg?.slice(0, 255) ?? null,
          }),
        );
      } catch (e) {
        // 审计失败不能阻断业务；错误输出便于运维发现
        // eslint-disable-next-line no-console
        console.error(`[OperationLog] 写入失败: ${e instanceof Error ? e.message : String(e)}`);
      }
    })();
  }
}
