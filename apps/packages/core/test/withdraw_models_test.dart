import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// ============================================================================
/// 提现（打手端 + 管理员态审核）—— **模型 / 规则 / 文案 / 地址解析** 单测
/// ============================================================================
///
/// 契约（服务端并行实现，以代码为准）：
/// - `GET/POST /worker/withdraw/account`、`GET /worker/withdraw/config`、
///   `POST/GET /worker/withdraw/requests`；
/// - 管理员态：`GET /withdraw/requests`、`GET /withdraw/requests/:id`、
///   `GET /withdraw/proof/:id?kind=qr|payout`、`POST .../pay`、`POST .../reject`。
///
/// 这里钉死的是**客户端自己那部分**（服务端仍是唯一权威）：
/// ① 金额校验的三条中文口径与**优先级**；② 三状态标签；③ `¥` 两位小数；
/// ④ 受保护媒体的**最终绝对 URL 逐字相等**（漏 `/api/v1` = 图永远转圈，踩过）；
/// ⑤ 提现链路禁用词（含旧计价单位「积分」）与提现审核屏黑名单。
void main() {
  const cfg = WorkerWithdrawConfig(
    minAmount: 10,
    maxAmount: 2000,
    dailyLimit: 1,
    feeRate: 0,
    noticeText: '提现会在 1 个工作日内处理',
    balance: 320.5,
    todayUsed: 0,
  );

  group('① 金额校验（中文口径与服务端 400 逐字一致 + 优先级）', () {
    test('低于最低 → 「单笔提现不能低于 ¥10.00」（与服务端同一句）', () {
      expect(WorkerWithdrawRules.validateAmount(5, cfg), WorkerWithdrawCopy.errBelowMin(10));
      expect(WorkerWithdrawCopy.errBelowMin(10), '单笔提现不能低于 ¥10.00');
    });

    test('超过单笔上限 → 「单笔提现不能高于 ¥2,000.00」（即使同时也超过余额）', () {
      // 3000 > 上限 2000，也 > 余额 320.5：必须报"上限"（规则不允许），不是余额不足
      expect(WorkerWithdrawRules.validateAmount(3000, cfg), WorkerWithdrawCopy.errAboveMax(2000));
      expect(WorkerWithdrawCopy.errAboveMax(2000), '单笔提现不能高于 ¥2,000.00');
    });

    test('超过余额 → **含「余额不足」字样**且带当前余额（服务端同一句 + 可行动补充）', () {
      final msg = WorkerWithdrawRules.validateAmount(500, cfg);
      expect(msg, WorkerWithdrawCopy.errInsufficient(320.5));
      // 验收项点名要看到「余额不足」四个字（服务端原文是"不能超过当前余额（¥320.50）"）
      expect(msg, contains('余额不足'), reason: '文案必须让用户一眼看出是余额不够：$msg');
      expect(msg, startsWith('提现金额不能超过当前余额'));
      expect(msg!.contains('¥320.50'), isTrue, reason: '带上余额数字，用户知道能提多少');
    });

    test('边界与合法值', () {
      expect(WorkerWithdrawRules.validateAmount(10, cfg), isNull, reason: '刚好等于最低');
      expect(WorkerWithdrawRules.validateAmount(320.5, cfg), isNull, reason: '刚好等于余额（不算不足）');
      // 余额不够时"刚好等于上限"仍然报余额不足（上限是规则、余额是你自己的钱）
      expect(WorkerWithdrawRules.validateAmount(2000, cfg), contains('余额不足'));
      // 余额足够时上限内的最大值合法
      const rich = WorkerWithdrawConfig(
        minAmount: 10,
        maxAmount: 2000,
        dailyLimit: 3,
        feeRate: 0,
        noticeText: '',
        balance: 5000,
        todayUsed: 0,
      );
      expect(WorkerWithdrawRules.validateAmount(2000, rich), isNull, reason: '刚好等于上限');
      expect(WorkerWithdrawRules.validateAmount(2000.01, rich), WorkerWithdrawCopy.errAboveMax(2000));
      expect(WorkerWithdrawRules.validateAmount(null, cfg), WorkerWithdrawCopy.errBadAmount);
      expect(WorkerWithdrawRules.validateAmount(0, cfg), WorkerWithdrawCopy.errBadAmount);
      expect(WorkerWithdrawCopy.errBadAmount, '提现金额不正确');
    });

    test('金额解析：最多两位小数；空/非法/负数一律 null', () {
      expect(WorkerWithdrawRules.parseAmount('12'), 12);
      expect(WorkerWithdrawRules.parseAmount('12.5'), 12.5);
      expect(WorkerWithdrawRules.parseAmount('12.50'), 12.5);
      expect(WorkerWithdrawRules.parseAmount(' 8.8 '), 8.8, reason: '浮点 8.8×100 = 880.0000001 不许被误判非法');
      expect(WorkerWithdrawRules.parseAmount('12.345'), isNull);
      expect(WorkerWithdrawRules.parseAmount('abc'), isNull);
      expect(WorkerWithdrawRules.parseAmount('-5'), isNull);
      expect(WorkerWithdrawRules.parseAmount(''), isNull);
      // 空输入不报红（只在真的输了内容时才说话）
      expect(WorkerWithdrawRules.validateInput('', cfg), isNull);
      expect(WorkerWithdrawRules.validateInput('5', cfg), WorkerWithdrawCopy.errBelowMin(10));
      expect(WorkerWithdrawRules.validateInput('abc', cfg), WorkerWithdrawCopy.errBadAmount);
      expect(WorkerWithdrawRules.validateInput('1.234', cfg), WorkerWithdrawCopy.errTooManyDecimals);
    });

    test('手续费/实际到账（feeRate<=0 时不收）', () {
      expect(WorkerWithdrawRules.fee(100, cfg), 0);
      expect(WorkerWithdrawRules.netAmount(100, cfg), 100);
      const withFee = WorkerWithdrawConfig(
        minAmount: 10,
        maxAmount: 2000,
        dailyLimit: 3,
        feeRate: 0.01,
        noticeText: '',
        balance: 1000,
        todayUsed: 0,
      );
      expect(WorkerWithdrawRules.fee(100, withFee), 1);
      expect(WorkerWithdrawRules.netAmount(100, withFee), 99);
      // 金额一律 ¥ 两位小数
      expect(WorkerWithdrawRules.formatAmount(100), '¥100.00');
      expect(WorkerWithdrawRules.formatAmount(1234.5), '¥1,234.50');
    });

    test('今日剩余次数：dailyLimit<=0 = 不限；用完 → todayExhausted', () {
      expect(cfg.todayRemaining, 1);
      expect(cfg.todayLine, '今日还剩 1 次（每日 1 次）');
      const used = WorkerWithdrawConfig(
        minAmount: 10,
        maxAmount: 2000,
        dailyLimit: 1,
        feeRate: 0,
        noticeText: '',
        balance: 100,
        todayUsed: 1,
      );
      expect(used.todayRemaining, 0);
      expect(used.todayExhausted, isTrue);
      const unlimited = WorkerWithdrawConfig(
        minAmount: 10,
        maxAmount: 2000,
        dailyLimit: 0,
        feeRate: 0,
        noticeText: '',
        balance: 100,
        todayUsed: 9,
      );
      expect(unlimited.todayRemaining, -1);
      expect(unlimited.todayExhausted, isFalse);
      expect(unlimited.todayLine, '今日提现次数不限');
    });

    test('绑定表单：手机号 11 位 / 姓名 / 微信号 / 收款码必填', () {
      expect(WorkerWithdrawRules.isPhone('13800001234'), isTrue);
      expect(WorkerWithdrawRules.isPhone('1380000123'), isFalse);
      expect(WorkerWithdrawRules.isPhone('23800001234'), isFalse);
      expect(WorkerWithdrawRules.isRealName('张三'), isTrue);
      expect(WorkerWithdrawRules.isRealName('张'), isFalse);
      expect(WorkerWithdrawRules.isWechatId('zhangsan_88'), isTrue);
      expect(WorkerWithdrawRules.isWechatId('123456'), isFalse, reason: '微信规则：字母开头');

      expect(
        WorkerWithdrawRules.validateAccountForm(
            realName: '', phone: '', wechatId: '', hasQr: false),
        '请填写收款人姓名',
      );
      expect(
        WorkerWithdrawRules.validateAccountForm(
            realName: '张三', phone: '1380000', wechatId: 'abcdef', hasQr: true),
        '手机号请填 11 位数字（1 开头）',
      );
      expect(
        WorkerWithdrawRules.validateAccountForm(
            realName: '张三', phone: '13800001234', wechatId: 'abcdef', hasQr: false),
        '请上传微信收款码',
      );
      expect(
        WorkerWithdrawRules.validateAccountForm(
            realName: '张三', phone: '13800001234', wechatId: 'abcdef', hasQr: true),
        isNull,
      );
    });
  });

  group('② 三状态与金额口径', () {
    test('pending / paid / rejected → 处理中 / 已打款 / 已驳回', () {
      WorkerWithdrawRequest mk(String s) => WorkerWithdrawRequest.fromJson({'id': '1', 'amount': 10, 'status': s});
      expect(mk('pending').statusText, WorkerWithdrawCopy.statusPending);
      expect(mk('paid').statusText, WorkerWithdrawCopy.statusPaid);
      expect(mk('rejected').statusText, WorkerWithdrawCopy.statusRejected);
      expect(mk('pending').isPending, isTrue);
      expect(mk('paid').isPaid, isTrue);
      expect(mk('rejected').isRejected, isTrue);
      // 未知状态显示服务端原文，不猜（说错"钱到没到"是最坏的撒谎）
      expect(mk('frozen').statusText, 'frozen');
    });

    test('记录解析：金额/状态/申请时间/打款时间/驳回原因 + 余额快照', () {
      final r = WorkerWithdrawRequest.fromJson(const {
        'id': '103',
        'amount': 300,
        'status': 'rejected',
        'balanceAfter': 500.25,
        'appliedAt': '2026-10-11T09:12:00Z',
        'rejectReason': '收款信息与本人不一致',
      });
      expect(r.amount, 300);
      expect(r.balanceAfter, 500.25);
      expect(r.appliedAt, isNotNull);
      expect(r.rejectReason, '收款信息与本人不一致');
      expect(WorkerWithdrawRequestPage.fromData({'list': [const {'id': '1'}], 'total': 7}).total, 7);
      // 裸数组也吃
      expect(WorkerWithdrawRequestPage.fromData(const [
        {'id': 'a'},
        {'id': 'b'},
      ]).list.length, 2);
    });

    test('申请响应：balanceAfter 是**权威**余额（余额立即扣除）', () {
      final res = WorkerWithdrawApplyResult.fromJson(const {
        'id': '200',
        'amount': 120,
        'status': 'pending',
        'balanceAfter': 200.5,
        'appliedAt': '2026-10-11T10:00:00Z',
      });
      expect(res.id, '200');
      expect(res.amount, 120);
      expect(res.balanceAfter, 200.5);
      expect(res.status, 'pending');
    });

    test('管理员端列表字段：昵称/工号 + **accountMasked 脱敏段**（老形状仍要能解析）', () {
      final r = WorkerWithdrawRequest.fromJson(const {
        'id': '501',
        'workerNickname': '王野',
        'workerNo': 'W20260118',
        'amount': 120,
        'amountYuan': 120,
        'status': 'pending',
        'accountMasked': {'realName': '张*山', 'phone': '138****8888', 'wechatId': 'zha***88'},
        'hasAccount': true,
      });
      expect(r.workerLabel, '王野');
      expect(r.workerNo, 'W20260118');
      expect(r.amount, 120);
      // 服务端没下发 account（老形状/未更新）→ 逐字段回退到脱敏段，**不裂**
      expect(r.realName, '张*山');
      expect(r.phone, '138****8888');
      expect(r.wechatId, 'zha***88');
      expect(r.payeeLine, '张*山 · 138****8888 · zha***88');
      // 没昵称时退化到工号；都没有才退化到中文 ID
      expect(WorkerWithdrawRequest.fromJson(const {'id': '1', 'workerNo': 'W1'}).workerLabel, 'W1');
      expect(WorkerWithdrawRequest.fromJson(const {'id': '1', 'uid': 'U1'}).workerLabel, 'U1');
    });

    test('管理员端列表：`account` **完整**收款信息优先 + 逐字段回退 + payeeLine（列表直接可核对）', () {
      // ① 完整值（2026-10-11 起列表也下发 account）
      final full = WorkerWithdrawRequest.fromJson(const {
        'id': '45',
        'workerNickname': '阿岩不熬夜',
        'workerNo': 'W-20429',
        'amount': 10,
        'status': 'pending',
        'account': {'realName': '陈岩', 'phone': '13907315528', 'wechatId': 'ayan_chen_0917'},
        'accountMasked': {'realName': '陈*', 'phone': '139****5528', 'wechatId': 'ay****17'},
        'hasAccount': true,
      });
      expect(full.realName, '陈岩');
      expect(full.phone, '13907315528', reason: '列表口径 = 完整值（能看列表 = 有 withdraw:review = 审核人本人）');
      expect(full.payeeLine, '陈岩 · 13907315528 · ayan_chen_0917');
      expect(full.payeeLine.contains('*'), isFalse, reason: '拿到完整值时不许再出现打码字符');

      // ② 逐字段回退：account 只给了姓名 → 电话/微信回退脱敏值（不是整段二选一）
      final mixed = WorkerWithdrawRequest.fromJson(const {
        'id': '46',
        'amount': 30,
        'status': 'pending',
        'account': {'realName': '李墨白'},
        'accountMasked': {'realName': '李*', 'phone': '139****2233', 'wechatId': 'xue***02'},
      });
      expect(mixed.realName, '李墨白');
      expect(mixed.phone, '139****2233');
      expect(mixed.wechatId, 'xue***02');
      expect(mixed.payeeLine, '李墨白 · 139****2233 · xue***02');

      // ③ 三个字段一个都没有 → payeeLine 为空串（调用点据此整行不渲染，而不是留「· ·」）
      final none = WorkerWithdrawRequest.fromJson(const {'id': '47', 'amount': 5, 'status': 'pending'});
      expect(none.payeeLine, isEmpty);
    });

    test('详情字段：account 段给**完整**收款信息 + 打款记录（payerName/payoutNote/rejectedAt）', () {
      final r = WorkerWithdrawRequest.fromJson(const {
        'id': '501',
        'workerNickname': '王野',
        'workerNo': 'W20260118',
        'amount': 120,
        'status': 'paid',
        'appliedAt': '2026-10-11T09:12:00Z',
        'paidAt': '2026-10-11T10:40:00Z',
        'payerName': '周砚',
        'payoutNote': '微信转账 20261011',
        'payoutProofMediaId': 'proof-9',
        'account': {
          'realName': '张守山',
          'phone': '13800001234',
          'wechatId': 'zhangsan_88',
          'qrMediaId': 'qr-501',
          'qrUrl': '/api/v1/media/protected/qr-501',
        },
      });
      expect(r.realName, '张守山');
      expect(r.phone, '13800001234');
      expect(r.wechatId, 'zhangsan_88');
      expect(r.qrUrl, '/api/v1/media/protected/qr-501');
      expect(r.payerName, '周砚');
      expect(r.payoutNote, '微信转账 20261011');
      expect(r.paidAt, isNotNull);
      expect(r.isPaid, isTrue);
    });
  });

  group('③ 收款信息解析', () {
    test('bound 缺失时用"姓名+电话都有"兜底；qrUrl 支持相对路径与纯媒体 id', () {
      final a = WorkerWithdrawAccount.fromJson(const {'realName': '张*山', 'phone': '138****8888'});
      expect(a.usable, isTrue);
      expect(WorkerWithdrawAccount.fromJson(const {'bound': false}).usable, isFalse);
      expect(WorkerWithdrawAccount.fromJson(const {'qrUrl': '/media/public/3'}).hasQr, isTrue);
      expect(WorkerWithdrawAccount.fromJson(const {'qrUrl': 'abc-123'}).qrImageUrl,
          contains('/api/v1/media/protected/abc-123'));
      expect(WorkerWithdrawAccount.fromJson(const {}).hasQr, isFalse);
    });

    test('配置解析：minAmount/maxAmount/dailyLimit/noticeText/balance/todayUsed', () {
      final c = WorkerWithdrawConfig.fromJson(const {
        'minAmount': 10,
        'maxAmount': 2000,
        'dailyLimit': 1,
        'feeRate': 0,
        'noticeText': '提现会在 1 个工作日内处理',
        'balance': 320.5,
        'todayUsed': 0,
      });
      expect(c.minAmount, 10);
      expect(c.maxAmount, 2000);
      expect(c.dailyLimit, 1);
      expect(c.feeRate, 0);
      expect(c.noticeText, '提现会在 1 个工作日内处理');
      expect(c.balance, 320.5);
      expect(c.todayUsed, 0);
    });
  });

  group('④ 受保护媒体地址（最终绝对 URL 逐字相等 —— 漏 /api/v1 就是永远转圈）', () {
    test('收款码/打款凭证都走 /api/v1/withdraw/proof/:id?kind=...', () {
      expect(
        resolveWithdrawProof('qr-media-501', requestId: '501', kind: 'qr'),
        endsWith('/api/v1/withdraw/proof/501?kind=qr'),
      );
      expect(
        resolveWithdrawProof('', requestId: '501', kind: 'payout'),
        endsWith('/api/v1/withdraw/proof/501?kind=payout'),
      );
      // 服务端下发的绝对 URL 原样用（那是图床，不是通道选择）
      expect(resolveWithdrawProof('https://cdn.example.com/a.png', requestId: '501'), 'https://cdn.example.com/a.png');
      // 没有申请 id 时才退回受保护媒体通道
      expect(resolveWithdrawProof('media-9'), endsWith('/api/v1/media/protected/media-9'));
    });

    test('收款码解析走**受保护**通道（withdraw_qr 是 protected，不是 public）', () {
      // 服务端 getAccount() 下发的就是这条路径（原样保留，不改写）
      expect(resolveWithdrawMedia('/api/v1/media/protected/7'), endsWith('/api/v1/media/protected/7'));
      // 纯媒体 id 兜底：也必须走 protected（旧实现走 /media/public/* → 必然 404 → 图永远转圈）
      expect(resolveWithdrawMedia('abc'), endsWith('/api/v1/media/protected/abc'));
      expect(resolveWithdrawMedia('abc').contains('/media/public/'), isFalse,
          reason: 'withdraw_qr 是 protected，公开通道必然 404');
      expect(resolveWithdrawMedia('https://cdn.example.com/q.png'), 'https://cdn.example.com/q.png');
      expect(resolveWithdrawMedia(''), '');
    });

    test('带令牌取图：headers 只认 Authorization: Bearer', () {
      expect(withdrawImageHeaders('recharge-token'), {'Authorization': 'Bearer recharge-token'});
      expect(withdrawImageHeaders(null), isEmpty);
      expect(withdrawImageHeaders(''), isEmpty);
    });
  });

  group('⑤ 禁用词（合规红线 + 旧计价单位）', () {
    test('提现链路禁用词表含「积分」「支付成功」「自动到账」', () {
      for (final w in const ['积分', '支付成功', '自动到账', '充值']) {
        expect(WorkerWithdrawCopy.forbiddenWords, contains(w));
      }
      // 提现链路自己的文案一个字都不许命中
      final copy = [
        WorkerWithdrawCopy.applied,
        WorkerWithdrawCopy.appliedDetail,
        WorkerWithdrawCopy.needBind,
        WorkerWithdrawCopy.rebindNotice,
        WorkerWithdrawCopy.entryTitle,
        WorkerWithdrawCopy.entrySubtitle,
        WorkerWithdrawCopy.recordsEmpty,
        WorkerWithdrawCopy.recordsEmptyDetail,
        WorkerWithdrawCopy.payConfirmWarning,
        WorkerWithdrawCopy.rejectConfirmWarning,
        WorkerWithdrawCopy.forbidden,
      ];
      for (final t in copy) {
        for (final w in WorkerWithdrawCopy.forbiddenWords) {
          expect(t.contains(w), isFalse, reason: '「$t」不该出现「$w」');
        }
      }
    });

    test('充值链路（RechargeCopy）同样禁用旧计价单位「积分」（负向扫描的锚点）', () {
      expect(RechargeCopy.forbiddenWords, contains('积分'));
    });

    test('金额一律 ¥ 两位小数（全片不得出现"积分"字样）', () {
      expect(fmtMoney(10), '¥10.00');
      expect(WorkerWithdrawRules.formatAmount(320.5), '¥320.50');
      expect(fmtMoney(10).contains('积分'), isFalse);
    });

    test('两个必说文案逐字钉死（负责人硬要求）', () {
      expect(WorkerWithdrawCopy.payConfirmWarning, '确认后将标记为已打款，此操作不可撤销');
      expect(WorkerWithdrawCopy.rejectConfirmWarning, '余额将退回打手');
      expect(WorkerWithdrawCopy.needBind, '提现前需先绑定收款信息');
      expect(WorkerWithdrawCopy.goBind, '去绑定');
      expect(WorkerWithdrawCopy.entryTitle, '我的收益 / 提现');
      expect(WithdrawReviewDetailPage.payNeedProof, '请先上传支付记录截图');
      expect(WithdrawRejectSheet.reasonRequired, '请填写驳回原因，打手会在提现记录里看到它');
    });

    test('打款可否发起的**唯一判据**是"有凭证"（纯函数，页面与测试同源）', () {
      expect(WithdrawReviewDetailPage.canPay(proofMediaId: null, busy: false), isFalse);
      expect(WithdrawReviewDetailPage.canPay(proofMediaId: '', busy: false), isFalse);
      expect(WithdrawReviewDetailPage.canPay(proofMediaId: 'p-1', busy: false), isTrue);
      expect(WithdrawReviewDetailPage.canPay(proofMediaId: 'p-1', busy: true), isFalse, reason: 'busy 期间不许再发');
    });

    test('媒体用途类型 = 契约里的 withdraw_qr / withdraw_proof', () {
      expect(WithdrawMedia.qrType, 'withdraw_qr');
      expect(WithdrawMedia.payoutProofType, 'withdraw_proof');
    });

    test('提现审核屏黑名单：放行「提现」「打款」，禁用「积分」「充值」「钱包」「订单」', () {
      final list = WithdrawAdminCleanliness.blacklist;
      for (final w in const ['积分', '充值', '钱包', '订单', '排行榜', '找陪玩', '支付成功']) {
        expect(list, contains(w));
      }
      expect(list, isNot(contains('提现')), reason: '这一屏就是在看提现');
      expect(list, isNot(contains('打款')), reason: '审核员要做的动作就是打款');
      // 老板端 22 词照旧全在（管理员态同样不许出现老板端内容）
      expect(list.length, greaterThanOrEqualTo(22));
      expect(WithdrawAdminCleanliness.violations(['待处理 1 笔', '已打款 ¥120.00', '收款人 张守山']), isEmpty);
      expect(WithdrawAdminCleanliness.violations(['余额不足']), isEmpty, reason: '「余额」是全平台计价单位，不是禁用词');
      expect(WithdrawAdminCleanliness.violations(['去下单']), ['下单']);
    });

    test('充值审核那一张表**仍然**禁用「提现」（两段口径不许互相污染）', () {
      expect(RechargeAdminCleanliness.blacklist, contains('提现'));
      expect(RechargeAdminCleanliness.rechargeForbiddenWords, contains('提现'));
      expect(RechargeAdminCleanliness.rechargeForbiddenWords, contains('积分'));
    });

    test('管理员态分段常量（充值审核 / 提现审核，默认第一段 = 改动前的形态）', () {
      expect(RechargeAdminShell.tabLabels, ['充值审核', '提现审核']);
      expect(RechargeAdminShell.tabRecharge, 0);
      expect(RechargeAdminShell.tabWithdraw, 1);
      expect(RechargeAdminShell.withdrawTitle, '待处理提现');
    });
  });
}
