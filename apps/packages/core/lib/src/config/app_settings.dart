import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App 本地设置（设置页，负责人设置需求）：
/// 消息通知开关（好友申请/客服消息角标）等轻量偏好，存安全存储；服务端数据不受影响
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _storage = FlutterSecureStorage();
  static const _kFriendNotify = 'setting_friend_notify';
  static const _kCsNotify = 'setting_cs_notify';
  static const _kWorkerNoticeAsked = 'setting_worker_notice_perm_asked';

  /// 测试钩子：widget 测试中安全存储的 method channel 永不响应（挂起），跳过真实读写
  @visibleForTesting
  static bool debugStorageDisabled = false;

  Future<bool> friendNotifyEnabled() async {
    if (debugStorageDisabled) return true;
    try {
      return (await _storage.read(key: _kFriendNotify)) != '0';
    } catch (_) {
      return true; // 存储不可用兜底
    }
  }

  Future<bool> csNotifyEnabled() async {
    if (debugStorageDisabled) return true;
    try {
      return (await _storage.read(key: _kCsNotify)) != '0';
    } catch (_) {
      return true;
    }
  }

  Future<void> setFriendNotify(bool v) =>
      _storage.write(key: _kFriendNotify, value: v ? '1' : '0');

  Future<void> setCsNotify(bool v) =>
      _storage.write(key: _kCsNotify, value: v ? '1' : '0');

  // ---- 打手态通知栏提醒（负责人 2026-10-15）：系统通知权限"只问一次" ----
  //
  // 为什么必须落盘：Android 13+ 的 POST_NOTIFICATIONS 弹窗**反复弹会让人反感**，
  // 而且用户点了"不允许"之后系统也可能不再弹。判定：进打手态时若系统还没授权
  // 且本标记为 false → 请求一次并置 true；被拒 → 只给**一次**中文说明，之后静默降级
  // （用户仍可在系统设置里自己打开，那时我们的 `notificationsAllowed()` 读到 true）。
  Future<bool> workerNoticePermissionAsked() async {
    if (debugStorageDisabled) return false;
    try {
      return (await _storage.read(key: _kWorkerNoticeAsked)) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setWorkerNoticePermissionAsked() async {
    if (debugStorageDisabled) return;
    try {
      await _storage.write(key: _kWorkerNoticeAsked, value: '1');
    } catch (_) {
      /* 存储不可用：退化为"这次运行内不重复问"（进程内还能靠 shell 只挂载一次兜住） */
    }
  }

  // ---- 主题模式（负责人需求：按账号独立保存，仅老板端使用） ----
  Future<String?> readThemeMode(String accountKey) => _storage.read(key: accountKey);

  Future<void> writeThemeMode(String accountKey, String modeKey) =>
      _storage.write(key: accountKey, value: modeKey);

  // 最近登录账号（启动时恢复该账号的主题选择）
  //
  // 2026-10-10：与下面的地址/AI 会话读写**对齐同一套兜底**（`debugStorageDisabled` 短路 + try/catch）。
  // 起因：`AuthStore.fetchMe()` 在登录落地时会 fire-and-forget 调 `writeLastUsername`，
  // 而它此前既不看测试钩子、也不 catch —— 无插件的环境（纯 dart 单测）里会**同步抛**
  // 出 `BindingBase.checkInstance`（测试里表现为"登录成功却抛异常"），
  // 真机上写失败同样会把异常漏进登录链路。语义不变：只存一个账号名，写不进去不影响主流程。
  Future<String?> readLastUsername() async {
    if (debugStorageDisabled) return null;
    try {
      return await _storage.read(key: 'last_username');
    } catch (_) {
      return null;
    }
  }

  Future<void> writeLastUsername(String username) async {
    if (debugStorageDisabled) return;
    try {
      await _storage.write(key: 'last_username', value: username);
    } catch (_) {
      /* 存储不可用：仅少一次"上次账号"记忆，不影响登录 */
    }
  }

  // ---- 地址发现韧性（2026-10-06）：本机记住"上次解析并生效的服务器地址" ----
  //
  // 用途：多源 bootstrap 里的"服务端自托管"这条腿需要一个**已知入口**才能去拉
  // `<候选>/site/client-config.json`。除了打包内置候选，本机记住的上次可用地址
  // 就是最有希望的那一个（隧道重开但域名没变、或后端短暂重启的场景全靠它）。
  // 只存一个 URL，不含任何凭据；读不到/写失败一律静默兜底（解析流程绝不因此失败）。
  static const _kLastGoodApi = 'address_last_good_api';

  // ── 底栏液态玻璃开关（负责人 2026-10-18；默认关）────────────────────────
  // 存 '1'/'0' 而不是 bool：和上面几条一样统一走字符串读写，少一条类型分支。
  // 读不到 → null → 调用方按"关"处理（外观开关绝不阻塞启动）。
  static const _kNavGlass = 'setting_nav_glass';

  Future<bool?> readNavGlass() async {
    if (debugStorageDisabled) return null;
    try {
      final v = await _storage.read(key: _kNavGlass);
      if (v == null) return null;
      return v == '1';
    } catch (_) {
      return null;
    }
  }

  Future<void> writeNavGlass(bool value) async {
    if (debugStorageDisabled) return;
    try {
      await _storage.write(key: _kNavGlass, value: value ? '1' : '0');
    } catch (_) {
      // 忽略：外观开关写盘失败不该影响主流程
    }
  }

  Future<String?> readLastGoodApi() async {
    if (debugStorageDisabled) return null;
    try {
      final String? v = await _storage.read(key: _kLastGoodApi);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null; // 存储不可用兜底
    }
  }

  Future<void> writeLastGoodApi(String apiBase) async {
    if (debugStorageDisabled) return;
    try {
      await _storage.write(key: _kLastGoodApi, value: apiBase);
    } catch (_) {
      /* 存储不可用：仅少一条自托管引导入口，不影响主流程 */
    }
  }

  // ---- 祁小山 AI 会话轮换：本机记住"上一次已经展示过的 session" ----
  //
  // 用途（老板端 AI 会话页的兜底）：`POST /user/ai/reset` 在离线/进程被杀时可能没发出去，
  // 这时服务端不会轮换 session，用户再进来就会看到上一次的对话。客户端把"已展示过的 session"
  // 记在本机（进程内 + 这里尽力持久化），下次进入若服务端返回的还是同一条 session，就按空会话渲染。
  // 只存一个 uuid，不含任何聊天内容；读不到/写失败都由调用方兜底（不影响主流程）。
  Future<String?> readAiSeenSession(String accountKey) async {
    if (debugStorageDisabled) return null;
    try {
      return await _storage.read(key: accountKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeAiSeenSession(String accountKey, String sessionId) async {
    if (debugStorageDisabled) return;
    try {
      await _storage.write(key: accountKey, value: sessionId);
    } catch (_) {
      /* 存储不可用：仅进程内记忆兜底 */
    }
  }
}
