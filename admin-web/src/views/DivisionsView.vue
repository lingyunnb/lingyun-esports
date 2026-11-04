<template>
  <div class="page">
    <n-card :bordered="false" class="head">
      <div class="head-row">
        <div>
          <h2>分部管理</h2>
          <p class="sub">
            分部 = <b>游戏 + 平台</b>。客户端首页「选择分部」、商品筛选、工作端接单大厅、排行榜分部榜全部由此驱动。
            <br />规则：同一游戏只有一个平台时，客户端<b>不显示平台筛选</b>（例如和平精英只有手游，不应出现端游选项）。
            <br /><b>建设中</b>：开启后客户端分部卡显示「建设中」标识，点击进<b>建设中页</b>（展示下方提示文案）而不是商品列表；
            关掉即自动恢复正常 —— <b>客户端无需改代码</b>。
          </p>
        </div>
        <n-button type="primary" @click="openCreate">新增分部</n-button>
      </div>
    </n-card>

    <n-card :bordered="false" class="body">
      <n-data-table :columns="columns" :data="rows" :loading="loading" :bordered="false" size="small" :scroll-x="1090" />
    </n-card>

    <n-modal v-model:show="showEdit" preset="card" :title="editing ? '编辑分部' : '新增分部'" style="width: 620px">
      <n-form :model="form" label-placement="left" label-width="96">
        <n-form-item label="所属游戏">
          <n-select v-model:value="form.gameId" :options="gameOptions" placeholder="选择游戏" />
        </n-form-item>
        <n-form-item label="平台">
          <n-select v-model:value="form.platform" :options="platformOptions" />
        </n-form-item>
        <n-form-item label="标识 code">
          <n-input v-model:value="form.code" placeholder="如 peace_mobile / delta_pc（唯一）" />
        </n-form-item>
        <n-form-item label="展示名">
          <n-input v-model:value="form.name" placeholder="如 和平精英 · 手游" />
        </n-form-item>
        <n-form-item label="分部简称">
          <n-input v-model:value="form.shortName" placeholder="如 和平精英（分部卡主标题）" />
        </n-form-item>
        <n-form-item label="平台标签">
          <n-input v-model:value="form.platformLabel" placeholder="如 手游 / 端游" />
        </n-form-item>
        <n-form-item label="在线说明">
          <n-input v-model:value="form.onlineDesc" placeholder="如 平均 3 分钟内接单" />
        </n-form-item>
        <n-form-item label="价格说明">
          <n-input v-model:value="form.priceNote" placeholder="如 按局计费，下单后显示明细" />
        </n-form-item>
        <n-form-item label="专区圆形图">
          <MediaUploadField v-model="iconModel" media-type="division_icon" style="width: 100%" />
        </n-form-item>
        <n-form-item label="卡片封面图">
          <MediaUploadField v-model="coverModel" media-type="division_cover" style="width: 100%" />
        </n-form-item>
        <n-form-item label="副标题"><n-input v-model:value="form.subTitle" placeholder="平均 3 分钟内接单" /></n-form-item>
        <n-form-item label="主题色">
          <n-input v-model:value="form.themeColor" placeholder="#16A34A（留空则客户端按序取默认色）" />
        </n-form-item>
        <n-form-item label="排序">
          <n-input-number v-model:value="form.sortOrder" :min="0" :max="9999" />
        </n-form-item>
        <n-form-item label="状态">
          <n-select v-model:value="form.status" :options="statusOptions" />
        </n-form-item>
        <n-form-item label="建设中">
          <div class="switch-row">
            <n-switch v-model:value="form.underConstruction" :checked-value="1" :unchecked-value="0" />
            <span class="hint">开启后：客户端分部卡显示「建设中」标识，点击进<b>建设中页</b>而不是商品列表；关掉即自动恢复正常。</span>
          </div>
        </n-form-item>
        <n-form-item label="提示文案">
          <n-input
            v-model:value="form.noticeText"
            type="textarea"
            :rows="3"
            maxlength="255"
            show-count
            placeholder="建设中页面展示的文案，可换行（例如：本分部正在建设中，敬请期待。&#10;本分部大力招人，有意者请联系本人 QQ：3989032755）"
          />
        </n-form-item>
      </n-form>
      <p class="foot-hint">
        提示文案由<b>服务端下发</b>给老板端建设中页（客户端不写死任何文案/QQ 号）；留空时客户端显示兜底文案「该分部正在建设中，敬请期待」。
      </p>
      <template #footer>
        <div class="foot">
          <n-button @click="showEdit = false">取消</n-button>
          <n-button type="primary" :loading="saving" @click="save">保存</n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>

