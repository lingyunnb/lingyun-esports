<script setup lang="ts">
// 管理员与角色管理（docs/04）：管理员列表/创建/编辑/重置密码 + 角色与权限点分配
// 安全保护由服务端强制：不能禁用自己、不能降级最后一名超管、内置超管角色权限不可改
import { ApiException, request } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import { NButton, NCheckbox, NCheckboxGroup, NDataTable, NDropdown, NForm, NFormItem, NInput, NModal, NSelect, NTabPane, NTabs, NTag, useDialog, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';
import type { VNode } from 'vue';
import type { DropdownOption } from 'naive-ui';

interface AdminRow {
  id: string;
  userId: string;
  username: string;
  nickname: string;
  status: number;
  roleCode: string;
  roleName: string;
  roleId: string;
  createdAt: string;
}

interface RoleRow {
  id: string;
  code: string;
  name: string;
  isBuiltin: boolean;
  permissions: string[];
}

interface PermRow {
  code: string;
  name: string;
  group: string;
}

const message = useMessage();
const dialog = useDialog();
const auth = useAuthStore();
const admins = ref<AdminRow[]>([]);
const roles = ref<RoleRow[]>([]);
const perms = ref<PermRow[]>([]);
const loading = ref(false);

async function loadAll() {
  loading.value = true;
  try {
    const [a, r, p] = await Promise.all([
      request<AdminRow[]>('GET', '/admin/admins'),
      request<RoleRow[]>('GET', '/admin/roles'),
      request<PermRow[]>('GET', '/admin/permissions'),
    ]);
    admins.value = a;
    roles.value = r;
    perms.value = p;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(loadAll);

const canWrite = computed(() => auth.hasPermission('admin:admin:write'));
// 所有者账号（kslingyun）：独占封号/注销其他管理员
const isOwner = computed(() => auth.isOwner);
const canRole = computed(() => auth.hasPermission('admin:role:write'));
const roleOptions = computed(() => roles.value.map((r) => ({ label: `${r.name}（${r.code}）`, value: r.code })));

// ---------- 管理员：新建/编辑/重置密码 ----------
const showAdmin = ref(false);
const editAdminId = ref<string | null>(null);
const adminForm = reactive({ username: '', password: '', nickname: '', roleCode: 'operator' });
function openCreateAdmin() {
  editAdminId.value = null;
  Object.assign(adminForm, { username: '', password: '', nickname: '', roleCode: roles.value[0]?.code ?? 'operator' });
  showAdmin.value = true;
}
function openEditAdmin(row: AdminRow) {
  editAdminId.value = row.id;
  Object.assign(adminForm, { username: row.username, password: '', nickname: row.nickname, roleCode: row.roleCode });
  showAdmin.value = true;
}
async function saveAdmin() {
  try {
    if (editAdminId.value) {
      await request('PUT', `/admin/admins/${editAdminId.value}`, { nickname: adminForm.nickname, roleCode: adminForm.roleCode });
      message.success('已保存（该管理员会话已重置，需重新登录）');
    } else {
      if (!adminForm.username || adminForm.password.length < 8) { message.warning('请填写账号与至少 8 位密码'); return; }
      await request('POST', '/admin/admins', { ...adminForm });
      message.success('管理员已创建');
    }
    showAdmin.value = false;
    await loadAll();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  }
}
// ---------- 所有者独占：封号 / 解封 / 注销 ----------
async function banAdmin(row: AdminRow) {
  dialog.warning({
    title: '封禁管理员账号',
    content: `确定封禁「${row.username}」？将立即吊销其全部会话，该账号无法再登录管理端。`,
    positiveText: '确认封禁',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('POST', `/admin/admins/${row.id}/ban`);
        message.success('已封禁（会话已吊销）');
        await loadAll();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '操作失败');
      }
    },
  });
}

