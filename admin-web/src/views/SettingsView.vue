<template>
  <div class="settings-page">
    <n-card title="平台抽成比例" size="small" class="rate-card">
      <template #header-extra>
        <n-tag size="small" :type="editable ? 'info' : 'default'">
          {{ editable ? '可修改（admin:setting:write）' : '只读（无 admin:setting:write）' }}
        </n-tag>
      </template>

      <p class="desc">
        订单完成结算时，平台按下述比例抽成，其余全部进入打手钱包。<strong>改动只影响之后的结算</strong>：
        每笔结算的金额与比例会写进结算记录（历史单据按当时比例留痕，退款冲正也按该记录金额，不会因改比例错位）。
      </p>

      <n-form label-placement="left" label-width="120" :show-feedback="false">
        <n-form-item label="平台抽成比例" :validation-status="validationStatus" :feedback="feedback">
          <!-- 故意不设 :min/:max/:precision 的"静默钳制"：输入 51 / 25.5 时要**当场报中文错误**，
               而不是被组件悄悄改成 50 / 26 再存进去（实测踩过：那样运营会以为库里是自己填的值）。
               真正的取值约束 = 下方 computed 校验（前端）+ 后端 400（权威）。 -->
          <n-input-number
            v-model:value="rate"
            :disabled="!editable"
            placeholder="0 - 50 的整数"
            style="width: 180px"
          >
            <template #suffix>%</template>
          </n-input-number>
          <!-- 校验提示显式渲染（n-form 关了 show-feedback，避免整表单多出空行）：非法值当场红字说明 -->
          <span v-if="validationError" class="err">{{ validationError }}</span>
          <span class="split-hint">
            打手分成 = 100 − 抽成 =
            <strong>{{ workerRate }}%</strong>
          </span>
        </n-form-item>
        <n-form-item label="生效比例">
          <span class="current">
            当前库中生效值：<strong>平台 {{ savedRate ?? '—' }}%</strong> / 打手
            {{ savedRate === null ? '—' : 100 - savedRate }}%
            <span v-if="updatedAt" class="ts">（最后更新 {{ updatedAt }}）</span>
          </span>
        </n-form-item>
      </n-form>

      <div class="ops">
        <n-button type="primary" :loading="saving" :disabled="!editable || !canSave" @click="save">保存</n-button>
        <n-button :disabled="saving" @click="load">重置</n-button>
        <span class="tip">取值范围 0–50 的整数；非法值后端会拒绝（中文提示）</span>
      </div>

      <n-alert v-if="editable" type="warning" :bordered="false" class="warn">
        改了抽成会立即影响新结算：例如抽成 25% 时 ¥100.00 的订单，打手入账 ¥75.00、平台入账 ¥25.00（金额守恒）。
      </n-alert>
    </n-card>

    <n-card title="平台默认下单须知" size="small" class="rate-card">
      <template #header-extra>
        <n-tag size="small" :type="editable ? 'info' : 'default'">
          {{ editable ? '可修改（admin:setting:write）' : '只读（无 admin:setting:write）' }}
        </n-tag>
      </template>

      <p class="desc">
        老板端<b>商品详情页</b>的「下单须知」默认折叠成一行，点「展开」看全。
        商品没单独配「下单须知」时（默认情况），下发<b>这份</b>；
        单个商品可在「商品」页的编辑弹窗里选「覆盖」写自己的一份。
        <b>每行一条</b>，不要自己写「1.」这类序号 —— 客户端按行自动编号。
      </p>

      <n-form label-placement="left" label-width="140" :show-feedback="false">
        <n-form-item label="默认下单须知">
          <n-input
            v-model:value="notice"
            type="textarea"
            :autosize="{ minRows: 5, maxRows: 16 }"
            maxlength="3000"
            show-count
            :disabled="!editable"
            style="width: 720px; max-width: 100%"
            placeholder="每行一条，条内不要写序号"
          />
        </n-form-item>
        <n-form-item label="当前生效">
          <span class="current">
            {{ savedNotice === null ? '—' : `${savedNotice.split('\n').filter((l) => l.trim()).length} 条` }}
            <span v-if="noticeUpdatedAt" class="ts">（最后更新 {{ noticeUpdatedAt }}）</span>
          </span>
        </n-form-item>
      </n-form>

      <div class="ops">
        <n-button type="primary" :loading="noticeSaving" :disabled="!editable || !noticeCanSave" @click="saveNotice">
          保存
        </n-button>
        <n-button :disabled="noticeSaving" @click="loadNotice">重置</n-button>
        <span class="tip">保存后，所有未单独配置须知的商品**下一次请求**即生效（详情接口带 45s 客户端缓存）</span>
      </div>
    </n-card>

    <n-card title="购买提示（选择服务页小字）" size="small" class="rate-card">
      <template #header-extra>
        <n-tag size="small" type="warning">仅超管可改（is_high_security）</n-tag>
      </template>

      <p class="desc">
        老板端<b>「选择服务」页底部</b>常驻的一行小字（11.5px 次要色、最多 2 行）。
        它会出现在**每一个分部的商品列表页**上，所以改错等于向所有用户发错充值口径。
        文案**完全由这里下发**，客户端零硬编码 —— 改完保存，用户**下一次请求**即生效（不需要发版）。
        <b>留空 = 这一行彻底不显示</b>（充值活动暂停时可以这么关掉）。
      </p>

      <n-form label-placement="left" label-width="140" :show-feedback="false">
        <n-form-item label="购买提示文案">
          <n-input
            v-model:value="purchaseHint"
            type="textarea"
            :autosize="{ minRows: 2, maxRows: 5 }"
            maxlength="200"
            show-count
            :disabled="!superEditable"
            style="width: 720px; max-width: 100%"
            placeholder="留空 = 该行不显示"
          />
        </n-form-item>
        <n-form-item label="当前生效">
          <span class="current">
            {{ savedHint === null ? '—' : savedHint === '' ? '（留空：客户端整行不渲染）' : `${savedHint.length} 字` }}
            <span v-if="purchaseHintUpdatedAt" class="ts">（最后更新 {{ purchaseHintUpdatedAt }}）</span>
          </span>
        </n-form-item>
      </n-form>

      <div class="ops">
        <n-button type="primary" :loading="hintSaving" :disabled="!superEditable || !hintCanSave" @click="saveHint">
          保存
        </n-button>
        <n-button :disabled="hintSaving || !superEditable" @click="fillHintDefault">恢复默认文案</n-button>
        <n-button :disabled="hintSaving" @click="loadHint">重置</n-button>
        <span class="tip">与「平台默认下单须知」同一套落库形状（system_setting 一行，cfg_value.value.text）</span>
      </div>
    </n-card>

    <n-card title="身份绑定上限" size="small" class="rate-card">
      <template #header-extra>
        <n-tag size="small" type="warning">仅超管可改（is_high_security）</n-tag>
      </template>

      <p class="desc">
        一个老板账号最多能绑定几个打手账号，默认 1。老板在老板端「我的 → 绑定打手账号」输入打手账密时，
        服务端**每次实时读这一项**：达到上限即中文拒绝「绑定数量已达上限（当前上限 N 个）」。
        绑定的存储侧用「槽位 + 唯一键」实现该上限（并发也不会越限），所以改完**下一次绑定请求立即生效**，
        不需要重启、不需要发版。绑定记录（绑定/解绑时间、上限占用）在「身份绑定」页可查。
      </p>

      <n-form label-placement="left" label-width="140" :show-feedback="false">
        <n-form-item label="绑定上限" :validation-status="bindMaxStatus" :feedback="bindMaxError">
          <n-input-number
            v-model:value="bindMax"
            :disabled="!superEditable"
            :min="1"
            :max="10"
            :precision="0"
            placeholder="1 - 10 的整数"
            style="width: 180px"
          >
            <template #suffix>个</template>
          </n-input-number>
          <span v-if="bindMaxError" class="err">{{ bindMaxError }}</span>
          <span class="split-hint">
            一个老板最多绑 <strong>{{ bindMax ?? '—' }}</strong> 个打手账号
          </span>
        </n-form-item>
        <n-form-item label="当前生效">
          <span class="current">
            当前库中生效值：<strong>{{ savedBindMax ?? '—' }}</strong> 个
            <span v-if="bindMaxUpdatedAt" class="ts">（最后更新 {{ bindMaxUpdatedAt }}）</span>
          </span>
        </n-form-item>
      </n-form>

      <div class="ops">
        <n-button type="primary" :loading="bindMaxSaving" :disabled="!superEditable || !bindMaxCanSave" @click="saveBindMax">
          保存
        </n-button>
        <n-button :disabled="bindMaxSaving || !superEditable" @click="loadBindMax">重置</n-button>
        <span class="tip">取值范围 1–10 的整数（0 等于"谁都不能绑"，语义上应由功能开关承担）；非法值后端 400 中文拒绝</span>
      </div>
    </n-card>

    <n-card title="提现设置" size="small" class="rate-card">
      <template #header-extra>
        <n-tag size="small" type="warning">仅超管可改（withdraw:review / withdraw:pay 只管审核）</n-tag>
      </template>

      <p class="desc">
        打手在 App 里发起提现时的<b>门槛 / 上限 / 每日次数 / 说明文案</b>。
        这里是唯一入口 —— 改完<b>下一次请求立即生效</b>（服务端实时读库、无缓存、不需要发版）。
        审核动作（核对收款信息、线下打款、驳回退余额）在「<b>提现审核</b>」页，两处的权限点刻意分开：
        <b>这一块只有超级管理员能改</b>，有审核权限的运营只能看。
      </p>

      <n-alert type="info" :bordered="false" class="warn">
        服务端口径（`withdraw-config.ts`）：金额是<b>整数元</b>（1–1,000,000）、每日次数 <b>1–20</b>、
        费率 <b>0–50 整数百分点</b>（当前 0 = 不收手续费，仅保留口径）、说明文案 <b>≤500 字</b>，
        且文案里不能再出现旧计价单位的字样（服务端会中文 400 拒绝）。
        另外「同一打手同时只能有一笔在途提现」是<b>资金安全不变量</b>（写死在服务端 + 唯一键），不在这里配。
      </n-alert>

      <n-alert v-if="withdrawConfigError" type="error" :bordered="false" class="warn">
        提现设置没取到：{{ withdrawConfigError }}
      </n-alert>

      <n-form label-placement="left" label-width="140" :show-feedback="false">
        <n-form-item label="单笔门槛" :validation-status="withdrawError ? 'error' : undefined">
          <n-input-number
            v-model:value="withdraw.minAmount"
            :disabled="!superEditable"
            :min="1"
            :max="1000000"
            :precision="0"
            placeholder="如 10"
            style="width: 180px"
          >
            <template #suffix>元</template>
          </n-input-number>
          <span class="split-hint">低于这个金额不能提交提现申请（整数元）</span>
        </n-form-item>
        <n-form-item label="单笔上限">
          <n-input-number
            v-model:value="withdraw.maxAmount"
            :disabled="!superEditable"
            :min="1"
            :max="1000000"
            :precision="0"
            placeholder="如 2000"
            style="width: 180px"
          >
            <template #suffix>元</template>
          </n-input-number>
          <span class="split-hint">超出即中文拒绝（整数元；上限不能小于门槛）</span>
        </n-form-item>
        <n-form-item label="每人每日次数">
          <n-input-number
            v-model:value="withdraw.dailyLimit"
            :disabled="!superEditable"
            :min="1"
            :max="20"
            :precision="0"
            placeholder="如 1"
            style="width: 180px"
          >
            <template #suffix>次</template>
          </n-input-number>
          <span class="split-hint">按北京时间自然日计（1–20）；超了服务端中文拒绝</span>
        </n-form-item>
        <n-form-item label="手续费率">
          <n-input-number
            v-model:value="withdraw.feeRate"
            :disabled="!superEditable"
            :min="0"
            :max="50"
            :precision="0"
            placeholder="0 表示不收费"
            style="width: 180px"
          >
            <template #suffix>%</template>
          </n-input-number>
          <span class="split-hint">0–50 整数（当前 0）；示例：费率 2% 时 ¥100.00 申请应打款 ¥98.00</span>
        </n-form-item>
        <n-form-item label="给打手的说明">
          <n-input
            v-model:value="withdraw.noticeText"
            type="textarea"
            :autosize="{ minRows: 3, maxRows: 10 }"
            maxlength="500"
            show-count
            :disabled="!superEditable"
            style="width: 720px; max-width: 100%"
            placeholder="每行一条，客户端按行渲染，不要写序号&#10;例：提现 1–3 个工作日处理&#10;请确保姓名、手机号、微信号与收款码是同一人"
          />
        </n-form-item>
        <n-form-item label="当前生效">
          <span class="current">
            <template v-if="withdrawSaved">
              门槛 <strong>{{ formatYuanOr(withdrawSaved.minAmount) }}</strong> ·
              上限 <strong>{{ formatYuanOr(withdrawSaved.maxAmount) }}</strong> ·
              每日 <strong>{{ withdrawSaved.dailyLimit }}</strong> 次 ·
              费率 <strong>{{ withdrawSaved.feeRate }}%</strong> ·
              说明 {{ withdrawSaved.noticeText ? `${withdrawSaved.noticeText.split('\n').filter((l) => l.trim()).length} 条` : '（空）' }}
            </template>
            <template v-else>（没取到服务端口径）</template>
          </span>
        </n-form-item>
      </n-form>

      <p v-if="withdrawError" class="err">{{ withdrawError }}</p>

      <div class="ops">
        <n-button
          type="primary"
          :loading="withdrawSaving"
          :disabled="!superEditable || !withdrawDirty || !!withdrawError"
          @click="saveWithdraw"
        >
          保存
        </n-button>
        <n-button :disabled="withdrawSaving || !withdrawSaved" @click="loadWithdraw">重置为当前生效值</n-button>
        <n-button :disabled="withdrawSaving || !superEditable" :loading="withdrawLoading" @click="loadWithdraw">重新读取</n-button>
        <span class="tip">
          {{ superEditable ? '保存后打手端下一次请求即按新口径下发' : '只读账号：保存会被服务端 403 拒绝（仅超管）' }}
        </span>
      </div>
    </n-card>

    <n-card title="全部配置项" size="small" class="list-card">
      <n-data-table :columns="columns" :data="rows" :loading="loading" size="small" :scroll-x="970" />
    </n-card>
  </div>
