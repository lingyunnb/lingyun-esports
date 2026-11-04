import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 评价体系地基 2/3：`user_game_account` 表（负责人 2026-10-15 定案「记住我的游戏 ID 这个也做」）。
 *
 * ## 语义：老板的"游戏账号簿"，**客户端永远不需要调 POST 来保存**
 *
 * 关键设计（任务书硬要求）：**下单成功时服务端自动 upsert 一条** ——
 * 取值来源就是订单本身的 `game_id` / `game_player_id` / `game_zone`（订单已校验并落库的权威值），
 * 客户端**只调 `GET /user/game-accounts` 做回填**。因此：
 * - 「忘记填游戏 ID」不会再发生：上次下过单的游戏，下次下单页自动带出来；
 * - 客户端**不需要**"下单前先调一次保存接口"（少一次往返、少一个会失败的分支）；
 * - 失败隔离见 `OrderService.rememberGameAccountBestEffort()`（best-effort，绝不影响下单成功）。
 *
 * ## `UNIQUE KEY UK_uga_user_game (user_id, game_id)` = 同一老板同一游戏只有一行
 *
 * 写入统一走 `INSERT ... ON DUPLICATE KEY UPDATE`（**幂等**）：
 * - 首次下单该游戏 → 插入；
 * - 之后换号/换区再下单 → **更新同一行**（`updated_at` 前进），不会留下两行让客户端"该信哪条"；
 * - 服务端自动 upsert 与 `POST /user/game-accounts` 手工保存**共用同一条 SQL 语义**
 *   （`GameAccountService.upsert()` 唯一一处实现），不存在"自动写的"和"手写的"两套规则。
 *
 * ## 与既有 columns 的关系（照任务书原文，未改列名）
 *
 * `game_zone` 定 `varchar(32)`：比 `order.game_zone`（varchar(16)）宽 ——
 * 本表是"用户自己填的备忘"，将来允许更自由的区服写法，不为兼容旧枚举而收紧；
 * `game_player_id` 与 `order.game_player_id` **同为 varchar(64)**，校验正则也同一份
 * （`^[A-Za-z0-9一-龥_-]+$`，见 `game-account.service.ts`）。
 *
 * **无 `created_at`**：这张表回答的问题是"我现在用的是哪个号"，不是"第一次什么时候填的"；
 * 多一列就多一处可能与 `updated_at` 打架的真相。
 *
 * ## 幂等与回滚
 *
 * `CREATE TABLE IF NOT EXISTS` → 重复执行不报错、不触碰任何既有数据。
 * 回滚只删本表（`order` / `user` / `game` 一行不动）。
 */
export class UserGameAccount1813000000000 implements MigrationInterface {
  name = 'UserGameAccount1813000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`user_game_account\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL COMMENT '老板账号（user.id，role=user）；只来自 JWT sub',
        \`game_id\` bigint unsigned NOT NULL COMMENT '游戏（game.id）',
        \`game_player_id\` varchar(64) NOT NULL COMMENT '游戏 ID（与 order.game_player_id 同长度同校验正则）',
        \`game_zone\` varchar(32) NULL COMMENT '游戏分区（QQ 区/微信区…；空串按未填处理 = NULL）',
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '最近一次使用/保存时间（下单自动 upsert 与手工保存都会前进）',
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_uga_user_game\` (\`user_id\`, \`game_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='老板保存过的游戏账号（同一游戏一行；下单成功时服务端自动 upsert，客户端只做回填）'
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `user_game_account`');
  }
}
