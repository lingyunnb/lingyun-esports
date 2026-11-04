<template>
  <div class="recharge-page">
    <!--
      页头口径（负责人定案，不许放宽）：平台不经手资金。
      这段文字同时是给运营的合规提醒 —— 页面里任何地方都不出现「支付成功」，只有「已发放」。
    -->
    <header class="page-head">
      <h1>充值管理</h1>
      <p class="lede">
        老板端「充值」= 选金额 → 扫<b>收款码图片</b>付款 → 上传付款截图 → 管理员核对后<b>手工发放</b>余额。
        平台不经手资金、不接支付通道；状态只有「待核对 / <b>已发放</b> / 已驳回」三档，余额一律由管理员手工发放。
        <b>余额仅可用于平台内消费，不可提现、不可转让。</b>
      </p>
    </header>

    <p v-if="hiddenPermHint" class="perm-note">{{ hiddenPermHint }}</p>

    <!-- 三个 tab 全都没权限（极端情况）：给一块说明，而不是渲染一个空壳页面 -->
    <div v-if="!visibleTabNames.length" class="perm-block">
      <div class="perm-title">没有充值管理的查看权限</div>
      <div class="perm-sub">
        充值申请需要窄权限点 <code>recharge:review</code>；收款码与充值设置需要 <code>admin:setting:read</code>。<br />
        当前账号两者都没有，因此这一页不给任何入口 —— 请联系超级管理员在「管理员与角色」里给角色勾选后再来。
      </div>
    </div>

    <n-tabs v-else v-model:value="tab" type="line" class="tabs">
      <!--
        tab 级权限渲染（负责人 2026-10-06 定案）：三个 tab 各自对应不同权限点，
        **没权限的 tab 直接不渲染**（而不是"点进去才吃 403"），并在页头用一行说明缺哪个权限点。
          · 充值申请 = recharge:review（看）/ recharge:grant（发放·驳回）
          · 收款码 / 充值设置 = admin:setting:read（看）/ admin:setting:write（改；保存设置另需超管）
          · 管理员白名单 = admin:admin:read（看）/ admin:admin:write（增删；另需超管）
      -->
      <n-tab-pane v-if="canReview" name="requests" tab="充值申请">
        <div class="filter-bar">
          <n-select
            v-model:value="filter.status"
            :options="STATUS_FILTERS"
            placeholder="全部状态"
            clearable
            style="width: 132px"
            @update:value="applyFilter"
          />
          <n-input
            v-model:value="filter.keyword"
            placeholder="昵称 / 中文 ID"
            clearable
            style="width: 200px"
            @keyup.enter="applyFilter"
          />
          <n-date-picker
            v-model:value="filter.range"
            type="daterange"
            clearable
            style="width: 260px"
            start-placeholder="提交开始日"
            end-placeholder="提交结束日"
            @update:value="applyFilter"
          />
          <n-button type="primary" ghost @click="applyFilter">查询</n-button>
          <n-button quaternary @click="resetFilter">重置</n-button>
          <div class="spacer" />
          <span class="count">共 {{ total }} 条申请</span>
          <n-button quaternary size="small" :loading="reqLoading" @click="loadRequests">刷新</n-button>
        </div>

        <p v-if="!canReview" class="ro-hint">
          当前账号没有充值申请查看权限（窄权限点 <code>recharge:review</code>）：列表会被服务端拒绝。
        </p>
        <p v-else-if="!canHandle" class="ro-hint">
          当前账号只有查看权限（缺 <code>recharge:grant</code>）：可以核对申请与看凭证大图，
          <b>发放/驳回按钮不可用</b>（服务端二次校验，前端只是隐藏）。
        </p>

        <n-data-table
          :columns="requestColumns"
          :data="rows"
          :loading="reqLoading"
          :bordered="false"
          :row-key="(r: RechargeRequestRow) => r.id"
          :scroll-x="1070"
          size="small"
          :pagination="{
            page: page,
            pageSize: pageSize,
            itemCount: total,
            showSizePicker: false,
            onChange: onPageChange,
          }"
        >
          <template #empty>
            <div class="empty">
              <div class="empty-title">还没有充值申请</div>
              <div class="empty-sub">
                老板在 App 里选金额、扫码付款、上传截图提交后，申请会出现在这里等着核对。<br />
                如果刚有人提交却看不到，先点「重置」清掉上面的筛选条件。
              </div>
            </div>
          </template>
        </n-data-table>
      </n-tab-pane>

      <!-- ============================================================ 收款码 -->
      <n-tab-pane v-if="canReadSetting" name="qr" tab="收款码">
        <div class="filter-bar">
          <span class="count">
            收款码就是<b>一张图片</b>：老板线下扫码付款，平台不产生任何支付单据。
            停用后老板端立刻不再拿到这张码（不影响已提交的申请）。
          </span>
          <div class="spacer" />
          <n-button quaternary size="small" :loading="qrLoading" @click="loadQrCodes">刷新</n-button>
          <n-button v-if="canWriteSetting" type="primary" size="small" @click="openQrCreate">新增收款码</n-button>
        </div>
        <p v-if="!canReadSetting" class="ro-hint">
          当前账号没有查看充值配置的权限（<code>admin:setting:read</code>）：收款码与充值设置会被服务端拒绝。
        </p>
        <p v-else-if="!canWriteSetting" class="ro-hint">
          当前账号对收款码<b>只读</b>：新增 / 编辑 / 删除 / 启停都需要 <code>admin:setting:write</code>；
          充值设置与管理员白名单另需超级管理员。下面的按钮已隐藏，说明写在每行操作列里。
        </p>

        <n-data-table
          :columns="qrColumns"
          :data="qrRows"
          :loading="qrLoading"
          :bordered="false"
          :row-key="(r: RechargeQrCode) => r.id"
          :scroll-x="746"
          size="small"
        >
          <template #empty>
            <div class="empty">
              <div class="empty-title">还没有收款码</div>
              <div class="empty-sub">
                先上传一张微信/支付宝收款码图片并启用，老板端「充值」页才有码可扫。<br />
                一张都没有时，老板端的充值入口不会显示任何收款方式。
              </div>
            </div>
          </template>
        </n-data-table>
      </n-tab-pane>

      <!-- ============================================================ 充值设置 -->
      <n-tab-pane v-if="canReadSetting" name="config" tab="充值设置">
        <n-alert v-if="!canConfig" type="warning" :bordered="false" class="ro-banner">
          <b>只读模式</b>：充值设置与管理员白名单属于最高安全档配置（<code>is_high_security</code>），
          只有<b>超级管理员</b>能改。当前账号可以查看现有口径，输入框全部禁用；即便绕过前端也会被服务端 403 拒绝。
        </n-alert>

        <section class="block">
          <div class="block-head">
            <h2>金额档位</h2>
            <span class="block-sub">老板端点选的面额（单位：元）。点标签可改：会把该档位取回输入框，改完回车放回。</span>
          </div>
          <div class="chips">
            <n-tag
              v-for="opt in draft.amountOptions"
              :key="opt"
              class="amount-chip"
              :type="editingAmount === opt ? 'primary' : 'default'"
              :closable="canConfig"
              size="medium"
              @close="removeAmount(opt)"
              @click="pickAmount(opt)"
            >
              {{ opt }} 元
            </n-tag>
            <span v-if="!draft.amountOptions.length" class="chips-empty">还没有档位：至少留一个，否则老板端只能走自定义金额</span>
          </div>
          <div class="chips-add">
            <!-- 整数（后端 assertRechargeConfig 对档位/上下限/比例一律要求整数；这里不给出小数输入口，
                 免得运营填 7.5 再吃一次中文 400） -->
            <n-input-number
              v-model:value="newAmount"
              :disabled="!canConfig"
              :min="1"
              :precision="0"
              placeholder="面额（元）"
              style="width: 150px"
              @keyup.enter="addAmount"
            />
            <n-button :disabled="!canConfig" @click="addAmount">加入档位</n-button>
            <span class="mini-hint">只能填整数元；按面额从小到大排序后保存；重复面额不会加两次</span>
          </div>
        </section>

        <section class="block">
          <div class="block-head">
            <h2>自定义金额</h2>
            <span class="block-sub">关掉后老板端只能在上面这些档位里选，不能自己填数。</span>
          </div>
          <div class="row">
            <n-switch v-model:value="draft.customEnabled" :disabled="!canConfig" />
            <span class="row-label">{{ draft.customEnabled ? '允许老板自己填金额' : '只允许档位金额' }}</span>
          </div>
          <div class="row">
            <span class="field-label">下限</span>
            <n-input-number v-model:value="draft.minYuan" :disabled="!canConfig" :min="1" :precision="0" placeholder="下限（元）" style="width: 150px">
              <template #suffix>元</template>
            </n-input-number>
            <span class="field-label">上限</span>
            <n-input-number v-model:value="draft.maxYuan" :disabled="!canConfig" :min="1" :precision="0" placeholder="上限（元）" style="width: 150px">
              <template #suffix>元</template>
            </n-input-number>
            <span v-if="amountRangeError" class="err">{{ amountRangeError }}</span>
          </div>
        </section>

        <section class="block">
          <div class="block-head">
            <h2>到账比例</h2>
            <span class="block-sub">老板端每一档显示多少余额、审核列表里的「应得余额」，都由这一项算出来（口径：余额 = 元，1 元 = 1 元）。</span>
          </div>
          <div class="row">
            <span class="field-label">1 元 到账</span>
            <n-input-number
              v-model:value="draft.pointsPerYuan"
              :disabled="!canConfig"
              :min="1"
              :precision="0"
              placeholder="到账比例"
              style="width: 150px"
              @update:value="touchRatio"
            >
              <template #suffix>余额</template>
            </n-input-number>
            <span class="preview">例：付款 10 元 → 到账 {{ formatYuan(previewPoints(10)) }} · 付款 68 元 → 到账 {{ formatYuan(previewPoints(68)) }}</span>
          </div>
          <n-alert type="warning" :bordered="false" class="ratio-warn">
            <b>改这里会影响全站口径</b>：老板端「充值」页显示的应得余额、各档位到账余额、审核列表的应得余额，
            全部按「1 元 到账 {{ draft.pointsPerYuan ?? '—' }} 余额」实时计算。改动<b>立即生效</b>，
            请先跟负责人确认新口径再保存（保存后旧口径不可回滚，只能再改回来）。
            <span v-if="ratioTouched && saved" class="ratio-changed">
              本次改动：{{ saved.pointsPerYuan }} → {{ draft.pointsPerYuan }} 余额/元（点「保存设置」才落库）
            </span>
          </n-alert>
        </section>

        <section class="block">
          <div class="block-head">
            <h2>限额</h2>
            <span class="block-sub">防刷：一个人不能同时堆一堆待审核申请；白名单也封顶，避免"谁都能发余额"。</span>
          </div>
          <div class="row">
            <span class="field-label">每人待审核上限</span>
            <n-input-number v-model:value="draft.pendingLimitPerUser" :disabled="!canConfig" :min="1" :precision="0" placeholder="待审核上限" style="width: 130px">
              <template #suffix>条</template>
            </n-input-number>
            <span class="field-label">管理员白名单上限</span>
            <n-input-number
              v-model:value="draft.adminLimit"
              :disabled="!canConfig"
              :min="1"
              :max="draft.adminLimitMax ?? 5"
              :precision="0"
              placeholder="白名单上限"
              style="width: 130px"
            >
              <template #suffix>人</template>
            </n-input-number>
            <span class="mini-hint">白名单当前已用 {{ whitelist.length }}/{{ draft.adminLimit }}</span>
          </div>
        </section>

        <section class="block">
          <div class="block-head">
            <h2>给老板看的说明文案</h2>
            <span class="block-sub">出现在老板端「充值」页的说明区（每行一条，客户端按行渲染，不要写序号）。</span>
          </div>
          <n-input
            v-model:value="draft.noticeText"
            type="textarea"
            :autosize="{ minRows: 3, maxRows: 10 }"
            maxlength="600"
            show-count
            :disabled="!canConfig"
            placeholder="例：付款后请截图订单详情页，含金额与时间&#10;提交后 2 小时内核对，节假日顺延&#10;截图模糊或金额不符会被驳回，可重新提交"
          />
        </section>

        <div class="ops">
          <n-button type="primary" :loading="cfgSaving" :disabled="!canConfig || !cfgDirty" @click="saveConfig">
            保存设置
          </n-button>
          <n-button :disabled="cfgSaving || !cfgDirty" @click="loadConfig">重置为当前生效值</n-button>
          <span class="mini-hint">
            {{ canConfig ? '保存后老板端下一次请求即生效（无需发版）' : '只读账号：保存会被服务端 403 拒绝' }}
          </span>
        </div>

        <!-- ---------------- 管理员白名单（可发放余额的人） ---------------- -->
        <section class="block whitelist">
          <div class="block-head">
            <h2>管理员白名单</h2>
            <span class="block-sub">
              只有名单里的管理员能核对并发放余额（列表/发放走专用窄权限，与改配置的权限分开）。
              只能添加 <code>role=admin</code> 的账号，上限 {{ draft.adminLimit }} 人。
            </span>
            <n-tag :type="whitelistFull ? 'warning' : 'default'" size="small" class="used-tag">
              已用 {{ whitelist.length }}/{{ draft.adminLimit }}
            </n-tag>
          </div>

          <p v-if="!canWhitelistRead" class="ro-hint">
            当前账号没有白名单查看权限（<code>admin:admin:read</code>）：名单内容不显示（服务端会拒绝读取）。
          </p>
          <template v-else>
            <div class="row add-row">
              <n-select
                v-model:value="pickedAdminId"
                :options="adminOptions"
                :disabled="!canConfig || whitelistFull"
                :loading="adminsLoading"
                filterable
                clearable
                placeholder="搜索管理员账号（昵称 / 用户名）"
                style="width: 300px"
              />
              <n-button type="primary" :disabled="!canConfig || whitelistFull || !pickedAdminId" :loading="wlAdding" @click="addWhitelistEntry">
                加入白名单
              </n-button>
              <span v-if="whitelistFull" class="err">
                已达上限 {{ whitelist.length }}/{{ draft.adminLimit }}：先移除一个才能再加（上限在「限额」里改）。
              </span>
              <span v-else-if="!canConfig" class="mini-hint">只读：白名单仅超级管理员可改</span>
            </div>

            <n-data-table
              :columns="whitelistColumns"
              :data="whitelist"
              :loading="wlLoading"
              :bordered="false"
              :row-key="(r: RechargeAdminEntry) => r.id"
              size="small"
              :scroll-x="570"
            >
              <template #empty>
                <div class="empty">
                  <div class="empty-title">白名单是空的</div>
                  <div class="empty-sub">
                    现在<b>没有任何人</b>能发放充值余额（超级管理员在服务端另有兜底）。
                    从上面的下拉里选一个管理员加进来，他就能在「充值申请」里核对发放。
                  </div>
                </div>
              </template>
            </n-data-table>
          </template>
        </section>
      </n-tab-pane>
    </n-tabs>

    <!-- ============================== 收款码 新增/编辑 ============================== -->
    <n-modal
      v-model:show="showQrModal"
      preset="card"
      style="width: 560px"
      :title="qrForm.id ? '编辑收款码' : '新增收款码'"
      :bordered="false"
    >
      <n-form label-placement="left" label-width="88">
        <n-form-item label="收款码图">
          <div style="width: 100%">
            <!-- 上传能力单独一把钥匙（admin:media:write）：没有就**禁用并说明**，不让人点了才吃 403；
                 但"权限还没加载出来"不等于"没权限"（uploadDisabled 只在 me 到位后才可能为 true） -->
            <MediaUploadField v-model="qrImageModel" :media-type="QR_UPLOAD_MEDIA_TYPE" :disabled="uploadDisabled" />
            <div class="mini-hint" style="margin-top: 6px; line-height: 1.7">
              用<b>公开可读</b>的图片用途上传 → 老板端直接拉图显示。建议正方形、宽 ≥600，别裁掉二维码白边。
            </div>
          </div>
        </n-form-item>
        <n-form-item label="渠道">
          <n-select v-model:value="qrForm.channel" :options="CHANNEL_OPTIONS" style="width: 180px" />
        </n-form-item>
        <n-form-item label="标签">
          <n-input v-model:value="qrForm.label" maxlength="24" show-count placeholder="如：微信 · 客服小祁（同一渠道可以有多张）" />
        </n-form-item>
        <n-form-item label="排序">
          <n-input-number v-model:value="qrForm.sort" :min="0" :precision="0" placeholder="排序" style="width: 140px" />
          <span class="mini-hint" style="margin-left: 10px">数字小的排前面（老板端按此顺序列码）</span>
        </n-form-item>
        <n-form-item label="启用">
          <n-switch v-model:value="qrForm.enabled" />
          <span class="mini-hint" style="margin-left: 10px">停用后老板端不再返回这张码</span>
        </n-form-item>
      </n-form>
      <template #footer>
        <div class="modal-footer">
          <n-button @click="showQrModal = false">取消</n-button>
          <n-button type="primary" :loading="qrSaving" @click="saveQrCode">保存</n-button>
        </div>
      </template>
    </n-modal>

    <!-- ============================== 驳回（必填原因） ============================== -->
    <n-modal
      v-model:show="showReject"
      preset="card"
      style="width: 520px"
      title="驳回充值申请"
      :bordered="false"
    >
      <p v-if="rejectRow" class="reject-info">
        驳回「{{ rejectRow.nickname || '（无昵称）' }}（{{ rejectRow.uid || rejectRow.userId }}）」的
        <b>{{ formatYuan(rejectRow.amount) }}</b> 申请（应得 {{ formatYuan(rejectRow.points) }} 余额）。
        <br />驳回后<b>不会</b>发放余额，原因会通知申请人，他可以用正确的截图重新提交。
      </p>
      <n-input
        v-model:value="rejectReason"
        type="textarea"
        :autosize="{ minRows: 3 }"
        maxlength="200"
        show-count
        placeholder="必填：例如「截图金额 10 元与申请 6 元不一致，请重新提交」"
      />
      <p v-if="rejectTouched && !rejectReason.trim()" class="err">驳回必须填写原因（申请人会看到这句话）</p>
      <template #footer>
        <div class="modal-footer">
          <n-button @click="showReject = false">取消</n-button>
          <n-button type="error" :loading="rejecting" :disabled="!rejectReason.trim()" @click="doReject">确认驳回</n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>

