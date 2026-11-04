<script setup lang="ts">
/**
 * 公用页头（白底 + 发丝线；返回箭头可选）
 * 白底为主定案：**不用彩色标题栏**，品牌色只出现在文字/图标与按钮上。
 */
import { useRouter } from 'vue-router';

withDefaults(
  defineProps<{
    title?: string;
    back?: boolean;
    /** 右侧插槽占位（如"客服""全部"） */
    right?: boolean;
  }>(),
  { title: '', back: true, right: false },
);

const router = useRouter();
function goBack() {
  // 直接进来（无历史）时回首页，避免出现"点了没反应"的死页
  if (window.history.length > 1) router.back();
  else router.replace({ name: 'home' });
}
</script>

<template>
  <header class="h5-head">
    <button v-if="back" class="h5-head__back" aria-label="返回" @click="goBack">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="m15 5-7 7 7 7" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <h1 class="h5-head__title">{{ title }}</h1>
    <slot name="right" />
  </header>
</template>

<style scoped>
.h5-head__back {
  flex: 0 0 auto; width: 32px; height: 32px; margin-left: -6px;
  display: grid; place-items: center; background: none; border: 0; padding: 0;
  color: var(--g1); cursor: pointer;
}
</style>
