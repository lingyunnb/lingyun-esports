import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsIn,
  IsInt,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  Length,
  Matches,
  Max,
  Min,
} from 'class-validator';
import { LenientUpdateDto } from '../../../common/pipes/lenient-validation.pipe';

export class CreateGameDto {
  @ApiProperty({ description: '游戏 code（唯一，如 delta_mobile）' })
  @IsString()
  @Length(2, 32)
  @Matches(/^[a-z0-9_]+$/)
  code: string;

  @ApiProperty({ description: '游戏名称' })
  @IsString()
  @Length(1, 32)
  name: string;

  @ApiPropertyOptional({ description: '排序' })
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional({ description: '1 上架 / 2 下架', default: 1 })
  @IsOptional()
  @IsIn([1, 2])
  status?: number;
}

/** 编辑游戏：允许回传整对象，未知字段静静忽略（管理端「编辑游戏」报障修复） */
export class UpdateGameDto extends LenientUpdateDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 32)
  name?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsIn([1, 2])
  status?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

export class SetGameConfigDto {
  @ApiProperty({ description: '配置项列表（整体替换）' })
  @IsArray()
  configs: {
    key: string;
    value: unknown;
    remark?: string;
  }[];
}

export class CreateCategoryDto {
  @ApiProperty()
  @IsString()
  @Matches(/^\d+$/)
  gameId: string;

  @ApiProperty()
  @IsString()
  @Length(1, 32)
  name: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

/** 编辑分类：允许回传整对象，未知字段静静忽略（管理端「编辑分类」报障修复） */
export class UpdateCategoryDto extends LenientUpdateDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 32)
  name?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsIn([1, 2])
  status?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

