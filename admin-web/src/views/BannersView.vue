<template>
  <div style="padding: 16px">
    <n-card title="宣传图管理" size="small">
      <template #header-extra>
        <n-button size="small" type="primary" @click="openCreate">新建宣传图</n-button>
        <n-button size="small" style="margin-left: 8px" @click="load">刷新</n-button>
      </template>

      <!--
        空态提示（任务②硬要求）：明确告诉运营"首页将不显示轮播位"，
        避免以为"保存失败/页面坏了"—— 客户端此时是零占位，首页看不出任何异常。
      -->
      <n-alert v-if="!loading && rows.length === 0" type="info" :bordered="false" style="margin-bottom: 12px">
        还没有宣传图，首页将不显示轮播位。
      </n-alert>

      <n-data-table :columns="columns" :data="rows" :loading="loading" :bordered="false" size="small" :scroll-x="1130" />
    </n-card>

    <n-modal v-model:show="show" preset="card" style="width: 640px" :title="form.id ? '编辑宣传图' : '新建宣传图'">
      <n-form label-placement="left" label-width="96">
        <n-form-item label="图片">
          <div style="width: 100%">
            <MediaUploadField v-model="imageModel" media-type="banner" />
            <!-- 建议尺寸：首页通栏比例 2.5:1（方案 C），给 2.2:1 的宽容区间，宽 ≥1080 保证高清屏不糊 -->
            <div style="font-size: 12px; color: var(--color-text-tertiary); margin-top: 6px; line-height: 1.6">
              建议尺寸 2.2:1、宽 ≥1080（首页通栏按 2.5:1 裁切，图片主体请靠左中放置，底部会压一条文字遮罩）
            </div>
          </div>
        </n-form-item>
        <n-form-item label="标题">
          <n-input v-model:value="form.title" maxlength="64" show-count placeholder="周末双排护航 8 折" />
        </n-form-item>
        <n-form-item label="副标题">
          <n-input v-model:value="form.subtitle" maxlength="64" show-count placeholder="10/05-10/07 · 全分部可用（留空则不显示）" />
        </n-form-item>
        <n-form-item label="跳转类型">
          <n-radio-group v-model:value="form.linkType">
            <n-radio v-for="o in LINK_OPTIONS" :key="o.value" :value="o.value">{{ o.label }}</n-radio>
          </n-radio-group>
        </n-form-item>
        <n-form-item v-if="needsValue" label="跳转目标">
          <n-input v-model:value="linkValueModel" :placeholder="linkPlaceholder" />
          <template #feedback>
            <span style="font-size: 12px; color: var(--color-text-tertiary)">{{ linkHint }}</span>
          </template>
        </n-form-item>
        <n-form-item label="排序">
          <n-input-number v-model:value="form.sortOrder" :min="0" style="width: 160px" />
          <span style="margin-left: 8px; font-size: 12px; color: var(--color-text-tertiary)">数字小的排前面</span>
        </n-form-item>
        <n-form-item label="投放时间">
          <n-date-picker
            v-model:value="range"
            type="datetimerange"
            clearable
            style="width: 100%"
            start-placeholder="开始时间（留空=不限制）"
            end-placeholder="结束时间（留空=不限制）"
          />
          <template #feedback>
            <span style="font-size: 12px; color: var(--color-text-tertiary)">
              留空 = 不限制；到时间自动生效/失效，无需手动上下架
            </span>
          </template>
        </n-form-item>
        <n-form-item label="状态">
          <n-radio-group v-model:value="form.visible">
            <n-radio :value="1">显示</n-radio>
            <n-radio :value="2">隐藏</n-radio>
          </n-radio-group>
          <span style="margin-left: 8px; font-size: 12px; color: var(--color-text-tertiary)">隐藏后首页立即不再显示</span>
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
/**
 * 宣传图管理（负责人 2026-10-05 任务② 方案 C「顶部通栏沉浸」）
 *
 * 数据面：复用既有 `home_banner` 表（**不新建表**），四个既有接口去掉 @deprecated 后继续用：
 * `GET/POST /admin/home/banners`、`PUT/DELETE /admin/home/banners/:id`（权限点 admin:home:write）。
 * 公开侧新增 `GET /public/banners`（只返回 visible=1 且在投放时间区间内），App 首页轮播消费。
 *
 * ## 三个"真实坑"在本页的落点（逐条对得上）
 * 1. **`visible` 是 1 显示 / 2 隐藏，不是 0/1** —— 表单用 `n-radio` 固定 1/2 两个值，
 *    默认 1；列表标签判 `=== 1 ? '显示' : '隐藏'`，绝不出现 0。
 * 2. **`image_url` 是 NOT NULL 且原无默认值** —— 本页上传通道只回填 `imageMediaId`，
 *    历史上这种"只传 media id"的新建会被 MySQL 拒（`ER_NO_DEFAULT_FOR_FIELD`）。
 *    服务端已给该列补 `DEFAULT ''`（migration 1798000000000），并在 `createBanner` 里显式兜空串；
 *    本页**不再提交** `imageUrl` 字段（提交了反而会把历史外链覆盖成空串时产生歧义）。
 * 3. **`linkType` 枚举扩了 `division` / `announcement`** —— 下面的 [LINK_OPTIONS] 就是新枚举；
 *    历史的 `tab` 值不在选项里（服务端白名单仍接受以兼容存量数据，客户端不认它），
 *    若某条老数据是 `tab`，列表里会显示成"无跳转"并在编辑时自动落到 `none`。
 */
