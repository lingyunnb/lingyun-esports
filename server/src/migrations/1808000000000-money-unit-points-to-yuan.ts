import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 计价单位变更：**积分（1 元 = 10 积分） → 余额（1 元 = 1 元）**，存量金额按 **10:1** 折算。
 *
 * 负责人拍板（2026-10-09）：
 * - 折算口径 = A：**按 10:1 折算存量金额**（商品 88.00 → 8.80；真实价格不变，与商品名里的「8.8」一致）
 * - 显示口径 = **金额用 ¥/元，钱包叫「余额」**（API 字段名不改，避免大改）
 * - 合规表述保留：余额**仅可用于平台内消费、不可提现、不可转让**；平台**不经手资金、不接支付通道**
 *
 * ## 一、改哪些列（**只折算金额类，计数类一律不动**）
 *
 * | 表.列 | 旧类型 | 折算 |
 * |---|---|---|
 * | `product.price` | decimal(10,2) | ÷10 |
 * | `order.unit_price` / `order.total_amount` | decimal(12,2) | ÷10 |
 * | `order_price_snapshot.unit_price` / `.total_amount` | decimal(12,2) | ÷10 |
 * | `order_settlement.order_amount` / `.worker_amount` / `.platform_amount` | decimal(12,2) | ÷10 |
 * | `refund_request.amount` | decimal(12,2) | ÷10 |
 * | `order_tip.amount` | **int → decimal(12,2)** | ÷10（见下「类型修正」） |
 * | `leaderboard_entry.total_amount` | decimal(14,2) | ÷10 |
 * | `worker_stats.total_amount` | decimal(14,2) | ÷10 |
 * | `leaderboard_adjustment.amount_delta` | decimal(14,2) | ÷10 |
 * | `user.total_spent` | decimal(14,2) | ÷10（累计消费是订单金额的派生值） |
 * | `recharge_request.points` | **int → decimal(12,2)** | ÷10（见下「类型修正」） |
 * | `wallet.balance` | decimal(14,2) | ÷10，**并按折算后的流水重算**（见下「守恒」） |
 * | `wallet_transaction.amount` / `.balance_before` / `.balance_after` | decimal(14,2) | ÷10 |
 *
 * **不折算**（容易误伤，逐条写明理由）：
 * - `order_settlement.worker_percentage` / `.platform_percentage`：**百分比整数**（25 / 75），不是金额；
 * - `worker_stats.total_orders` / `completed_orders`、`leaderboard_entry.completed_orders`、`product.sales_count`：
 *   纯**计数**（次数/单数/人数），与单位无关；
 * - `club.rating` / `top_worker.rating`：**评分**，不是金额；
 * - `recharge_request.amount_yuan`：**本来就是元**（字段名即 `_yuan`，老板自己填的付款金额），
 *   折算它等于把用户真金白银付的钱砍掉 90% —— 这是本迁移最容易踩的坑，刻意列在这里；
 * - `wallet_transaction.idempotency_key` / `transaction_no`：字符串，非金额。
 *
 * ## 二、类型修正（1:1 之后允许「分」，int 会丢钱）
 *
 * 1. `recharge_request.points` int → **decimal(12,2)**：
 *    `pointsPerYuan` 改成 1 之后，充 6.5 元应到账 **6.50 元**。int 列存不下 0.50，
 *    MySQL 会静默截断成 6 —— 直接把用户的钱丢掉。列类型必须跟上。
 * 2. `order_tip.amount` int → **decimal(12,2)**：同样的理由，且这次有**实际触发路径** ——
 *    `system_setting.tip_presets` 原为 `[6,18,38,88]`（积分），按 10:1 折算后是 `[0.6,1.8,3.8,8.8]`（元），
 *    **int 列连预设档位都存不下**（0.6 会被截断成 0，打赏直接失效）。不改成 decimal 就得
 *    把运营配的档位擅自改成整数元（那是改运营口径，不是换算），所以改列类型才是自洽解。
 *    0 行存量，改动无数据风险。
 *
 * ## 三、账目守恒（本迁移的核心约束）
 *
 * `SUM(wallet.balance) == SUM(wallet_transaction.amount)` 必须**折算后仍成立**。
 *
 * ⚠️ 天真的「每列各自 `ROUND(x/10,2)`」**会破坏守恒**：本库 `wallet_transaction` 有 **38 行**金额
 * 不是 10 的整数倍（如 `24.75`、`74.25`），`24.75/10 = 2.475` 半进位成 `2.48`（+0.005），
 * 而它的冲正行 `-24.75 → -2.48`（-0.005）在**笔数不对称**（19 正 18 负）时不会抵消 ——
 * 实测 `SUM(ROUND(amount/10,2)) = 105152.62`，而 `SUM(ROUND(balance/10,2)) = 105152.60`，**差 0.02**。
 *
 * 解法：`docs/06` 铁律是「**流水是权威账本，余额是派生值**」。所以
 * **`wallet.balance` 不独立折算，而是由折算后的流水重新聚合**（
 * `wallet.balance = SUM(该用户折算后的 wallet_transaction.amount)`）。
 * 这样守恒**按构造成立**，而不是靠舍入巧合。代价：两个钱包（user 14 平台户、user 1114）
 * 的余额比「直接 ÷10」多 **+0.01**，一共 0.02 元 —— 这是算术上唯一自洽的结果，已在报告里列明。
 *
 * ⚠️ 别用「最后一条流水的 `balance_after`」当余额：`balance_after` 是**逐行独立** ÷10 的结果，
 * 自己就带着上面那份舍入不对称，拿它当余额等于把误差搬回去（实测首版就这么写，守恒差 0.02，
 * 已改为 `SUM(amount)` 并用 `down → up` 重跑验证）。
 *
 * 为什么**不**重排 `balance_before`/`balance_after` 让快照首尾相接：本库的快照链**本来就是断的**
 * —— v0.4.0「数据重置」删过订单类资金流水、再按剩余流水重算余额，于是每个钱包首行仍留着
 * 折算前的历史 opening（如 user 14 首行 `balance_before = 119.00`，但它并不计入当前余额）。
 * 用这个 opening 去重放会把早已作废的历史余额**重新灌回**最终余额（user 14 会变成 125.57 而非 113.68），
 * 反而破坏守恒。本迁移因此对快照只做同口径 ÷10，**不重新解释历史**。
 *
 * ## 四、幂等（重复执行不得二次除以 10）
 *
 * 折算闸门 = `system_setting.recharge_config.value.pointsPerYuan`：
 * - **`=== 10`** → 执行全部折算，最后把它置为 **1**；
 * - **`!== 10`**（正常是已经跑过一次的 1）→ **整段折算跳过**，只做「文案校正 + 类型修正」这类天然幂等的动作。
 *
 * `down()` 反向同构：闸门是 `pointsPerYuan === 1` → ×10 并置回 10；否则只回滚文案与类型。
 * 因此 `up → down → up` 与 `up → up` 都不会产生二次缩放。
 *
 * ## 五、配置折算与改写
 *
 * - `recharge_config.pointsPerYuan` 10 → **1**；`noticeText` 去掉「1 元 = 10 积分」，
 *   改为「按付款金额 1:1 到账余额」，并**保留**「平台不提供在线支付 / 不经手资金 / 余额不可提现」原意；
 *   `minYuan` / `maxYuan` / `amountOptions` **不动**（它们本来就是元）；
 * - `level_rules.rules[].minSpent` **÷10**：它是「升级所需累计消费」，`user.total_spent` 折算后
 *   阈值不跟着折算的话，演示老板（4720 → 472.00）会从 3 级掉回 1 级 —— **等级集体回退**，
 *   这是纯粹的换算副作用，必须在同一迁移里消掉；
 * - `tip_presets` / `tip_max_per_tip` / `tip_max_per_order` **÷10**：都是余额口径的上限，
 *   不折算等于把打赏上限放宽 10 倍；
 * - `purchase_points_hint` / `order_notice_default` 文案改写为余额口径。
 *
 * ## 六、`price_unit` 与「名称里的旧单位回声」
 *
 * - `product.price_unit` / `order_price_snapshot.price_unit`：**实测库中取值只有「单」与「20分」**，
 *   **没有任何一行是「积分」** → **数据不动**（负责人给的「若存的是积分就改」条件不成立）。
 * - 但 4 个段位商品的**名称里带了旧单位回声**：`铂金 每20分4元=40积分` 的尾巴 `=40积分`
 *   是「4 元 × 10」的旧积分写法，折算后价格是 4.00 元，留着它就自相矛盾（名字说 40、价格说 4）。
 *   `up()` 只删除 `=N积分` 这一段尾巴，**其余字符逐字不动**；`down()` 按 `=折算后价格×10积分` 精确还原。
 */
