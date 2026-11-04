library;

import '../config/app_config.dart';
import '../identity/worker_shell.dart' show IdentityWorkerCleanliness;
import '../util/idempotency.dart';
import '../recharge/recharge_models.dart' show RechargeRules, authImageHeaders;

/// ============================================================================
/// 打手提现（收款信息 / 提现申请 / 记录）+ App 内管理员态「提现审核」
///   —— 负责人 2026-10-11 口径（计价单位 = **余额**，1 元 = 1 元）
/// ============================================================================
///
/// ## 契约（服务端由另一批并行实现，以代码为准；未落盘时按本节实现界面与状态机）
/// 打手端（companion 打手态可调 `/worker/*`）：
/// | 接口 | 形状 |
/// |---|---|
/// | `GET /worker/withdraw/account` | `{bound, realName, phone, wechatId, qrUrl, updatedAt}` |
/// | `POST /worker/withdraw/account` | body `{realName, phone, wechatId, qrMediaId}` |
/// | `GET /worker/withdraw/config` | `{minAmount, maxAmount, dailyLimit, feeRate, noticeText, balance, todayUsed}` |
/// | `POST /worker/withdraw/requests` | body `{amount}` → `{id, amount, status, balanceAfter, appliedAt}` |
/// | `GET /worker/withdraw/requests?page=` | 列表（金额/状态/申请时间/打款时间/驳回原因） |
///
/// 管理员态（受限会话 `kind='recharge'`）：
/// | 接口 | 形状 |
/// |---|---|
/// | `GET /withdraw/requests?status=&page=` | 待审核列表（打手昵称/工号/**完整收款信息 `account`**/金额/状态/申请时间） |
/// | `GET /withdraw/requests/:id` | 详情（完整姓名/电话/微信号 + 收款码 + 打款记录区） |
/// | `GET /withdraw/proof/:id?kind=qr\|payout` | **受保护媒体**：必须带受限会话令牌取图 |
/// | `POST /withdraw/requests/:id/pay` | body `{proofMediaId, note?}` |
/// | `POST /withdraw/requests/:id/reject` | body `{reason}` |
///
/// 服务端中文错误（**原样透传，客户端不改字**）：
/// `请先绑定收款信息` / `低于最低提现金额` / `超过单笔上限` / `余额不足` /
/// `今日提现次数已达上限` / `你有一笔提现正在处理中`。
///
/// ## 字段解析为什么"宽容"
/// 契约由并行任务实现，真实字段名可能与任务书有出入 → 所有 `fromJson` 走**多候选键名**
/// （`amount` / `amountYuan` / `yuan`…），解析不到就退化为"没有这个能力"
/// （如 `minAmount` 缺失 → 不显示下限，而不是编一个默认值把关卡设在用户头上）。

/// 收款信息（`GET /worker/withdraw/account`）
///
/// [realName] / [phone] 在打手端一律显示**服务端下发的脱敏值**（`张*山` / `138****8888`）；
/// 完整值只出现在**管理员态详情**里（那是一次人工打款必须看到的核对信息）。
class WorkerWithdrawAccount {
  const WorkerWithdrawAccount({
    required this.bound,
    required this.realName,
    required this.phone,
    required this.wechatId,
    required this.qrUrl,
    required this.updatedAt,
  });

  /// 是否已绑定（服务端口径；`bound` 缺失时按"四个字段里有没有内容"兜底）
  final bool bound;

  /// 真实姓名（打手端 = 脱敏值）
  final String realName;

  /// 手机号（打手端 = 脱敏值）
  final String phone;

  /// 微信号（不脱敏：打款时对方要按它加好友/转账）
  final String wechatId;

  /// 收款码图片地址（服务端下发；`withdraw_qr` 是 **public** 媒体）
  final String qrUrl;

  final DateTime? updatedAt;

  static const empty = WorkerWithdrawAccount(
    bound: false,
    realName: '',
    phone: '',
    wechatId: '',
    qrUrl: '',
    updatedAt: null,
  );

  /// 能喂给 `CachedNetImage` 的绝对地址（空 = 服务端没下发图）
  String get qrImageUrl => resolveWithdrawMedia(qrUrl);

  bool get hasQr => qrImageUrl.isNotEmpty;

  /// 已绑定且能看出绑的是谁（兜底 `bound` 缺失的情况）
  bool get usable => bound || (realName.isNotEmpty && phone.isNotEmpty);