import { computed, h, onMounted, reactive, ref } from 'vue';
import {
  NAlert,
  NButton,
  NCard,
  NDataTable,
  NDatePicker,
  NForm,
  NFormItem,
  NImage,
  NInput,
  NInputNumber,
  NModal,
  NRadio,
  NRadioGroup,
  NTag,
  useDialog,
  useMessage,
} from 'naive-ui';
import type { DataTableColumns } from 'naive-ui';
import { ApiException, mediaPreviewPath, request } from '@/api/client';
import MediaUploadField from '@/components/MediaUploadField.vue';

/** 跳转类型（与后端 DTO 白名单逐字对应；`tab` 是历史值，不再作为可选项） */
const LINK_OPTIONS = [
  { value: 'none', label: '无跳转' },
  { value: 'product', label: '商品' },
  { value: 'division', label: '分部' },
  { value: 'announcement', label: '公告' },
  { value: 'url', label: '外链' },
] as const;

interface BannerRow {
  id: string;
  title: string;
  subtitle: string;
  imageMediaId: string | null;
  imageUrl: string;
  linkType: string;
  linkValue: string;
  sortOrder: number;
  visible: number;
  startAt: string | null;
  endAt: string | null;
}

const message = useMessage();
const dialog = useDialog();
const rows = ref<BannerRow[]>([]);
const loading = ref(false);
const saving = ref(false);
const show = ref(false);

const form = reactive<Partial<BannerRow>>({ visible: 1, sortOrder: 0, linkType: 'none' });

/** 投放时间（naive-ui 的 datetimerange 是 [开始毫秒, 结束毫秒]，null = 清空） */
const range = ref<[number, number] | null>(null);

/** MediaUploadField 的 v-model 类型是 string|null（undefined 会触发类型错误） */
const imageModel = computed<string | null>({
  get: () => form.imageMediaId ?? null,
  set: (v) => {
    form.imageMediaId = v;
  },
});

/** 跳转目标：linkType=none 时该字段整体隐藏，但值要保留（切回来不丢） */
const needsValue = computed(() => (form.linkType ?? 'none') !== 'none');
const linkValueModel = computed<string>({
  get: () => form.linkValue ?? '',
  set: (v) => {
    form.linkValue = v;
  },
});