<script setup lang="ts">
/**
 * 充值管理（负责人定案：老板端线下扫码 + 截图申请 + 管理员手工发放余额）
 *
 * ## 放在哪、为什么
 * 侧栏位置：紧跟在「余额管理」之后（用户管理 → 身份绑定 → 余额管理 → **充值管理**）。
 * 理由：这一页的产出就是余额入账（`发放` = 写一条余额流水 + 审计），与「余额管理」是同一个业务动作的
 * 上下游 —— 运营核对完充值申请，接着就会去余额管理查这笔流水，两页挨着最省跳转。
 *
 * ## 口径（负责人 2026-10-09）
 * 计价单位从「积分（1 元 = 10 积分）」改为「余额（1 元 = 1 元）」，存量金额由服务端按 10:1 折算；
 * 本页所有金额一律 `¥` + 两位小数（统一走 @/utils/format），「积分」二字不再出现在金额语境。
 * API 字段名不变（`amount` / `points` / `pointsPerYuan` 一律照旧）。
 *
 * ## 三个 tab
 * 1. 充值申请：核对列表（筛选 + 发放 + 驳回 + 凭证看大图）
 * 2. 收款码：增删改查 + 启停 + 排序（图片走既有媒体上传，不接支付通道）
 * 3. 充值设置：档位/自定义/比例/限额/文案 + 管理员白名单（**仅超管可写**）
 *
 * ## 权限
 * - 查看/发放：专用窄权限点（`admin:recharge:read` 查看、`admin:recharge:handle` 发放/驳回）——
 *   前端只做隐藏/禁用，服务端才是权威（非超管保存设置一律 403）。
 * - 收款码与充值设置、白名单：最高安全档（`is_high_security`）→ **仅超管**（与「系统设置」里
 *   购买提示 / 身份绑定上限同一机制，见 auth store 的 `isSuperAdmin`）。
 *
 * ## 合规（不许放宽）
 * 不接支付通道：没有支付 SDK、回调、支付单号；收款码只是图片；页面文案里不出现「支付成功」，
 * 状态只有 待核对 / **已发放** / 已驳回。
 */