</template>

<script setup lang="ts">
// 系统设置（负责人 2026-10-04：抽成比例后台可自定义）：
// 可视化编辑 platform_commission_rate（数字输入 + % 后缀 + 0–50 整数校验），保存走既有 PUT /admin/settings/:key。
// 页面底部的"全部配置项"表格只读展示 system_setting 现状，便于运营核对（改其它配置走各自专属页面）。
import { ApiException, request } from '@/api/client';
import {
  DEFAULT_WITHDRAW_CONFIG,
  WITHDRAW_LIMITS,
  getWithdrawConfig,
  updateWithdrawConfig,
  type WithdrawConfig,
} from '@/api/withdraw';
import { formatYuanOr } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import { NAlert, NButton, NCard, NDataTable, NForm, NFormItem, NInput, NInputNumber, NTag, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

/** 与后端 server/src/modules/setting/commission-rate.ts 同名同语义（百分数整数，默认 25，范围 0–50） */
const RATE_KEY = 'platform_commission_rate';
const RATE_DEFAULT = 25;
const RATE_MIN = 0;
const RATE_MAX = 50;

/** 平台默认下单须知的配置 key（与 server/src/modules/setting/order-notice.ts 同名同语义） */
const ORDER_NOTICE_KEY = 'order_notice_default';

interface SettingRow {
  id: string;
  settingKey: string;
  cfgValue: Record<string, unknown>;
  description: string;
  isHighSecurity: number;
  updatedAt: string;
}

const auth = useAuthStore();
const message = useMessage();
const rows = ref<SettingRow[]>([]);
const loading = ref(false);
const saving = ref(false);
/** 输入框里的值（null = 空） */
const rate = ref<number | null>(null);
/** 库中当前生效值（保存成功后刷新） */
const savedRate = ref<number | null>(null);
const updatedAt = ref('');

const editable = computed(() => auth.hasPermission('admin:setting:write'));
/** 读配置：`admin:setting:read`（= 「系统设置」菜单项的权限点；提现配置的 GET 也用它，与写分开） */
const canReadSetting = computed(() => auth.hasPermission('admin:setting:read'));

/** 输入校验（与后端同一口径：0–50 的整数）；前端只是体验，服务端仍强制校验 */
const validationError = computed(() => {
  const v = rate.value;
  if (v === null || v === undefined || (typeof v === 'string' && v === '')) return '请填写抽成比例';
  const n = Number(v);
  if (!Number.isFinite(n)) return '抽成比例必须是数字';
  if (!Number.isInteger(n)) return '抽成比例必须是整数（不接受小数）';
  if (n < RATE_MIN || n > RATE_MAX) return `抽成比例必须在 ${RATE_MIN}–${RATE_MAX} 之间`;
  return '';
});
const validationStatus = computed<'error' | 'success' | undefined>(() =>
  validationError.value ? 'error' : undefined,
);
const feedback = computed(() => validationError.value || undefined);
const workerRate = computed(() => {
  const n = Number(rate.value);
  return Number.isInteger(n) ? 100 - n : '—';
});
const canSave = computed(() => !validationError.value && rate.value !== savedRate.value);

const columns = [
  // 列宽和 = 230+260+110+170 = 770（+「说明」弹性列 200）→ 模板 :scroll-x = 970
  // （原 :scroll-x="760" 小于列宽总和 → 右侧「最后更新」被裁）
  { title: '配置项 key', key: 'settingKey', width: 230 },
  {
    title: '取值', key: 'cfgValue', width: 260,
    render: (row: SettingRow) => JSON.stringify(row.cfgValue),
  },
  { title: '说明', key: 'description' },
  {
    title: '安全级别', key: 'isHighSecurity', width: 110,
    render: (row: SettingRow) => h(NTag, { size: 'small', type: row.isHighSecurity === 1 ? 'warning' : 'default' },
      { default: () => (row.isHighSecurity === 1 ? '仅超管可改' : '普通配置') }),
  },
  {
    title: '最后更新', key: 'updatedAt', width: 170,
    render: (row: SettingRow) => new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false }),
  },
];

