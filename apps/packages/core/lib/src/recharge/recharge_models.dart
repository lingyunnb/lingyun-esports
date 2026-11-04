library;

import '../config/app_config.dart';
import '../util/idempotency.dart';

/// ============================================================================
/// 充值（余额）+ 管理员审核 —— 数据模型与规则（负责人 2026-10-06 方案 ①②）
///   计价单位 2026-10-09 由「积分」改为「余额」（1 元 = 1 元）
/// ============================================================================
///
/// ## 合规铁律（写死在模型层，不给"顺手接个支付"留口子）
/// - **不接任何支付通道**：本文件里没有支付 SDK、没有订单号、没有"支付结果回调"概念。
///   收款码就是一张**图片**（[RechargeQrCode.imageUrl]），老板线下扫码付款，
///   付完**上传截图**提交申请，由超管在核对后**手工发放余额**。
/// - **绝不出现"支付成功 / 自动到账"字样**：见 [RechargeCopy.forbiddenWords]，
///   提交后的唯一文案是 [RechargeCopy.submitted]「申请已提交，等待审核」。
/// - 页面上**不做**提现、不做余额兑换现金（`RechargeCopy.forbiddenWords` 同样拦住这两个词）。
///
/// ## 为什么字段解析这么"宽容"
/// 后端契约由另一任务并行实现（任务书写的是 `GET /public/recharge/config` 等形状），
/// 实际字段名可能与任务书有出入。因此所有 `fromJson` 都按 **多候选键名** 解析
/// （如 `amountYuan` / `amount` / `yuan`），并在报告里列出联调清单；
/// **解析不到就退化为"没有这个能力"**（如收款码为空 → 首页入口不渲染），
/// 绝不猜一个默认值把用户引到死路上。

/// 收款码渠道 → 界面标签（渠道只有这三种，服务端可另给 `label` 覆盖）
enum RechargeQrChannel {
  wechat,
  alipay,
  other;

  static RechargeQrChannel parse(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'wechat':
      case 'wx':
      case 'weixin':
        return RechargeQrChannel.wechat;
      case 'alipay':
      case 'ali':
        return RechargeQrChannel.alipay;
      default:
        return RechargeQrChannel.other;
    }
  }

  /// 中文渠道名（docs/21：界面文案用中文，不用英文 key）
  String get label => switch (this) {
        RechargeQrChannel.wechat => '微信',
        RechargeQrChannel.alipay => '支付宝',
        RechargeQrChannel.other => '其它方式',
      };
}

/// 一张收款码（**图片**，多张时可切换/并排）
class RechargeQrCode {
  const RechargeQrCode({
    required this.id,
    required this.channel,
    required this.label,
    required this.url,
  });

  final String id;
  final RechargeQrChannel channel;

  /// 服务端下发的展示名（如「微信收款码 · 小云」）；为空时退化为渠道名
  final String label;

  /// 服务端下发的地址：绝对 URL / 相对路径 `/media/public/3` / 纯媒体 id 三种都吃
  final String url;

  String get displayLabel => label.isNotEmpty ? label : channel.label;

  /// 可直接喂给 `CachedNetImage` 的绝对地址
  String get imageUrl => resolveRechargeMedia(url);

  bool get usable => imageUrl.isNotEmpty;

  factory RechargeQrCode.fromJson(Map<String, dynamic> json) => RechargeQrCode(
        id: _str(json, const ['id', 'qrId', 'mediaId']) ?? '',
        channel: RechargeQrChannel.parse(_str(json, const ['channel', 'payChannel', 'type'])),
        label: _str(json, const ['label', 'name', 'title', 'remark']) ?? '',
        url: _str(json, const ['url', 'imageUrl', 'src', 'mediaUrl', 'path']) ?? '',
      );
}

/// `GET /public/recharge/config`：充值口径**全部来自服务端**（客户端不写死档位/比例/文案）
class RechargeConfig {
  const RechargeConfig({
    required this.amountOptions,
    required this.customEnabled,
    required this.minYuan,
    required this.maxYuan,
    required this.pointsPerYuan,
    required this.pendingLimitPerUser,
    required this.noticeText,
    required this.qrCodes,
  });