import { ApiException, mediaPreviewPath, protectedMediaUrl, request } from '@/api/client';
import { formatYuan, formatYuanOr } from '@/utils/format';
import { useAuthStore } from '@/stores/auth';
import MediaUploadField from '@/components/MediaUploadField.vue';
import {
  CHANNEL_OPTIONS,
  QR_UPLOAD_MEDIA_TYPE,
  addWhitelist,
  channelLabel,
  createQrCode,
  deleteQrCode,
  getConfig,
  grantRequest,
  listQrCodes,
  listRequests,
  listWhitelist,
  rejectRequest,
  removeWhitelist,
  statusLabel,
  updateConfig,
  updateQrCode,
  type RechargeAdminEntry,
  type RechargeChannel,
  type RechargeConfig,
  type RechargeQrCode,
  type RechargeRequestRow,
} from '@/api/recharge';
import {
  NAlert,
  NButton,
  NDataTable,
  NDatePicker,
  NForm,
  NFormItem,
  NImage,
  NInput,
  NInputNumber,
  NModal,
  NSelect,
  NSwitch,
  NTabPane,
  NTabs,
  NTag,
  useDialog,
  useMessage,
} from 'naive-ui';
import type { DataTableColumns } from 'naive-ui';
import { computed, h, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue';

const message = useMessage();
const dialog = useDialog();
const auth = useAuthStore();

const tab = ref<'requests' | 'qr' | 'config'>('requests');
/**
 * 权限（与后端 `recharge-admin.controller.ts` 的权限点映射逐条对应；前端只做隐藏/禁用，服务端才是权威）：
 * - 查看收款码/配置：`admin:setting:read`
 * - 改收款码（增删改 + 启停）：`admin:setting:write`（**不限超管**）
 * - 保存充值设置：`admin:setting:write` + **仅超管**（配置行 `is_high_security=1`，服务端 403）
 * - 白名单查看：`admin:admin:read`；增删：`admin:admin:write` + **仅超管**
 * - 申请列表：`recharge:review`；发放/驳回：`recharge:grant`
 */
const canReadSetting = computed(() => auth.hasPermission('admin:setting:read'));
const canWriteSetting = computed(() => auth.hasPermission('admin:setting:write'));
/** 上传图片是**另一把钥匙**（`POST /admin/media/upload` = admin:media:write）：没有就禁用上传控件并说明 */
const canUploadMedia = computed(() => auth.hasPermission('admin:media:write'));
/**
 * 上传控件的门禁（2026-10-07 修「收款码加不了」）：
 * **权限未知时不置灰**。`canUploadMedia` 在 `/auth/me` 还没回来时必然为 false
 * （permissions=[] 且 isSuperAdmin=false）—— 直接拿它当 `:disabled` 会让运营看到一个
 * "点不动 + 还谎报我没权限"的按钮，用户只会说「加不了」。
 * 现在：`me` 到位后才按权限点禁用；未知时就让它可点，真没权限由服务端 403 中文兜底。
 */
const uploadDisabled = computed(() => !!auth.me && !canUploadMedia.value);
const canWhitelistRead = computed(() => auth.hasPermission('admin:admin:read'));
/** 充值设置与白名单的写操作：**仅超管**（is_high_security / assertSuperAdmin 双闸门） */
const canConfig = computed(() => auth.isSuperAdmin);
/** 查看申请：专用窄权限 `recharge:review` */
const canReview = computed(() => auth.hasPermission('recharge:review'));
/** 发放/驳回：专用窄权限 `recharge:grant`（与 `admin:*` 大权限刻意分开） */
const canHandle = computed(() => auth.hasPermission('recharge:grant'));

/**
 * tab 级权限渲染：
 * - 可见的 tab = 有对应读权限的 tab（没权限的直接不渲染，不放"点了才 403"的死 tab）；
 * - 缺权限的 tab 在页头用一行说明"缺哪个权限点、去哪儿加"，避免运营以为是页面坏了。
 */
const visibleTabNames = computed(() => {
  const names: ('requests' | 'qr' | 'config')[] = [];
  if (canReview.value) names.push('requests');
  if (canReadSetting.value) names.push('qr', 'config');
  return names;
});
const hiddenPermHint = computed(() => {
  const missing: string[] = [];
  if (!canReview.value) missing.push('充值申请（需窄权限点 recharge:review）');
  if (!canReadSetting.value) missing.push('收款码与充值设置（需 admin:setting:read）');
  if (!missing.length) return '';
  return `当前账号看不到：${missing.join('、')}。这些权限点由超级管理员在「管理员与角色」里按角色勾选；无权限的接口服务端一律 403（前端只是不渲染，不是把权限藏起来）。`;
});

// ================================================================= 充值申请

const STATUS_FILTERS = [
  { label: '待核对', value: 'pending' },
  { label: '已发放', value: 'granted' },
  { label: '已驳回', value: 'rejected' },
];

const rows = ref<RechargeRequestRow[]>([]);
const total = ref(0);
const page = ref(1);
const pageSize = 20;
const reqLoading = ref(false);
const submittingId = ref<string | null>(null);

/** 状态筛选（空 = 全部）/ 关键词 / 时间范围（naive-ui 给毫秒时间戳） */
const filter = reactive<{ status: string | null; keyword: string; range: [number, number] | null }>({
  status: null,
  keyword: '',
  range: null,
});

function statusTagType(s: string): 'warning' | 'success' | 'error' | 'default' {
  if (s === 'pending') return 'warning';
  if (s === 'granted') return 'success';
  if (s === 'rejected') return 'error';
  return 'default';
}

function fmtTime(v: string | null | undefined): string {
  if (!v) return '—';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '—';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * 凭证大图（复用既有图片预览，不引新依赖）：
 * 先按公开媒体直连；读不到（受保护媒体会 403/404）再走 `protectedMediaUrl` 换成 blob 地址。
 * 两条都不通就保持「—」占位，不让表格整片崩。
 */
const voucherSrc = reactive<Record<string, string>>({});
const blobUrls: string[] = [];
function voucherUrl(id: string | null): string | null {
  if (!id) return null;
  return voucherSrc[id] ?? mediaPreviewPath(id);
}
async function onVoucherError(id: string) {
  if (voucherSrc[id]) return; // 已经退过一次，避免死循环
  try {
    const url = await protectedMediaUrl(id);
    blobUrls.push(url);
    voucherSrc[id] = url;
  } catch {
    /* 两条通道都读不到：保持占位 */
  }
}
onBeforeUnmount(() => {
  for (const u of blobUrls) URL.revokeObjectURL(u);
});

const requestColumns = computed<DataTableColumns<RechargeRequestRow>>(() => [
  {
    title: '用户',
    key: 'nickname',
    minWidth: 150,
    render: (r) => [
      h('div', { style: 'font-weight:600' }, r.nickname || '（无昵称）'),
      h('div', { style: 'font-size:12px;color:var(--color-text-tertiary)' }, r.uid || r.userId || '—'),
    ],
  },
  {
    // 付款金额（元）：¥ + 两位小数 —— 老板自己付的真金白银，格式必须一眼可核对
    title: '金额',
    key: 'amount',
    width: 110,
    render: (r) => h('span', {}, formatYuanOr(r.amount)),
  },
  {
    // 到账余额（元）：同样是「元」口径 → ¥ + 两位小数（旧口径这里写的是「应得积分」+N）
    title: '应得余额',
    key: 'points',
    width: 120,
    render: (r) => h('strong', { style: 'color:var(--color-primary)' }, `+${formatYuan(r.points)}`),
  },
  {
    title: '付款凭证',
    key: 'voucherMediaId',
    width: 96,
    render: (r) => {
      const src = voucherUrl(r.voucherMediaId);
      if (!src) return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '未上传');
      return h(NImage, {
        src,
        width: 52,
        height: 52,
        objectFit: 'cover',
        style: 'border-radius:4px',
        // 点缩略图看大图（n-image 自带预览层，不需要新依赖）
        onError: () => void onVoucherError(r.voucherMediaId as string),
      });
    },
  },
  {
    title: '提交时间',
    key: 'createdAt',
    width: 150,
    render: (r) => h('span', { style: 'font-size:12.5px' }, fmtTime(r.createdAt)),
  },
  {
    title: '状态',
    key: 'status',
    width: 96,
    render: (r) =>
      h(NTag, { size: 'small', type: statusTagType(r.status) }, { default: () => statusLabel(r.status) }),
  },
  {
    title: '审核人 / 时间',
    key: 'reviewerName',
    width: 168,
    render: (r) => {
      if (r.status === 'pending') return h('span', { style: 'color:var(--color-text-tertiary);font-size:12.5px' }, '待核对');
      return [
        h('div', {}, r.reviewerName || '—'),
        h('div', { style: 'font-size:12px;color:var(--color-text-tertiary)' }, fmtTime(r.reviewedAt)),
      ];
    },
  },
  {
    // 列宽和 = 150+110+120+96+150+96+168+180 = 1070 → 模板 :scroll-x = 1070
    // fixed:'right'：横向滚动时「发放/驳回」始终完整可见（这条链路最容易点错，必须一眼看到）
    title: '操作',
    key: 'actions',
    width: 180,
    fixed: 'right',
    render: (r) => {
      if (r.status !== 'pending') {
        if (r.status === 'rejected') {
          return h(
            'span',
            { style: 'color:var(--color-text-tertiary);font-size:12px', title: r.rejectReason },
            `已驳回：${r.rejectReason || '（无原因）'}`,
          );
        }
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '已发放（不可重复发放）');
      }
      if (!canHandle.value) {
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '无发放权限');
      }
      return h('div', { style: 'display:flex;gap:8px' }, [
        h(
          NButton,
          {
            size: 'small',
            type: 'primary',
            loading: submittingId.value === r.id,
            disabled: submittingId.value !== null,
            onClick: () => confirmGrant(r),
          },
          { default: () => '发放' },
        ),
        h(
          NButton,
          {
            size: 'small',
            type: 'error',
            quaternary: true,
            disabled: submittingId.value !== null,
            onClick: () => openReject(r),
          },
          { default: () => '驳回' },
        ),
      ]);
    },
  },
]);

