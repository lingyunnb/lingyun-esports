<script setup lang="ts">
// 页面级错误边界（最小兜底）：某个页面组件抛错时只影响内容区（显示错误+重试），
// 不再让整个管理端白屏；同时把错误打到控制台便于定位根因。
import { NButton, NResult } from 'naive-ui';
import { onErrorCaptured, ref } from 'vue';

const err = ref<Error | null>(null);
const route = ref<string>('');

onErrorCaptured((e, _instance, info) => {
  err.value = e as Error;
  route.value = info;
  console.error('[PageErrorBoundary] 页面渲染异常:', e, info);
  return false; // 阻止继续向上冒泡导致整站崩溃
});

function retry() {
  err.value = null;
  window.location.reload();
}
</script>

<template>
  <n-result
    v-if="err"
    status="error"
    title="页面加载失败"
    :description="`${err.message}${route ? `（${route}）` : ''}`"
  >
    <template #footer>
      <n-button type="primary" @click="retry">刷新重试</n-button>
    </template>
  </n-result>
  <slot v-else />
</template>
