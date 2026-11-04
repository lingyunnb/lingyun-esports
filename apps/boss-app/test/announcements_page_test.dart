import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/announcements_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 公告列表页测试（2026-10-05 新增）
///
/// 背景：顶部「公告」此前进的是**系统通知**页，真公告只能从零 import 的死代码
/// `home_page.dart` 进入 → 管理端发的公告用户**永远看不到**。本组测试锁死修正后的契约：
/// 1. 数据源是 `GET /public/announcements`（列表，不含正文）
/// 2. 排序 = **置顶优先，其后时间倒序**
/// 3. 置顶项有可区分的标记（「置顶」文字），普通项没有
/// 4. 空态是中文「暂无公告」
/// 5. 失败给重试入口，不白屏
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 公开 GET 会真正进 ApiCache；各 case 共用同一 baseUrl，不清缓存会互相串 fixture
    ApiCache.instance.clear();
  });

  /// 刻意打乱顺序（服务端排序失守时的兜底验证）：
  /// 普通-较新(10-05) / 置顶-较旧(10-01) / 普通-较旧(09-28)
  final listResp = {
    'code': 0,
    'message': 'ok',
    'data': [
      {'id': '11', 'title': '十月五日维护通知', 'summary': '本次维护不停服', 'pinned': 0, 'createdAt': '2026-10-05T10:00:00.000Z'},
      {'id': '12', 'title': '国庆活动规则', 'summary': '活动期间下单享双倍时长', 'pinned': 1, 'createdAt': '2026-10-01T09:00:00.000Z'},
      {'id': '13', 'title': '三角洲新分部上线', 'summary': '端游与手游均已开放', 'pinned': 0, 'createdAt': '2026-09-28T08:00:00.000Z'},
    ],
  };

  testWidgets('公告列表：置顶优先 + 时间倒序，置顶项有标记', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(api: _api({'/public/announcements': listResp})),
    ));
    await tester.pumpAndSettle();

    // 三条都在
    expect(find.text('国庆活动规则'), findsOneWidget);
    expect(find.text('十月五日维护通知'), findsOneWidget);
    expect(find.text('三角洲新分部上线'), findsOneWidget);

    // 排序：置顶(12) → 普通里时间较新(11) → 普通里较早(13)
    final pinnedY = tester.getTopLeft(find.text('国庆活动规则')).dy;
    final newerY = tester.getTopLeft(find.text('十月五日维护通知')).dy;
    final olderY = tester.getTopLeft(find.text('三角洲新分部上线')).dy;
    expect(pinnedY, lessThan(newerY), reason: '置顶项必须排在最前（即使它发布时间更早）');
    expect(newerY, lessThan(olderY), reason: '普通项之间必须按时间倒序');

    // 置顶标记：只有置顶那条有「置顶」文字（克制：一条竖条 + 文字，不是彩色胶囊）
    expect(find.text('置顶'), findsOneWidget);

    // 摘要与时间：列表项按「标题 + 时间」展示；时间格式与详情页一致
    expect(find.textContaining('活动期间下单享双倍时长'), findsOneWidget);
    expect(find.textContaining('2026-10-01'), findsOneWidget);

    // 无 emoji / 无彩色胶囊堆砌（docs/21）：不出现这些常见 AI 味字符
    expect(find.textContaining('🔥'), findsNothing);
    expect(find.textContaining('✨'), findsNothing);
  });

  testWidgets('公告列表：点击进公告详情页（复用既有 AnnouncementDetailPage）', (tester) async {
    final detail = {
      'code': 0,
      'message': 'ok',
      'data': {
        'id': '12',
        'title': '国庆活动规则',
        'summary': '活动期间下单享双倍时长',
        'content': '一、活动时间 10-01 至 10-07。\n二、活动期间下单享双倍时长。',
        'pinned': 1,
        'createdAt': '2026-10-01T09:00:00.000Z',
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(
        api: _api({'/public/announcements': listResp, '/public/announcements/12': detail}),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('国庆活动规则'));
    await tester.pumpAndSettle();

    // 详情页标题与正文（正文只在详情接口返回，列表接口不含 content）
    expect(find.text('公告详情'), findsOneWidget);
    expect(find.textContaining('一、活动时间'), findsOneWidget);
  });

  /// 回归（2026-10-12 修）：**同一条公告在列表页与详情页必须显示同一个时间**。
  ///
  /// 真因：详情页 `_formatTime` 少了 `.toLocal()`，服务端下发的是 UTC（`...Z`），
  /// 于是东八区下详情页比列表页**早 8 小时**（列表页 `timeText` 一直有 toLocal）。
  /// 这条用例把"两页对得上"钉死：先取列表页渲染出的时间文本，再进详情页取，
  /// **两者必须逐字相等**（不是各自断言一个写死的字面量 —— 那样两个页面可以一起错）。
  testWidgets('公告列表 ↔ 详情：同一条公告的时间显示必须一致（UTC 必须转本地）', (tester) async {
    const iso = '2026-10-01T09:00:00.000Z';
    // 期望值由 Dart 自己算（不写死字面量）：UTC → 本地 → 格式化
    final expected = () {
      final t = DateTime.parse(iso).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    }();
    // 前置条件：本机时区确实会造成偏差，否则这条用例证明不了什么（CI 跑 UTC 时会退化）
    expect(DateTime.parse(iso).toLocal() == DateTime.parse(iso), isFalse,
        reason: '本机时区非 UTC 时本用例才有鉴别力');

    final detail = {
      'code': 0,
      'message': 'ok',
      'data': {
        'id': '12',
        'title': '国庆活动规则',
        'summary': '活动期间下单享双倍时长',
        'content': '正文',
        'pinned': 1,
        'createdAt': iso,
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(
        api: _api({'/public/announcements': listResp, '/public/announcements/12': detail}),
      ),
    ));
    await tester.pumpAndSettle();

    // ① 列表页显示的就是本地时间
    expect(find.text(expected), findsOneWidget,
        reason: '列表页时间必须是本地时间（$expected），实际渲染与期望不符');

    // ② 进详情页 —— 同一串必须还在（详情页少了 toLocal 时这里会变成早 8 小时的串）
    await tester.tap(find.text('国庆活动规则'));
    await tester.pumpAndSettle();
    expect(find.text('公告详情'), findsOneWidget);
    expect(find.text(expected), findsOneWidget,
        reason: '详情页时间必须与列表页逐字一致（详情页漏了 .toLocal() 会差一个时区）');
  });

  testWidgets('公告列表：无公告时显示中文空态「暂无公告」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(api: _api({'/public/announcements': {'code': 0, 'message': 'ok', 'data': []}})),
    ));
    await tester.pumpAndSettle();

    expect(find.text('暂无公告'), findsOneWidget);
  });

  testWidgets('公告列表：接口失败给重试入口而不是白屏', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(api: _api(const {})),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('公告加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
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
    // 长 key 优先：`/public/announcements/12` 必须先于 `/public/announcements` 命中
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