async function unbanAdmin(row: AdminRow) {
  try {
    await request('POST', `/admin/admins/${row.id}/unban`);
    message.success('已解封');
    await loadAll();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

function deleteAdmin(row: AdminRow) {
  dialog.error({
    title: '注销管理员账号',
    content: `确定注销「${row.username}」？账号将被彻底删除且不可恢复（审计日志保留）。`,
    positiveText: '确认注销',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/admins/${row.id}`);
        message.success('账号已注销');
        await loadAll();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '注销失败');
      }
    },
  });
}

const showReset = ref(false);
const resetRow = ref<AdminRow | null>(null);
const resetPw = ref('');
function openReset(row: AdminRow) {
  resetRow.value = row;
  resetPw.value = '';
  showReset.value = true;
}
async function doReset() {
  if (!resetRow.value) return;
  if (resetPw.value.length < 8) { message.warning('密码至少 8 位'); return; }
  try {
    await request('POST', `/admin/admins/${resetRow.value.id}/reset-password`, { password: resetPw.value });
    message.success('密码已重置（该管理员全部设备已下线）');
    showReset.value = false;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '重置失败');
  }
}

// ---------- 角色：新建/编辑权限 ----------
const showRole = ref(false);
const editRoleId = ref<string | null>(null);
const roleForm = reactive({ code: '', name: '', permissions: [] as string[] });
function openCreateRole() {
  editRoleId.value = null;
  Object.assign(roleForm, { code: '', name: '', permissions: [] });
  showRole.value = true;
}
function openEditRole(row: RoleRow) {
  editRoleId.value = row.id;
  Object.assign(roleForm, { code: row.code, name: row.name, permissions: [...row.permissions] });
  showRole.value = true;
}
async function saveRole() {
  try {
    if (editRoleId.value) {
      await request('PUT', `/admin/roles/${editRoleId.value}`, { name: roleForm.name, permissions: roleForm.permissions });
      message.success('角色已更新（该角色管理员会话已重置）');
    } else {
      if (!roleForm.code || !roleForm.name) { message.warning('请填写角色标识与名称'); return; }
      await request('POST', '/admin/roles', { ...roleForm });
      message.success('角色已创建');
    }
    showRole.value = false;
    await loadAll();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  }
}

/** 权限点按 group 分组（UI 展示） */
const permGroups = computed(() => {
  const map = new Map<string, PermRow[]>();
  for (const p of perms.value) {
    const arr = map.get(p.group) ?? [];
    arr.push(p);
    map.set(p.group, arr);
  }
  return [...map.entries()].map(([group, items]) => ({ group, items }));
});

const adminColumns = [
  { title: '账号', key: 'username', width: 140 },
  { title: '昵称', key: 'nickname', width: 140 },
  {
    title: '角色', key: 'roleName', width: 140,
    render: (row: AdminRow) => h(NTag, { size: 'small', type: row.roleCode === 'super_admin' ? 'error' : 'info' }, { default: () => row.roleName ?? row.roleCode }),
  },
  {
    title: '状态', key: 'status', width: 90,
    render: (row: AdminRow) => h(NTag, { size: 'small', type: row.status === 1 ? 'success' : 'default' }, { default: () => (row.status === 1 ? '正常' : '已禁用') }),
  },
  { title: '创建时间', key: 'createdAt', width: 170, render: (row: AdminRow) => new Date(row.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 140+140+140+90+170+260 = 940（⚠️ :scroll-x 必须 ≥ 这个和，改列宽要同步改）
    // 原 340px 要塞 4 个按钮（编辑/重置密码/封号/注销），既挤又吃宽度 ——
    // 按「主要动作按钮 + 更多下拉」收口：常用两个留在外面，破坏性动作（封号/注销）进 n-dropdown。
    // fixed:'right'：横向滚动时操作列始终完整可见。
    title: '操作', key: 'actions', width: 260, fixed: 'right' as const,
    render: (row: AdminRow) => {
      const main: VNode[] = [];
      if (canWrite.value) {
        main.push(h(NButton, { size: 'small', onClick: () => openEditAdmin(row) }, { default: () => '编辑' }));
        main.push(h(NButton, { size: 'small', onClick: () => openReset(row) }, { default: () => '重置密码' }));
      }
      // 封号 / 注销：仅所有者账号（kslingyun）可见可用，服务端二次校验
      const more: DropdownOption[] = [];
      if (isOwner.value) {
        more.push({
          label: row.status === 1 ? '封号' : '解封',
          key: 'ban',
          props: { style: row.status === 1 ? 'color:var(--color-warning,#f59e0b)' : 'color:var(--color-primary)' },
        });
        more.push({ label: '注销', key: 'delete', props: { style: 'color:var(--color-error)' } });
      }
      if (more.length) {
        main.push(
          h(NDropdown, {
            trigger: 'click',
            options: more,
            onSelect: (key: string) => {
              if (key === 'ban') {
                if (row.status === 1) banAdmin(row); else unbanAdmin(row);
                return;
              }
              if (key === 'delete') deleteAdmin(row);
            },
          }, { default: () => h(NButton, { size: 'small', quaternary: true }, { default: () => '更多' }) }),
        );
      }
      if (!main.length) {
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '需 admin:admin:write');
      }
      return h('div', { style: 'display:flex;gap:8px;align-items:center' }, main);
    },
  },
];

const roleColumns = [
  { title: '角色名', key: 'name', width: 160 },
  { title: '标识', key: 'code', width: 140 },
  {
    title: '权限点数', key: 'permissions', width: 100,
    render: (row: RoleRow) => String(row.permissions.length),
  },
  {
    title: '类型', key: 'isBuiltin', width: 100,
    render: (row: RoleRow) => h(NTag, { size: 'small', type: row.isBuiltin ? 'error' : 'default' }, { default: () => (row.isBuiltin ? '内置' : '自定义') }),
  },
  {
    // 列宽和 = 160+140+100+100+140 = 640（⚠️ :scroll-x 必须 ≥ 这个和）
    // 120 → 140：无权限时的提示文案「需 admin:role:write」放得下不折行；fixed:'right' 保证滚动时可见
    title: '操作', key: 'actions', width: 140, fixed: 'right' as const,
    render: (row: RoleRow) => canRole.value && !row.isBuiltin
      ? h(NButton, { size: 'small', onClick: () => openEditRole(row) }, { default: () => '编辑权限' })
      : h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, row.isBuiltin ? '不可修改' : '需 admin:role:write'),
  },
];
</script>

<template>
  <div class="admins-page">
    <n-tabs type="line">
      <n-tab-pane name="admins" tab="管理员">
        <div class="toolbar">
          <p class="hint">创建管理员时请分配角色，角色决定其可用的菜单与操作（权限以服务端强制校验为准）</p>
          <div class="spacer" />
          <n-button v-if="canWrite" type="primary" @click="openCreateAdmin">新建管理员</n-button>
        </div>
        <!-- 列宽和 940；操作列 fixed:'right' —— scroll-x 必须 ≥ 列宽和，否则右侧操作列被裁 -->
        <n-data-table :columns="adminColumns" :data="admins" :loading="loading" :scroll-x="940" />
      </n-tab-pane>
      <n-tab-pane name="roles" tab="角色与权限">
        <div class="toolbar">
          <p class="hint">勾选权限点即授予对应能力；修改角色会使其下所有管理员重新登录</p>
          <div class="spacer" />
          <n-button v-if="canRole" type="primary" @click="openCreateRole">新建角色</n-button>
        </div>
        <!-- 列宽和 640；操作列 fixed:'right' -->
        <n-data-table :columns="roleColumns" :data="roles" :loading="loading" :scroll-x="640" />
      </n-tab-pane>
    </n-tabs>

    <n-modal v-model:show="showAdmin" preset="card" style="width: 520px" :title="editAdminId ? '编辑管理员' : '新建管理员'" positive-text="保存" negative-text="取消" @positive-click="saveAdmin">
      <n-form label-placement="left" label-width="80">
        <n-form-item label="账号"><n-input v-model:value="adminForm.username" :disabled="!!editAdminId" placeholder="登录用户名（创建后不可改）" /></n-form-item>
        <n-form-item v-if="!editAdminId" label="密码"><n-input v-model:value="adminForm.password" type="password" placeholder="至少 8 位" /></n-form-item>
        <n-form-item label="昵称"><n-input v-model:value="adminForm.nickname" placeholder="显示名称" /></n-form-item>
        <n-form-item label="角色">
          <n-select v-model:value="adminForm.roleCode" :options="roleOptions" />
        </n-form-item>
      </n-form>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showAdmin = false">取消</n-button>
          <n-button type="primary" @click="saveAdmin">保存</n-button>
        </div>
      </template>
    </n-modal>

    <n-modal v-model:show="showReset" preset="card" style="width: 460px" :title="`重置密码${resetRow ? ' —— ' + resetRow.username : ''}`" positive-text="确认重置" negative-text="取消" @positive-click="doReset">
      <n-input v-model:value="resetPw" type="password" placeholder="新密码（至少 8 位）" />
      <p class="hint">重置后该管理员所有设备将下线，需用新密码重新登录</p>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showReset = false">取消</n-button>
          <n-button type="primary" @click="doReset">确认重置</n-button>
        </div>
      </template>
    </n-modal>

    <n-modal v-model:show="showRole" preset="card" :title="editRoleId ? `编辑角色权限 —— ${roleForm.name}` : '新建角色'" positive-text="保存" negative-text="取消" style="width: 640px" @positive-click="saveRole">
      <n-form label-placement="left" label-width="80">
        <n-form-item label="标识"><n-input v-model:value="roleForm.code" :disabled="!!editRoleId" placeholder="小写字母数字下划线，如 operator" /></n-form-item>
        <n-form-item label="名称"><n-input v-model:value="roleForm.name" placeholder="角色显示名" /></n-form-item>
        <n-form-item label="权限点">
          <div class="perm-groups">
            <div v-for="g in permGroups" :key="g.group" class="perm-group">
              <div class="perm-group-name">{{ g.group }}</div>
              <n-checkbox-group v-model:value="roleForm.permissions">
                <n-checkbox v-for="p in g.items" :key="p.code" :value="p.code" :label="`${p.name}（${p.code}）`" />
              </n-checkbox-group>
            </div>
          </div>
        </n-form-item>
      </n-form>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showRole = false">取消</n-button>
          <n-button type="primary" @click="saveRole">保存</n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
  align-items: center;
}
.spacer {
  flex: 1;
}
.hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.perm-groups {
  display: flex;
  flex-direction: column;
  gap: 10px;
  max-height: 320px;
  overflow-y: auto;
  width: 100%;
}
.perm-group-name {
  font-size: 12px;
  font-weight: 600;
  color: var(--color-text-secondary);
  margin-bottom: 4px;
}
</style>
