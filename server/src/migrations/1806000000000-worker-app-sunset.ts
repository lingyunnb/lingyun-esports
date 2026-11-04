import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  WORKER_APP_SUNSET_DEFAULT_TEXT,
  WORKER_APP_SUNSET_DESCRIPTION,
  WORKER_APP_SUNSET_KEY,
} from '../modules/auth/worker-app-sunset';

/**
 * 工作端到期收口 1/1：配置行 `system_setting.worker_app_sunset_at`（2026-10-06 定案）。
 *
 * ## 为什么只有一行配置、没有新表、没有新列
 *
 * 到期判定是**纯读**（读一个时刻 + 与"现在"比大小），没有任何状态要落库：
 * 不需要表、不需要给 `worker` / `auth_token` 加标记位。
 * 判定实现唯一：`modules/auth/worker-app-sunset.ts`（`AuthService.login` / `JwtAuthGuard` /
 * `RealtimeGateway` 共用），读侧**每次实时读库、无缓存** → 改完下一次请求即生效。
 *
 * ## 为什么落在 `system_setting`（而不是单开一张 sunset 表 / 写进 .env）
 *
 * - `is_high_security = 1` → **仅超级管理员可改**：这条规则由
 *   `SystemSettingService.update()` 统一执行，落在这里就是"复用"，单开表就得再实现一遍
 *   （与"同一规则只有一份实现"冲突 —— 安全审计 F1 同类根因）。
 * - 运营需要能改（打手迁移没做完就得上线、临时提前/延后一天）→ 不能写死在代码或 `.env`。
 * - `setting_key` 唯一索引 → 读侧那条 SELECT 是主键级开销，可以放心每请求跑一次。
 *
 * ## 默认值 = 负责人定案口径
 *
 * `2026-10-13 00:00:00`（**Asia/Shanghai 墙钟**；等价 `2026-10-12T16:00:00Z`），
 * 与工作端终版 v1.8.1（码59）客户端内置的 `kWorkerSunsetDate` 是**同一天**。
 *
 * ## 幂等与回滚
 *
 * `INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key` → 重复执行不报错，
 * 且**不会冲掉运营已经改过的到期时间**（迁移重跑安全）。
 * `down` 只删本行，不触碰任何既有配置与业务数据。
 */
export class WorkerAppSunset1806000000000 implements MigrationInterface {
  name = 'WorkerAppSunset1806000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, ?, ?, 1)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [
        WORKER_APP_SUNSET_KEY,
        // 形状与既有配置一致：cfg_value = {"value": <配置本体>}，本体是"中国墙钟"文本（读侧同一 parser 解释）
        JSON.stringify({ value: WORKER_APP_SUNSET_DEFAULT_TEXT }),
        WORKER_APP_SUNSET_DESCRIPTION,
      ],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [WORKER_APP_SUNSET_KEY]);
  }
}
