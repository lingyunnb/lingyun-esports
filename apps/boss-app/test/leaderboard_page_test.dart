import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/leaderboard_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 排行榜页测试（复刻设计稿 I3 + 固化负责人硬规则）
///
/// 硬规则（CLAUDE.md 结构规则 6）：榜单每行**只有 名次 + 头像 + 名字 + 数值**，
/// **不得**出现分部副标与「明星陪玩 / 大神 / 单考 / 双考 / 空闲 / 忙碌」等标签。
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  setUp(() {
    // 【2026-10-04 性能专项】公开 GET（`/divisions`、`/public/leaderboard`）现在会真正进
    // ApiCache（修复前 `token != null` 的条件让公开接口从未被缓存）。
    // 本文件所有 case 共用 `baseUrl = http://fixture.local`，不清缓存会让
    // "空榜" case 命中上一个 case 的**非空榜**缓存，从而找不到空态文案。
    ApiCache.instance.clear();
  });

  final divisions = [
    {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'platformLabel': '手游'},
    {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'platformLabel': '手游'},
    {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'platformLabel': '端游'},
  ];

  final board = {
    'period': '2026-W40',
    'divisionId': null,
    'list': [
      {'rank': 1, 'nickname': '小云', 'workerNo': 'W001', 'completedOrders': 12, 'amount': 12480},
      {'rank': 2, 'nickname': '雪山', 'workerNo': 'W002', 'completedOrders': 9, 'amount': 9860},
      {'rank': 3, 'nickname': '兔神', 'workerNo': 'W003', 'completedOrders': 7, 'amount': 7240},
      {'rank': 4, 'nickname': '鸦鸦', 'workerNo': 'W004', 'completedOrders': 5, 'amount': 5930},
    ],
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
  });

  testWidgets('排行榜（方案 A）：页头副标题 + 周期分段 + 分部胶囊 + 实色名次徽章 + 金额', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardPage(api: _api({
        '/divisions': envelope(divisions),
        '/public/leaderboard': envelope(board),
      })),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 榜单名（方案 A：全页恰好 1 处 —— 只在页头标题；原静态胶囊与横幅内那两处已删）
    expect(find.text('接单榜'), findsOneWidget);
    // 周期：分段控件（AppSegmented，两段可点；与"分部筛选"是两类控件）
    expect(find.text('周榜'), findsOneWidget);
    expect(find.text('月榜'), findsOneWidget);
    // 分部胶囊（服务端驱动，含"仅手游"的和平精英与三角洲两平台）
    expect(find.text('和平精英 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 端游'), findsOneWidget);
    // 行内容：名次 + 名字 + 金额
    expect(find.text('小云'), findsOneWidget);
    expect(find.text('¥12,480.00'), findsOneWidget);
    expect(find.text('雪山'), findsOneWidget);
    // 吸底条（真实规则说明 + 去下单）
    expect(find.textContaining('每周一 03:00 重新统计'), findsOneWidget);
    expect(find.text('去下单 ›'), findsOneWidget);
  });

  testWidgets('排行榜硬规则：每行不出现分部副标与任何打手标签', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardPage(api: _api({
        '/divisions': envelope(divisions),
        '/public/leaderboard': envelope(board),
      })),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 分部名只允许出现在筛选胶囊里，不得作为"每行副标"重复出现
    // （和平精英 · 手游 出现在胶囊 = 1 次；若行内也写分部会出现 > 1 次）
    expect(find.text('和平精英 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 手游'), findsOneWidget);

    // 禁止词（硬规则）
    for (final banned in ['明星陪玩', '大神', '单考', '双考', '空闲', '忙碌', '评分', '单价']) {
      expect(find.textContaining(banned), findsNothing, reason: '榜单不得出现「$banned」');
    }
  });

  testWidgets('排行榜：空榜给出真实空态而非假数据', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardPage(api: _api({
        '/divisions': envelope(divisions),
        '/public/leaderboard': envelope({'period': '2026-W40', 'divisionId': null, 'list': const []}),
      })),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('还没有接单记录'), findsOneWidget);
  });

  // =====================================================================================
  // 方案 A（去横幅 · 信息归位）验收自检 —— 源码级，可变异验证
  //
  // 变异验证（2026-10-13 实测红/绿）：把 `gradient: T.brandGradient` 加回任意一处 →
  // 本用例立刻 FAIL（"本页必须 0 处渐变，实际 1 处"）；删掉 → 恢复绿。
  // =====================================================================================
  test('方案 A 自查：本页渐变数 0 · 「接单榜」恰好 1 处 · 阴影 0 · emoji 0', () {
    final src = File('${resolveRepoRoot()}/apps/boss-app/lib/pages/leaderboard_page.dart').readAsStringSync();
    // 剥掉注释再数：注释里允许写"为什么删"（历史沿革），但不许在代码里留下一处
    final code = _stripComments(src);

    // ① 渐变面积 = 0（docs/21 禁止清单第 1 条）：brandGradient / categoryGradient / LinearGradient 全部清零
    final gradients = RegExp(r'[Gg]radient').allMatches(code).length;
    expect(gradients, 0, reason: '本页必须 0 处渐变，实际 $gradients 处');

    // ② 阴影 = 0（docs/21：列表用发丝线，阴影只给弹层）
    final shadows = RegExp(r'[Ss]hadow').allMatches(code).length;
    expect(shadows, 0, reason: '本页必须 0 处阴影，实际 $shadows 处');

    // ③ 「接单榜」恰好 1 处（只在页头标题；原 :106 静态胶囊 + :135 横幅内榜名已随之删除）
    final names = '接单榜'.allMatches(code).length;
    expect(names, 1, reason: '「接单榜」全页只允许 1 处，实际 $names 处');

    // ④ emoji = 0（图标一律单色线性 AppIcon）
    final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true).allMatches(code).length;
    expect(emoji, 0, reason: '本页不得出现 emoji，实际 $emoji 个');

    // ⑤ 金额仍走统一出口（不自己拼 ¥ / 千分位），页面不得出现「积分」
    expect(code.contains('AppPrice(value: r.amount'), isTrue);
    expect(code.contains('积分'), isFalse);
  });
}

/// 剥掉行注释（`//`；不含 `://`）—— 与 `balance_display_test.dart` 同一份写法
String _stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    final m = RegExp(r'(^|\s)//').firstMatch(raw);
    if (m == null) {
      out.add(raw);
    } else {
      final cut = raw[m.start] == '/' ? m.start : m.start + 1;
      out.add(raw.substring(0, cut));
    }
  }
  return out.join('\n');
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
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
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}), 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