async function load() {
  loading.value = true;
  try {
    const list = await request<SettingRow[]>('GET', '/admin/settings');
    rows.value = list;
    const row = list.find((r) => r.settingKey === RATE_KEY);
    if (row) {
      const v = Number(row.cfgValue?.['value']);
      savedRate.value = Number.isFinite(v) ? v : RATE_DEFAULT;
      updatedAt.value = new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false });
    } else {
      savedRate.value = null;
      updatedAt.value = '';
    }
    rate.value = savedRate.value ?? RATE_DEFAULT;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}

async function save() {
  if (validationError.value) {
    message.error(validationError.value);
    return;
  }
  saving.value = true;
  try {
    await request('PUT', `/admin/settings/${RATE_KEY}`, { cfgValue: { value: Number(rate.value) } });
    message.success(`已保存：平台抽成 ${rate.value}%，打手 ${100 - Number(rate.value)}%（对之后的结算立即生效）`);
    await load();
  } catch (e) {
    // 后端中文校验消息（如"抽成比例必须是 0–50 的整数（单位：%），当前值非法：..."）直接展示
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

// ---------------- 身份绑定上限（负责人 2026-10-06 身份合并方案甲）----------------
//
// 配置 key = `worker_binding_max_per_boss`（落库形状 `{"value": 1}`，与抽成比例同约定），
// 该行 `is_high_security = 1` → **仅超管可改**（普通管理员可读、保存被服务端 403 中文拒绝），
// 所以这里除了 `admin:setting:write` 还要 `auth.isSuperAdmin`，避免普通管理员点保存白挨一次报错。
//
// 与后端同一口径（server/src/modules/auth/worker-binding-limit.ts）：1–10 整数，默认 1。
// 服务端 `SystemSettingService.update` 也会用同一个 assertWorkerBindingMax 校验（前端只是体验）。

/** 与后端 worker-binding-limit.ts 同名同语义 */
const BIND_MAX_KEY = 'worker_binding_max_per_boss';
const BIND_MAX_DEFAULT = 1;
const BIND_MAX_MIN = 1;
const BIND_MAX_MAX = 10;

/** 输入框里的值（null = 空） */
const bindMax = ref<number | null>(null);
/** 库中当前生效值（保存成功后刷新） */
const savedBindMax = ref<number | null>(null);
const bindMaxUpdatedAt = ref('');
const bindMaxSaving = ref(false);

const bindMaxError = computed(() => {
  const v = bindMax.value;
  if (v === null || v === undefined) return '请填写绑定上限';
  const n = Number(v);
  if (!Number.isFinite(n)) return '绑定上限必须是数字';
  if (!Number.isInteger(n)) return '绑定上限必须是整数（不接受小数）';
  if (n < BIND_MAX_MIN || n > BIND_MAX_MAX) return `绑定上限必须在 ${BIND_MAX_MIN}–${BIND_MAX_MAX} 之间`;
  return '';
});
const bindMaxStatus = computed<'error' | 'success' | undefined>(() => (bindMaxError.value ? 'error' : undefined));
const bindMaxCanSave = computed(() => !bindMaxError.value && bindMax.value !== savedBindMax.value);

async function loadBindMax() {
  try {
    const row = rows.value.find((r) => r.settingKey === BIND_MAX_KEY);
    if (row) {
      const v = Number(row.cfgValue?.['value']);
      savedBindMax.value = Number.isInteger(v) ? v : BIND_MAX_DEFAULT;
      bindMaxUpdatedAt.value = new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false });
    } else {
      savedBindMax.value = null;
      bindMaxUpdatedAt.value = '';
    }
    bindMax.value = savedBindMax.value ?? BIND_MAX_DEFAULT;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '绑定上限加载失败');
  }
}

