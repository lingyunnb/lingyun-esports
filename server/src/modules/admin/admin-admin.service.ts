import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import * as bcrypt from 'bcryptjs';
import { randomInt } from 'crypto';
import { DataSource, EntityManager } from 'typeorm';
import { AdminRole } from '../rbac/entities/admin-role.entity';
import { AdminRolePermission } from '../rbac/entities/admin-role-permission.entity';
import { Permission } from '../rbac/entities/permission.entity';
import { User } from '../user/user.entity';
import { Admin } from './admin.entity';

/**
 * 管理员与角色管理（docs/04）：
 * - 创建管理员（账号 + 档案 + 角色）；重置密码；启禁用；改角色
 * - 角色 CRUD + 权限点分配（super_admin 内置角色不可改）
 * - 安全保护：不能禁用/降级自己；不能改动最后一个超级管理员
 */
@Injectable()
export class AdminAdminService {
  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  /** 管理员列表（含角色与权限数） */
  async listAdmins() {
    const rows: Array<{ id: string; user_id: string; username: string; nickname: string; status: number; role_code: string; role_name: string; role_id: string; created_at: Date }> =
      await this.dataSource.query(
        `SELECT a.id, a.user_id, u.username, u.nickname, a.status, r.code AS role_code, r.name AS role_name, r.id AS role_id, a.created_at
         FROM admin a JOIN user u ON u.id = a.user_id LEFT JOIN admin_role r ON r.id = a.role_id
         ORDER BY a.id ASC`,
      );
    return rows.map((r) => ({
      id: r.id,
      userId: String(r.user_id),
      username: r.username,
      nickname: r.nickname,
      status: Number(r.status),
      roleCode: r.role_code,
      roleName: r.role_name,
      roleId: String(r.role_id),
      createdAt: r.created_at,
    }));
  }

