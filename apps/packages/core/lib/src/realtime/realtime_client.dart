import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;

import '../api/api_client.dart';
import '../config/app_config.dart';

/// 实时通道客户端（docs/07：Socket.IO /ws/chat，JWT 握手认证）
/// 全局单例共享一条连接（性能要求 #34：杜绝页面各自建连导致的多 WS 连接）；
/// 心跳由单例统一维持，业务页面只订阅事件（on() 返回退订函数）。
class RealtimeClient {
  RealtimeClient({String? wsBaseUrl}) : _explicitBaseUrl = wsBaseUrl;

  /// 全应用共享实例
  static final RealtimeClient shared = RealtimeClient();

  /// 实际连接地址：显式传入优先，否则**每次连接时**读 AppConfig（地址下发后自动跟随，见 app_address.dart）
  String get _wsBaseUrl => _explicitBaseUrl ?? AppConfig.wsBase;

  /// 测试钩子：连接时**真正会用的** ws 地址。
  ///
  /// 用于断言"地址热切换后 WS 也跟着换"这一条 —— `_wsBaseUrl` 是私有 getter
  /// 且只在 [connect] 里被读，没有这个出口就只能靠"读源码"来相信它，不算验证。
  @visibleForTesting
  String get debugWsBaseUrl => _wsBaseUrl;

  /// 等级变更推送钩子（需求 #9）：由 AuthStore 注册，收到 user:level-changed 后刷新本地资料
  static void Function()? onLevelChanged;

  /// **WS 连不上钩子**（2026-10-06 地址发现韧性专项，纯新增）。
  ///
  /// 由 `AddressWatchdog` 注册。WS 连不上是比"某个 HTTP 请求失败"更强、更早的信号 ——
  /// 握手阶段就失败几乎只有两种原因：当前地址已失效，或设备没网。
  /// 前者的正确处置是**立刻重走地址发现并热切换**（不是等用户重启 App）。
  ///
  /// 默认 `null`：不注册时行为与历史逐字节相同。
  static void Function()? onConnectFailed;

  /// 当前持有的令牌（地址热切换后重连要用；null = 从未连接过）
  String? get token => _token;

  /// **地址热切换后按新地址重连**（同一令牌，2026-10-06）。
  ///
  /// 为什么必须有这个方法：[connect] 是幂等的（同 token 已连接就跳过），
  /// socket.io 的自动重连也会一直重连**旧 URL** —— 于是"地址换了"这个事实
  /// 永远传不进已经建立过的连接。这里强制丢弃旧 socket，按新的
  /// `AppConfig.wsBase` 重新建连。未连接过（`_token == null`）则什么都不做，
  /// 交给正常的登录流程首次建连。
  void rebind() {
    final String? t = _token;
    if (t == null) return;
    _socket?.dispose();
    _socket = null;
    connect(token: t);
  }

  final String? _explicitBaseUrl;
  sio.Socket? _socket;
  String? _token;
  Timer? _heartbeat;

  bool get connected => _socket?.connected ?? false;

  /// 测试钩子：widget 测试中禁止真实 socket 连接（防 pumpAndSettle 被重连循环卡住）
  @visibleForTesting
  bool debugDisabled = false;

  /// **测试钩子：连接/断开计数与最近一次连接的令牌**（2026-10-06 身份直切专项）
  ///
  /// 为什么需要：`debugDisabled = true` 时 [connect] 直接返回，于是"切身份时该断的断没断、
  /// 该建的建没建"在测试里不可观测 —— 而"管理员态不建 WS / 打手态有 WS / 切走要断开"
  /// 正是本次验收的硬要求。计数在**跳过之前**累加，因此断言的是"调用意图"：
  /// - 从打手态切到管理员态 → `debugDisconnectCount` +1 且**不再** connect；
  /// - 从管理员态切回打手态 → 先 disconnect，再 connect(companion 令牌)。
  /// 生产路径零影响（不读这些字段时什么都不发生）。
  @visibleForTesting
  int debugConnectCount = 0;

  @visibleForTesting
  int debugDisconnectCount = 0;

  /// 最近一次 [connect] 传入的令牌（null = 从未连接过）
  @visibleForTesting
  String? debugLastConnectToken;

  /// 测试注入的事件总线（见 [on] 的说明）；**生产永远为 null**
  @visibleForTesting
  void Function() Function(String event, void Function(dynamic data) handler)? debugOnOverride;

