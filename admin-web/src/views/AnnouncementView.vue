<script setup lang="ts">
// 公告管理（admin:home:write）—— 由原「首页管理」拆出（2026-10-05）
//
// 为什么拆：原「首页管理」管四类东西，其中 Banner / 优秀打手 / 首页模块（介绍·活动·立即下单按钮）
// 只被老板端**旧首页**消费，而旧首页在 v0.5.0 UI 大改后已不在导航里（`home_shell.dart` 挂的是
// `services_page.dart`，`home_page.dart` 无人 import）→ 那三类已无人消费。
// 仍在被两端 App 消费的只剩两类，本页保留：
//   1. 公告（announcement 表）：`GET/POST/PUT/DELETE /admin/announcements`（原表单逻辑原样保留）
//   2. 关于我们 / 隐私政策两个模块文案（about_us / privacy_policy）：
//      两端「设置 → 关于 / 隐私政策」页读 `GET /public/about`、`GET /public/privacy`，
//      服务端从 `home_module` 取值 → 必须留一个可编辑入口。
//
// 已废弃（本页不再提供）：home_banner / top_worker / club_intro / activity / order_button
// —— 接口保留、表保留，详见审计报告「可清理清单」。
import { ApiException, request } from '@/api/client';
import { NButton, NCard, NDataTable, NForm, NFormItem, NInput, NModal, NPopconfirm, NRadioButton, NRadioGroup, NSwitch, NTabPane, NTabs, useMessage } from 'naive-ui';
import type { DataTableColumns } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface AnnouncementRow {
  id: string;
  title: string;
  summary: string;
  content: string;
  pinned: number;
  sortOrder: number;
  visible: number;
  createdAt: string;
}

interface ModuleRow {
  id: string;
  moduleKey: string;
  title: string;
  content: string | null;
  extraJson: Record<string, unknown> | null;
  sortOrder: number;
  visible: number;
}

/** 仍在被 App 消费的模块（其余模块已随旧首页废弃，不在此编辑） */
const LIVE_MODULES: { key: string; label: string; where: string }[] = [
  { key: 'about_us', label: '关于我们', where: '两端「设置 → 关于」页' },
  { key: 'privacy_policy', label: '隐私政策', where: '两端「设置 → 隐私政策」页' },
];

const message = useMessage();

const announcements = ref<AnnouncementRow[]>([]);
const modules = ref<ModuleRow[]>([]);
const loading = ref(false);