async function saveBindMax() {
  if (bindMaxError.value) {
    message.error(bindMaxError.value);
    return;
  }
  bindMaxSaving.value = true;
  try {
    await request('PUT', `/admin/settings/${BIND_MAX_KEY}`, { cfgValue: { value: Number(bindMax.value) } });
    message.success(`已保存：一个老板最多绑定 ${bindMax.value} 个打手账号（下一次绑定请求即生效）`);
    await load();
    await loadBindMax();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    bindMaxSaving.value = false;
  }
}

// ---------------- 提现设置（本轮新增：门槛 / 上限 / 每日次数 / 费率 / 说明文案）----------------
//
// 走专属端点 `GET/PUT /admin/withdraw/config`（**仅超管可写**），而不是通用的
// `/admin/settings/:key`：后者的 cfgValue 是 `{value:{...}}` 两层形状，表单直拼容易拼错；
// 这一块要的是"五个字段进、五个字段出"。落库侧由服务端决定（本页不关心它落在哪张表）。
//
// 与「充值设置」的关系：充值设置目前嵌在「充值管理」页的 tab 里（收款码/白名单同页，属同一业务面），
// 而提现设置**不新开页面**、并进本页 —— 负责人本轮口径；两块配置在语义上都是"资金口径"，
// 且**都只有超管能改**，放在系统设置里与抽成比例/绑定上限同一档。
//
// 权限：`admin:setting:write`（页面既有口径）**且** `auth.isSuperAdmin`（服务端 is_high_security 闸门）。
// 注意与审核权限分开：有 `withdraw:review` / `withdraw:pay` 的运营能审单，但改不了这里的口径。