export class MoneyUnitPointsToYuan1808000000000 implements MigrationInterface {
  name = 'MoneyUnitPointsToYuan1808000000000';

  /** 旧口径的说明文案（`up()` 改写它，`down()` 逐字还原） */
  private static readonly OLD_NOTICE =
    '本平台不提供在线支付。请扫描下方收款码，在微信或支付宝自行付款；付款后上传转账截图，管理员人工核对后为你发放积分（1 元 = 10 积分）。平台不经手资金，请勿向任何人索要或提供账号密码。';

  /** 新口径的说明文案：去掉「1 元 = 10 积分」，改为 1:1 到账余额；合规三句原意逐条保留 */
  private static readonly NEW_NOTICE =
    '本平台不提供在线支付。请扫描下方收款码，在微信或支付宝自行付款；付款后上传转账截图，管理员人工核对后按付款金额 1:1 到账余额。余额仅可用于平台内消费，不可提现、不可转让。平台不经手资金，请勿向任何人索要或提供账号密码。';

  private static readonly OLD_HINT = '下单均使用积分非人民币，10 积分等于 1 人民币；如需下单请联系小云进行积分充值';

  private static readonly NEW_HINT =
    '下单均使用余额（元），余额仅可用于平台内消费、不可提现；如需充值请联系客服';