  factory WorkerWithdrawAccount.fromJson(Map<String, dynamic> json) {
    final realName = _str(json, const ['realName', 'name', 'realname', 'trueName']) ?? '';
    final phone = _str(json, const ['phone', 'mobile', 'phoneNumber', 'tel']) ?? '';
    return WorkerWithdrawAccount(
      bound: _boolOr(json, const ['bound', 'isBound', 'boundFlag'], realName.isNotEmpty && phone.isNotEmpty),
      realName: realName,
      phone: phone,
      wechatId: _str(json, const ['wechatId', 'wechat', 'wxId', 'wxAccount', 'weixin']) ?? '',
      qrUrl: _str(json, const ['qrUrl', 'qrCodeUrl', 'qr', 'qrMediaId', 'qrImage']) ?? '',
      updatedAt: _time(json, const ['updatedAt', 'updateTime', 'boundAt', 'createTime', 'createdAt']),
    );
  }
}

/// 提现配置（`GET /worker/withdraw/config`）—— **口径全部来自服务端**，客户端不写死数字
class WorkerWithdrawConfig {
  const WorkerWithdrawConfig({
    required this.minAmount,
    required this.maxAmount,
    required this.dailyLimit,
    required this.feeRate,
    required this.noticeText,
    required this.balance,
    required this.todayUsed,
  });

  /// 单笔最低（元）
  final num minAmount;

  /// 单笔上限（元）；<=0 视为不限
  final num maxAmount;

  /// 每日可提现次数；<=0 视为不限
  final int dailyLimit;

  /// 手续费率（0.01 = 1%）；<=0 = 免手续费
  final num feeRate;

  /// 说明文案（**服务端下发**；为空时不编造规则）
  final String noticeText;

  /// 可用余额（元）
  final num balance;

  /// 今日已提现次数
  final int todayUsed;

  static const empty = WorkerWithdrawConfig(
    minAmount: 0,
    maxAmount: 0,
    dailyLimit: 0,
    feeRate: 0,
    noticeText: '',
    balance: 0,
    todayUsed: 0,
  );

  /// 今日剩余次数（`dailyLimit<=0` → -1 = 不限）
  int get todayRemaining => dailyLimit <= 0 ? -1 : (dailyLimit - todayUsed).clamp(0, dailyLimit);

  /// 今日次数是否已用完（服务端仍是权威：客户端只做"少跑一次必然失败的提交"）
  bool get todayExhausted => dailyLimit > 0 && todayUsed >= dailyLimit;

  /// 今日剩余次数的中文事实行（不限时不显示数字，避免"剩余 ∞ 次"这种怪话）
  String get todayLine =>
      dailyLimit <= 0 ? '今日提现次数不限' : '今日还剩 $todayRemaining 次（每日 $dailyLimit 次）';

  factory WorkerWithdrawConfig.fromJson(Map<String, dynamic> json) => WorkerWithdrawConfig(
        minAmount: _num(json, const ['minAmount', 'min', 'minYuan']) ?? 0,
        maxAmount: _num(json, const ['maxAmount', 'max', 'maxYuan']) ?? 0,
        dailyLimit: (_num(json, const ['dailyLimit', 'dailyMax', 'limitPerDay', 'dailyTimes']) ?? 0).toInt(),
        feeRate: _num(json, const ['feeRate', 'fee', 'rate']) ?? 0,
        noticeText: _str(json, const ['noticeText', 'notice', 'tips', 'description']) ?? '',
        balance: _num(json, const ['balance', 'available', 'availableBalance']) ?? 0,
        todayUsed: (_num(json, const ['todayUsed', 'usedToday', 'todayCount', 'usedCount']) ?? 0).toInt(),
      );
}

/// 一条提现申请（打手端记录 / 管理员端列表共用）
class WorkerWithdrawRequest {
  const WorkerWithdrawRequest({
    required this.id,
    required this.amount,
    required this.status,
    required this.balanceAfter,
    required this.appliedAt,
    required this.paidAt,
    required this.rejectReason,
    required this.nickname,
    required this.workerNo,
    required this.uid,
    required this.realName,
    required this.phone,
    required this.wechatId,
    required this.qrUrl,
    required this.payoutProofUrl,
    required this.payoutNote,
    this.rejectedAt,
    this.payerName = '',
  });

  final String id;

  /// 提现金额（元）
  final num amount;

  /// 状态：`pending`（处理中）/ `paid`（已打款）/ `rejected`（已驳回）
  final String status;

