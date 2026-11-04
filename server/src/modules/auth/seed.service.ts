import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import * as bcrypt from 'bcryptjs';
import { DataSource, Repository } from 'typeorm';
import { Admin } from '../admin/admin.entity';
import { AdminRole } from '../rbac/entities/admin-role.entity';
import { AdminRolePermission } from '../rbac/entities/admin-role-permission.entity';
import { Permission } from '../rbac/entities/permission.entity';
import { PERMISSIONS } from '../rbac/permissions.const';
import { User } from '../user/user.entity';

/**
 * 种子数据（幂等，docs/04）：
 * 1. 权限点全量清单（28 个）
 * 2. 内置 super_admin 角色并授予全部权限点
 * 3. 超级管理员账号（ADMIN_USERNAME / ADMIN_PASSWORD 环境变量，绝不允许默认弱密码）
 */
@Injectable()
export class SeedService implements OnApplicationBootstrap {
  private readonly logger = new Logger('Seed');

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(Admin) private readonly adminRepo: Repository<Admin>,
    @InjectRepository(AdminRole) private readonly roleRepo: Repository<AdminRole>,
    @InjectRepository(Permission) private readonly permissionRepo: Repository<Permission>,
    @InjectRepository(AdminRolePermission) private readonly rolePermRepo: Repository<AdminRolePermission>,
    private readonly config: ConfigService,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    // 1. 权限点（INSERT IGNORE 幂等）
    for (const p of PERMISSIONS) {
      await this.permissionRepo
        .createQueryBuilder()
        .insert()
        .values({ code: p.code, name: p.name, groupName: p.group })
        .orIgnore()
        .execute();
    }

    // 2. super_admin 角色
    let superRole = await this.roleRepo.findOne({ where: { code: 'super_admin' } });
    if (!superRole) {
      superRole = await this.roleRepo.save(
        this.roleRepo.create({ code: 'super_admin', name: '超级管理员', isBuiltin: 1 }),
      );
      this.logger.log('已创建内置角色 super_admin');
    }
    const allPermissions = await this.permissionRepo.find();
    for (const perm of allPermissions) {
      await this.rolePermRepo
        .createQueryBuilder()
        .insert()
        .values({ roleId: superRole.id, permissionId: perm.id })
        .orIgnore()
        .execute();
    }

    // 3. 超级管理员账号（环境变量）
    const username = this.config.get<string>('ADMIN_USERNAME', '');
    const password = this.config.get<string>('ADMIN_PASSWORD', '');
    if (!username || !password) {
      this.logger.warn('未配置 ADMIN_USERNAME/ADMIN_PASSWORD，跳过超管账号种子');
      return;
    }
    let adminUser = await this.userRepo.findOne({ where: { username } });
    if (!adminUser) {
      adminUser = await this.userRepo.save(
        this.userRepo.create({
          username,
          uid: `A${Date.now().toString().slice(-9)}`,
          passwordHash: await bcrypt.hash(password, 10),
          nickname: '超级管理员',
          role: 'admin',
          status: 1,
        }),
      );
      await this.adminRepo.save(this.adminRepo.create({ userId: adminUser.id, roleId: superRole.id, status: 1 }));
      this.logger.log(`已创建超级管理员账号 ${username}`);
    } else {
      // 账号已存在：确保档案与角色关联存在
      const exists = await this.adminRepo.findOne({ where: { userId: adminUser.id } });
      if (!exists) {
        await this.adminRepo.save(this.adminRepo.create({ userId: adminUser.id, roleId: superRole.id, status: 1 }));
      }
    }