const withdraw = reactive<WithdrawConfig>({ ...DEFAULT_WITHDRAW_CONFIG });
/** 库中当前生效值（保存成功后回读；null = 没取到，不把本地默认值谎报成线上值） */
const withdrawSaved = ref<WithdrawConfig | null>(null);
const withdrawLoading = ref(false);
const withdrawSaving = ref(false);
const withdrawConfigError = ref('');

/** 与后端同一口径的前端校验（服务端 `assertWithdrawConfig` 仍强制）——**逐条照抄它的中文口径**，
 *  免得运营在页面上填得进去、保存才吃 400：
 *  min/max 1–1,000,000 整数 · dailyLimit 1–20 整数 · feeRate 0–50 整数 · noticeText ≤500 字且不含"积分"。 */
const withdrawError = computed(() => {
  const w = withdraw;
  const L = WITHDRAW_LIMITS;
  if (w.minAmount === null || w.maxAmount === null || w.dailyLimit === null || w.feeRate === null) return '四项数字都要填';
  const min = Number(w.minAmount);
  const max = Number(w.maxAmount);
  const daily = Number(w.dailyLimit);
  const fee = Number(w.feeRate);
  if (!Number.isInteger(min) || min < L.amountMin || min > L.amountMax) {
    return `单笔提现下限必须是 ${L.amountMin}–${L.amountMax} 的整数（元）`;
  }
  if (!Number.isInteger(max) || max < L.amountMin || max > L.amountMax) {
    return `单笔提现上限必须是 ${L.amountMin}–${L.amountMax} 的整数（元）`;
  }
  if (min > max) return `单笔提现下限（${min} 元）不能大于上限（${max} 元）`;
  if (!Number.isInteger(daily) || daily < L.dailyLimitMin || daily > L.dailyLimitMax) {
    return `每日申请次数必须是 ${L.dailyLimitMin}–${L.dailyLimitMax} 的整数`;
  }
  if (!Number.isInteger(fee) || fee < L.feeRateMin || fee > L.feeRateMax) {
    return `手续费率必须是 ${L.feeRateMin}–${L.feeRateMax} 的整数（百分数）`;
  }
  if (withdraw.noticeText.length > L.noticeMax) return `说明文案最多 ${L.noticeMax} 字`;
  // 计价单位铁律（2026-10-09）：全站金额一律 ¥/元 —— 文案里也不能再出现旧计价单位的字样（服务端会 400）
  if (withdraw.noticeText.includes('积分')) return '说明文案请统一用「元」计价（旧计价单位的字样会被服务端拒绝）';
  return '';
});