  /// 申请后余额快照（服务端下发；为 null 时界面不显示这一行）
  final num? balanceAfter;

  /// 申请时间
  final DateTime? appliedAt;

  /// 打款时间
  final DateTime? paidAt;

  /// 驳回原因
  final String rejectReason;

  // ---- 管理员端字段（打手端列表不下发时为空）----
  final String nickname;
  final String workerNo;
  final String uid;
  final String realName;
  final String phone;
  final String wechatId;

  /// 收款码（管理员详情的大图；受保护通道，走 [proofUrl] 取）
  final String qrUrl;

  /// 打款凭证（管理员详情「打款记录区」）
  final String payoutProofUrl;

  /// 打款备注
  final String payoutNote;

  /// 驳回时间（服务端 `rejectedAt`）
  final DateTime? rejectedAt;

  /// 打款人昵称（服务端 `payerName`；审计事实行用）
  final String payerName;

  bool get isPending => status == 'pending' || status == 'processing' || status == 'reviewing';
  bool get isPaid => status == 'paid' || status == 'paid_out' || status == 'done' || status == 'finished';
  bool get isRejected => status == 'rejected' || status == 'refused';

  /// 状态中文（**只翻译已知状态**；未知状态显示服务端原文，不猜）
  String get statusText {
    if (isPending) return '处理中';
    if (isPaid) return '已打款';
    if (isRejected) return '已驳回';
    return status.isEmpty ? '—' : status;
  }

  /// 列表里显示的打手身份（昵称优先，其次工号）
  String get workerLabel {
    if (nickname.isNotEmpty) return nickname;
    if (workerNo.isNotEmpty) return workerNo;
    return uid.isEmpty ? '（无昵称）' : uid;
  }

  /// 收款信息一行：`姓名 · 电话 · 微信号`（**完整**值优先，逐字段回退）。
  ///
  /// 口径（负责人 2026-10-11）：**列表与详情都给完整收款信息** —— 能看列表 = 持有
  /// `withdraw:review` = **审核人本人**，向他隐藏只会让"核对收款信息"必须点进详情；
  /// 权限点一个没加。服务端列表行下发 `account:{realName,phone,wechatId}`，**保留**
  /// `accountMasked` 做兼容 → [fromJson] 已经是"完整优先、逐字段回退脱敏"，这里只负责拼一行。
  /// **审计日志与站内通知仍只记脱敏值**（服务端负责，客户端不参与）。
  ///
  /// 空串 = 三个字段服务端一个都没给（调用点据此整行不渲染，而不是留一行孤零零的分隔点）。
  String get payeeLine => [realName, phone, wechatId]
      .map((x) => x.trim())
      .where((x) => x.isNotEmpty)
      .join(' · ');

