/*
 * Naive UI 主题映射（docs/14 色板 + 2026-10-11 深色科技风 → 浅色为默认档）
 * ============================================================================
 * 做法参照 SoybeanAdmin / zclzone/vue-naive-admin（均 MIT）的"主题即配置"写法：
 *   `darkTheme` 变量决定底座（naive 自己算派生色），`themeOverrides` 只覆盖**品牌相关**的少量键；
 *   深色/浅色两套 override 分开写，避免"某一档下主色对比度不够"这类需要逐键调的问题。
 *
 * 档位（2026-10-11 第二轮）：
 *   · **浅色 = 默认档**（`stores/theme.ts` 的 DEFAULT_MODE='light'）：冷灰蓝底 #F5F7FB + 白卡 +
 *     发丝线 #E5E9F2 + **白底侧栏**；正文 #1F2937 / 次级 #5B6B82 / 三级 #667792。
 *   · **深色 = 保留档**（顶栏右上角仍可切）：近黑底 #0B1220 + 抬升卡面 #111C2E + 近黑侧栏 #0B1220，
 *     文字对比度逐值挑过（见 styles/tokens.css 顶部注释）。**这一档本次一行未退步**。
 *
 * 刻意的取舍：
 *   · **不引入整套模板框架**（那会推翻现有 22 页的 Naive 组件用法）—— 只抄它的主题配置与布局结构；
 *   · 主色用**我们自己的品牌色** 冰雪蓝 #2563EB / 青 #06B6D4 与琥珀金 #B45309（深色档 #F0A63C），
 *     不是参考视频的绿色（docs/21 法律风险条款）；
 *   · textColor2/3 两档都**逐值挑过对比度**，不靠 naive 默认灰。
 */
import type { GlobalThemeOverrides } from 'naive-ui';

/** 品牌基色（唯一出处，禁止在页面里再写一遍十六进制） */
export const BRAND = {
  primary: '#1D5FA8',
  primaryHover: '#1D4ED8',
  primaryPressed: '#1E40AF',
  /** 青：只做极小面积点缀（进度条/强调线），不做大块渐变铺底 */
  cyan: '#0E7C7B',
  /** 琥珀金：金额 / 等级 / 价格专用的唯一色（浅色档 = #B45309，白卡上 5.1:1） */
  gold: '#B45309',
  /** 琥珀金在深底上的提亮档（#B45309 在近黑上偏暗，且深色档要"数字感"） */
  goldOnDark: '#F0A63C',
  /** 侧栏浅色档底色（深色档回落 #0B1220，见 darkOverrides.Layout.siderColor） */
  siderBg: '#FFFFFF',
} as const;