  /// 金额档位（元）—— **不写死**：服务端换一批，界面跟着换
  final List<num> amountOptions;

  /// 是否允许自定义金额
  final bool customEnabled;

  /// 自定义金额下限（元）；<=0 视为 1 元
  final num minYuan;

  /// 自定义金额上限（元）；<=0 视为不限
  final num maxYuan;

  /// 1 元 = N 积分 / 余额（**接口历史字段，仍解析但不参与展示**）
  ///
  /// 2026-10-09 口径：计价单位 = 余额、**1 元 = 1 元**（[RechargeRules.previewBalance] 不再乘比例）。
  /// 字段保留只为**不改接口形状**（字段名与服务端约定不变），界面一律 1:1 展示。
  final num pointsPerYuan;

  /// 同一用户同时可有多少笔待审核（服务端口径，界面只做告知，拦截一律由服务端 400 兜底）
  final int pendingLimitPerUser;

  /// 说明文案（**服务端下发**，含"付款后请上传截图并提交申请"这类必须说清的话）
  final String noticeText;

  final List<RechargeQrCode> qrCodes;

  /// 生效比例（<=0 时退化为 1，绝不做除零）
  num get effectivePointsPerYuan => pointsPerYuan > 0 ? pointsPerYuan : 1;

  num get effectiveMinYuan => minYuan > 0 ? minYuan : 1;

  /// 上限（<=0 = 不限）
  num get effectiveMaxYuan => maxYuan > 0 ? maxYuan : 0;

  /// 下限（元）：自定义金额输入校验用
  bool get hasQrCode => usableQrCodes.isNotEmpty;

  /// 能真正展示的收款码（地址解析后仍为空的不算）
  List<RechargeQrCode> get usableQrCodes => qrCodes.where((q) => q.usable).toList();

  /// **首页充值入口是否渲染**的唯一判据（见 `services_page.dart` 的说明）
  ///
  /// 两条缺一不可：① 至少一张可用收款码（没有收款码 = 用户点进去也没法付款）；
  /// ② 至少一个金额档位或允许自定义（否则没有任何可提交的金额）。
  ///
  /// ⚠️ 2026-10-09 口径变更：**去掉了原「比例 > 0」这一条** —— 到账余额现在是 **1:1**
  /// （[RechargeRules.previewBalance] 不乘任何比例），比例字段已不参与展示；
  /// 若还拿它当入口闸门，服务端把该历史字段清零/移除时会让**整个充值入口消失**（功能丢失）。
  /// 真正的开关一直是"管理端有没有配收款码"。
  bool get entryAvailable => hasQrCode && (amountOptions.isNotEmpty || customEnabled);

  static const empty = RechargeConfig(
    amountOptions: [],
    customEnabled: false,
    minYuan: 0,
    maxYuan: 0,
    pointsPerYuan: 0,
    pendingLimitPerUser: 0,
    noticeText: '',
    qrCodes: [],
  );

  factory RechargeConfig.fromJson(Map<String, dynamic> json) {
    final rawOptions = _list(json, const ['amountOptions', 'amounts', 'options', 'amountList']);
    final options = <num>[];
    for (final e in rawOptions) {
      final v = e is num ? e : num.tryParse('$e');
      if (v != null && v > 0) options.add(v);
    }
    final rawQr = _list(json, const ['qrCodes', 'qrcodes', 'codes', 'payQrCodes']);
    return RechargeConfig(
      amountOptions: options,
      // customEnabled 兼容 custom / allowCustom 两个键；未下发时**按档位是否为空**兜底
      customEnabled: _bool(json, const ['customEnabled', 'allowCustom', 'custom'], options.isEmpty),
      minYuan: _num(json, const ['minYuan', 'min', 'customMinYuan']) ?? 0,
      maxYuan: _num(json, const ['maxYuan', 'max', 'customMaxYuan']) ?? 0,
      pointsPerYuan: _num(json, const ['pointsPerYuan', 'pointsPerYuanRatio', 'rate']) ?? 0,
      pendingLimitPerUser: (_num(json, const ['pendingLimitPerUser', 'pendingLimit', 'limitPerUser']) ?? 0).toInt(),
      noticeText: _str(json, const ['noticeText', 'notice', 'tips', 'description']) ?? '',
      qrCodes: rawQr
          .whereType<Map>()
          .map((e) => RechargeQrCode.fromJson(e.cast<String, dynamic>()))
          .where((q) => q.url.isNotEmpty)
          .toList(),
    );
  }
}

