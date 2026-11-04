import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 「积分」残留清理（计价单位已于 `1808000000000` 改为「余额（元）」，全站不应再出现「积分」）。
 *
 * ## 背景：上一版迁移漏了两类数据
 *
 * `1808000000000-money-unit-points-to-yuan` 只改写了 `system_setting` 的若干键
 * （`noticeText` / `purchase_points_hint` / `order_notice_default` / `ai_greeting` / `ai_presets`），
 * **没有覆盖 `home_module` 与 `announcement`**，也**没有清理 `product.description` 里的旧单位回声**
 * （它只清了 `product.name` 尾巴上的 `=N积分`，见该迁移第 ⑦ 步）。
 *
 * 实测残留（2026-10-12 夜间审计，公开接口 + 真库）：
 *
 * | 位置 | 行数 | 是否公开可见 |
 * |---|---|---|
 * | `home_module` id=17 `privacy_policy` | 1 | **是** —— `GET /public/privacy` 实测返回「订单与**积分**数据仅用于平台服务结算」 |
 * | `announcement` id=136 content | 1 | **是** —— `GET /public/announcements/136` 实测返回「新用户**积分**由管理员发放」 |
 * | `product.description` | 29 | 当前**未**下发（公开列表不带 `description`、详情接口 404）——但管理端可见、且随时可能被接口暴露 |
 * | `home_module` id=2 `activity` | 1 | 否（`/public/home` 已不下发 `activity`） |
 * | `ai_message.content` | 4 | 否（历史 AI 对话留档，**刻意不改** —— 见下） |
 *
 * ## 改写规则（逐条说明，不做无脑 `REPLACE`）
 *
 * ### 1) `home_module`：按 **`seed.service.ts` 的现文案** 对齐
 *
 * `seed.service.ts` 里 `privacy_policy` 与公告的种子文案**早已**是「余额」口径
 * （见该文件第 103 行与第 111 行），但种子用的是 `INSERT IGNORE` / "同 title 存在则跳过"
 * —— **只插不改**。所以老库里留下的仍是「积分」版本，且**永远不会被种子自愈**。
 * 本迁移把这**两处**按种子现文案逐字对齐（等于把"种子本该做的事"补上）。
 *
 * `activity`（id=2）不是种子文案（已被运营改过），只做**最小词替换**「积分」→「余额」，
 * 其余字符逐字不动。
 *
 * ### 2) `product.description`：只删「（积分 N，按单计价）」这一整段
 *
 * 实测 29 行**全部**以「（积分 N，按单计价）」结尾（形态检查 0 例外），
 * 这是模板生成的旧单位回声，与 `product.name` 尾巴的 `=N积分` 同源。
 * 删除该段后描述变成 `8.8保148万（机密）`，与商品名一致、不含旧单位。
 *
 * ⚠️ **刻意不按 `price × 10` 重算**：实测 29 行里有 3 行（id 141 / 142 / 143）的
 * 描述积分数与 `price × 10` **本来就不一致**（如 id=143 `price=233.00` 但描述写 3333.3）——
 * 那是**运营手写的原始价格意图**，与折算无关。任何"按价格重算"的写法都会把这 3 行的
 * 真实意图**静默改掉**。删掉整段回声则对 29 行一视同仁，不猜、不改写价格语义。
 *
 * ### 3) `ai_message.content`：**不改**
 *
 * 那是历史 AI 对话的**逐字留档**（含用户自己问的「积分怎么用？」）。
 * 改写历史对话 = 篡改审计记录，且与"单位变更"无关（用户当时问的就是积分）。
 * 归属：**待决策**（是否要清历史 AI 对话由负责人定），本迁移不动。
 *
 * ## 幂等
 *
 * 每一条 `UPDATE` 都带 `LIKE '%积分%'` 条件 → 重复执行第二次影响 0 行。
 * `privacy_policy` / 公告用**定值赋值**（不是替换），天然幂等。
 *
 * ## 回滚
 *
 * `down()` 恢复「积分」版本文案（与 `up()` 同构、同样带条件）。
 * `product.description` 的 `down()` **无法精确还原**被删掉的数字（3 行原始值与价格不符，
 * 重算会写错）→ `down()` 对描述**不做反向**，并在下面注明：
 * 需要回滚请从备份恢复。这是刻意的取舍：**宁可回滚不完整，也不写入错误的数字**。
 */
export class CleanupJifenResidue1811000000000 implements MigrationInterface {
  name = 'CleanupJifenResidue1811000000000';

  /** `seed.service.ts` 第 103 行的隐私政策现文案（逐字） */
  private static readonly PRIVACY_NEW =
    '我们重视你的隐私。\n\n1. 我们仅收集提供服务所必需的账号信息（用户名、密码加密存储）。\n' +
    '2. 你上传的头像、背景与聊天图片仅用于平台内展示，不会出售或提供给第三方。\n' +
    '3. 订单与余额数据仅用于平台服务结算。\n' +
    '4. 你可以随时在「账号与安全」中修改密码，或联系管理员删除账号数据。';

