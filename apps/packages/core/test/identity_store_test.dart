import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合并双端 · 身份切换（方案甲）—— **core 侧的身份隔离与双 token 槽**
///
/// 这里锁死的都是"出错就是数据安全事故"的点（设计稿风险 R1/R2/R3）：
/// - 双 token 槽：打手态必须用 companion，老板态必须用 primary（绝不串用）
/// - 缓存隔离：换身份必须清空旧身份缓存（否则 B 身份先看到 A 身份的数据）
/// - 伴随会话失效只丢打手身份，**绝不能把老板一起登出**
/// - 401 自动刷新按身份走不同通道（companion 走 /user/identity/refresh）
/// - 打手态干净度词表（22 词）与底部导航三项（结构常量）
void main() {
  late _FakeServer server;

  setUpAll(() {
    // 测试环境：不落安全存储（flutter_secure_storage 无平台实现）
    AuthStore.debugStorageDisabled = true;
    // 不建真 WS
    RealtimeClient.shared.debugDisabled = true;
    // 让 AuthStore 单例内部那个 `ApiClient()` 也走假通道（显式传 dio 的实例优先于它）
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://identity.local'));
  });

  setUp(() {
    server = _FakeServer();
    ApiClient.debugDefaultDio!.httpClientAdapter = server;
    server.reset();
    AuthStore.instance.debugClearIdentity();
    ApiCache.instance.endSession();
  });

  tearDown(() {
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  // =====================================================================================
  // 1. 双 token 槽
  // =====================================================================================

  group('双 token 槽与身份', () {
    test('老板态用 primary；打手态用 companion（两个槽互不覆盖）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      expect(AuthStore.instance.identity, AppIdentity.boss);
      expect(AuthStore.instance.workerIdentity, isFalse);
      expect(AuthStore.instance.activeToken, 'primary-token');

      AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker, companionToken: 'companion-token');
      expect(AuthStore.instance.workerIdentity, isTrue);
      expect(AuthStore.instance.activeToken, 'companion-token');
      // primary 槽**原封不动**：切回老板态立刻可用，不需要重新登录
      expect(AuthStore.instance.accessToken, 'primary-token');

      await AuthStore.instance.switchToBoss();
      expect(AuthStore.instance.identity, AppIdentity.boss);
      expect(AuthStore.instance.activeToken, 'primary-token');
      // 切回老板**不等于解绑**：companion 仍在本地（设计稿 A5「下次可免密切回」）
      expect(AuthStore.instance.companionToken, 'companion-token');
    });

    test('没有 companion 令牌时不会被当成打手态（身份标记与令牌必须同时成立）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker);
      expect(AuthStore.instance.workerIdentity, isFalse);
      expect(AuthStore.instance.activeToken, 'primary-token');
    });

    test('display 层 activeMe：老板态是老板资料，打手态是打手资料', () {
      final boss = AuthMe.fromJson(const {'id': '1', 'nickname': '阿远', 'role': 'user'});
      final worker = AuthMe.fromJson(const {
        'id': '2',
        'nickname': '王野',
        'role': 'worker',
        'worker': {'workerNo': 'W20260118'},
      });
      AuthStore.instance.debugSetSession(accessToken: 'p', me: boss);
      expect(AuthStore.instance.activeMe?.nickname, '阿远');

      AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'c',
        workerMe: worker,
      );
      expect(AuthStore.instance.activeMe?.nickname, '王野');
    });
  });

  // =====================================================================================
  // 2. 身份隔离（缓存 / WS / 未读）
  // =====================================================================================

  group('身份隔离：缓存按身份重开并清空', () {
    test('beginSession 的身份维度随身份切换，且切换即清空旧缓存', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      await AuthStore.instance.switchToBoss();
      expect(ApiCache.instance.sessionId, 'identity:boss');

      // 老板态塞一条缓存（模拟"老板已经看过订单列表"）
      ApiCache.instance.put(
        ApiCache.instance.keyOf('/user/orders', null, apiBase: 'http://identity.local'),
        const {'code': 0, 'data': const {'list': []}},
      );
      expect(ApiCache.instance.stats(), contains('cached=1'));

      AuthStore.instance.debugSetIdentity(identity: AppIdentity.boss, companionToken: 'companion-token');
      await AuthStore.instance.switchToWorker();
      expect(ApiCache.instance.sessionId, 'identity:worker');
      // 换身份必须清空：否则打手态会先命中老板态的列表（SWR 同步返回旧值 = 串号）
      expect(ApiCache.instance.stats(), contains('cached=0'));

      // 打手态塞一条，切回老板态必须同样被清掉（负责人：切回老板态必须彻底）
      ApiCache.instance.put(
        ApiCache.instance.keyOf('/worker/order-hall', null, apiBase: 'http://identity.local'),
        const {'code': 0, 'data': const {'list': []}},
      );
      expect(ApiCache.instance.stats(), contains('cached=1'));
      await AuthStore.instance.switchToBoss();
      expect(ApiCache.instance.sessionId, 'identity:boss');
      expect(ApiCache.instance.stats(), contains('cached=0'));
    });

    test('切身份会断开旧 WS（老板态的订阅随 socket 一起销毁）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      AuthStore.instance.debugSetIdentity(identity: AppIdentity.boss, companionToken: 'companion-token');
      await AuthStore.instance.switchToWorker();
      // debugDisabled=true 时不真连，但 disconnect() 仍会清掉单例持有的 socket 与令牌
      expect(RealtimeClient.shared.connected, isFalse);
      await AuthStore.instance.switchToBoss();
      expect(RealtimeClient.shared.connected, isFalse);
    });
  });

  // =====================================================================================
  // 3. 绑定 / 解绑（真实接口路径 + 令牌归属）
  // =====================================================================================

  group('绑定与解绑', () {
    test('bind 用 primary token 调 POST /user/identity/bind，成功后立即切到打手态', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      server.ok('POST /user/identity/bind', {
        'bindingId': '77',
        'rebound': false,
        'companionToken': 'companion-token',
        'companionRefreshToken': 'companion-refresh',
        'worker': {
          'workerNo': 'W20260118',
          'nickname': '王野',
          'canTakeOrder': true,
          'workerStatus': 1,
          'divisionPermissions': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
          ],
        },
      });
      server.ok('GET /auth/me', {
        'id': '2',
        'nickname': '王野',
        'role': 'worker',
        'worker': {'workerNo': 'W20260118'},
      });

      final result = await AuthStore.instance.bindWorkerIdentity(username: 'wangye_go', password: 'pw');

      expect(result.bindingId, '77');
      expect(AuthStore.instance.identity, AppIdentity.worker);
      expect(AuthStore.instance.workerIdentity, isTrue);
      expect(AuthStore.instance.activeToken, 'companion-token');
      // 老板 token 不变（服务端 bossTokenUnchanged）
      expect(AuthStore.instance.accessToken, 'primary-token');
      // 绑定请求带的是 primary（身份管理是老板侧能力）
      expect(server.bearerOf('POST /user/identity/bind'), 'primary-token');
      // 打手资料用 companion 拉（GET /auth/me 在伴随会话白名单内）
      expect(server.bearerOf('GET /auth/me'), 'companion-token');
      expect(AuthStore.instance.workerMe?.workerNo, 'W20260118');
      expect(AuthStore.instance.identityBusyLabel, isNull);
    });

    test('autoSwitch=false 只建绑定不发身份（"零分部权限"那条路径要靠它）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      server.ok('POST /user/identity/bind', {
        'bindingId': '78',
        'companionToken': 'companion-token',
        'companionRefreshToken': 'companion-refresh',
        'worker': {'workerNo': 'W9', 'nickname': '新人', 'divisionPermissions': []},
      });

      final r = await AuthStore.instance.bindWorkerIdentity(
        username: 'newbie',
        password: 'pw',
        autoSwitch: false,
      );

      expect(r.worker.takeOrderDivisions, isEmpty);
      expect(AuthStore.instance.identity, AppIdentity.boss); // 身份没动
      expect(AuthStore.instance.companionToken, 'companion-token'); // 令牌已存（仍可随后进入）
      expect(AuthStore.instance.identityStatus?.bound, isTrue);
    });

    test('bind 失败原样抛出服务端中文文案（页面只做分类、不改字）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      server.route['POST /user/identity/bind'] = _json(
        {'code': 403, 'message': '该账号不是打手账号，无法绑定', 'data': null},
        status: 403,
      );

      await expectLater(
        AuthStore.instance.bindWorkerIdentity(username: 'ayuan', password: 'pw'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', '该账号不是打手账号，无法绑定')),
      );
      expect(AuthStore.instance.identity, AppIdentity.boss);
    });

    test('unbind 用 primary 调 POST /user/identity/unbind，并彻底回到老板态', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'companion-token',
        status: _status(bound: true),
      );
      server.ok('POST /user/identity/unbind', {'ok': true, 'bindingId': '77', 'message': '已解绑，打手态登录已失效'});

      await AuthStore.instance.unbindWorkerIdentity();

      expect(server.bearerOf('POST /user/identity/unbind'), 'primary-token');
      expect(AuthStore.instance.companionToken, isNull);
      expect(AuthStore.instance.workerIdentity, isFalse);
      expect(AuthStore.instance.identity, AppIdentity.boss);
      expect(AuthStore.instance.identityStatus?.bound, isFalse);
      expect(ApiCache.instance.sessionId, 'identity:boss');
    });
  });

  // =====================================================================================
  // 4. 伴随会话失效：只丢打手身份
  // =====================================================================================

  group('伴随会话失效只丢打手身份', () {
    test('companion 401 后：打手身份清掉、老板会话分毫未动、也不弹"重新登录"', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token', me: AuthMe.fromJson(const {'id': '1'}));
      AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker, companionToken: 'companion-token');
      server.route['GET /worker/order-hall'] = _json(
        {'code': 401, 'message': '伴随身份已失效，请重新绑定打手账号', 'data': null},
        status: 401,
      );

      await expectLater(
        ApiClient().request('GET', '/worker/order-hall', token: 'companion-token'),
        throwsA(isA<ApiException>()),
      );
      // onUnauthorized 是同步派发的，等一轮微任务让它跑完
      await Future<void>.delayed(Duration.zero);

      expect(AuthStore.instance.workerIdentity, isFalse);
      expect(AuthStore.instance.companionToken, isNull);
      expect(AuthStore.instance.identity, AppIdentity.boss);
      // **关键**：老板态会话与"整机登录失效"标记都不受影响
      expect(AuthStore.instance.accessToken, 'primary-token');
      expect(AuthStore.instance.loggedIn, isTrue);
      expect(AuthStore.instance.authFailureMessage, isNull);
      // 打手态失效的原因留给 UI 展示（不是"重新登录"弹窗）
      expect(AuthStore.instance.identityNotice, '伴随身份已失效，请重新绑定打手账号');
      AuthStore.instance.clearIdentityNotice();
    });

    test('primary 401 不会误清打手身份（按"刚 401 的那个令牌"精确分派）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token', refreshToken: 'primary-refresh');
      AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'companion-token',
        companionRefreshToken: 'companion-refresh',
      );
      server.fail('GET /user/identity', code: 401, message: '登录已过期，请重新登录');
      server.ok('POST /auth/refresh', {'accessToken': 'primary-token-2', 'refreshToken': 'primary-refresh-2'});
      server.ok('GET /auth/me', {'id': '1', 'nickname': '阿远', 'role': 'user'});

      // 假服务器的这条路由固定回 401 -> 用新令牌重试一次仍然抛（这不是失败，是"刷新确实发生过"）
      await expectLater(
        ApiClient().request('GET', '/user/identity', token: 'primary-token'),
        throwsA(isA<ApiException>()),
      );

      expect(server.requests.any((r) => r.startsWith('POST /auth/refresh')), isTrue);
      // **关键**：老板侧的 401 绝不能去刷 companion，更不能把打手身份清掉
      expect(server.requests.any((r) => r.startsWith('POST /user/identity/refresh')), isFalse);
      expect(AuthStore.instance.companionToken, 'companion-token');
      expect(AuthStore.instance.identityNotice, isNull);
      expect(ApiClient.lastFailedToken, isNull);
    });
  });

  // =====================================================================================
  // 5. 401 自动刷新按身份分派
  // =====================================================================================

  group('令牌刷新按身份分派', () {
    test('打手态走 POST /user/identity/refresh，并且**不碰** /auth/refresh', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'companion-token',
        companionRefreshToken: 'companion-refresh',
      );
      server.ok('POST /user/identity/refresh', {
        'companionToken': 'companion-token-2',
        'companionRefreshToken': 'companion-refresh-2',
      });
      server.fail('POST /auth/refresh', code: 500, message: '不该被调用');

      final fresh = await AuthStore.instance.refreshAccessToken();

      expect(fresh, 'companion-token-2');
      expect(server.requests.any((r) => r.startsWith('POST /user/identity/refresh')), isTrue);
      expect(server.requests.any((r) => r.startsWith('POST /auth/refresh')), isFalse);
      expect(AuthStore.instance.activeToken, 'companion-token-2');
    });

    test('老板态仍走 POST /auth/refresh（历史行为）', () async {
      AuthStore.instance.debugSetSession(accessToken: 'primary-token');
      AuthStore.instance.debugSetIdentity(identity: AppIdentity.boss, companionToken: 'companion-token');
      // _refreshToken 为 null 时 _tryRefresh 会直接 _clear()，这里只为确认"没有走 companion 通道"
      await AuthStore.instance.refreshAccessToken();
      expect(server.requests.any((r) => r.startsWith('POST /user/identity/refresh')), isFalse);
    });
  });

  // =====================================================================================
  // 6. 协议形状与分类
  // =====================================================================================

  group('绑定状态解析（以后端实现为准，两种形状都吃）', () {
    test('后端形状：bindings[].worker', () {
      final s = IdentityBindingStatus.fromJson({
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': 1,
        'message': '已达绑定上限（最多 1 个）',
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'boundAt': '2026-10-06T12:00:00.000Z',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '王野',
              'workerStatus': 1,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'canTakeOrder': true},
                {'divisionId': '2', 'name': '建设中', 'canTakeOrder': false},
              ],
            },
          }
        ],
      });
      expect(s.bound, isTrue);
      expect(s.bindingId, '77');
      expect(s.worker?.workerNo, 'W20260118');
      expect(s.worker?.takeOrderDivisions.length, 1); // 只有 canTakeOrder 的才算
      expect(s.worker?.shortLabel, '王野 W20260118');
      expect(s.maxPerBoss, 1);
    });

    test('任务书形状：顶层 worker/bindingId 也能取到', () {
      final s = IdentityBindingStatus.fromJson({
        'bound': true,
        'bindingId': '88',
        'worker': {'workerNo': 'W1', 'nickname': '甲', 'canTakeOrder': true},
        'maxPerBoss': 3,
      });
      expect(s.bound, isTrue);
      expect(s.bindingId, '88');
      expect(s.worker?.workerNo, 'W1');
      expect(s.activeCount, 1);
    });

    test('未绑定：bound=false，且没有 worker 段', () {
      final s = IdentityBindingStatus.fromJson({'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': []});
      expect(s.bound, isFalse);
      expect(s.worker, isNull);
      expect(s.bindingId, '');
    });
  });

  group('错误态分类（只分类不改文案）', () {
    test('七种错误态各自归位', () {
      expect(classifyIdentityFailure(code: 400, message: '账号或密码错误'), IdentitySwitchFailure.credential);
      expect(classifyIdentityFailure(code: 400, message: '账号不存在或密码错误'), IdentitySwitchFailure.credential);
      expect(classifyIdentityFailure(code: 403, message: '该账号不是打手账号，无法绑定'), IdentitySwitchFailure.role);
      expect(
        classifyIdentityFailure(code: 403, message: '该账号已被封禁', errorCode: 'ACCOUNT_BANNED'),
        IdentitySwitchFailure.banned,
      );
      expect(classifyIdentityFailure(code: 400, message: '该打手账号已停用，无法绑定'), IdentitySwitchFailure.banned);
      expect(
        classifyIdentityFailure(code: 400, message: '该打手账号已被其他老板绑定，请先让对方解绑'),
        IdentitySwitchFailure.conflict,
      );
      expect(
        classifyIdentityFailure(code: 400, message: '绑定数量已达上限（当前上限 1 个）'),
        IdentitySwitchFailure.conflict,
      );
      expect(
        classifyIdentityFailure(code: 429, message: '绑定尝试过于频繁，请稍后再试', errorCode: 'RATE_LIMITED'),
        IdentitySwitchFailure.rateLimited,
      );
      expect(classifyIdentityFailure(code: -1, message: '网络连接失败，请检查网络'), IdentitySwitchFailure.other);
    });
  });

  // =====================================================================================
  // 7. 打手态干净度与结构常量
  // =====================================================================================

  group('打手态干净度与结构常量', () {
    test('黑名单为设计稿的 22 词（覆盖任务书点名的每一项）', () {
      expect(IdentityWorkerCleanliness.bossOnlyWords.length, 22);
      for (final w in ['下单', '找陪玩', '快速下单', '祁小山', '排行榜', '会员', 'VIP', '积分卡', '商品', '购物车']) {
        expect(IdentityWorkerCleanliness.bossOnlyWords, contains(w));
      }
    });

    test('violations 能命中"下单"这类词，干净文本返回空', () {
      expect(IdentityWorkerCleanliness.violations(['接单大厅', '抢单', '我的收益']), isEmpty);
      expect(IdentityWorkerCleanliness.violations(['接单大厅', '快速下单']), ['下单', '快速下单']);
    });

    test('底部导航恰好 3 项：接单 / 消息 / 我的', () {
      expect(IdentityWorkerMeta.navItemCount, 3);
      expect(IdentityWorkerMeta.navLabels, ['接单', '消息', '我的']);
      for (final banned in ['服务', '订单', '祁小山', '排行']) {
        expect(IdentityWorkerMeta.navLabels, isNot(contains(banned)));
      }
    });

    test('身份细带几何与文案（A+ 清单 ID-A / ID-B）', () {
      expect(AppIdentityBar.height, 28);
      expect(AppIdentityBar.background, const Color(0xFFEFF6FF)); // AppColors.primarySoft（2026-10-16 方案 F）
      expect(AppIdentityBar.border, const Color(0xFFE9EEF5)); // AppColors.divider（2026-10-16 方案 F）
      expect(AppIdentityBar.leadLabel, '当前身份');
      expect(AppIdentityBar.leadSize, 10.5);
      expect(AppIdentityBar.labelSize, 11.5);
      expect(AppIdentityBar.gap, 6);
      expect(AppIdentityBar.iconSize, 13);
      // 出现/消失 180ms（TR-B）
      expect(AppIdentityBar.enterDuration, const Duration(milliseconds: 180));
      expect(IdentityWorkerMeta.identityLabel(workerNo: 'W20260118'), '打手 · 工号 W20260118');
      expect(IdentityWorkerMeta.identityLabel(workerNo: '', nickname: '王野'), '打手 · 王野');
      expect(IdentityWorkerMeta.identityLabel(workerNo: ''), '打手');
    });

    test('打手态的身份标识**不得**出现「当前身份：老板」（正向断言的反面）', () {
      final label = AppIdentityBar.labelOf(workerNo: 'W20260118');
      final barText = '${AppIdentityBar.leadLabel}$label切回老板';
      expect(barText.contains(AppIdentityTag.bossLabel), isFalse);
      expect(barText.contains('当前身份：老板'), isFalse);
    });

    test('老板态中性身份标签：17dp / r4 / 10.5sp / 只读文案', () {
      expect(AppIdentityTag.bossLabel, '当前身份：老板');
      expect(AppIdentityTag.height, 17);
      expect(AppColors.tagNeutralBg, const Color(0xFFF1F4F8));
      expect(AppColors.tagNeutralBorder, const Color(0xFFCDD6E2));
    });

    test('切换过渡文案（TR-A：Toast 文案，不是通栏细带）', () {
      expect(IdentityTransition.toWorker, '已切换到打手身份');
      expect(IdentityTransition.toBoss, '已切换到老板身份');
      expect(IdentityTransition.unbound, '已解绑打手账号，已回到老板身份');
    });

    test('底栏高度参数：打手态与老板态同高（ID-F：切换不跳高）', () {
      expect(AppPlainBottomNav.defaultHeight, 60); // 默认值不动 → worker-app 视觉零变化
      expect(AppPlainBottomNav.identityHeight, AppPlainBottomNav.defaultHeight);
    });

    test('消息页两段文案与空态文案（MSG-A / MSG-B 逐字；2026-10-17 单页三分区后段名正名）', () {
      // 【2026-10-17 重钉】负责人定案「消息页去掉上方胶囊，改为单页三分区」：
      // 顺序固定 老板 → 官方客服 → 好友，且段名从「客服」正名为「官方客服」。
      // 旧断言是 ['老板', '客服'] —— 结构变了就重钉（不是放宽：段集合、顺序、段名都比原来更明确）。
      expect(IdentityWorkerMessagesPage.segments, ['老板', '官方客服']);
      expect(IdentityWorkerMessagesPage.friendSegment, '好友');
      expect(IdentityWorkerMessagesPage.emptyBossTitle, '还没有老板来找你');
      // 文案与 A+ 清单 MSG-B 的唯一差异：原文「下单的老板」命中了打手态 22 词黑名单，改为中性表述
      expect(IdentityWorkerMessagesPage.emptyBossDetail, '抢到第一单后，那位老板会自动出现在这里；抢单或派单成功时服务端会自动建会话');
      expect(IdentityWorkerMessagesPage.emptyCsTitle, '你还没有客服会话');
      // 2026-10-06 文案清理：「管理员单独授予」这类内部说法改成用户视角（由平台开通），语义不变
      expect(IdentityWorkerMessagesPage.emptyCsDetail, '客服权限由平台单独开通，与接单权限互相独立；开通后老板的咨询会出现在这里');
      // 单页三分区之后空段不再渲染 → 上屏的是**全页空态**这一组（三段都空时只给一次）
      expect(IdentityWorkerMessagesPage.emptyPageTitle, '还没有会话');
    });

    test('大厅相对时间文案（非整数、长短不一）', () {
      final now = DateTime(2026, 10, 6, 21, 0);
      String at(Duration ago) => now.subtract(ago).toIso8601String();
      expect(IdentityWorkerHallPage.relativeTime(at(const Duration(seconds: 20)), now: now), '刚刚');
      expect(IdentityWorkerHallPage.relativeTime(at(const Duration(minutes: 3)), now: now), '3 分钟前');
      expect(IdentityWorkerHallPage.relativeTime(at(const Duration(minutes: 26)), now: now), '26 分钟前');
      expect(IdentityWorkerHallPage.relativeTime(at(const Duration(hours: 1)), now: now), '1 小时前');
      expect(IdentityWorkerHallPage.relativeTime(at(const Duration(days: 1)), now: now), '昨天');
      expect(IdentityWorkerHallPage.relativeTime('不是时间', now: now), '');
    });
  });
}

