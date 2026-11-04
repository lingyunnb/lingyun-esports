<script setup lang="ts">
/**
 * 全局 Provider：config（主题/语言）→ dialog（useDialog 依赖）→ message（useMessage 依赖）
 * ============================================================================
 * 深色科技风（2026-10-11）：`darkTheme` 变量 + 深浅两套 `themeOverrides`（见 src/theme.ts）。
 * 主题选择在 `stores/theme.ts`（三档：跟随系统 / 浅色 / 深色，落 localStorage），
 * 本文件只负责把它接到 `<n-config-provider>` 上，并把系统深浅变化同步进 store。
 *
 * 顺序不能动：dialog/message 必须在 config-provider **内部**，否则弹层拿不到主题
 * （深色下会出现白底弹窗 = 层级/主题穿帮）。
 */
import { darkTheme, NConfigProvider, NDialogProvider, NMessageProvider, dateZhCN, useOsTheme, zhCN } from 'naive-ui';
import { computed, watch } from 'vue';
import { darkOverrides, lightOverrides } from './theme';
import { useThemeStore } from './stores/theme';

const theme = useThemeStore();
const osTheme = useOsTheme();
// 系统主题变化 → 同步进 store（mode==='auto' 时实时跟随，非 auto 时不生效）
watch(osTheme, (v) => theme.setSystemDark(v === 'dark'), { immediate: true });
// 挂载即把结果写到 <html data-theme>（main.ts 首屏已写过一次，这里是幂等兜底）
theme.syncAttr();

const naiveTheme = computed(() => (theme.isDark ? darkTheme : null));
const overrides = computed(() => (theme.isDark ? darkOverrides : lightOverrides));
</script>

<template>
  <n-config-provider
    :locale="zhCN"
    :date-locale="dateZhCN"
    :theme="naiveTheme"
    :theme-overrides="overrides"
  >
    <n-dialog-provider>
      <n-message-provider>
        <router-view />
      </n-message-provider>
    </n-dialog-provider>
  </n-config-provider>
</template>