  private static readonly OLD_ORDER_NOTICE = [
    '请在提交订单前确认游戏分区与游戏 ID 填写正确；ID 填错会导致护航员无法上号，需要取消后重新下单。',
    '下单即按标价扣积分，1 件为 1 单；提交后超时无人接单，系统自动取消并全额退回积分。',
    '未接单可随时取消，积分全额退回；护航员接单后请勿自行取消，有问题先联系客服。',
    '服务过程中请勿将账号密码告知护航员，平台不支持任何形式的账号共享。',
  ].join('\n');

  private static readonly NEW_ORDER_NOTICE = [
    '请在提交订单前确认游戏分区与游戏 ID 填写正确；ID 填错会导致护航员无法上号，需要取消后重新下单。',
    '下单即按标价扣余额，1 件为 1 单；提交后超时无人接单，系统自动取消并全额退回余额。',
    '未接单可随时取消，余额全额退回；护航员接单后请勿自行取消，有问题先联系客服。',
    '服务过程中请勿将账号密码告知护航员，平台不支持任何形式的账号共享。',
  ].join('\n');

  public async up(queryRunner: QueryRunner): Promise<void> {
    // TypeORM CLI 默认 `transaction: 'all'`（整批迁移一个事务）。若被改成 'none'，这里自行兜一个，
    // 保证「折算 + 配置改写」要么全成、要么全不成 —— 折算绝不允许半途而废。
    const own = !queryRunner.isTransactionActive;
    if (own) await queryRunner.startTransaction();
    try {
      await this.fold(queryRunner, 'up');
      if (own) await queryRunner.commitTransaction();
    } catch (e) {
      if (own) await queryRunner.rollbackTransaction();
      throw e;
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const own = !queryRunner.isTransactionActive;
    if (own) await queryRunner.startTransaction();
    try {
      await this.fold(queryRunner, 'down');
      if (own) await queryRunner.commitTransaction();
    } catch (e) {
      if (own) await queryRunner.rollbackTransaction();
      throw e;
    }
  }

  /**
   * 双向共用的主体（`dir='up'` 折算，`dir='down'` 还原）。
   *
   * 把两个方向写在同一个函数里，是为了让「哪一列被折算、折算闸门是什么、文案怎么改」
   * 只有**一份**描述 —— 分成两个函数时最容易出现「up 改了 A 列，down 忘了还原」。
   */
  private async fold(queryRunner: QueryRunner, dir: 'up' | 'down'): Promise<void> {
    const q = (sql: string, params?: unknown[]) => queryRunner.query(sql, params);
    const up = dir === 'up';

    // ---- ① 幂等闸门：只认 recharge_config.value.pointsPerYuan ----
    const cfgRows: Array<{ cfg_value: unknown }> = await q(
      `SELECT \`cfg_value\` FROM \`system_setting\` WHERE \`setting_key\` = 'recharge_config' LIMIT 1`,
    );
    const cfg = (cfgRows?.[0]?.cfg_value ?? null) as { value?: { pointsPerYuan?: unknown } } | null;
    const ppy = Number(cfg?.value?.pointsPerYuan);
    // up：仍是旧口径 10 → 折算；down：已是新口径 1 → 还原。
    // 其它情况（含配置行缺失 / 已被改写）→ 只做幂等的那部分，绝不做二次缩放。
    const needScale = up ? ppy === 10 : ppy === 1;

    if (needScale) {
      // ---- ② 金额类列 ÷10（up）或 ×10（down），一律保留 2 位小数 ----
      const f = (col: string) => (up ? `ROUND(\`${col}\`/10, 2)` : `ROUND(\`${col}\`*10, 2)`);

      await q(`UPDATE \`product\` SET \`price\` = ${f('price')}`);
      await q(`UPDATE \`order\` SET \`unit_price\` = ${f('unit_price')}, \`total_amount\` = ${f('total_amount')}`);
      await q(
        `UPDATE \`order_price_snapshot\` SET \`unit_price\` = ${f('unit_price')}, \`total_amount\` = ${f('total_amount')}`,
      );
      await q(
        `UPDATE \`order_settlement\` SET \`order_amount\` = ${f('order_amount')}, ` +
          `\`worker_amount\` = ${f('worker_amount')}, \`platform_amount\` = ${f('platform_amount')}`,
      );
      // ⚠️ 分账**守恒修补**（这一步不是"顺手优化"，是折算的必然要求，别删）。
      //
      // `splitAmount()`（modules/setting/commission-rate.ts）的铁律是
      //   `worker_amount + platform_amount === order_amount`
      // （打手先四舍五入到分，**平台 = 总额 − 打手**），为的是"绝不分出/分丢 1 分钱"。
      // 而**逐列独立 ÷10 会破坏它**：本库 id=374/375 两行原本是 `99.00 = 74.25 + 24.75`（精确），
      // 折算后变成 `9.90 = 7.43 + 2.48 = 9.91` —— 每行漂 0.01，两行共 0.02
      // （实测 `Σorder=471.00` vs `Σworker+Σplatform=471.02`，被 stage14 套件抓到）。
      //
      // 修法：把**平台侧**改成差额（平台 = 折算后订单额 − 折算后打手额）——
      // 也就是把平台自己的分账规则原样套到折算后的数字上。
      // 打手额保持 ÷10 的结果**不动**（打手的钱不因平台侧对齐而被改），守恒由平台侧吸收。
      // up / down 两个方向同一条语句：差额关系与缩放方向无关。
      await q(`UPDATE \`order_settlement\` SET \`platform_amount\` = ROUND(\`order_amount\` - \`worker_amount\`, 2)`);
      await q(`UPDATE \`refund_request\` SET \`amount\` = ${f('amount')}`);
      await q(`UPDATE \`order_tip\` SET \`amount\` = ${f('amount')}`);
      await q(`UPDATE \`leaderboard_entry\` SET \`total_amount\` = ${f('total_amount')}`);
      await q(`UPDATE \`worker_stats\` SET \`total_amount\` = ${f('total_amount')}`);
      await q(`UPDATE \`leaderboard_adjustment\` SET \`amount_delta\` = ${f('amount_delta')}`);
      await q(`UPDATE \`user\` SET \`total_spent\` = ${f('total_spent')}`);
      await q(`UPDATE \`recharge_request\` SET \`points\` = ${f('points')}`);

      // ---- ③ 钱包流水三列 ÷10 ----
      await q(
        `UPDATE \`wallet_transaction\` SET \`amount\` = ${f('amount')}, ` +
          `\`balance_before\` = ${f('balance_before')}, \`balance_after\` = ${f('balance_after')}`,
      );

      // ---- ④ 守恒：余额由**折算后的流水**重新聚合，而不是独立 ÷10 ----
      // ⚠️ 这里必须用 `SUM(amount)`，**不能**用「最后一条流水的 balance_after」：
      //    balance_after 是**逐行独立** ÷10 的结果，它自己就带着 ③ 的舍入不对称，
      //    拿它当余额等于把误差又搬回 `wallet.balance`（实测差 0.02，守恒直接不成立）。
      //    而 `SUM(折算后的 amount)` 与「全表折算后流水之和」逐项同源 →
      //    `SUM(wallet.balance) == SUM(wallet_transaction.amount)` **按构造成立**。
      // 为什么 SUM 是对的而不是漏了 opening：本库「有钱包流水的钱包」在折算前全都满足
      //    `balance == SUM(amount)`（已逐钱包核对，23 行钱包无一例外）；
      //    首行遗留的 `balance_before`（如 user 14 的 119.00）是 v0.4.0 清理流水后的孤儿快照，
      //    **本来就不计入余额**，用 SUM 恰好把它排除在外。
      // 先给「没有任何流水的钱包」一个同口径的折算（它们必然是 0，这一步只是语义完整）。
      await q(`UPDATE \`wallet\` SET \`balance\` = ${f('balance')}`);
      await q(
        `UPDATE \`wallet\` w
           JOIN (SELECT \`user_id\`, SUM(\`amount\`) AS \`sum_amount\` FROM \`wallet_transaction\` GROUP BY \`user_id\`) t
             ON t.\`user_id\` = w.\`user_id\`
            SET w.\`balance\` = t.\`sum_amount\``,
      );

      // ---- ⑤ 配置里的**金额口径**阈值同步缩放（比例类不动，见 ⑥）----
      // level_rules.rules[].minSpent：升级阈值，必须跟着 total_spent 一起缩，否则等级集体回退
      const lvlRows: Array<{ cfg_value: unknown }> = await q(
        `SELECT \`cfg_value\` FROM \`system_setting\` WHERE \`setting_key\` = 'level_rules' LIMIT 1`,
      );
      const lvl = (lvlRows?.[0]?.cfg_value ?? null) as { rules?: Array<{ minSpent?: unknown }> } | null;
      if (Array.isArray(lvl?.rules)) {
        const rules = lvl.rules.map((r) => ({
          ...r,
          minSpent: up ? Math.round((Number(r?.minSpent) / 10) * 100) / 100 : Number(r?.minSpent) * 10,
        }));
        await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.rules', CAST(? AS JSON)) WHERE \`setting_key\` = 'level_rules'`, [
          JSON.stringify(rules),
        ]);
      }

      // 打赏预设与两道上限：都是余额口径
      for (const key of ['tip_max_per_tip', 'tip_max_per_order']) {
        await q(
          `UPDATE \`system_setting\`
              SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value', ${
                up ? 'ROUND(JSON_EXTRACT(`cfg_value`, \'$.value\')/10, 2)' : 'JSON_EXTRACT(`cfg_value`, \'$.value\')*10'
              })
            WHERE \`setting_key\` = ?`,
          [key],
        );
      }
      // 打赏预设是**数组**，JSON_SET 无法对元素逐个运算 → 读出、映射、整体写回
      const presetRows: Array<{ cfg_value: unknown }> = await q(
        `SELECT \`cfg_value\` FROM \`system_setting\` WHERE \`setting_key\` = 'tip_presets' LIMIT 1`,
      );
      const presets = ((presetRows?.[0]?.cfg_value ?? { value: [] }) as { value?: unknown[] }).value ?? [];
      await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value', CAST(? AS JSON)) WHERE \`setting_key\` = 'tip_presets'`, [
        JSON.stringify(presets.map((v) => (up ? Math.round((Number(v) / 10) * 100) / 100 : Number(v) * 10))),
      ]);

      // ---- ⑥ 比例类配置：pointsPerYuan 10 ↔ 1（**这是幂等闸门本身**）----
      await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value.pointsPerYuan', ?) WHERE \`setting_key\` = 'recharge_config'`, [
        up ? 1 : 10,
      ]);

      // ---- ⑦ 段位商品名里的旧单位回声 `=N积分`：up 删除 / down 精确还原 ----
      if (up) {
        await q("UPDATE `product` SET `name` = REGEXP_REPLACE(`name`, '=[0-9]+积分$', '') WHERE `name` REGEXP '=[0-9]+积分$'");
      } else {
        // ② 已把价格 ×10，此处的 `price` 就是当初的旧积分价 → 尾巴数字由价格推导，不靠硬编码。
        // 用 CAST(ROUND(price,0) AS UNSIGNED) 而不是直接拼 price：decimal(10,2) 会渲染成 `40.00`，
        // 而原文字是 `=40积分`。
        await q(
          "UPDATE `product` SET `name` = CONCAT(`name`, '=', CAST(ROUND(`price`, 0) AS UNSIGNED), '积分') " +
            "WHERE `name` REGEXP '每20分[0-9.]+元$'",
        );
      }
    }

    // ---- ⑧ 文案（天然幂等：每次写成同一份定值，与闸门无关，保证「跳过折算也要校正文案」）----
    await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value.noticeText', ?) WHERE \`setting_key\` = 'recharge_config'`, [
      up ? MoneyUnitPointsToYuan1808000000000.NEW_NOTICE : MoneyUnitPointsToYuan1808000000000.OLD_NOTICE,
    ]);
    await q(
      `UPDATE \`system_setting\` SET \`description\` = ? WHERE \`setting_key\` = 'recharge_config'`,
      [
        up
          ? '充值配置（金额档位/1 元到账余额比例/自定义上下限/每人待审核上限/受限管理员上限/说明文案；仅超管可改）'
          : '充值配置（金额档位/1 元对应积分/自定义上下限/每人待审核上限/受限管理员上限/说明文案；仅超管可改）',
      ],
    );
    await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value.text', ?) WHERE \`setting_key\` = 'purchase_points_hint'`, [
      up ? MoneyUnitPointsToYuan1808000000000.NEW_HINT : MoneyUnitPointsToYuan1808000000000.OLD_HINT,
    ]);
    await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value.text', ?) WHERE \`setting_key\` = 'order_notice_default'`, [
      up ? MoneyUnitPointsToYuan1808000000000.NEW_ORDER_NOTICE : MoneyUnitPointsToYuan1808000000000.OLD_ORDER_NOTICE,
    ]);
    await q(`UPDATE \`system_setting\` SET \`description\` = ? WHERE \`setting_key\` = 'level_rules'`, [
      up ? '会员等级规则（升级所需累计消费金额，单位：元，前端只读）' : '会员等级规则（升级所需累计消费积分，前端只读）',
    ]);
    for (const [key, oldD, newD] of [
      ['tip_presets', '打赏预设金额（积分，管理端可改）', '打赏预设金额（元，管理端可改）'],
      ['tip_max_per_tip', '单次打赏上限（积分）', '单次打赏上限（元）'],
      ['tip_max_per_order', '同一订单累计打赏上限（积分）', '同一订单累计打赏上限（元）'],
    ] as const) {
      await q(`UPDATE \`system_setting\` SET \`description\` = ? WHERE \`setting_key\` = ?`, [up ? newD : oldD, key]);
    }
    // AI 咨询（祁小山）：开场白与快捷问题胶囊也会下发到客户端，同样不许留「积分」二字
    await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value', ?) WHERE \`setting_key\` = 'ai_greeting'`, [
      up
        ? '我是祁小山，祁连山电竞的客服。订单、余额、售后的事直接说，我帮你看。'
        : '我是祁小山，祁连山电竞的客服。订单、积分、售后的事直接说，我帮你看。',
    ]);
    await q(`UPDATE \`system_setting\` SET \`cfg_value\` = JSON_SET(\`cfg_value\`, '$.value', CAST(? AS JSON)) WHERE \`setting_key\` = 'ai_presets'`, [
      JSON.stringify(
        up
          ? [
              { text: '怎么下单？', label: '怎么下单' },
              { text: '余额怎么用？', label: '余额怎么用' },
              { text: '退款规则是什么？', label: '退款规则' },
              { text: '我要转人工客服', label: '转人工' },
            ]
          : [
              { text: '怎么下单？', label: '怎么下单' },
              { text: '积分怎么用？', label: '积分怎么用' },
              { text: '退款规则是什么？', label: '退款规则' },
              { text: '我要转人工客服', label: '转人工' },
            ],
      ),
    ]);

    // ---- ⑨ 列类型与注释 ----
    // 无条件 ALTER（不改值，只改类型/注释）：`MODIFY` 本身就是幂等的（重复执行结果相同），
    // 所以不需要先查 information_schema 再决定 —— 少一个分支就少一处判断错的机会。
    //
    // recharge_request.points：int → decimal(12,2)。1:1 后必须能存「分」，否则 6.5 元被截断成 6。
    await q(
      `ALTER TABLE \`recharge_request\` MODIFY \`points\` ${up ? 'decimal(12,2)' : 'int'} NOT NULL COMMENT '${
        up
          ? '按当时 points_per_yuan 换算并保留 2 位小数的到账余额（落库快照，事后改比例不影响历史）'
          : '按当时 points_per_yuan 换算的积分（落库快照，事后改比例不影响历史）'
      }'`,
    );
    // order_tip.amount：int → decimal(12,2)。1:1 后打赏预设 [0.6,1.8,3.8,8.8] 元，int 存不下 0.6。
    await q(
      `ALTER TABLE \`order_tip\` MODIFY \`amount\` ${up ? 'decimal(12,2)' : 'int'} NOT NULL COMMENT '${
        up ? '打赏金额（元，最多 2 位小数，服务端校验）' : '打赏积分（正整数，服务端校验）'
      }'`,
    );
    // product.price 只同步列注释（数值已由 ② 折算）
    await q(
      `ALTER TABLE \`product\` MODIFY \`price\` decimal(10,2) NOT NULL COMMENT '${
        up ? '价格（元，支持小数）' : '积分价格（支持小数）'
      }'`,
    );
  }
}
