<script setup lang="ts">
/**
 * 充值（H5）—— **线下扫码 + 人工审核**（项目铁律：不接任何支付通道）
 * ============================================================================
 * 数据源（全部是既有接口，未新增任何服务端路由）：
 *   ① `GET /public/recharge/config`（**已存在**，`RechargePublicController`）
 *      → { amountOptions, customEnabled, minYuan, maxYuan, pointsPerYuan, pendingLimitPerUser,
 *          noticeText, qrCodes: [{ id, channel, label, url }] }
 *      收款码就来自这里（`url` 形如 `/media/public/199`，已实测 200 且无需令牌直接可 <img>）；
 *      **没有 qrCodes 时降级为「联系客服获取收款码」**，不臆造图片与接口。
 *   ② `POST /media/upload`（既有，multipart：`file` + `type=recharge_proof`）
 *      → { id, path, ... }；`path` = `/api/v1/media/protected/:id`（**受保护媒体**，
 *      `<img>` 直连带不上 Bearer 头 → 用带令牌的 fetch 取 blob 做本地预览）。
 *   ③ `POST /user/recharge/requests`（既有）body { amountYuan, qrId?, note?, proofMediaId }
 *   ④ `GET /user/recharge/requests`（既有）→ 我的申请（含 pendingCount / pendingLimitPerUser / rejectReason）
 *
 * ## 合规口径（写死在文案里，不可放宽）
 * - 不接支付通道：本页没有支付 SDK、没有支付单号、没有回调，**全站不出现「支付成功」**；
 * - 收款码是**一张图片**，用户**在平台外**自行付款 → 上传截图 → **人工核对** → 管理员手工发余额；
 * - 「已发放」= 余额已由管理员手工发放，**不是**任何自动到账；用户永远不能自行加分。
 *
 * 硬约束：白底为主 · 4dp 网格间距 · 颜色全 token · 金额 ¥+两位小数+千分位 · 零 emoji。
 */
import { computed, onMounted, ref } from 'vue';
import { ApiError, getToken, rechargeApi } from '@/api';
import { http } from '@/api/client';
import { fmtMoney, fmtTime } from '@/utils/format';
import PageHead from '@/components/PageHead.vue';

type Any = Record<string, unknown>;

interface QrCode {
  id: string;
  channel: string;
  label: string;
  url: string;
}

const cfg = ref<Any | null>(null);
const loading = ref(true);
const loadErr = ref('');

const amountOptions = ref<number[]>([]);
const customEnabled = ref(false);
const minYuan = ref(1);
const maxYuan = ref(10000);
const pointsPerYuan = ref(1);
const pendingLimitPerUser = ref(3);
const noticeText = ref('');
const qrCodes = ref<QrCode[]>([]);

/** 金额（数字或 null）；自定义时来自输入框 */
const picked = ref<number | null>(null);
const custom = ref('');

/** 凭证 */
const proofId = ref('');
const proofPreview = ref('');
const uploading = ref(false);
const fileInput = ref<HTMLInputElement | null>(null);

const note = ref('');
const submitting = ref(false);
const submitErr = ref('');
const doneMsg = ref('');

const mine = ref<Any[]>([]);
const pendingCount = ref(0);

const amount = computed<number | null>(() => {
  const raw = custom.value.trim();
  if (raw !== '') {
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  }
  return picked.value;
});

const amountHint = computed(() => {
  const v = amount.value;
  if (v === null) return '';
  if (v <= 0) return '请输入大于 0 的金额';
  if (v < minYuan.value) return `最少 ${fmtMoney(minYuan.value)} 元`;
  if (v > maxYuan.value) return `最多 ${fmtMoney(maxYuan.value)} 元`;
  return `到账 ¥${fmtMoney(v * pointsPerYuan.value)}`;
});

const canSubmit = computed(() => {
  if (submitting.value || uploading.value) return false;
  if (!qrCodes.value.length) return false; // 没有收款码 → 只给降级提示
  if (pendingCount.value >= pendingLimitPerUser.value) return false;
  const v = amount.value;
  if (v === null || v <= 0 || v < minYuan.value || v > maxYuan.value) return false;
  return !!proofId.value;
});

const blockedByPending = computed(() => pendingCount.value >= pendingLimitPerUser.value);

