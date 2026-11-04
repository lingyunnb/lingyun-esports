<script setup lang="ts">
/**
 * 「调整打手展示数据」编辑窗（负责人 2026-10-16 指令）
 * ============================================================================
 * ## 只改两个数字：接单次数 / 好评率（评价内容一律真实，本窗**没有**评价编辑入口）
 * ## 三个概念必须在界面上一眼分清（运营最容易搞混的就是它们）
 *   ① **真实值（只读）**：订单与真实评价的实时统计，改不了；
 *   ② **展示值（可填）**：管理端设的对外数字；**留空 = 跟随真实**（不是 0！）；
 *   ③ **最终生效（预览）**：用户此刻真正会看到的数字 —— 填什么就实时预览什么。
 *
 * ## 预览为什么分两种来源（别把这段逻辑简化掉）
 *   · 表单**未改动** → 直接采信服务端下发的 `effective`（最权威：就是此刻 App 上的数字），
 *     顺带当了一次"我算的对不对"的自校验；
 *   · 有改动（含输入不合法）→ 本地按「留空 = 跟随真实」实时算，做到"填什么预览什么"。
 *
 * ## 好评率口径
 * **百分数**（`98.2` = 98.2%），**不是 0–1 比率**；显示一律走 `@/utils/worker-stats`（唯一出口，
 * 那里记着"`1.0` 被渲染成 100%"的事故，别在这里另写一套）。
 *
 * ## 写操作
 * 提交前**二次确认**，文案必须写清"这会让用户看到 X，而不是真实的 Y"；
 * 保存会写 `operation_log`（服务端负责），前端不重复留痕。
 */
import { ApiException } from '@/api/client';
import { fetchWorkerStats, saveWorkerDisplayStats, type WorkerStats } from '@/api/worker-display-stats';
import {
  ORDERS_MAX,
  ORDERS_MIN,
  RATE_MAX,
  RATE_MIN,
  ordersText,
  parseOrdersInput,
  parseRateInput,
  rateText,
  satisfiedRateText,
} from '@/utils/worker-stats';
import { NButton, NForm, NFormItem, NInput, NModal, NSpin, useDialog, useMessage } from 'naive-ui';
import { computed, h, ref, watch } from 'vue';

const props = defineProps<{
  show: boolean;
  /** **`worker.id`**（不是 `user.id`）—— 契约里的 `:id` */
  workerId: string | null;
  /** 窗头标题用的打手标识（昵称 · 工号） */
  workerLabel: string;
}>();
const emit = defineEmits<{
  (e: 'update:show', v: boolean): void;
  (e: 'saved'): void;
}>();

const dialog = useDialog();
const message = useMessage();

const visible = computed({
  get: () => props.show,
  set: (v: boolean) => emit('update:show', v),
});

// ---------------------------------------------------------------- 读取
const loading = ref(false);
const saving = ref(false);
const stats = ref<WorkerStats | null>(null);
/** 读取失败文案；**403 单独记一笔**（要给出"需要超管权限"的明确说明，不能只显示"加载失败"） */
const loadError = ref<string | null>(null);
const loadForbidden = ref(false);

/** 输入框用**字符串**存：才能把"留空（跟随真实）"与"填了 0"分开（数值型输入做不到这点） */
const ordersRaw = ref('');
const rateRaw = ref('');

function describeError(e: unknown, fallback: string, what: string): { text: string; forbidden: boolean } {
  if (e instanceof ApiException) {
    if (e.code === 403) {
      return {
        forbidden: true,
        text: `需要超管权限（权限点 worker:adjust）：服务端拒绝了本次${what}请求，当前账号不能调整展示数据。`,
      };
    }
    return { forbidden: false, text: e.message || fallback };
  }
  return { forbidden: false, text: fallback };
}

async function load() {
  const id = props.workerId;
  if (!id) return;
  loading.value = true;
  loadError.value = null;
  loadForbidden.value = false;
  stats.value = null;
  try {
    const s = await fetchWorkerStats(id);
    stats.value = s;
    // 已设展示值 → 回填；未设（null）→ **留空**（= 跟随真实）
    ordersRaw.value = s.display.completedOrders === null ? '' : String(s.display.completedOrders);
    rateRaw.value = s.display.satisfiedRate === null ? '' : String(s.display.satisfiedRate);
  } catch (e) {
    const d = describeError(e, '读取展示数据失败', '读取');
    loadError.value = d.text;
    loadForbidden.value = d.forbidden;
  } finally {
    loading.value = false;
  }
}

watch(
  () => [props.show, props.workerId] as const,
  ([show]) => {
    if (show) void load();
  },
);

