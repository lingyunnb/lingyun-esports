import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 打手态「通知栏提醒」的**平台实现**（负责人 2026-10-15）
///
/// `fish_core` 只声明 `WorkerNotifier` 接口（判定/文案/落点全在 core，纯 Dart 可测），
/// 真正的"发系统通知"落在这里 —— 理由：core 同时被**已冻结的工作端**复用，
/// 往 core 引平台插件会连带改冻结端的依赖树（与 `WithdrawMedia` 的注入路线同源）。
///
/// ## 两个渠道（Android 8+ 必须分渠道，微信也是这么做的）
/// 渠道 id / 名称 / 描述的唯一出处是 core 的 [WorkerNoticeChannel]（这里不再写第二份字符串）：
///   - `worker_orders` 「新订单」：`Importance.high` + 声音 + 震动 → **横幅（heads-up）**
///   - `worker_messages` 「消息」：同上 —— 两种打扰在系统设置里能**单独关**
///
/// ⚠️ 渠道参数**一旦创建就锁死**（Android 的规定）：改了 importance/声音不会对老用户生效
/// —— 以后要调，得换新的 channelId 或让用户自己去系统设置里改。
///
/// ## 点击行为
///   - App 在后台/前台存活：`onDidReceiveNotificationResponse` → 解析 payload → 登记跳转请求；
///   - **App 被杀后点通知冷启动**：`getNotificationAppLaunchDetails()` → 同上（`init()` 的返回值）。
/// 两种情况都只交给 [WorkerNotifyHub.pendingRoute]，由打手态壳落到接单大厅 / 消息页。
/// 供条件导入统一调用（与 `worker_notifier_noop.dart` 的同名函数配对）
WorkerNotifier createWorkerNotifier() => WorkerLocalNotifier.instance;

class WorkerLocalNotifier implements WorkerNotifier {
  WorkerLocalNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// 生产单例（`main.dart` 注入给 [WorkerNotifyHub]）
  static final WorkerLocalNotifier instance = WorkerLocalNotifier();

  final FlutterLocalNotificationsPlugin _plugin;

  /// init 的**幂等**记忆（main 里调一次、show 前再兜一次不会重复建渠道/重复注册回调）
  Future<WorkerNoticeRoute?>? _ready;

  @override
  Future<WorkerNoticeRoute?> init() => _ready ??= _init();

  Future<WorkerNoticeRoute?> _init() async {
    if (kIsWeb) return null; // 本 App 只出 Android；Web 上整个功能关闭
    const InitializationSettings settings = InitializationSettings(
      // 通知栏小图标：用启动图标（`@mipmap/ic_launcher` 是 manifest 里已有的资源，
      // 不新增 drawable —— 为一个功能加一套图标资源不值得，且这个 App 只有一个图标）
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse, // 存活期点击
      );
      await _ensureChannels();
    } catch (_) {
      return null; // 插件不可用（异常/未支持）：安静关掉，不影响接单
    }
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      // 冷启动由点通知拉起：把要跳的目标交出去（壳还没建，先挂在 hub 上）
      return WorkerNoticeRoute.decode(details?.notificationResponse?.payload);
    } catch (_) {
      return null;
    }
  }

  /// 建两个渠道（幂等：已存在时系统忽略；用户在系统里改过的设置**不会被覆盖**）
  Future<void> _ensureChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    for (final channel in channels) {
      try {
        await android.createNotificationChannel(channel);
      } catch (_) {
        // 建渠道失败不致命：第一次 show 时插件还会按 notification details 再建一次
      }
    }
  }

  /// 两个渠道的定义（**测试直接引用它断参数**：重要性 / 声音 / 震动 / 中文名）
  static const List<AndroidNotificationChannel> channels = <AndroidNotificationChannel>[
    AndroidNotificationChannel(
      WorkerNoticeChannel.orderId,
      WorkerNoticeChannel.orderName,
      description: WorkerNoticeChannel.orderDescription,
      importance: Importance.high, // HIGH = 横幅（heads-up），不是只在抽屉里躺着
      playSound: true,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      WorkerNoticeChannel.messageId,
      WorkerNoticeChannel.messageName,
      description: WorkerNoticeChannel.messageDescription,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ),
  ];

  /// 点击（App 存活时）→ 登记跳转请求；**在这里解析 payload 保证解析只做一次**
  static void _onDidReceiveNotificationResponse(NotificationResponse response) {
    final route = WorkerNoticeRoute.decode(response.payload);
    if (route == null) return;
    WorkerNotifyHub.instance.requestRoute(route);
  }

  @override
  Future<bool> notificationsAllowed() async {
    if (kIsWeb) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true; // 非 Android 平台：不拦（本 App 只出 Android）
      return await android.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true; // 查不到 → 当作允许（宁可少一次弹窗，也不要误报"没权限"）
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    // Android 13+ 弹系统授权框；< 13 直接返回系统设置里的真实开关状态（插件源码 line 1935）
    return await android.requestNotificationsPermission() ?? false;
  }

  /// 每条通知的 Android 细节（**测试直接引用它断参数**：渠道 / HIGH / 声音 / 震动）
  ///
  /// 渠道已存在时系统以**渠道**为准（Android 规定），这里再给一次是为了"渠道第一次由
  /// show 触发创建"时也带上同样的参数 —— 两条路径的参数**同源**，不会漂。
  static AndroidNotificationDetails detailsFor(WorkerNoticeKind kind, String body) {
    final isOrder = kind == WorkerNoticeKind.order;
    return AndroidNotificationDetails(
      isOrder ? WorkerNoticeChannel.orderId : WorkerNoticeChannel.messageId,
      isOrder ? WorkerNoticeChannel.orderName : WorkerNoticeChannel.messageName,
      channelDescription: isOrder ? WorkerNoticeChannel.orderDescription : WorkerNoticeChannel.messageDescription,
      importance: Importance.high, // HIGH = 横幅（heads-up）
      priority: Priority.high, // Android 8 以前只有 priority 能出横幅，两个都给
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.message,
      // 正文可能两行（`分部 · 商品 · 金额` + `单号 …`）：展开时看全，不截断
      styleInformation: BigTextStyleInformation(body),
      autoCancel: true, // 点掉即消失（"像微信"：点开看过就不该再挂着）
    );
  }

  @override
  Future<void> show(WorkerNotice notice) async {
    if (kIsWeb) return;
    await init(); // 幂等：保证渠道与回调一定就绪（冷路径：show 先于 init 时）
    await _plugin.show(
      id: notice.id,
      title: notice.title,
      body: notice.body,
      notificationDetails: NotificationDetails(android: detailsFor(notice.kind, notice.body)),
      payload: notice.payload,
    );
  }

  @override
  Future<void> cancelAll() async {
    if (kIsWeb) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // 退出打手态时清通知失败无所谓：下一条照样按 id 覆盖
    }
  }
}
