/// 打手态「通知栏提醒」· **接线层**（负责人 2026-10-15）
///
/// core 那边的纯逻辑由 `packages/core/test/worker_notify_test.dart` 逐条钉死；
/// 这个文件钉的是**老板端这一侧真的接上了**：
///   ① 进打手态 → 壳启动派发（事件真的能变成通知）；
///   ② 老板态 → 一条都不发（身份隔离）；
///   ③ **在那一屏不发**（接单大厅 / 正在看的那条会话）；
///   ④ 点通知（含冷启动）→ 壳跳到接单大厅 / 消息页；
///   ⑤ 权限只问一次 + 被拒给一条说明（不反复弹）；
///   ⑥ 事件 payload 再乱也不崩；
///   ⑦ 退出打手态 → 闭嘴 + 清掉已弹的通知；
///   ⑧ 两个渠道的参数（中文名 / HIGH / 声音 / 震动）与"用户能单独关"。
///
/// 全程用**假通知器**（[WorkerNotifier]）+ 假 HTTP 服务器 + 假事件总线，**不碰系统 API**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/services/worker_local_notifier.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 "METHOD /path" 精确回包的假服务器（仓库既有测试同款）
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  int calls(String key) => requests.where((String r) => r == key).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 404, 'message': '请求的资源不存在', 'data': null}),
        404,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 假事件总线：`debugDisabled = true` 时没有真 socket，靠它把服务端事件**真的投进**订阅方
class _Bus {
  final Map<String, List<void Function(dynamic)>> _h = <String, List<void Function(dynamic)>>{};

  void Function() register(String event, void Function(dynamic data) handler) {
    (_h[event] ??= <void Function(dynamic)>[]).add(handler);
    return () => _h[event]?.remove(handler);
  }

  int subscribers(String event) => (_h[event] ?? const <void Function(dynamic)>[]).length;

  void fire(String event, dynamic data) {
    for (final void Function(dynamic) h in List<void Function(dynamic)>.of(_h[event] ?? const [])) {
      h(data);
    }
  }

  void clear() => _h.clear();
}

/// 假通知器：记下"发了几条、要了几次权限"，**不调系统 API**
class _FakeNotifier implements WorkerNotifier {
  final List<WorkerNotice> shown = <WorkerNotice>[];
  int initCalls = 0;
  int permissionRequests = 0;
  int cancelAllCalls = 0;
  bool allowed = true;
  bool grantResult = true;

  @override
  Future<WorkerNoticeRoute?> init() async {
    initCalls++;
    return null;
  }

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return grantResult;
  }

  @override
  Future<void> show(WorkerNotice notice) async => shown.add(notice);

  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

IdentityBindingStatus _binding() => IdentityBindingStatus.fromJson(<String, dynamic>{
      'bound': true,
      'activeCount': 1,
      'maxPerBoss': 1,
      'bindings': <Map<String, dynamic>>[
        <String, dynamic>{
          'bindingId': 'b1',
          'status': 'active',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'nickname': '小云',
            'workerStatus': 1,
            'canTakeOrder': true,
            'canServeCustomer': false,
          },
        },
      ],
    });

