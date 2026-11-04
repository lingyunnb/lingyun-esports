<script setup lang="ts">
/**
 * 品牌雪山标（祁连山电竞）
 * ============================================================================
 * 复刻自 Flutter 侧 `AppMountainMark`（`apps/packages/core/lib/src/widgets/app_ui.dart`
 * 的 `_MountainPainter`），**只搬形态不搬代码**：
 *   · 主轴双峰折线：(0,1) → (0.30,0.18) → (0.46,0.62) → (0.66,0.30) → (1,1)
 *   · 线宽 = 宽 × 0.11，clamp 到 1.6–3.0；圆头圆角
 *   · 雪顶两层折线**只在雪顶色与主线不同色时才画**（同色时与主峰完全重合 = 纯冗余绘制）
 *   · 固有宽高比 0.72（Flutter 侧单测锁死的就是这个比例）
 *
 * viewBox 用 100×72：线宽就是确定的 11（= 100 × 0.11，正好落在 clamp 区间内），
 * 缩放由浏览器按渲染宽度做 —— 与 Flutter 侧 `size × 0.72` 的定尺等价。
 *
 * 为什么用 SVG 而不是 PNG：仓库里没有现成的雪山 PNG（Flutter 两端的 assets 目录只有 Android
 * 启动图标），而这块形态本身是**纯路径**（Flutter 侧就是 CustomPaint 画的，无图片依赖）
 * → SVG 是逐字等价的复刻，也顺带保证深色/浅色下都不糊。
 *
 * 素材来源合规：形态取自**本仓库**的 Flutter 组件，未使用任何第三方插画/截图。
 */
import { computed } from 'vue';

const props = withDefaults(
  defineProps<{
    /** 宽度（px）；高度自动 = size × 0.72 */
    size?: number;
    /** 主线颜色 */
    color?: string;
    /** 雪顶颜色；不传 = 与主线同色 → 不叠第二层（与 Flutter 侧同规则） */
    snowColor?: string;
  }>(),
  { size: 22, color: 'currentColor', snowColor: undefined },
);

const H = computed(() => Math.round(props.size * 0.72));
const showSnow = computed(() => !!props.snowColor && props.snowColor !== props.color);
</script>

<template>
  <svg
    class="mountain-mark"
    :width="size"
    :height="H"
    viewBox="0 0 100 72"
    fill="none"
    role="img"
    aria-label="祁连山电竞"
  >
    <!-- 主轴折线（双峰）：stroke-width 11 = 100 × 0.11 -->
    <path
      d="M0 72 L30 12.96 L46 44.64 L66 21.6 L100 72"
      :stroke="color"
      stroke-width="11"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
    <!-- 雪顶：只有雪顶色与主线不同色时才画（11 × 0.92 = 10.12） -->
    <template v-if="showSnow">
      <path
        d="M19 31.68 L30 12.96 L41 31.68"
        :stroke="snowColor"
        stroke-width="10.12"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <path
        d="M58 33.12 L66 21.6 L74 33.12"
        :stroke="snowColor"
        stroke-width="10.12"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </template>
  </svg>
</template>

<style scoped>
.mountain-mark {
  display: block;
  flex: none;
}
</style>