/// 我的一条充值申请（`GET /user/recharge/requests`）
class RechargeRequestItem {
  const RechargeRequestItem({
    required this.id,
    required this.amountYuan,
    required this.points,
    required this.status,
    required this.rejectReason,
    required this.note,
    required this.proofUrl,
    required this.createdAt,
    required this.grantedAt,
  });

  final String id;
  final num amountYuan;
  final num points;

  /// pending / granted / rejected（服务端口径；未知值原样保留并显示原文）
  final String status;
  final String rejectReason;
  final String note;
  final String proofUrl;
  final DateTime? createdAt;
  final DateTime? grantedAt;

  bool get isPending => status == 'pending';
  bool get isGranted => status == 'granted' || status == 'issued' || status == 'approved';
  bool get isRejected => status == 'rejected' || status == 'refused';

  /// 状态中文（**只翻译已知状态**；未知状态显示服务端原文，不猜）
  String get statusText {
    if (isPending) return '待审核';
    if (isGranted) return '已到账';
    if (isRejected) return '已驳回';
    return status.isEmpty ? '—' : status;
  }

  factory RechargeRequestItem.fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? json['requestId'] ?? ''}';
    return RechargeRequestItem(
      id: id,
      amountYuan: _num(json, const ['amountYuan', 'amount', 'yuan']) ?? 0,
      points: _num(json, const ['points', 'pointsAmount', 'grantedPoints', 'score']) ?? 0,
      status: '${json['status'] ?? ''}',
      rejectReason: _str(json, const ['rejectReason', 'reason', 'rejectRemark']) ?? '',
      note: _str(json, const ['note', 'remark', 'userNote']) ?? '',
      // docs/03：本接口回 `proofUrl`（受限会话走 `/recharge/proof/:requestId`）
      proofUrl: resolveRechargeProof(
        _str(json, const ['proofUrl', 'voucherUrl', 'proofMediaId', 'voucherMediaId', 'proof', 'proofImage']) ?? '',
        requestId: id,
      ),
      createdAt: _time(json, const ['createdAt', 'submittedAt', 'createTime', 'createdTime']),
      grantedAt: _time(json, const ['grantedAt', 'reviewedAt', 'issuedAt', 'auditTime', 'updatedAt']),
    );
  }
}

/// `POST /user/recharge/requests` 的 201 响应
class RechargeSubmitResult {
  const RechargeSubmitResult({required this.id, required this.points, required this.status});

  final String id;
  final num points;
  final String status;

  factory RechargeSubmitResult.fromJson(Map<String, dynamic> json) => RechargeSubmitResult(
        id: '${json['id'] ?? json['requestId'] ?? ''}',
        points: _num(json, const ['points', 'pointsAmount', 'score']) ?? 0,
        status: '${json['status'] ?? 'pending'}',
      );
}

/// 管理员账号（受限会话主体）
class RechargeAdminAccount {
  const RechargeAdminAccount({required this.id, required this.nickname, required this.username});

  final String id;
  final String nickname;
  final String username;

  /// 界面显示名（昵称优先；都没有就退化为「审核员」）
  String get displayName {
    if (nickname.isNotEmpty) return nickname;
    return username.isNotEmpty ? username : '审核员';
  }

  static const empty = RechargeAdminAccount(id: '', nickname: '', username: '');

  factory RechargeAdminAccount.fromJson(Map<String, dynamic> json) => RechargeAdminAccount(
        id: '${json['id'] ?? ''}',
        nickname: _str(json, const ['nickname', 'name', 'nickName']) ?? '',
        username: _str(json, const ['username', 'account', 'loginName']) ?? '',
      );
}