async function loadRequests() {
  reqLoading.value = true;
  try {
    const { list, total: t } = await listRequests({
      status: filter.status ?? undefined,
      keyword: filter.keyword.trim() || undefined,
      startAt: filter.range?.[0] ?? null,
      endAt: filter.range?.[1] ?? null,
      page: page.value,
      pageSize,
    });
    rows.value = list;
    total.value = t;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '充值申请加载失败');
  } finally {
    reqLoading.value = false;
  }
}

function applyFilter() {
  page.value = 1;
  void loadRequests();
}

function resetFilter() {
  filter.status = null;
  filter.keyword = '';
  filter.range = null;
  applyFilter();
}

function onPageChange(p: number) {
  page.value = p;
  void loadRequests();
}

/** 发放二次确认：明确写清「给 X 发放 N 元余额」，并说明这是手工发放、不是支付 */
function confirmGrant(r: RechargeRequestRow) {
  const who = `${r.nickname || '（无昵称）'}（${r.uid || r.userId}）`;
  dialog.warning({
    title: '确认发放余额',
    content: `给 ${who} 发放 ${formatYuan(r.points)} 余额？\n\n对应付款金额 ${formatYuan(r.amount)}。发放后立即计入该账号余额，并写入一条余额流水与操作审计；余额仅可用于平台内消费，不可提现、不可转让；重复发放会被服务端拒绝。`,
    positiveText: `确认发放 ${formatYuan(r.points)}`,
    negativeText: '取消',
    onPositiveClick: async () => {
      if (submittingId.value) return; // 防重复提交（按钮同时置忙）
      submittingId.value = r.id;
      try {
        await grantRequest(r.id);
        message.success(`已发放：给 ${who} 发放 ${formatYuan(r.points)} 余额`);
        await loadRequests();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '发放失败');
      } finally {
        submittingId.value = null;
      }
    },
  });
}

