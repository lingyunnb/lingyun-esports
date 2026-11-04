<script setup lang="ts">
// 游戏与商品管理（docs/02、docs/13）：游戏/分类/商品全生命周期（新增/编辑/删除/上下架）
// 删除受服务端引用保护：有下级的游戏/分类、有订单记录的商品会被拒绝并提示原因
// 口径（2026-10-09）：金额一律 ¥ + 两位小数（元；API 字段名不变）
import { ApiException, request } from '@/api/client';
import { formatYuan } from '@/utils/format';
import MediaUploadField from '@/components/MediaUploadField.vue';
import { NAlert, NButton, NCheckbox, NDataTable, NDropdown, NForm, NFormItem, NInput, NInputNumber, NModal, NRadio, NRadioGroup, NSelect, NSwitch, NTabPane, NTabs, NTag, useDialog, useMessage } from 'naive-ui';
import { computed, h, onMounted, reactive, ref } from 'vue';

interface GameRow {
  id: string;
  code: string;
  name: string;
  sortOrder: number;
  status: number;
}

interface CategoryRow {
  id: string;
  gameId: string;
  name: string;
  sortOrder: number;
  status: number;
}

interface ProductRow {
  id: string;
  name: string;
  subtitle: string;
  /** 列表短名（负责人 2026-10-05 任务②；客户端商品列表卡显示用，留空=列表用完整 name） */
  listName?: string | null;
  /** 徽标文案（负责人 2026-10-05；如「董事长推荐」，留空=不显示） */
  badgeText?: string | null;
  /** 每周限购（单/账号/周；null/0 = 不限） */
  weeklyLimit?: number | null;
  /** 限购口径（任务③）：0=按订单条数（默认）/ 1=按件数 SUM(quantity) */
  weeklyLimitByQuantity?: number | null;
  /** 商品级下单须知（null/空 = 继承平台默认；迁移 1799000000000） */
  orderNotice?: string | null;
  gameId: string;
  categoryId: string;
  divisionId?: string | null;
  divisionName?: string | null;
  price: number;
  priceUnit: string;
  estimateDurationMin: number;
  serviceStatus: number;
  salesCount: number;
  sortOrder: number;
  coverMediaId?: string | null;
  videoMediaId?: string | null;
}

/** 分部（负责人 2026-10-04：商品必须能挂分部，否则「商品在哪个分部显示」不准） */
interface DivisionRow {
  id: string;
  name: string;
  shortName?: string;
  platform?: string;
  platformLabel?: string;
  gameId?: string;
  status?: number;
}

/** 商品移动结果（POST /admin/products/move 的返回，负责人 2026-10-05） */
interface MoveResult {
  moved: number;
  skipped: number;
  failed: { id: string; reason: string }[];
  createdCategories: { id: string; name: string }[];
}

const message = useMessage();
const dialog = useDialog();
const games = ref<GameRow[]>([]);
const categories = ref<CategoryRow[]>([]);
const products = ref<ProductRow[]>([]);
const divisions = ref<DivisionRow[]>([]);
const loading = ref(false);
const filterGame = ref<string | null>(null);
const filterCategory = ref<string | null>(null);
/**
 * 分部筛选（负责人 2026-10-05 报障修复）
 *
 * 后端 `GET /admin/products?divisionId=` 此前没生效（controller 没透传 + service 没条件），
 * 修好后这里补上入口：不选 = 全部分部；选中只看该分部商品。
 */
const filterDivision = ref<string | null>(null);
/**
 * 商品多选（负责人 2026-10-05：批量移动到另一个分部）
 *
 * 存的是**选中行的 id**（row-key），列表刷新后键值仍然有效，不会因为重排丢选中。
 * 筛选条件不变时刷新列表，Naive UI 会按 row-key 保留仍在结果里的选中项。
 */
const checkedProductIds = ref<Array<string | number>>([]);
const catFilterGame = ref<string | null>(null);

async function loadGames() {
  const data = await request<GameRow[]>('GET', '/admin/games');
  games.value = data;
}
async function loadCategories() {
  const data = await request<CategoryRow[]>('GET', '/admin/categories');
  categories.value = data;
}
async function loadDivisions() {
  // 下拉选项与「分部名回显」共用同一份数据（管理端接口含下架分部）
  try {
    const data = await request<DivisionRow[]>('GET', '/admin/divisions');
    divisions.value = Array.isArray(data) ? data : [];
  } catch {
    divisions.value = [];
  }
  if (divisions.value.length) return;
  // 兜底：管理端分部接口异常/为空时取公开接口（负责人 2026-10-04：三个分部必须都能选到）
  try {
    const pub = await request<DivisionRow[]>('GET', '/divisions');
    divisions.value = Array.isArray(pub) ? pub : [];
  } catch {
    divisions.value = [];
  }
}
async function loadProducts() {
  loading.value = true;
  try {
    const q = new URLSearchParams({ page: '1', pageSize: '50' });
    if (filterGame.value) q.set('gameId', filterGame.value);
    if (filterCategory.value) q.set('categoryId', filterCategory.value);
    if (filterDivision.value) q.set('divisionId', filterDivision.value);
    const data = await request<{ list: ProductRow[] }>('GET', `/admin/products?${q.toString()}`);
    products.value = data.list;
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  } finally {
    loading.value = false;
  }
}
onMounted(async () => {
  try {
    await loadGames();
    await loadCategories();
    await loadDivisions();
    await loadProducts();
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '加载失败');
  }
  // 平台默认下单须知：**独立于上面 try**（它失败不该让整个页面报「加载失败」），
  // 商品编辑弹窗的「继承」态要显示它
  void loadNoticeDefault();
});

const catOptions = computed(() => categories.value.filter((c) => c.gameId === filterGame.value).map((c) => ({ label: c.name, value: c.id })));
const catFiltered = computed(() => categories.value.filter((c) => !catFilterGame.value || c.gameId === catFilterGame.value));
const divisionOptions = computed(() =>
  divisions.value.map((d) => ({ label: `${d.name}${d.status === 0 ? '（已下架）' : ''}`, value: String(d.id) })),
);
/** 「分部筛选」下拉：名称 + 手游/端游（下架分部也能筛，因为历史商品可能还挂在它下面） */
const divisionFilterOptions = computed(() =>
  divisions.value.map((d) => {
    const platformTag = d.platformLabel || (d.platform === 'pc' ? '端游' : '手游');
    return {
      label: `${d.name.includes(platformTag) ? d.name : `${d.name}（${platformTag}）`}${d.status === 0 ? '（已下架）' : ''}`,
      value: String(d.id),
    };
  }),
);
/** 分部名回显：列表接口优先用回带的 divisionName，缺失时按 divisionId 兜底映射 */
function divisionLabel(row: ProductRow): string {
  if (row.divisionName) return row.divisionName;
  const hit = divisions.value.find((d) => String(d.id) === String(row.divisionId));
  return hit ? hit.name : '未挂分部';
}

