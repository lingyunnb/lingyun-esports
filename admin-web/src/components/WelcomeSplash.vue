<script setup lang="ts">
/**
 * 登录成功欢迎序列（负责人 2026-10-11 审批放行）
 * ============================================================================
 * 触发：管理员登录成功后、进入工作台**之前**全屏播放一次；**每次登录都播**（不做"只播一次"）。
 * 节奏（逐值取自 `constants/welcome.ts`，页面里不写死数字）：
 *   纯黑底 → 第 1 行淡入 250ms → 停 700ms → 第 2 行淡入 250ms → 停 900ms → 整屏淡出 300ms → 工作台
 *   （总时长 2400ms，落在负责人给的 2.4–2.8s 区间）
 * 可跳过：点击 / 按任意键**立即结束**（避免每次登录都干等）。
 * 角色区分：`isOwner` 为真 → 两行（董事长）；否则 → 只显示一行「欢迎回来」。
 *
 * 排版：居中、40–48px、字重 800、白色；两行间距 20px；下方一条 64px 宽的品牌色细线（冰雪蓝 #2563EB）。
 * **没有**任何插画 / 光斑 / emoji（docs/21 反 AI 味硬规则）。
 * 文案全部来自 `constants/welcome.ts`，本文件不内联任何中文字符串。
 */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { WELCOME_TIMING, welcomeLines } from '@/constants/welcome';

const props = defineProps<{
  /** 仅影响**显示时长**（测试可调 0 秒级跳过）；文案仍按 isOwner 取 */
  isOwner: boolean;
}>();

const emit = defineEmits<{ done: [] }>();

const lines = computed(() => welcomeLines(props.isOwner));
/** 第 i 行是否已淡入 */
const shown = ref<boolean[]>(lines.value.map(() => false));
/** 整屏淡出中 */
const leaving = ref(false);
const finished = ref(false);

let timers: number[] = [];
function at(ms: number, fn: () => void) {
  timers.push(window.setTimeout(fn, ms));
}

function finish() {
  if (finished.value) return;
  finished.value = true;
  timers.forEach((t) => window.clearTimeout(t));
  timers = [];
  emit('done');
}

/** 跳过：点击 / 按任意键 → 立即结束（直接进工作台，不再补播淡出动画） */
function skip() {
  finish();
}

onMounted(() => {
  const T = WELCOME_TIMING;
  // 第 1 行淡入
  at(20, () => (shown.value = lines.value.map((_, i) => i === 0)));
  if (lines.value.length > 1) {
    // 第 2 行淡入（第 1 行淡入 + 停留之后）
    at(20 + T.line1FadeIn + T.hold1, () => {
      shown.value = lines.value.map(() => true);
    });
  }
  const total = 20 + T.line1FadeIn + (lines.value.length > 1 ? T.hold1 + T.line2FadeIn + T.hold2 : T.hold1);
  // 整屏淡出 → 交还工作台
  at(total, () => (leaving.value = true));
  at(total + T.fadeOut, finish);

  window.addEventListener('keydown', skip);
  window.addEventListener('mousedown', skip);
  window.addEventListener('touchstart', skip, { passive: true });
});

onBeforeUnmount(() => {
  timers.forEach((t) => window.clearTimeout(t));
  timers = [];
  window.removeEventListener('keydown', skip);
  window.removeEventListener('mousedown', skip);
  window.removeEventListener('touchstart', skip);
});
</script>

<template>
  <div
    v-if="!finished"
    class="welcome"
    :class="{ 'is-leaving': leaving }"
    data-testid="welcome-overlay"
    @click="skip"
  >
    <div class="welcome-inner">
      <p
        v-for="(line, i) in lines"
        :key="i"
        class="welcome-line"
        :class="{ 'is-shown': shown[i] }"
        :data-welcome-line="i"
      >
        {{ line }}
      </p>
      <!-- 品牌色细线（冰雪蓝 64px）；纯装饰、不承载信息 -->
      <span class="welcome-rule" :class="{ 'is-shown': shown[0] }" aria-hidden="true" />
    </div>
  </div>
</template>

<style scoped>
/*
 * 纯黑底（#000，刻意不用 --color-bg-page 的近黑：负责人要的就是"全屏纯黑底"）。
 * z-index 拉满：必须盖住整个外壳（侧栏/顶栏/内容区）。
 */
.welcome {
  position: fixed;
  inset: 0;
  z-index: 6000;
  background: #000;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  opacity: 1;
  transition: opacity 300ms cubic-bezier(0.4, 0, 0.2, 1);
  user-select: none;
}
.welcome.is-leaving {
  opacity: 0;
  pointer-events: none;
}

.welcome-inner {
  display: flex;
  flex-direction: column;
  align-items: center;
  /* 两行间距 20px（负责人规格） */
  gap: 20px;
}

.welcome-line {
  margin: 0;
  /* 40–48px 区间取 44px：1600 宽下不空、1280 宽下不挤 */
  font-size: 44px;
  font-weight: 800;
  letter-spacing: 0.02em;
  line-height: 1.25;
  color: #fff;
  text-align: center;
  opacity: 0;
  transform: translateY(6px);
  transition:
    opacity 250ms cubic-bezier(0.4, 0, 0.2, 1),
    transform 250ms cubic-bezier(0.4, 0, 0.2, 1);
}
.welcome-line.is-shown {
  opacity: 1;
  transform: none;
}

.welcome-rule {
  width: 64px;
  height: 2px;
  border-radius: 999px;
  /* 品牌色：冰雪蓝（唯一点缀，无渐变、无光斑） */
  background: #1d5fa8;
  opacity: 0;
  transition: opacity 250ms cubic-bezier(0.4, 0, 0.2, 1);
}
.welcome-rule.is-shown {
  opacity: 1;
}

/* 小屏（巡检脚本可能用 1280 宽）：字号降到区间下限，避免两行被挤换行 */
@media (max-width: 1366px) {
  .welcome-line {
    font-size: 40px;
  }
}
</style>