    // 4. 首页内容自愈种子（表空时补种：迁移只执行一次，数据可能被清空）
    await this.seedHomeContent();
  }

  /** 首页默认内容（模块/公告/优秀打手），INSERT IGNORE 幂等，空表自愈 */
  private async seedHomeContent(): Promise<void> {
    await this.dataSource.query(`
      INSERT IGNORE INTO \`home_module\` (\`module_key\`, \`title\`, \`content\`, \`extra_json\`, \`sort_order\`, \`visible\`) VALUES
      ('club_intro', '关于 祁连山电竞', '祁连山电竞俱乐部专注和平精英、三角洲行动的陪练与上分服务，汇聚优秀打手，用专业与热情陪伴每一位玩家。', NULL, 10, 1),
      ('activity', '俱乐部活动', '', NULL, 40, 2),
      ('order_button', '立即下单', '立即下单', JSON_OBJECT('tab', 'order'), 90, 1),
      ('about_us', '关于 祁连山电竞', '祁连山电竞是专注于和平精英、三角洲行动的陪玩与代练服务平台。\\n\\n我们汇聚经过认证的优秀打手，提供段位上分、代打、娱乐陪玩等服务，让每一位玩家都能享受更轻松的开黑体验。\\n\\n如有疑问请联系在线客服。', NULL, 5, 1),
      ('privacy_policy', '隐私政策', '我们重视你的隐私。\\n\\n1. 我们仅收集提供服务所必需的账号信息（用户名、密码加密存储）。\\n2. 你上传的头像、背景与聊天图片仅用于平台内展示，不会出售或提供给第三方。\\n3. 订单与余额数据仅用于平台服务结算。\\n4. 你可以随时在「账号与安全」中修改密码，或联系管理员删除账号数据。', NULL, 6, 1)
    `);
    // 公告表除主键外没有任何唯一键，INSERT IGNORE 起不到去重作用（每次启动都会重复插入）
    // → 显式「同 title 已存在则跳过」，保证种子幂等（docs/04）
    await this.seedAnnouncementOnce({
      title: '欢迎来到 祁连山电竞',
      summary: '祁连山电竞俱乐部正式上线，快来体验专业陪玩服务。',
      content:
        '祁连山电竞俱乐部正式上线！\n\n我们提供和平精英、三角洲行动的段位上分、代打、娱乐陪玩等服务。\n\n新用户余额由管理员发放，如有疑问请联系客服。',
      pinned: 1,
      sortOrder: 1,
      visible: 1,
    });
    /*
     * 【2026-10-05 删除 `top_worker` 种子插入】
     *
     * 删除依据（表 `top_worker` 与列一律保留，只删种子）：
     * - 该表唯一读取方是 `HomeService.publicHome().topWorkers`，而该字段的唯一消费者是
     *   死代码 `apps/boss-app/lib/pages/home_page.dart`（零 import）；本次已删字段与死代码。
     * - 管理端「优秀打手」入口在「首页管理 → 公告管理」拆分时已下架，无写入方。
     * - 因此原先每次启动都会给 `worker01` 插一条无人展示的打手记录，属于造脏数据。
     *
     * 保留的部分（不动）：
     * - 表 `top_worker` / 实体 / `user-admin.service.ts` 里「删除工作端时清理 top_worker 引用」
     *   的那条 DELETE（保表就必须继续清理，否则会留下指向已删除 worker 的悬空引用）；
     * - `media.service.ts` 的引用计数分支（保表则保计数，见该文件注释）。
     */
  }

  /**
   * 公告种子（幂等）：announcement 表没有 title 唯一键，
   * INSERT IGNORE 无法阻止重复插入 → 先按 title 查一次，存在则跳过。
   * 不新增任何唯一键/结构变更。
   */
  private async seedAnnouncementOnce(item: {
    title: string;
    summary: string;
    content: string;
    pinned: number;
    sortOrder: number;
    visible: number;
  }): Promise<void> {
    const existed = await this.dataSource.query<unknown[]>(
      'SELECT 1 FROM `announcement` WHERE `title` = ? LIMIT 1',
      [item.title],
    );
    if (Array.isArray(existed) && existed.length > 0) return;

    await this.dataSource.query(
      'INSERT IGNORE INTO `announcement` (`title`, `summary`, `content`, `pinned`, `sort_order`, `visible`) VALUES (?, ?, ?, ?, ?, ?)',
      [item.title, item.summary, item.content, item.pinned, item.sortOrder, item.visible],
    );
  }
}
