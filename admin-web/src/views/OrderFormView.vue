<template>
  <div style="padding: 16px">
    <n-card title="下单页配置（客户端「确认订单」页完全由这里驱动）" size="small">
      <template #header-extra>
        <n-button size="small" type="primary" :loading="saving" @click="save">保存</n-button>
        <n-button size="small" style="margin-left: 8px" @click="load">重置</n-button>
      </template>

      <n-form label-placement="left" label-width="130">
        <n-divider title-placement="left">区服选择</n-divider>
        <n-form-item label="标题"><n-input v-model:value="cfg.zoneLabel" /></n-form-item>
        <n-form-item label="选项">
          <n-dynamic-input v-model:value="cfg.zoneOptions" :on-create="() => ({ label: '', value: '' })">
            <template #default="{ value }">
              <n-input v-model:value="value.label" placeholder="展示名（微信）" style="width: 160px" />
              <n-input v-model:value="value.value" placeholder="落库值（wechat）" style="width: 160px; margin-left: 8px" />
            </template>
          </n-dynamic-input>
        </n-form-item>

        <n-divider title-placement="left">表单字段（顺序 = 展示顺序；关闭后客户端不显示）</n-divider>
        <n-dynamic-input v-model:value="cfg.fields" :on-create="() => ({ key: '', label: '', placeholder: '', type: 'text', required: false, enabled: true, maxLength: 64 })">
          <template #default="{ value }">
            <n-input v-model:value="value.key" placeholder="key" style="width: 130px" />
            <n-input v-model:value="value.label" placeholder="标签" style="width: 160px; margin-left: 8px" />
            <n-input v-model:value="value.placeholder" placeholder="占位提示" style="width: 190px; margin-left: 8px" />
            <n-select v-model:value="value.type" :options="typeOptions" style="width: 120px; margin-left: 8px" />
            <n-checkbox v-model:checked="value.required" style="margin-left: 8px">必填</n-checkbox>
            <n-checkbox v-model:checked="value.enabled" style="margin-left: 8px">显示</n-checkbox>
          </template>
        </n-dynamic-input>

        <n-divider title-placement="left">护航员与文案</n-divider>
        <n-form-item label="护航员标题"><n-input v-model:value="cfg.workerLabel" /></n-form-item>
        <n-form-item label="随机安排文案"><n-input v-model:value="cfg.workerRandomLabel" /></n-form-item>
        <n-form-item label="指定护航员文案"><n-input v-model:value="cfg.workerDesignatedLabel" /></n-form-item>
        <n-form-item label="费用区标题"><n-input v-model:value="cfg.feeTitle" /></n-form-item>
        <n-form-item label="单价前缀"><n-input v-model:value="cfg.feeUnitLabel" /></n-form-item>
        <n-form-item label="合计文案"><n-input v-model:value="cfg.totalLabel" /></n-form-item>
        <n-form-item label="提交按钮"><n-input v-model:value="cfg.submitText" /></n-form-item>
      </n-form>
    </n-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { NButton, NCard, NCheckbox, NDivider, NDynamicInput, NForm, NFormItem, NInput, NSelect, useMessage } from 'naive-ui';
import { ApiException, request } from '@/api/client';

interface ZoneOption { label: string; value: string }
interface FormField { key: string; label: string; placeholder: string; type: string; required: boolean; enabled: boolean; maxLength: number }
interface OrderFormConfig {
  zoneLabel: string;
  zoneOptions: ZoneOption[];
  fields: FormField[];
  workerLabel: string;
  workerRandomLabel: string;
  workerDesignatedLabel: string;
  feeTitle: string;
  feeUnitLabel: string;
  totalLabel: string;
  submitText: string;
  notice: string;
}

const message = useMessage();
const saving = ref(false);
const cfg = reactive<OrderFormConfig>({
  zoneLabel: '', zoneOptions: [], fields: [], workerLabel: '', workerRandomLabel: '',
  workerDesignatedLabel: '', feeTitle: '', feeUnitLabel: '', totalLabel: '', submitText: '', notice: '',
});
const typeOptions = [
  { label: '单行文本', value: 'text' },
  { label: '多行文本', value: 'textarea' },
  { label: '手机号', value: 'phone' },
];

async function load() {
  try {
    const data = await request<OrderFormConfig>('GET', '/admin/order-form');
    Object.assign(cfg, data);
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
}

async function save() {
  saving.value = true;
  try {
    await request('PUT', '/admin/order-form', { ...cfg });
    message.success('已保存，客户端下单页立即生效');
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    saving.value = false;
  }
}

onMounted(load);
</script>
