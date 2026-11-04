<script setup lang="ts">
// 媒体上传字段（阶段13）：NUpload 走管理端上传通道，回填 media id，支持预览与移除
// disabled（2026-10-06 充值页）：调用方无 `admin:media:write` 时**禁用上传并给出中文说明** ——
// 与"不做点了才吃 403 的死入口"同一原则（能力不可用就要在界面上说清楚）。
// 默认 false = 既有行为逐字节不变（其它页面不传该 prop 即不受影响）。
//
// ⚠️ 2026-10-07 修「收款码加不了」——**别再把它改回去**：
//   病灶是「选了文件却一个请求都不发」。naive-ui 2.45.3 的上传触发链有**两个开关，缺一不可**：
//     ① `default-upload`（Upload.mjs:425 `if (props.defaultUpload) submit()`）
//        —— 设成 `false` 时，选完文件**永远不会**调 `submit()`，`customRequest` 一次都不执行
//        （旧的 `:default-upload="false"` 就是这样把上传整条断掉的：页面毫无反应、网络面板全空）；
//     ② `:file-list` 必须是**可写**的（Upload.mjs:314 `useMergedState(controlled, uncontrolled)`）
//        —— 传一个只读的 `computed` 会让 n-upload 的 `update:file-list` 被丢弃、`clear()` 也失效，
//        于是即便修好 ①，`submit()` 也扫不到刚选中的 pending 文件（仍不发请求）。
//    现在 = 本地可写 `ref` + `@update:file-list` 回写 + 保留 `default-upload` 默认 true（选完即传）。
//    `show-file-list=false` 只是不渲染它自带的列表；文件在列表里的存在感由本组件的预览图与「移除」承担。
import { ApiException, mediaPreviewPath, protectedMediaUrl, uploadMedia } from '@/api/client';
import { NButton, NImage, NUpload, useMessage } from 'naive-ui';
import type { UploadCustomRequestOptions, UploadFileInfo } from 'naive-ui';
import { computed, onBeforeUnmount, ref, watch } from 'vue';

const props = withDefaults(
  defineProps<{
    /** media id（v-model） */
    modelValue: string | null;
    /** 上传用途类型：product_image/product_video/video_cover/banner/top_worker_avatar/recharge_qr/... */
    mediaType: string;
    /** 接受的文件类型提示 */
    accept?: string;
    /** 调用方是否**没有**上传权限（无 admin:media:write）→ 禁用上传并说明 */
    disabled?: boolean;
  }>(),
  { accept: 'image/*', disabled: false },
);
const emit = defineEmits<{ (e: 'update:modelValue', v: string | null): void }>();
const message = useMessage();

const preview = computed(() => protectedBlob.value ?? mediaPreviewPath(props.modelValue));
const isVideo = computed(() => props.mediaType === 'product_video');

/*
 * 受保护用途（`withdraw_proof` / `recharge_proof` / `complaint_image` 这类）**不能公开直连**：
 * `/media/public/:id` 对它们一律 404，直接渲染 `n-image` 只会得到一张破图（2026-10-11 提现页实测踩到：
 * 管理员上传完打款凭证，缩略图裂开，看着像"上传失败"）。
 * 处理方式与 RechargeView 的凭证预览**同一套**：先试公开路径，失败再换 `protectedMediaUrl()`（带令牌取 blob）；
 * 两条都不通就退成一行说明文字 —— 不把破图丢给运营猜。
 * 公开用途（商品图/收款码…）第一次就成功，走不到这里，**既有行为不变**。
 */
const protectedBlob = ref<string | null>(null);
const previewFailed = ref(false);
const triedProtected = ref(false);

watch(
  () => props.modelValue,
  () => {
    // 换了一张图 → 上一张的兜底状态必须清掉（否则新图会顶着旧图的"裂开"标记）
    if (protectedBlob.value) URL.revokeObjectURL(protectedBlob.value);
    protectedBlob.value = null;
    previewFailed.value = false;
    triedProtected.value = false;
  },
);

async function onPreviewError() {
  const id = props.modelValue;
  if (!id || triedProtected.value) {
    previewFailed.value = true;
    return;
  }
  triedProtected.value = true;
  try {
    protectedBlob.value = await protectedMediaUrl(id);
  } catch {
    previewFailed.value = true; // 两条通道都不通：退成文字说明
  }
}

onBeforeUnmount(() => {
  if (protectedBlob.value) URL.revokeObjectURL(protectedBlob.value);
});
/**
 * n-upload 的文件列表：**必须是可写的本地 ref**（不能是 computed）。
 * 它是 n-upload 判断「有没有 pending 文件要传」「max 到没到」的唯一依据；
 * `@update:file-list` 把 n-upload 每次的变更回写进来，submit() 才看得到刚选中的文件。
 * 预览图不依赖它（下面模板用 v-model 的 modelValue 渲染），所以它始终从空开始也不会丢预览。
 */
const fileList = ref<UploadFileInfo[]>([]);

async function customRequest({ file, onFinish, onError }: UploadCustomRequestOptions) {
  if (props.disabled) {
    onError();
    return;
  }
  const f = file.file as File | undefined;
  if (!f) {
    onError();
    return;
  }
  try {
    const res = await uploadMedia(props.mediaType, f);
    emit('update:modelValue', res.id);
    onFinish();
    message.success('上传成功（已通过服务端校验与压缩）');
  } catch (e) {
    onError();
    message.error(e instanceof ApiException ? e.message : '上传失败');
  }
}

function remove() {
  // 清空内部列表：否则 max=1 已满，移除后按钮会变成"点不动的死按钮"（再选一次也进不来）
  fileList.value = [];
  emit('update:modelValue', null);
}
</script>

<template>
  <div class="media-upload">
    <n-upload
      :custom-request="customRequest"
      v-model:file-list="fileList"
      :show-file-list="false"
      :max="1"
      :accept="accept"
      :disabled="disabled"
    >
      <!-- 槽里的 n-button 不会随 n-upload 的 disabled 自动置灰，必须显式绑（否则看着能点、点了没反应） -->
      <n-button size="small" :disabled="disabled">选择{{ isVideo ? '视频' : '图片' }}上传</n-button>
    </n-upload>
    <template v-if="modelValue">
      <n-image
        v-if="!isVideo && preview && !previewFailed"
        :src="preview"
        width="80"
        height="80"
        object-fit="cover"
        style="border-radius: 6px"
        @error="onPreviewError"
      />
      <video v-else-if="isVideo && preview" :src="preview" controls style="width: 160px; border-radius: 6px" />
      <!-- 受保护用途两条通道都读不到时：给一行说明 + 媒体 id，不显示破图 -->
      <span v-else-if="previewFailed" class="protected-hint">
        已上传（受保护图片，需带令牌读取，这里不预览）
      </span>
      <span class="media-id">#{{ modelValue }}</span>
      <n-button size="tiny" quaternary type="error" :disabled="disabled" @click="remove">移除</n-button>
    </template>
    <span v-if="disabled" class="deny-hint">
      你的账号没有图片上传权限（<code>admin:media:write</code>），请联系超级管理员
    </span>
  </div>
</template>

<style scoped>
.media-upload {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.media-id {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.deny-hint {
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-warning, #f59e0b);
}
/* 受保护图片的"不能预览"说明（替代破图） */
.protected-hint {
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-text-tertiary);
}
</style>