async function loadAnnouncements() {
  loading.value = true;
  try {
    announcements.value = await request<AnnouncementRow[]>('GET', '/admin/announcements');
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

async function loadModules() {
  try {
    modules.value = await request<ModuleRow[]>('GET', '/admin/home/modules');
    initModuleForm();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}

onMounted(() => {
  void loadAnnouncements();
  void loadModules();
});

// ---------- 公告（沿用原「首页管理 → 公告」表单逻辑，未改能力） ----------
const showAnn = ref(false);
const showAnnEdit = ref(false);
const annForm = reactive({ title: '', summary: '', content: '', pinned: 0 });
const editAnnId = ref<string | null>(null);

async function saveAnnouncement() {
  if (!annForm.title || !annForm.content) {
    message.warning('请填写标题与正文');
    return;
  }
  try {
    if (editAnnId.value) {
      await request('PUT', `/admin/announcements/${editAnnId.value}`, { ...annForm });
      message.success('公告已更新');
    } else {
      await request('POST', '/admin/announcements', { ...annForm });
      message.success('公告已发布');
    }
    showAnn.value = false;
    showAnnEdit.value = false;
    editAnnId.value = null;
    Object.assign(annForm, { title: '', summary: '', content: '', pinned: 0 });
    await loadAnnouncements();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  }
}

function openEditAnn(row: AnnouncementRow) {
  editAnnId.value = row.id;
  Object.assign(annForm, { title: row.title, summary: row.summary, content: row.content, pinned: row.pinned });
  showAnnEdit.value = true;
}

async function toggleAnn(row: AnnouncementRow, field: 'pinned' | 'visible') {
  try {
    // visible：1 显示 / 2 隐藏（api/docs/02 原语义，不是布尔）
    await request('PUT', `/admin/announcements/${row.id}`, { [field]: field === 'pinned' ? (row.pinned === 1 ? 0 : 1) : row.visible === 1 ? 2 : 1 });
    await loadAnnouncements();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

async function deleteAnn(row: AnnouncementRow) {
  try {
    await request('DELETE', `/admin/announcements/${row.id}`);
    message.success('公告已删除');
    await loadAnnouncements();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '删除失败');
  }
}

const annColumns = computed<DataTableColumns<AnnouncementRow>>(() => [
  { title: '标题', key: 'title', width: 220, ellipsis: { tooltip: true } },
  { title: '摘要', key: 'summary', ellipsis: { tooltip: true } },
  {
    title: '置顶',
    key: 'pinned',
    width: 80,
    render: (row) =>
      h(NSwitch, { value: row.pinned === 1, size: 'small', onUpdateValue: () => toggleAnn(row, 'pinned') }),
  },
  {
    title: '状态',
    key: 'visible',
    width: 148,
    render: (row) =>
      h(NRadioGroup, {
        value: row.visible,
        size: 'small',
        onUpdateValue: (v: number) => {
          if (v !== row.visible) void toggleAnn(row, 'visible');
        },
      }, {
        default: () => [
          h(NRadioButton, { value: 1 }, { default: () => '显示' }),
          h(NRadioButton, { value: 2 }, { default: () => '隐藏' }),
        ],
      }),
  },
  { title: '更新时间', key: 'createdAt', width: 170, render: (row) => fmtTime(row.createdAt) },
  {
    // 列宽和 = 220+80+148+170+140 = 758（+「摘要」弹性列，模板 :scroll-x 取 958 = 758+200）
    // 原 130 放不下「编辑 6px 删除」两个按钮（48+6+48=102 + 内边距 24 = 126）；fixed:'right' 保证滚动时可见
    title: '操作',
    key: 'actions',
    width: 140,
    fixed: 'right',
    render: (row) =>
      h('div', { style: 'display:flex;gap:6px' }, [
        h(NButton, { size: 'small', quaternary: true, onClick: () => openEditAnn(row) }, { default: () => '编辑' }),
        h(NPopconfirm, { onPositiveClick: () => deleteAnn(row) }, {
          trigger: () => h(NButton, { size: 'small', type: 'error', quaternary: true }, { default: () => '删除' }),
          default: () => '确认删除该公告？',
        }),
      ]),
  },
]);

/** 列表显示本地时间（服务端下发 UTC ISO；原页面直接显示原始串，改成本地可读） */
function fmtTime(v: string) {
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return v ?? '';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

// ---------- 模块文案（关于我们 / 隐私政策） ----------
const moduleForms = reactive<Record<string, { title: string; content: string; visible: number }>>({});
const savingModule = ref('');

function initModuleForm() {
  for (const m of modules.value) {
    if (!LIVE_MODULES.some((x) => x.key === m.moduleKey)) continue;
    moduleForms[m.moduleKey] = {
      title: m.title,
      content: m.content ?? '',
      visible: m.visible,
    };
  }
}

/** 模板 v-model 不能对可选链赋值，用访问函数返回可写对象 */
function moduleForm(key: string) {
  if (!moduleForms[key]) moduleForms[key] = { title: '', content: '', visible: 1 };
  return moduleForms[key];
}

function liveModule(key: string) {
  return modules.value.find((m) => m.moduleKey === key);
}

async function saveModule(key: string) {
  savingModule.value = key;
  try {
    const f = moduleForms[key];
    await request('PUT', `/admin/home/modules/${key}`, { title: f.title, content: f.content, visible: f.visible });
    message.success('已保存，App 设置页下次打开即更新');
    await loadModules();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    savingModule.value = '';
  }
}
</script>

<template>
  <div class="ann-page">
    <n-card title="公告管理" size="small">
      <n-tabs type="line" animated>
        <n-tab-pane name="announcements" tab="公告">
          <div class="toolbar">
            <span class="hint">置顶的公告排在最前；隐藏后客户端不再下发。</span>
            <div class="spacer" />
            <n-button size="small" @click="loadAnnouncements">刷新</n-button>
            <n-button size="small" type="primary" style="margin-left: 8px" @click="showAnn = true">发布公告</n-button>
          </div>
          <!-- 列宽和 758（摘要为弹性列，另计 200）→ 958；操作列 fixed:'right' -->
          <n-data-table :columns="annColumns" :data="announcements" :loading="loading" :bordered="false" size="small" :scroll-x="958" />
        </n-tab-pane>

        <n-tab-pane name="modules" tab="关于 / 隐私文案">
          <p class="panel-note">
            这两段文案仍在两端 App 里展示（设置页进入），保存后下次打开即更新；原「首页管理」的
            介绍 / 活动 / 立即下单按钮 / Banner / 优秀打手已随旧首页废弃，不再提供编辑入口。
          </p>
          <div v-for="m in LIVE_MODULES" :key="m.key" class="module-card">
            <div class="module-head">
              <strong>{{ m.label }}</strong>
              <span class="key">{{ m.key }}</span>
              <span class="where">{{ m.where }}</span>
              <div class="spacer" />
              <n-radio-group v-model:value="moduleForm(m.key).visible" size="small">
                <n-radio-button :value="1">显示</n-radio-button>
                <n-radio-button :value="2">隐藏</n-radio-button>
              </n-radio-group>
            </div>
            <n-form label-placement="left" label-width="60" size="small">
              <n-form-item label="标题">
                <n-input v-model:value="moduleForm(m.key).title" />
              </n-form-item>
              <n-form-item label="正文">
                <n-input
                  v-model:value="moduleForm(m.key).content"
                  type="textarea"
                  :autosize="{ minRows: 4, maxRows: 12 }"
                />
              </n-form-item>
            </n-form>
            <div class="module-foot">
              <span v-if="!liveModule(m.key)" class="hint warn">数据库中没有该模块行 —— 保存会新建一条</span>
              <div class="spacer" />
              <n-button size="small" type="primary" :loading="savingModule === m.key" @click="saveModule(m.key)">保存</n-button>
            </div>
          </div>
        </n-tab-pane>
      </n-tabs>
    </n-card>

    <n-modal
      v-model:show="showAnn"
      preset="dialog"
      title="发布公告"
      positive-text="发布"
      negative-text="取消"
      @positive-click="saveAnnouncement"
    >
      <n-form label-placement="left" label-width="60">
        <n-form-item label="标题"><n-input v-model:value="annForm.title" placeholder="不超过 100 字" /></n-form-item>
        <n-form-item label="摘要"><n-input v-model:value="annForm.summary" placeholder="列表里显示的一行摘要（可空）" /></n-form-item>
        <n-form-item label="正文"><n-input v-model:value="annForm.content" type="textarea" :autosize="{ minRows: 4, maxRows: 10 }" /></n-form-item>
        <n-form-item label="置顶"><n-switch v-model:value="annForm.pinned" :checked-value="1" :unchecked-value="0" /></n-form-item>
      </n-form>
    </n-modal>

    <n-modal
      v-model:show="showAnnEdit"
      preset="dialog"
      title="编辑公告"
      positive-text="保存"
      negative-text="取消"
      @positive-click="saveAnnouncement"
    >
      <n-form label-placement="left" label-width="60">
        <n-form-item label="标题"><n-input v-model:value="annForm.title" /></n-form-item>
        <n-form-item label="摘要"><n-input v-model:value="annForm.summary" /></n-form-item>
        <n-form-item label="正文"><n-input v-model:value="annForm.content" type="textarea" :autosize="{ minRows: 4, maxRows: 10 }" /></n-form-item>
        <n-form-item label="置顶"><n-switch v-model:value="annForm.pinned" :checked-value="1" :unchecked-value="0" /></n-form-item>
      </n-form>
    </n-modal>
  </div>
</template>

<style scoped>
/* 反 AI 味（docs/21）：实色 + 发丝线描边 + 圆角按既有 token 分档、无渐变、无 emoji、左对齐 */
.ann-page {
  padding: 16px;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 12px;
}
.spacer {
  flex: 1;
}
.hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.hint.warn {
  color: var(--color-warning);
}
.panel-note {
  margin: 0 0 12px;
  padding: 10px 12px;
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-text-secondary);
  background: var(--color-bg-page);
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-control);
}
.module-card {
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-card);
  padding: 14px 16px;
  margin-bottom: 16px;
  background: var(--color-bg-card);
}
.module-head {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
}
.module-head .key {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.module-head .where {
  font-size: 12px;
  color: var(--color-text-secondary);
}
.module-foot {
  display: flex;
  align-items: center;
  gap: 8px;
}
</style>
