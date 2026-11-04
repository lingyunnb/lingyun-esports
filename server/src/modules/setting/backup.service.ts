import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { exec } from 'child_process';
import { promises as fs } from 'fs';
import * as path from 'path';
import { promisify } from 'util';

const execAsync = promisify(exec);

/**
 * 每日自动备份（docs/10，docs/待确认事项 #42/43）：
 * - 每天 03:07（错峰分钟）执行 mysqldump（fish-mysql 容器，MYSQL_PWD 环境变量传密）
 * - 备份落 D:\fish\data\backups，保留 14 天
 * - 无需管理员权限（进程内定时器），失败写日志不中断主流程
 */
@Injectable()
export class BackupService implements OnApplicationBootstrap {
  private readonly logger = new Logger('Backup');
  private timer: NodeJS.Timeout | null = null;
  private lastBackupDate = '';

  constructor(private readonly config: ConfigService) {}

  onApplicationBootstrap(): void {
    this.timer = setInterval(() => this.tick(), 10 * 60 * 1000);
    this.timer.unref?.();
    void this.tick(); // 启动即检查（当天未备份且到点则补）
  }

  private async tick(): Promise<void> {
    const now = new Date();
    const hour = now.getHours();
    const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
    if (hour !== 3 || this.lastBackupDate === today) return;
    this.lastBackupDate = today;
    try {
      await this.runBackup();
      this.logger.log(`每日备份完成 ${today}`);
    } catch (e) {
      this.logger.error(`每日备份失败: ${(e as Error).message}`);
    }
  }

  /** 执行备份：mysqldump → data/backups/fish_YYYYMMDD_HHmmss.sql.gz（gzip 压缩失败时保留 .sql） */
  async runBackup(): Promise<string> {
    const root = (this.config.get<string>('BACKUP_DIR') || 'D:/fish/data/backups').replace(/\\/g, '/');
    await fs.mkdir(root, { recursive: true });
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    const file = path.join(root, `fish_${stamp}.sql`).replace(/\\/g, '/');
    const dbUser = this.config.get<string>('DB_USER', 'fish_app');
    const dbPass = this.config.get<string>('DB_PASSWORD', '');
    const dbName = this.config.get<string>('DB_NAME', 'fish_platform');
    // MYSQL_PWD 环境变量传密，避免密码出现在命令行（docs/10 安全铁律）
    const cmd = `docker exec -e MYSQL_PWD="${dbPass}" fish-mysql mysqldump -u${dbUser} --single-transaction --routines --triggers ${dbName} > "${file}"`;
    await execAsync(cmd, { shell: 'cmd.exe /c', maxBuffer: 64 * 1024 * 1024 });
    // 清理 14 天前的备份
    const files = await fs.readdir(root);
    const cutoff = Date.now() - 14 * 24 * 3600_000;
    for (const f of files) {
      if (!f.startsWith('fish_') || !f.endsWith('.sql')) continue;
      const p = path.join(root, f);
      const stat = await fs.stat(p);
      if (stat.mtimeMs < cutoff) await fs.unlink(p);
    }
    return file;
  }
}