/// `POST /user/identity/bind-recharge-admin` 的响应（**受限会话**）
///
/// ⚠️ 任务书里这条响应只写了 `{admin, expiresIn}` —— 没有令牌。客户端因此**两种形状都吃**：
/// - 服务端下发了 `adminToken` / `token` 之类 → 管理员态用**这一枚受限令牌**；
/// - 没下发 → 管理员态**沿用老板的 primary 令牌**发那些 `/recharge/*` 请求
///   （服务端仍按"账号是否在白名单"实时判定，客户端拿不到额外权限；
///   报告里作为待联调项列出：建议下发独立受限令牌，才能做到"被移出白名单即 401"）。
class RechargeAdminSession {
  const RechargeAdminSession({
    required this.admin,
    required this.expiresIn,
    required this.token,
    required this.refreshToken,
    required this.pendingCount,
  });

  final RechargeAdminAccount admin;

  /// 会话有效期（秒；服务端下发）
  final num expiresIn;

  /// 受限令牌（可能为空 —— 见类注释）
  final String token;
  final String refreshToken;
  final int pendingCount;

  bool get hasDedicatedToken => token.isNotEmpty;

  factory RechargeAdminSession.fromJson(Map<String, dynamic> json) {
    final adminRaw = json['admin'];
    return RechargeAdminSession(
      admin: adminRaw is Map
          ? RechargeAdminAccount.fromJson(adminRaw.cast<String, dynamic>())
          : RechargeAdminAccount.fromJson(json),
      expiresIn: _num(json, const ['expiresIn', 'expiresInSeconds', 'ttl']) ?? 0,
      token: _str(json, const [
            'rechargeToken', // docs/04 的实际字段名
            'adminToken',
            'token',
            'accessToken',
            'rechargeAdminToken',
          ]) ??
          '',
      refreshToken: _str(json, const ['rechargeRefreshToken', 'adminRefreshToken', 'refreshToken']) ?? '',
      pendingCount: (_num(json, const ['pendingCount', 'pending']) ?? 0).toInt(),
    );
  }
}

/// `GET /recharge/me`：当前管理员态信息 + 待审核数
class RechargeAdminMe {
  const RechargeAdminMe({required this.admin, required this.pendingCount, required this.expiresIn});

  final RechargeAdminAccount admin;
  final int pendingCount;
  final num expiresIn;

  static const empty = RechargeAdminMe(admin: RechargeAdminAccount.empty, pendingCount: 0, expiresIn: 0);

  factory RechargeAdminMe.fromJson(Map<String, dynamic> json) {
    final adminRaw = json['admin'];
    return RechargeAdminMe(
      admin: adminRaw is Map
          ? RechargeAdminAccount.fromJson(adminRaw.cast<String, dynamic>())
          : RechargeAdminAccount.fromJson(json),
      pendingCount: (_num(json, const ['pendingCount', 'pending', 'total']) ?? 0).toInt(),
      expiresIn: _num(json, const ['expiresIn', 'expiresInSeconds', 'ttl']) ?? 0,
    );
  }
}

/// 待审核列表里的一条（`GET /recharge/requests?status=pending`）
///
/// 服务端需要下发：用户昵称 + 中文 ID、金额、到账余额、凭证 url、提交时间。
/// 字段名同样按多候选键解析（联调清单见报告）。
class PendingRechargeRequest {
  const PendingRechargeRequest({
    required this.id,
    required this.nickname,
    required this.uid,
    required this.amountYuan,
    required this.points,
    required this.proofUrl,
    required this.note,
    required this.createdAt,
    required this.status,
  });

  final String id;
  final String nickname;

  /// 中文 ID（用户侧展示 ID，`U8471209365` 这类）
  final String uid;
  final num amountYuan;
  final num points;
  final String proofUrl;
  final String note;
  final DateTime? createdAt;
  final String status;