async function loadConfig() {
  try {
    const c = await http.get<Any>('/public/recharge/config', { anonymous: true });
    cfg.value = c;
    amountOptions.value = Array.isArray(c.amountOptions) ? (c.amountOptions as number[]).map(Number).filter((n) => Number.isFinite(n)) : [];
    customEnabled.value = c.customEnabled === true;
    minYuan.value = Number(c.minYuan ?? 1);
    maxYuan.value = Number(c.maxYuan ?? 10000);
    pointsPerYuan.value = Number(c.pointsPerYuan ?? 1);
    pendingLimitPerUser.value = Number(c.pendingLimitPerUser ?? 3);
    noticeText.value = String(c.noticeText ?? '');
    const qs = Array.isArray(c.qrCodes) ? (c.qrCodes as Any[]) : [];
    qrCodes.value = qs
      .map((q) => ({
        id: String(q.id ?? ''),
        channel: String(q.channel ?? ''),
        label: String(q.label ?? '收款码'),
        url: String(q.url ?? ''),
      }))
      .filter((q) => q.id && q.url);
    // 默认选中第一档（有档位才选；自定义仍可覆盖）
    if (amountOptions.value.length) picked.value = amountOptions.value[0];
  } catch (e) {
    loadErr.value = e instanceof ApiError ? e.message : '加载失败，请稍后重试';
  } finally {
    loading.value = false;
  }
}

async function loadMine() {
  try {
    const r = await rechargeApi.list({ page: 1, pageSize: 10 });
    mine.value = Array.isArray(r?.list) ? (r.list as Any[]) : [];
    const rAny = r as unknown as Any;
    pendingCount.value = Number(rAny?.pendingCount ?? 0);
    if (rAny?.pendingLimitPerUser !== undefined) pendingLimitPerUser.value = Number(rAny.pendingLimitPerUser);
  } catch {
    /* 我的申请是"附加信息"，失败不阻塞提交入口 */
  }
}

/** 金额档位：选中 = 主色浅底 + 主色描边（白底上不做实色块） */
function pickAmount(v: number) {
  custom.value = '';
  picked.value = v;
  submitErr.value = '';
}

function onCustomInput() {
  picked.value = null;
  submitErr.value = '';
}

/** 受保护媒体：必须带 Bearer 头取 blob（<img> 直连带不上令牌） */
async function loadPreview(id: string) {
  try {
    const resp = await fetch(`/api/v1/media/protected/${id}`, {
      headers: { Authorization: `Bearer ${getToken()}` },
    });
    if (!resp.ok) return;
    const blob = await resp.blob();
    if (proofPreview.value.startsWith('blob:')) URL.revokeObjectURL(proofPreview.value);
    proofPreview.value = URL.createObjectURL(blob);
  } catch {
    /* 预览失败不影响提交：id 已经拿到 */
  }
}

async function onPickFile(e: Event) {
  const input = e.target as HTMLInputElement;
  const f = input.files?.[0];
  if (!f) return;
  submitErr.value = '';
  uploading.value = true;
  try {
    const fd = new FormData();
    fd.append('file', f);
    fd.append('type', 'recharge_proof');
    const r = await http.post<Any>('/media/upload', undefined, { form: fd });
    const id = String(r?.id ?? '');
    if (!id) throw new ApiError(-1, '上传失败，请重试');
    proofId.value = id;
    await loadPreview(id);
  } catch (err) {
    submitErr.value = err instanceof ApiError ? err.message : '上传失败，请重试';
  } finally {
    uploading.value = false;
    // 允许重复选同一张（否则用户改错图后没法重选）
    input.value = '';
  }
}

function clearProof() {
  proofId.value = '';
  if (proofPreview.value.startsWith('blob:')) URL.revokeObjectURL(proofPreview.value);
  proofPreview.value = '';
}

function openPicker() {
  fileInput.value?.click();
}

async function submit() {
  if (!canSubmit.value) return;
  submitting.value = true;
  submitErr.value = '';
  doneMsg.value = '';
  try {
    // 后端 DTO 是 JSON（`CreateRechargeRequestDto`），但请求层只对 FormData 走 multipart
    // → 这里统一用 FormData 提交：字段名与 DTO 一致，服务端解析等价（金额会被强制转数字）
    const fd = new FormData();
    fd.append('amountYuan', String(amount.value));
    fd.append('proofMediaId', proofId.value);
    if (qrCodes.value.length) fd.append('qrId', qrCodes.value[0].id);
    const n = note.value.trim();
    if (n) fd.append('note', n);
    await rechargeApi.submit(fd);
    doneMsg.value = '申请已提交，客服核对后会为你发放余额';
    clearProof();
    custom.value = '';
    picked.value = amountOptions.value.length ? amountOptions.value[0] : null;
    note.value = '';
    await loadMine();
  } catch (e) {
    // 服务端中文原文（如「待审核申请已达上限」「请上传转账截图」），不自己编
    submitErr.value = e instanceof ApiError ? e.message : '提交失败，请稍后重试';
  } finally {
    submitting.value = false;
  }
}