/** 浅色档（**默认档**）：冷灰蓝底 + 白卡 + 发丝线 + 白底侧栏 */
export const lightOverrides: GlobalThemeOverrides = {
  common: {
    primaryColor: BRAND.primary,
    primaryColorHover: BRAND.primaryHover,
    primaryColorPressed: BRAND.primaryPressed,
    primaryColorSuppl: BRAND.primaryHover,
    successColor: '#15803D',
    warningColor: '#C2410C',
    errorColor: '#DC2626',
    /*
     * `infoColor`：**必须显式覆盖**（2026-10-11 实测）。
     * naive 的默认 info 是 `#2080F0`（自建主色），压白底只有 **3.88:1** ——
     * `n-tag type="info"`（用户管理的「工作端」角色标签、设置页的「可修改」标签）全踩这条。
     * 取主色系更深一档 `#0369A1`（白底 **5.9:1**），与 `--color-primary` 同族、不引入新色相。
     */
    infoColor: '#0369A1',
    textColorBase: '#1F2937',
    textColor1: '#1F2937',
    textColor2: '#5B6B82',
    /*
     * 三级文字必须 ≥4.5:1：原 #94A3B8 压白卡只有 2.6:1（实测不达标）；
     * 中途取过的 #667792 在白卡上 4.9:1 达标，但**页面底 #F5F7FB** 上只有 4.24 →
     * 工作台的 .block-hint、标签页的 ×、面包屑实测不过。
     * #5E7085：白卡 5.3:1 / 页底 4.7:1，两处都过 —— 与 tokens.css 的
     * `--color-text-tertiary` **必须保持同值**，改一处就要两处一起改。
     */
    textColor3: '#5E7085',
    /*
     * 输入框占位符：naive 浅色默认 `#C2C2C2` 压白底只有 **1.78:1**（2026-10-11 实测），
     * 输入框里"能搜什么"直接看不见。`#757575` = **4.6:1**，与次级/三级文字同一量级、
     * 仍明显弱于正文（正文 14.7:1），"占位符比正文淡"的语义没丢。
     * 深色档不设这一项：naive darkTheme 的默认值是 `rgba(255,255,255,0.38)` ≈ 4.9:1，本来就达标。
     */
    placeholderColor: '#757575',
    bodyColor: '#F5F7FB',
    cardColor: '#FFFFFF',
    /* 发丝线（负责人指定 #E5E9F2）；表格另有更实一档，见 DataTable.borderColor */
    dividerColor: '#E5E9F2',
    borderColor: '#D8DFEA',
    modalColor: '#FFFFFF',
    popoverColor: '#FFFFFF',
    tableColor: '#FFFFFF',
    tableHeaderColor: '#F7F9FC',
    borderRadius: '8px',
    borderRadiusSmall: '6px',
  },
  Card: {
    borderRadius: '12px',
    // 阴影只给弹层：卡片用 1px 发丝线 + 极轻投影（docs/21 反 AI 味：不铺满阴影）
    boxShadow: '0 1px 2px rgba(15,23,42,0.04)',
    borderColor: '#E8EDF5',
  },
  DataTable: {
    thColor: '#F7F9FC',
    thTextColor: '#5B6B82',
    tdColorHover: '#F8FAFD',
    /*
     * 表格线比通用发丝线更实一档：`#E5E9F2` 压在白表体上亮度差只有 0.008，
     * 1600px 宽的表会"看不见行"。`#DCE3EE` ≈0.026，是一像素线但真的分得出行列。
     * 与 tokens.css 的 `--table-hairline` 同值。
     */
    borderColor: '#DCE3EE',
    thFontWeight: '600',
  },
  Layout: {
    /* 侧栏浅色档 = 白底（深色档见 darkOverrides.Layout.siderColor = 近黑） */
    siderColor: BRAND.siderBg,
    color: '#F5F7FB',
  },
  Menu: {
    itemTextColor: '#1F2937',
    itemIconColor: '#5B6B82',
  },
  Button: {
    /* 浅色档实心主按钮**白字**（#2563EB 上 5.2:1）；tokens.css 另有一条兜底 */
    textColorPrimary: '#FFFFFF',
    textColorHoverPrimary: '#FFFFFF',
    textColorPressedPrimary: '#FFFFFF',
    textColorFocusPrimary: '#FFFFFF',
    borderPrimary: BRAND.primary,
  },
  Tag: {
    /* 主色标签（顶栏「超级管理员」）：白底上 #2563EB = 5.2:1，达标，用主色本身 */
    textColorPrimary: BRAND.primary,
    colorPrimary: 'rgba(37, 99, 235, 0.10)',
    borderPrimary: 'rgba(37, 99, 235, 0.28)',
  },
};