const linkPlaceholder = computed(() => {
  switch (form.linkType) {
    case 'product':
      return '商品 ID（在「游戏与商品」列表里的 ID 列）';
    case 'division':
      return '分部 ID（在「分部管理」列表里的 ID 列）';
    case 'announcement':
      return '公告 ID（在「公告管理」列表里的 ID 列）';
    case 'url':
      return 'https://…（App 内暂不直接打开外链，会提示用户复制到浏览器）';
    default:
      return '';
  }
});

const linkHint = computed(() => (form.linkType === 'url' ? '外链暂不在 App 内打开（未引入 url_launcher 依赖）' : '填对应列表里的数字 ID'));

const columns: DataTableColumns<BannerRow> = [
  {
    title: '图片',
    key: 'imageMediaId',
    width: 120,
    render: (r) => {
      const src = r.imageMediaId ? mediaPreviewPath(r.imageMediaId) : r.imageUrl || null;
      // 缩略图按 2.5:1（首页通栏比例）预览，运营一眼能看出裁切后剩多少
      return src
        ? h(NImage, { src, width: 96, height: 38, objectFit: 'cover', style: 'border-radius:4px' })
        : h('span', { style: 'color:var(--color-text-tertiary)' }, '未配图');
    },
  },
  {
    title: '标题 / 副标题',
    key: 'title',
    minWidth: 220,
    render: (r) => [
      h('div', { style: 'font-weight:600' }, r.title || '（无标题）'),
      r.subtitle ? h('div', { style: 'font-size:12px;color:var(--color-text-tertiary)' }, r.subtitle) : null,
    ],
  },
  { title: '跳转', key: 'linkType', width: 150, render: (r) => linkLabel(r) },
  { title: '排序', key: 'sortOrder', width: 70 },
  {
    title: '投放时间',
    key: 'startAt',
    width: 220,
    render: (r) => h('span', { style: 'font-size:12px' }, timeRangeLabel(r)),
  },
  {
    title: '状态',
    key: 'visible',
    width: 150,
    render: (r) =>
      h(
        NTag,
        { type: r.visible === 1 ? 'success' : 'default', size: 'small' },
        { default: () => (r.visible === 1 ? '显示' : '隐藏') },
      ),
  },
  {
    // 列宽和 = 120+220+150+70+220+150+200 = 1130 → 模板 :scroll-x = 1130
    // fixed:'right'：横向滚动时「编辑/下架/删除」始终完整可见
    title: '操作',
    key: 'actions',
    width: 200,
    fixed: 'right',
    render: (r) => [
      h(NButton, { size: 'tiny', onClick: () => openEdit(r) }, { default: () => '编辑' }),
      h(
        NButton,
        { size: 'tiny', style: 'margin-left:6px', onClick: () => toggleVisible(r) },
        { default: () => (r.visible === 1 ? '下架' : '上架') },
      ),
      h(
        NButton,
        { size: 'tiny', type: 'error', style: 'margin-left:6px', onClick: () => remove(r) },
        { default: () => '删除' },
      ),
    ],
  },
];

function linkLabel(r: BannerRow): string {
  const opt = LINK_OPTIONS.find((o) => o.value === r.linkType);
  if (!opt || opt.value === 'none') return '无跳转';
  return `${opt.label}：${r.linkValue || '（未填目标）'}`;
}

/** 投放时间可读化：两端都空 = 不限制；只配一端时按"从某时起 / 到某时止"显示 */
function timeRangeLabel(r: BannerRow): string {
  const s = fmt(r.startAt);
  const e = fmt(r.endAt);
  if (!s && !e) return '不限制';
  if (s && !e) return `${s} 起`;
  if (!s && e) return `至 ${e}`;
  return `${s} → ${e}`;
}

