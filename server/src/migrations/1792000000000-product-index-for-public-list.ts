import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 性能专项：给「商品列表」补一个复合索引（负责人 2026-10-04「秒刷」）
 *
 * ## 背景：为什么只加**一个**索引
 *
 * 本迁移是「先 EXPLAIN、再决定」的产物。做法不是照着"可能有用"的清单盲加，
 * 而是先用 MySQL 通用查询日志抓下**接口真实执行的 SQL**（27 条去重 SELECT），
 * 逐条 EXPLAIN，把出现 `Using filesort` / `Using temporary` / `type=ALL` 的挑出来，
 * 再用**合成数据**做 A/B 实测（生产库当前只有 3 张分部、22 个商品、3 张订单，
 * 任何索引在 20 行数据上都测不出差别，不能拿它下结论）。
 *
 * 实测脚本与原始输出（可复跑）：
 *   - `scripts/tmp/perf-capture-sql2.js` → `scripts/tmp/perf-real-sql.json`（真实 SQL + EXPLAIN）
 *   - `scripts/tmp/perf-index-bench.js`  → `scripts/tmp/perf-index-bench.json`（4 个候选索引 A/B）
 *   - `scripts/tmp/perf-index-bench3.js` → `scripts/tmp/perf-index-bench3.json`（规模扫描 5k/50k/200k）
 *
 * ## 唯一采纳的索引
 *
 * `product (division_id, status, service_status, sort_order)`
 *
 * 对应真实 SQL（`GET /public/products?divisionId=N`，来自 general_log 抓取，非手写近似）：
 *   SELECT ... FROM product
 *   WHERE status = 1 AND service_status = 1 AND division_id = '2'
 *   ORDER BY sort_order ASC, id DESC LIMIT 20 OFFSET 0
 *
 * 现状：命中 `IDX_product_division(division_id)`，`rows=1667`，`Using where; Using filesort`
 * —— 即"按分部捞出全部商品（约 1/3 表）再排序"，排序发生在**整个分部的商品集**上，
 * 而不是只排前 20 行。商品目录是管理端会持续加东西的表，这条查询又是**客户端首页/商品列表
 * 必打**的接口，属于会随运营增长而变慢的典型形状。
 *
 * 实测收益（合成数据，EXPLAIN rows 与中位耗时）：
 *   | 商品行数 | 现有索引             | 本索引                        | 提速  |
 *   |----------|----------------------|-------------------------------|-------|
 *   | 5,000    | rows=1667 1.776ms    | rows=1250 1.551ms             | 1.15x |
 *   | 50,000   | rows=24983 12.530ms  | rows=23766 11.844ms           | 1.06x |
 *   | 200,000  | rows=99592 52.471ms  | rows=96378 47.952ms           | 1.09x |
 *
 * **如实说明（不粉饰）**：这把索引**没能消除 filesort**（三种规模下 `Using filesort` 依旧在），
 * 收益仅 1.06~1.15x，属于"预防性、低幅度"优化，不是"秒刷"的关键路径。
 * 想彻底去掉 filesort 需要把 `id` 也放进索引
 * `(division_id, status, service_status, sort_order, id)`，但实测（bench2）MySQL 仍选择
 * 更短的 key 并保留 filesort、耗时与不含 id 的版本基本一致（1.14x vs 1.15x），
 * 多一列只增加写放大，故**不采纳**。
 *
 * ## 明确**不加**的索引（都过了 EXPLAIN + A/B 实测，收益为 0 或负）
 *
 * 1. `order (user_id, created_at)` / `order (user_id, id)`
 *    真实 SQL 是 `WHERE user_id = ? ORDER BY id DESC LIMIT 20`（排序键是**主键**，
 *    不是 created_at —— 我最初按"按创建时间倒序"的错误假设设计过，抓真实 SQL 后纠正）。
 *    实测：0.663ms → 0.660ms（1.00x），优化器坚持走 `IDX_order_user_status`。不加。
 *
 * 2. `chat_message (conversation_id, seq)`
 *    **已经存在**（`IDX_msg_conv_seq`），EXPLAIN 显示 `Backward index scan`，
 *    无 filesort、无临时表。属于"用户建议里已经做好了"的一项，无需重复添加。
 *
 * 3. `worker (status, can_take_order, division_id)`
 *    真实 SQL 为 `FROM worker w INNER JOIN user u ... WHERE w.status=1 AND w.can_take_order=1`，
 *    已命中 `IDX_worker_can_take_order_status(can_take_order, status)`，`rows=2`，无 filesort。
 *    单独看 `status` 这一列在当前数据分布下选择性极差（几乎全是 1），
 *    把它放索引首位会让优化器更难选到好 key。不加。
 *
 * 4. `chat_conversation (user_id, type, status, id)`
 *    实测 0.674ms → 0.691ms（**0.98x，即略慢**），优化器继续走 `UQ_conv_pair`。不加。
 *
 * 5. `user_notification (user_id, id)`
 *    实测 0.649ms → 0.643ms（1.01x），在噪声范围内。不加。
 *
 * 结论：4 个"看起来该加"的索引里 3 个实测零收益、1 个（chat_message）早已存在。
 * 只留下唯一有正收益且对应高频首页接口的那一个。
 *
 * ## 其他被 EXPLAIN 标出但**确认无需处理**的项
 *
 * - `division` 的 `Using temporary; Using filesort`：来自 `ORDER BY g.sort_order, d.sort_order`
 *   跨表排序；分部表是**配置级小表**（当前 3 行，业务上不会超过几十行），排序成本可忽略。
 * - `home_module` 全表扫 + filesort：当前 5 行，首页模块表由管理端手工维护。
 * - `home_announcement` filesort：`ORDER BY pinned DESC, sort_order ASC, id DESC`，
 *   已有 `IDX_announcement_pinned_sort`，且查询 `LIMIT 10`、表极小。
 *
 * 这些表都加索引属于"为了 EXPLAIN 好看"而非为了快，故不动（也避免无谓的写放大）。
 *
 * ## 安全性
 *
 * - 纯 `ADD INDEX`，不改列、不改默认值、不碰数据；`IF NOT EXISTS` 语义（先查
 *   `information_schema.statistics`）保证**可重复执行**、不会因为人工先加过而失败。
 * - `product` 只有 22 行，加索引是瞬时完成，无锁表风险。
 * - **不涉及**结算/抽成/设置模块（那部分有另一任务在改，本迁移完全不碰）。
 */