// ---------- 游戏：新增/编辑/删除 ----------
const showGameModal = ref(false);
const editGameId = ref<string | null>(null);
const gameForm = reactive({ code: '', name: '', sortOrder: 0 });
function openCreateGame() {
  editGameId.value = null;
  Object.assign(gameForm, { code: '', name: '', sortOrder: 0 });
  showGameModal.value = true;
}
function openEditGame(row: GameRow) {
  editGameId.value = row.id;
  Object.assign(gameForm, { code: row.code, name: row.name, sortOrder: row.sortOrder });
  showGameModal.value = true;
}
async function saveGame() {
  if (!gameForm.name || (!editGameId.value && !gameForm.code)) { message.warning('请填写名称与 Code'); return; }
  try {
    if (editGameId.value) {
      await request('PUT', `/admin/games/${editGameId.value}`, { name: gameForm.name, sortOrder: gameForm.sortOrder });
      message.success('游戏已更新');
    } else {
      await request('POST', '/admin/games', { ...gameForm });
      message.success('游戏已创建');
    }
    showGameModal.value = false;
    await loadGames();
  } catch (e) { message.error(e instanceof ApiException ? e.message : '保存失败'); }
}
async function toggleGameStatus(row: GameRow) {
  try {
    await request('PUT', `/admin/games/${row.id}`, { status: row.status === 1 ? 2 : 1 });
    await loadGames();
  } catch (e) { message.error(e instanceof ApiException ? e.message : '操作失败'); }
}
function deleteGame(row: GameRow) {
  dialog.warning({
    title: '删除游戏',
    content: `确定删除「${row.name}」？有分类或商品时会被拒绝。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/games/${row.id}`);
        message.success('游戏已删除');
        await loadGames();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

// ---------- 分类：新增/编辑/删除 ----------
const showCatModal = ref(false);
const editCatId = ref<string | null>(null);
const catForm = reactive({ gameId: '', name: '', sortOrder: 0 });
function openCreateCat() {
  editCatId.value = null;
  // 已在上方筛选了游戏则默认带入，否则在弹窗内选择（弹窗本身有「游戏」选择项）
  Object.assign(catForm, { gameId: catFilterGame.value || games.value[0]?.id || '', name: '', sortOrder: 0 });
  showCatModal.value = true;
}
function openEditCat(row: CategoryRow) {
  editCatId.value = row.id;
  Object.assign(catForm, { gameId: row.gameId, name: row.name, sortOrder: row.sortOrder });
  showCatModal.value = true;
}
async function saveCat() {
  if (!catForm.name || !catForm.gameId) { message.warning('请填写名称并选择游戏'); return; }
  try {
    if (editCatId.value) {
      await request('PUT', `/admin/categories/${editCatId.value}`, { name: catForm.name, sortOrder: catForm.sortOrder });
      message.success('分类已更新');
    } else {
      await request('POST', '/admin/categories', { ...catForm });
      message.success('分类已创建');
    }
    showCatModal.value = false;
    await loadCategories();
  } catch (e) { message.error(e instanceof ApiException ? e.message : '保存失败'); }
}
function deleteCat(row: CategoryRow) {
  dialog.warning({
    title: '删除分类',
    content: `确定删除「${row.name}」？该分类下有商品时会被拒绝。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/categories/${row.id}`);
        message.success('分类已删除');
        await loadCategories();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

// ---------- 商品：新增/编辑/上下架/删除 ----------
const showProductModal = ref(false);
const editProductId = ref<string | null>(null);
/** 创建后是否立即上架（默认不勾：保持 docs/02「新建默认下架、防误上架」的既有行为） */
const publishAfterCreate = ref(false);
/**
 * 平台默认下单须知（`GET /admin/order-notice`，商品未覆盖时下发的就是它）。
 *
 * 声明放在 [productForm] **之前**：下面的 `noticeOverride` / `effectiveNotice` 会读它，
 * 而 TDZ 限制要求先声明后使用（放后面 TS 直接报"在声明前使用"）。
 *
 * 拉失败不阻断编辑：把空串当默认 —— 此时「继承」态的说明会显示"读取失败"，
 * 比静默显示一片空白要诚实。
 */
const noticeDefault = ref('');
const noticeDefaultLoaded = ref(false);
async function loadNoticeDefault() {
  try {
    const resp = await request<{ text: string }>('GET', '/admin/order-notice');
    noticeDefault.value = resp?.text ?? '';
  } catch {
    noticeDefault.value = '';
  } finally {
    noticeDefaultLoaded.value = true;
  }
}

const productForm = reactive({
  name: '', subtitle: '', gameId: '', categoryId: '', divisionId: null as string | null,
  // 列表短名（任务②）：只在客户端**商品列表卡**上替代完整名显示；留空=列表用完整名（详情/订单仍用完整名）
  listName: '' as string,
  // 徽标文案 / 每周限购（负责人 2026-10-05）：徽标 = 商品卡左上角小片（留空不显示）；
  // 每周限购 = 每账号每周可下单数（留空或 0 = 不限，服务端下单事务内强制）
  // 限购口径（任务③）：0=按订单条数（默认，现状）/ 1=按件数（SUM(quantity)，一单 2 件占 2 个名额）
  badgeText: '' as string, weeklyLimit: null as number | null, weeklyLimitByQuantity: 0 as number,
  price: 100, priceUnit: '局', estimateDurationMin: 30,
  // 主图 / 视频 / 视频封面：视频两项的**表单状态与提交字段保留**（负责人 2026-10-05 只撤管理端入口，
  // 后端字段与接口不动）——保留才能让「编辑保存」原样回带已有 videoMediaId，不因撤入口而清库；
  // 恢复入口 = 在弹窗「主图」下方放回两个 n-form-item（模板里留了注释与原文）。
  coverMediaId: null as string | null, videoMediaId: null as string | null, videoCoverMediaId: null as string | null,
  // 下单须知（负责人 2026-10-05 商品详情页 v2 方案 B，迁移 1799000000000）：
  // null = **继承平台默认**（详情页下发平台默认那份）；非 null = 商品级覆盖。
  // 空串由服务端 UpdateProductDto 的 @Transform 统一转 NULL（= 回退继承），与 badgeText 同一口径。
  orderNotice: null as string | null,
});

/** 当前生效的下单须知（商品级覆盖优先 → 平台默认） */
const effectiveNotice = computed(() => {
  const own = (productForm.orderNotice ?? '').trim();
  return own.length ? own : noticeDefault.value;
});

/**
 * 「使用商品级下单须知（覆盖）」开关。
 *
 * 由 `orderNotice !== null` **派生**，不单独存一个 ref —— 两份状态一定会不同步
 * （同类事故：`divisionId` 与它的开关各存一份，"打开弹窗直接保存"就把分部清掉了）。
 */
const noticeOverride = computed({
  get: () => productForm.orderNotice !== null,
  set: (on: boolean) => {
    // 开：以**当前生效文本**作为起点，运营不必从空白开始写；关：置 null → 保存后即继承平台默认
    productForm.orderNotice = on ? effectiveNotice.value : null;
  },
});

/** 当前所选游戏下的分类（商品必须选分类） */
const productCategories = computed(() => categories.value.filter((c) => String(c.gameId) === String(productForm.gameId)));
const productCatOptions = computed(() => productCategories.value.map((c) => ({ label: c.name, value: String(c.id) })));
/** 当前所选游戏名（提示文案用） */
const productGameName = computed(() => games.value.find((g) => String(g.id) === String(productForm.gameId))?.name ?? '');

/**
 * 选游戏后：清掉旧分类并**自动选中该游戏下的第一个分类**。
 *
 * 负责人报障「商品无法添加」根因之一：游戏下没有任何分类时，「分类」下拉是空的（显示「无数据」），
 * 表单无法选到分类 → 点创建只弹一句笼统的「请选择游戏与分类」，看起来就是「加不了」。
 * 这里自动带入第一个分类（有分类时少一步操作），没有分类时由弹窗内提示引导先去建分类。
 *
 * 入参 gameId 用事件值（不读 productForm，避免与 v-model 的赋值顺序耦合）。
 */
function onProductGameChange(gameId: string | null) {
  const gid = String(gameId ?? productForm.gameId ?? '');
  const first = categories.value.find((c) => String(c.gameId) === gid);
  productForm.categoryId = first ? String(first.id) : '';
}
function openCreateProduct() {
  editProductId.value = null;
  // divisionId 必须一起重置：否则新建时会带上「上一次编辑」的分部（列表回显残留）
  Object.assign(productForm, {
    name: '', subtitle: '', gameId: '', categoryId: '', divisionId: null,
    listName: '', badgeText: '', weeklyLimit: null, weeklyLimitByQuantity: 0,
    orderNotice: null,
    price: 100, priceUnit: '局', estimateDurationMin: 30,
    coverMediaId: null, videoMediaId: null, videoCoverMediaId: null,
  });
  publishAfterCreate.value = false;
  showProductModal.value = true;
}
function openEditProduct(row: ProductRow) {
  editProductId.value = row.id;
  Object.assign(productForm, {
    name: row.name ?? '', subtitle: row.subtitle ?? '', gameId: row.gameId ?? '', categoryId: row.categoryId ?? '',
    divisionId: row.divisionId ? String(row.divisionId) : null,
    // 徽标/限购/短名必须一起回显：不回显的话「打开弹窗直接保存」会把已配好的徽标、限购、短名清掉
    listName: row.listName ?? '',
    badgeText: row.badgeText ?? '',
    weeklyLimit: row.weeklyLimit === null || row.weeklyLimit === undefined ? null : Number(row.weeklyLimit),
    // 口径开关：只有明确等于 1 才算"按件数"，其余（null/undefined/脏值）一律回显 0（按订单条数）
    weeklyLimitByQuantity: Number(row.weeklyLimitByQuantity ?? 0) === 1 ? 1 : 0,
    // 下单须知：NULL/空 ⇒ **保持 null（继承）**，不能回显成空串 ——
    // 空串在开关上是"未覆盖"、在保存时也会被服务端转回 NULL，但一旦回显成 `''`
    // 会让"打开弹窗直接保存"把 null 写成 ''（再被转回 null，看似无害），
    // 真正的问题是**界面会显示成"已覆盖但内容为空"**，运营以为配过了。统一按 null 回显。
    orderNotice: row.orderNotice == null || String(row.orderNotice).trim() === '' ? null : String(row.orderNotice),
    price: Number(row.price) || 0, priceUnit: row.priceUnit ?? '局', estimateDurationMin: row.estimateDurationMin ?? 30,
    coverMediaId: row.coverMediaId ?? null,
    videoMediaId: row.videoMediaId ?? null,
    videoCoverMediaId: null,
  });
  showProductModal.value = true;
}

/**
 * 只提交「可写字段」（对齐 DivisionsView.vue 的 buildPayload() 风格）：
 * 列表接口 /admin/products 会回带 divisionName / salesCount / createdAt 等只读/计算字段，
 * 用 `{ ...form }` 回传整对象只会被白名单丢掉（或 400）；id 只出现在 URL 里，绝不进 body。
 *
 * 分部是本次修复点：`divisionId` 显式构造，空值统一送 null（清空分部），由后端 UpdateProductDto 落库。
 */
function buildProductPayload() {
  return {
    name: productForm.name,
    subtitle: productForm.subtitle ?? '',
    // 列表短名（任务②）：空串由服务端转 NULL（= 列表回退完整商品名）
    listName: (productForm.listName ?? '').trim(),
    // 徽标/限购（负责人 2026-10-05）：徽标空串由服务端转 NULL（= 取消徽标）；
    // 限购留空/0 都表示不限（服务端按 weekly_limit > 0 判定）
    badgeText: (productForm.badgeText ?? '').trim(),
    weeklyLimit: productForm.weeklyLimit === null || productForm.weeklyLimit === undefined ? null : Number(productForm.weeklyLimit),
    // 限购口径（任务③）：显式提交 0/1，不依赖服务端默认值（避免"改了开关没生效"）
    weeklyLimitByQuantity: Number(productForm.weeklyLimitByQuantity ?? 0) === 1 ? 1 : 0,
    divisionId: productForm.divisionId ? String(productForm.divisionId) : null,
    price: productForm.price,
    priceUnit: productForm.priceUnit,
    estimateDurationMin: productForm.estimateDurationMin,
    coverMediaId: productForm.coverMediaId ?? null,
    videoMediaId: productForm.videoMediaId ?? null,
    videoCoverMediaId: productForm.videoCoverMediaId ?? null,
    // 下单须知：null ⇒ 继承平台默认。服务端 `@Transform(value === '' ? null : value)`
    // 只认「空串 → NULL」，所以这里显式送 null / 文本，不送 `''`（避免两边理解不一致）
    orderNotice: productForm.orderNotice === null ? null : String(productForm.orderNotice),
  };
}

/** 提交前本地校验（负责人报障修复）：逐项给出可执行的具体文案，而不是笼统一句或英文 400 */
function validateProductForm(): string | null {
  if (!productForm.name?.trim()) return '请填写商品名称';
  if (!editProductId.value) {
    if (!productForm.gameId) return '请选择所属游戏';
    if (!productCategories.value.length) return `「${productGameName.value || '该游戏'}」下还没有分类，请先到「分类」标签页新增分类，再回来添加商品`;
    if (!productForm.categoryId) return '请选择分类';
  }
  if (productForm.price === null || productForm.price === undefined || Number.isNaN(Number(productForm.price))) return '请填写价格（0.01 ~ 9999999.99，最多两位小数）';
  if (Number(productForm.price) < 0.01) return '价格不能低于 0.01';
  if (!productForm.priceUnit?.trim()) return '请填写计价单位（如 局 / 小时）';
  if (!productForm.estimateDurationMin || Number(productForm.estimateDurationMin) < 1) return '请填写预计时长（≥ 1 分钟）';
  // 徽标/限购/短名（负责人 2026-10-05）：先本地拦一道，避免"填完点保存才弹服务端 400"的体验
  if ((productForm.badgeText ?? '').trim().length > 32) return '徽标文案最多 32 字（留空表示不显示徽标）';
  if ((productForm.listName ?? '').trim().length > 64) return '列表短名最多 64 字（留空表示列表用完整商品名）';
  if (productForm.weeklyLimit !== null && productForm.weeklyLimit !== undefined) {
    const weekly = Number(productForm.weeklyLimit);
    if (!Number.isInteger(weekly) || weekly < 0 || weekly > 999) return '每周限购请填 0~999 的整数（留空或 0 表示不限）';
  }
  if (Number(productForm.weeklyLimitByQuantity ?? 0) !== 0 && Number(productForm.weeklyLimitByQuantity ?? 0) !== 1) {
    return '限购口径只能选「按订单条数」或「按件数」';
  }
  // 下单须知（迁移 1799000000000）：与后端 DTO 同一口径（≤3000 字）。
  // 「覆盖」态下不允许存空 —— 空覆盖等于继承，但开关还显示"已覆盖"，是误导。
  if (productForm.orderNotice !== null && String(productForm.orderNotice).trim().length === 0) {
    return '下单须知已选「覆盖」但内容为空：请填写内容，或关掉开关改为「继承平台默认」';
  }
  if ((productForm.orderNotice ?? '').length > 3000) return '下单须知最多 3000 字';
  return null;
}

async function saveProduct() {
  const invalid = validateProductForm();
  if (invalid) { message.warning(invalid); return; }
  try {
    if (editProductId.value) {
      // 编辑不接受 gameId/categoryId（后端 UpdateProductDto 未声明，改归属请删后重建）
      await request('PUT', `/admin/products/${editProductId.value}`, buildProductPayload());
      message.success('商品已更新');
    } else {
      const created = await request<{ id: string }>('POST', '/admin/products', { ...buildProductPayload(), gameId: productForm.gameId, categoryId: productForm.categoryId });
      if (publishAfterCreate.value && created?.id) {
        // 勾了「创建后立即上架」：一步到位，客户端立刻能看到（不勾则保持默认下架）
        await request('POST', `/admin/products/${created.id}/status`, { serviceStatus: 1 });
        message.success('商品已创建并上架（客户端该分部下立即可见）');
      } else {
        message.success('商品已创建（默认下架，请点「上架」后客户端才可见）');
      }
    }
    showProductModal.value = false;
    await loadProducts();
  } catch (e) { message.error(e instanceof ApiException ? e.message : '保存失败'); }
}
async function toggleProductStatus(row: ProductRow) {
  try {
    await request('POST', `/admin/products/${row.id}/status`, { serviceStatus: row.serviceStatus === 1 ? 2 : 1 });
    message.success(row.serviceStatus === 1 ? '已下架' : '已上架');
    await loadProducts();
  } catch (e) { message.error(e instanceof ApiException ? e.message : '操作失败'); }
}
function deleteProduct(row: ProductRow) {
  dialog.warning({
    title: '删除商品',
    content: `确定删除「${row.name}」？删除后不可恢复，历史订单不受影响（按当时的价格快照保留）。`,
    positiveText: '删除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await request('DELETE', `/admin/products/${row.id}`);
        message.success('商品已删除');
        await loadProducts();
      } catch (e) {
        message.error(e instanceof ApiException ? e.message : '删除失败');
      }
    },
  });
}

// ---------- 商品移动到另一个分部（负责人 2026-10-05） ----------

const showMoveModal = ref(false);
/** 本次要移动的商品 id（批量 = 勾选集合；单条 = 该行） */
const moveIds = ref<string[]>([]);
const moveSaving = ref(false);
/** 移动结果（弹窗内展示 + 关闭后页面顶部保留一条汇总） */
const moveResult = ref<MoveResult | null>(null);
const moveResultText = ref('');
const moveForm = reactive({
  targetDivisionId: null as string | null,
  /** auto = 自动匹配/新建同名分类（默认）；manual = 手动指定目标游戏下的分类 */
  categoryMode: 'auto' as 'auto' | 'manual',
  targetCategoryId: null as string | null,
});

/** 选中行（批量按钮用；也用于弹窗里回显名称与当前分部） */
const checkedProductRows = computed(() => {
  const keys = new Set(checkedProductIds.value.map((k) => String(k)));
  return products.value.filter((p) => keys.has(String(p.id)));
});

/** 目标分部下拉：名称 + 手游/端游；已下架分部不可选（服务端也会拒绝） */
const moveDivisionOptions = computed(() =>
  divisions.value.map((d) => {
    const platformTag = d.platformLabel || (d.platform === 'pc' ? '端游' : '手游');
    return {
      label: `${d.name.includes(platformTag) ? d.name : `${d.name}（${platformTag}）`}${d.status === 0 ? '（已下架，不可选）' : ''}`,
      value: String(d.id),
      disabled: d.status === 0,
    };
  }),
);
const moveTargetDivision = computed(() => divisions.value.find((d) => String(d.id) === String(moveForm.targetDivisionId)) ?? null);
/** 目标分部所属游戏（分类必须选在同一个游戏下） */
const moveTargetGameId = computed(() => (moveTargetDivision.value?.gameId ? String(moveTargetDivision.value.gameId) : ''));
const moveTargetGameName = computed(() => games.value.find((g) => String(g.id) === moveTargetGameId.value)?.name ?? '');
/** 目标游戏下已有分类（手动指定模式的可选项） */
const moveCategoryOptions = computed(() =>
  categories.value.filter((c) => String(c.gameId) === moveTargetGameId.value).map((c) => ({ label: c.name, value: String(c.id) })),
);
/** 本次弹窗涉及的商品行 */
const moveMoveRows = computed(() => {
  const keys = new Set(moveIds.value.map(String));
  return products.value.filter((p) => keys.has(String(p.id)));
});
/** 待移动商品的来源分类名（自动匹配模式下要说明「按哪个名字去找/建」） */
const moveSourceCategoryNames = computed(() => {
  const names = new Set<string>();
  for (const row of moveMoveRows.value) {
    const hit = categories.value.find((c) => String(c.id) === String(row.categoryId));
    if (hit) names.add(hit.name);
  }
  return [...names];
});

function openMoveModal(rows: ProductRow[]) {
  if (!rows.length) { message.warning('请先勾选要移动的商品'); return; }
  moveIds.value = rows.map((r) => String(r.id));
  moveResult.value = null;
  moveResultText.value = '';
  // 目标分部留空强制显式选择（避免手滑把商品移到错的分部）
  Object.assign(moveForm, { targetDivisionId: null, categoryMode: 'auto', targetCategoryId: null });
  showMoveModal.value = true;
}
/** 切换目标分部时清掉手动选的目标分类（分类必须属于目标游戏，跨游戏残留会 400） */
function onMoveDivisionChange() {
  moveForm.targetCategoryId = null;
}

/** 提交前本地校验：给出可执行的中文提示，而不是等后端 400 */
function validateMoveForm(): string | null {
  if (!moveIds.value.length) return '请先勾选要移动的商品';
  if (!moveForm.targetDivisionId) return '请选择目标分部';
  if (moveForm.categoryMode === 'manual' && !moveForm.targetCategoryId) return '请选择目标分类，或切换回「自动匹配同名分类」';
  return null;
}

function describeMoveResult(r: MoveResult): string {
  const parts = [`移动 ${r.moved} 条`];
  if (r.skipped) parts.push(`跳过 ${r.skipped} 条（已在目标分部）`);
  if (r.createdCategories?.length) parts.push(`新建分类 ${r.createdCategories.length} 个：${r.createdCategories.map((c) => c.name).join('、')}`);
  if (r.failed?.length) parts.push(`失败 ${r.failed.length} 条：${r.failed.map((f) => `#${f.id} ${f.reason}`).join('；')}`);
  return parts.join('　·　');
}

async function submitMove() {
  const invalid = validateMoveForm();
  if (invalid) { message.warning(invalid); return; }
  moveSaving.value = true;
  try {
    const payload: { ids: string[]; targetDivisionId: string; targetCategoryId?: string } = {
      ids: moveIds.value,
      targetDivisionId: String(moveForm.targetDivisionId),
    };
    if (moveForm.categoryMode === 'manual' && moveForm.targetCategoryId) {
      payload.targetCategoryId = String(moveForm.targetCategoryId);
    }
    const r = await request<MoveResult>('POST', '/admin/products/move', payload);
    moveResult.value = r;
    moveResultText.value = describeMoveResult(r);
    // 自动新建的分类要回到分类数据里，否则「分类」列与后续操作看不到它
    if (r.createdCategories?.length) await loadCategories();
    await loadProducts();
    if (r.failed?.length) message.warning(`已移动 ${r.moved} 条，${r.failed.length} 条未移动`);
    else if (r.moved === 0) message.info(`无需移动：${r.skipped} 条已在目标分部`);
    else message.success(`已移动 ${r.moved} 条到「${moveTargetDivision.value?.name ?? ''}」`);
    showMoveModal.value = false;
    checkedProductIds.value = [];
  } catch (e) {
    message.error(e instanceof ApiException ? e.message : '移动失败');
  } finally {
    moveSaving.value = false;
  }
}

const gameColumns = [
  // 列宽和 = 120+140+70+80+200 = 610 → 模板 :scroll-x = 610
  { title: 'Code', key: 'code', width: 120 },
  { title: '名称', key: 'name', width: 140 },
  { title: '排序', key: 'sortOrder', width: 70 },
  {
    title: '状态', key: 'status', width: 80,
    render: (row: GameRow) => h(NTag, { type: row.status === 1 ? 'success' : 'default', size: 'small' }, { default: () => (row.status === 1 ? '上架' : '下架') }),
  },
  {
    title: '操作', key: 'actions', width: 200, fixed: 'right' as const,
    render: (row: GameRow) => h('div', { style: 'display:flex;gap:8px' }, [
      h(NButton, { size: 'small', onClick: () => openEditGame(row) }, { default: () => '编辑' }),
      h(NButton, { size: 'small', onClick: () => toggleGameStatus(row) }, { default: () => (row.status === 1 ? '下架' : '上架') }),
      h(NButton, { size: 'small', type: 'error', quaternary: true, onClick: () => deleteGame(row) }, { default: () => '删除' }),
    ]),
  },
];

const catColumns = [
  // 列宽和 = 140+160+70+160 = 530 → 模板 :scroll-x = 530
  { title: '所属游戏', key: 'gameName', width: 140 },
  { title: '名称', key: 'name', width: 160 },
  { title: '排序', key: 'sortOrder', width: 70 },
  {
    title: '操作', key: 'actions', width: 160, fixed: 'right' as const,
    render: (row: CategoryRow) => h('div', { style: 'display:flex;gap:8px' }, [
      h(NButton, { size: 'small', onClick: () => openEditCat(row) }, { default: () => '编辑' }),
      h(NButton, { size: 'small', type: 'error', quaternary: true, onClick: () => deleteCat(row) }, { default: () => '删除' }),
    ]),
  },
];

const productColumns = [
  // 多选列（负责人 2026-10-05）：顶部「移动到分部」按勾选批量操作
  { type: 'selection' as const },
  {
    title: '名称', key: 'name', width: 150,
    // 徽标回显（负责人 2026-10-05）：列表里直接看到哪个商品挂了徽标，不必逐个点开弹窗
    render: (row: ProductRow) =>
      h('div', [
        h('span', row.name),
        row.badgeText
          ? h(NTag, { size: 'small', type: 'warning', bordered: false, style: 'margin-left:6px' }, { default: () => row.badgeText })
          : null,
      ]),
  },
  {
    // 分部回显（负责人 2026-10-04）：商品挂在哪个分部，列表一眼可见
    title: '分部', key: 'divisionId', width: 150,
    render: (row: ProductRow) =>
      row.divisionId
        ? h('span', divisionLabel(row))
        : h('span', { style: 'color: var(--color-text-tertiary);font-size:12px' }, '未挂分部'),
  },
  {
    // 价格列（口径 2026-10-09）：金额一律 ¥ + 两位小数（元）；`priceUnit` 是**服务端下发的计价单位**
    // （实测取值「单」「20分」），本页只渲染、不改写 —— 单位语义由服务端数据决定。
    title: '价格', key: 'price', width: 120,
    render: (row: ProductRow) => h('strong', { style: 'color: var(--color-primary)' }, `${formatYuan(row.price)}/${row.priceUnit}`),
  },
  { title: '时长(分)', key: 'estimateDurationMin', width: 80 },
  { title: '销量', key: 'salesCount', width: 70 },
  {
    title: '状态', key: 'serviceStatus', width: 80,
    render: (row: ProductRow) => h(NTag, { type: row.serviceStatus === 1 ? 'success' : 'warning', size: 'small' }, { default: () => (row.serviceStatus === 1 ? '上架' : '下架') }),
  },
  {
    // 4 个动作（编辑/移动/上下架/删除）在 280px 里靠猜是放不下的 —— 按「主要动作 + 更多下拉」收口：
    // 常用两个留在外面，上下架/删除进 n-dropdown；列宽 280 → 190。
    // 列宽和 = 150+150+120+80+70+80+190 = 840（+多选列 ≈50）→ 模板 :scroll-x = 900
    title: '操作', key: 'actions', width: 190, fixed: 'right' as const,
    render: (row: ProductRow) => h('div', { style: 'display:flex;gap:8px;align-items:center' }, [
      h(NButton, { size: 'small', onClick: () => openEditProduct(row) }, { default: () => '编辑' }),
      // 单条移动：复用同一个小弹窗（预选该条），与批量入口行为完全一致
      h(NButton, { size: 'small', onClick: () => openMoveModal([row]) }, { default: () => '移动' }),
      h(NDropdown, {
        trigger: 'click',
        options: [
          { label: row.serviceStatus === 1 ? '下架' : '上架', key: 'status' },
          { label: '删除', key: 'delete', props: { style: 'color:var(--color-error)' } },
        ],
        onSelect: (key: string) => {
          if (key === 'status') toggleProductStatus(row);
          else if (key === 'delete') deleteProduct(row);
        },
      }, { default: () => h(NButton, { size: 'small', quaternary: true }, { default: () => '更多' }) }),
    ]),
  },
];
</script>

<template>
  <div class="catalog-page">
    <n-tabs type="line">
      <n-tab-pane name="games" tab="游戏">
        <div class="toolbar">
          <div class="spacer" />
          <n-button type="primary" @click="openCreateGame">新增游戏</n-button>
        </div>
        <n-data-table :columns="gameColumns" :data="games" :scroll-x="610" />
        <p class="hint">新增游戏无需改客户端代码（docs/13）；删除游戏前需先删除其分类与商品</p>
      </n-tab-pane>
      <n-tab-pane name="categories" tab="分类">
        <div class="toolbar">
          <n-select v-model:value="catFilterGame" :options="games.map((g) => ({ label: g.name, value: g.id }))" placeholder="全部游戏" clearable style="width: 160px" />
          <div class="spacer" />
          <n-button type="primary" @click="openCreateCat">新增分类</n-button>
        </div>
        <n-data-table
          :columns="catColumns"
          :data="catFiltered.map((c) => ({ ...c, gameName: games.find((g) => g.id === c.gameId)?.name ?? '-' }))"
          :scroll-x="530"
        />
        <p class="hint">删除分类前需先删除或转移其下商品</p>
      </n-tab-pane>
      <n-tab-pane name="products" tab="商品">
        <div class="toolbar">
          <n-select v-model:value="filterGame" :options="games.map((g) => ({ label: g.name, value: g.id }))" placeholder="全部游戏" clearable style="width: 160px" @update:value="() => { filterCategory = null; loadProducts(); }" />
          <n-select v-model:value="filterCategory" :options="catOptions" placeholder="全部分类" clearable style="width: 160px" @update:value="loadProducts" />
          <!-- 分部筛选（负责人 2026-10-05）：修好接口后补上管理端入口 -->
          <n-select v-model:value="filterDivision" :options="divisionFilterOptions" placeholder="全部分部" clearable style="width: 200px" @update:value="loadProducts" />
          <div class="spacer" />
          <!-- 批量移动到另一个分部（负责人 2026-10-05）：未勾选时禁用，勾选后显示条数 -->
          <span v-if="checkedProductIds.length" class="sel-count">已选 {{ checkedProductIds.length }} 条</span>
          <n-button :disabled="!checkedProductIds.length" @click="openMoveModal(checkedProductRows)">移动到分部</n-button>
          <n-button type="primary" @click="openCreateProduct">新增商品</n-button>
        </div>
        <!-- 移动结果（页面级保留一条汇总，便于核对「移动/跳过/新建分类/失败原因」） -->
        <n-alert v-if="moveResultText" :type="moveResult?.failed?.length ? 'warning' : 'success'" :bordered="false" closable class="move-result" @close="moveResultText = ''">
          {{ moveResultText }}
        </n-alert>
        <n-data-table
          :columns="productColumns"
          :data="products"
          :loading="loading"
          :row-key="(row: ProductRow) => String(row.id)"
          v-model:checked-row-keys="checkedProductIds"
          :scroll-x="900"
        />
        <p class="hint">商品价格以服务端为准；改价不影响历史订单价格快照（docs/06）。<b>分部</b>决定商品在客户端哪个分部显示（不挂分部则不在任何分部筛选下出现）。有订单记录的商品不可删除，请使用下架。勾选多条后可用「移动到分部」批量改归属 —— 只改「分部/游戏/分类」，名称、价格、时长、图片、上下架状态一律不变。</p>
      </n-tab-pane>
    </n-tabs>

    <n-modal v-model:show="showGameModal" preset="card" style="width: 520px" :title="editGameId ? '编辑游戏' : '新增游戏'" positive-text="保存" negative-text="取消" @positive-click="saveGame">
      <n-form label-placement="left" label-width="70">
        <n-form-item label="Code">
          <n-input v-model:value="gameForm.code" placeholder="如 delta_mobile（小写字母数字下划线）" :disabled="!!editGameId" />
        </n-form-item>
        <n-form-item label="名称"><n-input v-model:value="gameForm.name" placeholder="游戏名称" /></n-form-item>
        <n-form-item label="排序"><n-input-number v-model:value="gameForm.sortOrder" :min="0" /></n-form-item>
      </n-form>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showGameModal = false">取消</n-button>
          <n-button type="primary" @click="saveGame">保存</n-button>
        </div>
      </template>
    </n-modal>

    <n-modal v-model:show="showCatModal" preset="card" style="width: 520px" :title="editCatId ? '编辑分类' : '新增分类'" positive-text="保存" negative-text="取消" @positive-click="saveCat">
      <n-form label-placement="left" label-width="70">
        <n-form-item label="游戏">
          <n-select v-model:value="catForm.gameId" :options="games.map((g) => ({ label: g.name, value: g.id }))" />
        </n-form-item>
        <n-form-item label="名称"><n-input v-model:value="catForm.name" placeholder="分类名称" /></n-form-item>
        <n-form-item label="排序"><n-input-number v-model:value="catForm.sortOrder" :min="0" /></n-form-item>
      </n-form>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showCatModal = false">取消</n-button>
          <n-button type="primary" @click="saveCat">保存</n-button>
        </div>
      </template>
    </n-modal>

    <n-modal v-model:show="showProductModal" preset="card" style="width: 640px" :title="editProductId ? '编辑商品' : '新增商品'" positive-text="保存" negative-text="取消" @positive-click="saveProduct">
      <n-form label-placement="left" label-width="80">
        <n-form-item label="游戏"><n-select v-model:value="productForm.gameId" :options="games.map((g) => ({ label: g.name, value: String(g.id) }))" :disabled="!!editProductId" placeholder="请选择游戏" @update:value="onProductGameChange" /></n-form-item>
        <n-form-item label="分类">
          <n-select v-model:value="productForm.categoryId" :options="productCatOptions" :disabled="!!editProductId" :placeholder="productCategories.length ? '请选择分类' : '该游戏下暂无分类'" />
        </n-form-item>
        <!-- 报障修复：分类为空时给出可执行指引（原来只有一句笼统的「请选择游戏与分类」） -->
        <n-alert v-if="!editProductId && productForm.gameId && !productCategories.length" type="warning" :bordered="false" style="margin: 0 0 12px 80px">
          「{{ productGameName }}」下还没有分类，商品必须先有分类才能创建 —— 请先切到上方<b>「分类」标签页</b>新增一个分类，再回来添加商品。
        </n-alert>
        <n-form-item label="分部">
          <n-select v-model:value="productForm.divisionId" :options="divisionOptions" clearable placeholder="不挂分部（客户端不在此分部显示）" />
        </n-form-item>
        <p class="form-hint">分部决定商品在客户端哪个分部显示（当前共 {{ divisions.length }} 个分部可选；不挂分部则不在任何分部筛选下出现）。</p>
        <n-form-item label="名称"><n-input v-model:value="productForm.name" placeholder="如 传奇段位上分陪练" /></n-form-item>
        <n-form-item label="副标题"><n-input v-model:value="productForm.subtitle" /></n-form-item>
        <!-- 列表短名（负责人 2026-10-05 任务②）：通用能力，任何商品都能配；只影响客户端**列表卡** -->
        <n-form-item label="列表短名">
          <n-input
            v-model:value="productForm.listName"
            maxlength="64"
            show-count
            clearable
            style="width: 320px"
            placeholder="如 36.6博弈宝冠单（不出保888w）"
          />
        </n-form-item>
        <p class="form-hint">
          只在客户端<b>商品列表</b>的卡片上显示（窄卡放不下超长商品名时用）；<b>留空 = 列表用完整名称</b>。
          商品详情页、确认订单页、订单页**始终显示完整名称**，填了也不影响这些页面与历史订单。
        </p>
        <!-- 徽标文案 / 每周限购（负责人 2026-10-05）：通用能力，任何商品都能配，不是给某一个商品写死 -->
        <n-form-item label="徽标文案">
          <n-input
            v-model:value="productForm.badgeText"
            maxlength="32"
            show-count
            clearable
            style="width: 240px"
            placeholder="如 董事长推荐（留空=不显示）"
          />
        </n-form-item>
        <p class="form-hint">徽标显示在客户端商品卡左上角（实色琥珀金小片 + 白字）；留空即不显示，也不会有金色描边。</p>
        <n-form-item label="每周限购">
          <n-input-number
            v-model:value="productForm.weeklyLimit"
            :min="0"
            :max="999"
            :precision="0"
            clearable
            style="width: 160px"
            placeholder="留空/0 = 不限"
          />
          <span class="form-hint" style="margin-left:8px">{{ Number(productForm.weeklyLimitByQuantity ?? 0) === 1 ? '件/账号/周（按件数）' : '单/账号/周（按订单条数）' }}</span>
        </n-form-item>
        <!-- 限购口径（负责人 2026-10-05 任务③）：默认「按订单条数」= 原行为，切「按件数」后一单买 2 件占 2 个名额 -->
        <n-form-item label="限购口径">
          <n-switch
            v-model:value="productForm.weeklyLimitByQuantity"
            :checked-value="1"
            :unchecked-value="0"
          />
          <span class="form-hint" style="margin-left:8px">
            {{ Number(productForm.weeklyLimitByQuantity ?? 0) === 1 ? '按件数（一次买 2 件占 2 个名额）' : '按订单条数（默认，一个账号一周 N 单）' }}
          </span>
        </n-form-item>
        <p class="form-hint">
          每周限购由服务端在下单扣款前强制校验（最近 7 天该账号对该商品未取消的订单，<b>滚动 7×24 小时</b>，不是自然周）。
          口径：<b>按订单条数</b>（默认，一单一名额）／<b>按件数</b>（SUM(quantity)，一单买 2 件占 2 个名额）。
          改口径只影响之后的判定与提示文案，历史订单不变；客户端只展示服务端文案，不参与判定。
        </p>
        <!-- 下单须知（负责人 2026-10-05 商品详情页 v2 方案 B）：继承平台默认 / 商品级覆盖 两态 -->
        <n-form-item label="下单须知">
          <n-switch v-model:value="noticeOverride" />
          <span class="form-hint" style="margin: 0 0 0 8px">
            {{ noticeOverride ? '覆盖：使用下面这份（保存后只影响本商品）' : '继承：使用平台默认（在「系统设置」页维护）' }}
          </span>
        </n-form-item>
        <div class="notice-field">
          <!-- 继承态：**只读显示平台默认**（运营要能看见客户端将显示什么，否则无从判断要不要覆盖） -->
          <div v-if="!noticeOverride" class="notice-inherit">
            <p class="notice-inherit-label">
              当前继承的平台默认（只读）<span v-if="!noticeDefaultLoaded"> · 读取中…</span>
              <span v-else-if="!noticeDefault"> · 读取失败，请到「系统设置」页确认</span>
            </p>
            <pre class="notice-preview">{{ noticeDefault || '（暂无平台默认文案）' }}</pre>
          </div>
          <!-- 覆盖态：可编辑 -->
          <div v-else>
            <n-input
              v-model:value="productForm.orderNotice"
              type="textarea"
              :autosize="{ minRows: 5, maxRows: 14 }"
              maxlength="3000"
              show-count
              placeholder="每行一条，条内不要写「1.」这类序号（客户端会按行自动编号）"
            />
            <p class="form-hint" style="margin: 8px 0 0">
              每行一条，<b>不要自己写序号</b>（客户端按行渲染成「1. 2. 3.…」，自己写了会变成「1. 1. …」）。
              详情页默认折叠成一行显示第一条，点「展开」看全。
            </p>
          </div>
        </div>
        <n-form-item label="价格（元）">
          <n-input-number v-model:value="productForm.price" :min="0.01" :step="0.5" :precision="2" style="width: 180px">
            <template #prefix>¥</template>
          </n-input-number>
        </n-form-item>
        <n-form-item label="单位"><n-input v-model:value="productForm.priceUnit" style="width: 100px" /></n-form-item>
        <n-form-item label="时长(分)"><n-input-number v-model:value="productForm.estimateDurationMin" :min="1" style="width: 160px" /></n-form-item>
        <n-form-item label="主图"><media-upload-field v-model="productForm.coverMediaId" media-type="product_image" /></n-form-item>
        <!-- 商品视频：负责人 2026-10-05 决定不在管理端提供（"视频作用不大"）；后端字段与接口保留，需要时可恢复。
             恢复方式 = 把下面两行放回本行位置即可（表单状态与提交字段一直保留，见 productForm.videoMediaId/videoCoverMediaId）：
             <n-form-item label="视频"><media-upload-field v-model="productForm.videoMediaId" media-type="product_video" accept="video/mp4" /></n-form-item>
             <n-form-item label="视频封面"><media-upload-field v-model="productForm.videoCoverMediaId" media-type="video_cover" /></n-form-item> -->
        <n-form-item v-if="!editProductId" label="上架">
          <n-checkbox v-model:checked="publishAfterCreate">创建后立即上架（不勾则先下架保存，确认后再点「上架」）</n-checkbox>
        </n-form-item>
      </n-form>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button @click="showProductModal = false">取消</n-button>
          <n-button type="primary" @click="saveProduct">{{ editProductId ? '保存' : '创建' }}</n-button>
        </div>
      </template>
    </n-modal>

    <!-- 移动到分部（负责人 2026-10-05）：批量/单条共用；只改归属，不动任何业务字段 -->
    <n-modal
      v-model:show="showMoveModal"
      preset="card"
      style="width: 560px"
      title="移动到分部"
      :mask-closable="!moveSaving"
    >
      <div class="mv-summary">
        <p class="mv-title">将移动 {{ moveIds.length }} 个商品</p>
        <p class="mv-line">移动后<b>只改归属</b>：名称、价格、单价单位、时长、图片、上下架状态全部保持不变。</p>
        <p class="mv-line mv-list">{{ moveMoveRows.map((r) => r.name).join('、') }}</p>
      </div>
      <n-form label-placement="left" label-width="88">
        <n-form-item label="目标分部">
          <n-select
            v-model:value="moveForm.targetDivisionId"
            :options="moveDivisionOptions"
            placeholder="选择目标分部（三角洲行动 · 手游 / 端游）"
            @update:value="onMoveDivisionChange"
          />
        </n-form-item>
        <n-form-item label="目标分类">
          <n-radio-group v-model:value="moveForm.categoryMode">
            <n-radio value="auto">自动匹配同名分类</n-radio>
            <n-radio value="manual">手动指定</n-radio>
          </n-radio-group>
        </n-form-item>
        <n-form-item v-if="moveForm.categoryMode === 'manual'" label="选择分类">
          <n-select
            v-model:value="moveForm.targetCategoryId"
            :options="moveCategoryOptions"
            :disabled="!moveTargetGameId"
            :placeholder="moveTargetGameId ? '选择目标游戏下的分类' : '请先选择目标分部'"
          />
        </n-form-item>
      </n-form>
      <p class="mv-note">
        <template v-if="!moveTargetDivision">分部与分类必须配套：目标分类只能选目标分部所属游戏下的分类。</template>
        <template v-else-if="moveForm.categoryMode === 'auto'">
          在「{{ moveTargetGameName }}」下按来源分类名（{{ moveSourceCategoryNames.join('、') || '当前分类' }}）查找同名分类；找不到会<b>自动新建</b>同名分类，并在结果里说明新建了哪些。
        </template>
        <template v-else>
          目标分类「{{ categories.find((c) => String(c.id) === String(moveForm.targetCategoryId))?.name ?? '未选择' }}」将用于本次全部商品（必须属于「{{ moveTargetGameName }}」）。
        </template>
      </p>
      <!-- 结果留在弹窗内不关闭的场景很少；正常路径是关窗 + 页面顶部汇总条 -->
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:12px">
          <n-button :disabled="moveSaving" @click="showMoveModal = false">取消</n-button>
          <n-button type="primary" :loading="moveSaving" :disabled="!moveIds.length" @click="submitMove">
            确认移动
          </n-button>
        </div>
      </template>
    </n-modal>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
  align-items: center;
}
.spacer {
  flex: 1;
}
.hint {
  margin-top: 12px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
.form-hint {
  margin: -4px 0 12px 80px;
  font-size: 12px;
  color: var(--color-text-tertiary);
  line-height: 1.7;
}
/* 已选条数：只做文字提示，不加胶囊标签（docs/21：标签只给必须区分的项） */
.sel-count {
  font-size: 13px;
  color: var(--color-text-secondary);
}
.move-result {
  margin-bottom: 16px;
  border-radius: var(--radius-control);
}
/* 移动确认块：发丝线分档，不用阴影/渐变 */
.mv-summary {
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-control);
  padding: 10px 12px;
  margin-bottom: 20px;
  background: var(--color-bg-card);
}
.mv-title {
  margin: 0 0 8px;
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}
.mv-line {
  margin: 0;
  font-size: 12px;
  line-height: 1.8;
  color: var(--color-text-secondary);
}
.mv-list {
  color: var(--color-text-tertiary);
  max-height: 60px;
  overflow: auto;
}
.mv-note {
  margin: 0 0 4px;
  font-size: 12px;
  line-height: 1.8;
  color: var(--color-text-tertiary);
}
/* 下单须知：与 n-form-item 同左缩进（label-width 80），保持管理端表单的纵向对齐 */
.notice-field {
  margin: -4px 0 12px 80px;
}
.notice-inherit {
  border: 1px solid var(--color-divider);
  border-radius: var(--radius-control);
  padding: 10px 12px;
  background: var(--color-bg-page, #f5f7fb);
}
.notice-inherit-label {
  margin: 0 0 6px;
  font-size: 12px;
  color: var(--color-text-tertiary);
}
/* 只读预览：按行显示（每行一条须知），与客户端「展开」后的排版同构 */
.notice-preview {
  margin: 0;
  font-family: inherit;
  font-size: 12px;
  line-height: 1.9;
  color: var(--color-text-secondary);
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
