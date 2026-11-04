<!--
  打手六维评分 · 手填弹窗（负责人 2026-10-18「六个数据和图要可以在管理端改」）

  ## 为什么需要它
  老板评价是**自愿**的：没评价 → `worker_rating_agg` 无行 → 陪玩主页六轴全显示 `--`。
  运营需要一个**只影响展示**的手填通道，让新打手/冷门打手的主页雷达图也有数据。

  ## 六维
  评分 / 技术水平 / 情绪价值 / 抗压能力 / 声音听感 / 综合表现（顺序 = 雷达图六轴）。
  每维可单独「清除」回到自动（显式传 null = 清除；省略 = 不改）。

  ## ⚠️ 只影响展示，不影响等级
  等级判定只读 `worker_rating_agg` / `worker_stats` / `order_review`，手填值一律不参与升级。
  这条在弹窗里**必须显式写在界面上**，否则运营会以为改分能升级。
-->
<template>
  <NModal
    :show="show"
    preset="card"
    :title="`编辑六维评分 · ${workerName || ''}`"
    style="width: 460px"
    :bordered="false"
    @update:show="(v: boolean) => emit('update:show', v)"
  >
    <div class="rating-modal">
      <NAlert type="info" :bordered="false" class="rating-alert">
        <template #header>只影响展示，不影响等级</template>
        手填值只用于陪玩主页的雷达图。等级（初出/立足/扬名/称雄/宗师）只按真实评价与接单数据判定，
        改这里<b>不会</b>让打手升级。
      </NAlert>

      <div class="rating-status">
        <span>当前状态：</span>
        <NTag v-if="samples > 0" type="success" size="small">老板评价聚合 {{ samples }} 条</NTag>
        <NTag v-else type="default" size="small">暂无老板评价</NTag>
      </div>

      <div v-for="dim in RATING_DIMS6" :key="dim" class="rating-row">
        <span class="rating-label">{{ DIM_LABELS[dim] }}</span>
        <span class="rating-source">{{ sourceText(sources[dim]) }}</span>
        <NInputNumber
          v-model:value="form[dim]"
          :min="0"
          :max="10"
          :step="0.01"
          :precision="2"
          size="small"
          placeholder="未设"
          class="rating-input"
        />
        <NButton size="tiny" quaternary :disabled="form[dim] === null" @click="clearDim(dim)">
          清除
        </NButton>
      </div>

      <p class="rating-hint">清除 = 该维回到自动值；六项都可留空。</p>
    </div>

    <template #footer>
      <div class="rating-footer">
        <NButton @click="emit('update:show', false)">取消</NButton>
        <NButton type="primary" :loading="saving" @click="onSave">保存</NButton>
      </div>
    </template>
  </NModal>
</template>

<script setup lang="ts">
import { computed, h, reactive, ref, watch } from 'vue'
import { NAlert, NButton, NInputNumber, NModal, NTag, useMessage } from 'naive-ui'
import {
  DIM_LABELS,
  RATING_DIMS6,
  fetchWorkerRatingManual,
  saveWorkerRatingManual,
  sourceText,
  type RatingDim6,
  type RatingSource,
  type RatingValues,
} from '@/api/worker-rating-manual'
import { ApiException } from '@/api/client'

const props = defineProps<{
  show: boolean
  workerId: string
  workerName?: string
}>()
const emit = defineEmits<{
  (e: 'update:show', v: boolean): void
  (e: 'saved'): void
}>()

const message = useMessage()
const saving = ref(false)
const samples = ref(0)
const sources = reactive<Record<RatingDim6, RatingSource>>({
  score: 'none',
  skill: 'none',
  emotion: 'none',
  stress: 'none',
  voice: 'none',
  shop: 'none',
})
const form = reactive<RatingValues>({
  score: null,
  skill: null,
  emotion: null,
  stress: null,
  voice: null,
  shop: null,
})

/** 打开时拉一次当前值（手填 + 生效值 + 来源） */
watch(
  () => [props.show, props.workerId] as const,
  async ([show, id]) => {
    if (!show || !id) return
    try {
      const d = await fetchWorkerRatingManual(id)
      samples.value = d.samples ?? 0
      for (const dim of RATING_DIMS6) {
        form[dim] = d.manual?.[dim] ?? null
        sources[dim] = d.sources?.[dim] ?? 'none'
      }
    } catch (e) {
      message.error(e instanceof ApiException ? e.message : '读取六维评分失败')
    }
  },
  { immediate: true },
)

/** 清除某一维（置 null，保存时显式传 null = 回到自动） */
function clearDim(dim: RatingDim6) {
  form[dim] = null
}

async function onSave() {
  saving.value = true
  try {
    // 六项全传（null 表示清除）：语义明确，避免"省略 = 不改"与"清空"混淆
    const patch: Record<string, number | null> = {}
    for (const dim of RATING_DIMS6) patch[dim] = form[dim]
    const d = await saveWorkerRatingManual(props.workerId, patch)
    samples.value = d.samples ?? 0
    for (const dim of RATING_DIMS6) sources[dim] = d.sources?.[dim] ?? 'none'
    message.success('六维评分已保存（客户端下一次请求即生效，改动已写操作日志）')
    emit('saved')
    emit('update:show', false)
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败')
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
.rating-modal {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.rating-alert {
  font-size: 12px;
  line-height: 1.6;
}
.rating-status {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: #5a6879;
}
.rating-row {
  display: grid;
  grid-template-columns: 76px 44px 1fr 48px;
  align-items: center;
  gap: 8px;
}
.rating-label {
  font-size: 13px;
  color: #14202e;
}
.rating-source {
  font-size: 11px;
  color: #8492a4;
}
.rating-input {
  width: 100%;
}
.rating-hint {
  margin: 0;
  font-size: 11px;
  color: #8492a4;
}
.rating-footer {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}
</style>