  @visibleForTesting
  void debugResetCounters() {
    debugConnectCount = 0;
    debugDisconnectCount = 0;
    debugLastConnectToken = null;
  }

  /// 建立连接（token = access token；服务端校验失败会立即断开）。
  /// 幂等：同 token 已连接时跳过（页面重复调用/重建不会多开连接）；token 变化（重新登录）则重连。
  void connect({required String token}) {
    debugConnectCount += 1;
    debugLastConnectToken = token;
    if (debugDisabled) return;
    if (_socket != null && _socket!.connected && _token == token) return;
    _token = token;
    _socket?.dispose();
    final socket = sio.io(
      '$_wsBaseUrl/ws/chat',
      sio.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .enableReconnection()
          .build(),
    );
    _socket = socket;
    socket.onConnect((_) {});
    socket.onDisconnect((_) {});
    socket.onConnectError((_) {
      // 地址看门狗据此触发"重取地址 + 热切换"（未注册时为 no-op，行为与历史一致）
      onConnectFailed?.call();
    });
    socket.on('pong', (_) {});
    // 单设备登录（docs/04）：服务端心跳校验发现会话被顶掉/失效 → 全局踢出（复用 API 钩子）
    socket.on('auth:session-replaced', (_) {
      ApiClient.onSessionKicked?.call('账号已在其他设备登录');
    });
    socket.on('auth:expired', (data) {
      /**
       * 封禁（2026-10-16 负责人需求「封禁秒踢」）：封禁时服务端会**主动**断开该账号的全部 WS
       * （`UserAdminService.ban()` → `BindingReleaseService.kickRevoked` → `disconnectByJti`），
       * 并在 `auth:expired` 载荷里带上 `{ message, errorCode: 'ACCOUNT_BANNED' }`
       * —— 因为被踢的用户可能**正停在某个页面不发请求**（只有 WS 在跑），
       * 只给一个空事件的话客户端只能弹通用的「登录已失效」，看不到"被封了、为什么被封"。
       *
       * 只认机器码（`ApiClient.accountBannedErrorCode`），不认文案。
       */
      final payload = data is Map ? data : const {};
      if (payload['errorCode'] == ApiClient.accountBannedErrorCode) {
        ApiClient.onAccountBanned?.call('${payload['message'] ?? ''}');
        return;
      }
      ApiClient.onSessionKicked?.call('登录已失效，请重新登录');
    });
    // 等级实时同步（需求 #9）：服务端在自动升级/管理员调级后推送，客户端立即刷新本地资料
    socket.on('user:level-changed', (_) {
      onLevelChanged?.call();
    });
    socket.connect();
    // 应用层心跳由单例统一维持（docs/07：25s ping），页面不再各自开 Timer
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
      _socket?.emit('ping', {});
    });
  }

  /// 订阅服务端事件；返回取消函数
  ///
  /// 【2026-10-08 客服大厅专项 · 测试钩子】[debugOnOverride] 非 null 时**整条订阅改走它**
  /// —— 存在的唯一理由：`debugDisabled = true` 时 `_socket` 恒为 null，`on()` 直接返回空退订函数，
  /// 于是"页面收到 `cs:new` 会不会刷新列表"这件事在单测里**根本无法触发**（只能靠真机）。
  /// 有了它，测试可以注入一个本地事件总线，把服务端会推的事件原样投进去（见 worker_cs_hall_test）。
  /// **生产永远为 null** → 行为与历史逐字节相同。
  void Function() on(String event, void Function(dynamic data) handler) {
    final override = debugOnOverride;
    if (override != null) return override(event, handler);
    final socket = _socket;
    if (socket == null) return () {};
    socket.on(event, handler);
    return () => socket.off(event, handler);
  }

  /// 发送事件到服务端（聊天 msg:send / conv:join 等）
  void emit(String event, [dynamic data]) {
    _socket?.emit(event, data ?? const {});
  }

  /// 手动心跳（保留兼容旧调用；单例已自动维持）
  void startHeartbeat() {
    _socket?.emit('ping', {});
  }

  void disconnect() {
    debugDisconnectCount += 1;
    _heartbeat?.cancel();
    _heartbeat = null;
    _socket?.dispose();
    _socket = null;
    _token = null;
  }
}