/** 我的申请状态文案：**只有「已发放」**，绝不出现「支付成功」 */
const MY_STATUS: Record<string, string> = {
  pending: '审核中',
  granted: '已发放',
  rejected: '已驳回',
};
function myStatusText(s: string): string {
  return MY_STATUS[s] ?? s;
}
function myStatusCls(s: string): string {
  if (s === 'granted') return 'stag--ok';
  if (s === 'rejected') return 'stag--bad';
  return 'stag--wait';
}
function myStatusIcon(s: string): string {
  if (s === 'granted') return 'm5 13 4 4L19 7';
  if (s === 'rejected') return 'M6 6l12 12M18 6L6 18';
  return 'M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z';
}

onMounted(async () => {
  await Promise.all([loadConfig(), loadMine()]);
});
</script>

<template>
  <div class="h5-page h5-page--nobar">
    <PageHead title="充值" />

    <div v-if="loading" class="h5-card sk">
      <div class="h5-skel sk__l sk__l--w40" />
      <div class="h5-skel sk__l sk__l--w70" />
    </div>

    <div v-else-if="loadErr && !cfg" class="h5-empty">
      <p class="em__t">{{ loadErr }}</p>
      <button class="h5-btn h5-btn--ghost h5-btn--sm em__b" type="button" @click="loading = true, loadConfig()">
        重试
      </button>
    </div>

    <template v-else>
      <!-- 0 说明：文案取自服务端 noticeText（不自己编合规话术） -->
      <div v-if="noticeText" class="h5-card nt">
        <div class="nt__hd">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
            <circle cx="12" cy="12" r="9" /><path d="M12 8h.01M11 12h1v4h1" stroke-linecap="round" />
          </svg>
          <span>充值说明</span>
        </div>
        <p class="nt__x">{{ noticeText }}</p>
      </div>

      <!-- 1 金额选择 -->
      <div class="h5-sec"><span class="h5-sec__t">选择金额</span></div>
      <div class="h5-card">
        <div v-if="amountOptions.length" class="ag">
          <button
            v-for="v in amountOptions"
            :key="v"
            class="ag__i"
            :class="{ 'ag__i--on': custom.trim() === '' && picked === v }"
            type="button"
            @click="pickAmount(v)"
          >
            <span class="ag__sym">¥</span>{{ fmtMoney(v) }}
          </button>
        </div>

        <div v-if="customEnabled" class="cu">
          <span class="cu__k">自定义</span>
          <div class="cu__box">
            <span class="cu__sym">¥</span>
            <input
              v-model="custom"
              class="cu__in"
              type="number"
              inputmode="decimal"
              :min="minYuan"
              :max="maxYuan"
              step="0.01"
              placeholder="输入金额"
              @input="onCustomInput"
            />
          </div>
        </div>

        <p class="ag__hint" :class="{ 'ag__hint--bad': amountHint.startsWith('请输入') || amountHint.startsWith('最少') || amountHint.startsWith('最多') }">
          {{ amountHint || `单笔 ${fmtMoney(minYuan)} ~ ${fmtMoney(maxYuan)} 元` }}
        </p>
      </div>

      <!-- 2 收款码（管理端指定的图片；没有就降级提示，不臆造） -->
      <div class="h5-sec"><span class="h5-sec__t">扫码付款</span></div>
      <div class="h5-card qr">
        <template v-if="qrCodes.length">
          <img class="qr__img" :src="qrCodes[0].url" :alt="qrCodes[0].label" />
          <p class="qr__lb">{{ qrCodes[0].label }}</p>
          <p class="qr__tip">请在微信或支付宝里扫码付款，付款金额与上方选择一致</p>
        </template>
        <div v-else class="qr__none">
          <p class="qr__noneT">联系客服获取收款码</p>
          <p class="qr__noneX">管理端尚未配置收款码，请联系客服索取后再提交申请。</p>
        </div>
      </div>

      <!-- 3 上传转账截图 -->
      <div class="h5-sec"><span class="h5-sec__t">上传转账截图</span></div>
      <div class="h5-card up">
        <input
          ref="fileInput"
          class="up__file"
          type="file"
          accept="image/jpeg,image/png,image/gif,image/webp"
          @change="onPickFile"
        />
        <div v-if="!proofId" class="up__drop" role="button" tabindex="0" @click="openPicker" @keydown.enter="openPicker">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
            <path d="M12 16V6m0 0L8 10m4-4 4 4" stroke-linecap="round" stroke-linejoin="round" />
            <path d="M4 16v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" stroke-linecap="round" />
          </svg>
          <span class="up__dT">{{ uploading ? '上传中…' : '点击上传付款截图' }}</span>
          <span class="up__dX">仅支持图片，单张不超过 10MB</span>
        </div>
        <div v-else class="up__pv">
          <img v-if="proofPreview" class="up__img" :src="proofPreview" alt="付款截图" />
          <div v-else class="up__ph">已上传</div>
          <div class="up__ops">
            <button class="up__b" type="button" @click="openPicker">重新上传</button>
            <button class="up__b up__b--del" type="button" @click="clearProof">删除</button>
          </div>
        </div>
      </div>

      <!-- 4 备注 -->
      <div class="h5-sec"><span class="h5-sec__t">备注（选填）</span></div>
      <div class="h5-card">
        <textarea
          v-model="note"
          class="rk"
          rows="2"
          maxlength="200"
          placeholder="如付款用的微信昵称，便于客服核对"
        />
      </div>

      <!-- 5 提交 -->
      <div class="sub">
        <button class="h5-btn" type="button" :disabled="!canSubmit" @click="submit">
          {{ submitting ? '提交中…' : '提交充值申请' }}
        </button>
        <p class="sub__tip">提交后由客服核对后发放，不是自动到账；余额到账前请不要重复提交。</p>
        <p v-if="blockedByPending" class="sub__bad">待审核申请已达上限（{{ pendingLimitPerUser }} 笔），请等客服核对后再提交</p>
        <p v-if="submitErr" class="sub__bad">{{ submitErr }}</p>
        <p v-if="doneMsg" class="sub__ok">{{ doneMsg }}</p>
      </div>

      <!-- 6 我的申请 -->
      <div class="h5-sec">
        <span class="h5-sec__t">我的充值申请</span>
        <span v-if="pendingCount" class="h5-sec__x">待审核 {{ pendingCount }} 笔</span>
      </div>
      <div v-if="!mine.length" class="h5-empty">还没有充值申请</div>
      <div v-else class="h5-card h5-card--flush">
        <div v-for="m in mine" :key="String(m.id)" class="mr">
          <div class="mr__m">
            <div class="mr__t">
              <span class="mr__amt"><span class="h5-price__sym">¥</span>{{ fmtMoney(m.amountYuan) }}</span>
              <span class="stag" :class="myStatusCls(String(m.status))">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
                  <path :d="myStatusIcon(String(m.status))" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
                {{ myStatusText(String(m.status)) }}
              </span>
            </div>
            <div class="mr__d">
              提交 {{ fmtTime(String(m.createdAt ?? '')) }}
              <template v-if="m.qrLabel"> · {{ m.qrLabel }}</template>
            </div>
            <div v-if="m.status === 'granted' && m.grantedAt" class="mr__d">发放 {{ fmtTime(String(m.grantedAt)) }}</div>
            <div v-if="m.status === 'rejected' && m.rejectReason" class="mr__bad">驳回原因：{{ m.rejectReason }}</div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