  factory WorkerWithdrawRequest.fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? json['requestId'] ?? ''}';
    final worker = json['worker'];
    final wm = worker is Map ? worker.cast<String, dynamic>() : const <String, dynamic>{};
    /**
     * 收款信息：**完整值优先、逐字段回退**。
     *
     * `detail()` 给 `account:{realName,phone,wechatId}`；**列表 `reviewList()` 现在也给同名同形的
     * `account`（2026-10-11 起，列表直接可核对）**，同时**保留** `accountMasked` 做兼容 → 因此
     * 每个字段都按 `顶层平铺 → account（完整） → accountMasked（脱敏）` 取值：
     * 服务端没更新（或某个字段缺失）时自动回退，页面不会裂。
     * （字段名按服务端实际下发对齐：`workerNickname` / `amount` / `account` / `accountMasked`。）
     */
    final account = json['account'];
    final am = account is Map ? account.cast<String, dynamic>() : const <String, dynamic>{};
    final masked = json['accountMasked'];
    final mm = masked is Map ? masked.cast<String, dynamic>() : const <String, dynamic>{};
    return WorkerWithdrawRequest(
      id: id,
      amount: _num(json, const ['amount', 'amountYuan', 'yuan', 'withdrawAmount']) ?? 0,
      status: '${json['status'] ?? ''}',
      balanceAfter: _num(json, const ['balanceAfter', 'balance_after']),
      appliedAt: _time(json, const ['appliedAt', 'createdAt', 'applyTime', 'createTime', 'submittedAt']),
      paidAt: _time(json, const ['paidAt', 'payTime', 'paidTime', 'remittedAt']),
      rejectReason: _str(json, const ['rejectReason', 'reason', 'rejectRemark', 'refuseReason']) ?? '',
      nickname: _str(json, const ['workerNickname', 'nickname', 'userNickname', 'name']) ??
          _str(wm, const ['nickname', 'name']) ??
          '',
      workerNo: _str(json, const ['workerNo', 'workerNumber', 'no', 'jobNo']) ??
          _str(wm, const ['workerNo', 'workerNumber', 'no']) ??
          '',
      uid: _str(json, const ['uid', 'workerUid', 'chineseId', 'displayId']) ??
          _str(wm, const ['uid', 'chineseId']) ??
          '',
      realName: _str(json, const ['realName', 'trueName', 'accountName']) ??
          _str(am, const ['realName', 'trueName']) ??
          _str(mm, const ['realName']) ??
          '',
      phone: _str(json, const ['phone', 'mobile', 'phoneNumber']) ??
          _str(am, const ['phone', 'mobile']) ??
          _str(mm, const ['phone']) ??
          '',
      wechatId: _str(json, const ['wechatId', 'wechat', 'wxId']) ??
          _str(am, const ['wechatId', 'wechat']) ??
          _str(mm, const ['wechatId']) ??
          '',
      qrUrl: _str(json, const ['qrUrl', 'qrCodeUrl', 'qrMediaId', 'qr']) ??
          _str(am, const ['qrUrl', 'qrMediaId', 'qr']) ??
          '',
      payoutProofUrl:
          _str(json, const ['payoutProofUrl', 'payProofUrl', 'payoutMediaId', 'payMediaId']) ?? '',
      payoutNote: _str(json, const ['payoutNote', 'payNote', 'note', 'remark']) ?? '',
      rejectedAt: _time(json, const ['rejectedAt', 'refuseTime']),
      payerName: _str(json, const ['payerName', 'paidByName']) ?? '',
    );
  }
}

/// 一页提现申请（打手端记录 / 管理员端待审列表共用容器解析）
///
/// ⚠️ 名字里带 `Request`：`WorkerWithdrawPage` 这个名字已经被**提现申请页那个 widget** 占了
/// （两者在 `fish_core.dart` 里同时导出，重名会让所有调用点变成 `ambiguous_import`）。
class WorkerWithdrawRequestPage {
  const WorkerWithdrawRequestPage({required this.list, required this.total});

  final List<WorkerWithdrawRequest> list;
  final int total;

  static const empty = WorkerWithdrawRequestPage(list: [], total: 0);

  factory WorkerWithdrawRequestPage.fromData(Object? data) {
    if (data is List) {
      final list = data
          .whereType<Map>()
          .map((e) => WorkerWithdrawRequest.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
      return WorkerWithdrawRequestPage(list: list, total: list.length);
    }
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final raw = _list(m, const ['list', 'items', 'records', 'rows', 'requests']);
      final list = raw
          .whereType<Map>()
          .map((e) => WorkerWithdrawRequest.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
      return WorkerWithdrawRequestPage(
        list: list,
        total: (_num(m, const ['total', 'count', 'pendingCount']) ?? list.length).toInt(),
      );
    }
    return empty;
  }
}

/// `POST /worker/withdraw/requests` 的响应：`{id, amount, status, balanceAfter, appliedAt}`
///
/// [balanceAfter] 是**申请后服务端算出的余额**（余额立即扣除）——它同时是
/// 「余额刷新一致性」的权威值：页面拿它先就地更新，再去回源校验。
class WorkerWithdrawApplyResult {
  const WorkerWithdrawApplyResult({
    required this.id,
    required this.amount,
    required this.status,
    required this.balanceAfter,
    required this.appliedAt,
  });

  final String id;
  final num amount;
  final String status;
  final num? balanceAfter;
  final DateTime? appliedAt;

  factory WorkerWithdrawApplyResult.fromJson(Map<String, dynamic> json) => WorkerWithdrawApplyResult(
        id: '${json['id'] ?? json['requestId'] ?? ''}',
        amount: _num(json, const ['amount', 'amountYuan', 'yuan']) ?? 0,
        status: '${json['status'] ?? 'pending'}',
        balanceAfter: _num(json, const ['balanceAfter', 'balance_after', 'balance']),
        appliedAt: _time(json, const ['appliedAt', 'createdAt', 'createTime']),
      );
}

/// ============================================================================
/// 提现规则（**纯函数，可单测**；页面只调这里，不自己算）
/// ============================================================================
class WorkerWithdrawRules {
  WorkerWithdrawRules._();