  factory PendingRechargeRequest.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    final um = user is Map ? user.cast<String, dynamic>() : const <String, dynamic>{};
    final id = '${json['id'] ?? json['requestId'] ?? ''}';
    return PendingRechargeRequest(
      id: id,
      nickname: _str(json, const ['nickname', 'userNickname', 'userName', 'name']) ??
          _str(um, const ['nickname', 'name', 'userName']) ??
          '',
      uid: _str(json, const ['uid', 'userUid', 'chineseId', 'displayId', 'userNo']) ??
          _str(um, const ['uid', 'chineseId', 'displayId', 'userNo']) ??
          '',
      amountYuan: _num(json, const ['amountYuan', 'amount', 'yuan']) ?? 0,
      points: _num(json, const ['points', 'pointsAmount', 'score']) ?? 0,
      // docs/03：本接口同时回 `proofMediaId`（别名 `voucherMediaId`）与凭证 url；
      // **只给媒体 id 时** → 走受限会话专用窄通道 `/recharge/proof/:requestId`
      proofUrl: resolveRechargeProof(
        _str(json, const ['proofUrl', 'voucherUrl', 'proofMediaId', 'voucherMediaId', 'proof', 'proofImage']) ?? '',
        requestId: id,
      ),
      note: _str(json, const ['note', 'remark', 'userNote']) ?? '',
      createdAt: _time(json, const ['createdAt', 'submittedAt', 'createTime', 'createdTime']),
      status: '${json['status'] ?? 'pending'}',
    );
  }
}

/// 一页待审核数据（列表 + 待审核总数；两种容器形状都吃）
class PendingRechargePage {
  const PendingRechargePage({required this.list, required this.total});

  final List<PendingRechargeRequest> list;
  final int total;

  static const empty = PendingRechargePage(list: [], total: 0);

  /// 解析 `{list,total}` / `{items,pendingCount}` / 裸数组（调用方传入 `data` 段）
  factory PendingRechargePage.fromData(Object? data) {
    if (data is List) {
      final list = data
          .whereType<Map>()
          .map((e) => PendingRechargeRequest.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
      return PendingRechargePage(list: list, total: list.length);
    }
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final raw = _list(m, const ['list', 'items', 'records', 'rows', 'requests']);
      final list = raw
          .whereType<Map>()
          .map((e) => PendingRechargeRequest.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.id.isNotEmpty)
          .toList();
      final total = (_num(m, const ['total', 'pendingCount', 'count']) ?? list.length).toInt();
      return PendingRechargePage(list: list, total: total);
    }
    return empty;
  }
}

/// 我的充值申请列表（`GET /user/recharge/requests`）
///
/// docs/03：除了列表，服务端还回 `pendingCount` + `pendingLimitPerUser`
/// （客户端据此**禁用提交按钮**并把在审笔数说清楚；服务端仍是唯一权威，400 文案原样透传）。
class RechargeRequestPage {
  const RechargeRequestPage({
    required this.list,
    required this.total,
    this.pendingCount = 0,
    this.pendingLimitPerUser = 0,
  });

  final List<RechargeRequestItem> list;
  final int total;

  /// 当前在审笔数（服务端口径；列表未分页到 pending 时也准）
  final int pendingCount;

  /// 同一时间可有多少笔待审核（0 = 服务端没下发）
  final int pendingLimitPerUser;

  static const empty = RechargeRequestPage(list: [], total: 0);

  /// 已达在审上限（此时提交按钮置灰；等审核完成后自动恢复）
  bool get atPendingLimit => pendingLimitPerUser > 0 && pendingCount >= pendingLimitPerUser;

  int get pendingCountInList => list.where((e) => e.isPending).length;

  factory RechargeRequestPage.fromData(Object? data) {
    if (data is List) {
      final list = data
          .whereType<Map>()
          .map((e) => RechargeRequestItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      return RechargeRequestPage(list: list, total: list.length, pendingCount: list.where((e) => e.isPending).length);
    }
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final raw = _list(m, const ['list', 'items', 'records', 'rows', 'requests']);
      final list = raw
          .whereType<Map>()
          .map((e) => RechargeRequestItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      final total = (_num(m, const ['total', 'count']) ?? list.length).toInt();
      final pending = (_num(m, const ['pendingCount']) ?? list.where((e) => e.isPending).length).toInt();
      return RechargeRequestPage(
        list: list,
        total: total,
        pendingCount: pending,
        pendingLimitPerUser: (_num(m, const ['pendingLimitPerUser', 'pendingLimit']) ?? 0).toInt(),
      );
    }
    return empty;
  }
}

/// ============================================================================
/// 金额 / 余额规则（**纯函数，可单测**；页面只调这里，不自己算）
/// ============================================================================
class RechargeRules {
  RechargeRules._();