// ---------------- 驳回（必填原因） ----------------
const showReject = ref(false);
const rejectRow = ref<RechargeRequestRow | null>(null);
const rejectReason = ref('');
const rejectTouched = ref(false);
const rejecting = ref(false);

function openReject(r: RechargeRequestRow) {
  rejectRow.value = r;
  rejectReason.value = '';
  rejectTouched.value = false;
  showReject.value = true;
}

async function doReject() {
  const r = rejectRow.value;
  rejectTouched.value = true;
  if (!r || !rejectReason.value.trim()) {
    message.warning('驳回必须填写原因');
    return;
  }
  rejecting.value = true;
  try {
    await rejectRequest(r.id, rejectReason.value.trim());
    message.success('已驳回（原因已通知申请人）');
    showReject.value = false;
    await loadRequests();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '驳回失败');
  } finally {
    rejecting.value = false;
  }
}

// ================================================================= 收款码

const qrRows = ref<RechargeQrCode[]>([]);
const qrLoading = ref(false);
const showQrModal = ref(false);
const qrSaving = ref(false);
const qrForm = reactive<{
  id: string | null;
  channel: RechargeChannel;
  label: string;
  sort: number;
  enabled: boolean;
  imageMediaId: string | null;
}>({ id: null, channel: 'wechat', label: '', sort: 0, enabled: true, imageMediaId: null });

