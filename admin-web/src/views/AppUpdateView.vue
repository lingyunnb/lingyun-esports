<script setup lang="ts">
// 老板端版本更新管理（负责人云端更新需求）：上传 APK（版本号/版本名/更新说明/是否强制/最低支持版本）
// + 历史版本列表（大小/哈希/下载地址/上传人/状态），支持启用/停用（无删除：保护使用中的版本）
import { ApiException, request } from '@/api/client';
import { getToken } from '@/api/client';
import {
  NButton, NDataTable, NInput, NInputNumber, NModal, NRadioButton, NRadioGroup, NSwitch, NTag, useMessage,
} from 'naive-ui';
import { computed, h, onMounted, ref } from 'vue';

interface VersionRow {
  id: string;
  appType: string;
  versionCode: number;
  versionName: string;
  updateDesc: string;
  forceUpdate: number;
  minSupportedVersion: number;
  fileName: string;
  fileSize: string;
  fileHash: string;
  status: number;
  uploader: string;
  createdAt: string;
}

const message = useMessage();
const loading = ref(false);
// 应用类型：老板端（boss）/ 工作端（worker）各自的版本通道，互不影响
const appType = ref<'boss' | 'worker'>('boss');
const appLabel = computed(() => (appType.value === 'boss' ? '老板端' : '工作端'));
const rows = ref<VersionRow[]>([]);
const showUpload = ref(false);
const uploading = ref(false);
const fileRef = ref<HTMLInputElement | null>(null);
const form = ref({
  file: null as File | null,
  versionCode: null as number | null,
  versionName: '',
  updateDesc: '',
  forceUpdate: false,
  minSupportedVersion: 1,
});