const withdrawDirty = computed(() => {
  const s = withdrawSaved.value;
  if (!s) return false;
  return (
    Number(withdraw.minAmount) !== Number(s.minAmount) ||
    Number(withdraw.maxAmount) !== Number(s.maxAmount) ||
    Number(withdraw.dailyLimit) !== Number(s.dailyLimit) ||
    Number(withdraw.feeRate) !== Number(s.feeRate) ||
    withdraw.noticeText !== s.noticeText
  );
});

async function loadWithdraw() {
  // 读配置要 `admin:setting:read`（服务端 `GET /admin/withdraw/config` 的权限点）——
  // 没权限就**不发请求**（发了只会满页红色报错，运营以为页面坏了）
  if (!canReadSetting.value) {
    withdrawSaved.value = null;
    withdrawConfigError.value = '';
    return;
  }
  withdrawLoading.value = true;
  withdrawConfigError.value = '';
  try {
    const cfg = await getWithdrawConfig();
    withdrawSaved.value = cfg;
    Object.assign(withdraw, cfg);
  } catch (e) {
    // 服务端中文原文直接展示（不翻译、不吞）
    withdrawSaved.value = null;
    withdrawConfigError.value = e instanceof ApiException ? e.message : '提现设置加载失败';
  } finally {
    withdrawLoading.value = false;
  }
}

