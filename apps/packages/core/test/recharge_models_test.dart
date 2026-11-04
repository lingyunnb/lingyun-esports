import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 充值（余额）+ 审核 —— **模型与规则层**单测（负责人 2026-10-06 方案①②）
/// 口径 2026-10-09：计价单位由「积分」改为「余额」，**1 元 = 1 元**，金额一律 `fmtMoney`（¥）
///
/// 覆盖：
/// ① 配置解析（档位/自定义/上限/收款码；多候选键名，后端字段有出入也吃得住）
/// ② 入口渲染判据 `entryAvailable`（**没有收款码就没有入口**；比例字段不再参与）
/// ③ 金额解析与越界校验（中文错误）
/// ④ 到账余额预览（1:1）与金额格式化（¥ + 两位小数 + 千分位）
/// ⑤ 我的申请状态文案（待审核 / 已到账 / 已驳回 / 未知状态显示原文）
/// ⑥ 待审核列表解析（list / items / 裸数组；用户字段嵌在 user 里也吃）
/// ⑦ 合规文案：提交后只允许「申请已提交，等待审核」，且**不含**"支付成功/自动到账"
/// ⑧ `RechargeEntry` 版式硬参数：无渐变、无阴影、圆角 10、无 emoji
void main() {
  group('① 充值配置解析', () {
    test('任务书字段形状', () {
      final cfg = RechargeConfig.fromJson(const {
        'amountOptions': [6, 10, 20, 38, 68, 98, 128, 198, 328, 648],
        'customEnabled': true,
        'minYuan': 6,
        'maxYuan': 648,
        'pointsPerYuan': 10,
        'pendingLimitPerUser': 3,
        'noticeText': '付款后请上传截图并提交申请',
        'qrCodes': [
          {'id': '11', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/11'},
          {'id': '12', 'channel': 'alipay', 'label': '', 'url': 'https://cdn.example.com/a.png'},
        ],
      });
      expect(cfg.amountOptions, hasLength(10));
      expect(cfg.amountOptions.first, 6);
      expect(cfg.amountOptions.last, 648);
      expect(cfg.customEnabled, isTrue);
      expect(cfg.effectiveMinYuan, 6);
      expect(cfg.effectiveMaxYuan, 648);
      expect(cfg.effectivePointsPerYuan, 10);
      expect(cfg.pendingLimitPerUser, 3);
      expect(cfg.noticeText, contains('上传截图'));
      expect(cfg.qrCodes, hasLength(2));
      expect(cfg.qrCodes[0].channel, RechargeQrChannel.wechat);
      expect(cfg.qrCodes[0].channel.label, '微信');
      // label 为空时退化为渠道名（绝不显示空白渠道）
      expect(cfg.qrCodes[1].channel, RechargeQrChannel.alipay);
      expect(cfg.qrCodes[1].displayLabel, '支付宝');
      expect(cfg.entryAvailable, isTrue);
    });

    test('字段名有出入也吃得住（amounts / rate / custom / codes）', () {
      final cfg = RechargeConfig.fromJson(const {
        'amounts': ['12', '30'],
        'allowCustom': 1,
        'min': 5,
        'max': 100,
        'rate': 20,
        'codes': [
          {'qrId': '3', 'payChannel': 'WX', 'name': '微信', 'imageUrl': 'abc-uuid'},
        ],
      });
      expect(cfg.amountOptions, [12, 30]);
      expect(cfg.customEnabled, isTrue);
      expect(cfg.effectiveMinYuan, 5);
      expect(cfg.effectiveMaxYuan, 100);
      expect(cfg.effectivePointsPerYuan, 20);
      expect(cfg.qrCodes.single.channel, RechargeQrChannel.wechat);
      // 纯媒体 id → 走公开媒体通道
      expect(cfg.qrCodes.single.imageUrl, endsWith('/media/public/abc-uuid'));
    });

    test('② 没有可用收款码 → 入口不渲染（entryAvailable = false）', () {
      final cfg = RechargeConfig.fromJson(const {
        'amountOptions': [6, 20],
        'customEnabled': true,
        'pointsPerYuan': 10,
        'qrCodes': [],
      });
      expect(cfg.qrCodes, isEmpty);
      expect(cfg.entryAvailable, isFalse);
    });

    test('② 比例字段缺失（=0）**不再影响入口**：1:1 口径下比例不参与展示', () {
      final cfg = RechargeConfig.fromJson(const {
        'amountOptions': [6],
        'qrCodes': [
          {'id': '1', 'channel': 'wechat', 'url': '/media/public/1'}
        ],
      });
      expect(cfg.effectivePointsPerYuan, 0 + 1); // 退化为 1（防除零）
      // 口径变更（2026-10-09）：到账 = 付款金额（1:1），不再需要"比例"才能给出承诺。
      // 原实现把比例当入口闸门 → 服务端清零/移除该历史字段时充值入口会整个消失（功能丢失）。
      expect(cfg.entryAvailable, isTrue, reason: '有收款码 + 有金额档位就该有入口');
    });

    test('金额档位过滤非法值（<=0 / 非数字），并保持顺序', () {
      final cfg = RechargeConfig.fromJson(const {
        'amountOptions': [6, 0, -3, 'x', 20],
        'qrCodes': [
          {'id': '1', 'channel': 'wechat', 'url': '/media/public/1'}
        ],
        'pointsPerYuan': 10,
      });
      expect(cfg.amountOptions, [6, 20]);
    });
  });

  group('③ 金额解析与越界校验（中文错误）', () {
    final cfg = RechargeConfig.fromJson(const {
      'amountOptions': [6, 10, 20],
      'customEnabled': true,
      'minYuan': 6,
      'maxYuan': 200,
      'pointsPerYuan': 10,
      'qrCodes': [
        {'id': '1', 'channel': 'wechat', 'url': '/media/public/1'}
      ],
    });

    test('parseYuan：合法 / 两位小数 / 非法', () {
      expect(RechargeRules.parseYuan('12'), 12);
      expect(RechargeRules.parseYuan(' 12.5 '), 12.5);
      expect(RechargeRules.parseYuan('12.50'), 12.5);
      // 浮点回归（2026-10-09 实测踩坑）：`8.8 * 100 == 880.0000000000001`，
      // 用 `(v*100).round() != v*100` 判两位小数会把合法的 8.8 判成非法
      expect(RechargeRules.parseYuan('8.8'), 8.8);
      expect(RechargeRules.parseYuan('0.6'), 0.6);
      expect(RechargeRules.parseYuan('99999.9'), 99999.9);
      expect(RechargeRules.parseYuan('8.88'), 8.88);
      expect(RechargeRules.parseYuan('0'), isNull);
      expect(RechargeRules.parseYuan('-8'), isNull);
      expect(RechargeRules.parseYuan('abc'), isNull);
      expect(RechargeRules.parseYuan(''), isNull);
      expect(RechargeRules.parseYuan('1.234'), isNull);
    });

    test('hasAtMostTwoDecimals：浮点下仍能正确判两位小数', () {
      for (final v in [8.8, 0.6, 1.8, 3.8, 12.5, 12.55, 1234.5, 99999.9, 6, 0]) {
        expect(RechargeRules.hasAtMostTwoDecimals(v), isTrue, reason: '$v 是合法金额');
      }
      for (final v in [1.234, 0.005, 12.345]) {
        expect(RechargeRules.hasAtMostTwoDecimals(v), isFalse, reason: '$v 超过两位小数');
      }
    });

    test('validateAmount：低于下限 / 高于上限 / 合法 / 未选', () {
      expect(RechargeRules.validateAmount(5, cfg), '最低 ¥6.00');
      expect(RechargeRules.validateAmount(201, cfg), '最高 ¥200.00');
      expect(RechargeRules.validateAmount(6, cfg), isNull);
      expect(RechargeRules.validateAmount(200, cfg), isNull);
      expect(RechargeRules.validateAmount(null, cfg), '请输入充值金额');
    });

    test('validateCustomInput：空输入不报红，输错了才报', () {
      expect(RechargeRules.validateCustomInput('', cfg), isNull);
      expect(RechargeRules.validateCustomInput('  ', cfg), isNull);
      expect(RechargeRules.validateCustomInput('3', cfg), '最低 ¥6.00');
      expect(RechargeRules.validateCustomInput('900', cfg), '最高 ¥200.00');
      expect(RechargeRules.validateCustomInput('9.9.9', cfg), '请输入正确的金额（最多两位小数）');
      expect(RechargeRules.validateCustomInput('38', cfg), isNull);
    });

    test('maxYuan<=0 视为不限（只卡下限）', () {
      final open = RechargeConfig.fromJson(const {
        'amountOptions': [6],
        'customEnabled': true,
        'minYuan': 6,
        'maxYuan': 0,
        'pointsPerYuan': 10,
        'qrCodes': [
          {'id': '1', 'channel': 'wechat', 'url': '/media/public/1'}
        ],
      });
      expect(open.effectiveMaxYuan, 0);
      expect(RechargeRules.validateAmount(99999, open), isNull);
    });
  });

  group('④ 到账余额预览（1:1）与金额格式化', () {
    final cfg = RechargeConfig.fromJson(const {
      'amountOptions': [6, 38],
      'pointsPerYuan': 10, // 历史字段仍在（接口形状不变），但**不得**再参与到账展示
      'qrCodes': [
        {'id': '1', 'channel': 'wechat', 'url': '/media/public/1'}
      ],
    });

    test('到账余额 = 付款金额（1 元 = 1 元），**不再乘比例、不再向下取整**', () {
      expect(RechargeRules.previewBalance(6), 6);
      expect(RechargeRules.previewBalance(38), 38);
      // 余额是金额不是"积分条数"：12.5 元到账必须是 12.5（旧口径 floor 会砍成 12）
      expect(RechargeRules.previewBalance(12.5), 12.5);
      expect(RechargeRules.previewBalance(12.55), 12.55);
      expect(RechargeRules.previewBalance(0), 0);
      expect(RechargeRules.previewBalance(-1), 0);
      // 比例字段即使配成 10 也不影响（防"界面按 10 倍撒谎"回归）
      final texts = RechargeCopy.previewLine(6);
      expect(texts, '付款 ¥6.00 → 到账 ¥6.00');
      expect(cfg.effectivePointsPerYuan, 10, reason: '字段仍解析（接口形状不变）');
    });

    test('金额格式化统一走 fmtMoney：¥ + 两位小数 + 千分位', () {
      expect(RechargeRules.formatYuan(6), '¥6.00');
      expect(RechargeRules.formatYuan(12.5), '¥12.50');
      expect(RechargeRules.formatYuan(12.55), '¥12.55');
      expect(RechargeRules.formatYuan(1234.5), '¥1,234.50');
      expect(fmtMoney(60), '¥60.00');
      expect(fmtMoney(125.4), '¥125.40');
    });

    test('到账预览文案（口径唯一出处）：付款 ¥6.00 → 到账 ¥6.00', () {
      expect(RechargeCopy.previewLine(6), '付款 ¥6.00 → 到账 ¥6.00');
      expect(RechargeCopy.previewLine(1234.5), '付款 ¥1,234.50 → 到账 ¥1,234.50');
      for (final w in RechargeCopy.forbiddenWords) {
        expect(RechargeCopy.previewLine(6).contains(w), isFalse, reason: '不得出现「$w」');
      }
    });
  });

  group('⑤ 我的充值申请（状态文案）', () {
    test('pending / granted / rejected 三种状态 + 驳回原因', () {
      final page = RechargeRequestPage.fromData({
        'list': [
          {'id': '1', 'amountYuan': 6, 'points': 60, 'status': 'pending', 'createdAt': '2026-10-06T10:00:00Z'},
          {'id': '2', 'amountYuan': 20, 'points': 200, 'status': 'granted', 'grantedAt': '2026-10-06T11:00:00Z'},
          {'id': '3', 'amountYuan': 38, 'points': 380, 'status': 'rejected', 'rejectReason': '未查到这笔转账'},
        ],
        'total': 3,
      });
      expect(page.total, 3);
      expect(page.list[0].statusText, '待审核');
      expect(page.list[1].statusText, '已到账');
      expect(page.list[2].statusText, '已驳回');
      expect(page.list[2].rejectReason, '未查到这笔转账');
      expect(page.pendingCount, 1);
      expect(page.list[2].isGranted, isFalse);
    });

    test('未知状态显示服务端原文，不猜', () {
      final item = RechargeRequestItem.fromJson(const {'id': '9', 'status': 'frozen', 'amountYuan': 6});
      expect(item.statusText, 'frozen');
    });

    test('裸数组也吃；凭证只给媒体 id 时走受限会话窄通道 /recharge/proof/:id', () {
      final page = RechargeRequestPage.fromData(const [
        {'id': '1', 'amountYuan': 6, 'status': 'pending', 'proofMediaId': 'p-1'},
      ]);
      // docs/03：受限会话白名单里没有 /media/*，凭证只能按"申请 id"取
      expect(page.list.single.proofUrl, endsWith('/recharge/proof/1'));
    });

    test('pendingCount / pendingLimitPerUser 来自服务端（客户端据此禁用提交按钮）', () {
      final page = RechargeRequestPage.fromData({
        'list': [
          {'id': '1', 'amountYuan': 6, 'status': 'pending'},
        ],
        'total': 1,
        'pendingCount': 3,
        'pendingLimitPerUser': 3,
      });
      expect(page.pendingCount, 3);
      expect(page.pendingLimitPerUser, 3);
      expect(page.atPendingLimit, isTrue);

      final ok = RechargeRequestPage.fromData({
        'list': const [],
        'pendingCount': 1,
        'pendingLimitPerUser': 3,
      });
      expect(ok.atPendingLimit, isFalse);
      // 服务端没下发上限时不自行判定（0 = 未知，不禁用）
      expect(RechargeRequestPage.fromData(const {'pendingCount': 9}).atPendingLimit, isFalse);
    });
  });

  group('⑥ 待审核列表解析', () {
    test('list 容器 + 顶层字段', () {
      final page = PendingRechargePage.fromData({
        'list': [
          {
            'id': '9',
            'nickname': '麻药',
            'uid': 'U8471209365',
            'amountYuan': 68,
            'points': 680,
            'proofUrl': 'https://cdn.example.com/p.png',
            'createdAt': '2026-10-06T12:34:00Z',
            'note': '微信转账',
          }
        ],
        'pendingCount': 1,
      });
      final r = page.list.single;
      expect(page.total, 1);
      expect(r.id, '9');
      expect(r.nickname, '麻药');
      expect(r.uid, 'U8471209365');
      expect(r.amountYuan, 68);
      expect(r.points, 680);
      expect(r.proofUrl, 'https://cdn.example.com/p.png');
      expect(r.note, '微信转账');
      expect(r.createdAt, isNotNull);
    });

    test('⑥ 待审核列表解析 items 容器 + user 嵌套 + 凭证窄通道', () {
      final page = PendingRechargePage.fromData({
        'items': [
          {
            'requestId': '10',
            'user': {'nickname': '雪山', 'uid': 'U10086'},
            'amount': 6,
            'pointsAmount': 60,
            'proofMediaId': 'pp',
          },
          {'amount': 999},
        ],
        'total': 5,
      });
      expect(page.list, hasLength(1));
      expect(page.total, 5);
      expect(page.list.single.nickname, '雪山');
      expect(page.list.single.uid, 'U10086');
      expect(page.list.single.proofUrl, endsWith('/recharge/proof/10'));
    });

    test('绑定受限会话：吃 docs/04 的 rechargeToken / rechargeRefreshToken', () {
      final s = RechargeAdminSession.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'rechargeToken': 'rt',
        'rechargeRefreshToken': 'rrt',
        'expiresIn': 43200,
      });
      expect(s.admin.displayName, '周砚');
      expect(s.hasDedicatedToken, isTrue);
      expect(s.token, 'rt');
      expect(s.refreshToken, 'rrt');
      expect(s.expiresIn, 43200);
    });

    test('空/异常数据不抛（空列表）', () {
      expect(PendingRechargePage.fromData(null).list, isEmpty);
      expect(PendingRechargePage.fromData('nope').list, isEmpty);
      expect(PendingRechargePage.fromData(const <String, dynamic>{}).total, 0);
    });
  });

  // =====================================================================================
  // ⑥-b 凭证取值优先级（2026-10-07 修「付款凭证图一直转圈」的核心口径）
  //
  // 受限会话（App 管理员态）的白名单**刻意不含 `/media/*`** → 服务端下发的
  // `/media/protected/:id`、乃至修好前缀的 `/api/v1/media/protected/:id` 在 App 里
  // 都拿不到（403 或历史 404）→ 界面表现就是图**永久转圈**。
  // 因此：**只要拿得到申请 id，一律走窄通道 `/recharge/proof/<requestId>`**。
  // =====================================================================================
  group('⑥-b 付款凭证取值优先级（有 requestId 必走窄通道）', () {
    test('有 requestId + 服务端给受保护媒体根路径（历史坏值 404）→ 仍走窄通道', () {
      final page = PendingRechargePage.fromData({
        'items': [
          {'id': '48', 'amount': 6, 'points': 60, 'proofMediaId': '201', 'proofUrl': '/media/protected/201'},
        ],
      });
      final r = page.list.single;
      expect(r.proofUrl, endsWith('/recharge/proof/48'));
      expect(r.proofUrl.contains('/media/protected/'), isFalse, reason: '不得采用坏掉的根路径');
      expect(r.proofUrl.contains('/media/'), isFalse);
    });

    test('有 requestId + 服务端给**修好后**的 /api/v1/media/protected/:id → 仍走窄通道（App 里那条 403）', () {
      final page = PendingRechargePage.fromData({
        'items': [
          {'id': '48', 'amount': 6, 'points': 60, 'proofMediaId': '201',
           'proofUrl': '/api/v1/media/protected/201'},
        ],
      });
      expect(page.list.single.proofUrl, endsWith('/recharge/proof/48'));
    });

    test('我的申请（RechargeRequestItem）与待审核（PendingRechargeRequest）**同一份口径**', () {
      final mine = RechargeRequestPage.fromData(const {
        'list': [
          {'id': '48', 'amountYuan': 6, 'points': 60, 'status': 'pending',
           'proofMediaId': '201', 'proofUrl': '/media/protected/201'},
        ],
      });
      final pending = PendingRechargePage.fromData(const {
        'list': [
          {'id': '48', 'amountYuan': 6, 'points': 60, 'status': 'pending',
           'proofMediaId': '201', 'proofUrl': '/media/protected/201'},
        ],
      });
      expect(mine.list.single.proofUrl, endsWith('/recharge/proof/48'));
      expect(pending.list.single.proofUrl, mine.list.single.proofUrl, reason: '列表与详情不许两处口径');
    });

    test('拿不到 requestId 才退回服务端给的相对路径', () {
      expect(resolveRechargeProof('/recharge/proof/9'), endsWith('/recharge/proof/9'));
      expect(resolveRechargeProof('/api/v1/media/protected/9'), endsWith('/api/v1/media/protected/9'));
    });

    test('既没有 requestId 也没有路径、只剩媒体 id → 拼真实受保护路由（含 /api/v1 前缀，不再是 404 根路径）', () {
      final u = resolveRechargeProof('201');
      expect(u, endsWith('/api/v1/media/protected/201'));
      expect(u.contains('/media/protected/201'), isTrue);
    });

    test('外部绝对 URL 原样采用（服务端显式指定的图床，不是通道选择）', () {
      expect(resolveRechargeProof('https://cdn.example.com/p.png', requestId: '48'),
          'https://cdn.example.com/p.png');
    });

    test('空值不抛：没有 requestId 也没有地址 → 空串（界面显示"这笔申请没有凭证地址"）', () {
      expect(resolveRechargeProof(''), '');
      expect(resolveRechargeProof('   ', requestId: ''), '');
    });

    test('图片鉴权头：无令牌 → 空 Map（公开图零影响）；有令牌 → Bearer', () {
      expect(proofImageHeaders(null), isEmpty);
      expect(proofImageHeaders(''), isEmpty);
      expect(proofImageHeaders('rt-1'), {'Authorization': 'Bearer rt-1'});
    });

    test('磁盘缓存键：公开图 = URL 本身（既有缓存不失效）；带令牌 → 按令牌分桶（不串图）', () {
      expect(imageCacheKey('/media/public/11'), '/media/public/11');
      expect(imageCacheKey('/media/public/11', headers: const {}), '/media/public/11');
      final a = imageCacheKey('/recharge/proof/48', headers: proofImageHeaders('rt-a'));
      final b = imageCacheKey('/recharge/proof/48', headers: proofImageHeaders('rt-b'));
      expect(a, isNot(b), reason: '不同审核员必须分桶，否则会看到上一个人的凭证');
      expect(a.startsWith('/recharge/proof/48'), isTrue);
    });
  });

  group('⑦ 合规文案（红线）', () {
    test('提交成功只有一句：「申请已提交，等待审核」', () {
      expect(RechargeCopy.submitted, '申请已提交，等待审核');
      expect(RechargeCopy.submitted.contains('支付成功'), isFalse);
      expect(RechargeCopy.submitted.contains('到账'), isFalse);
      expect(RechargeCopy.submitted, contains('等待审核'));
    });

    test('禁用词表覆盖"支付成功/自动到账/提现/兑换现金"（+旧单位「积分」）', () {
      for (final w in const ['支付成功', '自动到账', '提现', '兑换现金', '积分']) {
        expect(RechargeCopy.forbiddenWords, contains(w));
      }
    });

    test('渲染文案本身不含任何禁用词', () {
      final texts = [
        RechargeCopy.submitted,
        RechargeCopy.submittedDetail,
        RechargeCopy.scanHint,
        RechargeCopy.entryTitle,
        RechargeCopy.entrySubtitle,
      ];
      for (final t in texts) {
        for (final w in RechargeCopy.forbiddenWords) {
          expect(t.contains(w), isFalse, reason: '「$t」不该出现「$w」');
        }
      }
    });
  });

  group('⑧ RechargeEntry 版式（docs/21 + 设计定案 C 套）+ 管理员态常量', () {
    testWidgets('导航下方通栏条：图标 + 文字 + 右箭头，无渐变/无阴影/圆角 6/高 44/无 emoji', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RechargeEntry(onTap: () => taps++),
        ),
      ));

      expect(find.text(RechargeCopy.entryTitle), findsOneWidget);
      expect(find.text(RechargeCopy.entrySubtitle), findsOneWidget);
      expect(find.byIcon(AppIcon.coin), findsOneWidget);
      expect(find.byIcon(AppIcon.chevronRight), findsOneWidget);

      // 无渐变、无阴影（遍历这一小块里所有 BoxDecoration）
      final decorations = <BoxDecoration>[];
      for (final element in tester.elementList(find.byType(Container))) {
        final d = (element.widget as Container).decoration;
        if (d is BoxDecoration) decorations.add(d);
      }
      for (final element in tester.elementList(find.byType(DecoratedBox))) {
        final d = (element.widget as DecoratedBox).decoration;
        if (d is BoxDecoration) decorations.add(d);
      }
      expect(decorations, isNotEmpty);
      for (final d in decorations) {
        expect(d.gradient, isNull, reason: 'docs/21：禁渐变做主视觉');
        expect(d.boxShadow ?? const <BoxShadow>[], isEmpty, reason: 'docs/21：阴影只给弹层');
      }
      expect(decorations.any((d) => d.borderRadius == BorderRadius.circular(RechargeEntry.radius)), isTrue);

      // 审批定案的版式常量（测试与实现同源，避免两套数字）
      expect(RechargeEntry.radius, 6, reason: '定案：圆角 10 → 6（与三宫格同档）');
      expect(RechargeEntry.height, 44, reason: '定案：高度 56 → 44（首屏余量 −9dp → +3dp）');
      expect(tester.getSize(find.byKey(RechargeEntry.entryKey)).height, 44);
      expect(RechargeEntry.usesGradient, isFalse);
      expect(RechargeEntry.usesShadow, isFalse);

      // 无 emoji（含全角字符与中文都不算）
      for (final t in [RechargeCopy.entryTitle, RechargeCopy.entrySubtitle]) {
        expect(RechargeEntry.containsEmoji(t), isFalse);
      }
      expect(RechargeEntry.containsEmoji('💰'), isTrue);

      await tester.tap(find.byKey(RechargeEntry.entryKey));
      expect(taps, 1);
    });

    test('入口副文案 ≤14 字（定案选"缩短"而非"两行"），且不含合规禁用词', () {
      expect(RechargeCopy.entrySubtitle, '扫码付款，审核后发放余额');
      expect(RechargeCopy.entrySubtitle.length, lessThanOrEqualTo(RechargeEntry.subtitleMaxChars));
      for (final w in RechargeCopy.forbiddenWords) {
        expect(RechargeCopy.entrySubtitle.contains(w), isFalse);
      }
      // 两行写死行高 → 1.3× 系统字号下两行总高仍必须放得进 44dp
      final at13 = RechargeEntry.titleSize * 1.3 * RechargeEntry.titleLineHeight +
          RechargeEntry.subtitleSize * 1.3 * RechargeEntry.subtitleLineHeight +
          1;
      expect(at13, lessThan(RechargeEntry.height), reason: '1.3× 下两行必须放得进 44dp');
    });

    test('管理员态细带文案 = 当前身份 · 充值审核；黑名单同时吃打手态 22 词与管理员追加词', () {
      expect(RechargeAdminMeta.bandLabel, '充值审核');
      expect(RechargeAdminMeta.bandFullText, '当前身份充值审核');
      expect(RechargeAdminMeta.bottomNavItemCount, 0);
      expect(RechargeAdminMeta.abilities, ['看待审核列表', '发放余额', '驳回']);

      final list = RechargeAdminCleanliness.blacklist;
      for (final w in const ['下单', '找陪玩', '快速下单', '祁小山', '排行榜', '提现', '支付成功']) {
        expect(list, contains(w));
      }
      // 「余额」不再是管理员态禁用词（2026-10-09 起它就是全平台计价单位，本屏必须能说"发放余额"）
      expect(list, isNot(contains('余额')));
      expect(RechargeAdminCleanliness.violations(['待审核 1 笔', '给 麻药 发放 ¥680.00 余额']), isEmpty);
      expect(RechargeAdminCleanliness.violations(['去下单']), ['下单']);
    });

    testWidgets('AppIdentityBar 的管理员形态：同一枚 28dp 细带，只换身份串', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AppIdentityBar(
            label: AppIdentityBar.adminLabel,
            onSwitchBack: () {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(AppIdentityBar.leadLabel), findsOneWidget);
      expect(find.text('充值审核'), findsOneWidget);
      expect(find.text('切回老板'), findsOneWidget);
      final size = tester.getSize(find.byType(AppIdentityBar));
      expect(size.height, AppIdentityBar.height); // 28dp，与打手态同一条
    });
  });
}