export class ProductIndexForPublicList1792000000000 implements MigrationInterface {
  name = 'ProductIndexForPublicList1792000000000';

  /** 目标索引与列（保持与 entity / EXPLAIN 分析一致） */
  private static readonly INDEX_NAME = 'IDX_product_division_status_sort';
  private static readonly COLUMNS = ['division_id', 'status', 'service_status', 'sort_order'];

  public async up(queryRunner: QueryRunner): Promise<void> {
    const exists: Array<{ c: number }> = await queryRunner.query(
      `SELECT COUNT(1) AS c FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = 'product' AND index_name = ?`,
      [ProductIndexForPublicList1792000000000.INDEX_NAME],
    );
    if (Number(exists[0]?.c ?? 0) > 0) return; // 幂等：已存在（人工先建过）则跳过

    await queryRunner.query(
      `ALTER TABLE \`product\` ADD INDEX \`${ProductIndexForPublicList1792000000000.INDEX_NAME}\`
        (${ProductIndexForPublicList1792000000000.COLUMNS.map((c) => `\`${c}\``).join(', ')})`,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const exists: Array<{ c: number }> = await queryRunner.query(
      `SELECT COUNT(1) AS c FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = 'product' AND index_name = ?`,
      [ProductIndexForPublicList1792000000000.INDEX_NAME],
    );
    if (Number(exists[0]?.c ?? 0) === 0) return;
    await queryRunner.query(`ALTER TABLE \`product\` DROP INDEX \`${ProductIndexForPublicList1792000000000.INDEX_NAME}\``);
  }
}