/** MediaUploadField 的 v-model 是 string|null（undefined 会触发类型错误） */
const qrImageModel = computed<string | null>({
  get: () => qrForm.imageMediaId,
  set: (v) => {
    qrForm.imageMediaId = v;
  },
});

const qrColumns = computed<DataTableColumns<RechargeQrCode>>(() => [
  {
    title: '收款码',
    key: 'imageMediaId',
    width: 108,
    render: (r) => {
      const src = r.imageMediaId ? mediaPreviewPath(r.imageMediaId) : null;
      return src
        ? h(NImage, { src, width: 64, height: 64, objectFit: 'contain', style: 'border-radius:4px' })
        : h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '未配图');
    },
  },
  {
    title: '渠道',
    key: 'channel',
    width: 92,
    render: (r) => h(NTag, { size: 'small' }, { default: () => channelLabel(r.channel) }),
  },
  {
    title: '标签',
    key: 'label',
    minWidth: 160,
    render: (r) => r.label || h('span', { style: 'color:var(--color-text-tertiary)' }, '（未填标签）'),
  },
  { title: '排序', key: 'sort', width: 74 },
  {
    title: '状态',
    key: 'enabled',
    width: 92,
    render: (r) =>
      h(NTag, { size: 'small', type: r.enabled ? 'success' : 'default' }, { default: () => (r.enabled ? '启用中' : '已停用') }),
  },
  {
    // 列宽和 = 108+92+160+74+92+220 = 746 → 模板 :scroll-x = 746
    // fixed:'right'：横向滚动时「编辑/启停/删除」始终完整可见
    title: '操作',
    key: 'actions',
    width: 220,
    fixed: 'right',
    render: (r) => {
      if (!canWriteSetting.value) {
        return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '只读：需 admin:setting:write');
      }
      return h('div', { style: 'display:flex;gap:8px' }, [
        h(NButton, { size: 'tiny', onClick: () => openQrEdit(r) }, { default: () => '编辑' }),
        h(
          NButton,
          { size: 'tiny', onClick: () => toggleQr(r) },
          { default: () => (r.enabled ? '停用' : '启用') },
        ),
        h(
          NButton,
          { size: 'tiny', type: 'error', quaternary: true, onClick: () => confirmDeleteQr(r) },
          { default: () => '删除' },
        ),
      ]);
    },
  },
]);

async function loadQrCodes() {
  if (!canReadSetting.value) return; // 无 admin:setting:read 时不发请求，由页面提示说明
  qrLoading.value = true;
  try {
    qrRows.value = await listQrCodes();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '收款码加载失败');
  } finally {
    qrLoading.value = false;
  }
}

function openQrCreate() {
  Object.assign(qrForm, {
    id: null,
    channel: 'wechat' as RechargeChannel,
    label: '',
    sort: (qrRows.value.at(-1)?.sort ?? qrRows.value.length) + 1,
    enabled: true,
    imageMediaId: null,
  });
  showQrModal.value = true;
}

function openQrEdit(r: RechargeQrCode) {
  Object.assign(qrForm, {
    id: r.id,
    channel: r.channel,
    label: r.label,
    sort: r.sort,
    enabled: r.enabled,
    imageMediaId: r.imageMediaId,
  });
  showQrModal.value = true;
}

function qrPayload() {
  return {
    channel: qrForm.channel,
    label: qrForm.label.trim(),
    sort: Number(qrForm.sort) || 0,
    enabled: qrForm.enabled,
    imageMediaId: qrForm.imageMediaId,
  };
}

async function saveQrCode() {
  if (!qrForm.imageMediaId) {
    message.warning('请先上传收款码图片');
    return;
  }
  qrSaving.value = true;
  try {
    if (qrForm.id) await updateQrCode(qrForm.id, qrPayload());
    else await createQrCode(qrPayload());
    message.success(qrForm.enabled ? '已保存（老板端下一次请求即拿到这张码）' : '已保存（当前为停用，老板端不会返回）');
    showQrModal.value = false;
    await loadQrCodes();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    qrSaving.value = false;
  }
}

/** 启停：提交完整字段（避免后端 DTO 要求必填字段时报 400） */
async function toggleQr(r: RechargeQrCode) {
  try {
    await updateQrCode(r.id, {
      channel: r.channel,
      label: r.label,
      sort: r.sort,
      enabled: !r.enabled,
      imageMediaId: r.imageMediaId,
    });
    message.success(r.enabled ? '已停用（老板端不再返回这张码）' : '已启用（老板端下一次请求即可见）');
    await loadQrCodes();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '操作失败');
  }
}

