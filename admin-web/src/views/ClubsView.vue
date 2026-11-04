<template>
  <div style="padding: 16px">
    <n-card title="官方馆管理" size="small">
      <template #header-extra>
        <n-button size="small" type="primary" @click="openCreate">新建官方馆</n-button>
        <n-button size="small" style="margin-left: 8px" @click="load">刷新</n-button>
      </template>
      <n-data-table :columns="columns" :data="rows" :loading="loading" :bordered="false" size="small" :scroll-x="910" />
    </n-card>

    <n-modal v-model:show="show" preset="card" style="width: 560px" :title="form.id ? '编辑官方馆' : '新建官方馆'">
      <n-form label-placement="left" label-width="90">
        <n-form-item label="名称"><n-input v-model:value="form.name" placeholder="祁连山电竞 · 和平精英分部" /></n-form-item>
        <n-form-item label="副标题"><n-input v-model:value="form.subTitle" placeholder="和平精英分部" /></n-form-item>
        <n-form-item label="简介"><n-input v-model:value="form.description" type="textarea" :rows="2" /></n-form-item>
        <n-form-item label="封面图">
          <MediaUploadField v-model="coverModel" media-type="club_cover" style="width: 100%" />
        </n-form-item>
        <n-form-item label="角标"><n-input v-model:value="form.badge" placeholder="官方" /></n-form-item>
        <n-form-item label="评分"><n-input v-model:value="form.rating" placeholder="4.9" /></n-form-item>
        <n-form-item label="单量"><n-input-number v-model:value="form.orderCount" :min="0" /></n-form-item>
        <n-form-item label="排序"><n-input-number v-model:value="form.sortOrder" :min="0" /></n-form-item>
        <n-form-item label="状态">
          <n-radio-group v-model:value="form.status">
            <n-radio :value="1">上架</n-radio>
            <n-radio :value="2">下架</n-radio>
          </n-radio-group>
        </n-form-item>
      </n-form>
      <template #footer>
        <n-button @click="show = false">取消</n-button>
        <n-button type="primary" style="margin-left: 8px" :loading="saving" @click="save">保存</n-button>
      </template>
    </n-modal>
  </div>
</template>

<script setup lang="ts">
import { computed, h, onMounted, reactive, ref } from 'vue';
import { NButton, NCard, NDataTable, NForm, NFormItem, NInput, NInputNumber, NModal, NRadio, NRadioGroup, NTag, useDialog, useMessage } from 'naive-ui';
import type { DataTableColumns } from 'naive-ui';
import { ApiException, request } from '@/api/client';
import MediaUploadField from '@/components/MediaUploadField.vue';

interface ClubRow {
  id: string;
  name: string;
  subTitle: string;
  description: string;
  coverMediaId: string | null;
  badge: string;
  rating: string;
  orderCount: number;
  divisionId: string | null;
  sortOrder: number;
  status?: number;
}

const message = useMessage();
const dialog = useDialog();
const rows = ref<ClubRow[]>([]);
const loading = ref(false);
const saving = ref(false);
const show = ref(false);
// MediaUploadField 的 v-model 类型为 string|null（undefined 会触发类型错误）
const coverModel = computed<string | null>({
  get: () => form.coverMediaId ?? null,
  set: (v) => {
    form.coverMediaId = v;
  },
});
const form = reactive<Partial<ClubRow>>({ status: 1, orderCount: 0, sortOrder: 0, rating: '4.9', badge: '官方' });

const columns: DataTableColumns<ClubRow> = [
  { title: 'ID', key: 'id', width: 70 },
  { title: '名称', key: 'name' },
  { title: '副标题', key: 'subTitle', width: 140 },
  { title: '封面', key: 'coverMediaId', width: 80, render: (r) => (r.coverMediaId ? '已设置' : '—') },
  { title: '评分', key: 'rating', width: 70 },
  { title: '单量', key: 'orderCount', width: 80 },
  { title: '排序', key: 'sortOrder', width: 70 },
  { title: '状态', key: 'status', width: 80, render: (r) => h(NTag, { type: r.status === 1 ? 'success' : 'default', size: 'small' }, { default: () => (r.status === 1 ? '上架' : '下架') }) },
  {
    // 列宽和 = 70+140+80+70+80+70+80+140 = 730（+「名称」弹性列 180）→ 模板 :scroll-x = 910
    // fixed:'right'：横向滚动时「编辑/删除」始终完整可见
    title: '操作',
    key: 'actions',
    width: 140,
    fixed: 'right',
    render: (r) => [
      h(NButton, { size: 'tiny', onClick: () => openEdit(r) }, { default: () => '编辑' }),
      h(NButton, { size: 'tiny', type: 'error', style: 'margin-left: 6px', onClick: () => remove(r) }, { default: () => '删除' }),
    ],
  },
];

async function load() {
  loading.value = true;
  try {
    rows.value = await request<ClubRow[]>('GET', '/admin/clubs');
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

function openCreate() {
  // divisionId 必须一起重置：否则新建时会带上「上一次编辑」的分部（列表回显残留）
  Object.assign(form, { id: undefined, name: '', subTitle: '', description: '', coverMediaId: null, badge: '官方', rating: '4.9', orderCount: 0, divisionId: null, sortOrder: 0, status: 1 });
  show.value = true;
}

function openEdit(r: ClubRow) {
  Object.assign(form, { ...r, coverMediaId: r.coverMediaId ?? null });
  show.value = true;
}

/**
 * 只提交「可写字段」（负责人 2026-10-04 报障修复）：
 * 以前 `{ ...form }` 会把列表回带的 `id`（以及任何回显字段）塞进 body，
 * 服务端白名单校验直接 400 `property id should not exist` → 简介/副标题都存不进去。
 * 现在显式构造 payload，id 只出现在 URL 里。
 */
function buildPayload() {
  return {
    name: form.name ?? '',
    subTitle: form.subTitle ?? '',
    description: form.description ?? '',
    coverMediaId: form.coverMediaId ?? null,
    badge: form.badge ?? '官方',
    rating: form.rating ?? '5.0',
    orderCount: form.orderCount ?? 0,
    divisionId: form.divisionId ?? null,
    sortOrder: form.sortOrder ?? 0,
    status: form.status ?? 1,
  };
}

async function save() {
  saving.value = true;
  try {
    if (form.id) await request('PUT', `/admin/clubs/${form.id}`, buildPayload());
    else await request('POST', '/admin/clubs', buildPayload());
    message.success('已保存');
    show.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

function remove(r: ClubRow) {
  dialog.warning({
    title: '删除官方馆',
    content: `确认删除「${r.name}」？客户端首页将不再显示。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/clubs/${r.id}`);
        message.success('已删除');
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

onMounted(load);
</script>