  /// 金额解析：接受 `12` / `12.5` / `12.50`；非法（<=0 / 三位小数 / 非数字）返回 null
  static num? parseAmount(String raw) {
    final t = raw.trim().replaceAll('　', '');
    if (t.isEmpty) return null;
    final v = num.tryParse(t);
    if (v == null || v <= 0) return null;
    if (!RechargeRules.hasAtMostTwoDecimals(v)) return null;
    return v;
  }

  /// 金额校验（**顺序与服务端逐条同序**：格式 → 最低 → 上限 → 余额）
  ///
  /// ## 文案与服务端 400 **逐字一致**（服务端已落盘，见 `withdraw.service.ts#createRequest`）
  /// | 服务端 | 客户端 |
  /// |---|---|
  /// | `提现金额不正确` | 同 |
  /// | `提现金额最多保留 2 位小数` | 同 |
  /// | `请先绑定收款信息` | 同 |
  /// | `单笔提现不能低于 ¥10.00` | 同（**带上配置里的金额**） |
  /// | `单笔提现不能高于 ¥2,000.00` | 同 |
  /// | `提现金额不能超过当前余额（¥320.50）` | 同 |
  ///
  /// **本地校验只为少跑一次必然失败的请求**，服务端仍是唯一权威（400 中文原样透传）。
  /// 文案同源的价值：用户不会遇到"本地说一套、服务端说另一套"。
  ///
  /// ## 顺序为什么是"先最低/上限、后余额"
  /// 输 3000 时最该看到的是"不能高于 ¥2,000.00"（**规则不允许**），而不是余额不足
  /// ——后者会让人以为"钱够了就能提 3000"，去凑钱再试一次。反之余额只有 320 想提 500 时，
  /// 必须说"不能超过当前余额"（那才是他能自己解决的那件事：少提一点）。
  static String? validateAmount(num? amount, WorkerWithdrawConfig cfg) {
    if (amount == null || amount <= 0) return WorkerWithdrawCopy.errBadAmount;
    if (!RechargeRules.hasAtMostTwoDecimals(amount)) return WorkerWithdrawCopy.errTooManyDecimals;
    if (cfg.minAmount > 0 && amount < cfg.minAmount) {
      return WorkerWithdrawCopy.errBelowMin(cfg.minAmount);
    }
    if (cfg.maxAmount > 0 && amount > cfg.maxAmount) {
      return WorkerWithdrawCopy.errAboveMax(cfg.maxAmount);
    }
    if (amount > cfg.balance) return WorkerWithdrawCopy.errInsufficient(cfg.balance);
    return null;
  }

  /// 输入框实时校验（**空输入不报红**，只有真的输了内容才说话）
  static String? validateInput(String raw, WorkerWithdrawConfig cfg) {
    if (raw.trim().isEmpty) return null;
    final v = parseAmount(raw);
    // 解析失败分两种说法：格式错 vs 小数位过多（与服务端两条 400 对齐）
    if (v == null) {
      final t = raw.trim().replaceAll('　', '');
      final n = num.tryParse(t);
      if (n != null && n > 0) return WorkerWithdrawCopy.errTooManyDecimals;
      return WorkerWithdrawCopy.errBadAmount;
    }
    return validateAmount(v, cfg);
  }

  /// 手续费（元）：`feeRate <= 0` → 0；四舍五入到分
  static num fee(num amount, WorkerWithdrawConfig cfg) {
    if (cfg.feeRate <= 0 || amount <= 0) return 0;
    final v = amount * cfg.feeRate;
    return (v * 100).roundToDouble() / 100;
  }

  /// 实际到账（元）= 提现金额 − 手续费
  static num netAmount(num amount, WorkerWithdrawConfig cfg) {
    final f = fee(amount, cfg);
    final net = amount - f;
    return net > 0 ? net : 0;
  }

  /// 金额展示：**统一出口**（`¥` + 千分位 + 两位小数）
  static String formatAmount(num v) => fmtMoney(v);

  /// 手机号（11 位，1 开头）—— 绑定表单的本地校验
  static bool isPhone(String raw) => RegExp(r'^1\d{10}$').hasMatch(raw.trim());

  /// 姓名：2–20 字，中文/字母/·（与"收款人姓名"的现实取值一致）
  static bool isRealName(String raw) {
    final t = raw.trim();
    if (t.length < 2 || (t.length > 20)) return false;
    return RegExp(r'^[\u4e00-\u9fa5A-Za-z·\u00b7]{2,20}$').hasMatch(t);
  }