  /// 自定义金额解析：接受 `12` / `12.5` / `12.50` / 全角空格；非法返回 null
  static num? parseYuan(String raw) {
    final t = raw.trim().replaceAll('　', '');
    if (t.isEmpty) return null;
    final v = num.tryParse(t);
    if (v == null) return null;
    if (v <= 0) return null;
    // 最多两位小数（金额口径，与全站小数金额一致）
    if (!hasAtMostTwoDecimals(v)) return null;
    return v;
  }

  /// 是否最多两位小数（**口径唯一实现**）
  ///
  /// ⚠️ 不能写 `(v * 100).round() != v * 100`：浮点数下 `8.8 * 100 == 880.0000000000001`
  /// ≠ 880，会把**完全合法**的 `8.8`（服务端打赏预设档位之一）判成非法
  /// —— 实测于 2026-10-09 修（充值自定义金额与打赏金额都踩过）。
  static bool hasAtMostTwoDecimals(num v) {
    final scaled = v.toDouble() * 100;
    if (!scaled.isFinite) return false;
    return (scaled - scaled.roundToDouble()).abs() < 1e-6;
  }

  /// 金额 → 中文错误（null = 合法）
  ///
  /// **文案是客户端的**（"你输错了"这类本地校验），服务端的 400 文案永远原样透传（见页面）。
  /// 金额一律走 `fmtMoney`（`¥6.00`），所以这里不再补「元」字。
  static String? validateAmount(num? amount, RechargeConfig cfg) {
    if (amount == null || amount <= 0) return '请输入充值金额';
    final min = cfg.effectiveMinYuan;
    final max = cfg.effectiveMaxYuan;
    if (amount < min) return '最低 ${fmtMoney(min)}';
    if (max > 0 && amount > max) return '最高 ${fmtMoney(max)}';
    return null;
  }

  /// 自定义金额输入框的实时校验（**只在用户真的输入了内容时才报错**，空输入不报红）
  static String? validateCustomInput(String raw, RechargeConfig cfg) {
    if (raw.trim().isEmpty) return null;
    final v = parseYuan(raw);
    if (v == null) return '请输入正确的金额（最多两位小数）';
    return validateAmount(v, cfg);
  }

  /// 该档位**到账余额**（预览值；提交后以服务端发放的 `points` 为准）
  ///
  /// 2026-10-09 口径：计价单位 = 余额，**1 元 = 1 元** → 到账就是**付款金额本身**
  /// （`¥6.00` 付款 → `¥6.00` 到账），不再乘任何比例、也不再向下取整：
  /// 余额是金额而不是"积分条数"，`12.5` 元到账就必须是 `¥12.50`（不是 12）。
  /// 客户端只是预览，服务端的发放结果仍是权威。
  static num previewBalance(num amountYuan) => amountYuan > 0 ? amountYuan : 0;

  /// 金额展示：**统一出口** `fmtMoney`（`¥` + 千分位 + 两位小数）
  ///
  /// 语义化别名：本方法的调用方说的都是"这是一笔钱"，格式规则只由 `fmtMoney` 持有
  /// （页面不得自己拼 `¥` / 小数点 / 千分位）。
  static String formatYuan(num v) => fmtMoney(v);
}

/// ============================================================================
/// 文案常量（合规口径的唯一出处：测试与页面引用同一份）
/// ============================================================================
class RechargeCopy {
  RechargeCopy._();

  /// 提交成功后**唯一**允许的成功文案（负责人定案）
  static const String submitted = '申请已提交，等待审核';

  /// 提交成功页的补充说明（说清"接下来谁做什么"，不承诺时间也不提"支付"）
  static const String submittedDetail = '客服核对收款记录后发放余额，请留意「我的充值记录」里的状态变化。';

  /// 收款码下方固定提示（无论服务端 notice 是否下发都要有的一句）
  static const String scanHint = '付款后请上传截图并提交申请';

