import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 打手等级 + 五维评分地基（负责人已审批，2026-10-17）：**三张表，一个 migration**。
 *
 * ## 表清单（只在**本** migration 里建，不碰任何既有表）
 *
 * | 表 | 语义 | 主键 |
 * |---|---|---|
 * | `worker_grade` | 打手当前等级（1–5）+ 最近一次变更的审计三件套 | `worker_id` |
 * | `worker_rating` | 一单一评的五维原始数据（1–10 整数） | `id`（`order_id` 唯一） |
 * | `worker_rating_agg` | 五维均分 + 样本数（**写入侧唯一聚合**，避免每次判级现算 AVG） | `worker_id` |
 *
 * ## 三个刻意的设计取舍（改之前先读）
 *
 * ### ① `worker_id` 一律是 `worker.id`（打手档案），**不是** `user.id`
 *
 * 与既有 `worker_stats.worker_id` / `order.worker_id` / `worker_division_permission.worker_id`
 * 完全同源 —— 判级要连读 `worker_stats`（完成单/结算额）与 `worker_rating_agg`（五维），
 * 三张表的连接键必须是同一个 id。**不要**顺手把 `user_id` 塞进来：
 * 那会让"订单上的 worker_id"与"评分上的 worker_id"变成两种 id，是这类功能最经典的错配来源。
 *
 * ### ② `worker_rating_agg` 的五维列是 **`decimal(4,2)`**，不是审批表写的 `decimal(3,2)`
 *
 * 这是**唯一一处**与审批表字面不一致、且必须不一致的地方：
 * `decimal(3,2)` 的取值范围是 `-9.99 ~ 9.99`，而五维单条评分上限是 **10** ——
 * 当某打手的样本全打 10 分时 `AVG(r_skill) = 10.00`，写进 `decimal(3,2)` 会触发
 * **ER_DATA_OUT_OF_RANGE（1264）**；本库 `sql_mode` 含 `STRICT_TRANS_TABLES`（实测 MySQL 8.4.11），
 * 于是**整条评价提交事务回滚 → 接口 500**（若放开严格模式则会静默截断成 9.99，那是数据造假，更糟）。
 * 因此列宽取 `decimal(4,2)`（0.00–99.99）：**语义、精度、默认值一个都没变**，只是把上界放到能装下 10.00。
 *
 * ### ③ 等级中文名**不落库**
 *
 * `worker_grade.grade` 只存 1–5 的数字；名字与 LV 标签是**代码常量**，
 * 唯一出处 `modules/worker/worker-grade.constants.ts`（名字是**代码常量**：
 * 以后改名只改那一处，库里的数字不动、接口文案自动跟着变）。
 * 本文件的列注释里也**不写**具体档位名，避免第二份中文。
 *
 * ## 索引与约束的理由
 *
 * - `worker_rating.UK_wrating_order (order_id)`：**一单一评**的表级兜底（服务层另有事务内查重 +
 *   中文 400，两层都在）；并发下第二个 INSERT 撞唯一键 → 服务层翻译成中文 400（不是 500）。
 * - `worker_rating.IDX_wrating_worker_created (worker_id, created_at)`：**按打手聚合**
 *   （`AVG`/`COUNT` 走这条索引）+ 「打分记录」倒序分页。
 * - `worker_rating_agg` 与 `worker_grade` 都以 `worker_id` 为主键：一人一行，
 *   `INSERT … ON DUPLICATE KEY UPDATE` 天然幂等，不需要额外唯一键。
 * - **不加外键**：与全项目既有姿势一致（`worker_stats` / `worker_division_permission` 都没有 FK）。
 *   账号删除时由 `UserAdminService.delete()` 显式清理这三张表（同 `worker_stats` 的处理方式）。
 *
 * ## 幂等与回滚
 *
 * 每张表先查 `information_schema.TABLES`，存在则**整段跳过**（`CREATE TABLE IF NOT EXISTS` 再兜一层）；
 * 重复执行不报错、不覆盖既有数据。`down()` 只删本 migration 建的三张表，
 * 不触碰 `worker_stats` / `order` / `order_review` / `operation_log` 与任何既有数据。
 */