  /// 微信号：6–20 位，字母打头（微信自身的规则范围；过宽的规则会让打款失败）
  static bool isWechatId(String raw) => RegExp(r'^[A-Za-z][A-Za-z0-9_-]{5,19}$').hasMatch(raw.trim());

  /// 绑定表单校验 → 中文错误（null = 全部通过）
  ///
  /// 顺序 = 表单从上到下的顺序：第一个错就是用户眼下要改的那一格。
  static String? validateAccountForm({
    required String realName,
    required String phone,
    required String wechatId,
    required bool hasQr,
  }) {
    if (realName.trim().isEmpty) return '请填写收款人姓名';
    if (!isRealName(realName)) return '姓名请填 2–20 个中文或字母';
    if (phone.trim().isEmpty) return '请填写手机号';
    if (!isPhone(phone)) return '手机号请填 11 位数字（1 开头）';
    if (wechatId.trim().isEmpty) return '请填写微信号';
    if (!isWechatId(wechatId)) return '微信号请填 6–20 位，字母开头';
    if (!hasQr) return '请上传微信收款码';
    return null;
  }
}

/// ============================================================================
/// 文案常量（提现链路唯一出处：页面、测试与黑名单引用同一份）
/// ============================================================================
class WorkerWithdrawCopy {
  WorkerWithdrawCopy._();

  /// 「我的」页入口标题（提现放在「我的」里，见任务书）
  static const String entryTitle = '我的收益 / 提现';

  /// 入口副标题（说清这一页能干什么，不承诺任何时间）
  static const String entrySubtitle = '看余额、绑定收款信息、申请提现';

  /// 未绑定收款信息时的显著提示（提现页与绑定页共用同一句）
  static const String needBind = '提现前需先绑定收款信息';

  /// 「去绑定」按钮
  static const String goBind = '去绑定';

  /// 已绑定时的说明（提醒换绑要谨慎）
  static const String boundHint = '打款会转到这条收款信息';

  /// 换绑提示（**明确说清影响面**）
  static const String rebindNotice = '换绑后新收款信息用于后续打款，正在处理中的提现仍按原信息打款';

  /// 提交绑定成功
  static const String bound = '收款信息已保存';

  /// 换绑成功
  static const String rebound = '收款信息已换绑，新信息用于后续打款';

  /// 提现页标题
  static const String pageTitle = '提现';

  /// 记录页标题
  static const String recordsTitle = '提现记录';

  /// 绑定页标题
  static const String bindTitle = '收款信息';

  /// 全部提现（快捷填入可用余额）
  static const String allAmount = '全部提现';

  /// 提交按钮
  static const String submit = '申请提现';

  /// 提交中
  static const String submitting = '提交中…';

  /// 申请成功（**唯一**成功文案：钱还没到，只是提交成功）
  ///
  /// 与服务端站内通知口径一致（`withdraw.service.ts`：「提现申请已提交：¥100.00 已从余额扣除」）
  /// —— 客户端不抄那条通知（它有金额、是通知的句子），只说"提交成功 + 等打款"。
  static const String applied = '提现申请已提交，等待打款';

  /// 申请成功后的补充说明（**必须说清"钱已经扣了"**：申请时立即扣款锁定）
  static const String appliedDetail = '余额已按申请金额扣除；平台核对后打款到你的收款信息，可在「提现记录」里看状态。';

  /// 记录页空态
  static const String recordsEmpty = '还没有提现记录';

  /// 记录页空态说明
  static const String recordsEmptyDetail = '申请提现后会在这里显示金额、状态与打款时间。';

  /// 审核列表空态（管理员态）
  static const String auditEmpty = '暂无待处理的提现申请';

  /// 审核列表空态说明（管理员态）
  static const String auditEmptyDetail = '打手提交提现申请后会出现在这里，下拉可刷新。';

  /// 收款码上传位空态（绑定页）
  static const String pickQr = '上传微信收款码';

  /// 打款凭证上传位空态（管理员态详情）
  static const String pickPayoutProof = '上传支付记录截图';

  /// 打款二次确认里**必须出现**的那句话（负责人硬要求，不可改字）
  static const String payConfirmWarning = '确认后将标记为已打款，此操作不可撤销';

  /// 驳回二次确认里**必须出现**的那句话（负责人硬要求）
  static const String rejectConfirmWarning = '余额将退回打手';

