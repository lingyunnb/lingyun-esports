import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/services/ai_recommend_service.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 找陪玩页 × 祁小山（负责人 2026-10-04：找陪玩也加 AI，两个都做）
///
/// 覆盖任务书验收第 3 条点名要测的三件事：
/// ① 「问祁小山」入口点击 → **push 既有 AI 会话页**（不是第二套 AI 页）
/// ② 推荐结果渲染 name/intro/reason，且**推荐卡本身**不含价格/评分/等级/标签/下单人数/在线状态
///    （2026-10-17 起列表卡允许这些字段，见下方口径重钉注释）
/// ③ AI 不可用/没挑出人时 → 降级到「直接展示找陪玩列表」（页面不空白）
void main() {
  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required _FakeRecommendSource rec,
    VoidCallback? onAskAi,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: PlayersPage(api: _api(), recommendSource: rec, onAskAi: onAskAi),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> ask(WidgetTester tester, String need) async {
    await tester.enterText(find.byKey(const Key('players-ai-need')), need);
    await tester.pump();
    await tester.tap(find.byKey(const Key('players-ai-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('①「有疑问？问祁小山」入口：样式合规（白底/发丝线/r10/祁山标 16）+ 点击 push 既有 AI 页', (tester) async {
    await pumpPage(tester, rec: _FakeRecommendSource());

    // 入口存在，文案与图标都对
    expect(find.byKey(const Key('players-ask-qishan')), findsOneWidget);
    expect(find.text(kAskQishanLabel), findsOneWidget);
    expect(find.byType(AppQishanMark), findsWidgets);
    final mark = tester.widget<AppQishanMark>(
      find.descendant(of: find.byKey(const Key('players-ask-qishan')), matching: find.byType(AppQishanMark)),
    );
    expect(mark.size, 16, reason: '任务书：AppQishanMark 16px');
    expect(find.byIcon(AppIcon.chevronRight), findsWidgets, reason: '右侧 chevron');

    // 一行引导的视觉硬参数：白底 + 1px 发丝线 + 圆角 10（不是第二个凸起按钮/悬浮球）
    final row = tester.widget<Container>(
      find.descendant(of: find.byKey(const Key('players-ask-qishan')), matching: find.byType(Container)).first,
    );
    final deco = row.decoration! as BoxDecoration;
    expect(deco.color, T.bgCardSolid);
    expect((deco.border! as Border).top.width, 1);
    expect((deco.border! as Border).top.color, T.divider);
    expect(deco.borderRadius, BorderRadius.circular(10));
    expect(deco.gradient, isNull, reason: '零渐变');
    expect(deco.boxShadow, isNull, reason: '阴影只给浮层');

    // 点击 → push 既有 AI 会话页（同一个 AiChatPage 类型，没有第二套实现）
    await tester.tap(find.byKey(const Key('players-ask-qishan')));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPage), findsOneWidget, reason: '必须复用既有 AI 会话页');
    expect(find.text('祁小山'), findsWidgets, reason: 'AI 页页头名字');
  });

  testWidgets('①b 有宿主回调时（HomeShell）：不 push，改成通知宿主切 AI 分支 + 自己退出', (tester) async {
    var asked = 0;
    // 模拟真实层级：找陪玩页是被 shell push 出来的一层路由（底栏在它下面）
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => PlayersPage(
                  api: _api(),
                  recommendSource: _FakeRecommendSource(),
                  onAskAi: () => asked++,
                ),
              )),
              child: const Text('进找陪玩'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('进找陪玩'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayersPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('players-ask-qishan')));
    await tester.pumpAndSettle();

    expect(asked, 1, reason: '通知宿主切到 AI 分支（AI 页在 shell 内 → 底栏常驻）');
    expect(find.byType(PlayersPage), findsNothing, reason: '找陪玩页自己退出（留在栈上会盖住底栏）');
    expect(find.byType(AiChatPage), findsNothing, reason: '这里不再 push AI 页 —— 由 shell 切分支');
  });

  testWidgets('② 推荐结果：渲染 reply + 名字/介绍/理由，且推荐卡不出现价格/评分/等级/标签/在线状态', (tester) async {
    final rec = _FakeRecommendSource(
      result: const AiRecommendResult(
        reply: '你说的"带我上分、话多"我记下了，挑了这个：',
        picks: [
          AiPick(
            workerId: '116',
            name: '祁小测·夜航',
            intro: '三角洲行动端游，主玩突击位，晚上 9 点以后有空，不接急单。',
            divisionName: '三角洲行动 · 端游',
            reason: '晚上 9 点后有空，节奏带得住新手',
          ),
          AiPick(
            workerId: '117',
            name: '祁小测·话筒',
            intro: '和平精英手游，话多能带节奏，新手局也接。',
            divisionName: '和平精英 · 手游',
            reason: '介绍里写着话多、接新手局',
          ),
        ],
      ),
    );
    await pumpPage(tester, rec: rec);
    await ask(tester, '想找个晚上 9 点后有空、能带我上分的，我新手');

    // 请求参数正确（需求原文 + 当前分部）
    expect(rec.calls.length, 1);
    expect(rec.calls.first['need'], '想找个晚上 9 点后有空、能带我上分的，我新手');
    expect(rec.calls.first['token'], 'test-token');

    // 祁小山 reply（v4 气泡）+ 两张推荐卡
    expect(find.byKey(const Key('players-ai-reply')), findsOneWidget);
    expect(find.text('你说的"带我上分、话多"我记下了，挑了这个：'), findsOneWidget);
    // 断言精确到卡片内部（同一名字在下面的"全部陪玩"列表里也会出现，避免 findsOneWidget 歧义）
    for (final entry in const {
      '116': ['祁小测·夜航', '三角洲行动端游，主玩突击位，晚上 9 点以后有空，不接急单。', '晚上 9 点后有空，节奏带得住新手'],
      '117': ['祁小测·话筒', '和平精英手游，话多能带节奏，新手局也接。', '介绍里写着话多、接新手局'],
    }.entries) {
      final card = find.byKey(Key('ai-pick-${entry.key}'));
      expect(card, findsOneWidget);
      for (final t in entry.value) {
        expect(find.descendant(of: card, matching: find.text(t)), findsOneWidget, reason: '推荐卡必须展示：$t');
      }
    }
    // 推荐卡里必须没有价格/评分/等级这类字段（服务端也没下发）
    expect(find.byKey(const Key('players-ai-reply')), findsOneWidget);

    /**
     * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
     *
     * 原断言把整页文本塞进一个正则，禁止出现
     * `¥|积分|评分|等级|星|大神|空闲|单价|下单人数|在线|标签` —— 依据是旧的结构规则 6。
     * 负责人当日新指令要求照参考图 1 重构列表卡（顶部「明星大神」入口卡、金额位 `¥--`、
     * 接单数 + 好评率都在卡里），这些词**必然出现在页面上**。
     * 于是把它拆成两条各自正确的断言，而不是放宽：
     * ① **推荐卡**仍然极简（祁小山给的是理由清单，不是第二份商品卡）→ 禁项原样保留；
     * ② **整页**仍然禁止的只有"假数据/旧单位"：钻石 · 积分 · 赔付 · 支付成功。
     */
    final pickText = <String>[
      for (final id in const ['116', '117'])
        ...tester
            .widgetList<Text>(find.descendant(of: find.byKey(Key('ai-pick-$id')), matching: find.byType(Text)))
            .map((t) => t.data ?? ''),
    ].join('\n');
    expect(pickText.contains('祁小测'), isTrue, reason: '推荐卡文本确实被采集到了（否则断言恒真）');
    final cardForbidden = RegExp(r'¥|￥|积分|评分|等级|星|Lv|VIP|大神|单考|双考|空闲|忙碌|单价|下单人数|在线|标签');
    expect(cardForbidden.hasMatch(pickText), isFalse,
        reason: '推荐卡不得出现价格/评分/等级/标签/下单人数/在线状态：'
            '${cardForbidden.allMatches(pickText).map((m) => m[0]).toList()}');
    // 反面校验：正则本身有效（否则"没命中"毫无意义）
    expect(cardForbidden.hasMatch('¥12 积分 Lv3 在线'), isTrue);

    // 整页：仍然不许出现"假数据 / 旧计价单位"
    final pageText = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').join('\n');
    final pageForbidden = RegExp(r'钻石|积分|赔付|支付成功');
    expect(pageForbidden.hasMatch(pageText), isFalse,
        reason: '全站只认 ¥/元，且不出现旧计价单位/合规红线词：'
            '${pageForbidden.allMatches(pageText).map((m) => m[0]).toList()}');
  });

  testWidgets('③ 兜底：AI 报错 → 只占一行提示 + 重试；列表照常展示（不白屏）', (tester) async {
    final rec = _FakeRecommendSource(
      error: const ApiException(429, '问得有点快，30 秒后再问', '', errorCode: 'AI_RATE_LIMITED'),
    );
    await pumpPage(tester, rec: rec);
    await ask(tester, '随便找个能带我打两局的');

    expect(find.byKey(const Key('players-ai-error')), findsOneWidget);
    expect(find.textContaining('30 秒后再问'), findsOneWidget, reason: '错误码 → 能直接看的中文');
    expect(find.byKey(const Key('players-ai-retry')), findsOneWidget);
    // 关键：AI 不可用时下面的陪玩列表必须还在
    expect(find.text('祁小测·夜航'), findsWidgets);
    expect(find.textContaining('三角洲行动端游，主玩突击位'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('③b 兜底：AI 没挑出人（picks 为空）→ 说明一句 + 全部陪玩列表仍在', (tester) async {
    final rec = _FakeRecommendSource(
      result: const AiRecommendResult(reply: '这几个都不太贴你的需求，我不硬凑。', picks: []),
    );
    await pumpPage(tester, rec: rec);
    await ask(tester, '要职业选手级别的');

    expect(find.text('这几个都不太贴你的需求，我不硬凑。'), findsOneWidget);
    expect(find.byKey(const Key('players-ai-none')), findsOneWidget);
    expect(find.byKey(const Key('ai-pick-116')), findsNothing);
    expect(find.text('祁小测·夜航'), findsWidgets, reason: '列表兜底：一个推荐都没有时也要能看到全部陪玩');
  });

  testWidgets('③c 降级：服务端 degraded=true → 一行灰字说明（不谎称 AI 精选）', (tester) async {
    final rec = _FakeRecommendSource(
      result: const AiRecommendResult(
        reply: '我这边反应慢了点，先按你说的从介绍里挑了：祁小测·夜航。',
        degraded: true,
        picks: [
          AiPick(
            workerId: '116',
            name: '祁小测·夜航',
            intro: '三角洲行动端游，主玩突击位，晚上 9 点以后有空，不接急单。',
            divisionName: '三角洲行动 · 端游',
            reason: '三角洲行动端游，主玩突击位，晚上 9 点以后有空…',
          ),
        ],
      ),
    );
    await pumpPage(tester, rec: rec);
    await ask(tester, '想找个晚上有空的');

    expect(find.byKey(const Key('players-ai-degraded')), findsOneWidget);
    expect(find.byKey(const Key('ai-pick-116')), findsOneWidget);
  });
}

/// 假推荐数据源（不需要后端）
class _FakeRecommendSource implements AiRecommendSource {
  _FakeRecommendSource({this.result, this.error});

  AiRecommendResult? result;
  ApiException? error;
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<AiRecommendResult> recommend(String token, {required String need, String? divisionId}) async {
    calls.add({'token': token, 'need': need, 'divisionId': divisionId});
    if (error != null) throw error!;
    return result ?? const AiRecommendResult(reply: '');
  }
}

/// 固定数据 ApiClient（分部 + 陪玩列表 + AI 会话页那两个接口 → 全程离线，不碰真后端）
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(const {
    '/divisions': {
      'code': 0,
      'message': 'ok',
      'data': [
        {'id': '3', 'name': '三角洲行动 · 端游'},
        {'id': '1', 'name': '和平精英 · 手游'},
      ],
    },
    '/public/players': {
      'code': 0,
      'message': 'ok',
      'data': {
        'list': [
          {
            'workerId': '116',
            'nickname': '祁小测·夜航',
            'intro': '三角洲行动端游，主玩突击位，晚上 9 点以后有空，不接急单。',
            'avatarMediaId': null,
            'divisionId': '3',
          },
          {
            'workerId': '117',
            'nickname': '祁小测·话筒',
            'intro': '和平精英手游，话多能带节奏，新手局也接。',
            'avatarMediaId': null,
            'divisionId': '1',
          },
        ],
        'total': 2,
        'page': 1,
        'pageSize': 50,
      },
    },
    '/user/ai/config': {
      'code': 0,
      'message': 'ok',
      'data': {
        'enabled': true,
        'presets': [
          {'label': '怎么下单', 'text': '怎么下单？'}
        ],
        'maxInputLength': 500,
        'greeting': '我是祁小山，有什么想问的？',
      },
    },
    '/user/ai/messages': {
      'code': 0,
      'message': 'ok',
      'data': {'list': [], 'hasMore': false},
    },
  });
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(
        jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
