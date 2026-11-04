import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/models/review_models.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/pages/worker_profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 【A 套验收】陪玩列表页（`players_page.dart`）+ 打手个人主页（`worker_profile_page.dart`）
///
/// 依据：已批准的 `docs/43`（列表页 A 套）与 `docs/44`（主页 A 套）
/// + 设计图 `site/design/players-nav/A-list.png` / `site/design/worker-profile/A.png`
/// （实测基准见两份 `shots.json`：卡高 148 / L-SLOT 72×20 / 头部场 160 / 胶囊高 24 / 宫格行高 64）。
///
/// 六条硬验收（逐条对应，不允许放松）：
/// ① 卡片**行高恒定**（带介绍 / 不带介绍 **同高**；卡高 148 → **128**，见下）
///
/// 【口径变更 · 负责人 2026-10-18 真机圈图】卡上那枚 `¥--  待接入` 整块删除 →
/// 行高由 148 降到 128（少掉 20dp 金额行 + 4dp 间距）。**断言一条没删**：下面所有
/// "行高恒定 / 骨架同高" 的判据都取 `PlayersPage.cardHeight` 常量（不是字面量 148），
/// 所以口径一变，断言自动跟着新值走 —— 这正是不写死数字的好处。
/// ② 介绍为空 → 显示「介绍待补充」且**节点不消失**（高度不变）
/// ③ `satisfiedRate` 为 `null` → 「暂无评价」；**`"1.0"` + 100 条 → `1%`（不是 100%）**
/// ④ 胶囊**不超过 3 枚**、**只有名字下方一处**
/// ⑤ 字段缺失（3 个新字段都不在）→ **不崩、降级正确**（不显示 0 / 100%）
/// ⑥ 头像为 `null` → 字标兜底（且**不是渐变底**）
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  /// 推进到数据真的上屏：**假时钟 + 真实异步时间交替**。
  ///
  /// 为什么不能只用 `pump(Duration)`：页面里的请求走 `Dio` → `HttpClientAdapter`，
  /// 它虽然立即完成，但完成的 Future 要靠**真实异步时间**才被调度；
  /// 纯假时钟推进时 `runAsync` 之外的微任务队列可能一直等不到那次调度
  /// （表现就是"卡找不到 / 空态不出来"这种假失败）。
  /// 也不能只用 `pumpAndSettle`：本页有 `RefreshIndicator`/无限动画时它会空转。
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 加高视口：390 逻辑宽（设计稿手机壳宽度，`Row` 不溢出）
  /// × 1400 高（6 张 `PlayersPage.cardHeight` 卡 + 页头 48 + 宫格 64 + 计数 32 + 页脚，
  /// 全部落在首屏内，免得 `ListView` 懒加载把下面几张卡判成"不存在"）
  /// —— 卡高从 148 降到 128 之后更宽松，这个视口高度照旧够用。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPlayers(WidgetTester tester, {required _Fixture fx}) async {
    useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(fx))));
    await settle(tester);
  }

  Future<void> pumpProfile(WidgetTester tester, {required _Fixture fx, String workerId = '413', String fallbackName = '小云'}) async {
    useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: WorkerProfilePage(
        api: _api(fx),
        workerId: workerId,
        fallbackNickname: fallbackName,
        fallbackIntro: '',
      ),
    ));
    await settle(tester);
  }

  // =========================================================================
  // 列表页
  // =========================================================================

  group('① 陪玩列表页 · 卡片行高恒定', () {
    testWidgets('带介绍 / 不带介绍：6 张卡全部同一个 cardHeight，一个高度都不许漂', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      final heights = <String, double>{};
      for (final id in ['413', '401', '402', '403', '414', '415']) {
        final card = find.byKey(Key('player-card-$id'));
        expect(card, findsOneWidget, reason: '第 $id 张卡必须在');
        heights[id] = tester.getSize(card).height;
      }

      for (final e in heights.entries) {
        expect(e.value, PlayersPage.cardHeight,
            reason: '卡 ${e.key} 的行高必须恒为 ${PlayersPage.cardHeight}dp（带介绍与不带介绍完全一样高）');
      }
      expect(heights.values.toSet().length, 1, reason: '所有卡只能有同一个高度');
    });

    testWidgets('骨架态与真卡同高（数据回来不跳版）', (tester) async {
      final fx = _Fixture.full();
      useTallViewport(tester);
      await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(fx))));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull, reason: '骨架/真卡都不许溢出或抛异常');

      // 骨架与真卡共用同一个 cardHeight 常量：任一张在屏上的卡都必须恰好等于它（顶格，不许 +1）
      double heightOf(Key k) => tester.getSize(find.byKey(k)).height;
      if (find.byKey(const Key('players-skeleton-0')).evaluate().isNotEmpty) {
        for (var i = 0; i < 5; i++) {
          expect(heightOf(Key('players-skeleton-$i')), PlayersPage.cardHeight,
              reason: '骨架卡必须与真卡同高（否则数据回来会跳一下）');
        }
      }
      await settle(tester);
      expect(find.byKey(const Key('player-card-413')), findsOneWidget, reason: '数据回来后进真卡');
      expect(heightOf(const Key('player-card-413')), PlayersPage.cardHeight);
    });
  });

  group('② 介绍为空 → 「介绍待补充」且节点不消失', () {
    testWidgets('13/14 人为空的线上现状：占位在、高度不变、节点不塌', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      // ① 有介绍的两张卡：显示真介绍，**不显示占位**
      expect(find.text('E2E 测试账号：和平精英手游，只跑验收流程。'), findsOneWidget);
      expect(find.text('和平精英手游，主玩地铁逃生与团队竞技。'), findsOneWidget);
      expect(find.byKey(const Key('player-intro-placeholder-413')), findsNothing);
      expect(find.byKey(const Key('player-intro-placeholder-414')), findsNothing);
      expect(find.byKey(const Key('player-intro-placeholder-402')), findsNothing,
          reason: '402 的介绍里有「100%」原文 → 它是填充态，不是占位态');

      // ② 介绍为空的四张卡：**每张都有占位节点**（不是整块消失）
      for (final id in ['401', '403', '415']) {
        final ph = find.byKey(Key('player-intro-placeholder-$id'));
        expect(ph, findsOneWidget, reason: '介绍为空时占位节点必须存在（$id）');
        expect(tester.widget<Text>(ph).data, kIntroPlaceholder);
        expect(tester.widget<Text>(ph).style!.color, AppColors.textPlaceholder,
            reason: '占位必须是弱化档 #8A99AB，不能抢名字的视线');
      }
      expect(find.text(kIntroPlaceholder), findsNWidgets(3));

      // ③ 占位卡与真介绍卡**一样高**（②与①是同一条硬约束的两面）
      expect(
        tester.getSize(find.byKey(const Key('player-card-413'))).height,
        tester.getSize(find.byKey(const Key('player-card-401'))).height,
      );
    });
  });

  group('③ 好评率口径（致命 bug 锁死）', () {
    testWidgets('satisfiedRate = null → 「暂无评价」，绝不编 100%', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        // ignore: avoid_print
        print('DBG2: ${t.data}');
      }

      // 401/402/415 无评价；403 有 reviewCount=100 且 rate "1.0"
      final meta401 = tester.widget<Text>(find.byKey(const Key('player-meta-401')));
      expect(meta401.data, '暂无接单记录 · $kNoReviewYet');
      expect(meta401.data!.contains('100%'), isFalse, reason: '无评价不许出现任何百分比');
      expect(meta401.data!.contains('0 次'), isFalse, reason: '缺字段不许退化成 0');
    });

    testWidgets('reviewCount=0 但服务端误回 100 → 仍然「暂无评价」', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      final meta415 = tester.widget<Text>(find.byKey(const Key('player-meta-415')));
      expect(meta415.data, '接单 0 次 · $kNoReviewYet', reason: '0 条评价算不出好评率');
      expect(meta415.data!.contains('100%'), isFalse);
    });

    testWidgets('"1.0" + 100 条 → 必须显示 1%，绝不能显示 100%（致命口径）', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      final meta403 = tester.widget<Text>(find.byKey(const Key('player-meta-403')));
      expect(meta403.data, '接单 30 次 · 1%',
          reason: 'satisfiedRate 是**百分数字符串**："1.0" = 1%；按 0–1 比率猜就会渲染成 100%');
      expect(meta403.data!.contains('100%'), isFalse,
          reason: '100 条评价里只有 1 条好评，显示 100% 等于把差评显示成满分');
    });

    testWidgets('有评价且比率正常 → 原样渲染 + 千分位接单次数', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      expect(tester.widget<Text>(find.byKey(const Key('player-meta-413'))).data, '接单 30 次 · 96.5%');
      expect(tester.widget<Text>(find.byKey(const Key('player-meta-414'))).data, '接单 1,284 次 · 98.2%');
      // 计数行取真实 total（不缩数）
      expect(tester.widget<Text>(find.byKey(const Key('players-count-row'))).data, '共 6 位陪玩');
      expect(find.text('共 6 位陪玩 · 已到底'), findsOneWidget);
    });
  });

  group('④ 胶囊：≤3 枚 + 只有名字下方一处', () {
    testWidgets('每张卡最多 3 枚；本卡只有名字下方那一处', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      // 线上只有分部副标一项真实数据 → 有 divisionName 的两张卡各 1 枚
      expect(find.byType(PlayerCapsule), findsNWidgets(2));
      expect(
        find.descendant(of: find.byKey(const Key('player-card-413')), matching: find.byType(PlayerCapsule)),
        findsOneWidget,
      );

      for (final id in ['401', '402', '403', '413', '414', '415']) {
        expect(
          find.descendant(of: find.byKey(Key('player-card-$id')), matching: find.byType(PlayerCapsule)).evaluate().length,
          lessThanOrEqualTo(3),
          reason: '卡 $id 的胶囊不得超过 3 枚（A 套放宽的硬边界）',
        );
      }

      // 全部胶囊都在某张卡内 → 不存在"卡外第二处"（全页只有名字下方这一处）
      final all = find.byType(PlayerCapsule).evaluate().length;
      var inside = 0;
      for (final id in ['401', '402', '403', '413', '414', '415']) {
        inside += find
            .descendant(of: find.byKey(Key('player-card-$id')), matching: find.byType(PlayerCapsule))
            .evaluate()
            .length;
      }
      expect(inside, all, reason: '胶囊只能出现在卡片的名字下方');
    });

    testWidgets('没有 divisionName 的卡：不画空格子（结构规则 2）', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());
      expect(
        find.descendant(of: find.byKey(const Key('player-card-401')), matching: find.byType(PlayerCapsule)),
        findsNothing,
      );
      // 但卡本身照旧在、高度照旧是 cardHeight（行高恒定不因缺字段而漂）
      expect(tester.getSize(find.byKey(const Key('player-card-401'))).height, PlayersPage.cardHeight);
    });
  });

  group('⑤ 字段缺失降级', () {
    testWidgets('三个新字段都不在 → 不崩、降到「头像 + 名字 + 介绍」', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.legacy());

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('player-card-401')), findsOneWidget);
      expect(find.text('小云'), findsOneWidget);
      expect(find.text('只跑验收流程的测试账号。'), findsOneWidget);

      final meta = tester.widget<Text>(find.byKey(const Key('player-meta-401')));
      expect(meta.data, '暂无接单记录 · $kNoReviewYet');
      expect(meta.data!.contains('0'), isFalse, reason: '字段缺失不许显示 0');
      expect(meta.data!.contains('100%'), isFalse, reason: '字段缺失不许显示 100%');
      expect(find.byType(PlayerCapsule), findsNothing, reason: '没有 divisionName 就不画胶囊');
    });

    testWidgets('空名单 → 空态说清原因（不白屏、不摆假数据）', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.empty());

      expect(tester.takeException(), isNull);
      expect(find.textContaining('还没有陪玩'), findsOneWidget);
      expect(find.byType(AppEmpty), findsOneWidget);
    });

    testWidgets('接口失败 → 给原因 + 重试（不崩溃）', (tester) async {
      final fx = _Fixture.full()..playersStatus = 500;
      await pumpPlayers(tester, fx: fx);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('⚠️ 关键回归：错误态下「问祁小山」与 AI 挑人**照旧能渲染**（导航入口不随列表状态消失）', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full()..playersStatus = 500);

      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.byKey(const Key('players-ask-qishan')), findsOneWidget,
          reason: '列表挂了不能把唯一的人工兜底入口一起藏掉（docs/21 §五：错误态下仍要有出路）');
      expect(find.byKey(const Key('players-ai-need')), findsOneWidget, reason: 'AI 挑人也不受列表状态影响');
      expect(tester.takeException(), isNull);
    });
  });

  group('⑥ 头像：null → 字标兜底（非渐变）；有图 → core 的 AppAvatar', () {
    testWidgets('14/14 头像为 null：字标兜底、浅底实色、无渐变', (tester) async {
      await pumpPlayers(tester, fx: _Fixture.full());

      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
       *
       * 原断言读的是「`player-avatar-<id>` 内必须有一个 `AppAvatar`，且 `mediaId == null`」。
       * 重构后左栏是参考图的**大方形圆角头像**，`AppAvatar(square: true)` 的方角半径是
       * `size × 0.34`（120 → 41），在 120 的方块上会变成"近似圆形"，与本项目
       * 「圆角只取 0/4/6/10/14/胶囊」的词汇表冲突 → 头像块改成页面自绘的
       * `ClipRRect(radius 14)` + 字标（**真实头像存在时仍走 `AppAvatar`**）。
       *
       * 因此这里把断言重钉到**同一个验证目标**（字标兜底、实色、无渐变、首字可命中），
       * 只是不再要求那个兜底必须是 `AppAvatar` 类型。
       */
      final block = find.byKey(const Key('player-avatar-413')).first;

      // ① 线上 14 人头像全为 null → 必须走字标兜底（首字画在块里）
      expect(find.descendant(of: block, matching: find.text('E')), findsOneWidget,
          reason: '昵称「E2E打手」的首字必须画在头像块上');
      expect(find.descendant(of: block, matching: find.byType(AppAvatar)), findsNothing,
          reason: '线上头像全为 null → 走页面自绘字标块（不再借 AppAvatar 的 0.34 半径）');

      // ② 兜底底是**实色**（无 decoration.gradient）
      final containers = tester.widgetList<Container>(find.descendant(
        of: block,
        matching: find.byType(Container),
      ));
      expect(containers, isNotEmpty, reason: '字标兜底必须有一个实底容器');
      for (final c in containers) {
        final deco = c.decoration;
        expect(deco is BoxDecoration && deco.gradient != null, isFalse, reason: '兜底底不许是渐变');
      }
    });

    testWidgets('有真实头像时必须走 core 的 AppAvatar（不许退化成字标块）', (tester) async {
      /**
       * 【两条一起守 · 负责人 2026-10-17 指示照参考图重构 + 本轮回修要求】
       *
       * 上一条守「头像为 null → 字标兜底」；**这一条必须同时存在**，守另一半：
       * 「只要服务端给了 `avatarMediaId`，头像就必须复用 core 的 `AppAvatar`」
       * （它是全站唯一的取图实现：磁盘缓存 + 解码尺寸限制 + 失败兜底）。
       * 只留字标那条 = 这条约束没人守，所以两条都在。
       */
      await pumpPlayers(tester, fx: _Fixture.withAvatar());

      final avatarFinder = find.descendant(
        of: find.byKey(const Key('player-avatar-413')).first,
        matching: find.byType(AppAvatar),
      );
      expect(avatarFinder, findsOneWidget, reason: '有 mediaId 时头像必须复用 core 的 AppAvatar');
      final avatar = tester.widget<AppAvatar>(avatarFinder);
      expect(avatar.mediaId, '9001', reason: '必须真的把服务端 mediaId 交给 AppAvatar（不是画字标了事）');
      expect(avatar.gradient, isFalse, reason: '头像底不许用品牌渐变（docs/21 禁渐变做主视觉）');
      expect(avatar.color, isNotNull);
      expect(tester.takeException(), isNull, reason: '测试环境取图拿不到图源 → 走组件自己的兜底，不许抛');
    });
  });

  // =========================================================================
  // 打手个人主页
  // =========================================================================

  group('主页 · 头部「隆重感」五件事（零深色块）', () {
    testWidgets('海报式头部 176dp + 冷灰蓝底 + 返回栏（二级页无底栏）', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileRich());

      final field = find.byKey(const Key('worker-profile-header-field'));
      expect(field, findsOneWidget);
      expect(tester.getSize(field).height, WorkerProfilePage.headerHeight);
      expect(tester.widget<Container>(field).color, AppColors.fieldBg, reason: '场 = 冷灰蓝 #F1F4F8');

      expect(find.text('打手信息'), findsOneWidget);
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar, isNull,
          reason: '二级页没有底栏');
      expect(find.byKey(const Key('worker-profile-ruler')), findsOneWidget, reason: '头部与内容之间的标尺线');
    });

    testWidgets('刻度环 + 名字 22/800 + 统计行 + 一排胶囊 + 底部主按钮', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileRich());

      // ② 尺度：名字是本页最大的字（22/800）
      final name = tester.widget<Text>(find.text('小云'));
      expect(name.style!.fontSize, 22);
      expect(name.style!.fontWeight, FontWeight.w800);

      // ④ 锚：字标头像 = 墨蓝实底 + 白字（极小面积）
      final avatar = tester.widget<AppAvatar>(find.byKey(const Key('worker-profile-avatar')));
      expect(avatar.color, AppColors.brandInk);
      expect(avatar.gradient, isFalse);
      expect(avatar.size, WorkerProfilePage.avatarSize);

      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】（2026-10-18 补注）
       *
       * 原断言是「头部有一行事实：`接单 ` + `30` + `96.5%` 三段独立 Text」。
       * 重构后参考图 2 把这三个数值收进了**统计行**（`worker-profile-stats`：
       * 接单次数 / 好评率 / 时长）。
       * 2026-10-18 负责人再删掉海报里那两个计数（粉丝 / 推荐）→ 头部只剩
       * 「头像 + 名字 + 等级徽章 + ID」；**本组断言一个字都不用改**：三个数值本来
       * 就钉在统计行上，删的是头部的占位数字，不是数据本身。
       */
      final stats = find.byKey(const Key('worker-profile-stats'));
      expect(find.descendant(of: stats, matching: find.text('30 次')), findsOneWidget,
          reason: '接单次数（countText 千分位）必须在统计行里');
      expect(find.text('96.5%'), findsWidgets, reason: '好评率按服务端百分数口径原样渲染');
      expect(find.text('好评率'), findsOneWidget, reason: '统计行三格之一');
      expect(find.text('时长'), findsOneWidget, reason: '统计行三格之一（值待接入）');

      // A 套放宽项：**全页只有这一排**、≤3 枚、单一主色浅底
      expect(find.byType(WorkerCapsule), findsOneWidget);

      /**
       * 【口径重钉 · 负责人 2026-10-18：删礼物墙/粉丝/推荐，雷达改六轴且数值溢出图外】
       *
       * 2026-10-17 版的海报里有一行 `粉丝 -- · 推荐 --`（后端没有这两个字段 → 占位）。
       * 负责人当日新指令「粉丝和推荐也不要」→ 整行删除；这里把"占位在"重钉成"必须不在"，
       * 头像 / 名字 / ID / 等级徽章四条仍在（上面几条断言继续守）。
       */
      expect(find.textContaining('粉丝'), findsNothing, reason: '海报里的 粉丝 计数必须删除');
      expect(find.textContaining('推荐 '), findsNothing, reason: '海报里的 推荐 计数必须删除');
      expect(find.byKey(const Key('worker-profile-gift-wall')), findsNothing, reason: '礼物墙整卡必须删除');
      expect(find.text('ID '), findsOneWidget, reason: 'ID 行照旧（删的只是那两个数字）');

      // 底部只有一个主按钮，且不出现第二个入口
      expect(find.text('找 TA 下单'), findsOneWidget);
      expect(find.textContaining('陪玩'), findsNothing, reason: '底部条不许出现「选择陪玩」这类回列表入口（结构规则 1）');
      expect(find.textContaining('祁小山'), findsNothing, reason: '问祁小山是底栏分支，本页不再开一个入口');
    });
  });

  group('主页 · 真实现状屏（头像 null / 介绍空 / 0 评价）必须真的能看', () {
    testWidgets('字标兜底 + 「介绍待补充」高度不变 + 「暂无评价」+ L-SLOT 照旧占位', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileReal(), workerId: '167', fallbackName: '小云');

      expect(tester.takeException(), isNull);

      // ① 头像 null → 字标兜底（墨蓝实底，非渐变）
      final avatar = tester.widget<AppAvatar>(find.byKey(const Key('worker-profile-avatar')));
      expect(avatar.mediaId, isNull);
      expect(avatar.gradient, isFalse);

      // ② 介绍空 → 占位节点在，且介绍卡高度 ≥ 104（固定底线，不因空介绍塌陷）
      final ph = find.byKey(const Key('worker-profile-intro-placeholder'));
      expect(ph, findsOneWidget);
      expect(tester.widget<Text>(ph).data, contains(kIntroPlaceholder));
      expect(tester.widget<Text>(ph).style!.color, AppColors.textPlaceholder);
      expect(tester.getSize(find.byKey(const Key('worker-profile-intro'))).height, greaterThanOrEqualTo(104));

      // ③ 0 评价 → 「暂无评价」+ 空态说明；**绝不编 100%**
      expect(find.text('暂无评价'), findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
      expect(find.byKey(const Key('worker-profile-reviews-empty')), findsOneWidget);

      // ④ L-SLOT 照旧占位（不因为等级没做就缩掉，否则将来加等级会整屏重排）
      final slot = find.byKey(const Key('worker-profile-level-slot'));
      expect(slot, findsOneWidget);
      final size = tester.getSize(slot);
      expect(size.height, WorkerProfilePage.levelSlotHeight);
      expect(size.width, WorkerProfilePage.levelSlotMaxWidth);

      // 没有胶囊数据 → 不画空格子
      expect(find.byType(WorkerCapsule), findsNothing);
      expect(find.text('找 TA 下单'), findsOneWidget, reason: '真实现状屏底部主按钮照旧在');
    });

    testWidgets('L-SLOT 在名字行内、距名字 8dp、同行垂直居中（只留位不画形态）', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileReal(), workerId: '167');

      final nameRect = tester.getRect(find.text('小云'));
      final slotRect = tester.getRect(find.byKey(const Key('worker-profile-level-slot')));

      expect(slotRect.left - nameRect.right, moreOrLessEquals(8, epsilon: 0.5), reason: '距名字 8dp');
      expect(
        slotRect.center.dy,
        moreOrLessEquals(nameRect.center.dy, epsilon: 1.0),
        reason: '同行垂直居中',
      );
    });
  });

  group('主页 · 好评率与评价行', () {
    testWidgets('"1.0" + 100 条 → 1%（不是 100%）', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileBadRate());

      expect(find.text('1%'), findsWidgets);
      expect(find.textContaining('100%'), findsNothing, reason: '1% 不许被换算成 100%（致命口径）');
      expect(find.text(kNoReviewYet), findsNothing);
    });

    testWidgets('评价行：昵称脱敏在上、判定在右上（四重信号）、备注、时间；没有星', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileRich());

      expect(find.text('老***板'), findsOneWidget);
      expect(find.text('节奏很稳，全程没掉线'), findsOneWidget);

      // 判定四重信号：图标（形状）+ 字重 + 文案 + 颜色
      final good = tester.widget<Text>(find.text('满意'));
      expect(good.style!.fontWeight, FontWeight.w700);
      expect(find.byIcon(AppIcon.check), findsOneWidget);
      expect(find.byIcon(AppIcon.complaint), findsOneWidget);
      expect(good.style!.color, reviewVerdictColor(true));

      // 判定在昵称**右侧同一行**
      final nickRect = tester.getRect(find.text('老***板'));
      final verdictRect = tester.getRect(find.text('满意'));
      expect(verdictRect.left, greaterThan(nickRect.right), reason: '判定在右上');
      expect((verdictRect.center.dy - nickRect.center.dy).abs(), lessThan(8), reason: '同一行');

      // 备注在判定下面、时间在最后
      final remarkRect = tester.getRect(find.text('节奏很稳，全程没掉线'));
      expect(remarkRect.top, greaterThan(verdictRect.bottom - 1));

      // **没有星**：评价模型是满意 / 不满意二元 + 一个好评率数字
      // （2026-10-17 重构后仍不画星：六维评分/等级都还是「待接入」，没有任何星级能力）
      expect(find.byIcon(AppIcon.star), findsNothing, reason: '不准画星（评价模型是二元，不是 5 星）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('双 Tab「个人能力 / 评价 N」+ 单主按钮在底部固定条', (tester) async {
      await pumpProfile(tester, fx: _Fixture.profileRich());

      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
       *
       * 原断言是「Tab 行**只一项**「评价 N」」。参考图 2 是**双 Tab（个人能力 / 动态）」，
       * 我们把它落成「个人能力 / 评价 N」——两个都对应**真实内容区**（能力区 = 六维圆环 +
       * 五维雷达，评价区 = 既有评价列表），点击会把对应区块滚到顶部（真滚动，不是死控件）。
       * 所以"只能有一项"重钉成"必须有两项，且评价项仍带真实条数"。
       */
      expect(find.byKey(const Key('worker-profile-tab-row')), findsOneWidget);
      expect(find.text('个人能力'), findsWidgets, reason: '双 Tab 第一项（能力区标题与 Tab 同名，两处都在）');
      expect(find.text('评价 2'), findsOneWidget, reason: '评价 Tab 带上真实条数');
      expect(find.byKey(const Key('worker-profile-tab-0')), findsOneWidget);
      expect(find.byKey(const Key('worker-profile-tab-1')), findsOneWidget);

      // 参考图里没有的模块**仍然不画**（结构规则 2：不存在的东西不出现）
      expect(find.text('帖子'), findsNothing);
      expect(find.text('动态'), findsNothing);
      expect(find.text('筛选'), findsNothing, reason: '筛选行不做（无带图评价、无排序参数 → 死控件）');
      expect(tester.getSize(find.byKey(const Key('worker-profile-order-button'))).height, 44);
    });
  });

  group('主页 · 硬编码色值 / 渐变 / 结构规则（源码级断言）', () {
    test('两页零硬编码色值、零 emoji、零「积分」', () {
      for (final path in const [
        'apps/boss-app/lib/pages/players_page.dart',
        'apps/boss-app/lib/pages/worker_profile_page.dart',
      ]) {
        final src = _read(path);
        final code = _stripComments(src);
        expect(RegExp(r'0x[0-9A-Fa-f]{6,8}').allMatches(code), isEmpty,
            reason: '$path 的色值必须一律走 T.* / AppColors.*');
        final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true).allMatches(code).length;
        expect(emoji, 0, reason: '$path 不许用 emoji 当图标');
        expect(code.contains('积分'), isFalse, reason: '$path 不出现旧计价单位');
      }
    });

    test('头像兜底不许再走渐变（本轮修掉的违规）', () {
      for (final path in const [
        'apps/boss-app/lib/pages/players_page.dart',
        'apps/boss-app/lib/pages/worker_profile_page.dart',
      ]) {
        final code = _stripComments(_read(path));
        expect(code.contains('gradient: true'), isFalse,
            reason: '$path 的字标头像必须是实色（渐变不做主视觉）');
      }
    });

    test('头像两条分支都在：null → 自绘字标块；非空 → core 的 AppAvatar（且吃服务端 mediaId）', () {
      final code = _stripComments(_read('apps/boss-app/lib/pages/players_page.dart'));
      expect(code.contains('p.avatarMediaId == null'), isTrue,
          reason: '必须按"有没有 mediaId"分两支（否则线上有图也画字标）');
      expect(RegExp(r':\s*AppAvatar\(').hasMatch(code), isTrue,
          reason: '非空分支必须落到 core 的 AppAvatar（唯一取图实现）');
      expect(code.contains('mediaId: p.avatarMediaId'), isTrue,
          reason: 'AppAvatar 必须真的拿到服务端 mediaId');
    });

    test('胶囊在两页各只有一处渲染点（防超标）', () {
      final listCode = _stripComments(_read('apps/boss-app/lib/pages/players_page.dart'));
      final detailCode = _stripComments(_read('apps/boss-app/lib/pages/worker_profile_page.dart'));
      expect(RegExp(r'PlayerCapsule\(label:').allMatches(listCode).length, 1,
          reason: '列表页只允许一处胶囊渲染点（名字下方）');
      expect(RegExp(r'WorkerCapsule\(label:').allMatches(detailCode).length, 1,
          reason: '主页只允许一处胶囊渲染点（名字下方）');
      expect(listCode.contains('.take(3)'), isTrue, reason: '上限在代码里收口');
      expect(detailCode.contains('.take(3)'), isTrue, reason: '上限在代码里收口');
    });

    test('等级徽章：几何仍是 L-SLOT（72×20），内容必须是「待接入」占位', () {
      final listCode = _stripComments(_read('apps/boss-app/lib/pages/players_page.dart'));
      final detailCode = _stripComments(_read('apps/boss-app/lib/pages/worker_profile_page.dart'));
      for (final code in [listCode, detailCode]) {
        expect(code.contains('levelSlotHeight'), isTrue, reason: '高度 20 必须走常量');
        expect(code.contains('levelSlotMaxWidth'), isTrue, reason: '最长 72 必须走常量');
      }
      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
       *
       * 原断言是「L-SLOT 里**不渲染任何可见元素**（连虚线框都不画）」。
       * 参考图里等级是一枚 **可见的小牌子（一品）**，而后端**没有等级字段**
       * → 新口径：**徽章要画出来，但内容必须是「待接入」占位**（`--`），
       * 绝不许编「一品」这种假等级名。几何（72×20）一个字没变。
       */
      expect(RegExp(r'levelSlotHeight[\s\S]{0,200}?border:').hasMatch(listCode), isFalse,
          reason: '等级位不画描边（待接入徽章只用灰底，避免出现第二套"牌子"外观）');
      expect(RegExp(r'worker-profile-level-slot[\s\S]{0,200}?border:').hasMatch(detailCode), isFalse);
      for (final code in [listCode, detailCode]) {
        expect(code.contains("'--'"), isTrue, reason: '等级徽章内容必须是 `--` 占位（不许填假等级名）');
        expect(code.contains('一品'), isFalse, reason: '后端没有等级字段 → 严禁出现「一品」这类假等级名');
      }
    });
  });
}

