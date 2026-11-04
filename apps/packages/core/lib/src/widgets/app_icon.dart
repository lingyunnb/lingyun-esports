/// 旧导入路径的**兼容转发层**（2026-10-16 方案 F 图标迁移）。
///
/// 历史：本文件曾是「旧图标包装器」——一个把 Flutter 内置 Material 图标
/// （Material 图标字面量）包成 `static const IconData` 的字典，全 App 的图标都从这里取。
/// 方案 F 换成自绘图标集（`src/icons/`）后，本文件**只做转发**：
/// 旧的 `import '.../widgets/app_icon.dart'` 与 `fish_core.dart` 的
/// `export 'src/widgets/app_icon.dart'` 因此**一行都不用改**。
///
/// 转发出去的东西：
/// - [AppIcon]：新图标组件（自绘）；同时保留旧包装器的 **70 条语义别名**
///   （`AppIcon.info` / `AppIcon.check` / `AppIcon.servicesFill` …，名与值逐字未变，
///   所以 `Icon(AppIcon.x)` 形式的存量调用点与测试 finder 全部继续可用）；
/// - `AppIcon.of(...)`：**迁移入口** —— 把旧 `IconData` 解析成新图标并画新几何；
/// - [AppIcons]：新图标枚举；[AppIconsLegacy]：Material 名 → 新图标的映射表；
/// - [AppIconPainter]：自绘 painter（像素级测试直接用）。
library;

export '../icons/app_icon.dart';
export '../icons/app_icons.dart';
export '../icons/app_icons_legacy.dart';