function confirmDeleteQr(r: RechargeQrCode) {
  dialog.error({
    title: '删除收款码',
    content: `确认删除「${channelLabel(r.channel)}${r.label ? ' · ' + r.label : ''}」？删除后老板端立即不再显示这张码，已提交的申请不受影响。`,
    positiveText: '确认删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await deleteQrCode(r.id);
        message.success('已删除');
        await loadQrCodes();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

// ================================================================= 充值设置

const cfgSaving = ref(false);
/** 输入中的草稿（保存前不影响线上） */
const draft = reactive<RechargeConfig>({
  amountOptions: [],
  customEnabled: true,
  minYuan: 1,
  maxYuan: 9999,
  pointsPerYuan: 10,
  pendingLimitPerUser: 3,
  adminLimit: 5,
  noticeText: '',
  /** 服务端下发的只读附加项（保存时不提交，只是页面展示用） */
  superAdminOnly: true,
  adminLimitMax: 5,
});
/** 库中当前生效值（用于「重置」与脏检查） */
const saved = ref<RechargeConfig | null>(null);
const newAmount = ref<number | null>(null);
const editingAmount = ref<number | null>(null);
/** 比例被改过（用于加重提醒） */
const ratioTouched = ref(false);

const cfgDirty = computed(() => {
  const s = saved.value;
  if (!s) return false;
  return (
    JSON.stringify(draft.amountOptions) !== JSON.stringify(s.amountOptions) ||
    draft.customEnabled !== s.customEnabled ||
    draft.minYuan !== s.minYuan ||
    draft.maxYuan !== s.maxYuan ||
    draft.pointsPerYuan !== s.pointsPerYuan ||
    draft.pendingLimitPerUser !== s.pendingLimitPerUser ||
    draft.adminLimit !== s.adminLimit ||
    draft.noticeText !== s.noticeText
  );
});

const amountRangeError = computed(() => {
  if (draft.minYuan == null || draft.maxYuan == null) return '下限/上限都要填';
  if (!(draft.minYuan > 0)) return '下限要大于 0';
  if (draft.maxYuan < draft.minYuan) return '上限不能小于下限';
  return '';
});

function previewPoints(yuan: number): string {
  const n = (draft.pointsPerYuan ?? 0) * yuan;
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

function touchRatio() {
  ratioTouched.value = true;
}

function addAmount() {
  const v = Number(newAmount.value);
  if (!Number.isFinite(v) || v <= 0) {
    message.warning('面额要是大于 0 的数字');
    return;
  }
  // 后端 assertRechargeConfig 只接受整数元（toInt），这里同样取整，避免"填了 7.5 → 保存才 400"
  const rounded = Math.round(v);
  if (rounded !== v) {
    message.warning('面额只能是整数元（后端口径），已按四舍五入处理');
  }
  if (draft.amountOptions.includes(rounded)) {
    message.warning(`档位里已经有 ${rounded} 元了`);
    return;
  }
  draft.amountOptions = [...draft.amountOptions, rounded].sort((a, b) => a - b);
  newAmount.value = null;
  editingAmount.value = null;
}

function removeAmount(v: number) {
  draft.amountOptions = draft.amountOptions.filter((x) => x !== v);
  if (editingAmount.value === v) editingAmount.value = null;
}

/** 点标签 = 把该档位取回输入框（改完回车放回），实现「可增删改」里的「改」 */
function pickAmount(v: number) {
  if (!canConfig.value) return;
  removeAmount(v);
  newAmount.value = v;
  editingAmount.value = v;
}

async function loadConfig() {
  if (!canReadSetting.value) return;
  try {
    const cfg = await getConfig();
    saved.value = cfg;
    Object.assign(draft, {
      amountOptions: [...cfg.amountOptions],
      customEnabled: cfg.customEnabled,
      minYuan: cfg.minYuan,
      maxYuan: cfg.maxYuan,
      pointsPerYuan: cfg.pointsPerYuan,
      pendingLimitPerUser: cfg.pendingLimitPerUser,
      adminLimit: cfg.adminLimit,
      noticeText: cfg.noticeText,
      superAdminOnly: cfg.superAdminOnly,
      adminLimitMax: cfg.adminLimitMax,
    });
    ratioTouched.value = false;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '充值设置加载失败');
  }
}

async function saveConfig() {
  if (!canConfig.value) {
    message.warning('充值设置仅超级管理员可改');
    return;
  }
  if (amountRangeError.value) {
    message.error(amountRangeError.value);
    return;
  }
  if (!draft.amountOptions.length && !draft.customEnabled) {
    message.error('档位为空且关闭了自定义金额：老板端将没有可选金额');
    return;
  }
  cfgSaving.value = true;
  try {
    await updateConfig({
      amountOptions: [...draft.amountOptions].sort((a, b) => a - b),
      customEnabled: draft.customEnabled,
      minYuan: Number(draft.minYuan),
      maxYuan: Number(draft.maxYuan),
      pointsPerYuan: Number(draft.pointsPerYuan),
      pendingLimitPerUser: Number(draft.pendingLimitPerUser),
      adminLimit: Number(draft.adminLimit),
      noticeText: draft.noticeText,
    });
    message.success('已保存：老板端下一次请求即按新口径下发');
    // 保存后回读一次，页面上显示的"当前生效"必须是库里的值（不是本地草稿）
    await loadConfig();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '保存失败');
  } finally {
    cfgSaving.value = false;
  }
}

// ---------------- 管理员白名单 ----------------

const whitelist = ref<RechargeAdminEntry[]>([]);
const wlLoading = ref(false);
const wlAdding = ref(false);
const pickedAdminId = ref<string | null>(null);
/**
 * 可选的管理员账号（只取 role=admin 且未封禁、且不在白名单里的）。
 *
 * ⚠️ value 必须是 **`user.id`**（`AdminRow.userId`），不是 `admin.id`：
 * 后端 `POST /admin/recharge/admins` 收的是 `adminUserId` = 管理员**账号**的 user id
 * （`recharge_admin.user_id` 主键），传 admin 表的行 id 会去查错账号。
 * 本轮 CDP 实测抓到过这一处（选中的是 admin.id → 加不进去），故在此显式写明。
 */
const adminCandidates = ref<{ id: string; label: string }[]>([]);
const adminsLoading = ref(false);

const whitelistFull = computed(() => whitelist.value.length >= (draft.adminLimit || 0));

const adminOptions = computed(() =>
  adminCandidates.value.map((c) => ({ label: c.label, value: c.id })),
);

async function loadAdmins() {
  if (!canWhitelistRead.value) return; // 候选账号来自 GET /admin/admins（同一把钥匙）
  adminsLoading.value = true;
  try {
    const list = await request<
      { id: string; userId: string; username: string; nickname: string; status: number; roleCode: string }[]
    >('GET', '/admin/admins');
    const used = new Set(whitelist.value.map((w) => w.adminUserId));
    adminCandidates.value = list
      .filter((a) => a.status === 1 && !used.has(a.userId) && !used.has(a.id))
      .map((a) => ({
        // value = 管理员账号的 user id（与后端 adminUserId 同义）；label 供运营按昵称/用户名搜索
        id: a.userId,
        label: `${a.nickname || a.username}（${a.username} · ${a.roleCode}）`,
      }));
  } catch (e) {
    // 窄权限运营可能没有 admin:admin:read：不阻断页面，只提示
    adminCandidates.value = [];
    message.error(e instanceof ApiException ? e.message : '管理员账号列表加载失败（需要 admin:admin:read）');
  } finally {
    adminsLoading.value = false;
  }
}

const whitelistColumns = computed<DataTableColumns<RechargeAdminEntry>>(() => [
  {
    title: '管理员',
    key: 'nickname',
    minWidth: 160,
    render: (r) => [
      h('div', { style: 'font-weight:600' }, r.nickname || r.username || '（未知账号）'),
      h('div', { style: 'font-size:12px;color:var(--color-text-tertiary)' }, r.username || r.adminUserId),
    ],
  },
  {
    title: '角色',
    key: 'roleCode',
    width: 130,
    render: (r) => h(NTag, { size: 'small' }, { default: () => r.roleCode || 'admin' }),
  },
  {
    title: '加入时间',
    key: 'createdAt',
    width: 160,
    render: (r) => h('span', { style: 'font-size:12.5px' }, fmtTime(r.createdAt)),
  },
  {
    // 列宽和 = 160+130+160+120 = 570 → 模板 :scroll-x = 570
    // fixed:'right'：横向滚动时「移出」始终完整可见
    title: '操作',
    key: 'actions',
    width: 120,
    fixed: 'right',
    render: (r) => {
      if (!canConfig.value) return h('span', { style: 'color:var(--color-text-tertiary);font-size:12px' }, '仅超管可改');
      return h(
        NButton,
        { size: 'tiny', type: 'error', quaternary: true, onClick: () => confirmRemoveWhitelist(r) },
        { default: () => '移出' },
      );
    },
  },
]);

async function loadWhitelist() {
  if (!canWhitelistRead.value) return; // GET /admin/recharge/admins 需要 admin:admin:read
  wlLoading.value = true;
  try {
    whitelist.value = await listWhitelist();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '白名单加载失败');
  } finally {
    wlLoading.value = false;
  }
}

async function addWhitelistEntry() {
  if (!pickedAdminId.value) return;
  if (whitelistFull.value) {
    message.warning(`已达上限 ${whitelist.value.length}/${draft.adminLimit}，先移除一个才能再加`);
    return;
  }
  wlAdding.value = true;
  try {
    await addWhitelist(pickedAdminId.value);
    message.success('已加入白名单（该管理员现在可以核对并发放充值余额）');
    pickedAdminId.value = null;
    await loadWhitelist();
    await loadAdmins();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加入失败');
  } finally {
    wlAdding.value = false;
  }
}

function confirmRemoveWhitelist(r: RechargeAdminEntry) {
  dialog.warning({
    title: '移出白名单',
    content: `确认把「${r.nickname || r.username || r.adminUserId}」移出白名单？移出后他不能再发放充值余额（已发放的记录不受影响）。`,
    positiveText: '确认移出',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await removeWhitelist(r.id);
        message.success('已移出白名单');
        await loadWhitelist();
        await loadAdmins();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '移出失败');
      }
    },
  });
}