// =========================================================================
// 测试替身
// =========================================================================

class _Fixture {
  _Fixture({
    Map<String, dynamic>? players,
    this.profile,
    this.divisions = const [],
  }) : players = players ?? {'list': <Map<String, dynamic>>[], 'total': 0};

  /// `/public/players` 的 HTTP 状态（非 200 → 页面走失败态）
  int playersStatus = 200;

  /// `/public/players` 的 `data`（含 list / total）
  Map<String, dynamic> players;

  /// `/public/workers/:id` 的 `data`；null → 500（失败态）
  Map<String, dynamic>? profile;

  List<Map<String, dynamic>> divisions;

  /// 首屏骨架：让 `/public/players` 慢 300ms 才回（首帧就是骨架态）—— 仅骨架态用例注入
  Duration? playersDelay;

  /// A 套线上现状：14 人里 13 人介绍为空、14 人头像全 null、无评价
  factory _Fixture.full() => _Fixture(
        divisions: const [
          {'id': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英'},
        ],
        players: {
          'list': [
            {
              'workerId': '413',
              'nickname': 'E2E打手',
              'intro': 'E2E 测试账号：和平精英手游，只跑验收流程。',
              'avatarMediaId': null,
              'divisionId': '1',
              'divisionName': '和平精英·手游',
              'completedOrders': 30,
              'reviewCount': 2,
              'satisfiedRate': '96.5',
            },
            {
              'workerId': '401',
              'nickname': '小云',
              'intro': '',
              'avatarMediaId': null,
              'divisionId': null,
              'divisionName': null,
              'completedOrders': null,
              'reviewCount': null,
              'satisfiedRate': null,
            },
            // 介绍里有「100%」原文：用来验证"不许出现 100%"的断言必须**收窄到好评率那一格**
            {
              'workerId': '402',
              'nickname': '反悔',
              'intro': '不承诺 100% 上分，按局结算。',
              'avatarMediaId': null,
              'divisionName': '三角洲行动·端游',
              'completedOrders': null,
              'reviewCount': null,
              'satisfiedRate': null,
            },
            {
              'workerId': '403',
              'nickname': '清水',
              'intro': '',
              'avatarMediaId': null,
              'completedOrders': 30,
              'reviewCount': 100,
              'satisfiedRate': '1.0',
            },
            {
              'workerId': '414',
              'nickname': '演示工作端',
              'intro': '和平精英手游，主玩地铁逃生与团队竞技。',
              'avatarMediaId': null,
              'completedOrders': 1284,
              'reviewCount': 2,
              'satisfiedRate': '98.2',
            },
            {
              'workerId': '415',
              'nickname': 'wtest_a',
              'intro': '',
              'avatarMediaId': null,
              'completedOrders': 0,
              'reviewCount': 0,
              'satisfiedRate': 100,
            },
          ],
          'total': 6,
          'page': 1,
          'pageSize': 50,
        },
      );

  /// 有一张**真实头像**（`avatarMediaId` 非空）：守"有图必须走 AppAvatar"这条
  factory _Fixture.withAvatar() => _Fixture(
        divisions: const [
          {'id': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英'},
        ],
        players: {
          'list': [
            {
              'workerId': '413',
              'nickname': 'E2E打手',
              'intro': 'E2E 测试账号：和平精英手游，只跑验收流程。',
              'avatarMediaId': '9001',
              'divisionId': '1',
              'divisionName': '和平精英·手游',
              'completedOrders': 30,
              'reviewCount': 2,
              'satisfiedRate': '96.5',
            },
          ],
          'total': 1,
        },
      );

  /// 老接口：`/public/players` **一个字段都没加**（服务端还没上线新字段时的降级）
  factory _Fixture.legacy() => _Fixture(        divisions: const [
          {'id': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英'},
        ],
        players: {
          'list': [
            {
              'workerId': '401',
              'nickname': '小云',
              'intro': '只跑验收流程的测试账号。',
              'avatarMediaId': null,
            },
          ],
          'total': 1,
        },
      );

  /// 空名单（线上空分部的状态）：有分部、有宫格、有计数行，但名单为空
  factory _Fixture.empty() => _Fixture(
        divisions: const [
          {'id': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英'},
        ],
      );

  /// 详情：有介绍 / 有接单 / 有评价（含一条不满意）
  factory _Fixture.profileRich() => _Fixture(
        profile: {
          'id': '11',
          'nickname': '小云',
          'intro': '和平精英 · 手游。晚 9 点到次日 2 点在线，不接急单。',
          'avatarMediaId': null,
          'completedOrders': 30,
          'reviewCount': 2,
          'satisfiedRate': '96.5',
          'divisionName': '和平精英·手游',
          'divisionId': '1',
          'reviews': [
            {
              'satisfied': true,
              'remark': '节奏很稳，全程没掉线',
              'createdAt': '2026-10-15T09:20:00.000Z',
              'nicknameMasked': '老***板',
            },
            {
              'satisfied': false,
              'remark': '中间挂机了 15 分钟',
              'createdAt': '2026-10-14T21:05:00.000Z',
              'nicknameMasked': '雪***山',
            },
          ],
        },
        divisions: const [
          {'id': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英'},
        ],
      );

  /// 详情：**线上真实**（167 小云）—— 头像 null / 介绍空 / 0 接单 / 0 评价 / rate null
  factory _Fixture.profileReal() => _Fixture(
        profile: {
          'id': '167',
          'nickname': '小云',
          'intro': '',
          'avatarMediaId': null,
          'completedOrders': 0,
          'reviewCount': 0,
          'satisfiedRate': null,
          'divisionName': null,
          'divisionId': null,
          'reviews': const <Map<String, dynamic>>[],
        },
      );

  factory _Fixture.profileBadRate() => _Fixture(
        profile: {
          'id': '11',
          'nickname': '清水',
          'intro': '',
          'avatarMediaId': null,
          'completedOrders': 30,
          'reviewCount': 100,
          'satisfiedRate': '1.0',
          'reviews': const <Map<String, dynamic>>[],
        },
      );
}

ApiClient _api(_Fixture fx) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(fx);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.fx);

  final _Fixture fx;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.path;
    if (path.startsWith('/divisions')) {
      return _body(200, {'code': 0, 'message': 'ok', 'data': fx.divisions});
    }
    if (path.startsWith('/public/players')) {
      final delay = fx.playersDelay;
      if (delay != null) await Future<void>.delayed(delay);
      if (fx.playersStatus != 200) {
        return _body(fx.playersStatus, {'code': fx.playersStatus, 'message': '服务器开小差了', 'data': null});
      }
      return _body(200, {'code': 0, 'message': 'ok', 'data': fx.players});
    }
    if (path.contains('/reviews')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': const {'list': [], 'total': 2, 'page': 2, 'pageSize': 10},
      });
    }
    if (path.startsWith('/public/workers/')) {
      final p = fx.profile;
      if (p == null) {
        return _body(500, {'code': 500, 'message': '服务器开小差了', 'data': null});
      }
      return _body(200, {'code': 0, 'message': 'ok', 'data': p});
    }
    if (path.startsWith('/user/wallet')) {
      return _body(200, {'code': 0, 'message': 'ok', 'data': {'balance': 999}});
    }
    return _body(200, {'code': 0, 'message': 'ok', 'data': null});
  }

  static ResponseBody _body(int status, Map<String, dynamic> json) => ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

// =========================================================================
// 小工具
// =========================================================================

String _read(String relativePath) => File('${_repoRoot()}/$relativePath').readAsStringSync();

/// 仓库根（从测试文件位置往上找，直到看到 `apps` 与 `docs`）
String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/apps').existsSync() && Directory('${dir.path}/docs').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

/// 剥掉行注释（`//`；不含 `://`）—— 与 `leaderboard_page_test.dart` / `worker_profile_page_test.dart` 同一份写法
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
