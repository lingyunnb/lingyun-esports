<script setup lang="ts">
// 安全审计（docs/09）：登录日志（失败/限流审计）+ 操作日志（高危操作留痕）+ 系统运行状态
import { ApiException, request } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { NDataTable, NTabPane, NTabs, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

interface LoginRow {
  id: string;
  user_type: string;
  username: string;
  ip: string;
  result: string;
  fail_reason: string | null;
  created_at: string;
}

interface OpRow {
  id: string;
  admin_name: string;
  module: string;
  action: string;
  method: string;
  path: string;
  request_body: string | null;
  ip: string;
  result: string;
  error_msg: string | null;
  created_at: string;
}

interface SysStatus {
  platform: string;
  hostname: string;
  uptimeSec: number;
  cpuCount: number;
  cpuLoadPercent: number;
  memTotalMB: number;
  memUsedMB: number;
  memUsagePercent: number;
  nodeVersion: string;
}

const message = useMessage();
const auth = useAuthStore();
const logins = ref<LoginRow[]>([]);
const ops = ref<OpRow[]>([]);
const status = ref<SysStatus | null>(null);
const loading = ref(false);
const failOnly = ref(false);

/*
 * 三个接口的权限点是**三把不同的钥匙**（此前把它们塞进同一个 Promise.all → 整页连坐）：
 *   · `GET /admin/logs/logins`     → `admin:log:read`
 *   · `GET /admin/logs/operations` → `admin:audit:read`（本页菜单项断的就是它）
 *   · `GET /admin/system/status`   → `admin:setting:read`
 * 而 `operator` 角色实测**只有 admin:log:read**（没有 admin:audit:read / admin:setting:read）。
 * 旧写法下 `/admin/logs/operations` 先 403，Promise.all 立刻整体 reject →
 * **登录日志表格连数据都拿不到**（页面只剩一句红色报错），而这块恰恰是该账号有权看的。
 * 现在逐个接口独立判定 + 独立失败：无权限**不发请求**并就地说明，其余两块照常渲染。
 */
const canReadLogins = computed(() => auth.hasPermission('admin:log:read'));
const canReadOps = computed(() => auth.hasPermission('admin:audit:read'));
const canReadStatus = computed(() => auth.hasPermission('admin:setting:read'));

async function load() {
  loading.value = true;
  const jobs: Promise<void>[] = [];

  if (canReadLogins.value) {
    jobs.push(
      request<{ list: LoginRow[] }>('GET', `/admin/logs/logins?page=1&pageSize=50${failOnly.value ? '&failOnly=1' : ''}`)
        .then((l) => void (logins.value = l.list ?? []))
        .catch((e) => {
          message.error(e instanceof ApiException ? e.message : '登录日志加载失败');
        }),
    );
  } else {
    logins.value = [];
  }

  if (canReadOps.value) {
    jobs.push(
      request<{ list: OpRow[] }>('GET', '/admin/logs/operations?page=1&pageSize=50')
        .then((o) => void (ops.value = o.list ?? []))
        .catch((e) => {
          message.error(e instanceof ApiException ? e.message : '操作日志加载失败');
        }),
    );
  } else {
    ops.value = [];
  }

  if (canReadStatus.value) {
    jobs.push(
      request<SysStatus>('GET', '/admin/system/status')
        .then((s) => void (status.value = s))
        .catch(() => void (status.value = null)),
    );
  } else {
    status.value = null;
  }

  await Promise.all(jobs);
  loading.value = false;
}
onMounted(load);

function fmtUptime(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

const loginColumns = [
  // 列宽和 = 130+80+90+130+165 = 595（+「失败原因」弹性列 200）→ 模板 :scroll-x = 795
  { title: '账号', key: 'username', width: 130 },
  { title: '类型', key: 'user_type', width: 80 },
  {
    title: '结果', key: 'result', width: 90,
    render: (row: LoginRow) => h(NTag, { size: 'small', type: row.result === 'success' ? 'success' : 'error' }, { default: () => (row.result === 'success' ? '成功' : '失败') }),
  },
  { title: '失败原因', key: 'fail_reason', ellipsis: true },
  { title: 'IP', key: 'ip', width: 130 },
  { title: '时间', key: 'created_at', width: 165, render: (row: LoginRow) => new Date(row.created_at).toLocaleString('zh-CN', { hour12: false }) },
];

const opColumns = [
  // 列宽和 = 100+180+220+80+165 = 745 → 模板 :scroll-x = 745
  { title: '模块', key: 'module', width: 100 },
  { title: '操作', key: 'action', width: 180 },
  { title: '路径', key: 'path', width: 220, ellipsis: true },
  {
    title: '结果', key: 'result', width: 80,
    render: (row: OpRow) => h(NTag, { size: 'small', type: row.result === 'success' ? 'success' : 'error' }, { default: () => row.result }),
  },
  { title: '时间', key: 'created_at', width: 165, render: (row: OpRow) => new Date(row.created_at).toLocaleString('zh-CN', { hour12: false }) },
];
</script>

<template>
  <div class="audit-page">
    <!-- 系统状态另需 admin:setting:read（operator 角色没有）→ 无权限时不渲染，并说明原因 -->
    <div v-if="status" class="status-cards">
      <div class="card"><strong>CPU</strong><span>{{ status.cpuLoadPercent }}%（{{ status.cpuCount }} 核）</span></div>
      <div class="card"><strong>内存</strong><span>{{ status.memUsedMB }}MB / {{ status.memTotalMB }}MB（{{ status.memUsagePercent }}%）</span></div>
      <div class="card"><strong>运行时长</strong><span>{{ fmtUptime(status.uptimeSec) }}</span></div>
      <div class="card"><strong>环境</strong><span>{{ status.platform }} · Node {{ status.nodeVersion }}</span></div>
    </div>
    <p v-else-if="!canReadStatus" class="perm-hint">
      系统运行状态需要 <code>admin:setting:read</code> 权限点（本页其余内容不受影响）。
    </p>
    <n-tabs type="line">
      <n-tab-pane name="logins" tab="登录日志">
        <div class="toolbar">
          <n-tag :type="failOnly ? 'error' : 'default'" style="cursor: pointer" @click="failOnly = !failOnly; load()">
            {{ failOnly ? '只看失败' : '全部记录' }}
          </n-tag>
        </div>
        <p v-if="!canReadLogins" class="perm-hint">登录日志需要 <code>admin:log:read</code> 权限点。</p>
        <n-data-table v-else :columns="loginColumns" :data="logins" :loading="loading" :scroll-x="795" />
      </n-tab-pane>
      <n-tab-pane name="ops" tab="操作日志">
        <p v-if="!canReadOps" class="perm-hint">操作日志需要 <code>admin:audit:read</code> 权限点。</p>
        <n-data-table v-else :columns="opColumns" :data="ops" :loading="loading" :scroll-x="745" />
      </n-tab-pane>
    </n-tabs>
  </div>
</template>

<style scoped>
.status-cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 12px;
  margin-bottom: 16px;
}
.card {
  background: var(--color-bg-card);
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
  padding: 14px 16px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.card strong {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.card span {
  font-size: 15px;
  font-weight: 600;
}
.toolbar {
  margin-bottom: 12px;
}
/* 无权限说明：走三级文字 token（深浅两档都达标），不硬编码颜色 */
.perm-hint {
  margin: 0 0 12px;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--color-text-tertiary);
}
</style>
