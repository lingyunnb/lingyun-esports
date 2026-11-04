import '../auth/auth_store.dart';

/// 当前生效身份（合并双端 · 身份切换，方案甲；负责人 2026-10-06 拍板）
///
/// - [boss]：老板态。用 primary token（原登录令牌）调 `/user/*`；界面 = 原老板端 5 项导航。
/// - [worker]：打手态。用 **companion（伴随）token** 调 `/worker/*` 与消息/资料读接口；
///   界面 = 只有 3 项导航（接单 / 消息 / 我的）。
/// - [admin]：**管理员态（充值审核）**。负责人 2026-10-06 方案②：与打手态同一套机制
///   （同样**不顶 primary**、同样是受限会话），但**只做三件事** —— 看待审核列表 /
///   发放余额 / 驳回；界面里**不出现任何其它管理能力**，也不出现老板端的任何内容。
///
/// 身份不是权限：服务端每次都按 token 里的 `kind` 与绑定关系实时判定，
/// 客户端这个枚举**只决定界面骨架与用哪个 token**，绝不参与授权判定。
enum AppIdentity {
  boss,
  worker,
  admin;

  /// 存储/日志用的稳定标识（不要用 `name`，避免将来改枚举名把本地存档读废）
  String get key => switch (this) {
        AppIdentity.worker => 'worker',
        AppIdentity.admin => 'admin',
        AppIdentity.boss => 'boss',
      };

  /// **管理员态刻意不落盘**（[fromKey] 对未知/`admin` 值一律回落到老板态）：
  /// 冷启动一定从老板态开始，要进管理员态必须重新输入管理员账密。
  /// 理由：审核权限（发放余额）不该在一次大退之后静默常驻；服务端的会话 TTL 是上限，不是目标。
  static AppIdentity fromKey(String? key) => key == 'worker' ? AppIdentity.worker : AppIdentity.boss;
}

/// 某老板一条「打手身份绑定」里的打手档案摘要
/// （`GET /user/identity` / `POST /user/identity/bind` 的 `worker` 段，服务端不含任何敏感字段）
class IdentityWorkerProfile {
  const IdentityWorkerProfile({
    required this.workerNo,
    required this.nickname,
    required this.avatarMediaId,
    required this.canTakeOrder,
    required this.canServeCustomer,
    required this.workerStatus,
    required this.divisionPermissions,
  });

  final String workerNo;
  final String nickname;
  final String? avatarMediaId;

  /// 派生汇总（是否有任一分部授权）。**不作判定依据**，界面只用来决定文案（见 CLAUDE.md 第 10 条）
  final bool canTakeOrder;
  final bool canServeCustomer;

  /// 打手档案状态（1 = 在职）
  final int workerStatus;

  /// 全部分部 + 是否已授权（服务端实时查库下发）
  final List<WorkerDivisionPermission> divisionPermissions;

  /// 有接单权限的分部（分部胶囊 / 「已授权 N 个分部」用）
  List<WorkerDivisionPermission> get takeOrderDivisions =>
      divisionPermissions.where((d) => d.canTakeOrder).toList();

  bool get active => workerStatus == 1;

  /// 设计稿 A6 的「已绑定 · 王野 W20260118」
  String get shortLabel => workerNo.isEmpty ? nickname : '$nickname $workerNo';

  /// 打手态身份标识条用的「工号 W20260118」（工号缺失时退化为昵称，绝不显示空白）
  String get workerNoText => workerNo.isEmpty ? nickname : '工号 $workerNo';

  static const empty = IdentityWorkerProfile(
    workerNo: '',
    nickname: '',
    avatarMediaId: null,
    canTakeOrder: false,
    canServeCustomer: false,
    workerStatus: 0,
    divisionPermissions: [],
  );

  factory IdentityWorkerProfile.fromJson(Map<String, dynamic> json) {
    final raw = json['divisionPermissions'];
    final list = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => WorkerDivisionPermission.fromJson(e.cast<String, dynamic>()))
            .toList()
        : <WorkerDivisionPermission>[];
    return IdentityWorkerProfile(
      workerNo: json['workerNo'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      avatarMediaId: json['avatarMediaId'] as String?,
      canTakeOrder: json['canTakeOrder'] == true,
      canServeCustomer: json['canServeCustomer'] == true,
      workerStatus: (json['workerStatus'] as num?)?.toInt() ?? 0,
      divisionPermissions: list,
    );
  }
}

/// 一条绑定关系（服务端 `bindings[]` 一项）
class IdentityBinding {
  const IdentityBinding({
    required this.bindingId,
    required this.status,
    required this.boundAt,
    required this.worker,
  });

  final String bindingId;

  /// active / unbound
  final String status;
  final DateTime? boundAt;
  final IdentityWorkerProfile worker;

  bool get isActive => status == 'active';

