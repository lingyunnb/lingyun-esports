<script setup lang="ts">
// 官网管理（admin:site:edit）：官网（/site）全部内容高度自定义
// —— 标题/俱乐部介绍/宣传视频/图片展示区/下载说明/页脚，保存后官网立即生效
import { ApiException, request } from '@/api/client';
import MediaUploadField from '@/components/MediaUploadField.vue';
import { NButton, NCard, NDynamicInput, NForm, NFormItem, NInput, NInputGroup, NInputNumber, NSpace, NTabPane, NTabs, NText, useMessage } from 'naive-ui';
import { onMounted, ref } from 'vue';

const message = useMessage();
const saving = ref(false);

interface GalleryItem {
  title: string;
  url: string | null;
}

interface SiteContent {
  siteTitle: string;
  logoText: string;
  heroTitle: string;
  heroSubtitle: string;
  heroBgUrl: string;
  clubTitle: string;
  clubParagraphs: string[];
  clubImageUrl: string | null;
  videoTitle: string;
  videoUrl: string;
  videoPosterUrl: string | null;
  galleryTitle: string;
  galleryItems: GalleryItem[];
  downloadTitle: string;
  downloadNote: string;
  footerText: string;
  contactText: string;
}

const form = ref<SiteContent>({
  siteTitle: '', logoText: '', heroTitle: '', heroSubtitle: '', heroBgUrl: '',
  clubTitle: '', clubParagraphs: [], clubImageUrl: null,
  videoTitle: '', videoUrl: '', videoPosterUrl: null,
  galleryTitle: '', galleryItems: [],
  downloadTitle: '', downloadNote: '', footerText: '', contactText: '',
});

async function load() {
  try {
    const data = await request<Partial<SiteContent>>('GET', '/admin/site');
    form.value = { ...form.value, ...(data ?? {}), clubParagraphs: data?.clubParagraphs ?? [], galleryItems: data?.galleryItems ?? [] };
  } catch (e) {
    if (e instanceof ApiException) message.error(e.message);
  }
}

/// 上传控件存 media id，官网需要 URL：数字 id 转公开通道路径（/media/public/{id}）
function toPath(v: string | null | undefined): string {
  const s = String(v ?? '').trim();
  if (!s) return '';
  if (/^\d+$/.test(s)) return `/media/public/${s}`;
  return s;
}

async function save() {
  saving.value = true;
  try {
    const content = {
      ...form.value,
      clubImageUrl: toPath(form.value.clubImageUrl),
      videoPosterUrl: toPath(form.value.videoPosterUrl),
      galleryItems: form.value.galleryItems.map((g) => ({ title: g.title, url: toPath(g.url) })),
    };
    await request('PUT', '/admin/site', { content });
    message.success('已保存，官网立即生效');
  } catch (e) {
    if (e instanceof ApiException) message.error(e.message);
  } finally {
    saving.value = false;
  }
}

onMounted(load);
</script>

<template>
  <div style="max-width: 880px">
    <NCard title="官网管理" style="margin-bottom: 16px">
      <template #header-extra>
        <NSpace align="center">
          <NText depth="3" style="font-size: 13px">
            官网地址：<b>/site</b>（手机打开 <b>https://&lt;隧道域名&gt;/site/</b>）
          </NText>
          <NButton type="primary" :loading="saving" @click="save">保存全部</NButton>
        </NSpace>
      </template>

      <NTabs type="line" animated>
        <NTabPane name="hero" tab="首屏与导航">
          <NForm label-placement="left" label-width="110">
            <NFormItem label="网站标题">
              <NInput v-model:value="form.siteTitle" placeholder="浏览器标签页标题" />
            </NFormItem>
            <NFormItem label="导航 Logo">
              <NInput v-model:value="form.logoText" placeholder="左上角文字，如 祁连山电竞" />
            </NFormItem>
            <NFormItem label="首屏大标题">
              <NInput v-model:value="form.heroTitle" placeholder="如：祁连山电竞俱乐部" />
            </NFormItem>
            <NFormItem label="首屏副标题">
              <NInput v-model:value="form.heroSubtitle" type="textarea" :rows="2" placeholder="一句话介绍俱乐部" />
            </NFormItem>
          </NForm>
        </NTabPane>

        <NTabPane name="about" tab="俱乐部介绍">
          <NForm label-placement="left" label-width="110">
            <NFormItem label="区块标题">
              <NInput v-model:value="form.clubTitle" placeholder="如：关于俱乐部" />
            </NFormItem>
            <NFormItem label="介绍段落">
              <NDynamicInput v-model:value="form.clubParagraphs" :on-create="() => ''" show-sort-button>
                <template #default="{ value }">
                  <NInput
                    :value="value"
                    type="textarea"
                    :rows="3"
                    placeholder="一段介绍文字"
                    @update:value="(v: string) => { const i = form.clubParagraphs.indexOf(value); if (i >= 0) form.clubParagraphs[i] = v; }"
                  />
                </template>
              </NDynamicInput>
            </NFormItem>
            <NFormItem label="配图">
              <MediaUploadField v-model="form.clubImageUrl" media-type="forum_image" style="width: 100%" />
            </NFormItem>
          </NForm>
        </NTabPane>

        <NTabPane name="video" tab="宣传视频">
          <NForm label-placement="left" label-width="110">
            <NFormItem label="区块标题">
              <NInput v-model:value="form.videoTitle" placeholder="如：俱乐部宣传片" />
            </NFormItem>
            <NFormItem label="视频地址">
              <NInput v-model:value="form.videoUrl" placeholder="默认 /site/assets/promo-bgm.mp4 或任意 http(s) 地址" />
            </NFormItem>
            <NFormItem label="视频封面">
              <NInput v-model="form.videoPosterUrl" placeholder="可选：播放前显示的封面图" />
            </NFormItem>
          </NForm>
        </NTabPane>

        <NTabPane name="gallery" tab="图片展示区">
          <NForm label-placement="left" label-width="110">
            <NFormItem label="区块标题">
              <NInput v-model:value="form.galleryTitle" placeholder="如：精彩瞬间" />
            </NFormItem>
            <NFormItem label="展示图片">
              <NDynamicInput v-model:value="form.galleryItems" :on-create="() => ({ title: '', url: null })" show-sort-button>
                <template #default="{ value }">
                  <NInputGroup>
                    <NInput :value="value.title" placeholder="图片标题（可选）" style="width: 30%" @update:value="(v: string) => { value.title = v; }" />
                    <MediaUploadField v-model="value.url" media-type="forum_image" style="width: 70%" />
                  </NInputGroup>
                </template>
              </NDynamicInput>
            </NFormItem>
          </NForm>
        </NTabPane>

        <NTabPane name="download" tab="下载区与页脚">
          <NForm label-placement="left" label-width="110">
            <NFormItem label="区块标题">
              <NInput v-model:value="form.downloadTitle" placeholder="如：下载客户端" />
            </NFormItem>
            <NFormItem label="下载说明">
              <NInput v-model:value="form.downloadNote" type="textarea" :rows="3" placeholder="下载区下方说明文字" />
            </NFormItem>
            <NFormItem label="联系方式">
              <NInput v-model:value="form.contactText" placeholder="页脚上方展示的联系/招募信息" />
            </NFormItem>
            <NFormItem label="页脚文字">
              <NInput v-model:value="form.footerText" placeholder="如：© 2026 祁连山电竞俱乐部" />
            </NFormItem>
          </NForm>
        </NTabPane>
      </NTabs>
    </NCard>
  </div>
</template>
