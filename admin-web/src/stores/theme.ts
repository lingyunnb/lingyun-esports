/**
 * 涓婚鎬侊紙2026-10-11 娣辫壊绉戞妧椋庡澹?鈫?2026-10-11 娴呰壊涓洪粯璁ゆ。锛? * ============================================================================
 * 涓変釜鍙€夐」锛氳窡闅忕郴缁?/ 娴呰壊 / 娣辫壊銆傞€夋嫨钀?`localStorage`锛屽埛鏂颁繚鎸侊紱
 * 鍚屾椂鎶婄粨鏋滃啓鍒?`html[data-theme]`锛岃 `styles/tokens.css` 鐨?CSS 鍙橀噺鏁寸珯璺熼殢銆? *
 * **榛樿鏄€屾祬鑹层€嶈€屼笉鏄€岃窡闅忕郴缁熴€?*锛堣礋璐ｄ汉 2026-10-11 瀹氭锛氫富棰樻敼銆岀櫧鑹诧紙娴呰壊锛夈€嶄负榛樿锛夛細
 * 棣栧睆锛堢櫥褰曢〉 + 杩涘叆鍚庡彴锛夊繀椤诲氨鏄祬鑹诧紝涓嶈兘鍥犱负鏌愬彴鏈哄櫒鐨勭郴缁熷亸濂芥槸娣辫壊鑰屼氦鍑轰竴濂楁繁鑹插３銆? * 銆岃窡闅忕郴缁熴€嶄粛淇濈暀鍦ㄩ€夐」閲岋紝浣嗛偅鏄竴娆℃槑纭殑鐢ㄦ埛閫夋嫨銆? * 娣辫壊妗?*瀹屾暣淇濈暀**锛堥《鏍忓彸涓婅涓€閿垏鎹級锛屾祬鑹插彧鏄?娌￠€夎繃鏃剁殑榛樿鍊?銆? *
 * 涓轰粈涔?mode 涓?resolved 鍒嗗紑锛? *   `mode === 'auto'` 鏃?resolved 鐢?`matchMedia('(prefers-color-scheme: dark)')` 瀹炴椂鍐冲畾锛? *   涓嶆妸瀹冨啓姝昏繘 state 鈥斺€?绯荤粺鎹富棰樻椂涓嶅繀閲嶆柊鎸傝浇灏辫兘璺熶笂銆? *
 * 渚ф爮**闅忎富棰樺彉**锛堟祬鑹叉。鐧藉簳 / 娣辫壊妗ｈ繎榛?#0B1220锛夛細涓ゆ。鍏辩敤鍚屼竴鎵?`--sider-*` 鍙橀噺锛? * `LayoutView` 涓€琛屾牱寮忛兘涓嶇敤鍒嗕富棰?鈥斺€?鎹㈡。鍙崲 `html[data-theme]`銆? */
import { defineStore } from 'pinia';

export type ThemeMode = 'auto' | 'light' | 'dark';

const STORAGE_KEY = 'fish_admin_theme_mode';
/** 娌℃湁瀛樿繃鍋忓ソ鏃剁殑榛樿妗ｏ細**娴呰壊**锛堣鏂囦欢澶磋鏄庯級 */
const DEFAULT_MODE: ThemeMode = 'light';

/** 涓婚鍋忓ソ鍞竴璇诲啓鍑哄彛锛坄main.ts` 棣栧睆涔熺敤瀹冿紝閬垮厤"鎸傝浇鍚庢墠闂竴涓?锛?*/
export function readThemeMode(): ThemeMode {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === 'light' || v === 'dark' || v === 'auto' ? v : DEFAULT_MODE;
  } catch {
    return DEFAULT_MODE;
  }
}

function writeThemeMode(mode: ThemeMode) {
  try {
    if (mode === 'auto') localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    /* 闅愮妯″紡涓?localStorage 鍙兘涓嶅彲鐢細涓婚閫€鍖栦负"鏈浼氳瘽鏈夋晥"锛屼笉褰卞搷鍔熻兘 */
  }
}

/** 绯荤粺鏄惁鍋忓ソ娣辫壊锛圫SR/鑰佹祻瑙堝櫒鏃?matchMedia 鏃舵寜娴呰壊锛?*/
function systemPrefersDark(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

/** 鎶婁富棰樼粨鏋滃啓鍒?<html>锛圕SS 鍙橀噺涓?naive 涔嬪鐨勫尯鍩熷叏闈犲畠锛?*/
export function applyThemeAttr(resolved: 'light' | 'dark') {
  document.documentElement.setAttribute('data-theme', resolved);
}

/**
 * 銆屽亸濂?鈫?瀹為檯涓婚銆嶇殑鍞竴鍒ゅ畾锛坄main.ts` 棣栧睆涓?store getter 鍏辩敤鍚屼竴浠介€昏緫锛夈€? * 鎷嗗嚭鏉ユ槸涓轰簡閬垮厤"棣栧睆鍏堟寜 system銆佹寕杞藉悗鍙堟寜涓€娆″埆鐨勮鍒?杩欑涓ゅ鍒ゅ畾婕傜Щ銆? */
export function resolveThemeMode(mode: ThemeMode = readThemeMode()): 'light' | 'dark' {
  if (mode === 'auto') return systemPrefersDark() ? 'dark' : 'light';
  return mode;
}

export const useThemeStore = defineStore('theme', {
  state: () => ({
    mode: readThemeMode() as ThemeMode,
    /** 绯荤粺娣辨祬锛堜粎 mode==='auto' 鏃惰璇诲彇锛涙寕杞芥椂鍚屾涓€娆★紝涔嬪悗鐢?App.vue 鐨勭洃鍚洿鏂帮級 */
    systemDark: systemPrefersDark(),
  }),
  getters: {
    resolved(state): 'light' | 'dark' {
      if (state.mode === 'auto') return state.systemDark ? 'dark' : 'light';
      return state.mode;
    },
    isDark(): boolean {
      return this.resolved === 'dark';
    },
  },
  actions: {
    setMode(mode: ThemeMode) {
      this.mode = mode;
      writeThemeMode(mode);
      applyThemeAttr(this.resolved);
    },
    /** 鍦ㄣ€屾祬鑹?/ 娣辫壊銆嶄箣闂村垏鎹紙椤舵爮鎸夐挳鐢紱涓嶇粡杩?auto锛岄伩鍏嶇偣浜嗘病鍙嶅簲锛?*/
    toggle() {
      this.setMode(this.resolved === 'dark' ? 'light' : 'dark');
    },
    /** 绯荤粺涓婚鍙樺寲鏃惰皟鐢紙App.vue 鎸?matchMedia 鐩戝惉锛?*/
    setSystemDark(dark: boolean) {
      this.systemDark = dark;
      if (this.mode === 'auto') applyThemeAttr(this.resolved);
    },
    /** 棣栨鎸傝浇鍚屾涓€娆″睘鎬э紙骞傜瓑锛?*/
    syncAttr() {
      applyThemeAttr(this.resolved);
    },
  },
});
