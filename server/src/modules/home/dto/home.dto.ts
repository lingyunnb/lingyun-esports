import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsDateString, IsIn, IsInt, IsOptional, IsString, Length, Matches, Max, Min } from 'class-validator';

export class UpsertModuleDto {
  @ApiPropertyOptional({ description: '标题' })
  @IsOptional()
  @IsString()
  @Length(1, 64)
  title?: string;

  @ApiPropertyOptional({ description: '内容（文本）' })
  @IsOptional()
  @IsString()
  @Length(0, 10000)
  content?: string;

  @ApiPropertyOptional({ description: '扩展配置 JSON（如按钮文字/跳转）' })
  @IsOptional()
  extraJson?: Record<string, unknown>;

  @ApiPropertyOptional({ description: '排序' })
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional({ description: '1 显示 / 2 隐藏' })
  @IsOptional()
  @IsIn([1, 2])
  visible?: number;
}

/**
 * 首页宣传图（顶部通栏轮播，方案 C）的新建/编辑入参
 *
 * 2026-10-05：本 DTO 随「宣传图管理」页**重新启用**（此前标了 @deprecated，现已去掉）：
 * 管理端新增 `/banners` 页、App 首页新增 `GET /public/banners` 消费方，Banner 不再是死数据。
 * 表 `home_banner` 原样复用，只多了 `subtitle` / `startAt` / `endAt` 三个可空字段
 * （列见 migration `1798000000000`）。
 */
export class UpsertBannerDto {
  @ApiPropertyOptional({ description: '标题（图片上主文案）' })
  @IsOptional()
  @IsString()
  @Length(1, 64)
  title?: string;

  @ApiPropertyOptional({ description: '副标题（图片上第二行文案；留空不显示）' })
  @IsOptional()
  @IsString()
  @Length(0, 64)
  subtitle?: string;

  @ApiPropertyOptional({ description: '图片 URL（历史兼容；新数据请传 imageMediaId）' })
  @IsOptional()
  @IsString()
  @Length(0, 500)
  imageUrl?: string;

  @ApiPropertyOptional({ description: '图片媒体 id（阶段13，优先于 imageUrl）' })
  @IsOptional()
  @Matches(/^\d+$/)
  imageMediaId?: string;

  @ApiPropertyOptional({
    description: '跳转类型：none 无跳转 / product 商品 / division 分部 / announcement 公告 / url 外链 / tab 切底部tab（历史值，管理端不再提供）',
    default: 'none',
  })
  @IsOptional()
  @IsIn(['none', 'tab', 'product', 'division', 'announcement', 'url'])
  linkType?: string;

  @ApiPropertyOptional({ description: '跳转值（按 linkType：商品id / 分部id / 公告id / 外链地址；none 时留空）' })
  @IsOptional()
  @IsString()
  @Length(0, 255)
  linkValue?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional({ description: '1 显示 / 2 隐藏（**不是 0/1**）' })
  @IsOptional()
  @IsIn([1, 2])
  visible?: number;

  /**
   * 投放时间区间（可选）。**不传 = 该端不限制**，传字符串清空 = 置 NULL（同样表示不限制）。
   *
   * 用 `@IsDateString()` 而不是 `@IsDate()`：前端 naive-ui 的 `NDatePicker`（type=datetime）
   * 拿到的是时间戳（number），提交时转 ISO 字符串；服务端统一按 ISO 字符串收，
   * 再在 service 里 `new Date(...)` 落库。这样管理端不必关心后端时区格式。
   */
  @ApiPropertyOptional({ description: '投放开始时间（ISO 字符串；留空=不限制）' })
  @IsOptional()
  @IsDateString()
  startAt?: string | null;

  @ApiPropertyOptional({ description: '投放结束时间（ISO 字符串；留空=不限制）' })
  @IsOptional()
  @IsDateString()
  endAt?: string | null;
}

export class UpsertAnnouncementDto {
  @ApiPropertyOptional({ description: '标题' })
  @IsOptional()
  @IsString()
  @Length(1, 100)
  title?: string;

  @ApiPropertyOptional({ description: '摘要' })
  @IsOptional()
  @IsString()
  @Length(0, 500)
  summary?: string;

  @ApiPropertyOptional({ description: '正文' })
  @IsOptional()
  @IsString()
  @Length(1, 10000)
  content?: string;

  @ApiPropertyOptional({ description: '1 置顶 / 0 普通' })
  @IsOptional()
  @IsIn([0, 1])
  pinned?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional({ description: '1 显示 / 2 隐藏' })
  @IsOptional()
  @IsIn([1, 2])
  visible?: number;
}

/**
 * @deprecated 2026-10-05 起无调用方：管理端「优秀打手」配置入口已下架
 * （`admin-web/src` grep `home/top-workers` 零命中），`GET /public/home` 的 `topWorkers`
 * 字段也已删除。`seed.service.ts` 里的 `top_worker` 种子同批移除。
 * 保留 DTO 仅为让已废弃的 `home/top-workers*` 路由继续可编译/可响应；**表 `top_worker` 不删**。
 */
export class UpsertTopWorkerDto {
  @ApiPropertyOptional({ description: 'worker 档案 id' })
  @IsOptional()
  @IsString()
  @Matches(/^\d+$/)
  workerId?: string;

  @ApiPropertyOptional({ description: '展示昵称' })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  displayName?: string;

  @ApiPropertyOptional({ description: '头像 URL（历史兼容）' })
  @IsOptional()
  @IsString()
  @Length(0, 500)
  avatarUrl?: string;

  @ApiPropertyOptional({ description: '头像媒体 id（阶段13，优先于 avatarUrl）' })
  @IsOptional()
  @Matches(/^\d+$/)
  avatarMediaId?: string;

  @ApiPropertyOptional({ description: '擅长游戏/项目' })
  @IsOptional()
  @IsString()
  @Length(0, 100)
  skills?: string;

  @ApiPropertyOptional({ description: '服务评价（0-5，一位小数）' })
  @IsOptional()
  @IsString()
  @Matches(/^[0-5](\.\d)?$/)
  rating?: string;

  @ApiPropertyOptional({ description: '完成单量展示值' })
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1000000)
  completedOrders?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional({ description: '1 显示 / 2 隐藏' })
  @IsOptional()
  @IsIn([1, 2])
  visible?: number;
}
