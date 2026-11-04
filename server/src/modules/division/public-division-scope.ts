import { Raw, type FindOperator } from 'typeorm';

/**
 * 公开侧「分部已上架」可见性口径 —— **全项目唯一一处**（2026-10-08）
 *
 * ## 语义（负责人意图推断，原话「我在管理端下架了，为啥客户端还显示」）
 *
 * **分部下架（`division.status <> 1`）= 其名下内容不再公开**：
 * - 商品：所属分部已下架 → 不再出现在 `/public/products`（列表与详情都不再下发）；
 * - 打手（找陪玩 `/public/players`）：只有在**已上架分部**有接单权限才算「可接单」，才会公开；
 * - 榜单（`/public/leaderboard`）：已下架分部的**分部榜**不再公开（全站榜语义不变）。
 *
 * 为什么这样收口是自洽的：客户端此时**也进不去该分部**（`GET /divisions` 只下发 `status=1`，
 * `DivisionService.listActive()`），所以不会出现「看不到分部却看得到它的商品」的错配；
 * 反之不收口就会复现本次报障——管理端下架了，客户端还在卖。
 *
 * **未挂分部（`division_id IS NULL`）的内容不受分部约束**（保持既有可见性）：
 * 它不属于任何分部，自然不存在"所属分部已下架"；这里刻意不用 `JOIN`/`IN` 的一刀切写法
 * （`JOIN` 会连 NULL 行一起吞掉，`NOT IN` 遇 NULL 恒为 NULL 同样会吞），避免误伤历史数据。
 *
 * ## 使用边界（改这里之前先读）
 *
 * - **只用于公开读路径**。管理端接口必须能看到并管理下架分部的商品
 *   （`ProductService.adminList()` 刻意不挂本条件）。
 * - **订单/结算等写入路径不在这里**：下单时已有 `DivisionService.isUnderConstruction()`
 *   中文拒绝（`OrderService.create` 内），那条是本条件的下游兜底，两边天然一致。
 * - **打手态大厅/抢单的分部权限判定是另一套**（`worker-division-permission.service.ts`
 *   的 `takeOrderDivisionExistsSql`：只认 `can_take_order`，不看分部上架状态），
 *   **本文件不替换它**——大厅"有权限但分部已下架"的可见性由大厅自己决定，不在这里收口。
 *
 * ⚠️ 撤销成本：若要恢复「分部下架但商品仍公开」的行为，只需去掉下列**唯一一处条件**
 * （`ProductService.publicList()` 里 `where.divisionId = publicDivisionFindWhere(...)` 那一行，
 * 见该处注释给出的文件:行号）。
 */

/**
 * 「该内容所属分部可见」SQL 片段（`divisionIdRef` = 分部外键列，如 `p.division_id`）
 *
 * 生成的表达式：`(<ref> IS NULL OR EXISTS (SELECT 1 FROM division d WHERE d.id = <ref> AND d.status = 1))`
 *
 * 用 `EXISTS` 而不是 `JOIN`：语义就是"可见性过滤"，不会因 JOIN 放大行数（商品列表带分页，
 * 行数被放大 = 分页错乱）；且能同时服务裸 SQL（榜单）与 TypeORM 查询构造。
 */
export function publicOwnedDivisionVisibleSql(divisionIdRef: string): string {
  return `(${divisionIdRef} IS NULL OR EXISTS (SELECT 1 FROM division d WHERE d.id = ${divisionIdRef} AND d.status = 1))`;
}

/**
 * TypeORM `find` 版条件（`/public/products` 列表用）
 *
 * 一个表达式同时表达两件事，避免"同一列两个条件"在 `find` 的 where 对象里无法并存：
 * 1. 显式请求了某个分部（`?divisionId=`）→ 只出该分部的行；
 * 2. 该分部必须**已上架** → 请求已下架分部时结果为空（`alias IS NULL` 分支不可能成立）。
 *
 * `requestedDivisionId` 走 TypeORM 具名参数（`:publicReqDivisionId`），**不做字符串拼接**。
 */
export function publicDivisionFindWhere(requestedDivisionId?: string | null): FindOperator<unknown> {
  const requested =
    requestedDivisionId === undefined || requestedDivisionId === null || String(requestedDivisionId).trim() === ''
      ? null
      : String(requestedDivisionId);
  return requested
    ? Raw((alias) => `${alias} = :publicReqDivisionId AND ${publicOwnedDivisionVisibleSql(alias)}`, {
        publicReqDivisionId: requested,
      })
    : Raw((alias) => publicOwnedDivisionVisibleSql(alias));
}

/**
 * 打手「在**已上架分部**有接单权限」的 `EXISTS` 片段（找陪玩公开名单用）
 *
 * `placeholder` 省略 = 不限定具体分部，只要求"存在任一个已上架分部的接单权限"
 * （用于 `/public/players` 不传 `divisionId` 的全局名单：只在已下架分部有权限的打手
 * 既抢不到单、也点不进该分部，公开名单里就不该出现）。
 *
 * 与 `worker-division-permission.service.ts` 的 `takeOrderDivisionExistsSql` 的关系：
 * 那条是**大厅/抢单**的判定（只认权限、不看分部上架状态，一行不许动）；
 * 本函数是**公开名单**的可见性口径，多一个 `d.status = 1`。两者刻意分开，互不替换。
 */
export function publicTakeOrderDivisionExistsSql(placeholder?: string): string {
  return `EXISTS (SELECT 1 FROM worker_division_permission p JOIN division d ON d.id = p.division_id
           WHERE p.worker_id = w.id AND p.can_take_order = 1 AND d.status = 1${
             placeholder ? ` AND p.division_id = ${placeholder}` : ''
           })`;
}

/**
 * 实体级判定（已把分部行读进内存时用，例如商品详情）：
 * **没有分部 = 不受约束**；有分部则以 `status = 1` 为准。
 */
export function isDivisionPubliclyVisible(division: { status?: number | string | null } | null | undefined): boolean {
  if (!division) return true;
  return Number(division.status) === 1;
}
