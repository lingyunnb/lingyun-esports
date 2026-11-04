import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/models/review_models.dart';
import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/pages/worker_profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手信息页（负责人 2026-10-15：「选打手页面点开打手头像可以看打手信息」）
///
/// 硬要求：
/// 1. **好评率无评价时显示「暂无评价」，不许编 100%**；
/// 2. 展示 头像 + 名字 + 介绍 + **接单次数** + **好评率** + **最近评价列表**；
/// 3. 评价列表用**发丝线**分隔；好评/差评用**图标 + 字重 + 文案**区分（不只靠颜色）；
/// 4. 二级页：**底栏不显示**；页头用既有 `AppPageHeader`（PageHead 风格）；
/// 5. **不破坏结构规则 6**：「找陪玩」**列表行**仍然只有 头像 + 名字 + 介绍
///    （属性放到点进去的这一页）。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  Future<void> settle(WidgetTester tester, {int frames = 10}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Map<String, dynamic> review({required bool satisfied, String remark = '', String masked = '老***板', String at = '2026-10-15T09:20:00.000Z'}) =>
      {'satisfied': satisfied, 'remark': remark, 'createdAt': at, 'nicknameMasked': masked};

  Future<void> pumpPage(WidgetTester tester, _WorkerAdapter adapter) async {
    // 参考图 2 的头部（176dp 海报场）+ 内容卡（统计 / 介绍 / 胶囊 / Tab / 六维圆环 +
    // 六轴雷达 / 评价）→ 整页比重构前高了一倍多，默认 800×600 视口里「查看更多评价」根本不在屏上。
    // 用**加高视口**（402×2400，不缩内容）让整页一屏到底：交互位置真实可达、
    // `Tab`/按钮/追加的条目都在视口内 → 断言一条都不用动（也不靠 scrollUntilVisible 猜位置）。
    tester.view.physicalSize = const Size(402 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: WorkerProfilePage(
        api: _api(adapter),
        workerId: '11',
        fallbackNickname: '小云',
        fallbackIntro: '列表里的介绍',
      ),
    ));
    await settle(tester);
  }

  /// 详情夹具：有评价 + 有**五维评分**（`rating`）→ 六轴全有值（雷达画得出多边形）
  ///
  /// `rating` 的形状与服务端 `WorkerGradeService.detail()` 的 `RatingSummary` 一致
  /// （`samples > 0` 才算"有人评过"，见 `_WorkerRating.tryParse`）。
  Map<String, dynamic> richProfile() => {
        'id': '11',
        'nickname': '小云',
        'intro': '三角洲手游，晚上 8 点后接单；不接急单',
        'avatarMediaId': null,
        'completedOrders': 1284,
        'reviewCount': 2,
        'satisfiedRate': '98.6',
        'rating': {
          'skill': 8.75,
          'emotion': 9.1,
          'stress': 7.5,
          'voice': 8.0,
          'shop': 9.4,
          'avg': 8.55,
          'samples': 12,
        },
        'reviews': [
          review(satisfied: true, remark: '节奏很稳，全程没掉线'),
          review(
            satisfied: false,
            remark: '中间挂机了 15 分钟',
            masked: '雪***山',
            at: '2026-10-14T21:05:00.000Z',
          ),
        ],
      };

  testWidgets('无评价：好评率显示「暂无评价」，绝不编 100%', (tester) async {
    final adapter = _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '三角洲手游，晚上 8 点后接单',
      'avatarMediaId': null,
      'completedOrders': 0,
      'reviewCount': 0,
      'satisfiedRate': null,
      'reviews': const [],
    });
    await pumpPage(tester, adapter);

    expect(find.text(kNoReviewYet), findsOneWidget);
    expect(find.textContaining('100%'), findsNothing, reason: '无评价不许编 100%');
    expect(find.text('好评率'), findsOneWidget);
    expect(find.text('接单次数'), findsOneWidget);
    expect(find.text('0 次'), findsOneWidget);
    expect(find.text('这位打手还没有收到评价'), findsOneWidget);
  });

  testWidgets('无评价但服务端误回 100 + reviewCount 0：仍然显示「暂无评价」', (tester) async {
    final adapter = _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '',
      'avatarMediaId': null,
      'completedOrders': 3,
      'reviewCount': 0,
      'satisfiedRate': 100,
      'reviews': const [],
    });
    await pumpPage(tester, adapter);

    expect(find.text(kNoReviewYet), findsOneWidget);
    expect(find.textContaining('100%'), findsNothing);
  });

  testWidgets('有评价：头像 + 名字 + 介绍 + 接单次数 + 好评率 + 最近评价列表', (tester) async {
    final adapter = _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '三角洲手游，晚上 8 点后接单；不接急单',
      'avatarMediaId': null,
      'completedOrders': 1284,
      'reviewCount': 2,
      'satisfiedRate': '98.2',
      'reviews': [
        review(satisfied: true, remark: '节奏很稳，全程没掉线'),
        review(
          satisfied: false,
          remark: '中间挂机了 15 分钟',
          masked: '雪***山',
          at: '2026-10-14T21:05:00.000Z',
        ),
      ],
    });
    await pumpPage(tester, adapter);

    expect(find.text('打手信息'), findsOneWidget);
    expect(find.byType(AppPageHeader), findsOneWidget, reason: '二级页页头用既有 AppPageHeader');
    expect(find.text('小云'), findsOneWidget);
    expect(find.text('三角洲手游，晚上 8 点后接单；不接急单'), findsOneWidget);
    expect(find.text('1,284 次'), findsOneWidget);
    // 好评率的真值在**统计行**（2026-10-18 起头部只剩 名字 + ID + 等级徽章），口径同一个出口
    expect(find.text('98.2%'), findsWidgets, reason: '好评率按服务端百分数口径原样渲染');

    // 评价列表：发丝线分隔（2 条评价 = 1 条发丝线）
    expect(find.byKey(const Key('worker-profile-reviews')), findsOneWidget);
    expect(find.byType(AppHairline), findsOneWidget, reason: '列表行之间用发丝线分隔');
    expect(find.text('节奏很稳，全程没掉线'), findsOneWidget);
    expect(find.text('中间挂机了 15 分钟'), findsOneWidget);
    expect(find.text('老***板'), findsOneWidget, reason: '评价人昵称用服务端脱敏值');

    // 好评 / 差评不能只靠颜色：图标 + 字重 + 文案三档同时在
    expect(find.byIcon(AppIcon.check), findsOneWidget, reason: '好评的勾图标');
    expect(find.byIcon(AppIcon.complaint), findsOneWidget, reason: '差评的警示图标');
    expect(find.text('满意'), findsOneWidget);
    expect(find.text('不满意'), findsOneWidget);
    final good = tester.widget<Text>(find.text('满意'));
    final bad = tester.widget<Text>(find.text('不满意'));
    expect(good.style!.fontWeight, FontWeight.w700);
    expect(bad.style!.fontWeight, FontWeight.w700);
    expect(good.style!.color, isNot(bad.style!.color), reason: '颜色只是第三重信号（不是唯一）');

    // 二级页：底栏不显示
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar, isNull,
        reason: '打手信息页是二级页 → 没有底栏');
  });

  testWidgets('查看更多评价：还有下一页时给按钮，点完追加且不与「最近评价」重复', (tester) async {
    // 详情接口给了 2 条「最近评价」，总数 4 → 还有 2 条在第二页
    final adapter = _WorkerAdapter(
      profile: {
        'id': '11',
        'nickname': '小云',
        'intro': '',
        'avatarMediaId': null,
        'completedOrders': 1284,
        'reviewCount': 4,
        'satisfiedRate': '75',
        'reviews': [
          review(satisfied: true, remark: '第一条'),
          review(satisfied: true, remark: '第二条', at: '2026-10-14T21:05:00.000Z'),
        ],
      },
      pages: {
        // 第 2 页故意把第 1 页的「第二条」也带回来（真实服务端分页边界常见的重叠）
        2: {
          'list': [
            review(satisfied: true, remark: '第二条', at: '2026-10-14T21:05:00.000Z'),
            review(satisfied: true, remark: '第三条', at: '2026-10-13T20:00:00.000Z'),
            review(satisfied: false, remark: '第四条', at: '2026-10-13T18:00:00.000Z'),
          ],
          'total': 4,
          'page': 2,
          'pageSize': 10,
        },
      },
    );
    await pumpPage(tester, adapter);

    /**
     * 【前置动作修正 · 负责人 2026-10-17 指示照参考图重构】
     *
     * 参考图 2 在评价区之前多了「礼物墙卡 + 六维圆环 + 五维雷达」三块（版式做满），
     * 页面因此变长。上一轮我用 `ensureVisible` + `drag` 去"追"按钮，**没有真的把按钮
     * 滚进可点位置**（点了没反应 → `page=2` 从未发出）。
     * 本轮回修：把整页放进**加高视口**（见 [pumpPage] 的 402×2400）——
     * 按钮/追加条目都在视口内，不再依赖滚动，**断言一条未动、去重口径未动**。
     */
    final more = find.byKey(const Key('worker-profile-more-reviews'));
    expect(more, findsOneWidget);

    // 保险：视口已经够高（按钮本来就在屏上，这一步是 no-op）；
    // 万一以后页面再变长，它会把按钮滚到可点位置，而不是让 tap 落空。
    await tester.ensureVisible(more);
    await settle(tester);
    await tester.tap(more);
    await settle(tester);

    expect(adapter.reviewsQueries, contains('page=2'));

    expect(find.text('第三条'), findsOneWidget, reason: '第二页的新条目追加进来');
    expect(find.text('第四条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget, reason: '与第一页重叠的那一条只出现一次（去重）');
    expect(find.byType(AppHairline), findsNWidgets(3), reason: '4 条评价 → 3 条发丝线');
    expect(more, findsNothing, reason: '已展示条数 = 总数 → 按钮收掉');
  });

  testWidgets('差评占多数的打手：`1.0`（= 1%）必须显示 1%，**绝不能显示 100%**', (tester) async {
    // 致命口径回归（2026-10-15 主控亲修）：`satisfiedRate` 是**百分数字符串**（"1.0" = 1%）。
    // 若客户端按"0–1 比率"猜口径，100 条评价里只有 1 条好评会被渲染成 **100%（满分）**——
    // 用户会照着"满分"去下单，这是评价体系里最不能出的错。这条用例就钉死这一条。
    final adapter = _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '',
      'avatarMediaId': null,
      'completedOrders': 30,
      'reviewCount': 100,
      'satisfiedRate': '1.0',
      'reviews': const [],
    });
    await pumpPage(tester, adapter);

    // A 套设计稿：头部"一行事实"与统计卡**都显示**这个比率（同一个出口）
    expect(find.text('1%'), findsWidgets);
    expect(find.textContaining('100%'), findsNothing, reason: '1% 不许被换算成 100%');
    expect(find.text(kNoReviewYet), findsNothing, reason: '有评价就不是"暂无评价"');
  });

  testWidgets('拿不到打手信息：给出重试（列表带的兜底名字先显示，不空白）', (tester) async {
    final adapter = _WorkerAdapter(profile: null);
    await pumpPage(tester, adapter);

    expect(find.text('打手信息暂时取不到'), findsOneWidget);
    expect(find.text('小云'), findsOneWidget, reason: '兜底名字先上屏（列表带过来的）');
    expect(find.text('重试'), findsOneWidget);

    // 服务端恢复 → 重试拿到真数据
    adapter.profile = {
      'id': '11',
      'nickname': '小云（服务端）',
      'intro': '真介绍',
      'avatarMediaId': null,
      'completedOrders': 12,
      'reviewCount': 0,
      'satisfiedRate': null,
      'reviews': const [],
    };
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('小云（服务端）'), findsOneWidget);
    expect(find.text('12 次'), findsOneWidget);
  });

  testWidgets('接口形状不对（review 缺 satisfied）：那条评价被丢掉，不猜成差评', (tester) async {
    final adapter = _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '',
      'avatarMediaId': null,
      'completedOrders': 5,
      'reviewCount': 2,
      'satisfiedRate': '50',
      'reviews': [
        {'remark': '形状不对的一条', 'createdAt': '2026-10-15T09:20:00.000Z'},
        review(satisfied: true, remark: '正常的一条'),
      ],
    });
    await pumpPage(tester, adapter);

    expect(find.text('形状不对的一条'), findsNothing, reason: '形状不对的条目丢掉，不当成差评');
    expect(find.text('正常的一条'), findsOneWidget);
    expect(find.text('不满意'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 两个入口都要能进（负责人 2026-10-15：找陪玩点头像 / 指定护航员弹层点头像）
  // -------------------------------------------------------------------------

  testWidgets('入口①「找陪玩」列表点头像 → 进打手信息页', (tester) async {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _apiFor(_EntryAdapter()))));
    await settle(tester);

    expect(find.text('小云'), findsOneWidget);
    expect(find.text('三角洲手游，晚上 8 点后接单'), findsOneWidget);

    /**
     * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
     *
     * 原断言是「列表行**不许出现**接单次数 / 好评率」（依据旧的结构规则 6）。
     * 负责人当日新指令要求照参考图 1 重构列表卡（名字 / 分部胶囊 / 介绍 / **金额** /
     * **接单数 + 好评率**），并把旧禁项覆盖掉 → 这里把两条"禁止出现"改成"必须出现"，
     * 且值必须来自真实字段（`completedOrders` / `satisfiedRate` 同一出口）。
     */
    expect(find.text('接单 1,284 次 · 98.2%'), findsOneWidget,
        reason: '列表卡必须显示接单次数 + 好评率（真实字段，千分位 + 百分数口径同一出口）');
    expect(find.text('暂无接单记录 · $kNoReviewYet'), findsNothing, reason: '本夹具两个字段都有值');

    // 点头像 → 新页
    expect(find.byType(WorkerProfilePage), findsNothing);
    await tester.tap(find.byKey(const Key('player-avatar-11')));
    await settle(tester);

    expect(find.byType(WorkerProfilePage), findsOneWidget);
    expect(find.text('打手信息'), findsOneWidget);
    expect(find.text('98.2%'), findsWidgets, reason: '属性在详情页的统计行（同一出口）');
    expect(find.text('接单次数'), findsOneWidget);
  });

  testWidgets('入口②下单页「指定护航员」弹层点头像 → 进打手信息页（弹层不关）', (tester) async {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _apiFor(_EntryAdapter()), divisionId: '2', product: _entryProduct),
    ));
    await settle(tester);

    // 护航员卡在页面下方 → 滚动到它，点「指定护航员」开弹层
    await tester.drag(find.byType(ListView).first, const Offset(0, -420));
    await settle(tester, frames: 6);
    await tester.tap(find.text('指定护航员'));
    await settle(tester);

    expect(find.byKey(const Key('picker-avatar-11')), findsOneWidget, reason: '弹层行头像是入口');
    await tester.tap(find.byKey(const Key('picker-avatar-11')));
    await settle(tester);

    expect(find.byType(WorkerProfilePage), findsOneWidget);
    expect(find.text('打手信息'), findsOneWidget);
    expect(find.text('98.2%'), findsWidgets);
  });

  // -------------------------------------------------------------------------
  // 负责人 2026-10-18：删三样 + 能力雷达改六轴（数值允许溢出卡片边界）
  // -------------------------------------------------------------------------

  testWidgets('删除三样：礼物墙整卡 / 海报里的 粉丝·推荐 / 底部「礼物」都不在了', (tester) async {
    await pumpPage(tester, _WorkerAdapter(profile: richProfile()));

    /**
     * 【口径重钉 · 负责人 2026-10-18：删礼物墙/粉丝/推荐，雷达改六轴且数值溢出图外】
     *
     * 2026-10-17 那一版按参考图 2 把这三块版式做满了（收据见当时的 `worker-profile-gift-wall`）。
     * 2026-10-18 负责人明确「不要加礼物墙，粉丝和推荐也不要」→ 三样整体删除；
     * 这里从"版式必须有"重钉成"必须没有"，同时钉住**保留下来的那两个动作**。
     */
    expect(find.byKey(const Key('worker-profile-gift-wall')), findsNothing, reason: '礼物墙整卡必须删除');
    expect(find.textContaining('礼物'), findsNothing, reason: '礼物墙 / 礼物按钮的文字一个都不许留');
    expect(find.textContaining('粉丝'), findsNothing, reason: '海报里的 粉丝 N 删除');
    expect(find.textContaining('推荐 '), findsNothing, reason: '海报里的 推荐 N 删除（底部那颗「推荐」按钮不带空格，见下）');

    // 保留：推荐（置灰待接入，按指示原样保留）+ 联系客服 + 主按钮
    expect(find.text('推荐'), findsOneWidget, reason: '底部「推荐」按钮保留（仍是置灰待接入位）');
    expect(find.text('联系客服'), findsOneWidget, reason: '底部「联系客服」是真功能，必须留');
    expect(find.text('找 TA 下单'), findsOneWidget, reason: '主按钮不因删按钮而丢');
    // 头像 / 名字 / ID 照旧（删的只是那两个数字）
    expect(find.byKey(const Key('worker-profile-avatar')), findsOneWidget);
    expect(find.text('小云'), findsOneWidget);
    expect(find.text('ID '), findsOneWidget);
  });

  testWidgets('六轴雷达：六个轴名固定 + 数值来自 rating.* / 好评率÷10 + 单位「分」', (tester) async {
    await pumpPage(tester, _WorkerAdapter(profile: richProfile()));

    /**
     * 【口径重钉 · 负责人 2026-10-18：KD 评分那几个字改成评分，店内表现改成综合表现】
     *
     * 原断言（2026-10-17）钉的是"六维圆环 + 五维雷达四个维度都是 `--`"（当时后端没有分值）。
     * 2026-10-18 起详情接口已带 `rating{skill,emotion,stress,voice,shop,samples}` +
     * 好评率，于是重钉成"六个轴必须有名字、有真实数值、有单位"，并把旧名钉死为不许出现。
     */
    for (final name in kRatingAxes) {
      expect(find.text(name), findsWidgets, reason: '轴名「$name」必须出现在能力区（环图标签 + 雷达顶点）');
    }
    expect(kRatingAxes, <String>['评分', '技术水平', '情绪价值', '抗压能力', '声音听感', '综合表现'],
        reason: '六个轴的名字与顺序由负责人固定，一个字都不许改');
    expect(find.text('KD评分'), findsNothing, reason: '「KD评分」这个说法已删，第一个轴只叫「评分」');
    expect(find.text('店内表现'), findsNothing, reason: '「店内表现」改名「综合表现」');

    // 「评分」轴 = 好评率 ÷ 10：98.6% → 9.86（环图与雷达顶点各一处）
    expect(find.text('9.86'), findsWidgets, reason: '「评分」轴必须是 好评率÷10（98.6% → 9.86）');
    // 其余五轴 = rating.skill / emotion / stress / voice / shop（原样，不重算）
    expect(find.text('8.75'), findsWidgets, reason: '技术水平 = rating.skill');
    expect(find.text('9.1'), findsWidgets, reason: '情绪价值 = rating.emotion（9.10 不吃尾零）');
    expect(find.text('7.5'), findsWidgets, reason: '抗压能力 = rating.stress');
    expect(find.text('8'), findsWidgets, reason: '声音听感 = rating.voice（8.0 → 8）');
    expect(find.text('9.4'), findsWidgets, reason: '综合表现 = rating.shop');

    // 单位：数值后面跟小字「分」，不写英文 best
    expect(find.text('分'), findsWidgets, reason: '数值后面跟小字「分」');
    expect(find.textContaining('best'), findsNothing, reason: '项目全中文，不出现英文 best');
    expect(find.text('100%'), findsNothing, reason: '1% 那类口径仍然不许被换算成 100%');
  });

  testWidgets('缺数据：只画网格不画多边形，数值显示 `--`（绝不编 0 分）', (tester) async {
    // 没有 `rating`、没有好评率 → 六轴一个值都没有
    await pumpPage(tester, _WorkerAdapter(profile: {
      'id': '11',
      'nickname': '小云',
      'intro': '',
      'avatarMediaId': null,
      'completedOrders': 0,
      'reviewCount': 0,
      'satisfiedRate': null,
      'reviews': const [],
    }));

    expect(find.byKey(const Key('worker-profile-radar')), findsOneWidget, reason: '网格照画（坐标轴在、数据不在）');
    expect(find.text('--'), findsWidgets, reason: '六个轴的数值位必须是 `--`');
    expect(find.text('分'), findsNothing, reason: '没有数值就不挂单位（"-- 分"读不通）');
    expect(find.text(kRatingPendingText), findsOneWidget, reason: '一格数据都没有时才说明"评分体系待接入"');
    expect(find.text('0'), findsNothing, reason: '缺数据不许画成 0 分');
    expect(tester.takeException(), isNull);
  });

  testWidgets('数值可以溢出卡片：卡片与雷达块都是 Clip.none + 雷达区留白 ≥44dp', (tester) async {
    await pumpPage(tester, _WorkerAdapter(profile: richProfile()));

    /**
     * 【口径重钉 · 负责人 2026-10-18：数据可以直接溢出去的】
     *
     * 轴标签 / 数值 / 单位画在六边形**外侧**，窄屏上会压到卡片描边之外 →
     * 卡片与雷达块都必须 `Clip.none`（默认值碰巧是 none 不算数，要写成契约），
     * 且雷达区上下左右留白 ≥44dp 给这些数字落位。
     */
    final card = tester.widget<Container>(
      find.ancestor(of: find.byKey(const Key('worker-profile-rings')), matching: find.byType(Container)).first,
    );
    expect(card.clipBehavior, Clip.none, reason: '能力卡不许裁掉溢出的数值');

    final radar = find.byKey(const Key('worker-profile-radar'));
    final size = tester.getSize(radar);
    expect(size.height, WorkerProfilePage.radarBlockHeight, reason: '雷达块高 = 画布 + 上下两组顶点外标签');
    expect((size.width - WorkerProfilePage.radarChartSize) / 2, greaterThanOrEqualTo(44),
        reason: '左右留白 ≥44dp');
    expect((size.height - WorkerProfilePage.radarChartSize) / 2, greaterThanOrEqualTo(44),
        reason: '上下留白 ≥44dp');
    expect(WorkerProfilePage.radarAxes, 6, reason: '六轴（不是五轴）');
    expect(WorkerProfilePage.radarRings, 5, reason: '5 圈同心网格，不画满 10 圈');
    expect(tester.takeException(), isNull);
  });

  /**
   * 【新钉 · 负责人 2026-10-18 真机圈图】
   *
   * 原样：「上方那一块要跟着用户滑动而动，不要在那停着不动」。
   * 旧实现里页头（`AppPageHeader`）挂在 `Column` 第一格、与滚动区**并列** → 它永远不动。
   * 现在页头是 `CustomScrollView` 的第一个 sliver（`pinned: false, floating: true`）。
   *
   * 这条测试钉住三件事（缺一条这个改造就算没做成）：
   * 1. 顶栏与海报**同步上移**（同一根滚动轴，位移必须一致 → 也顺手钉死"没有错位"）
   * 2. 底部操作条（推荐 / 联系客服 / 找 TA 下单）**不动** —— 它是操作区，不跟着滚
   * 3. 反向滑回来时顶栏**自己回来**（floating）→ 滚到页面深处也永远有返回入口
   */
  testWidgets('顶栏随内容滚走（不再固定），底部操作条仍固定', (tester) async {
    // 真机高度（402×700）：内容必然超出视口 → 真的能滚
    tester.view.physicalSize = const Size(402 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: WorkerProfilePage(
        api: _api(_WorkerAdapter(profile: richProfile())),
        workerId: '11',
        fallbackNickname: '小云',
      ),
    ));
    await settle(tester);

    final headerTitle = find.text('打手信息');
    final poster = find.byKey(const Key('worker-profile-header-field'));
    final bar = find.byKey(const Key('worker-profile-bottom-bar'));
    final scroll = find.byKey(WorkerProfilePage.scrollKey);

    expect(headerTitle, findsOneWidget, reason: '进页即有返回栏（返回按钮必须在页头里）');
    expect(scroll, findsOneWidget, reason: '整页只有这一个滚动区（顶栏与内容同一根轴）');

    final double headerTop0 = tester.getTopLeft(headerTitle).dy;
    final double posterTop0 = tester.getTopLeft(poster).dy;
    final double barTop0 = tester.getTopLeft(bar).dy;

    // 页头没把海报挤错位：海报紧跟页头（57 = 56 内容 + 1 发丝线，tests 里无状态栏内距）
    expect(posterTop0 - headerTop0, closeTo(AppPageHeader.barHeight, 0.5),
        reason: '海报紧贴页头：加了滚动层但层高没变');

    // 手指上滑 40 → 顶栏与海报**一起**上移（固定着不动时就还是 0）
    await tester.drag(scroll, const Offset(0, -40));
    await settle(tester);
    final double headerDelta = tester.getTopLeft(headerTitle).dy - headerTop0;
    final double posterDelta = tester.getTopLeft(poster).dy - posterTop0;

    expect(headerDelta, lessThan(-20),
        reason: '负责人 2026-10-18：「上方那一块要跟着用户滑动而动，不要在那停着不动」');
    expect(posterDelta, lessThan(-20), reason: '海报本来就该随滚（前置条件）');
    expect(posterDelta, closeTo(headerDelta, 0.5),
        reason: '顶栏与海报在同一根滚动轴上 → 位移逐像素一致（也证明没有因为它上面多了一层而错位）');
    expect(tester.getTopLeft(bar).dy, closeTo(barTop0, 0.01),
        reason: '底部操作条是操作区：不跟着滚');

    // 手指下滑 80 → 回到顶部，顶栏**自己回来**（floating 语义）
    await tester.drag(scroll, const Offset(0, 80));
    await settle(tester);
    expect(tester.getTopLeft(headerTitle).dy, closeTo(headerTop0, 2),
        reason: 'floating：回滑时顶栏自己滑回来 → 滚到深处也不会没有返回入口');
    expect(tester.getTopLeft(bar).dy, closeTo(barTop0, 0.01), reason: '底部操作条依然固定');
    expect(tester.takeException(), isNull);
  });

  test('结构与口径：列表行可以带接单数/好评率，但绝不出现「评分/等级/单价」这类假数值', () {
    final src = File('${resolveRepoRoot()}/apps/boss-app/lib/pages/players_page.dart').readAsStringSync();
    final code = _stripComments(src);
    /**
     * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
     *
     * 原断言是「找陪玩列表行不得出现 `接单次数` / `好评率` / `评分`」——那是旧的结构规则 6
     * （"列表只允许 名字 + 介绍"）。负责人当日新指令明确要求照参考图重构列表卡，
     * 并把这些字段**放开**；于是这里改成"必须有"，同时把**仍然不许编的东西**钉死：
     * 后端没有的 6 类字段（六维评分 / 礼物墙 / 粉丝 / 等级 / 单价 / 时长）只能是「待接入」占位。
     */
    expect(code.contains('接单 '), isTrue, reason: '列表卡必须显示接单次数（真实字段）');
    expect(code.contains('satisfiedRateText'), isTrue, reason: '好评率必须走唯一出口');
    /**
     * 【口径重钉 · 负责人 2026-10-18 真机圈图】
     *
     * 原断言是「金额位必须存在：`code.contains('价格') || code.contains('¥')`」——
     * 那是 2026-10-17 照参考图重构时的口径（后端没有单价 → 画 `¥--` + 「待接入」占位）。
     * 负责人本轮在真机上圈住那枚 `¥--  待接入` 说「这个标志也去掉」，占位整块删除
     * → 旧断言**必然过期**（这不是 bug，是口径变了）。
     *
     * 重钉成两条**反向**断言（不是放宽：从"必须有金额位"改成"必须没有金额位"，并把节点
     * Key 一起钉住）—— 谁把占位偷偷加回来，这里立刻红。
     */
    expect(code.contains('¥--'), isFalse,
        reason: '金额占位 `¥--` 已按负责人圈图删除（卡上不再有价签；单价只可能出现在详情页）');
    expect(code.contains('player-price-'), isFalse, reason: '列表卡不再渲染金额位节点（Key 也不许留）');
    expect(code.contains('待接入'), isTrue, reason: '后端没有的字段必须是「待接入」，不许填假数字');
    expect(code.contains('钻石'), isFalse, reason: '全站只认 ¥/元，绝不出现「钻石」计价');
    expect(code.contains('一品'), isFalse, reason: '后端没有等级字段 → 严禁假等级名');
    expect(code.contains('WorkerProfilePage'), isTrue, reason: '点头像进新页的入口必须在');
  });

  test('打手信息页零硬编码色值、零 emoji、零渐变铺面', () {
    final src = File('${resolveRepoRoot()}/apps/boss-app/lib/pages/worker_profile_page.dart').readAsStringSync();
    final code = _stripComments(src);
    expect(RegExp(r'0x[0-9A-Fa-f]{6,8}').allMatches(code), isEmpty, reason: '色值一律走 T.* / AppColors.*');
    final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true).allMatches(code).length;
    expect(emoji, 0, reason: '图标一律用 AppIcon（禁 emoji）');
    expect(code.contains('积分'), isFalse, reason: '不出现旧计价单位');
  });
}