// ---------------------------------------------------------------- 解析 / 预览
const ordersParse = computed(() => parseOrdersInput(ordersRaw.value));
const rateParse = computed(() => parseRateInput(rateRaw.value));
const hasInvalid = computed(() => ordersParse.value.kind === 'invalid' || rateParse.value.kind === 'invalid');

/** 待提交的展示值（留空 = null = 跟随真实） */
const draft = computed<{ completedOrders: number | null; satisfiedRate: number | null }>(() => ({
  completedOrders: ordersParse.value.kind === 'ok' ? ordersParse.value.value : null,
  satisfiedRate: rateParse.value.kind === 'ok' ? rateParse.value.value : null,
}));

/** 表单是否被改动过（含"输入不合法"——那种情况必须走本地预览，才能把不合法提示出来） */
const dirty = computed(() => {
  const s = stats.value;
  if (!s) return false;
  if (hasInvalid.value) return true;
  return (
    draft.value.completedOrders !== s.display.completedOrders ||
    draft.value.satisfiedRate !== s.display.satisfiedRate
  );
});

/** 真实值（只读） */
const realView = computed(() => {
  const s = stats.value;
  if (!s) return { orders: '—', rate: '—' };
  return {
    orders: ordersText(s.real.completedOrders),
    rate: satisfiedRateText(s.real.satisfiedRate, s.real.reviewCount),
  };
});

/** 「最终生效值」实时预览：未改动 → 服务端 effective；有改动 → 本地即时算 */
const effective = computed(() => {
  const s = stats.value;
  if (s && !dirty.value) {
    return {
      orders: ordersText(s.effective.completedOrders),
      rate: satisfiedRateText(s.effective.satisfiedRate, s.effective.reviewCount),
      fromServer: true,
    };
  }
  const o = ordersParse.value;
  const r = rateParse.value;
  return {
    orders: o.kind === 'blank' ? realView.value.orders : o.kind === 'invalid' ? '输入不合法' : ordersText(o.value),
    rate: r.kind === 'blank' ? realView.value.rate : r.kind === 'invalid' ? '输入不合法' : rateText(r.value),
    fromServer: false,
  };
});

/** 每个字段自己的状态一句话（把"留空 = 跟随真实"钉在字段旁边，而不是只写在说明里） */
const ordersState = computed(() => {
  const p = ordersParse.value;
  if (p.kind === 'invalid') return '无法保存：请先修正';
  if (p.kind === 'blank') return `跟随真实（真实值 ${realView.value.orders}）`;
  return `将展示为 ${ordersText(p.value)}`;
});
const rateState = computed(() => {
  const p = rateParse.value;
  if (p.kind === 'invalid') return '无法保存：请先修正';
  if (p.kind === 'blank') return `跟随真实（真实值 ${realView.value.rate}）`;
  return `将展示为 ${rateText(p.value)}`;
});

const canSubmit = computed(() => !!stats.value && !hasInvalid.value && dirty.value);

const submitBlockHint = computed(() => {
  if (!stats.value) return '';
  if (hasInvalid.value) return '请先修正上面标红的输入';
  if (!dirty.value) return '两个展示值都没有改动（留空 = 跟随真实）';
  return '';
});

// ---------------------------------------------------------------- 恢复 / 保存
/** 恢复跟随真实：**清空两个字段**（真正的生效仍走「保存」那一次二次确认） */
function restoreFollowReal() {
  ordersRaw.value = '';
  rateRaw.value = '';
}

function confirmContent(): string[] {
  const s = stats.value;
  if (!s) return [];
  const restore = draft.value.completedOrders === null && draft.value.satisfiedRate === null;
  const parts: string[] = [
    `这会让用户看到：接单 ${effective.value.orders} · 好评率 ${effective.value.rate}；而不是真实的：接单 ${realView.value.orders} · 好评率 ${realView.value.rate}（评价 ${s.real.reviewCount} 条）。`,
  ];
  if (restore) {
    parts.push('本次为「恢复跟随真实」：两个展示值都清空，客户端重新显示真实数据。');
  } else {
    const byField: string[] = [];
    if (draft.value.completedOrders !== null) {
      byField.push(`接单次数展示为 ${ordersText(draft.value.completedOrders)}（真实 ${ordersText(s.real.completedOrders)}）`);
    }
    if (draft.value.satisfiedRate !== null) {
      byField.push(`好评率展示为 ${rateText(draft.value.satisfiedRate)}（真实 ${realView.value.rate}）`);
    }
    parts.push(`本次设置：${byField.length ? byField.join('；') : '两个展示值都留空 = 全部跟随真实。'}`);
  }
  parts.push('评价内容一律真实、不可编辑 —— 本次只改「接单次数」与「好评率」两个展示数字。');
  parts.push('这是用户可见的对外数据，提交后会写入操作日志。');
  return parts;
}

