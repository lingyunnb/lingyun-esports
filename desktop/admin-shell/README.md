# 祁连山电竞 · 管理端 桌面版（`desktop/admin-shell`）

把管理端装进一个 **Windows 单文件 exe**，方案是**薄壳**：**壳 + 远程页面**。

```
exe（只有壳：寻址 / 窗口 / 菜单 / 错误页）
        │  启动时按顺序探活 /api/v1/health
        ▼
  http://127.0.0.1:3100/  ← 管理端页面（admin-web，由后端直接托管）
  或 Gitee 引导/内置候选里的公网地址
```

**页面更新不用重发 exe**：改完 `admin-web` 重新构建、后端一起发布，用户**重开一次壳**就是新页面
（想强制拉新用「视图 → 强制刷新」或 `Ctrl+Shift+R`）。

- 窗口：默认 1600×1000（下限 **1440×900**），大小/位置/最大化状态记忆在
  `%APPDATA%\qls-admin-shell\window-state.json`（记忆的位置若已不在任何屏幕上会自动丢弃）
  —— 目录名用的是 package.json 的 `name`（`qls-admin-shell`，**ASCII**，避免中文路径带来的编码坑）
- 标题：**恒为「祁连山电竞 · 管理端」**（拦掉远端页面 `<title>管理后台</title>` 的顶替）
- 菜单：精简三组 —— **管理端**（重新连接服务端 / 在浏览器打开 / 退出）·
  **视图**（刷新 `Ctrl+R` / 强制刷新 `Ctrl+Shift+R` / 开发者工具 `F12` / 缩放 / 全屏 `F11`）·
  **帮助**（关于 / 诊断信息，含本轮探活记录）
- 图标：`build/icon.png` + `build/icon.ico`（由 `tools/make-icon.py` 从
  `docs/验收素材/2026-10-09-QQ互联提交/qq_icon_512.png` 生成，多尺寸 16–256）
  —— ⚠️ 那个**素材目录不入 git**，所以 `build/icon.png` / `build/icon.ico` 才是**入库的权威产物**：
  打包只读它们、不依赖源图；要重新生成才需要那份源 PNG 在本机存在

## 地址解析顺序（三档，每一档都要 `/api/v1/health` 返回 **HTTP 200 且 `code=0`** 才算可用）

| 档 | 地址 | 说明 |
|---|---|---|
| ① | `http://127.0.0.1:3100/` | 壳与服务端同一台电脑时最快（也是本机验收走的那一档） |
| ② | Gitee raw 引导 `https://gitee.com/lingyunnb666/fish-endpoint/raw/main/client-config.json` | 取 `api` **去掉 `/api/v1`** 得到域名；`preferred` / `candidates` 依次兜底 |
| ③ | 内置候选（写死在 `src/resolver.js`） | ngrok 固定域名 `<your-tunnel-domain>` + 上次隧道域名 `immediate-assign-nor-bike.trycloudflare.com` |

三档全灭 → 显示**自家风格的浅色错误页**（「连不上服务端，请先启动服务」+ 三条启动步骤 +
**本轮探活记录** + 「重试」按钮），**不白屏、不裸报 `ERR_CONNECTION_REFUSED`**。
页面已连上但加载中会先显示「正在连接服务端…」加载页（同样浅色，不白屏）。

### 2026-10-11 实测（写进报告的那次）

| 档 | 结果 |
|---|---|
| ① 本机 | **✓ HTTP 200 · code=0 · database=up redis=up（62ms）** |
| ② Gitee 引导 | 解析正常，但 Gitee 上那两个域名**当前都不可用**：quick tunnel `vista-bind-archives-components` → **HTTP 530**（隧道已过期），ngrok 固定域名 → **HTTP 403**（月度流量耗尽，账号级，见 CLAUDE.md 公网出口事件） |
| ③ 内置候选 | ngrok 固定域名 ✗ 403；**上次隧道域名 `immediate-assign-nor-bike.trycloudflare.com` ✓ HTTP 200** → 公网真能加载出管理端 |

> ⚠️ **Gitee 引导已落后于仓库**：`config/client-config.json`（本机）updatedAt = `2026-10-10`、api = `immediate-assign-nor-bike…`（**活着**）；
> Gitee raw 上还是 `2026-10-06` 的 `vista-bind-archives-components…`（**已 530**）。
> 换地址后要跑 `scripts/publish-address.ps1` 把新地址推上 Gitee，否则 ② 这一档等于白跑（当前靠 ③ 兜住）。
> 这条不属本次改动范围（只读发现，未改任何发布脚本）。

## 测试缝（只读环境变量，正常双击完全不受影响）