  /** 创建管理员账号（事务：user + admin 档案） */
  async createAdmin(adminUserId: string, dto: { username: string; password: string; nickname?: string; roleCode: string }) {
    const exists = await this.dataSource.getRepository(User).findOne({ where: { username: dto.username } });
    if (exists) throw new ConflictException('账号已存在');
    // 安全修复（2026-09-23）：roleCode 缺失时 TypeORM 会忽略该条件并返回**第一行角色**（super_admin），
    // 造成「漏传参数 = 静默授予超管」的权限提升漏洞 → 必须显式校验
    if (!dto.roleCode || typeof dto.roleCode !== 'string') {
      throw new BadRequestException('请选择要分配的角色');
    }
    const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { code: dto.roleCode } });
    if (!role) throw new BadRequestException('角色不存在');
    if (!dto.password || dto.password.length < 8 || dto.password.length > 64) {
      throw new BadRequestException('密码须为 8-64 位');
    }
    return this.dataSource.transaction(async (em) => {
      const user = await em.save(
        em.create(User, {
          username: dto.username,
          uid: `A${randomInt(100_000_000, 1_000_000_000)}`,
          passwordHash: await bcrypt.hash(dto.password, 10),
          nickname: dto.nickname || dto.username,
          role: 'admin',
          status: 1,
        }),
      );
      const admin = await em.save(em.create(Admin, { userId: user.id, roleId: role.id, status: 1 }));
      return { id: admin.id, userId: user.id, username: user.username, roleCode: role.code };
    });
  }

  /** 编辑管理员（昵称/状态/角色）+ 安全保护 */
  async updateAdmin(operatorUserId: string, id: string, dto: { nickname?: string; status?: number; roleCode?: string }) {
    const admin = await this.dataSource.getRepository(Admin).findOne({ where: { id } });
    if (!admin) throw new NotFoundException('管理员不存在');
    // 封禁/解封是所有者独占操作（防止用编辑接口绕过 @OwnerOnly 的封号限制）
    if (dto.status !== undefined && dto.status !== admin.status) {
      const op = await this.dataSource.getRepository(Admin).findOne({ where: { userId: operatorUserId } });
      if (op?.isOwner !== 1) {
        throw new BadRequestException('启用/禁用管理员账号仅限所有者账号操作');
      }
    }
    const target = await this.dataSource.getRepository(User).findOne({ where: { id: admin.userId } });
    if (!target) throw new NotFoundException('账号不存在');
    const isSelf = String(admin.userId) === String(operatorUserId);
    if (isSelf && dto.status === 2) throw new BadRequestException('不能禁用自己的账号');
    if (dto.roleCode) {
      const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { code: dto.roleCode } });
      if (!role) throw new BadRequestException('角色不存在');
      const currentRole = await this.dataSource.getRepository(AdminRole).findOne({ where: { id: admin.roleId } });
      // 禁止把最后一个超管降级（防系统失去管理能力）
      if (currentRole?.code === 'super_admin' && role.code !== 'super_admin') {
        const cnt: Array<{ n: string }> = await this.dataSource.query(
          `SELECT COUNT(*) AS n FROM admin a JOIN admin_role r ON r.id = a.role_id WHERE r.code = 'super_admin' AND a.status = 1`,
        );
        if (Number(cnt[0].n) <= 1) throw new BadRequestException('系统必须保留至少一个超级管理员');
      }
      if (isSelf && currentRole?.code === 'super_admin' && role.code !== 'super_admin') {
        throw new BadRequestException('不能降低自己的角色（请用另一个超管账号操作）');
      }
      admin.roleId = role.id;
    }
    if (dto.status !== undefined) admin.status = dto.status;
    await this.dataSource.getRepository(Admin).save(admin);
    if (dto.nickname !== undefined) {
      target.nickname = dto.nickname;
      await this.dataSource.getRepository(User).save(target);
    }
    // 角色/状态/昵称变化后吊销该账号会话（保证权限立即生效）
    await this.dataSource.query(`UPDATE auth_token SET revoked = 1 WHERE user_id = ? AND revoked = 0`, [admin.userId]);
    return { ok: true };
  }

  /** 封禁管理员账号（所有者独占）：禁用 + 立即吊销全部会话；防自锁保护 */
  async banAdmin(operatorUserId: string, id: string) {
    const admin = await this.dataSource.getRepository(Admin).findOne({ where: { id } });
    if (!admin) throw new NotFoundException('管理员不存在');
    if (String(admin.userId) === String(operatorUserId)) {
      throw new BadRequestException('不能封禁自己的账号');
    }
    const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { id: admin.roleId } });
    // 禁止封禁最后一个在用超管（防系统失去管理能力）
    if (role?.code === 'super_admin') {
      const cnt: Array<{ n: string }> = await this.dataSource.query(
        `SELECT COUNT(*) AS n FROM admin a JOIN admin_role r ON r.id = a.role_id WHERE r.code = 'super_admin' AND a.status = 1`,
      );
      if (Number(cnt[0].n) <= 1) throw new BadRequestException('系统必须保留至少一个启用中的超级管理员');
    }
    await this.dataSource.getRepository(Admin).update(id, { status: 2 });
    await this.dataSource.query(`UPDATE auth_token SET revoked = 1 WHERE user_id = ? AND revoked = 0`, [admin.userId]);
    const target = await this.dataSource.getRepository(User).findOne({ where: { id: admin.userId } });
    return { ok: true, username: target?.username ?? '' };
  }

  /** 解封管理员账号（所有者独占） */
  async unbanAdmin(id: string) {
    const admin = await this.dataSource.getRepository(Admin).findOne({ where: { id } });
    if (!admin) throw new NotFoundException('管理员不存在');
    if (admin.status !== 2) throw new BadRequestException('该账号未被封禁');
    await this.dataSource.getRepository(Admin).update(id, { status: 1 });
    return { ok: true };
  }

  /** 注销管理员账号（负责人需求）：删除账号本体 + 会话；防自锁保护；操作日志仍保留（审计不断链） */
  async deleteAdmin(operatorUserId: string, id: string) {
    const admin = await this.dataSource.getRepository(Admin).findOne({ where: { id } });
    if (!admin) throw new NotFoundException('管理员不存在');
    if (String(admin.userId) === String(operatorUserId)) {
      throw new BadRequestException('不能注销自己的账号（请用另一个超管账号操作）');
    }
    const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { id: admin.roleId } });
    // 禁止注销最后一个在用超管（防系统失去管理能力）
    if (role?.code === 'super_admin') {
      const cnt: Array<{ n: string }> = await this.dataSource.query(
        `SELECT COUNT(*) AS n FROM admin a JOIN admin_role r ON r.id = a.role_id WHERE r.code = 'super_admin' AND a.status = 1`,
      );
      if (Number(cnt[0].n) <= 1) throw new BadRequestException('系统必须保留至少一个超级管理员');
    }
    const target = await this.dataSource.getRepository(User).findOne({ where: { id: admin.userId } });
    await this.dataSource.transaction(async (em) => {
      await em.query(`UPDATE auth_token SET revoked = 1 WHERE user_id = ? AND revoked = 0`, [admin.userId]);
      await em.query(`DELETE FROM admin WHERE id = ?`, [id]);
      await em.query(`DELETE FROM auth_token WHERE user_id = ?`, [admin.userId]);
      await em.query(`DELETE FROM user WHERE id = ?`, [admin.userId]);
    });
    return { ok: true, username: target?.username ?? '' };
  }

  /** 重置管理员密码（吊销其全部会话） */
  async resetPassword(id: string, password: string) {
    const admin = await this.dataSource.getRepository(Admin).findOne({ where: { id } });
    if (!admin) throw new NotFoundException('管理员不存在');
    if (!password || password.length < 8 || password.length > 64) throw new BadRequestException('密码须为 8-64 位');
    await this.dataSource.getRepository(User).update(admin.userId, { passwordHash: await bcrypt.hash(password, 10) });
    await this.dataSource.query(`UPDATE auth_token SET revoked = 1 WHERE user_id = ? AND revoked = 0`, [admin.userId]);
    return { ok: true };
  }

  // ---------------- 角色 ----------------

  /** 角色列表（含权限点 code 列表） */
  async listRoles() {
    const roles = await this.dataSource.getRepository(AdminRole).find({ order: { id: 'ASC' } });
    const rows: Array<{ role_id: string; code: string }> = await this.dataSource.query(
      `SELECT rp.role_id, p.code FROM admin_role_permission rp JOIN permission p ON p.id = rp.permission_id`,
    );
    const byRole = new Map<string, string[]>();
    for (const r of rows) {
      const arr = byRole.get(String(r.role_id)) ?? [];
      arr.push(r.code);
      byRole.set(String(r.role_id), arr);
    }
    return roles.map((r) => ({
      id: r.id,
      code: r.code,
      name: r.name,
      isBuiltin: Number(r.isBuiltin) === 1,
      permissions: (byRole.get(String(r.id)) ?? []).sort(),
    }));
  }

  /** 全部权限点（UI 分配用，按 group 分组） */
  async listPermissions() {
    const rows: Array<{ code: string; name: string; group_name: string }> = await this.dataSource.query(
      `SELECT code, name, group_name FROM permission ORDER BY group_name, id`,
    );
    return rows.map((r) => ({ code: r.code, name: r.name, group: r.group_name }));
  }

  /** 创建角色（含权限点） */
  async createRole(operatorUserId: string, dto: { code: string; name: string; permissions: string[] }) {
    const exists = await this.dataSource.getRepository(AdminRole).findOne({ where: { code: dto.code } });
    if (exists) throw new ConflictException('角色标识已存在');
    if (!/^[a-z][a-z0-9_]{1,31}$/.test(dto.code)) throw new BadRequestException('角色标识须为小写字母数字下划线（2-32 位）');
    return this.dataSource.transaction(async (em) => {
      const role = await em.save(em.create(AdminRole, { code: dto.code, name: dto.name, isBuiltin: 0 }));
      await this.assignPermissions(em, role.id, dto.permissions, operatorUserId);
      return { id: role.id, code: role.code };
    });
  }

  /** 更新角色（名称/权限点）；内置角色不可改权限 */
  async updateRole(operatorUserId: string, id: string, dto: { name?: string; permissions?: string[] }) {
    const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { id } });
    if (!role) throw new NotFoundException('角色不存在');
    if (Number(role.isBuiltin) === 1 && dto.permissions) {
      throw new BadRequestException('内置角色（超级管理员）权限不可修改');
    }
    if (dto.name) {
      role.name = dto.name;
      await this.dataSource.getRepository(AdminRole).save(role);
    }
    if (dto.permissions) {
      const perms = dto.permissions;
      await this.dataSource.transaction(async (em) => {
        await em.delete(AdminRolePermission, { roleId: role.id });
        await this.assignPermissions(em, role.id, perms, operatorUserId);
      });
    }
    // 角色权限变化 → 吊销该角色下所有管理员会话（权限立即生效）
    await this.dataSource.query(
      `UPDATE auth_token SET revoked = 1 WHERE revoked = 0 AND user_id IN (SELECT a.user_id FROM admin a WHERE a.role_id = ?)`,
      [role.id],
    );
    return { ok: true };
  }

  private async assignPermissions(em: EntityManager, roleId: string, codes: string[], grantedBy: string) {
    if (!codes?.length) return;
    const perms: Permission[] = await em.getRepository(Permission).find();
    const byCode = new Map(perms.map((p) => [p.code, p]));
    const unknown = codes.filter((c) => !byCode.has(c));
    if (unknown.length) throw new BadRequestException(`存在无法识别的权限项：${unknown.join('、')}`);
    await em.save(
      codes.map((c) => em.create(AdminRolePermission, { roleId, permissionId: byCode.get(c)!.id, grantedBy })),
    );
  }
}