  /// **禁止出现在界面上的字样**（"支付成功/自动到账"是合规红线；提现与余额兑换现金同样不做）
  ///
  /// 用途：测试逐屏扫描所有 `Text`，命中任一 → FAIL。
  static const List<String> forbiddenWords = [
    '支付成功',
    '支付已完成',
    '自动到账',
    '充值成功',
    '立即支付',
    '提现',
    '兑换现金',
    // 2026-10-09 口径：计价单位是「余额」，充值链路上不许再出现旧单位字样
    '积分',
  ];

  /// 首页入口标题（克制：一条入口，不是横幅广告）
  static const String entryTitle = '充值';

  /// 首页入口副标题（**审批定案：≤14 字**，1.3× 系统字号下不截断）
  ///
  /// 原 18 字文案在 1.3× 字号下需要约 299dp 而可用只有约 269dp（会被省略号截断）→ 压到 12 字。
  /// 语义仍是"扫码付款 → 审核后发放余额"：既**不是**即时到账，也**不出现**"支付"字样。
  static const String entrySubtitle = '扫码付款，审核后发放余额';

  /// 到账预览：**1 元 = 1 元余额**（口径唯一出处，页面与测试引用同一份）
  ///
  /// 例：`付款 ¥6.00 → 到账 ¥6.00`。刻意写成"付款 → 到账"两段：
  /// 钱是线下扫给收款码的，平台只负责核对后**手工发放**余额 —— 不承诺即时到账。
  static String previewLine(num amountYuan) =>
      '付款 ${fmtMoney(amountYuan)} → 到账 ${fmtMoney(amountYuan)}';