async function saveWithdraw() {
  if (!superEditable.value) {
    message.warning('提现设置仅超级管理员可改');
    return;
  }
  if (withdrawError.value) {
    message.error(withdrawError.value);
    return;
  }
  withdrawSaving.value = true;
  try {
    await updateWithdrawConfig({
      minAmount: Number(withdraw.minAmount),
      maxAmount: Number(withdraw.maxAmount),
      dailyLimit: Number(withdraw.dailyLimit),
      feeRate: Number(withdraw.feeRate),
      noticeText: withdraw.noticeText,
    });
    message.success('已保存：打手端下一次请求即按新口径下发');
    await loadWithdraw(); // 保存后回读：页面上"当前生效"必须是库里的值，不是本地草稿
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '提现设置保存失败');
  } finally {
    withdrawSaving.value = false;
  }
}

// ---------------- 平台默认下单须知（负责人 2026-10-05 商品详情页 v2 方案 B）----------------
//
// 走专属端点 `GET/PUT /admin/order-notice`，不用通用的 `/admin/settings/:key`：
// 后者的 `cfgValue` 是 `{value:{text}}` 这种两层形状，管理端表单直接拼容易拼错，
// 而这里只需要"一份多行文本进、一份多行文本出"。落库形状仍与通用设置完全一致
// （见 server 侧 `OrderNoticeAdminController`），所以「全部配置项」表格里也能看到它。

/** 输入框里的文本（null = 尚未加载） */
const notice = ref<string | null>(null);
/** 库中当前生效文本（保存成功后刷新） */
const savedNotice = ref<string | null>(null);
const noticeUpdatedAt = ref('');
const noticeSaving = ref(false);

/** 与后端同一口径：不能全空白（留空会让所有未单独配置的商品失去须知） */
const noticeError = computed(() => {
  const v = (notice.value ?? '').trim();
  if (!v) return '默认下单须知不能为空';
  if (v.length > 3000) return '默认下单须知最多 3000 字';
  return '';
});
const noticeCanSave = computed(() => !noticeError.value && (notice.value ?? '') !== (savedNotice.value ?? ''));

async function loadNotice() {
  try {
    const resp = await request<{ text: string }>('GET', '/admin/order-notice');
    savedNotice.value = resp?.text ?? '';
    notice.value = savedNotice.value;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '默认下单须知加载失败');
  }
  // 最后更新时间从「全部配置项」里取（同一份 system_setting 行）
  const row = rows.value.find((r) => r.settingKey === ORDER_NOTICE_KEY);
  noticeUpdatedAt.value = row ? new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false }) : '';
}

async function saveNotice() {
  if (noticeError.value) {
    message.error(noticeError.value);
    return;
  }
  noticeSaving.value = true;
  try {
    await request('PUT', '/admin/order-notice', { text: (notice.value ?? '').trim() });
    message.success('已保存：未单独配置须知的商品，详情页下次请求即显示这份');
    await load();
    await loadNotice();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    noticeSaving.value = false;
  }
}