export class WorkerGradeRating1817000000000 implements MigrationInterface {
  name = 'WorkerGradeRating1817000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 1) 打手当前等级（一人一行；无行 = 默认 1 级）----------
    if (!(await this.tableExists(queryRunner, 'worker_grade'))) {
      await queryRunner.query(`
        CREATE TABLE IF NOT EXISTS \`worker_grade\` (
          \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案（worker.id；不是 user.id，与 worker_stats.worker_id 同源）',
          \`grade\` tinyint NOT NULL DEFAULT 1 COMMENT '等级 1-5（只存数字；中文名与 LV 标签的唯一出处：modules/worker/worker-grade.constants.ts）',
          \`upgraded_at\` datetime(3) NULL COMMENT '最近一次等级变更时间（NULL = 从未变更，即注册默认等级）',
          \`upgraded_by\` bigint unsigned NULL COMMENT '变更操作人（user.id，role=admin）；NULL = 系统自动判定（自动升级无法归属到人）',
          \`note\` varchar(100) NULL COMMENT '备注（人工设置时填写；自动升级写命中指标摘要）',
          PRIMARY KEY (\`worker_id\`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='打手等级（只升不降；最高档仅人工设置，自动判定不到该档）'
      `);
    }

    // ---------- 2) 五维评分原始数据（一单一评；评分**自愿**，只有评了才计入）----------
    if (!(await this.tableExists(queryRunner, 'worker_rating'))) {
      await queryRunner.query(`
        CREATE TABLE IF NOT EXISTS \`worker_rating\` (
          \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
          \`order_id\` bigint unsigned NOT NULL COMMENT '被评价订单（order.id）—— 唯一键保证一单一评',
          \`worker_id\` bigint unsigned NOT NULL COMMENT '被评价打手档案（worker.id；落库时快照自 order.worker_id）',
          \`r_skill\` tinyint NOT NULL COMMENT '五维第 1 维（字面直译：技术）1-10 整数',
          \`r_emotion\` tinyint NOT NULL COMMENT '五维第 2 维（字面直译：情绪价值）1-10 整数',
          \`r_stress\` tinyint NOT NULL COMMENT '五维第 3 维（字面直译：抗压）1-10 整数',
          \`r_voice\` tinyint NOT NULL COMMENT '五维第 4 维（字面直译：声音）1-10 整数',
          \`r_shop\` tinyint NOT NULL COMMENT '五维第 5 维（字面直译：店铺/配合）1-10 整数',
          \`r_comment\` varchar(200) NULL COMMENT '评价正文（可选；空串按未填处理 = NULL）',
          \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '评价时间（服务层显式写入，便于同事务回显）',
          PRIMARY KEY (\`id\`),
          UNIQUE KEY \`UK_wrating_order\` (\`order_id\`),
          KEY \`IDX_wrating_worker_created\` (\`worker_id\`, \`created_at\`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='打手五维评分（一单一评；写入后同事务重算聚合并跑升级检查）'
      `);
    }

    // ---------- 3) 五维聚合（写入侧唯一聚合；列宽见类注释 ②）----------
    if (!(await this.tableExists(queryRunner, 'worker_rating_agg'))) {
      await queryRunner.query(`
        CREATE TABLE IF NOT EXISTS \`worker_rating_agg\` (
          \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案（worker.id）',
          \`skill\` decimal(4,2) NOT NULL DEFAULT 0.00 COMMENT '第 1 维均分（worker_rating.r_skill 的 AVG，0.00-10.00）',
          \`emotion\` decimal(4,2) NOT NULL DEFAULT 0.00 COMMENT '第 2 维均分（r_emotion 的 AVG）',
          \`stress\` decimal(4,2) NOT NULL DEFAULT 0.00 COMMENT '第 3 维均分（r_stress 的 AVG）',
          \`voice\` decimal(4,2) NOT NULL DEFAULT 0.00 COMMENT '第 4 维均分（r_voice 的 AVG）',
          \`shop\` decimal(4,2) NOT NULL DEFAULT 0.00 COMMENT '第 5 维均分（r_shop 的 AVG）',
          \`sample_count\` int NOT NULL DEFAULT 0 COMMENT '样本数（worker_rating 条数；< 10 条不参与升级判定）',
          \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '最近一次重算时间',
          PRIMARY KEY (\`worker_id\`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='五维评分聚合（每次评价同事务重算；判级只读这一行）'
      `);
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // 只删本 migration 建的三张表（顺序无关：无外键）
    await queryRunner.query('DROP TABLE IF EXISTS `worker_rating_agg`');
    await queryRunner.query('DROP TABLE IF EXISTS `worker_rating`');
    await queryRunner.query('DROP TABLE IF EXISTS `worker_grade`');
  }

  private async tableExists(queryRunner: QueryRunner, table: string): Promise<boolean> {
    const rows = (await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.TABLES
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?`,
      [table],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0) > 0;
  }
}