  /// 已达在审上限时的提示（**服务端仍是权威**：这里只是让用户少跑一次必然失败的提交）
  static const String pendingLimitReached = '你在审的申请已达上限，等审核完成后再提交';
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

bool _bool(Map<String, dynamic> m, List<String> keys, bool fallback) {
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

/// 收款码地址解析：绝对 URL 原样 / 相对路径拼接 / 纯媒体 id 走公开媒体通道
///
/// **路径口径（与 [resolveRechargeProof] 同一份说明）**：收款码是 `recharge_qr`（**public**），
/// 真实路由就是根路径 `/media/public/:id`（全局前缀把它排除了）→ 传参**不带** `/api/v1`。
/// 这里三条分支全部正确，`/media/public/*` 属于"根路径才对"的那一类，**不要**顺手加前缀。
///
/// ⚠️ 唯一的隐患是"服务端显式下发了受保护地址"（`/api/v1/media/protected/:id`）：
/// 收款码语义上永远是公开图，下发了受保护地址属于服务端配置错误（管理端把图传成了受保护用途），
/// 这里不做静默改写 —— 保持原样交给 `resolveMediaUrl`，由服务端修数据。
String resolveRechargeMedia(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (v.startsWith('/')) return AppConfig.resolveMediaUrl(v);
  // 纯 id（UUID / 雪花 id）：管理端上传的收款码走公开媒体通道
  return AppConfig.resolveMediaUrl('/media/public/$v');
}

/// 付款凭证地址解析（docs/03 `GET /recharge/proof/:requestId`）
///
/// **受限会话的白名单里刻意没有 `/media/*`**（它会让 `role=admin` 拿到任意受保护媒体），
/// 所以审核员看凭证只有一个窄通道：`/recharge/proof/<这张申请的 id>`。
///
/// **优先级（2026-10-06 修正，修掉"凭证图永久转圈"）**：
/// 1. **拿得到申请 id → 一律走 `/recharge/proof/<id>`**（再也不被服务端下发的凭证地址覆盖）。
///    为什么必须压过服务端：服务端 `proofUrl` 走的是 `MediaService.clientPath()` 的受保护通道，
///    而 App 管理员态是**受限会话**，`/media/*` 对它一律 403；
///    且历史上服务端给的是**少了前缀的根路径** `/media/protected/:id`（实测 404 `Cannot GET`）——
///    两种情况都表现为"图一直转圈"。申请 id 是这条窄通道的唯一入参（媒体 id 用不上），
///    列表与详情都从同一个字段拿 id，所以两处口径天然一致。
/// 2. 外部绝对 URL（`http(s)://`）原样用 —— 那是服务端显式指定的图床，不是通道选择。
/// 3. 没有申请 id（历史/异常数据）才退回服务端给的相对路径；
///    若连路径都没有、只剩媒体 id，退到 `/api/v1/media/protected/:id`（与真实路由一致，正常情况下走不到）。
///
/// ## ⚠️ 这一类 bug 的**唯一判据：服务端路由有没有 `/api/v1`**
///
/// `AppConfig.resolveMediaUrl` 的实现是「**先剥掉** `/api/v1` 再拼主机」：
/// `apiBase = https://h/api/v1` → `host = https://h` → `'$host$pathOrUrl'`。
/// 也就是说它**不会**替你补全局前缀，只负责"相对路径 → 绝对地址"。
/// 因此传进去的路径**必须自己带前缀**（服务端真实路由是什么就写什么）：
///
/// | 通道 | 真实路由 | 传参 |
/// |---|---|---|
/// | 公开媒体 | `/media/public/:id`（`main.ts` 的 `setGlobalPrefix` **排除**了它） | `/media/public/$id` —— **不带**前缀 |
/// | 受保护媒体 | `/api/v1/media/protected/:id`（没被排除，挂在全局前缀下） | `/api/v1/media/protected/$id` |
/// | 凭证窄通道 | `/api/v1/recharge/proof/:requestId`（同上） | `/api/v1/recharge/proof/$requestId` |
///
/// 【2026-10-07 修「充值审核详情页付款凭证图一直转圈」】第 1 条分支此前写的是
/// `/recharge/proof/$requestId`（**漏了 `/api/v1`**，同一分支的第 3 条却带着前缀 —— 两条腿不一致），
/// 最终拼出 `https://<host>/recharge/proof/48`：该路径不存在 → 图永远出不来。
/// **同一天晚上 `/media/protected` 是同一个根因**（见 `media.service.ts#clientPath` 的注记）。
///
/// 测试口径（防回归的关键，见 `test/recharge_proof_url_test.dart`）：
/// **断言最终绝对 URL 逐字相等**，不许用 `contains`/`endsWith` ——
/// 旧测试正是只断言了 `endsWith('/recharge/proof/48')`，所以漏掉了前缀缺失。
String resolveRechargeProof(String raw, {String requestId = ''}) {
  final v = raw.trim();
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (requestId.isNotEmpty) {
    return AppConfig.resolveMediaUrl('/api/v1/recharge/proof/$requestId');
  }
  if (v.startsWith('/')) return AppConfig.resolveMediaUrl(v);
  if (v.isEmpty) return '';
  // 服务端未给路径、只给媒体 id：按真实受保护路由拼（全局前缀 /api/v1 不可省）
  return AppConfig.resolveMediaUrl('/api/v1/media/protected/$v');
}

/// 图片请求头：受保护媒体（`/api/v1/media/protected/:id`、`/api/v1/recharge/proof/:requestId`）
/// 只认 `Authorization: Bearer <token>`，而 `CachedNetImage`/`Image.network` 都**不自己读登录态**
/// —— 由调用方显式给。
///
/// 【2026-10-07 更名与推广】原函数名里的 `proof` 让后来人以为"只有充值凭证用得上"，
/// 于是聊天图片（`chat_detail_page.dart`）与投诉截图（`complaint_page.dart`）
/// 各自手写了裸 `Image.network`（一个地址少 `/api/v1`、一个干脆没带令牌）→ 图永远出不来。
/// 现在统一走这一份实现：语义不限充值，令牌是谁由调用方决定
/// （老板态给 primary、打手态给 companion、管理员态给 recharge）。[proofImageHeaders] 保留为别名，
/// 既有调用方与测试**逐字不变**。
Map<String, String> authImageHeaders(String? token) =>
    (token == null || token.isEmpty) ? const <String, String>{} : {'Authorization': 'Bearer $token'};

/// [authImageHeaders] 的历史名字（充值审核付款凭证那条链路的既有调用方在用）
Map<String, String> proofImageHeaders(String? token) => authImageHeaders(token);
