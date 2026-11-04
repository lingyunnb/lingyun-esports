/// 客服大厅专项 · **老板侧**文案（2026-10-08）。
///
/// 背景：客服从"平台值班"改成"**有客服权限的打手在打手态主动接咨询**"（先到先得）。
/// 于是老板发起咨询之后，在有人点「接入」之前，**根本没有客服在线** ——
/// 原先那两句写死的文案就成了假事实：
///   - 「在线客服 · 平均 1 分钟回复」（会话页页头状态字）
///   - 「客服 9:00–次日 2:00 在线」（AI 转人工卡 / 退款页副标题 / 客服信息条次行）
///
/// 本文件钉住三件事：
///   ① **未接入态**（服务端没给 active 指派客服的工号）→「已提交，客服会尽快接入」，**不承诺时间**；
///   ② 已经接入 → 原来的在线文案照旧（不能把"有人接了"也说成"已提交"）；
///   ③ 客户端**不再兜底任何在线时段**（服务端配了才显示）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String kSubmitted = '已提交，客服会尽快接入';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);

  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final List<String> matches = raw.keys.where(options.path.startsWith).toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    final String key = matches.isEmpty ? '' : matches.first;
    final String body = key.isEmpty
        ? jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <dynamic>[]}})
        : jsonEncode(raw[key]);
    return ResponseBody.fromString(body, 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    // SWR 缓存是进程级单例：不清就会让"上一个用例的 info 响应"喂给下一个用例
    // （实测过 —— 第二个用例拿到的是第一个用例那份 `staffNo: ''`）
    ApiCache.instance.clear();
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    ApiCache.instance.clear();
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  ApiClient bossApi({required String staffNo, String status = 'open'}) {
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://cs-copy.local'))
      ..httpClientAdapter = _Adapter(<String, Map<String, dynamic>>{
        '/user/conversations/75/messages': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{'list': <dynamic>[], 'total': 0},
        },
        '/user/conversations/75/info': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{'id': '75', 'type': 'cs', 'status': status, 'staffNo': staffNo},
        },
      });
    return ApiClient(dio: dio);
  }

  Future<void> pumpChat(WidgetTester tester, {required String staffNo}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatDetailPage(
          conversationId: '75',
          title: '联系客服',
          csConversation: true,
          peerNickname: '祁连山客服',
          api: bossApi(staffNo: staffNo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 会话状态（info：status / staffNo）是 `_init` 里的**第二个**串行请求，
    // 多给一帧确保它落地后再断言页头状态字
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  // ==========================================================================
  // ⑭ 未接入态文案
  // ==========================================================================
  group('⑭ 老板侧未接入态 → 「$kSubmitted」（不承诺时间）', () {
    testWidgets('会话页页头状态字：没有 active 指派客服 → 新文案', (tester) async {
      await pumpChat(tester, staffNo: '');

      expect(find.text(kSubmitted), findsWidgets, reason: '尚无客服接入时的唯一正确说法');
      expect(find.text('在线客服 · 平均 1 分钟回复'), findsNothing, reason: '没有人接手就不是"在线客服"');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('**负向**：已经有人接入（服务端给了工号）→ 不许再说"已提交"', (tester) async {
      await pumpChat(tester, staffNo: 'W20260118');

      expect(find.text('在线客服 · 平均 1 分钟回复'), findsOneWidget);
      expect(find.text(kSubmitted), findsNothing, reason: '有人接了就不是"等待接入"了');
      await tester.pump(const Duration(milliseconds: 700));
    });

    test('文案常量只有一个出处（页面与信息条共用 ChatV4CsBar.submittedText）', () {
      expect(ChatV4CsBar.submittedText, kSubmitted);
    });

    testWidgets('**客服视角**（打手态 + 从大厅接入）：页头说的是「老板咨询」而不是"在线客服"', (tester) async {
      // 摆成打手态（companion 会话）——此时看这条 CS 会话的人就是接入的客服
      AuthStore.instance.debugSetIdentity(
        identity: AppIdentity.worker,
        companionToken: 'companion-token',
        workerMe: AuthMe.fromJson(<String, dynamic>{
          'id': 'w1',
          'nickname': '打手甲',
          'worker': <String, dynamic>{'workerNo': 'W20260118', 'canServeCustomer': true},
        }),
      );

      await pumpChat(tester, staffNo: 'W20260118');

      expect(find.text('老板咨询 · 已接入'), findsOneWidget, reason: '客服视角要说清"这是老板的咨询"');
      expect(find.text(kSubmitted), findsNothing, reason: '这句话是给老板看的，不该出现在客服眼前');
      expect(find.text('在线客服 · 平均 1 分钟回复'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 700));
      AuthStore.instance.debugClearIdentity();
    });
  });

  group('客服信息条（ChatV4CsBar）：未接入 / 已接入两态', () {
    Widget bar({String staffNo = '', String serviceHours = '', bool closed = false}) => MaterialApp(
          home: Scaffold(
            body: ChatV4CsBar(
              nickname: '祁连山客服',
              staffNo: staffNo,
              serviceHours: serviceHours,
              closed: closed,
            ),
          ),
        );

    testWidgets('未接入：状态字是短标「待接入」、次行是「已提交，客服会尽快接入」，且**没有任何时段**', (tester) async {
      await tester.pumpWidget(bar());
      expect(find.text('待接入'), findsOneWidget, reason: '状态字用短标，把长句让给次行（否则两行说同一句还被截断）');
      expect(find.text(kSubmitted), findsOneWidget);
      expect(find.textContaining('9:00'), findsNothing, reason: '不许再出现写死的在线时段');
      expect(find.textContaining('人工客服'), findsNothing, reason: '还没人接，不许声称有人工客服在线');
      expect(tester.takeException(), isNull);
    });

    testWidgets('已接入：状态字回到「在线 · 刚回过」，次行给真实工号（不编造）', (tester) async {
      await tester.pumpWidget(bar(staffNo: 'W20260118'));
      expect(find.text('在线 · 刚回过'), findsOneWidget);
      expect(find.text('工号 W20260118'), findsOneWidget, reason: '服务端没下发时段时不写时段，只写工号');
      expect(find.textContaining('9:00'), findsNothing);
    });

    testWidgets('已接入 + 服务端下发了时段 → **原样展示服务端配置**（客户端不改服务端口径）', (tester) async {
      await tester.pumpWidget(bar(staffNo: 'W20260118', serviceHours: '9:00–次日 2:00'));
      expect(find.text('9:00–次日 2:00 · 工号 W20260118'), findsOneWidget);
    });

    testWidgets('已结束：仍是「本次咨询已结束」（本次改动一行没碰）', (tester) async {
      await tester.pumpWidget(bar(staffNo: 'W20260118', closed: true));
      expect(find.text('本次咨询已结束'), findsOneWidget);
      expect(find.text('在线 · 刚回过'), findsNothing);
    });
  });

  group('AI 转人工卡的在线文案：服务端有才显示，没有就说"尽快接入"', () {
    test('serviceHours 兜底 = 空串（**不再兜底一个写死的时段**）', () {
      expect(kCsServiceHoursFallback, '');
      expect(const AiChatConfig().serviceHours, '');
      expect(AiChatConfig.fromJson(const <String, dynamic>{}).serviceHours, '');
      expect(AiChatConfig.fromJson(null).serviceHours, '');
    });

    test('服务端下发了 serviceHours / csServiceHours → 原样用', () {
      expect(AiChatConfig.fromJson(const <String, dynamic>{'serviceHours': '9:00–次日 2:00'}).serviceHours,
          '9:00–次日 2:00');
      expect(AiChatConfig.fromJson(const <String, dynamic>{'csServiceHours': '10:00–22:00'}).serviceHours,
          '10:00–22:00');
    });

    test('csAvailabilityLine：有/无时段两种说法，都不写死数字', () {
      expect(csAvailabilityLine(serviceHours: '', replyHint: '平均 5 分钟回复'), '客服会尽快接入 · 平均 5 分钟回复');
      expect(csAvailabilityLine(serviceHours: '9:00–次日 2:00', replyHint: '平均 5 分钟回复'),
          '客服 9:00–次日 2:00 在线 · 平均 5 分钟回复');
      expect(csAvailabilityLine(serviceHours: '', replyHint: ''), '客服会尽快接入');
    });

    test('csManualHandoffLine：同上', () {
      expect(csManualHandoffLine(serviceHours: ''), '订单和退款的事直接找人工，客服会尽快接入');
      expect(csManualHandoffLine(serviceHours: '9:00–次日 2:00'), '订单和退款的事直接找人工，客服 9:00–次日 2:00 在线');
      // 未配置时**绝不能**出现任何时刻
      expect(csManualHandoffLine(serviceHours: '').contains('9:00'), isFalse);
    });

    test('未开 AI 的那张卡引用的提示语也不再承诺时段', () {
      expect(kAiHandoffHint.contains('9:00'), isFalse);
      expect(kAiHandoffHint.contains('次日'), isFalse);
      expect(kAiHandoffHint, '答不上来的，我会给你接人工客服');
    });
  });
}