function askSave() {
  if (!canSubmit.value || saving.value) return;
  const lines = confirmContent();
  dialog.warning({
    title: '确认修改展示数据',
    // 弹层内容由 dialog provider 渲染（不在本组件的 scoped 作用域里）→ 用内联样式，不依赖类名
    content: () =>
      h('div', { style: 'line-height:1.7' }, [
        h('p', { style: 'margin:0 0 8px;font-weight:600' }, lines[0]),
        h(
          'ul',
          { style: 'margin:0;padding-left:18px' },
          lines.slice(1).map((t) => h('li', { style: 'margin-bottom:4px' }, t)),
        ),
      ]),
    positiveText: '确认保存',
    negativeText: '取消',
    onPositiveClick: () => {
      void doSave();
    },
  });
}

async function doSave() {
  const id = props.workerId;
  if (!id || !stats.value) return;
  saving.value = true;
  try {
    const next = await saveWorkerDisplayStats(id, {
      completedOrders: draft.value.completedOrders,
      satisfiedRate: draft.value.satisfiedRate,
    });
    // 服务端按契约会回传更新后的 stats；未回传时不做本地猜测（下次打开本窗会重新 GET）
    if (next) stats.value = next;
    emit('saved');
    visible.value = false;
  } catch (e) {
    const d = describeError(e, '保存失败', '保存');
    if (d.forbidden) loadForbidden.value = true;
    message.error(d.text);
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <n-modal
    v-model:show="visible"
    preset="card"
    style="width: 620px"
    :title="`调整展示数据 · ${workerLabel || '打手'}`"
    :mask-closable="!saving"
  >
    <n-spin :show="loading">
      <!-- 读取失败：403 单独给"需要超管权限"，其余给原始中文原因（不谎报成"加载失败"） -->
      <div v-if="loadError" class="err-block" :class="{ 'is-perm': loadForbidden }">
        <p class="err-title">{{ loadForbidden ? '无权限' : '读取失败' }}</p>
        <p class="err-text">{{ loadError }}</p>
        <p class="err-text">展示数据的读取与写入都由服务端按权限点拦截；这里只是把结果说清楚，不是把权限藏起来。</p>
      </div>

      <template v-if="stats">
        <!-- ① 真实值（只读） -->
        <section class="sec">
          <div class="sec-head">
            <h4 class="sec-title">真实值</h4>
            <span class="sec-tag">只读 · 系统实时统计</span>
          </div>
          <p class="sec-line">
            接单 <b>{{ realView.orders }}</b>
            <span class="dot">·</span>
            评价 <b>{{ stats.real.reviewCount }} 条</b>
            <span class="dot">·</span>
            好评率 <b>{{ realView.rate }}</b>
          </p>
          <p class="sec-hint">来自订单与真实评价的实时统计，管理端无法修改。</p>
        </section>

        <!-- ② 展示值（可填） -->
        <section class="sec">
          <div class="sec-head">
            <h4 class="sec-title">展示值</h4>
            <span class="sec-tag">可由管理端设置</span>
          </div>
          <n-form label-placement="left" label-width="88" :show-feedback="true">
            <n-form-item
              label="接单次数"
              :validation-status="ordersParse.kind === 'invalid' ? 'error' : undefined"
              :feedback="ordersParse.kind === 'invalid' ? ordersParse.message : ''"
            >
              <div class="field">
                <div class="field-line">
                  <n-input v-model:value="ordersRaw" class="num-input" placeholder="留空 = 跟随真实" />
                  <span class="unit">次</span>
                </div>
                <span class="field-state">{{ ordersState }}</span>
              </div>
            </n-form-item>
            <n-form-item
              label="好评率"
              :validation-status="rateParse.kind === 'invalid' ? 'error' : undefined"
              :feedback="rateParse.kind === 'invalid' ? rateParse.message : ''"
            >
              <div class="field">
                <div class="field-line">
                  <n-input v-model:value="rateRaw" class="num-input" placeholder="留空 = 跟随真实" />
                  <span class="unit">%</span>
                </div>
                <span class="field-state">{{ rateState }}</span>
              </div>
            </n-form-item>
          </n-form>
          <p class="sec-hint">
            <b>留空 = 跟随真实</b>（不是填 0）：两个都留空即完全使用真实数据。可填范围 ——
            接单次数 {{ ORDERS_MIN }}–{{ ORDERS_MAX }} 的整数；好评率 {{ RATE_MIN }}.0–{{ RATE_MAX }}.0 一位小数
            （百分数口径：填 98.2 就是 98.2%）。超范围前端直接拦下，服务端也会拦。
          </p>
          <n-button size="small" quaternary :disabled="saving || !stats" @click="restoreFollowReal">
            恢复跟随真实
          </n-button>
          <span class="restore-hint">清空上面两个字段；点「保存」后才真正生效。</span>
        </section>

        <!-- ③ 最终生效（预览） -->
        <section class="sec">
          <div class="sec-head">
            <h4 class="sec-title">最终生效（预览）</h4>
            <span class="sec-tag">{{ effective.fromServer ? '服务端当前值' : '本地实时预览' }}</span>
          </div>
          <p class="sec-line is-strong">
            接单 <b>{{ effective.orders }}</b>
            <span class="dot">·</span>
            好评率 <b>{{ effective.rate }}</b>
          </p>
          <p class="sec-hint">客户端「找陪玩」与打手主页显示的就是这一行；保存后下一次请求即生效。</p>
        </section>

        <p class="foot-note">
          评价内容一律真实：本窗只调整「接单次数」与「好评率」两个展示数字，不提供任何评价编辑入口。
        </p>
      </template>
    </n-spin>

    <template #footer>
      <div class="foot">
        <span class="foot-hint">{{ submitBlockHint }}</span>
        <div class="foot-btns">
          <n-button :disabled="saving" @click="visible = false">取消</n-button>
          <n-button type="primary" :loading="saving" :disabled="!canSubmit" @click="askSave">保存</n-button>
        </div>
      </div>
    </template>
  </n-modal>
</template>

<style scoped>
/*
 * 版式：组内紧（8–10）/ 组间松（20–24），三级说明文字走 --color-text-tertiary。
 * 颜色与圆角**一律读 token**（禁写死十六进制）；间距走 4dp 网格。
 */
.sec + .sec {
  margin-top: var(--space-6);
}
.sec {
  padding-bottom: var(--space-4);
  border-bottom: 1px solid var(--color-divider);
}
.sec:last-of-type {
  border-bottom: none;
  padding-bottom: 0;
}
.sec-head {
  display: flex;
  align-items: baseline;
  gap: var(--space-2);
  margin-bottom: var(--space-2);
}
.sec-title {
  margin: 0;
  font-size: 14px;
  font-weight: 650;
  color: var(--color-text-primary);
}
.sec-tag {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.sec-line {
  margin: 0;
  font-size: 13.5px;
  color: var(--color-text-secondary);
}
.sec-line b {
  color: var(--color-text-primary);
}
.sec-line.is-strong {
  font-size: 14px;
}
.sec-line.is-strong b {
  color: var(--color-primary-text);
}
.dot {
  margin: 0 var(--space-2);
  color: var(--color-text-tertiary);
}
.sec-hint {
  margin: var(--space-2) 0 0;
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-text-tertiary);
}
.sec-hint b {
  color: var(--color-text-secondary);
}

/* 输入行：数字框定宽 + 单位贴右（单位是读的口径提示，不是装饰） */
.field {
  display: flex;
  flex-direction: column;
  gap: var(--space-1);
  padding: 4px 0;
}
.field-line {
  display: flex;
  align-items: center;
  gap: var(--space-2);
}
.num-input {
  width: 168px;
}
.unit {
  font-size: 13px;
  color: var(--color-text-secondary);
}
/* 字段旁的一行状态："跟随真实（真实值 …）" / "将展示为 …" —— 把留空语义钉在字段上 */
.field-state {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.restore-hint {
  margin-left: var(--space-2);
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.foot-note {
  margin: var(--space-5) 0 0;
  padding: var(--space-2) var(--space-3);
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-text-secondary);
  background: var(--color-bg-sunken);
  border-radius: var(--radius-tag);
}

/* 读取失败 / 无权限：不给卡片阴影，一块浅琥珀底说明（与充值页缺权限说明同姿势） */
.err-block {
  margin-bottom: var(--space-4);
  padding: var(--space-2) var(--space-3);
  border-radius: var(--radius-tag);
  background: var(--color-gold-soft);
}
.err-title {
  margin: 0;
  font-size: 13px;
  font-weight: 650;
  color: var(--color-text-primary);
}
.err-text {
  margin: var(--space-1) 0 0;
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-text-secondary);
}

.foot {
  display: flex;
  align-items: center;
  gap: var(--space-3);
}
.foot-hint {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  color: var(--color-text-tertiary);
  text-align: left;
}
.foot-btns {
  display: flex;
  gap: var(--space-2);
}
</style>