  /** 旧文案（`down()` 还原用） */
  private static readonly PRIVACY_OLD =
    '我们重视你的隐私。\n\n1. 我们仅收集提供服务所必需的账号信息（用户名、密码加密存储）。\n' +
    '2. 你上传的头像、背景与聊天图片仅用于平台内展示，不会出售或提供给第三方。\n' +
    '3. 订单与积分数据仅用于平台服务结算。\n' +
    '4. 你可以随时在「账号与安全」中修改密码，或联系管理员删除账号数据。';

  /** `seed.service.ts` 第 111 行的公告现文案（逐字） */
  private static readonly ANNOUNCEMENT_NEW =
    '祁连山电竞俱乐部正式上线！\n\n我们提供和平精英、三角洲行动的段位上分、代打、娱乐陪玩等服务。\n\n' +
    '新用户余额由管理员发放，如有疑问请联系客服。';

  private static readonly ANNOUNCEMENT_OLD =
    '祁连山电竞俱乐部正式上线！\n\n我们提供和平精英、三角洲行动的段位上分、代打、娱乐陪玩等服务。\n\n' +
    '新用户积分由管理员发放，如有疑问请联系客服。';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const q = (sql: string, params?: unknown[]) => queryRunner.query(sql, params);

    // ---- ① 隐私政策：按种子现文案逐字对齐（公开接口 /public/privacy 实测泄漏）----
    await q(
      `UPDATE \`home_module\` SET \`content\` = ?
        WHERE \`module_key\` = 'privacy_policy' AND \`content\` LIKE '%积分%'`,
      [CleanupJifenResidue1811000000000.PRIVACY_NEW],
    );

    // ---- ② 公告 136：同上（公开接口 /public/announcements/:id 实测泄漏）----
    await q(
      `UPDATE \`announcement\` SET \`content\` = ?
        WHERE \`title\` = '欢迎来到 祁连山电竞' AND \`content\` LIKE '%积分%'`,
      [CleanupJifenResidue1811000000000.ANNOUNCEMENT_NEW],
    );

    // ---- ③ 其余 home_module：最小词替换（activity 等运营改过的文案，只换词不改结构）----
    await q(
      `UPDATE \`home_module\` SET \`content\` = REPLACE(\`content\`, '积分', '余额')
        WHERE \`content\` LIKE '%积分%'`,
    );

    // ---- ④ product.description：删掉模板回声「（积分 N，按单计价）」（整段，含中文括号）----
    // 形态实测 29/29 命中，无例外；不按价格重算（理由见类注释 2)）
    await q(
      `UPDATE \`product\`
          SET \`description\` = TRIM(REGEXP_REPLACE(\`description\`, '（积分[^）]*）', ''))
        WHERE \`description\` LIKE '%积分%'`,
    );

    // ---- ⑤ 自检：公开面（home_module / announcement / product.description）不应再有「积分」----
    const left: Array<{ n: number | string }> = await q(
      `SELECT
         (SELECT COUNT(*) FROM \`home_module\` WHERE \`content\` LIKE '%积分%')
       + (SELECT COUNT(*) FROM \`announcement\` WHERE \`content\` LIKE '%积分%' OR \`title\` LIKE '%积分%')
       + (SELECT COUNT(*) FROM \`product\` WHERE \`description\` LIKE '%积分%' OR \`name\` LIKE '%积分%') AS n`,
    );
    const remaining = Number(left?.[0]?.n ?? -1);
    if (remaining !== 0) {
      throw new Error(`「积分」清理后公开面仍有 ${remaining} 行残留，已回滚`);
    }
  }

  /**
   * 恢复「积分」口径文案。
   *
   * ⚠️ `product.description` **不做反向**：被删掉的数字里，id 141/142/143 三行与
   * `price × 10` 本来就不一致（运营手写意图），重算会写入**错误的数字**。
   * 宁可回滚不完整，也不制造错误数据 —— 需要完整回滚请从备份恢复。
   */
  public async down(queryRunner: QueryRunner): Promise<void> {
    const q = (sql: string, params?: unknown[]) => queryRunner.query(sql, params);

    await q(
      `UPDATE \`home_module\` SET \`content\` = ?
        WHERE \`module_key\` = 'privacy_policy' AND \`content\` LIKE '%余额%'`,
      [CleanupJifenResidue1811000000000.PRIVACY_OLD],
    );
    await q(
      `UPDATE \`announcement\` SET \`content\` = ?
        WHERE \`title\` = '欢迎来到 祁连山电竞' AND \`content\` LIKE '%余额%'`,
      [CleanupJifenResidue1811000000000.ANNOUNCEMENT_OLD],
    );
    // 其余 home_module 的「余额」→「积分」不反向：无法区分"本来就叫余额"与"本迁移改的"
    // （product.description 同理）—— 见类注释「回滚」一节。
  }
}
