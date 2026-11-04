import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 首页宣传图轮播（负责人 2026-10-05 任务②，方案 C 顶部通栏沉浸）
 *
 * **复用既有 `home_banner` 表，不新建表**（负责人明确要求）。该表自 `1789915000000-create-home-tables`
 * 建表起就存在，`1789916000000-create-media-tables` 给它加过 `image_media_id`；本次只补 3 个可空列
 * 与 1 个 DEFAULT（下面第 3 条），字段语义与旧列完全兼容。
 *
 * ---------------------------------------------------------------------------
 * 1) `subtitle` varchar(64) NULL —— 宣传图副标题
 *    设计稿 C 的图片上只有「标题」一行主文案，副标题用于管理端补一句说明（如「10/05–10/07 · 全分部可用」）。
 *    可空：老数据没有副标题，客户端不显示即可；长度 64 与 `title` 一致（同一行文字的两种写法）。
 *
 * 2) `start_at` / `end_at` datetime(3) NULL —— 投放时间区间
 *    **两个都可空**，语义严格定义为：
 *      - `start_at` NULL = 不设开始时间（从建好那一刻就可以投）
 *      - `end_at`   NULL = 不设结束时间（永不过期）
 *    即 NULL 一律表示「这一端不限制」，而不是「立即过期」。公开接口的过滤条件据此写成
 *    `(start_at IS NULL OR start_at <= NOW()) AND (end_at IS NULL OR end_at >= NOW())`
 *    —— 不用 `BETWEEN`，因为 `BETWEEN` 遇到 NULL 恒为假，会把「只配了结束时间」的活动整条吞掉。
 *    精度 3 与 `created_at` / `updated_at` 一致（本表既有列就是这个精度）。
 *    不建索引：`home_banner` 是管理端人工维护的**个位数行数**表（首页轮播位天然只有几张），
 *    全表扫描比走二级索引更省；建索引反而是给一张永远很小的表加维护成本。
 *    （对比：`visible` + `sort_order` 已有 `IDX_home_banner_visible_sort`，那是建表时给「按可见性筛选 + 排序」准备的，
 *     本次公开接口的 WHERE 仍以 `visible` 打头，可以直接复用该索引。）
 *
 * 3) `image_url` 加 `DEFAULT ''` —— **真实坑，会让「只传 imageMediaId 的新建」失败**
 *    现状（`1789915000000` 建表语句）：`image_url varchar(500) NOT NULL`，**无默认值**。
 *    管理端新版宣传图上传通道只回填 `imageMediaId`（阶段 13 起媒体走 media 表，`image_url` 是历史兼容字段），
 *    而 `HomeService.createBanner` 走 `repo.create(dto)` + `save()` —— dto 里没有 `imageUrl` 时
 *    TypeORM 会把它当「未提供」而不是「空串」，生成的 INSERT 不含该列，
 *    MySQL 在 strict 模式下对「NOT NULL 且无默认值」的列直接报
 *    `ER_NO_DEFAULT_FOR_FIELD: Field 'image_url' doesn't have a default value` → 新建宣传图 500。
 *    因此这里把列改成 `NOT NULL DEFAULT ''`：空串在本表的语义就是「没有历史 URL，图片走 image_media_id」，
 *    **不改成 NULL**（改 NULL 会连带改 `HomeBanner.imageUrl: string` 的类型与所有读取方的空值判断，
 *    为一个历史兼容字段扩散改动不值得；保持 NOT NULL 语义、只补默认值，影响面最小）。
 *    已有数据不受影响：MySQL 加 DEFAULT 不会重写既有的非空行。
 *
 * 4) `link_type` 枚举**不加数据库约束**：本表 `link_type` 建表时就是 `varchar(16)`（不是 ENUM 类型），
 *    所以扩 `division` / `announcement` 两个新值**不需要 DDL**，只改 DTO 的 `@IsIn` 白名单与实体注释。
 *    这里不写 DDL 是刻意的：若改成 MySQL ENUM 类型，以后每加一种跳转类型都要再写一次 ALTER TABLE。
 *
 * **幂等**：三个列各自先查 `information_schema.COLUMNS`，存在则跳过；
 * `image_url` 的 DEFAULT 通过 `information_schema.COLUMNS.COLUMN_DEFAULT` 判断，已是 `''` 则跳过。
 * **回滚**：删 3 个新列 + 撤掉 `image_url` 的 DEFAULT（回到建表时的「NOT NULL 无默认值」），
 * 不动任何行数据、不删列以外的东西。
 */
export class HomeBannerCarouselFields1798000000000 implements MigrationInterface {
  name = 'HomeBannerCarouselFields1798000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // 1) subtitle
    if (!(await this.hasColumn(queryRunner, 'subtitle'))) {
      await queryRunner.query(
        `ALTER TABLE \`home_banner\`
           ADD COLUMN \`subtitle\` varchar(64) NULL
           COMMENT '副标题（宣传图图片上第二行文案；NULL/空=不显示）'
           AFTER \`title\``,
      );
    }

    // 2) start_at / end_at（NULL = 该端不限制）
    if (!(await this.hasColumn(queryRunner, 'start_at'))) {
      await queryRunner.query(
        `ALTER TABLE \`home_banner\`
           ADD COLUMN \`start_at\` datetime(3) NULL
           COMMENT '投放开始时间（NULL=不限制）'
           AFTER \`visible\``,
      );
    }
    if (!(await this.hasColumn(queryRunner, 'end_at'))) {
      await queryRunner.query(
        `ALTER TABLE \`home_banner\`
           ADD COLUMN \`end_at\` datetime(3) NULL
           COMMENT '投放结束时间（NULL=不限制）'
           AFTER \`start_at\``,
      );
    }

    // 3) image_url 补 DEFAULT ''（否则只传 imageMediaId 的新建会 500）
    const rows = await queryRunner.query(
      `SELECT COLUMN_DEFAULT AS d, IS_NULLABLE AS n FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'home_banner' AND COLUMN_NAME = 'image_url'`,
    );
    // COLUMN_DEFAULT 为字符串 '' 时 mysql2 返回空串（不是 null）；null 表示「真的没有默认值」
    if (rows.length && rows[0].d === null && rows[0].n !== 'YES') {
      await queryRunner.query(
        `ALTER TABLE \`home_banner\`
           MODIFY COLUMN \`image_url\` varchar(500) NOT NULL DEFAULT ''
           COMMENT '图片 URL（历史兼容；新数据走 image_media_id，本列留空串）'`,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // 先撤 DEFAULT（回到建表时的 NOT NULL 无默认值），再删新列
    const rows = await queryRunner.query(
      `SELECT COLUMN_DEFAULT AS d FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'home_banner' AND COLUMN_NAME = 'image_url'`,
    );
    if (rows.length && rows[0].d === '') {
      await queryRunner.query(
        `ALTER TABLE \`home_banner\` MODIFY COLUMN \`image_url\` varchar(500) NOT NULL`,
      );
    }
    for (const col of ['end_at', 'start_at', 'subtitle']) {
      if (await this.hasColumn(queryRunner, col)) {
        await queryRunner.query(`ALTER TABLE \`home_banner\` DROP COLUMN \`${col}\``);
      }
    }
  }

  private async hasColumn(queryRunner: QueryRunner, column: string): Promise<boolean> {
    const [row] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'home_banner' AND COLUMN_NAME = ?`,
      [column],
    );
    return Number(row.c) > 0;
  }
}