// =========================================================================================
// 假服务器（按 "METHOD /path" 路由；记录顺序与 Authorization 头）
// =========================================================================================

/// 造一个响应（body + 状态码一起带上，避免"文案换了状态码忘了换"）
_Resp _json(Object body, {int status = 200}) => (body: jsonEncode(body), status: status);

/// 响应 = 正文 + 状态码
typedef _Resp = ({String body, int status});

IdentityBindingStatus _status({required bool bound}) => IdentityBindingStatus.fromJson({
      'bound': bound,
      'activeCount': bound ? 1 : 0,
      'maxPerBoss': 1,
      'bindings': bound
          ? [
              {
                'bindingId': '77',
                'status': 'active',
                'worker': {'workerNo': 'W20260118', 'nickname': '王野', 'workerStatus': 1},
              }
            ]
          : [],
    });

class _FakeServer implements HttpClientAdapter {
  final Map<String, _Resp> route = {};

  final List<String> requests = [];
  final Map<String, String?> _auth = {};

  void reset() {
    route.clear();
    requests.clear();
    _auth.clear();
  }

  /// 200 + JSON data
  void ok(String key, Object? data) => route[key] = _json({'code': 0, 'message': 'ok', 'data': data});

  /// 业务失败（HTTP 状态码 == body.code，与后端约定一致）
  void fail(String key, {required int code, required String message}) =>
      route[key] = _json({'code': code, 'message': message, 'data': null}, status: code);

  String? bearerOf(String key) => _auth[key];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.path}';
    requests.add(key);
    final auth = options.headers['Authorization'];
    _auth[key] = auth is String && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    final resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        },
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