/* ---------- 说明卡 ---------- */
.nt__hd {
  display: flex; align-items: center; gap: var(--s2);
  margin-bottom: var(--s2);
  font-size: var(--f4); font-weight: 700; color: var(--g2);
}
.nt__hd svg { color: var(--pri); }
.nt__x { margin: 0; font-size: var(--f5); color: var(--g2); line-height: 1.6; }

/* ---------- 金额档位 ---------- */
.ag { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--s2); }
.ag__i {
  height: var(--h-btn);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
  color: var(--g1);
  font-size: var(--f3);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
.ag__i--on { background: var(--pri-soft); border-color: var(--pri); color: var(--pri); }
.ag__sym { font-size: .78em; margin-right: 1px; }

/* ---------- 自定义金额 ---------- */
.cu { display: flex; align-items: center; gap: var(--s3); margin-top: var(--s3); }
.cu__k { flex: 0 0 auto; font-size: var(--f4); color: var(--g2); }
.cu__box {
  flex: 1 1 auto; min-width: 0;
  display: flex; align-items: center; gap: var(--s1);
  height: var(--h-btn);
  padding: 0 var(--s3);
  background: var(--card);
  border: 1px solid var(--g4);
  border-radius: var(--r-ctrl);
}
.cu__box:focus-within { border-color: var(--pri); }
.cu__sym { color: var(--g3); font-size: var(--f3); }
.cu__in {
  flex: 1 1 auto; min-width: 0; height: 100%;
  border: 0; padding: 0; background: none; outline: none;
  font-size: var(--f3); color: var(--g1); font-variant-numeric: tabular-nums;
}
.ag__hint { margin: var(--s3) 0 0; font-size: var(--f5); color: var(--g3); }
.ag__hint--bad { color: var(--warn); }

/* ---------- 收款码 ---------- */
.qr { text-align: center; }
.qr__img {
  width: 200px; height: 200px;
  margin: 0 auto;
  object-fit: contain;
  border: 1px solid var(--g5);
  border-radius: var(--r-ctrl);
}
.qr__lb { margin: var(--s3) 0 var(--s1); font-size: var(--f4); font-weight: 700; color: var(--g1); }
.qr__tip { margin: 0; font-size: var(--f5); color: var(--g3); }
.qr__none { padding: var(--s4) 0; }
.qr__noneT { margin: 0 0 var(--s2); font-size: var(--f3); font-weight: 700; color: var(--g1); }
.qr__noneX { margin: 0; font-size: var(--f5); color: var(--g3); line-height: 1.6; }

/* ---------- 上传 ---------- */
.up__file { display: none; }
.up__drop {
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  gap: var(--s2);
  min-height: 96px;
  background: var(--g6);
  border: 1px dashed var(--g4);
  border-radius: var(--r-ctrl);
  color: var(--g3);
  cursor: pointer;
}
.up__dT { font-size: var(--f4); color: var(--g2); font-weight: 600; }
.up__dX { font-size: var(--f6); color: var(--g3); }
.up__pv { display: flex; align-items: center; gap: var(--s3); }
.up__img {
  width: 72px; height: 72px; flex: 0 0 auto;
  object-fit: cover;
  border: 1px solid var(--g5);
  border-radius: var(--r-ctrl);
}
.up__ph {
  width: 72px; height: 72px; flex: 0 0 auto;
  display: grid; place-items: center;
  background: var(--g6); border: 1px solid var(--g5); border-radius: var(--r-ctrl);
  font-size: var(--f6); color: var(--g3);
}
.up__ops { display: flex; flex-direction: column; gap: var(--s2); }
.up__b {
  height: var(--h-btn-sm); padding: 0 var(--s3);
  background: var(--card); border: 1px solid var(--g4); border-radius: var(--r-ctrl);
  color: var(--g2); font-size: var(--f5); cursor: pointer;
}
.up__b--del { color: var(--danger); border-color: var(--danger); }

/* ---------- 备注 ---------- */
.rk {
  width: 100%;
  min-height: 48px;
  padding: var(--s2) 0;
  border: 0; outline: none; resize: vertical;
  background: none;
  font: inherit; font-size: var(--f4); color: var(--g1);
}
.rk::placeholder { color: var(--g3); }

/* ---------- 提交 ---------- */
.sub { margin: var(--s5) var(--page-x) 0; }
.sub__tip { margin: var(--s3) 0 0; font-size: var(--f5); color: var(--g3); line-height: 1.6; }
.sub__bad { margin: var(--s2) 0 0; font-size: var(--f5); color: var(--danger); line-height: 1.6; }
.sub__ok { margin: var(--s2) 0 0; font-size: var(--f5); color: var(--celadon); line-height: 1.6; font-weight: 700; }

/* ---------- 我的申请 ---------- */
.mr {
  padding: var(--s3) var(--card-pad-x);
  border-bottom: 1px solid var(--g5);
}
.mr:last-child { border-bottom: 0; }
.mr__m { display: flex; flex-direction: column; gap: var(--s1); }
.mr__t { display: flex; align-items: center; gap: var(--s2); }
.mr__amt { font-size: var(--f3); font-weight: 800; color: var(--gold); font-variant-numeric: tabular-nums; }
.mr__d { font-size: var(--f5); color: var(--g3); font-variant-numeric: tabular-nums; }
.mr__bad { font-size: var(--f5); color: var(--danger); line-height: 1.5; }

/* ---------- 骨架 / 空态 ---------- */
.sk { display: flex; flex-direction: column; gap: var(--s3); }
.sk__l { height: 12px; }
.sk__l--w40 { width: 40%; }
.sk__l--w70 { width: 70%; }
.em__t { margin: 0 0 var(--s3); }
.em__b { margin: 0 auto; }
</style>