function fmtSize(n: number | string): string {
  const v = Number(n);
  if (v >= 1024 * 1024 * 1024) return (v / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  if (v >= 1024 * 1024) return (v / 1024 / 1024).toFixed(2) + ' MB';
  return Math.round(v / 1024) + ' KB';
}

async function load() {
  loading.value = true;
  try {
    const data = await request<{ list: VersionRow[] }>('GET', `/admin/app-versions?appType=${appType.value}`);
    rows.value = data.list;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(load);

function onPickFile(e: Event) {
  const input = e.target as HTMLInputElement;
  form.value.file = input.files?.[0] ?? null;
}

async function handleUpload() {
  const f = form.value;
  if (!f.file) { message.warning('请选择 APK 文件'); return; }
  if (!f.versionCode || f.versionCode < 1) { message.warning('请填写正确的版本号（正整数，必须大于线上当前版本）'); return; }
  if (!f.versionName.trim()) { message.warning('请填写版本名称'); return; }
  uploading.value = true;
  try {
    const fd = new FormData();
    fd.append('file', f.file);
    fd.append('appType', appType.value);
    fd.append('versionCode', String(f.versionCode));
    fd.append('versionName', f.versionName.trim());
    fd.append('updateDesc', f.updateDesc.trim());
    fd.append('forceUpdate', f.forceUpdate ? 'true' : 'false');
    fd.append('minSupportedVersion', String(f.minSupportedVersion ?? 1));
    const resp = await fetch('/api/v1/admin/app-versions/upload', {
      method: 'POST',
      headers: { Authorization: `Bearer ${getToken()}` },
      body: fd,
    });
    const json = await resp.json();
    if (json.code !== 0) throw new ApiException(json.code, json.message, json.requestId);
    message.success(`版本 v${f.versionName}（${f.versionCode}）已上传，${appLabel.value}将收到更新提示`);
    showUpload.value = false;
    form.value = { file: null, versionCode: null, versionName: '', updateDesc: '', forceUpdate: false, minSupportedVersion: 1 };
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '上传失败');
  } finally {
    uploading.value = false;
  }
}

async function toggleStatus(row: VersionRow, enable: boolean) {
  try {
    await request('POST', `/admin/app-versions/${row.id}/status`, { status: enable ? 1 : 2 });
    message.success(enable ? '已启用' : '已停用（客户端不再提示该版本）');
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

const columns = computed(() => [
  { title: '版本号', key: 'versionCode', width: 90, render: (r: VersionRow) => `${r.versionCode}（v${r.versionName}）` },
  { title: '更新说明', key: 'updateDesc', ellipsis: { tooltip: true }, render: (r: VersionRow) => r.updateDesc },
  {
    title: '类型', key: 'forceUpdate', width: 90,
    render: (r: VersionRow) => h(NTag, { size: 'small', type: r.forceUpdate === 1 ? 'error' : 'default' }, { default: () => (r.forceUpdate === 1 ? '强制更新' : '普通更新') }),
  },
  { title: '大小', key: 'fileSize', width: 100, render: (r: VersionRow) => fmtSize(r.fileSize) },
  { title: '文件名', key: 'fileName', width: 160, ellipsis: { tooltip: true } },
  { title: 'SHA256', key: 'fileHash', width: 130, render: (r: VersionRow) => `${r.fileHash.slice(0, 12)}…` },
  {
    title: '状态', key: 'status', width: 80,
    render: (r: VersionRow) => h(NTag, { size: 'small', type: r.status === 1 ? 'success' : 'default' }, { default: () => (r.status === 1 ? '启用中' : '已停用') }),
  },
  { title: '上传人', key: 'uploader', width: 110 },
  { title: '上传时间', key: 'createdAt', width: 170, render: (r: VersionRow) => new Date(r.createdAt).toLocaleString('zh-CN', { hour12: false }) },
  {
    // 列宽和 = 90+90+100+160+130+80+110+170+90 = 1020（+「更新说明」弹性列 220）→ 模板 :scroll-x = 1240
    // fixed:'right'：横向滚动时「停用/启用」始终完整可见
    title: '操作', key: 'actions', width: 90, fixed: 'right' as const,
    render: (r: VersionRow) =>
      r.status === 1
        ? h(NButton, { size: 'small', quaternary: true, type: 'warning', onClick: () => toggleStatus(r, false) }, { default: () => '停用' })
        : h(NButton, { size: 'small', quaternary: true, type: 'success', onClick: () => toggleStatus(r, true) }, { default: () => '启用' }),
  },
]);
</script>

<template>
  <div class="app-update-page">
    <div class="toolbar">
      <n-radio-group v-model:value="appType" size="small" @update:value="load">
        <n-radio-button value="boss">老板端</n-radio-button>
        <n-radio-button value="worker">工作端</n-radio-button>
      </n-radio-group>
      <div class="hint-block">
        上传新的 APK 后，{{ appLabel }}启动时会自动检测并提示更新；<b>强制更新</b>会阻止用户继续使用直到完成更新。
        两端版本通道相互独立（工作端只会收到工作端安装包）。
      </div>
      <div class="spacer" />
      <n-button type="primary" @click="showUpload = true">上传新版本</n-button>
    </div>

    <n-data-table :columns="columns" :data="rows" :loading="loading" :pagination="{ pageSize: 10 }" :scroll-x="1240" />

    <n-modal v-model:show="showUpload" preset="card" :title="`上传${appLabel}新版本`" style="width: 560px" :bordered="false">
      <div class="form">
        <div class="form-row">
          <span class="label">APK 文件</span>
          <input ref="fileRef" type="file" accept=".apk,application/vnd.android.package-archive" @change="onPickFile" />
          <span v-if="form.file" class="file-name">{{ form.file.name }}（{{ fmtSize(form.file.size) }}）</span>
        </div>
        <div class="form-row">
          <span class="label">版本号</span>
          <n-input-number v-model:value="form.versionCode" :min="1" placeholder="整数，如 2（必须大于当前线上版本）" style="width: 100%" />
        </div>
        <div class="form-row">
          <span class="label">版本名称</span>
          <n-input v-model:value="form.versionName" placeholder="如 1.0.1" />
        </div>
        <div class="form-row">
          <span class="label">更新说明</span>
          <n-input v-model:value="form.updateDesc" type="textarea" :rows="3" :placeholder="`本次更新的内容，将展示在${appLabel}更新弹窗中`" />
        </div>
        <div class="form-row">
          <span class="label">强制更新</span>
          <n-switch v-model:value="form.forceUpdate" />
          <span class="sub">开启后{{ appLabel }}必须完成更新才能继续使用</span>
        </div>
        <div class="form-row">
          <span class="label">最低支持版本</span>
          <n-input-number v-model:value="form.minSupportedVersion" :min="1" style="width: 140px" />
          <span class="sub">预留字段</span>
        </div>
      </div>
      <template #footer>
        <div class="footer">
          <n-button @click="showUpload = false">取消</n-button>
          <n-button type="primary" :loading="uploading" @click="handleUpload">上传并发布</n-button>
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
.hint-block {
  font-size: 12.5px;
  color: var(--color-text-secondary);
}
.spacer {
  flex: 1;
}
.form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.form-row {
  display: flex;
  align-items: center;
  gap: 12px;
}
.label {
  width: 96px;
  flex-shrink: 0;
  font-size: 13px;
  color: var(--color-text-secondary);
}
.file-name {
  font-size: 12px;
  color: var(--color-primary-text);
}
.sub {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.footer {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
}
</style>