function fmt(v: string | null): string {
  if (!v) return '';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

async function load() {
  loading.value = true;
  try {
    rows.value = await request<BannerRow[]>('GET', '/admin/home/banners');
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

function openCreate() {
  Object.assign(form, { id: undefined, title: '', subtitle: '', imageMediaId: null, linkType: 'none', linkValue: '', sortOrder: 0, visible: 1 });
  range.value = null;
  show.value = true;
}

function openEdit(r: BannerRow) {
  Object.assign(form, {
    id: r.id,
    title: r.title ?? '',
    subtitle: r.subtitle ?? '',
    imageMediaId: r.imageMediaId ?? null,
    linkType: LINK_OPTIONS.some((o) => o.value === r.linkType) ? r.linkType : 'none',
    linkValue: r.linkValue ?? '',
    sortOrder: r.sortOrder ?? 0,
    visible: r.visible === 2 ? 2 : 1,
  });
  const s = r.startAt ? new Date(r.startAt).getTime() : null;
  const e = r.endAt ? new Date(r.endAt).getTime() : null;
  range.value = s != null && e != null ? [s, e] : s != null ? [s, s] : null;
  // 只配了结束时间的老数据：datetimerange 表达不了"只有右端"，这里退化为"不限制"，
  // 运营打开弹窗就能看见（并在反馈文案里说明），保存后统一成区间 —— 不做隐式改写。
  if (s == null && e != null) range.value = null;
  show.value = true;
}

/**
 * 只提交「可写字段」：不把列表回带的 id / startAt / endAt 原样塞进 body
 * （服务端 DTO 白名单会 400 `property id should not exist`）。
 * `imageUrl` 也**不提交** —— 见文件头第 2 条：新数据一律走 imageMediaId。
 */
function buildPayload() {
  return {
    title: form.title ?? '',
    subtitle: form.subtitle ?? '',
    imageMediaId: form.imageMediaId ?? null,
    linkType: form.linkType ?? 'none',
    linkValue: form.linkValue ?? '',
    sortOrder: form.sortOrder ?? 0,
    visible: form.visible ?? 1,
    // ISO 字符串（服务端 @IsDateString）；null = 清空该端（不限制）
    startAt: range.value ? new Date(range.value[0]).toISOString() : null,
    endAt: range.value ? new Date(range.value[1]).toISOString() : null,
  };
}

async function save() {
  if (!form.imageMediaId) {
    message.warning('请先上传宣传图');
    return;
  }
  if (!form.title) {
    message.warning('请填写标题');
    return;
  }
  if (needsValue.value && !form.linkValue) {
    message.warning('已选择跳转类型，请填写跳转目标');
    return;
  }
  saving.value = true;
  try {
    if (form.id) await request('PUT', `/admin/home/banners/${form.id}`, buildPayload());
    else await request('POST', '/admin/home/banners', buildPayload());
    message.success('已保存（首页轮播即刻生效）');
    show.value = false;
    await load();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

/** 上下架：只改 visible 一个字段（1 显示 / 2 隐藏） */
function toggleVisible(r: BannerRow) {
  const next = r.visible === 1 ? 2 : 1;
  dialog.info({
    title: next === 2 ? '下架宣传图' : '上架宣传图',
    content:
      next === 2
        ? `确认下架「${r.title || '（无标题）'}」？首页轮播将立即不再显示这一张。`
        : `确认上架「${r.title || '（无标题）'}」？首页轮播将立即显示（若配了投放时间，还要落在时间区间内）。`,
    positiveText: next === 2 ? '下架' : '上架',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('PUT', `/admin/home/banners/${r.id}`, { visible: next });
        message.success(next === 2 ? '已下架' : '已上架');
        await load();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '操作失败');
      }
    },
  });
}

function remove(r: BannerRow) {
  dialog.warning({
    title: '删除宣传图',
    content: `确认删除「${r.title || '（无标题）'}」？删除后不可恢复。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/home/banners/${r.id}`);
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
