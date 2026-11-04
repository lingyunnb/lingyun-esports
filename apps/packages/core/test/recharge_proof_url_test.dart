import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// ============================================================================
/// 「最终绝对 URL」断言 —— 付款凭证图为什么必须这样测
/// ============================================================================
///
/// ## 教训（2026-10-07，真事故，别再犯）
///
/// 充值审核详情页的付款凭证图**一直转圈**，根因只有一处：客户端把凭证地址拼成了
/// `https://<host>/recharge/proof/48`，而服务端真实路由是
/// **`https://<host>/api/v1/recharge/proof/48`**（少了全局前缀 `/api/v1`）。
///
/// 而这个 bug **当时是有测试覆盖的** —— 但旧断言写的是：
///
/// ```dart
/// expect(r.proofUrl, endsWith('/recharge/proof/48'));   // ← 少了前缀照样绿
/// ```
///
/// `endsWith` / `contains` 只证明"尾巴还在"，**证明不了前缀对**；
/// 而"少一段前缀"恰恰是最常见、也最容易在链路上静默失败（404 / SPA HTML / 401）的错法。
///
/// ## 因此本文件的铁律
///
/// **① 只断言最终 URL 与期望字符串逐字相等（`equals`/`==`），禁止 `contains`/`endsWith`/`matches`。**
/// **② 期望值写成完整字面量**（`https://example.test/api/v1/recharge/proof/48`），
///    不写成 `'$host$path'` 之类的再拼一遍 —— 那样等于用同一段错误逻辑验证自己。
/// **③ 正反都测**：需要前缀的接口路径必须带前缀，公开媒体必须**不带**（防"一刀切加前缀"）。
///
/// ## 固定假 apiBase
///
/// `AppConfig.apiBase` 是运行期可注入的（[AppConfigRuntime.apply]，App 启动时地址下发也走它），
/// 所以这里固定成 `https://example.test/api/v1` —— 与真机/隧道环境解耦，结果可复现、逐字可断言。
/// `tearDownAll` 里 [AppConfigRuntime.reset] 还原，绝不给同进程其它测试留下污染。
void main() {
  const String fakeApiBase = 'https://example.test/api/v1';
  const String fakeWs = 'https://example.test';

  setUp(() {
    AppConfigRuntime.reset();
    AppConfigRuntime.apply(api: fakeApiBase, ws: fakeWs, from: 'test');
  });

  tearDownAll(AppConfigRuntime.reset);

  group('前置：假 apiBase 已生效（否则下面的断言没有意义）', () {
    test('AppConfig.apiBase 逐字等于注入值', () {
      expect(AppConfig.apiBase, fakeApiBase);
    });

    test('apiHost 是去掉 /api/v1 的主机部分', () {
      expect(AppConfig.apiHost, 'https://example.test');
    });
  });

  group('① resolveRechargeProof：最终 URL 逐字相等（本次事故的回归锁）', () {
    test('有 requestId → https://example.test/api/v1/recharge/proof/48（逐字，不许只有尾巴对）', () {
      // 服务端下发的 proofUrl 两种历史形态都喂一遍：结果必须**完全一样**。
      const String expected = 'https://example.test/api/v1/recharge/proof/48';
      expect(resolveRechargeProof('/media/protected/201', requestId: '48'), expected);
      expect(resolveRechargeProof('/api/v1/media/protected/201', requestId: '48'), expected);
      expect(resolveRechargeProof('', requestId: '48'), expected);
      expect(resolveRechargeProof('201', requestId: '48'), expected);
    });

    test('服务端真实形状（proofMediaId + proofUrl）走完整解析链，也是逐字相等', () {
      final page = PendingRechargePage.fromData(const {
        'items': [
          {
            'id': '48',
            'nickname': '麻药',
            'uid': 'U8471209365',
            'amountYuan': 68,
            'points': 680,
            'proofMediaId': '201',
            'proofUrl': '/api/v1/media/protected/201',
            'status': 'pending',
          },
        ],
      });
      expect(page.list.single.proofUrl, 'https://example.test/api/v1/recharge/proof/48');
    });

    test('「我的充值记录」与「待审核」两条解析链**逐字同源**（不许两处口径）', () {
      const row = {
        'id': '48',
        'amountYuan': 6,
        'points': 60,
        'status': 'pending',
        'proofMediaId': '201',
        'proofUrl': '/media/protected/201',
      };
      final mine = RechargeRequestPage.fromData(const {'list': [row]}).list.single.proofUrl;
      final pending = PendingRechargePage.fromData(const {'items': [row]}).list.single.proofUrl;
      expect(mine, 'https://example.test/api/v1/recharge/proof/48');
      expect(pending, mine);
    });
  });

  group('② 反向前缀差一位就必须变红（自证这条断言真的锁住了前缀）', () {
    test('少 /api/v1 的旧写法与期望值**不相等** —— 断言本身有辨别力', () {
      // 旧实现拼出来的就是这个字符串（少一段前缀）；如果它"恰好等于"期望值，
      // 说明期望值写错了（例如用了 endsWith 或自己又拼了一遍），这条会红。
      const String oldBroken = 'https://example.test/recharge/proof/48';
      const String expected = 'https://example.test/api/v1/recharge/proof/48';
      expect(oldBroken == expected, isFalse,
          reason: '期望值必须真的包含 /api/v1，否则回归锁形同虚设');
      expect(resolveRechargeProof('/x', requestId: '48'), isNot(oldBroken));
    });

    test('把前缀写成两个 /api/v1 也是错的（防"补前缀补两遍"）', () {
      expect(resolveRechargeProof('/x', requestId: '48'),
          isNot('https://example.test/api/v1/api/v1/recharge/proof/48'));
    });
  });

  group('③ 分支覆盖：相对路径 / 只有媒体 id / 外部绝对 URL', () {
    test('无 requestId + 服务端给**带前缀**的相对路径 → 逐字保留前缀', () {
      expect(resolveRechargeProof('/api/v1/media/protected/9'),
          'https://example.test/api/v1/media/protected/9');
    });

    test('无 requestId + 服务端给**不带前缀**的相对路径 → 按原样拼（服务端负责写对）', () {
      // 这条分支不做静默改写：路径就是服务端给的那条，前缀对错由服务端负责
      //（历史上服务端给过坏值 `/media/protected/:id`，那属于服务端 bug，已在 media.service 修掉）。
      expect(resolveRechargeProof('/recharge/proof/9'), 'https://example.test/recharge/proof/9');
    });

    test('既没有 requestId 也没有路径、只剩媒体 id → /api/v1/media/protected/<id>（逐字）', () {
      expect(resolveRechargeProof('201'), 'https://example.test/api/v1/media/protected/201');
    });

    test('外部绝对 URL 原样采用（图床地址不是通道选择，一个字符都不许改）', () {
      expect(resolveRechargeProof('https://cdn.example.com/p.png', requestId: '48'),
          'https://cdn.example.com/p.png');
    });

    test('空值不抛：空串进空串出', () {
      expect(resolveRechargeProof(''), '');
      expect(resolveRechargeProof('   ', requestId: ''), '');
      expect(resolveRechargeProof(''), '');
    });
  });

  group('④ 公开媒体对照：绝不能被"一刀切加前缀"弄坏', () {
    test('resolveMediaUrl 对 /media/public/3 → https://example.test/media/public/3（不带 /api/v1）', () {
      expect(AppConfig.resolveMediaUrl('/media/public/3'), 'https://example.test/media/public/3');
    });

    test('收款码（公开媒体）逐字相等；纯 id 也走公开通道', () {
      expect(resolveRechargeMedia('/media/public/3'), 'https://example.test/media/public/3');
      expect(resolveRechargeMedia('3'), 'https://example.test/media/public/3');
      expect(resolveRechargeMedia('https://cdn.example.com/qr.png'), 'https://cdn.example.com/qr.png');
    });

    test('两类前缀**方向相反**：接口路径要前缀、公开媒体不要 —— 同一次调用里同时成立', () {
      expect(AppConfig.resolveMediaUrl('/api/v1/media/protected/201'),
          'https://example.test/api/v1/media/protected/201');
      expect(AppConfig.resolveMediaUrl('/media/public/201'),
          'https://example.test/media/public/201');
    });
  });

  group('⑤ 前缀规则本身（resolveMediaUrl / apiHostFor）', () {
    test('带前缀的接口路径：前缀保留、主机是 apiBase 去前缀', () {
      expect(AppConfig.resolveMediaUrl('/api/v1/public/app-versions/download/99'),
          'https://example.test/api/v1/public/app-versions/download/99');
      expect(AppConfig.apiHostFor('/api/v1/recharge/proof/1'), 'https://example.test');
    });

    test('不带前缀的根路径：主机 = apiBase 剥掉结尾 /api/v1（公开媒体必须落在 /api/v1 之外）', () {
      expect(AppConfig.apiHostFor('/media/public/1'), 'https://example.test');
      expect(AppConfig.apiHostFor('/site/'), 'https://example.test');
    });

    test('恰好等于 /api/v1 与 /api/v1/ 也算带前缀（不产生 // 双斜杠）', () {
      expect(AppConfig.resolveMediaUrl('/api/v1'), 'https://example.test/api/v1');
      expect(AppConfig.resolveMediaUrl('/api/v1/'), 'https://example.test/api/v1/');
    });

    test('apiBase 不含 /api/v1 时保持旧行为（宁可不改，也不猜）', () {
      AppConfigRuntime.apply(api: 'https://direct.example.com', ws: fakeWs, from: 'test');
      expect(AppConfig.resolveMediaUrl('/api/v1/media/protected/9'),
          'https://direct.example.com/api/v1/media/protected/9');
      expect(AppConfig.resolveMediaUrl('/media/public/9'), 'https://direct.example.com/media/public/9');
    });

    test('apiBase 带结尾斜杠也不产生双斜杠', () {
      AppConfigRuntime.apply(api: 'https://example.test/api/v1/', ws: fakeWs, from: 'test');
      expect(AppConfig.resolveMediaUrl('/api/v1/media/protected/9'),
          'https://example.test/api/v1/media/protected/9');
      expect(AppConfig.resolveMediaUrl('/media/public/9'), 'https://example.test/media/public/9');
    });

    test('绝对 URL 与空串原样返回（一个字符都不动）', () {
      expect(AppConfig.resolveMediaUrl(''), '');
      expect(AppConfig.resolveMediaUrl('http://a.test/x.png'), 'http://a.test/x.png');
      expect(AppConfig.resolveMediaUrl('https://a.test/x.png'), 'https://a.test/x.png');
    });
  });
}
