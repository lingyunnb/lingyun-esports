import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 评价体系地基 1/3：`order_review` 表（负责人 2026-10-15 定案「做评价与评分体系」）。
 *
 * ## 设计来源（照抄竞品的信息架构，不照抄文案与视觉）
 *
 * 竞品（东东电竞 4.6.0，资源转储见 `data/temp/dd-res.txt`）的做法是**二值评价**
 * （满意 / 不满意）+ **差评直接转售后**，而不是"5 星评分"：
 * - `string/home_skill_order_desc = "接单%1$s次  好评率%2$s"` —— 打手卡只显示「接单次数 + 好评率」；
 * - 「已收到您的满意评价，感谢认可！」/「已收到您的不满意评价，平台售后正在前来的路上～」
 *   —— 不满意**当场转售后**，不留在打手页面上；
 * - 「未及时评价，评价已超时～」/「您已经评价过了哦~」/「评价次数已达到上限」
 *   —— 一单一评、超时/放弃不可恢复。
 *
 * 我们采用它的**核心语义**（二值 + 一单一评 + 好评率），但**不用它的文案与视觉**：
 * - `satisfied TINYINT(1)`：1 好评 / 0 差评；
 * - **差评不改订单状态、不落售后单** —— 接口只回 `needAfterSale=true` 引导客户端走
 *   **既有的** `POST /user/orders/:id/appeal`（唯一售后入口，一单一申诉，docs/05），
 *   避免出现"第二条售后真相"；
 * - **不在这个表里存"好评率"**：`worker_stats` **一列都不加**，好评率由公开接口
 *   **实时聚合** `order_review`（见下）—— 冗余列 = 第二条真相，与 docs/06 的口径铁律冲突。
 *
 * ## 为什么"一单一评"是**表级**唯一约束
 *
 * `UNIQUE KEY UK_review_order (order_id)` 是三层保证里的**第②层兜底**：
 * 服务层在事务内已用「锁订单行 + 查重」挡住绝大部分重复提交（第①层），
 * 但多实例并发下两个请求可能同时通过第①层 —— 此时第二个 INSERT 撞 `ER_DUP_ENTRY`，
 * 服务层把它翻译成中文 400「该订单已评价」（**不是 500，也不是两条评价**）。
 * 这与 `order_settlement.order_id` 唯一、"一个订单最多结算一次"的既有姿势完全一致。
 *
 * ## 索引口径
 *
 * - `IDX_review_worker (worker_id, hidden, created_at)`：**公开打手页的两个查询都走它** ——
 *   ① `COUNT/SUM` 好评率（`worker_id = ? AND hidden = 0`）；
 *   ② 最近 N 条评价（`worker_id = ? AND hidden = 0 ORDER BY id DESC`，id 与 created_at 同序）。
 *   第三列 `created_at` 让"按时间倒序取前 N 条"在覆盖索引内完成。
 * - 刻意**不加** `hidden` 单列索引 / `user_id` 索引：管理端列表是低频治理入口（超管专用），
 *   filesort 的代价可以忽略；少一个索引就少一处写入开销（本项目"**不加多余索引**"口径）。
 *
 * ## 幂等与回滚
 *
 * `CREATE TABLE IF NOT EXISTS` → 重复执行不报错、不触碰任何既有数据。
 * 回滚只删本表（`order` / `worker` / `worker_stats` 一行不动）。
 */
export class OrderReview1812000000000 implements MigrationInterface {
  name = 'OrderReview1812000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`order_review\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_id\` bigint unsigned NOT NULL COMMENT '被评价的订单（order.id）—— 唯一键保证"一单一评"',
        \`user_id\` bigint unsigned NOT NULL COMMENT '评价人 = 下单老板（user.id，role=user）；只来自 JWT sub，绝不信任请求体',
        \`worker_id\` bigint unsigned NULL COMMENT '被评价打手档案（worker.id）；落库时快照自 order.worker_id，可为 NULL（历史脏数据兜底，通知侧跳过）',
        \`satisfied\` tinyint(1) NOT NULL COMMENT '1 好评 / 0 差评（差评不改订单状态、不落售后单，只回 needAfterSale=true 引导走既有申诉通道）',
        \`remark\` varchar(200) NULL COMMENT '评价内容（可选；strip 前后空格，空串按未填处理 = NULL）',
        \`hidden\` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0 正常 / 1 已隐藏（仅管理端窄权限点 review:moderate 可改；hidden=1 的行公开接口一律不下发）',
        \`hidden_reason\` varchar(200) NULL COMMENT '隐藏原因（隐藏时必填）；恢复可见时**清空** —— 本列语义是"当前的隐藏原因"，历史原因在 operation_log',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '评价时间（服务层显式写入，便于同事务内直接回显）',
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_review_order\` (\`order_id\`),
        KEY \`IDX_review_worker\` (\`worker_id\`, \`hidden\`, \`created_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单评价（二值 满意/不满意；一单一评；好评率实时聚合，不在本表存冗余列）'
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `order_review`');
  }
}