<script setup lang="ts">
import { ApiException, request } from '@/api/client';
import MediaUploadField from '@/components/MediaUploadField.vue';
import { NButton, NCard, NDataTable, NForm, NFormItem, NInput, NInputNumber, NModal, NSelect, NSwitch, NTag, useDialog, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface DivisionRow {
  iconMediaId?: string | null;
  coverMediaId?: string | null;
  subTitle?: string;
  /** 1 = 建设中（客户端显示「建设中」标识并进建设中页）/ 0 = 正常（负责人 2026-10-05） */
  underConstruction?: number;
  /** 建设中页提示文案（服务端下发，可含换行与 QQ 号） */
  noticeText?: string;
  id: string;
  gameId: string;
  gameName?: string;
  platform: string;
  code: string;
  name: string;
  shortName: string;
  platformLabel: string;
  onlineDesc: string;
  priceNote: string;
  themeColor: string;
  sortOrder: number;
  status?: number;
}

const message = useMessage();
const dialog = useDialog();
const loading = ref(false);
const saving = ref(false);
const showEdit = ref(false);
const editing = ref(false);
const rows = ref<DivisionRow[]>([]);
const gameOptions = ref<{ label: string; value: string }[]>([]);

const platformOptions = [
  { label: '手游', value: 'mobile' },
  { label: '端游', value: 'pc' },
];
const statusOptions = [
  { label: '上架', value: 1 },
  { label: '下架', value: 0 },
];

const form = reactive<DivisionRow>({
  id: '',
  gameId: '',
  platform: 'mobile',
  code: '',
  name: '',
  shortName: '',
  platformLabel: '手游',
  onlineDesc: '',
  priceNote: '',
  themeColor: '',
  sortOrder: 0,
  status: 1,
  underConstruction: 0,
  noticeText: '',
});
const iconModel = computed<string | null>({
  get: () => form.iconMediaId ?? null,
  set: (v) => {
    form.iconMediaId = v;
  },
});
const coverModel = computed<string | null>({
  get: () => form.coverMediaId ?? null,
  set: (v) => {
    form.coverMediaId = v;
  },
});


const columns = [
  { title: 'ID', key: 'id', width: 60 },
  {
    title: '分部',
    key: 'name',
    render: (r: DivisionRow) =>
      h('div', [
        h('b', r.name || r.shortName),
        h('div', { style: 'font-size:12px;color:#94a3b8' }, `${r.gameName ?? ''} · ${r.platformLabel || (r.platform === 'pc' ? '端游' : '手游')}`),
      ]),
  },
  { title: '标识', key: 'code', width: 140 },
  {
    title: '平台',
    key: 'platform',
    width: 90,
    render: (r: DivisionRow) =>
      h(NTag, { type: r.platform === 'pc' ? 'warning' : 'info', size: 'small' }, { default: () => r.platformLabel || r.platform }),
  },
  {
    title: '主题色',
    key: 'themeColor',
    width: 110,
    render: (r: DivisionRow) =>
      h('div', { style: 'display:flex;align-items:center;gap:6px' }, [
        h('span', { style: `width:14px;height:14px;border-radius:4px;background:${r.themeColor || '#1D5FA8'}` }),
        h('span', { style: 'font-size:12px' }, r.themeColor || '默认'),
      ]),
  },
  { title: '在线说明', key: 'onlineDesc', width: 150 },
  { title: '排序', key: 'sortOrder', width: 70 },
  {
    title: '状态',
    key: 'status',
    width: 140,
    render: (r: DivisionRow) =>
      h('div', { style: 'display:flex;gap:6px;align-items:center;flex-wrap:wrap' }, [
        h(NTag, { type: r.status === 0 ? 'default' : 'success', size: 'small' }, { default: () => (r.status === 0 ? '下架' : '上架') }),
        // 建设中（负责人 2026-10-05）：列表里必须一眼看出哪些分部还没上架商品 —— 用描边小片，不用彩色填充
        Number(r.underConstruction ?? 0) === 1
          ? h(NTag, { size: 'small', bordered: true }, { default: () => '建设中' })
          : null,
      ]),
  },
  {
    // 列宽和 = 60+140+90+110+150+70+140+150 = 910（+「分部」弹性列 180）→ 模板 :scroll-x = 1090
    // fixed:'right'：横向滚动时「编辑/删除」始终完整可见
    title: '操作',
    key: 'actions',
    width: 150,
    fixed: 'right' as const,
    render: (r: DivisionRow) =>
      h('div', { style: 'display:flex;gap:8px' }, [
        h(NButton, { size: 'tiny', onClick: () => openEdit(r) }, { default: () => '编辑' }),
        h(
          NButton,
          { size: 'tiny', type: 'error', quaternary: true, onClick: () => remove(r) },
          { default: () => '删除' },
        ),
      ]),
  },
];

async function load() {
  loading.value = true;
  try {
    const data = await request<DivisionRow[]>('GET', '/admin/divisions');
    rows.value = Array.isArray(data) ? data : [];
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

async function loadGames() {
  try {
    const games = await request<{ id: string; name: string }[]>('GET', '/admin/games');
    gameOptions.value = (games ?? []).map((g) => ({ label: g.name, value: `${g.id}` }));
  } catch {
    gameOptions.value = [];
  }
}

function openCreate() {
  editing.value = false;
  Object.assign(form, {
    id: '',
    gameId: gameOptions.value[0]?.value ?? '',
    platform: 'mobile',
    code: '',
    name: '',
    shortName: '',
    platformLabel: '手游',
    onlineDesc: '',
    priceNote: '',
    themeColor: '',
    sortOrder: rows.value.length * 10 + 10,
    status: 1,
    underConstruction: 0,
    noticeText: '',
  });
  showEdit.value = true;
}

function openEdit(r: DivisionRow) {
  editing.value = true;
  Object.assign(form, {
    ...r,
    status: r.status ?? 1,
    // 服务端下发 true/false（公开接口）或 0/1（管理端列表）→ 统一收成 0/1 给 n-switch
    underConstruction: Number(r.underConstruction ?? 0) === 1 ? 1 : 0,
    noticeText: r.noticeText ?? '',
  });
  showEdit.value = true;
}

/**
 * 只提交「可写字段」（负责人 2026-10-04 报障修复）：
 * 列表接口 /admin/divisions 会回带只读/计算字段（gameName / onlineCount 等），
 * 以前用 `{ ...form }` 把整对象回传 → 服务端白名单校验 400
 * `property gameName should not exist; property onlineCount should not exist`。
 * 现在显式构造 payload，id 只出现在 URL 里，绝不进 body。
 *
 * 2026-10-05：新增 underConstruction（**统一发 0/1**，服务端 DTO 按 @IsIn([0,1]) 校验）与 noticeText。
 * `noticeText` 必须发（空串 = 清空文案），否则管理端删掉文案后服务端会保留旧值。
 */
function buildPayload() {
  return {
    gameId: form.gameId,
    platform: form.platform,
    code: form.code,
    name: form.name,
    shortName: form.shortName,
    platformLabel: form.platformLabel,
    onlineDesc: form.onlineDesc,
    priceNote: form.priceNote,
    themeColor: form.themeColor,
    iconMediaId: form.iconMediaId ?? null,
    coverMediaId: form.coverMediaId ?? null,
    subTitle: form.subTitle ?? '',
    sortOrder: form.sortOrder,
    status: form.status,
    underConstruction: Number(form.underConstruction ?? 0) === 1 ? 1 : 0,
    noticeText: form.noticeText ?? '',
  };
}

async function save() {
  if (!form.gameId || !form.code || !form.name) {
    message.warning('所属游戏、标识 code、展示名为必填');
    return;
  }
  saving.value = true;
  try {
    if (editing.value) {
      await request('PUT', `/admin/divisions/${form.id}`, buildPayload());
    } else {
      await request('POST', '/admin/divisions', buildPayload());
    }
    message.success('已保存');
    showEdit.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

function remove(r: DivisionRow) {
  dialog.warning({
    title: '删除分部',
    content: `确认删除「${r.name}」？该分部下已有商品或订单时会被拒绝，请改用下架。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        const res = await request<{ ok: boolean; message?: string }>('DELETE', `/admin/divisions/${r.id}`);
        if (res && res.ok === false) {
          message.warning(res.message ?? '删除被拒绝');
        } else {
          message.success('已删除');
        }
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

onMounted(async () => {
  await loadGames();
  await load();
});
</script>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.head-row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
}
h2 {
  margin: 0 0 6px;
  font-size: 18px;
}
.sub {
  margin: 0;
  color: #64748b;
  font-size: 13px;
  line-height: 1.8;
}
.foot {
  display: flex;
  justify-content: flex-end;
  gap: 10px;
}
.switch-row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.hint {
  color: #94a3b8;
  font-size: 12px;
  line-height: 1.6;
}
.foot-hint {
  margin: 4px 0 0;
  color: #94a3b8;
  font-size: 12px;
  line-height: 1.7;
}
</style>