/** 深色档：近黑底 + 抬升卡面 + 发丝线（发丝线在深色下**必须可见**，故不用 naive 默认） */
export const darkOverrides: GlobalThemeOverrides = {
  common: {
    primaryColor: BRAND.primary,
    primaryColorHover: '#3B82F6',
    primaryColorPressed: '#1D4ED8',
    primaryColorSuppl: '#3B82F6',
    successColor: '#22C55E',
    warningColor: '#FB923C',
    errorColor: '#F87171',
    textColorBase: '#E8EEF7',
    textColor1: '#E8EEF7',
    textColor2: '#9DB0C8',
    /*
     * 三级文字原为 #6B8199：压在卡片面 #111C2E 上只有 4.25:1（实测不达标）。
     * 深色里三级文字基本都落在卡面/顶栏（面包屑、说明行），故提到 #8CA3BE（5.56:1）。
     * 与 styles/tokens.css 的 `--color-text-tertiary` 必须保持同值。
     */
    textColor3: '#8CA3BE',
    bodyColor: '#0B1220',
    cardColor: '#111C2E',
    dividerColor: '#1E2C42',
    borderColor: '#22304A',
    modalColor: '#121E31',
    popoverColor: '#121E31',
    tableColor: '#111C2E',
    tableHeaderColor: '#0E1728',
    inputColor: 'rgba(255,255,255,0.04)',
    tableColorHover: 'rgba(255,255,255,0.04)',
    borderRadius: '8px',
    borderRadiusSmall: '6px',
  },
  Card: {
    borderRadius: '12px',
    borderColor: '#1E2C42',
    boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
  },
  DataTable: {
    thColor: '#0E1728',
    thTextColor: '#9DB0C8',
    tdColorHover: 'rgba(255,255,255,0.035)',
    /*
     * 发丝线在深色下**必须显式给值**：`common.dividerColor = #1E2C42` 压在表体 `#111C2E` 上
     * 亮度差只有 0.006（实测）—— 表格会"糊成一片"，行与列都分不出来。
     * 这里用 #26364F（与 #111C2E 亮度差 0.017），仍是一条克制的一像素线，但真的看得见。
     */
    borderColor: '#26364F',
    thFontWeight: '600',
  },
  Layout: {
    /*
     * 深色档侧栏**必须显式写近黑**（不能读 `BRAND.siderBg`：那个常量现在指浅色档的白底，
     * 复用会让深色档的侧栏变成白色 —— 2026-10-11 改浅色档时踩过的坑，这里钉住字面值）。
     */
    siderColor: '#0B1220',
    color: '#0B1220',
  },
  Menu: {
    itemTextColor: '#E8EEF7',
    itemIconColor: '#9DB0C8',
  },
  Tabs: {
    tabTextColorLine: '#9DB0C8',
    tabTextColorActiveLine: '#E8EEF7',
    tabTextColorHoverLine: '#E8EEF7',
    barColor: BRAND.primary,
    paneTextColor: '#E8EEF7',
  },
  Button: {
    /*
     * 主按钮文字**必须显式给白色**：naive-ui 2.45 的 darkTheme 下 `textColorPrimary`
     * 解析成了 `#000`（黑字压 #2563EB = 4.06:1，且"主按钮黑字"本身就不是这套设计语言）。
     */
    textColorPrimary: '#FFFFFF',
    textColorHoverPrimary: '#FFFFFF',
    textColorPressedPrimary: '#FFFFFF',
    textColorFocusPrimary: '#FFFFFF',
    borderPrimary: BRAND.primary,
  },
  Dialog: {
    color: '#121E31',
    titleTextColor: '#E8EEF7',
  },
  Breadcrumb: {
    itemTextColor: '#9DB0C8',
    itemTextColorHover: '#E8EEF7',
  },
  Tag: {
    /*
     * 主色标签（顶栏「超级管理员」）：naive 默认的 `textColorPrimary = #2563EB`
     * 压在近黑底上只有 3.62:1（实测不达标）→ 用主色文字态 #7FB0FF（8.1:1）。
     * 标签底色的柔光层仍走 primaryColor（色块不受文字对比度约束）。
     */
    textColorPrimary: '#7FB0FF',
    colorPrimary: 'rgba(37, 99, 235, 0.18)',
    borderPrimary: 'rgba(127, 176, 255, 0.32)',
  },
};

/**
 * 默认导出（兼容既有 `import { themeOverrides } from './theme'`）：
 * **浅色档（默认档）**。App.vue 按当前主题在 light/dark 之间切换。
 */
export const themeOverrides: GlobalThemeOverrides = lightOverrides;