  factory IdentityBinding.fromJson(Map<String, dynamic> json) => IdentityBinding(
        bindingId: '${json['bindingId'] ?? ''}',
        status: json['status'] as String? ?? '',
        boundAt: DateTime.tryParse('${json['boundAt'] ?? ''}'),
        worker: IdentityWorkerProfile.fromJson(
          (json['worker'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
        ),
      );
}

/// `GET /user/identity` 的响应
///
/// ⚠️ **以后端实现为准**：任务书写的字段是 `{bound, worker?, bindingId?, maxPerBoss?}`，
/// 后端实际返回 `{bound, activeCount, maxPerBoss, bindings[], message}`（打手摘要嵌在
/// `bindings[].worker` 里）。本类两种形状都吃：`bindings` 为空但顶层给了 `worker` 时也能取到。
class IdentityBindingStatus {
  const IdentityBindingStatus({
    required this.bound,
    required this.activeCount,
    required this.maxPerBoss,
    required this.message,
    required this.bindings,
  });

  final bool bound;
  final int activeCount;
  final int maxPerBoss;

  /// 服务端语义提示（如「已达绑定上限（最多 1 个）」/「可继续绑定」）
  final String message;
  final List<IdentityBinding> bindings;

  /// 当前生效的那条绑定（上限 1 时就是唯一一条）
  IdentityBinding? get active {
    for (final b in bindings) {
      if (b.isActive) return b;
    }
    return bindings.isEmpty ? null : bindings.first;
  }

  IdentityWorkerProfile? get worker => active?.worker;

  String get bindingId => active?.bindingId ?? '';

  static const empty = IdentityBindingStatus(
    bound: false,
    activeCount: 0,
    maxPerBoss: 0,
    message: '',
    bindings: [],
  );

  factory IdentityBindingStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['bindings'];
    final list = raw is List
        ? raw.whereType<Map>().map((e) => IdentityBinding.fromJson(e.cast<String, dynamic>())).toList()
        : <IdentityBinding>[];
    // 兼容任务书里的 `{bound, worker, bindingId}` 形状：顶层给 worker 时补一条伪绑定
    if (list.isEmpty && json['worker'] is Map) {
      list.add(IdentityBinding(
        bindingId: '${json['bindingId'] ?? ''}',
        status: 'active',
        boundAt: DateTime.tryParse('${json['boundAt'] ?? ''}'),
        worker: IdentityWorkerProfile.fromJson((json['worker'] as Map).cast<String, dynamic>()),
      ));
    }
    return IdentityBindingStatus(
      bound: json['bound'] == true || list.isNotEmpty,
      activeCount: (json['activeCount'] as num?)?.toInt() ?? list.length,
      maxPerBoss: (json['maxPerBoss'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
      bindings: list,
    );
  }
}

/// `POST /user/identity/bind` 的响应
class IdentityBindResult {
  const IdentityBindResult({
    required this.bindingId,
    required this.rebound,
    required this.companionToken,
    required this.companionRefreshToken,
    required this.worker,
  });

  final String bindingId;

  /// true = 这条绑定本来就存在（重新签发伴随会话），false = 本次新建
  final bool rebound;
  final String companionToken;
  final String companionRefreshToken;
  final IdentityWorkerProfile worker;

  factory IdentityBindResult.fromJson(Map<String, dynamic> json) => IdentityBindResult(
        bindingId: '${json['bindingId'] ?? ''}',
        rebound: json['rebound'] == true,
        companionToken: json['companionToken'] as String? ?? '',
        companionRefreshToken: json['companionRefreshToken'] as String? ?? '',
        worker: IdentityWorkerProfile.fromJson(
          (json['worker'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
        ),
      );
}

/// 切换身份弹层的**错误态分类**（设计稿 A2 的 7 个 state；文案全部来自服务端）
///
/// 分类只决定**版式与下一步动作**，文案一律取服务端 `message`（负责人要求：
/// 「各错误态中文文案来自服务端」——把假接口文案换掉，页面跟着换）。
enum IdentitySwitchFailure {
  /// 账密错误（400「账号或密码错误」/「账号不存在或密码错误」）→ 输入框红框 + 行内错误行
  credential,

  /// 角色不符（403「该账号不是打手账号，无法绑定」）→ 橙色告知条（不是"你输错了"，是"你拿错了账号"）
  role,

  /// 账号被封禁/停用（403 ACCOUNT_BANNED / 400「该打手账号已停用」）→ 红色条
  banned,

  /// 已被其他老板绑定 / 超出绑定上限 → 橙色条
  conflict,

  /// 绑定成功但一个分部权限都没有 → 橙色条 + 仍可进入大厅
  noPermission,

  /// 限流（429）
  rateLimited,

  /// 其它（网络、5xx）
  other,
}

/// 把服务端错误映射成弹层状态（**只做分类，不改文案**）
IdentitySwitchFailure classifyIdentityFailure({required int code, required String message, String errorCode = ''}) {
  if (errorCode == 'RATE_LIMITED' || code == 429) return IdentitySwitchFailure.rateLimited;
  final m = message;
  if (m.contains('不是打手账号') || m.contains('角色')) return IdentitySwitchFailure.role;
  // 管理员受限会话（方案②）：不在充值审核白名单 / 没有该权限 → 与"角色不符"同类
  // （橙色告知条：不是你输错了，是这个账号没这个权限）。文案仍是服务端原文。
  // 覆盖服务端原文：「该账号未获授权进行充值审核，请联系超级管理员」/「…不在白名单…」
  if (m.contains('白名单') || m.contains('没有权限') || m.contains('无权限') || m.contains('授权')) {
    return IdentitySwitchFailure.role;
  }
  if (errorCode == 'ACCOUNT_BANNED' || m.contains('封禁') || m.contains('已停用')) {
    return IdentitySwitchFailure.banned;
  }
  if (m.contains('已被其他老板绑定') || m.contains('绑定数量已达上限') || m.contains('已达绑定上限')) {
    return IdentitySwitchFailure.conflict;
  }
  if (m.contains('密码') || m.contains('账号不存在')) return IdentitySwitchFailure.credential;
  return IdentitySwitchFailure.other;
}