export class CreateProductDto {
  @ApiProperty({ description: '商品名称' })
  @IsString({ message: '请填写商品名称' })
  @Length(1, 64, { message: '商品名称长度应为 1~64 字' })
  name: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 64)
  subtitle?: string;

  /**
   * 列表短名（负责人 2026-10-05 任务②）：只在老板端**商品列表卡**上替代完整 `name` 显示；
   * 空串统一转 NULL（管理端「清空」= 列表回退完整名），与 badgeText 同一口径。
   *
   * ≤64 字与 DDL 一致（短名是名字的另一种写法，允许与 name 同长）。
   */
  @ApiPropertyOptional({ description: '列表短名（≤64 字；留空表示列表用完整商品名）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '列表短名必须是文本' })
  @Length(0, 64, { message: '列表短名最多 64 字（留空表示列表用完整商品名）' })
  listName?: string | null;

  /**
   * 徽标文案（负责人 2026-10-05）：卡片左上角小徽标（「董事长推荐」这类）；留空 = 不显示。
   * 空串统一转 NULL（管理端「清空」= 取消徽标），与 divisionId 的处理口径一致。
   */
  @ApiPropertyOptional({ description: '徽标文案（≤32 字；留空表示不显示徽标）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '徽标文案必须是文本' })
  @Length(0, 32, { message: '徽标文案最多 32 字（留空表示不显示徽标）' })
  badgeText?: string | null;

  /** 每周限购（单/账号/周）：留空或 0 = 不限；服务端下单事务内强制（迁移 1796000000000） */
  @ApiPropertyOptional({ description: '每周限购（单/账号/周；留空或 0 表示不限）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsInt({ message: '每周限购必须是整数（留空或 0 表示不限）' })
  @Min(0, { message: '每周限购不能小于 0（留空或 0 表示不限）' })
  @Max(999, { message: '每周限购最大 999 单（留空或 0 表示不限）' })
  weeklyLimit?: number | null;

  /**
   * 限购口径开关（负责人 2026-10-05 任务③）：0=按订单条数（默认，现状）/ 1=按件数 SUM(quantity)。
   * 只接受 0 / 1（中文 400），不传 = 保持原值（编辑时不会把开关悄悄改成 0）。
   */
  @ApiPropertyOptional({ description: '限购口径：0=按订单条数（默认）/ 1=按件数', enum: [0, 1] })
  @IsOptional()
  @IsIn([0, 1], { message: '限购口径只能是 0（按订单条数）或 1（按件数）' })
  weeklyLimitByQuantity?: number;

  @ApiProperty()
  @IsString({ message: '请选择所属游戏' })
  @Matches(/^\d+$/, { message: '请选择所属游戏（gameId 必须是数字 id）' })
  gameId: string;

  @ApiProperty()
  @IsString({ message: '请选择分类' })
  @Matches(/^\d+$/, { message: '请选择分类（categoryId 必须是数字 id）' })
  categoryId: string;

  @ApiPropertyOptional({ description: '分部 id（游戏 + 平台；负责人 2026-10-03，客户端按分部筛选商品）' })
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/, { message: '分部 id 不合法（请重新选择分部）' })
  divisionId?: string;

  @ApiProperty({ description: '价格（元，服务端权威）' })
  @IsNumber({ maxDecimalPlaces: 2 }, { message: '价格必须是数字（最多两位小数）' })
  @Min(0.01, { message: '价格不能低于 0.01' })
  @Max(9_999_999.99, { message: '价格不能超过 9999999.99' })
  price: number;

  @ApiPropertyOptional({ description: '计价单位', default: '局' })
  @IsOptional()
  @IsString()
  @Length(1, 16, { message: '计价单位长度应为 1~16 字' })
  priceUnit?: string;

  @ApiPropertyOptional({ description: '预计服务时长（分钟）' })
  @IsOptional()
  @IsInt({ message: '预计时长必须是整数分钟' })
  @Min(1, { message: '预计时长至少 1 分钟' })
  @Max(10080, { message: '预计时长不能超过 10080 分钟' })
  estimateDurationMin?: number;

  @ApiPropertyOptional({ description: '商品描述' })
  @IsOptional()
  @IsString()
  @Length(0, 2000)
  description?: string;

  @ApiPropertyOptional({ description: '详细介绍' })
  @IsOptional()
  @IsString()
  @Length(0, 10000)
  detail?: string;

  @ApiPropertyOptional({ description: '服务流程' })
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  serviceFlow?: string;

  @ApiPropertyOptional({ description: '服务规则' })
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  serviceRules?: string;

  @ApiPropertyOptional({ description: '注意事项' })
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  attention?: string;

  /**
   * 商品级「下单须知」（负责人 2026-10-05 商品详情页 v2 方案 B；迁移 1799000000000）。
   *
   * 空串统一转 NULL（管理端「清空」= **回退继承平台默认**），与 `badgeText` / `listName`
   * 同一口径 —— 这条约定是管理端「继承/覆盖」两个态能否正确往返的前提。
   * 上限 3000 字（TEXT 存储，DTO 只负责给运营一句中文 400）。
   */
  @ApiPropertyOptional({ description: '下单须知（商品级覆盖；留空表示继承平台默认）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '下单须知必须是文本' })
  @Length(0, 3000, { message: '下单须知最多 3000 字（留空表示继承平台默认）' })
  orderNotice?: string | null;

  /**
   * 扩展字段（游戏特有属性，docs/13）—— **复核修复（2026-10-05 发布工程师）**
   *
   * 上面新增 `orderNotice` 时把本字段整段替换掉了。本 DTO **不继承 `LenientUpdateDto`**，
   * 全局管道是 `whitelist: true, forbidNonWhitelisted: true`（`lenient-validation.pipe.ts`）
   * → 少了这一行，`POST /admin/products` 带 `extraJson` 会直接 **400 property extraJson
   * should not exist**（此前能存进 `product.extra_json`），属**静默的 API 契约收窄**。
   * 按 HEAD 原样恢复（`UpdateProductDto` 里一直没被删，两边口径重新一致）；纯增量、零行为变化。
   */
  @ApiPropertyOptional({ description: '扩展字段（游戏特有属性）' })
  @IsOptional()
  @IsObject()
  extraJson?: Record<string, unknown>;

  @ApiPropertyOptional({ description: '主图媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  coverMediaId?: string;

  @ApiPropertyOptional({ description: '商品视频媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  videoMediaId?: string;

  @ApiPropertyOptional({ description: '视频封面媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  videoCoverMediaId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

/** 编辑商品：允许回传整对象（含 salesCount/coverMediaId 等回显字段），未知字段静静忽略 */
export class UpdateProductDto extends LenientUpdateDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 64)
  name?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 64)
  subtitle?: string;

  /**
   * 列表短名（负责人 2026-10-05 任务②，编辑侧）
   *
   * 与新增同口径：≤64 字；空串 → NULL（管理端清空输入 = 列表回退完整名）。
   * 声明在 UpdateProductDto 里才有意义 —— 白名单校验下未声明的字段会被静默丢弃，
   * 那样「管理端填了短名但保存后不变」会变成最难查的一类 bug（divisionId / badgeText 都踩过）。
   */
  @ApiPropertyOptional({ description: '列表短名（≤64 字；留空表示列表用完整商品名）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '列表短名必须是文本' })
  @Length(0, 64, { message: '列表短名最多 64 字（留空表示列表用完整商品名）' })
  listName?: string | null;

  /**
   * 徽标文案（负责人 2026-10-05，编辑侧）
   *
   * 与新增同口径：≤32 字；空串 → NULL（管理端清空输入 = 取消徽标）。
   * 声明在 UpdateProductDto 里才有意义 —— 白名单校验下，未声明的字段会被静默丢弃，
   * 那样「管理端填了徽标但保存后不变」会变成最难查的一类 bug（divisionId 当初就踩过）。
   */
  @ApiPropertyOptional({ description: '徽标文案（≤32 字；留空表示不显示徽标）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '徽标文案必须是文本' })
  @Length(0, 32, { message: '徽标文案最多 32 字（留空表示不显示徽标）' })
  badgeText?: string | null;

  /** 每周限购（单/账号/周）：空串/0 = 不限；服务端下单事务内强制（迁移 1796000000000） */
  @ApiPropertyOptional({ description: '每周限购（单/账号/周；留空或 0 表示不限）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsInt({ message: '每周限购必须是整数（留空或 0 表示不限）' })
  @Min(0, { message: '每周限购不能小于 0（留空或 0 表示不限）' })
  @Max(999, { message: '每周限购最大 999 单（留空或 0 表示不限）' })
  weeklyLimit?: number | null;

  /**
   * 限购口径开关（负责人 2026-10-05 任务③，编辑侧）
   *
   * 0=按订单条数（默认，现状）/ 1=按件数 SUM(quantity)。**不传 = 保持数据库里的原值**——
   * 老版本管理端/脚本只回传自己认识的字段时，不会把管理员配好的"按件数"悄悄改回"按条数"。
   */
  @ApiPropertyOptional({ description: '限购口径：0=按订单条数（默认）/ 1=按件数', enum: [0, 1] })
  @IsOptional()
  @IsIn([0, 1], { message: '限购口径只能是 0（按订单条数）或 1（按件数）' })
  weeklyLimitByQuantity?: number;

  @ApiPropertyOptional({ description: '价格（元，支持小数，最多两位）' })
  @IsOptional()
  @IsNumber({ maxDecimalPlaces: 2 })
  @Min(0.01)
  @Max(9_999_999.99)
  price?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 16)
  priceUnit?: string;

  /**
   * 分部 id（负责人 2026-10-04 缺口修复）
   *
   * 新增（CreateProductDto）一直支持 divisionId，但编辑 DTO 漏了这个字段 ——
   * 管理端商品页改分部时即使提交也会被白名单静默丢弃，导致「商品挂哪个分部」改不动。
   * 语义与新增一致：数字字符串；空串 / null 表示清空分部（前端下拉 clearable）。
   */
  @ApiPropertyOptional({ description: '分部 id（游戏 + 平台；空表示不挂分部）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @Matches(/^\d+$/, { message: 'divisionId 只能是数字字符串或留空' })
  divisionId?: string | null;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(10080)
  estimateDurationMin?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 2000)
  description?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 10000)
  detail?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  serviceFlow?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  serviceRules?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(0, 5000)
  attention?: string;

  /**
   * 商品级「下单须知」（负责人 2026-10-05；迁移 1799000000000）。
   *
   * `value === '' → null` 这个 Transform 是**管理端「继承/覆盖」两态往返的关键**：
   * 管理端点「继承」时光传空串，服务端必须落成 NULL 而不是空字符串，
   * 否则详情页的 `effectiveOrderNotice` 会拿到空串、须知块整块消失（看起来像功能坏了）。
   * 与 `badgeText` / `listName` / `divisionId` 完全同一口径。
   */
  @ApiPropertyOptional({ description: '下单须知（商品级覆盖；留空表示继承平台默认）' })
  @Transform(({ value }) => (value === '' ? null : value))
  @IsOptional()
  @IsString({ message: '下单须知必须是文本' })
  @Length(0, 3000, { message: '下单须知最多 3000 字（留空表示继承平台默认）' })
  orderNotice?: string | null;

  @ApiPropertyOptional()
  @IsOptional()
  @IsObject()
  extraJson?: Record<string, unknown>;

  @ApiPropertyOptional({ description: '主图媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  coverMediaId?: string;

  @ApiPropertyOptional({ description: '商品视频媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  videoMediaId?: string;

  @ApiPropertyOptional({ description: '视频封面媒体 id（阶段13）' })
  @IsOptional()
  @Matches(/^\d+$/)
  videoCoverMediaId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

export class ProductMediaDto {
  @ApiProperty({ description: 'media id' })
  @IsString()
  @Matches(/^\d+$/)
  mediaId: string;

  @ApiPropertyOptional({ description: 'image / video', default: 'image' })
  @IsOptional()
  @IsIn(['image', 'video'])
  mediaType?: string;

  @ApiPropertyOptional({ description: '是否设为封面', default: 0 })
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1)
  isCover?: number;

  @ApiPropertyOptional({ description: '排序' })
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;
}

export class ProductStatusDto {
  @ApiProperty({ description: '1 上架 / 2 下架' })
  @IsIn([1, 2])
  serviceStatus: number;
}

/**
 * 批量移动商品到另一个分部（负责人 2026-10-05）
 *
 * 语义：把**已存在**的商品整体改归属（division/game/category 三个字段），
 * 名称、价格、单价单位、时长、图片、上下架状态等**一律不动**。
 *
 * id 用 `number`（负责人给的契约）或数字字符串都能收：管理端列表回带的 id 是字符串，
 * 前端手写 payload 时可能给数字 —— 统一 `String()` 归一化后再按 `/^\d+$/` 校验，
 * 避免「同一次请求里数字/字符串混用」被判成非法参数。
 */
export class MoveProductsDto {
  @ApiProperty({ description: '要移动的商品 id 列表（最多 200 个）', type: [Number] })
  @Transform(({ value }) => (Array.isArray(value) ? value.map((v) => String(v)) : value))
  @IsArray({ message: '必须是数组（商品 id 列表）' })
  @ArrayNotEmpty({ message: '不能为空（请至少选择 1 个商品）' })
  @ArrayMaxSize(200, { message: '最多 200 个（请分批移动）' })
  @Matches(/^\d+$/, { each: true, message: '里存在非法编号（只能是数字）' })
  ids: string[];

  @ApiProperty({ description: '目标分部 id', type: Number })
  @Transform(({ value }) => (value === undefined || value === null || value === '' ? value : String(value)))
  @IsString({ message: '不能为空' })
  @Matches(/^\d+$/, { message: '格式不正确（只能是数字）' })
  targetDivisionId: string;

  @ApiPropertyOptional({ description: '目标分类 id（不传则按原分类名在目标游戏下自动匹配/新建）', type: Number })
  @IsOptional()
  @Transform(({ value }) => (value === undefined || value === null || value === '' ? value : String(value)))
  @Matches(/^\d+$/, { message: '格式不正确（只能是数字）' })
  targetCategoryId?: string;
}

export class ProductListQueryDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  gameId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  categoryId?: string;

  @ApiPropertyOptional({ description: '分部 id 过滤（负责人 2026-10-03）' })
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  divisionId?: string;

  @ApiPropertyOptional({ description: '搜索商品名/副标题' })
  @IsOptional()
  @IsString()
  @Length(0, 64)
  keyword?: string;

  @ApiPropertyOptional({ default: 1 })
  @IsOptional()
  @IsInt()
  @Min(1)
  page?: number;

  @ApiPropertyOptional({ default: 20 })
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(50)
  pageSize?: number;
}
