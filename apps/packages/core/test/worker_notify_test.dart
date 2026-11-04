/// 打手态「通知栏提醒」· **纯逻辑层**（负责人 2026-10-15）
///
/// 这个文件钉的是 core 侧的三件事（全部不碰系统 API、不碰任何平台插件）：
///   ① **判定门**：打手态才发 / 老板态不发 / 在那一屏不发 / 被抢·取消不算新单 /
///      自己发的消息不回弹给自己；
///   ② **payload 解析**：服务端事件形状千奇百怪（null / 字符串 / 缺字段 / 坏 JSON），
///      **解析不许崩**，解析不出来就不发；
///   ③ **派发链路**：事件 → 回源拿真实业务信息 → 交给通知器。
///      其中"不得编造"是硬要求：**回源拿不到就不发**，而不是拼一条假文案。
///
/// 变异验证（报告里贴红/绿，实测见开发日志）：
///   - 把 `_shouldFire` 里的 `_workerModeProbe()` 去掉 → 「老板态不发」立刻红；
///   - 把 `_presence.hallVisible` 那段去掉 → 「在大厅不发」立刻红；
///   - 把 `isNewOrderEvent` 那段去掉 → 「被抢/取消不算新单」立刻红。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 "METHOD /path" 精确回包 + 记录请求的假服务器（仓库既有测试同款）
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

/// 假通知器（**不碰系统 API**）：记下"发了几条、什么内容、要了几次权限"
class _FakeNotifier implements WorkerNotifier {
  final List<WorkerNotice> shown = <WorkerNotice>[];
  int initCalls = 0;
  int permissionRequests = 0;
  int cancelAllCalls = 0;

  /// 系统层面是否已允许（false → 需要弹一次授权）
  bool allowed = true;

  /// 弹窗结果
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

/// 一条真实形状的打手身份绑定（服务端 `GET /user/identity` 的 `bindings[].worker`）
IdentityBindingStatus _binding({int workerStatus = 1}) => IdentityBindingStatus.fromJson(<String, dynamic>{
      'bound': true,
      'activeCount': 1,
      'maxPerBoss': 1,
      'message': '可继续绑定',
      'bindings': <Map<String, dynamic>>[
        <String, dynamic>{
          'bindingId': 'b1',
          'status': 'active',
          'boundAt': '2026-10-15T00:00:00.000Z',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'nickname': '小云',
            'workerStatus': workerStatus,
            'canTakeOrder': true,
            'canServeCustomer': false,
          },
        },
      ],
    });