/**
 * 首屏加载：**必须等 `auth.me` 就绪**（权限点来自 /auth/me）。
 *
 * 踩过的坑（本轮实测抓到）：子页面 `onMounted` 会先于 `LayoutView` 的 `auth.fetchMe()` 完成，
 * 此时 `auth.permissions` 还是空数组 → 按权限点分派的 `loadConfig()` 直接 return，
 * 「充值设置」整片回落到默认值、保存按钮因"没改动"而置灰（页面看起来正常，其实是空的）。
 * 故用 watch(me) + 只跑一次的方式，me 一到就补加载。
 */
const inited = ref(false);
async function init() {
  if (inited.value || !auth.me) return;
  inited.value = true;
  // 当前 tab 没权限时落到第一个可见 tab（否则会停在"空 tabs"上）
  if (!visibleTabNames.value.includes(tab.value)) {
    tab.value = visibleTabNames.value[0] ?? 'requests';
  }
  // 按权限点分派：缺权限的接口**不发请求**（否则满页红色报错，运营以为页面坏了）
  await Promise.all([
    canReview.value ? loadRequests() : Promise.resolve(),
    loadQrCodes(),
    loadConfig(),
    loadWhitelist(),
  ]);
  await loadAdmins();
}
onMounted(() => void init());
watch(
  () => auth.me,
  () => void init(),
);
</script>

<style scoped>
.recharge-page {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

/* 页头：左对齐、组内紧（标题与说明 6px）、组间松（与 tabs 20px）—— docs/21 的节奏要求 */
.page-head h1 {
  margin: 0;
  font-size: 17px;
  font-weight: 600;
}
.lede {
  margin: 6px 0 0;
  font-size: 12.5px;
  line-height: 1.75;
  color: var(--color-text-secondary);
  max-width: 900px;
}

.tabs {
  background: var(--color-bg-card, #fff);
  border: 1px solid var(--color-divider, #eef0f4);
  border-radius: var(--radius-card, 12px);
  padding: 4px 16px 16px;
}

.filter-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 14px;
}
.spacer {
  flex: 1;
}
.count {
  font-size: 12.5px;
  color: var(--color-text-secondary);
}
.ro-hint {
  margin: 0 0 12px;
  font-size: 12px;
  line-height: 1.7;
  color: var(--color-warning, #f59e0b);
}
/* 缺权限说明（tab 级渲染）：一行可见提示 + 无权限时的整块说明，都不用卡片、不留阴影 */
.perm-note {
  margin: 0;
  padding: 8px 12px;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--color-text-secondary);
  background: #fff7e6;
  border: 1px solid #f5e0b7;
  border-radius: 6px;
}
.perm-block {
  padding: 28px 16px 30px;
  text-align: center;
  background: var(--color-bg-card, #fff);
  border: 1px solid var(--color-divider, #eef0f4);
  border-radius: var(--radius-card, 12px);
}
.perm-title {
  font-size: 14px;
  font-weight: 600;
}
.perm-sub {
  margin-top: 6px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-tertiary);
}
.ro-banner {
  margin-bottom: 8px;
}

/* 分区之间用发丝线，不堆卡片（docs/21：列表/分区优先于卡片阵；阴影只给弹层） */
.block {
  padding: 16px 0;
  border-top: 1px solid var(--color-divider, #eef0f4);
}
.block:first-of-type {
  border-top: none;
  padding-top: 8px;
}
.block-head {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.block-head h2 {
  margin: 0;
  font-size: 14px;
  font-weight: 600;
}
.block-sub {
  font-size: 12px;
  color: var(--color-text-tertiary);
  line-height: 1.6;
}
.used-tag {
  margin-left: auto;
}

.row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
  margin-bottom: 10px;
}
.row:last-child {
  margin-bottom: 0;
}
.row-label {
  font-size: 13px;
  color: var(--color-text-secondary);
}
.field-label {
  font-size: 13px;
  color: var(--color-text-secondary);
}
.mini-hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.err {
  font-size: 12px;
  color: var(--color-error, #ef4444);
}
.preview {
  font-size: 12.5px;
  color: var(--color-text-secondary);
}

.chips {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  min-height: 30px;
  margin-bottom: 12px;
}
.amount-chip {
  cursor: pointer;
}
.chips-empty {
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.chips-add {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}

.ratio-warn {
  margin-top: 4px;
  max-width: 900px;
}
.ratio-changed {
  display: block;
  margin-top: 6px;
  font-weight: 600;
}
.ops {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px 0 4px;
  border-top: 1px solid var(--color-divider, #eef0f4);
}
.whitelist {
  padding-bottom: 0;
}
.add-row {
  margin-bottom: 12px;
}
.modal-footer {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
}
.reject-info {
  margin: 0 0 12px;
  font-size: 13px;
  line-height: 1.8;
  color: var(--color-text-secondary);
}

/* 空态：说清"为什么空 + 下一步做什么"（docs/21 要求必须设计空态） */
.empty {
  padding: 28px 16px 30px;
  text-align: center;
}
.empty-title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}
.empty-sub {
  margin-top: 6px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--color-text-tertiary);
}
</style>