  /// 权限不足（403）时的中文说明（**不显示任何操作按钮**）
  ///
  /// 文案刻意**不点名任何内部角色**（"超级管理员"这类内部称呼一律不给用户看 ——
  /// 护栏测试 `user_visible_copy_guard_test` 逐字扫描客户端写死的字符串）：
  /// 只说"这个账号没有权限"与"该找谁"，不说"系统里还有个什么角色"。
  static const String forbidden = '这个账号没有提现审核权限，请联系平台客服开通';

  /// 服务端中文错误（**本地同名文案与它逐字一致**，见 [WorkerWithdrawRules.validateAmount]）
  ///
  /// 带参数的用函数（金额随配置变），不带参数的用常量。
  static const String errBadAmount = '提现金额不正确';
  static const String errTooManyDecimals = '提现金额最多保留 2 位小数';
  static String errBelowMin(num min) => '单笔提现不能低于 ${fmtMoney(min)}';
  static String errAboveMax(num max) => '单笔提现不能高于 ${fmtMoney(max)}';
  static String errInsufficient(num balance) =>
      '提现金额不能超过当前余额（${fmtMoney(balance)}），余额不足时请改小金额或先接单';

  /// **提现链路禁止出现的字样**（合规红线 + 旧计价单位）
  ///
  /// 与 [RechargeCopy.forbiddenWords] 是**两份表**，但结论必须一致：
  /// - 「积分」：2026-10-09 起全平台计价单位是「余额」，提现链路一个字都不许出现
  ///   （两个链路都把它列进黑名单 = 同一结论有两处钉子，任一处漏掉都测得出）；
  /// - 「支付成功 / 自动到账」：合规红线（钱是**人工打款**，没有支付通道、没有回调）；
  /// - 「充值」：提现屏上出现"充值"会让打手以为自己能往账号里加钱（余额只能由平台发放）。
  static const List<String> forbiddenWords = [
    '积分',
    '支付成功',
    '支付已完成',
    '自动到账',
    '提现成功',
    '立即到账',
    '充值',
  ];

  /// 状态标签文案（页面与测试共用同一份）
  static const String statusPending = '处理中';
  static const String statusPaid = '已打款';
  static const String statusRejected = '已驳回';

  /// 打款按钮（管理员态）
  static const String payButton = '已提现';

  /// 驳回按钮（管理员态）
  static const String rejectButton = '驳回';

  /// 打款成功
  static const String paid = '已标记为打款完成';

  /// 驳回成功
  static const String rejected = '已驳回，余额已退回打手';
}

/// ============================================================================
/// 管理员态「提现审核」的干净度核验工具（黑名单）
/// ============================================================================
///
/// 提现审核屏**继承**充值审核那套老板端词（订单/钱包/会员/排行榜/找陪玩…），
/// 但**必须放行**两个词，否则本功能自己的名字会被判违规：
/// - 「提现」= 这一屏在看什么（页头、状态、按钮全用它）；
/// - 「打款」= 审核员要做的动作。
///
/// ⚠️ 放行**只在本类的 [blacklist] 里成立**：充值审核那一屏的禁用词表
/// （[RechargeAdminCleanliness.rechargeForbiddenWords]）里「提现」**照旧禁用** ——
/// 老板充值链路上不做提现（docs/06 铁律），两套口径互不污染。
class WithdrawAdminCleanliness {
  WithdrawAdminCleanliness._();

  /// 提现审核屏追加的禁用词（在老板端 22 词之外）
  ///
  /// 比充值审核那套**多**两个：「积分」（旧计价单位）与「钱包」（打手态不叫钱包，
  /// 提现也只有一个余额口径）。**不含**「提现」与「打款」—— 见类注释。
  static const List<String> auditForbiddenWords = [
    // 别的管理能力：受限会话只做充值审核 + 提现审核两件事
    '用户管理',
    '封禁',
    '后台管理',
    '数据看板',
    '系统设置',
    '操作日志',
    // 打手态专有（除了本屏要用的"提现/打款"）
    '接单大厅',
    '抢单',
    '我的收益',
    '打手态',
    // 老板态内容
    '订单',
    '钱包',
    '会员',
    'VIP',
    '优惠券',
    '购物车',
    '购物',
    '赛事',
    '排行榜',
    '找陪玩',
    // 合规红线 + 旧计价单位
    '积分',
    '兑换现金',
    '支付成功',
    '自动到账',
    '充值',
  ];