void main() {
  late _FakeServer server;
  int seq = 0;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    final String base = 'http://worker-notify-${seq++}.local';
    server = _FakeServer();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    AuthStore.instance.debugSetSession(accessToken: 'boss-primary');
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  // ------------------------------------------------------------------ 工具

  void loginAsWorker({int workerStatus = 1, bool withBinding = true}) {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-token',
      status: withBinding ? _binding(workerStatus: workerStatus) : null,
    );
  }

  void loginAsBoss() {
    AuthStore.instance.debugSetIdentity(identity: AppIdentity.boss);
  }

  /// 大厅里"我"能看到的一单（服务端 `orderView()` + `productName` 的真实字段名）
  Map<String, dynamic> hallOrder({String id = 'o1', String orderNo = '20261015230001'}) => <String, dynamic>{
        'id': id,
        'orderNo': orderNo,
        'productName': '三局陪练',
        'priceUnit': '局',
        'totalAmount': 38,
        'status': 'pending_take',
        'statusName': '待接单',
        'quantity': 1,
        'createdAt': '2026-10-15T02:00:00.000Z',
        'divisionId': 'd1',
      };

  void serveHall({List<Map<String, dynamic>>? orders, bool divisionLabel = true}) {
    server.ok('GET /worker/order-hall', <String, dynamic>{
      'list': orders ?? <Map<String, dynamic>>[hallOrder()],
      'total': (orders ?? <Map<String, dynamic>>[hallOrder()]).length,
      'page': 1,
      'pageSize': 20,
    });
    server.ok(
      'GET /worker/division-permissions',
      divisionLabel
          ? <Map<String, dynamic>>[
              <String, dynamic>{'divisionId': 'd1', 'label': '三角洲行动·手游', 'canTakeOrder': true},
            ]
          : <Map<String, dynamic>>[],
    );
  }

  Map<String, dynamic> convRow(String id, String type, {String? nickname}) => <String, dynamic>{
        'id': id,
        'type': type,
        'unread': 1,
        'lastSeq': 1,
        'status': 'open',
        'peer': nickname == null ? null : <String, dynamic>{'id': 'u1', 'nickname': nickname},
      };

  void serveConversations(List<Map<String, dynamic>> list) =>
      server.ok('GET /worker/cs/conversations', <String, dynamic>{'list': list, 'total': list.length});

  Map<String, dynamic> msgEvent({
    String conversationId = 'c1',
    String senderType = 'user',
    String content = '在吗，想约今晚八点',
    String msgType = 'text',
    bool recalled = false,
    String senderNickname = '小苏',
  }) =>
      <String, dynamic>{
        'msgId': 'm1',
        'seq': 3,
        'conversationId': conversationId,
        'senderType': senderType,
        'senderId': 'u1',
        'senderNickname': senderNickname,
        'msgType': msgType,
        'content': content,
        'recalled': recalled,
      };

  // ------------------------------------------------------- ① payload 解析不崩

  group('① payload 解析：什么形状都不许崩', () {
    test('order:new —— null / 字符串 / 空表 / 坏 JSON / JSON 字符串 都不抛，坏形状返回 null', () {
      expect(WorkerOrderEvent.parse(null), isNull);
      expect(WorkerOrderEvent.parse('not-json'), isNull);
      expect(WorkerOrderEvent.parse(<String, dynamic>{}), isNull);
      expect(WorkerOrderEvent.parse(<String, dynamic>{'orderId': ''}), isNull);
      expect(WorkerOrderEvent.parse('{bad json'), isNull);
      expect(WorkerOrderEvent.parse(<String, dynamic>{'orderId': 12345})?.orderId, '12345');
      // Socket.IO 正常给 Map；允许是 JSON 字符串（自建 relay / 回放）
      expect(WorkerOrderEvent.parse('{"orderId":"o9","status":"taken"}')?.status, 'taken');
      final e = WorkerOrderEvent.parse(<String, dynamic>{'orderId': 'o1'})!;
      expect(e.status, isNull);
    });

    test('msg:new —— 缺 conversationId / 类型怪异 都不抛', () {
      expect(WorkerMessageEvent.parse(null), isNull);
      expect(WorkerMessageEvent.parse(<dynamic>[]), isNull);
      expect(WorkerMessageEvent.parse(<String, dynamic>{'msgId': 'm1'}), isNull);
      final e = WorkerMessageEvent.parse('{"conversationId":88,"senderType":"user"}')!;
      expect(e.conversationId, '88');
      expect(e.msgType, 'text'); // 缺 msgType 时按 text（不猜成别的类型）
    });

    test('route —— 往返一致；坏 payload 一律 null（点通知不该让 App 崩）', () {
      const route = WorkerNoticeRoute(kind: WorkerNoticeKind.message, conversationId: 'c1');
      final decoded = WorkerNoticeRoute.decode(route.encode())!;
      expect(decoded.kind, WorkerNoticeKind.message);
      expect(decoded.conversationId, 'c1');
      expect(WorkerNoticeRoute.decode(null), isNull);
      expect(WorkerNoticeRoute.decode(''), isNull);
      expect(WorkerNoticeRoute.decode('{'), isNull);
      expect(WorkerNoticeRoute.decode('[1,2,3]'), isNull);
      expect(WorkerNoticeRoute.decode('{"k":"unknown"}'), isNull);
      expect(WorkerNoticeRoute.decode('{"k":"order"}')?.conversationId, '');
    });

    test('摘要口径：图片 / 撤回 / 非文字 / 超长截断（与消息页同源）', () {
      expect(WorkerMessageEvent.parse(msgEvent(msgType: 'image', content: ''))!.preview, '[图片]');
      expect(WorkerMessageEvent.parse(msgEvent(recalled: true))!.preview, '[消息已撤回]');
      expect(WorkerMessageEvent.parse(msgEvent(msgType: 'voice'))!.preview, '[新消息]');
      final long = WorkerMessageEvent.parse(msgEvent(content: '字' * 200))!.preview;
      expect(long.length, WorkerNoticeText.previewMax + 1); // 截断 + 省略号
      expect(long.endsWith('…'), isTrue);
      expect(WorkerMessageEvent.parse(msgEvent(content: '  换\n行  '))!.preview, '换 行');
    });
  });

  // ------------------------------------------------------------ ② 判定门

  group('② 判定门（打手态才发 / 在那一屏不发）', () {
    test('isWorkerMode：老板态 false；打手态 + 生效档案 true；档案停用 false；绑定未加载不拦', () {
      expect(WorkerNoticeGate.isWorkerMode(workerIdentity: false, bindingWorker: _binding().worker), isFalse);
      expect(WorkerNoticeGate.isWorkerMode(workerIdentity: true, bindingWorker: _binding().worker), isTrue);
      expect(
        WorkerNoticeGate.isWorkerMode(workerIdentity: true, bindingWorker: _binding(workerStatus: 0).worker),
        isFalse,
      );
      // 绑定状态还没拉回来（null）→ 不拦（身份本身已证明在打手态，别让功能时灵时不灵）
      expect(WorkerNoticeGate.isWorkerMode(workerIdentity: true, bindingWorker: null), isTrue);
    });

    test('新单：就在接单大厅那一屏 → 不发', () {
      expect(WorkerNoticeGate.shouldNotifyOrder(workerMode: true, hallVisible: false), isTrue);
      expect(WorkerNoticeGate.shouldNotifyOrder(workerMode: true, hallVisible: true), isFalse);
      expect(WorkerNoticeGate.shouldNotifyOrder(workerMode: false, hallVisible: false), isFalse);
    });

    test('order:new 被复用：只有真正的新单才算新单（被抢 / 取消 不算）', () {
      expect(WorkerNoticeGate.isNewOrderEvent(null), isTrue);
      expect(WorkerNoticeGate.isNewOrderEvent(''), isTrue);
      expect(WorkerNoticeGate.isNewOrderEvent('pending_take'), isTrue);
      expect(WorkerNoticeGate.isNewOrderEvent('taken'), isFalse);
      expect(WorkerNoticeGate.isNewOrderEvent('canceled'), isFalse);
    });

    test('消息：自己发的 / 系统消息 一律不弹给自己；正在看那条会话不弹', () {
      bool go(String senderType, String cid, String open) => WorkerNoticeGate.shouldNotifyMessage(
            workerMode: true,
            senderType: senderType,
            conversationId: cid,
            openConversationId: open,
          );
      expect(go('user', 'c1', ''), isTrue);
      expect(go('worker', 'c1', ''), isFalse); // 我方（自己 / 同侧客服）→ 房间会把我的消息推回来
      expect(go('system', 'c1', ''), isFalse);
      expect(go('user', 'c1', 'c1'), isFalse); // 正在看这条会话
      expect(go('user', 'c1', 'c2'), isTrue); // 看的是别的会话 → 照样提醒
      expect(go('user', '', ''), isFalse);
      expect(WorkerNoticeGate.shouldNotifyMessage(workerMode: false, senderType: 'user', conversationId: 'c1', openConversationId: ''), isFalse);
    });
  });

  // ------------------------------------------------------------ ③ 文案不编造

  group('③ 文案：只用服务端真的给了的字段', () {
    test('新单正文 = 分部 · 商品 · 金额 + 第二行单号（金额走 fmtMoney）', () {
      final body = WorkerNoticeText.orderBody(
        divisionLabel: '三角洲行动·手游',
        productName: '三局陪练',
        totalAmount: 38,
        orderNo: '20261015230001',
      );
      expect(body, '三角洲行动·手游 · 三局陪练 · ¥38.00\n单号 20261015230001');
    });

    test('拿不到的字段整段不写（不占位、不猜）；全空则返回空串 → 调用方据此不发', () {
      final noDivision = WorkerNoticeText.orderBody(
        divisionLabel: '',
        productName: '三局陪练',
        totalAmount: 5.5,
        orderNo: '',
      );
      expect(noDivision, '三局陪练 · ¥5.50');
      expect(noDivision.contains('null'), isFalse);
      final allEmpty = WorkerNoticeText.orderBody(
        divisionLabel: '',
        productName: '',
        totalAmount: 0,
        orderNo: '',
      );
      expect(allEmpty, isEmpty);
    });

    test('消息标题：客服会话固定「祁连山客服」；老板直聊用老板昵称，缺失才退回「老板」', () {
      expect(WorkerNoticeText.messageTitle(conversationType: 'cs', peerNickname: '小苏'), '祁连山客服');
      expect(WorkerNoticeText.messageTitle(conversationType: 'worker', peerNickname: '小苏'), '小苏');
      expect(WorkerNoticeText.messageTitle(conversationType: 'worker', peerNickname: ''), '老板');
    });

    test('通知 id：同一会话稳定复用（后到覆盖先到），不同会话不撞', () {
      final ids = WorkerNoticeIds();
      final a = ids.forConversation('c1');
      expect(ids.forConversation('c1'), a);
      final b = ids.forConversation('c2');
      expect(b, isNot(a));
      expect(a, isNot(WorkerNoticeIds.order));
      expect(WorkerNoticeIds.order, isNot(b));
    });
  });

  // ------------------------------------------------------- ④ 派发链路（端到端）

  group('④ 派发链路：打手态才发 + 拿真实信息', () {
    late _FakeNotifier notifier;
    late WorkerNotifyPresence presence;
    late WorkerNotifyService service;

    WorkerNotifyService build() => WorkerNotifyService(
          notifier: notifier,
          presence: presence,
          api: ApiClient(),
          realtime: RealtimeClient.shared,
        );

    setUp(() async {
      notifier = _FakeNotifier();
      presence = WorkerNotifyPresence();
      service = build();
      await service.start();
    });

    tearDown(() => service.stop());

    test('新单（不在大厅）→ 发 1 条：标题「有新订单」，正文含分部名/商品/金额/单号', () async {
      loginAsWorker();
      serveHall();
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      expect(notifier.shown.length, 1);
      final n = notifier.shown.single;
      expect(n.kind, WorkerNoticeKind.order);
      expect(n.title, '有新订单');
      expect(n.body, '三角洲行动·手游 · 三局陪练 · ¥38.00\n单号 20261015230001');
      expect(n.id, WorkerNoticeIds.order); // 新单固定 id：始终覆盖上一条
      expect(n.payload, WorkerNoticeRoute(kind: WorkerNoticeKind.order).encode());
    });

    test('就在接单大厅那一屏 → **不发**（列表自己在刷新，横幅只是盖住他正看的东西）', () async {
      loginAsWorker();
      serveHall();
      presence.hallVisible = true;
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      expect(notifier.shown, isEmpty);
      expect(server.calls('GET /worker/order-hall'), 0); // 连回源都不做
    });

    test('老板态 → **不发**（身份隔离：老板不该收到打手通知）', () async {
      loginAsBoss();
      serveHall();
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      await service.handleMessage(msgEvent());
      expect(notifier.shown, isEmpty);
      expect(server.calls('GET /worker/order-hall'), 0);
    });

    test('被抢（status=taken）/ 取消（status=canceled）→ 不算新单，不发', () async {
      loginAsWorker();
      serveHall();
      await service.handleOrder(<String, dynamic>{'orderId': 'o1', 'status': 'taken'});
      await service.handleOrder(<String, dynamic>{'orderId': 'o1', 'status': 'canceled'});
      expect(notifier.shown, isEmpty);
    });

    test('单子不在我的大厅里（无权限分部 / 已被抢）→ **不发**（宁可少一条，也不编一条）', () async {
      loginAsWorker();
      serveHall(orders: <Map<String, dynamic>>[hallOrder(id: 'other')]);
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      expect(notifier.shown, isEmpty);
    });

    test('大厅接口失败 → 不发（不拿缓存也不编）', () async {
      loginAsWorker();
      // 不注册任何路由 → 404
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      expect(notifier.shown, isEmpty);
    });

    test('客服消息（senderType=user，type=cs）→ 标题「祁连山客服」+ 正文摘要', () async {
      loginAsWorker();
      serveConversations(<Map<String, dynamic>>[convRow('c1', 'cs')]);
      await service.handleMessage(msgEvent());
      expect(notifier.shown.length, 1);
      expect(notifier.shown.single.title, '祁连山客服');
      expect(notifier.shown.single.body, '在吗，想约今晚八点');
      expect(notifier.shown.single.route.conversationId, 'c1');
    });

    test('老板直聊消息（type=worker）→ 标题是老板昵称（真的昵称，不是编的）', () async {
      loginAsWorker();
      serveConversations(<Map<String, dynamic>>[convRow('c9', 'worker', nickname: '小苏')]);
      await service.handleMessage(msgEvent(conversationId: 'c9'));
      expect(notifier.shown.single.title, '小苏');
    });

    test('我发的消息（senderType=worker）→ **不弹给自己**', () async {
      loginAsWorker();
      serveConversations(<Map<String, dynamic>>[convRow('c1', 'cs')]);
      await service.handleMessage(msgEvent(senderType: 'worker'));
      expect(notifier.shown, isEmpty);
      expect(server.calls('GET /worker/cs/conversations'), 0); // 一律早退，连会话都不查
    });

    test('正在看那条会话 → 不发；看的是别的会话 → 照发', () async {
      loginAsWorker();
      serveConversations(<Map<String, dynamic>>[convRow('c1', 'cs'), convRow('c2', 'cs')]);
      presence.openConversationId = 'c1';
      await service.handleMessage(msgEvent(conversationId: 'c1'));
      expect(notifier.shown, isEmpty);
      await service.handleMessage(msgEvent(conversationId: 'c2'));
      expect(notifier.shown.length, 1);
    });

    test('会话不在【客服 / 老板】两段里（好友 / 已结束）→ **不发**（不知道发送方是谁就别乱弹）', () async {
      loginAsWorker();
      serveConversations(<Map<String, dynamic>>[convRow('c1', 'friend', nickname: '阿哲')]);
      await service.handleMessage(msgEvent(conversationId: 'c1'));
      expect(notifier.shown, isEmpty);
    });

    test('stop() 之后一条都不发（退出打手态 = 立刻闭嘴）', () async {
      loginAsWorker();
      serveHall();
      service.stop();
      await service.handleOrder(<String, dynamic>{'orderId': 'o1'});
      expect(notifier.shown, isEmpty);
      expect(notifier.cancelAllCalls, 1); // 顺手清掉已经弹出去的打手通知
    });

    test('通知器抛异常不许影响 App（渠道被关 / 系统限流 / 插件异常）', () async {
      loginAsWorker();
      serveHall();
      final throwing = _ThrowingNotifier();
      final s = WorkerNotifyService(notifier: throwing, presence: presence, api: ApiClient());
      await s.start();
      await s.handleOrder(<String, dynamic>{'orderId': 'o1'}); // 不抛 = 通过
      expect(throwing.attempts, 1);
      s.stop();
    });
  });
}

class _ThrowingNotifier implements WorkerNotifier {
  int attempts = 0;

  @override
  Future<WorkerNoticeRoute?> init() async => null;

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(WorkerNotice notice) async {
    attempts++;
    throw StateError('渠道被用户关掉了');
  }

  @override
  Future<void> cancelAll() async {}
}