// ---------------- 购买提示（负责人 2026-10-05：选择服务页那一行小字）----------------
//
// 与「平台默认下单须知」同一套做法（专属端点 + 落库形状一致），两点不同：
// 1) **仅超管可写**：该配置行 is_high_security = 1，服务端 `SystemSettingService.update`
//    按真实角色码校验（普通管理员能看、保存会被 403 中文拒绝）。所以这里除了
//    `admin:setting:write` 还要 `auth.isSuperAdmin`，避免普通管理员点保存白挨一次报错。
// 2) **允许留空**：留空 = 客户端整行不渲染（运营主动关闭这行提示），
//    与下单须知"留空会让商品失去须知"的语义刚好相反，故不做"不能为空"校验。

/** 购买提示的配置 key（与 server/src/modules/setting/purchase-hint.ts 同名同语义） */
const PURCHASE_HINT_KEY = 'purchase_points_hint';

/** 输入框里的文本（null = 尚未加载） */
const purchaseHint = ref<string | null>(null);
/** 库中当前生效文本（保存成功后刷新；'' = 运营清空 → 客户端不显示） */
const savedHint = ref<string | null>(null);
/** 代码里的初始默认值（服务端随读接口一起下发，供「恢复默认文案」按钮用） */
const hintDefaultText = ref('');
const purchaseHintUpdatedAt = ref('');
const hintSaving = ref(false);

/** 仅超管可写（权威判定在服务端：is_high_security=1） */
const superEditable = computed(() => editable.value && auth.isSuperAdmin);

/** 与后端同一口径：最多 200 字；**允许为空**（空 = 关闭这行提示） */
const hintError = computed(() => ((purchaseHint.value ?? '').length > 200 ? '购买提示最多 200 字' : ''));
const hintCanSave = computed(() => !hintError.value && (purchaseHint.value ?? '') !== (savedHint.value ?? ''));

async function loadHint() {
  try {
    const resp = await request<{ text: string; defaultText?: string }>('GET', '/admin/purchase-hint');
    savedHint.value = resp?.text ?? '';
    hintDefaultText.value = resp?.defaultText ?? '';
    purchaseHint.value = savedHint.value;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '购买提示加载失败');
  }
  // 最后更新时间从「全部配置项」里取（同一份 system_setting 行）
  const row = rows.value.find((r) => r.settingKey === PURCHASE_HINT_KEY);
  purchaseHintUpdatedAt.value = row ? new Date(row.updatedAt).toLocaleString('zh-CN', { hour12: false }) : '';
}

/** 把服务端下发的默认文案填进输入框（还要点「保存」才落库，避免误触直接改线上） */
function fillHintDefault() {
  if (!hintDefaultText.value) {
    message.warning('服务端没有下发默认文案，请手动填写');
    return;
  }
  purchaseHint.value = hintDefaultText.value;
}

async function saveHint() {
  if (hintError.value) {
    message.error(hintError.value);
    return;
  }
  hintSaving.value = true;
  try {
    const text = (purchaseHint.value ?? '').trim();
    await request('PUT', '/admin/purchase-hint', { text });
    message.success(text ? '已保存：老板端「选择服务」页下一次请求即显示这行提示' : '已保存为空：客户端这一行不再显示');
    await load();
    await loadHint();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    hintSaving.value = false;
  }
}

onMounted(async () => {
  await load();
  await loadNotice();
  await loadHint();
  // 身份绑定上限（与上面每一项同一份 system_setting，故放在最后：先 load() 拿到「全部配置项」再取时间戳）
  await loadBindMax();
  // 提现设置（本轮新增，走专属端点 /admin/withdraw/config，与上面几项的来源不同，因此独立加载）
  await loadWithdraw();
});
</script>

<style scoped>
.settings-page {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.desc {
  color: var(--color-text-secondary);
  font-size: 13px;
  line-height: 1.7;
  margin: 0 0 16px;
}
.split-hint {
  margin-left: 16px;
  color: var(--color-text-secondary);
  font-size: 13px;
}
.err {
  margin-left: 12px;
  color: var(--color-danger, #d03050);
  font-size: 13px;
}
.current {
  font-size: 13px;
  color: var(--color-text-secondary);
}
.ts {
  color: var(--color-text-tertiary);
}
.ops {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 8px;
}
.tip {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.warn {
  margin-top: 16px;
}
</style>