void main() {
  late _FakeServer server;
  late _Bus bus;
  late _FakeNotifier fake;
  int seq = 0;
  int mountSeq = 0;

  // ------------------------------------------------------------------ 工具
  // 注意：Dart 的**局部函数必须先声明后引用**（哪怕是包在 setUp 的闭包里），
  // 所以这一整段必须排在 setUp/setUpAll 之前。

  void loginAsWorker() => AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'companion-token',
        status: _binding(),
      );

  void loginAsBoss() => AuthStore.instance.debugSetIdentity(identity: AppIdentity.boss);

  Map<String, dynamic> order({String id = 'o1'}) => <String, dynamic>{
        'id': id,
        'orderNo': '20261015230001',
        'productName': '三局陪练',
        'priceUnit': '局',
        'totalAmount': 38,
        'status': 'pending_take',
        'statusName': '待接单',
        'quantity': 1,
        'createdAt': '2026-10-15T02:00:00.000Z',
        'divisionId': 'd1',
      };

  Map<String, dynamic> msgEvent({
    String conversationId = 'c1',
    String senderType = 'user',
    String content = '在吗，想约今晚八点',
  }) =>
      <String, dynamic>{
        'msgId': 'm1',
        'seq': 3,
        'conversationId': conversationId,
        'senderType': senderType,
        'senderId': 'u1',
        'senderNickname': '小苏',
        'msgType': 'text',
        'content': content,
        'recalled': false,
      };

  /// 打手态三屏会打到的接口全摆好（其余 404 只会让对应区块显示错误态，不影响本用例）
  void serveAll() {
    server.ok('GET /worker/order-hall', <String, dynamic>{
      'list': <Map<String, dynamic>>[order()],
      'total': 1,
      'page': 1,
      'pageSize': 50,
    });
    server.ok('GET /worker/division-permissions', <Map<String, dynamic>>[
      <String, dynamic>{'divisionId': 'd1', 'label': '三角洲行动·手游', 'canTakeOrder': true},
    ]);
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'list': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'c1', 'type': 'cs', 'unread': 1, 'lastSeq': 1, 'status': 'open', 'peer': null},
      ],
      'total': 1,
    });
    server.ok('GET /user/conversations', <String, dynamic>{'list': <dynamic>[], 'total': 0});
    server.ok('GET /divisions', <dynamic>[]);
  }

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    server = _FakeServer();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://worker-notify-${seq++}.local'))
      ..httpClientAdapter = server;
    bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;
    RealtimeClient.shared.debugResetCounters();
    // 假通知器经 hub 注入（生产由 main.dart 注入 WorkerLocalNotifier）
    fake = _FakeNotifier();
    WorkerNotifyHub.instance.reset();
    WorkerNotifyHub.instance.notifier = fake;
    WorkerNotifyPresence.instance.reset();
    AuthStore.instance.debugSetSession(accessToken: 'boss-primary');
    loginAsWorker();
    serveAll();
  });

  tearDown(() {
    WorkerNotifyHub.instance.reset();
    WorkerNotifyPresence.instance.reset();
    RealtimeClient.shared.debugOnOverride = null;
    bus.clear();
    ApiClient.debugDefaultDio = null;
    ApiCache.instance.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  /// 30 帧 × 50ms：够 Dio 假适配器 + 事件回调全部落地（**不用 pumpAndSettle**：
  /// 页面里有骨架/转圈动画，`pumpAndSettle` 会一直等下去）
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      // **每次挂载换一个 key**：不给 key 的话同一个测试里的第二次 pumpWidget 会**复用**上一次的
      // State（同类型同位置）→ initState 不重跑 → "重新进打手态会不会再要一次权限"这类用例
      // 会假绿。有了唯一 key，每次都是真的重挂。
      home: IdentityWorkerShell(key: ValueKey<String>('worker-shell-${mountSeq++}'), api: ApiClient()),
    ));
    await settle(tester);
  }

  /// 当前停在第几个 tab（**生产中画底栏用的就是它**，比"找文字"精确：
  /// `IndexedStack` 里三页同时挂载，按文字找会同时找到不可见那几页的字）
  int navIndex(WidgetTester tester) =>
      tester.widget<AppPlainBottomNav>(find.byType(AppPlainBottomNav)).currentIndex;

  /// 点打手态底栏（标签文字在页面里也可能出现，必须限定在底栏内找）
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(AppPlainBottomNav), matching: find.text(label)));
    await settle(tester, frames: 5);
  }

  // =============================================================== ① 接线

  testWidgets('① 进打手态：壳订阅了 order:new / msg:new，事件真的变成通知（内容全是真的）', (tester) async {
    await pumpShell(tester);
    // order:new 有两条订阅：**本功能的派发服务 1 条** + 接单大厅页自己的自动刷新 1 条
    expect(bus.subscribers('order:new'), 2, reason: '大厅自动刷新 1 + 派发服务 1');
    // msg:new 同理：消息页自己订阅做刷新 1 条 + 派发服务 1 条
    expect(bus.subscribers('msg:new'), 2, reason: '消息页刷新 1 + 派发服务 1');

    // 默认停在「接单」那一屏 → 新单**在屏上不发**（免打扰，见 ③）；先切到消息页再投
    await tapTab(tester, '消息');
    expect(navIndex(tester), 1);

    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    bus.fire('msg:new', msgEvent());
    await settle(tester);

    expect(fake.shown.length, 2, reason: '新单 1 条 + 消息 1 条');
    final orderNotice = fake.shown.firstWhere((n) => n.kind == WorkerNoticeKind.order);
    expect(orderNotice.title, '有新订单');
    expect(orderNotice.body, '三角洲行动·手游 · 三局陪练 · ¥38.00\n单号 20261015230001',
        reason: '正文全部来自服务端（分部名 / 商品 / 金额 / 单号），一个字都不是编的');
    final msgNotice = fake.shown.firstWhere((n) => n.kind == WorkerNoticeKind.message);
    expect(msgNotice.title, '祁连山客服');
    expect(msgNotice.body, '在吗，想约今晚八点');
  });

  testWidgets('② 老板态（打手壳根本不在树上）→ 没有订阅、一条都不发（结构上的隔离）', (tester) async {
    // 老板态的真实结构：`HomeShell` 走老板分支，`IdentityWorkerShell` 压根不挂载
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await settle(tester, frames: 3);
    expect(bus.subscribers('order:new'), 0);
    expect(bus.subscribers('msg:new'), 0);
    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    bus.fire('msg:new', msgEvent());
    await settle(tester);
    expect(fake.shown, isEmpty);
  });

  testWidgets('②b 极端情形：壳还活着但身份已切回老板 → 判定门拦住，一条都不发', (tester) async {
    await pumpShell(tester);
    loginAsBoss(); // 真实链路里壳会被换掉，这里故意不给它这个机会
    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    bus.fire('msg:new', msgEvent());
    await settle(tester);
    expect(fake.shown, isEmpty, reason: '身份不是打手态 → 一条都不发');
    // ⚠️ 这里**不**去数 `GET /worker/order-hall` 的次数：那两个事件同时也会被
    // 大厅页 / 消息页**自己的**订阅消费（它们收到事件就回源刷新列表），计数分不出"谁发的"。
    // 本功能的判据只有 [fake.shown]（到底弹没弹通知），干净且充分。
  });

  // =============================================================== ③ 免打扰

  testWidgets('③ 就在接单大厅那一屏 → 新单不弹；切到消息页后同一条事件**立刻会弹**', (tester) async {
    await pumpShell(tester);
    expect(WorkerNotifyPresence.instance.hallVisible, isTrue, reason: '默认停在接单大厅');

    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    await settle(tester);
    expect(fake.shown, isEmpty, reason: '用户正盯着大厅，列表自己在刷新 → 不打扰');

    await tapTab(tester, '消息');
    expect(WorkerNotifyPresence.instance.hallVisible, isFalse);

    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    await settle(tester);
    expect(fake.shown.length, 1, reason: '不在大厅那一屏 → 弹');
  });

  testWidgets('④ 正在看那条会话 → 该会话的消息不弹；别人的会话照弹', (tester) async {
    await pumpShell(tester);
    // 宿主（openWorkerChat）在压上聊天页期间写这个字段
    WorkerNotifyPresence.instance.openConversationId = 'c1';
    bus.fire('msg:new', msgEvent(conversationId: 'c1'));
    await settle(tester);
    expect(fake.shown, isEmpty, reason: '正在看这条会话 → 不弹（"像微信"的免打扰）');

    WorkerNotifyPresence.instance.openConversationId = '';
    bus.fire('msg:new', msgEvent(conversationId: 'c1'));
    await settle(tester);
    expect(fake.shown.length, 1);
  });

  // =============================================================== ④ 点击跳转

  testWidgets('⑤ 点消息通知 → 壳跳到消息页（**冷启动的 pendingRoute 走同一条路**）', (tester) async {
    await pumpShell(tester);
    expect(navIndex(tester), 0, reason: '默认停在接单大厅');
    expect(WorkerNotifyPresence.instance.hallVisible, isTrue);

    // 通知被点：payload 解码 → 登记请求（生产中由通知器回调做，冷启动走 getNotificationAppLaunchDetails）
    final route = WorkerNoticeRoute.decode(
      const WorkerNoticeRoute(kind: WorkerNoticeKind.message, conversationId: 'c1').encode(),
    );
    WorkerNotifyHub.instance.requestRoute(route!);
    await settle(tester, frames: 5);

    expect(navIndex(tester), 1, reason: '消息通知 → 消息页（底栏第 2 项）');
    expect(WorkerNotifyPresence.instance.hallVisible, isFalse, reason: '已经离开接单大厅');
    expect(WorkerNotifyHub.instance.pendingRoute.value, isNull, reason: '请求被消费掉，不会残留');
  });

  testWidgets('⑤b 点新单通知 → 壳回到接单大厅那一屏', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '消息');
    expect(navIndex(tester), 1);

    WorkerNotifyHub.instance.requestRoute(const WorkerNoticeRoute(kind: WorkerNoticeKind.order));
    await settle(tester, frames: 5);
    expect(navIndex(tester), 0, reason: '新单 → 接单大厅');
    expect(WorkerNotifyPresence.instance.hallVisible, isTrue);
    expect(find.text('三局陪练'), findsWidgets, reason: '大厅里真的摆着一单（数据到位，不是跳进空屏）');
  });

  testWidgets('⑤c 坏 payload → 不崩、不跳', (tester) async {
    await pumpShell(tester);
    expect(WorkerNoticeRoute.decode('{"k":"message"'), isNull);
    expect(WorkerNoticeRoute.decode(null), isNull);
    expect(tester.takeException(), isNull);
    expect(navIndex(tester), 0, reason: '坏 payload 没有把界面拽走');
  });

  test('⑤d 过期的跳转请求不再抢用户的视线（>2 分钟的请求直接作废）', () {
    // 不挂壳：只验 hub 自己的时效语义（挂壳时 requestRoute 会被同步消费掉，测不到"过期"）
    WorkerNotifyHub.instance.now = () => DateTime(2026, 10, 15, 10, 0, 0);
    WorkerNotifyHub.instance.requestRoute(const WorkerNoticeRoute(kind: WorkerNoticeKind.message));
    WorkerNotifyHub.instance.now = () => DateTime(2026, 10, 15, 10, 5, 0);
    expect(WorkerNotifyHub.instance.consumeRoute(), isNull, reason: '过期 = 不作数');

    WorkerNotifyHub.instance.now = () => DateTime(2026, 10, 15, 10, 0, 0);
    WorkerNotifyHub.instance.requestRoute(const WorkerNoticeRoute(kind: WorkerNoticeKind.order));
    WorkerNotifyHub.instance.now = () => DateTime(2026, 10, 15, 10, 0, 30);
    expect(WorkerNotifyHub.instance.consumeRoute(), isNotNull, reason: '保鲜期内照跳');
    expect(WorkerNotifyHub.instance.pendingRoute.value, isNull, reason: '取走即清，不残留');
  });

  // =============================================================== ⑥ 权限

  testWidgets('⑥ 首次进打手态问一次；被拒 → 给一条中文说明（一次）', (tester) async {
    fake.allowed = false; // 系统层面还没允许
    fake.grantResult = false; // 用户拒绝
    await pumpShell(tester);
    expect(fake.permissionRequests, 1, reason: '没权限 → 问一次');
    expect(find.text(WorkerNoticeText.permissionDenied), findsOneWidget, reason: '被拒 → 有一次性说明，不是静默');
    await settle(tester, frames: 60); // 让 Toast 自己消失（它带 2s 定时器）
    expect(find.text(WorkerNoticeText.permissionDenied), findsNothing);
  });

  testWidgets('⑥b 已经开着 → 一次都不问（不打扰）', (tester) async {
    fake.allowed = true;
    await pumpShell(tester);
    expect(fake.permissionRequests, 0);
    expect(find.text(WorkerNoticeText.permissionDenied), findsNothing);
  });

  testWidgets('⑥c 问过之后（落盘记忆）：再进打手态**不再反复弹**', (tester) async {
    // 这一个用例要用**真的**安全存储读写（其余用例走 debugStorageDisabled 的短路），
    // 用插件自带的测试替身做内存实现 —— 验证的是"标记真的落盘了、下次读到"。
    AppSettings.debugStorageDisabled = false;
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    addTearDown(() => AppSettings.debugStorageDisabled = true);

    fake.allowed = false;
    fake.grantResult = false;

    await pumpShell(tester);
    expect(fake.permissionRequests, 1, reason: '第一次：问一次');

    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, frames: 5);
    await pumpShell(tester);
    expect(fake.permissionRequests, 1, reason: '第二次：标记已落盘 → 不再弹（用户已经表达过一次态度）');
  });

  // =============================================================== ⑦ 乱数据

  testWidgets('⑦ 事件 payload 再乱也不崩、不发（null / 字符串 / 数组 / 缺字段 / 坏 JSON）', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '消息');
    for (final dynamic payload in <dynamic>[
      null,
      'not-a-map',
      <dynamic>[1, 2, 3],
      <String, dynamic>{'orderId': ''},
      '{"orderId":',
      <String, dynamic>{'conversationId': ''},
      <String, dynamic>{'conversationId': 'c1', 'senderType': 'worker'},
      <String, dynamic>{'conversationId': 'c1', 'senderType': 'system'},
    ]) {
      bus.fire('order:new', payload);
      bus.fire('msg:new', payload);
    }
    await settle(tester);
    expect(fake.shown, isEmpty, reason: '解析不出来 / 自己发的 / 系统消息 → 一律不发');
    expect(tester.takeException(), isNull);
  });

  // =============================================================== ⑧ 退出打手态

  testWidgets('⑧ 切回老板态（壳销毁）→ 退订 + 清掉已弹的打手通知，之后一条都不发', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '消息');
    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    await settle(tester);
    expect(fake.shown.length, 1);
    final subscribed = bus.subscribers('order:new');
    expect(subscribed, greaterThan(0), reason: '挂载期间确实有订阅');

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    await settle(tester, frames: 5);
    expect(bus.subscribers('order:new'), 0, reason: '退订，事件不再进来');
    expect(fake.cancelAllCalls, 1, reason: '通知栏里不该留着打手态的通知');

    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    await settle(tester, frames: 5);
    expect(fake.shown.length, 1, reason: '退出后一条都不多发');
  });

  testWidgets('⑧b 宿主没注入通知器（未接平台实现）→ 一切如常，不订阅也不崩', (tester) async {
    WorkerNotifyHub.instance.reset(); // notifier = null
    await pumpShell(tester);
    // 只剩接单大厅页自己的自动刷新订阅 1 条 —— **没有第 2 条**：派发服务根本没启动
    expect(bus.subscribers('order:new'), 1, reason: '没有能力就整个功能关闭，行为与改动前一致');
    bus.fire('order:new', <String, dynamic>{'orderId': 'o1'});
    await settle(tester);
    expect(fake.shown, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // =============================================================== ⑨ 渠道与文案

  test('⑨ 两个渠道：中文名/描述 + importance HIGH + 声音 + 震动（用户在系统设置里能单独关）', () {
    expect(WorkerLocalNotifier.channels.length, 2);
    final order = WorkerLocalNotifier.channels[0];
    final message = WorkerLocalNotifier.channels[1];
    expect(order.id, 'worker_orders');
    expect(order.name, '新订单');
    expect(order.description, '有新单进接单大厅时提醒你');
    expect(message.id, 'worker_messages');
    expect(message.name, '消息');
    expect(message.description, '客服或老板发来消息时提醒你');
    for (final c in WorkerLocalNotifier.channels) {
      expect(c.importance, Importance.high, reason: 'HIGH = 横幅（heads-up）');
      expect(c.playSound, isTrue);
      expect(c.enableVibration, isTrue);
    }
    // 两条通知的 details 与渠道参数同源（渠道已存在时以渠道为准，参数不会漂）
    for (final kind in WorkerNoticeKind.values) {
      final d = WorkerLocalNotifier.detailsFor(kind, '正文');
      expect(d.importance, Importance.high);
      expect(d.priority, Priority.high);
      expect(d.playSound, isTrue);
      expect(d.enableVibration, isTrue);
      expect(d.autoCancel, isTrue);
      expect(d.channelId, kind == WorkerNoticeKind.order ? 'worker_orders' : 'worker_messages');
    }
    // 通知文案里不许出现打手态黑名单词（与 `docs/21` 反 AI 味/文案护栏同一口径）
    expect(IdentityWorkerCleanliness.violations(<String>[
      WorkerNoticeText.orderTitle,
      WorkerNoticeChannel.orderName,
      WorkerNoticeChannel.orderDescription,
      WorkerNoticeChannel.messageName,
      WorkerNoticeChannel.messageDescription,
      WorkerNoticeText.permissionDenied,
      WorkerNoticeText.messageTitleCs,
      WorkerNoticeText.recalledPreview,
      WorkerNoticeText.imagePreview,
      WorkerNoticeText.otherPreview,
    ]), isEmpty);
  });
}