  /// 完整黑名单 = 老板端 22 词 + 本屏追加词（去重后按稳定顺序）
static List<String> get blacklist {
    final out = <String>[];
    for (final w in <String>[...IdentityWorkerCleanliness.bossOnlyWords, ...auditForbiddenWords]) {
      if (!out.contains(w)) out.add(w);
    }
    return out;
  }

  /// 在 [texts] 里找出命中的词（空列表 = 干净）；**逐条比对**，不拼接
  static List<String> violations(Iterable<String> texts) {
    final list = blacklist;
    final hit = <String>{};
    for (final t in texts) {
      for (final w in list) {
        if (t.contains(w)) hit.add(w);
      }
    }
    return list.where(hit.contains).toList();
  }
}

// ============================================================================
// 内部解析工具（多候选键名；全部容错，绝不抛）
// ============================================================================

String? _str(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final s = '$v'.trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}

num? _num(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is num) return v;
    final n = num.tryParse('$v');
    if (n != null) return n;
  }
  return null;
}

bool _boolOr(Map<String, dynamic> m, List<String> keys, bool fallback) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '$v'.toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

List<dynamic> _list(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v is List) return v;
  }
  return const [];
}

DateTime? _time(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final d = DateTime.tryParse('$v');
    if (d != null) return d;
  }
  return null;
}

/// 收款信息里的收款码地址解析
///
/// ⚠️ **2026-10-11 服务端落盘后修正**：`withdraw_qr` 是 **protected**（不是 public）——
/// 收款码属于敏感个人信息，`media.service.ts` 的 TYPE_RULES 里明确写
/// `withdraw_qr: { protected: true }`（与老板端充值收款码 `recharge_qr` 相反：
/// 那是**给付款人扫的**，必须公开；打手的收款码只给**审核管理员**看）。
/// 服务端 `getAccount()` 下发的 `qrUrl` 因此是 `/api/v1/media/protected/:id`。
///
/// 三分支：
/// - 绝对 URL 原样（图床）；
/// - 服务端下发的路径原样拼主机（**它自己带对了前缀**，不要改写）；
/// - 纯媒体 id（本地兜底/异常数据）→ 按真实受保护路由拼 `/api/v1/media/protected/:id`。
///
/// ❌ 旧实现走的是 `/media/public/$v`（照抄充值收款码）→ 对 protected 媒体**必然 404**，
/// 表现为"收款码缩略图一直转圈"。测试断言最终绝对 URL **逐字相等**（不是 endsWith）。
String resolveWithdrawMedia(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (v.startsWith('/')) return AppConfig.resolveMediaUrl(v);
  // 纯 id：**受保护**通道（全局前缀 /api/v1 不可省，见下面那张路由对照表）
  return AppConfig.resolveMediaUrl('/api/v1/media/protected/$v');
}

/// **管理员态受保护媒体**的地址解析：`GET /withdraw/proof/:id?kind=qr|payout`
///
/// 为什么必须走这条窄通道而不是 `/media/protected/:id`：App 内管理员态是**受限会话**，
/// 白名单里刻意没有 `/media/*`（那会让受限会话拿到任意受保护媒体）——与充值凭证
/// `/recharge/proof/:requestId` 完全同构。
///
/// ⚠️ 与 [resolveRechargeProof] 同一条踩过的坑：路径**必须自己带 `/api/v1`**，
/// `AppConfig.resolveMediaUrl` 只把相对路径拼成绝对地址、**不补**全局前缀
/// （实测漏前缀的后果 = 图永远转圈）。测试断言**最终绝对 URL 逐字相等**。
String resolveWithdrawProof(String raw, {String requestId = '', String kind = 'qr'}) {
  final v = raw.trim();
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (requestId.isNotEmpty) {
    return AppConfig.resolveMediaUrl('/api/v1/withdraw/proof/$requestId?kind=$kind');
  }
  if (v.startsWith('/')) return AppConfig.resolveMediaUrl(v);
  if (v.isEmpty) return '';
  return AppConfig.resolveMediaUrl('/api/v1/media/protected/$v');
}

/// 受保护媒体的请求头（**带受限会话令牌**；公开图不传即可）
///
/// 与 [authImageHeaders] / [proofImageHeaders] 同一份实现 —— 这条链路上没有第二份
/// "怎么把令牌塞进图片请求"的写法（充值凭证、聊天图、投诉截图三处曾各写一遍而漏令牌）。
Map<String, String> withdrawImageHeaders(String? token) => authImageHeaders(token);