/// 剥掉行注释（`//`；不含 `://`）—— 与 `leaderboard_page_test.dart` 同一份写法
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

ApiClient _api(_WorkerAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 任意适配器 → ApiClient（两个入口用例用组合适配器）
ApiClient _apiFor(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 两个入口用例共用的商品（三角洲手游：gameId=36 / divisionId=2）
const Map<String, dynamic> _entryProduct = {
  'id': '201',
  'name': '三角洲手游护航单',
  'subtitle': '',
  'gameId': '36',
  'categoryId': '51',
  'divisionId': '2',
  'price': 88,
  'priceUnit': '单',
  'salesCount': 12,
  'coverMediaId': null,
  'coverUrl': null,
};

/// 入口用例的组合假接口：`/divisions` + `/public/players` + `/public/order-form` + `/public/workers/11`
class _EntryAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.path;
    if (path.startsWith('/divisions')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '2',
            'gameId': '36',
            'name': '三角洲行动 · 手游',
            'shortName': '三角洲行动',
            'platformLabel': '手游',
            'themeColor': '#2563EB',
            'iconMediaId': null,
          },
        ],
      });
    }
    if (path.startsWith('/public/players')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {
              'workerId': '11',
              'nickname': '小云',
              'intro': '三角洲手游，晚上 8 点后接单',
              'avatarMediaId': null,
              // 2026-10-17 起列表卡允许展示接单数 + 好评率（真实字段），与详情页同一出口
              'completedOrders': 1284,
              'reviewCount': 2,
              'satisfiedRate': '98.2',
            },
          ],
          'total': 1,
          'page': 1,
          'pageSize': 50,
        },
      });
    }
    if (path.startsWith('/public/order-form')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': {
          'zoneLabel': '选择区服',
          'zoneOptions': [
            {'label': 'QQ 区', 'value': 'qq'},
          ],
          'fields': [
            {
              'key': 'gamePlayerId',
              'label': '游戏 ID',
              'placeholder': '填游戏 ID',
              'type': 'text',
              'required': true,
              'enabled': true,
              'maxLength': 64,
            },
          ],
          'workerLabel': '选择护航员',
          'workerRandomLabel': '随机安排',
          'workerDesignatedLabel': '指定护航员',
          'feeTitle': '商品费用',
          'feeUnitLabel': '单价',
          'totalLabel': '合计',
          'submitText': '提交订单',
        },
      });
    }
    if (path.contains('/reviews')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': const {'list': [], 'total': 2, 'page': 2, 'pageSize': 10},
      });
    }
    if (path.startsWith('/public/workers/')) {
      return _body(200, {
        'code': 0,
        'message': 'ok',
        'data': {
          'id': '11',
          'nickname': '小云',
          'intro': '三角洲手游，晚上 8 点后接单',
          'avatarMediaId': null,
          'completedOrders': 1284,
          'reviewCount': 2,
          'satisfiedRate': '98.2',
          'reviews': [
            {'satisfied': true, 'remark': '节奏很稳', 'createdAt': '2026-10-15T09:20:00.000Z', 'nicknameMasked': '老***板'},
            {'satisfied': false, 'remark': '中间挂机', 'createdAt': '2026-10-14T09:20:00.000Z', 'nicknameMasked': '雪***山'},
          ],
        },
      });
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

/// 假接口：`GET /public/workers/:id`（profile = null → 500）+ `GET .../reviews?page&pageSize`
class _WorkerAdapter implements HttpClientAdapter {
  _WorkerAdapter({required this.profile, this.pages = const {}});

  Map<String, dynamic>? profile;

  /// page → 分页响应
  final Map<int, Map<String, dynamic>> pages;

  final List<String> reviewsQueries = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.path.contains('/reviews')) {
      final page = int.tryParse('${options.queryParameters['page'] ?? '1'}') ?? 1;
      reviewsQueries.add('page=$page');
      final body = pages[page] ?? const {'list': [], 'total': 0, 'page': 1, 'pageSize': 10};
      return _body(200, {'code': 0, 'message': 'ok', 'data': body});
    }
    final p = profile;
    if (p == null) {
      return _body(500, {'code': 500, 'message': '服务器开小差了', 'data': null});
    }
    return _body(200, {'code': 0, 'message': 'ok', 'data': p});
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
