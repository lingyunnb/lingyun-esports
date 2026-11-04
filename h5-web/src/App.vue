<script setup lang="ts">
/**
 * 应用外壳
 * ============================================================================
 * - 底部导航固定五格：**服务 · 订单 · ＋下单 · 消息 · 我的**（结构规则 3）
 *   「消息」在 H5 首期是**占位提示**（实时聊天属二期），仍保留格子以保持与 App 一致的导航心智。
 * - 页头由各页自绘（`meta.headless`），外壳**不**统一加标题栏 ——
 *   因为首页/详情页的头部结构差异大，统一加会处处要"豁免"。
 */
import { computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';

const route = useRoute();
const router = useRouter();

const tab = computed(() => (route.meta as { tab?: string }).tab || '');
/** 只有"带 tab 的四个主页面"才显示底栏（二级页不显示，避免入口重复） */
const showNav = computed(() => !!tab.value);

function go(name: string) {
  router.push({ name }).catch(() => {});
}
</script>

<template>
  <router-view v-slot="{ Component }">
    <component :is="Component" />
  </router-view>

  <nav v-if="showNav" class="h5-nav">
    <button class="h5-nav__i" :class="{ 'h5-nav__i--on': tab === 'home' }" @click="go('home')">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <path d="M3 10.5 12 3l9 7.5" /><path d="M5 9.5V21h14V9.5" />
      </svg>
      <span>服务</span>
    </button>

    <button class="h5-nav__i" :class="{ 'h5-nav__i--on': tab === 'orders' }" @click="go('orders')">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <rect x="5" y="3" width="14" height="18" rx="2" /><path d="M9 8h6M9 12h6M9 16h4" />
      </svg>
      <span>订单</span>
    </button>

    <button class="h5-nav__i h5-nav__i--mid" @click="go('products')">
      <span class="dot">＋</span>
      <span>下单</span>
    </button>

    <button class="h5-nav__i" :class="{ 'h5-nav__i--on': tab === 'msg' }" @click="go('announcements')">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <path d="M21 12a8 8 0 0 1-8 8H7l-4 3v-6.5A8 8 0 0 1 11 4h2a8 8 0 0 1 8 8Z" />
      </svg>
      <span>消息</span>
    </button>

    <button class="h5-nav__i" :class="{ 'h5-nav__i--on': tab === 'mine' }" @click="go('profile')">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <circle cx="12" cy="8" r="3.6" /><path d="M4.5 20.5c1.4-3.6 4.2-5.4 7.5-5.4s6.1 1.8 7.5 5.4" />
      </svg>
      <span>我的</span>
    </button>
  </nav>
</template>
