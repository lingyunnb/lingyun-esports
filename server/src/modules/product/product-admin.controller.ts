import { Body, Controller, Delete, Get, Param, Post, Put, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { CreateProductDto, MoveProductsDto, ProductListQueryDto, ProductMediaDto, ProductStatusDto, UpdateProductDto } from '../game/dto/catalog.dto';
import { ProductService } from './product.service';

/** 商品管理（RBAC，docs/02：价格服务端权威，新建默认下架） */
@ApiTags('admin/products')
@Controller('admin/products')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class ProductAdminController {
  constructor(private readonly service: ProductService) {}

  @Get()
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：商品列表（分页/过滤/搜索；支持 divisionId 分部筛选）' })
  list(@Query() q: ProductListQueryDto) {
    return this.service.adminList({
      gameId: q.gameId,
      categoryId: q.categoryId,
      // 分部筛选（负责人 2026-10-05 报障修复）：DTO 里 divisionId 早就声明并校验了，
      // 但这里没往下传 + service 也没这个条件 → 「按分部筛选」返回全部商品。
      divisionId: q.divisionId,
      keyword: q.keyword,
      page: q.page ?? 1,
      pageSize: q.pageSize ?? 20,
    });
  }

  @Post()
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：新增商品（默认下架，需手动上架）' })
  create(@Body() dto: CreateProductDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    // 审计（operation_log，module='product' action='product:create'）在 service 内**与数据变更同事务**写入，
    // 这里只把操作者信息传下去（adminUserId 来自 JWT，客户端伪造不了）
    return this.service.create(dto, {
      adminUserId: user.userId,
      ip: req.ip,
      requestId: req.requestId,
      path: req.path,
      method: req.method,
    });
  }

  /**
   * 批量移动商品到另一个分部（负责人 2026-10-05）
   *
   * 路径选 `POST /admin/products/move`（与既有 `POST /admin/products/:id/status` 同前缀同分组，
   * 单段路径不会与 `:id/status` 冲突）；权限沿用商品写权限 `admin:product:write`。
   * 事务/校验/审计全在 service.moveProducts（审计与数据变更同事务）。
   */
  @Post('move')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：批量移动商品到另一个分部（名称/价格/时长等全部不变，只改归属）' })
  move(@Body() dto: MoveProductsDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.moveProducts(
      { ids: dto.ids, targetDivisionId: dto.targetDivisionId, targetCategoryId: dto.targetCategoryId },
      { adminUserId: user.userId, ip: req.ip, requestId: req.requestId, path: req.path, method: req.method },
    );
  }

  @Put(':id')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：编辑商品（含简介/改价，不影响历史订单快照；未知字段忽略不报错）' })
  update(@Param('id') id: string, @Body() dto: UpdateProductDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.update(id, dto, {
      adminUserId: user.userId,
      ip: req.ip,
      requestId: req.requestId,
      path: req.path,
      method: req.method,
    });
  }

  @Post(':id/status')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：上架/下架' })
  updateStatus(@Param('id') id: string, @Body() dto: ProductStatusDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.updateStatus(id, dto.serviceStatus, {
      adminUserId: user.userId,
      ip: req.ip,
      requestId: req.requestId,
      path: req.path,
      method: req.method,
    });
  }

  @Delete(':id')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：删除商品（有订单记录时拒绝，建议下架）' })
  remove(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.deleteProduct(id, {
      adminUserId: user.userId,
      ip: req.ip,
      requestId: req.requestId,
      path: req.path,
      method: req.method,
    });
  }

  @Post(':id/media')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：挂载商品媒体（多图/视频）' })
  addMedia(@Param('id') id: string, @Body() dto: ProductMediaDto) {
    return this.service.addMedia(id, dto);
  }

  @Delete(':id/media/:mediaRowId')
  @RequirePermission('admin:product:write')
  @ApiOperation({ summary: '权限点 admin:product:write：移除商品媒体挂载' })
  removeMedia(@Param('id') id: string, @Param('mediaRowId') mediaRowId: string) {
    return this.service.removeMedia(id, mediaRowId);
  }
}