| 变量 | 作用 | 用在哪 |
|---|---|---|
| `QLS_SHELL_FORCE_OFFLINE=1` | 所有探活/引导强制失败 | 验收「三档全灭 → 自家错误页，不白屏」（否则只能把服务停掉，风险太大） |
| `QLS_SHELL_SKIP_LOCAL=1` | 跳过 ① 本机 | 验收 ②→③ **公网回退链**（本机开发时 ① 永远命中，这两档平时根本跑不到） |

## 构建

```powershell
cd D:\fish\desktop\admin-shell
npm install          # 首次；.npmrc 已配 npmmirror（registry + electron + electron-builder 二进制）
npm run build        # = electron-builder --win portable --x64（脚本内部强制设镜像）
```

产物：`D:\fish\dist-desktop\祁连山电竞-管理端-<版本>.exe`（portable 单文件，免安装，双击即用）。

> **国内网络铁律**：不设镜像会去 GitHub 拉 ~100MB 的 Electron 与 NSIS 二进制，**表现为长时间无输出地卡死**。
> `scripts/build-win.mjs` 已经把四个镜像变量写进环境再调 electron-builder，
> 所以 `npm run build` **自带镜像**，不依赖"记得先 export"。

## 验收（真启动 + CDP 断言，不看代码）

```powershell
node tools/verify-shell-cdp.mjs                # 用 dist-desktop 里最新的 exe（在线，本机 ① 档 + 登录 + 侧栏）
node tools/verify-shell-cdp.mjs --dev          # 改完源码想快速自检（用 node_modules 的 electron）
node tools/verify-shell-cdp.mjs --offline      # 三档全灭 → 自家错误页 + 「重试」真的又跑一轮
node tools/verify-shell-cdp.mjs --no-local     # 跳过 ① → 走 ②→③ 公网回退链
```

脚本自己拉起 exe（带 `--remote-debugging-port=9222`）→ 连上 CDP → 断言：
① 解析走第 ① 档且真探活过 `/api/v1/health`；② 窗口标题（含**操作系统层面** `MainWindowTitle`）+ URL + 页面标题；
③ 浅色 `body` 底色**逐字** `rgb(245, 247, 251)` + `data-theme=light`；④ 登录后侧栏 **8 个顶层项**名字逐条比对 +
白底侧栏；⑤ 无未捕获异常；⑥ 截图（CDP 页面截图 + **系统级窗口截图**含标题栏）；⑦ 收尾关掉自己拉起的进程（不留残留）。
账号走 `scripts/tools/regression-admin.js` 的**专用测试超管**，绝不碰真人超管会话。

## 已知限制（有意为之，不是缺陷）

- **未做代码签名**：首次运行 Windows SmartScreen 会拦一下 → 点「更多信息」→「仍要运行」即可；
  Chrome/Edge 下载时也可能提示"不常见的文件"。企业内网分发想彻底免提示需买代码签名证书（负责人决策）。
- **体积 ≈100MB**：Electron 运行时本身就 ~200MB（压缩后 ~100MB），portable 每次启动要解压到
  `%TEMP%\qls-admin-shell`，首次启动约 2–5s —— 这是"免安装单文件"的代价。
- **不做自动更新**：壳指向远程页面，页面天然跟随；只有当**壳自身**（寻址/菜单/窗口）要改时才需要重发 exe。
- 依赖许可：**electron（MIT）+ electron-builder（MIT）**，无 GPL/AGPL 依赖。

## ⚠️ 自动化里的大坑：`ELECTRON_RUN_AS_NODE`

如果父进程环境里有 `ELECTRON_RUN_AS_NODE=1`（**DSH 会话就带这个变量**，一些"把 electron 当 node 跑"的工具链也会带），
`electron.exe` 会**退化成纯 Node**：进程活着、**窗口不开、9222 端口不通**、`require('electron')` 返回一个字符串路径。
从资源管理器双击不受影响。自动化脚本里必须显式剔除：

```js
const env = { ...process.env }; delete env.ELECTRON_RUN_AS_NODE;
spawn(exe, ['--remote-debugging-port=9222'], { env });
```

`tools/verify-shell-cdp.mjs` 已经这么做了。

## 目录

```
src/main.js        主进程：窗口 / 菜单 / 地址解析编排 / 错误页切换（唯一入口）
src/resolver.js    地址解析与探活（① 本机 → ② Gitee 引导 → ③ 内置候选），可单测的纯逻辑
src/preload.js     contextBridge 暴露的唯一壳接口（adminShell：title/version/info/retry/onStatus）
src/loading.html   加载页（浅色，显示探活进度）
src/error.html     错误页（浅色，探活记录 + 重试）
src/shell.css      两个自带页面的共用样式（与 admin-web 浅色 token 同源）
build/             icon.png（窗口图标）/ icon.ico（exe 图标，多尺寸）
scripts/build-win.mjs  打包入口（先设镜像再调 electron-builder）
tools/verify-shell-cdp.mjs  真启动 + CDP 断言验收套件
tools/make-icon.py         品牌 PNG → 多尺寸 ico
```
