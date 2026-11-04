import 'package:flutter/foundation.dart';
import '../api/api_cache.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';
import '../config/app_settings.dart';
import '../identity/worker_identity_models.dart';
import '../recharge/recharge_models.dart';
import '../realtime/realtime_client.dart';
import 'email_auth.dart';

/// 打手在某个分部的接单权限（工作端「我的」/大厅分部筛选用；服务端实时查库下发，客户端仅展示）
///
/// 负责人 2026-10-04：接单权限按分部细分（和平 / 三角洲手游 / 三角洲端游），
/// 老字段 `canTakeOrder` 只是「是否有任一分部权限」的汇总，**不能**用来判断某个分部能不能接。
class WorkerDivisionPermission {
  const WorkerDivisionPermission({
    required this.divisionId,
    required this.name,
    required this.shortName,
    required this.platformLabel,
    required this.canTakeOrder,
  });

  final String divisionId;
  final String name;
  final String shortName;
  final String platformLabel;
  final bool canTakeOrder;

  /// 展示名：简称 · 平台（如「三角洲行动 · 手游」）；缺简称时回退完整名
  String get label {
    if (shortName.isEmpty) return name;
    return platformLabel.isEmpty ? shortName : '$shortName · $platformLabel';
  }

  factory WorkerDivisionPermission.fromJson(Map<String, dynamic> json) => WorkerDivisionPermission(
        divisionId: '${json['divisionId'] ?? ''}',
        name: json['name'] as String? ?? '',
        shortName: json['shortName'] as String? ?? '',
        platformLabel: json['platformLabel'] as String? ?? '',
        canTakeOrder: json['canTakeOrder'] == true,
      );
}

/// 当前登录主体资料（与 GET /auth/me 返回结构对应，docs/04）
class AuthMe {
  const AuthMe({
    required this.id,
    required this.username,
    required this.uid,
    required this.nickname,
    required this.role,
    required this.raw,
  });

  final String id;
  final String username;
  final String uid;
  final String nickname;
  final String role;
  final Map<String, dynamic> raw;

  /// 工作端权限位（worker 时有效；服务端每次请求实时校验，这里仅用于展示，docs/04）
  bool get canTakeOrder => raw['worker']?['canTakeOrder'] == true;
  bool get canServeCustomer => raw['worker']?['canServeCustomer'] == true;
  String get workerNo => raw['worker']?['workerNo'] as String? ?? '';

  /// 全部分部 + 是否已授权（服务端下发；缺失时返回空表，页面按"无权限"展示）
  List<WorkerDivisionPermission> get divisionPermissions {
    final list = (raw['worker'] as Map?)?['divisionPermissions'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => WorkerDivisionPermission.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// **有接单权限**的分部（工作端展示「我能接哪些分部」用）
  List<WorkerDivisionPermission> get takeOrderDivisions =>
      divisionPermissions.where((d) => d.canTakeOrder).toList();

  /// 头像/背景媒体 ID（真实上传后端，docs/08；公开通道直接展示）
  String? get avatarMediaId => raw['avatarMediaId'] as String?;
  String? get backgroundMediaId => raw['backgroundMediaId'] as String?;

  /// 背景是图还是视频（服务端 /auth/me 下发，2026-10-21）
  ///
  /// g 存图片、g_video 存 mp4，共用 [backgroundMediaId]。
  /// 客户端只凭 mediaId 分不出类型（/media/public/:id 不带扩展名），必须由服务端指认。
  String? get backgroundType => raw['backgroundType'] as String?;

  /// 背景是不是视频（决定用播放器还是 Image.network）
  bool get backgroundIsVideo => backgroundType == 'video';

  /// 头像是不是动图 —— 服务端不下发，靠 AppAvatar(allowAnimation: true) 直接按
  /// GIF 字节自动播，这里不提供判断（避免两处口径不一致）。

  /// 等级 1-5（累计实际消费升级，服务端权威，docs/06 补充）
  int get level => (raw['level'] as num?)?.toInt() ?? 1;

  /// 累计实际消费金额（服务端权威，非本地余额；展示一律 fmtMoney）
  double get totalSpent => (raw['totalSpent'] as num?)?.toDouble() ?? 0;

  /// 等级名（与服务端 `LEVEL_RULES` / `system_setting.level_rules` 对齐）
  ///
  /// ⚠️ 这是**本地兜底**：正常路径是服务端下发 `levelName`（改配置后立即生效）。
  /// 只有服务端没给名字时才走这里 —— 名字必须与 `level_style.dart` 的 label 逐字一致，
  /// 否则同一等级在两个地方显示成两个名字。
  /// 负责人 2026-10-18 改定：初识 / 知交 / 尊享 / 臻享 / 至尊会员。
  String get levelName => switch (level) {
        5 => '至尊会员',
        4 => '臻享会员',
        3 => '尊享会员',
        2 => '知交会员',
        _ => '初识会员',
      };

  factory AuthMe.fromJson(Map<String, dynamic> json) => AuthMe(
        id: '${json['id']}',
        username: json['username'] as String? ?? '',
        uid: json['uid'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        role: json['role'] as String? ?? '',
        raw: json,
      );
}

/// 认证状态（单例）：token 存 Android Keystore 安全存储（docs/09），
/// 登录/登出/注册/自动 refresh 过期处理；单设备登录（docs/04）全局踢出。
class AuthStore extends ChangeNotifier {
  AuthStore._() {
    ApiClient.onSessionKicked = _handleSessionKicked;
    // 令牌过期自动刷新（2026-09-25）：任何接口遇到 401"登录已过期"自动换新令牌重试，
    // 长时间使用不再需要重启 App / 重新登录
    ApiClient.onTokenExpired = refreshAccessToken;
    /**
     * 401 的**令牌维度**通知（合并双端 · 身份切换）：
     * [onSessionKicked] 只在"账号已在其他设备登录"这一条精确文案上触发，而伴随会话失效时
     * 服务端给的是「伴随身份已失效，请重新绑定打手账号」等另一套文案。这里补一个拿到
     * "**刚刚 401 的那个 token**"的钩子，由 AuthStore 判断它是不是 companion：
     *   - 是 companion → 只丢打手身份、切回老板态（老板态会话完全不受影响）；
     *   - 不是 → 什么都不做，继续走原有 primary 路径（行为逐字节不变）。
     */
    ApiClient.onUnauthorized = _handleUnauthorized;
    /**
     * **封禁（账号被封）专用钩子**（2026-10-16 负责人需求：「点了封禁直接踢下线，显示被封禁 + 原因」）：
     * 服务端给的是 401 + `errorCode=ACCOUNT_BANNED` + 「账号已被封禁：<原因>（解封时间：…）」，
     * 走这里而不是 [onSessionKicked]（那句通用文案看不出账号被封，正是本次要修的用户可见缺口）。
     * 落地动作与"被顶下线"完全一致：清本地令牌 → `RootGate` 回登录页 →
     * `SessionKickListener` 弹**不可关闭**提示（封禁版带原因与解封时间 + 「重新登录」/「退出」）。
     */
    ApiClient.onAccountBanned = _handleAccountBanned;
    // 等级变更 WS 推送 → 立即刷新本地资料（需求 #9，跨页面/跨端同步）
    RealtimeClient.onLevelChanged = () {
      fetchMe().catchError((_) => AuthMe.fromJson(const {}));
    };
  }

  static final AuthStore instance = AuthStore._();

  static const _storage = FlutterSecureStorage();
  static const _accessKey = 'auth_access_token';
  static const _refreshKey = 'auth_refresh_token';

  /// **测试/出图专用**：禁用安全存储读写。
  ///
  /// `flutter_secure_storage` 在 `flutter test` 里没有平台实现，任何 read/write 都会抛
  /// `MissingPluginException`。身份切换路径（切身份写标记、绑定写 companion 令牌、解绑删令牌）
  /// 全部会碰存储，所以必须有一个显式的开关把它关掉（默认 false = 生产行为逐字节不变）。
  @visibleForTesting
  static bool debugStorageDisabled = false;

  /// **测试专用**：记录每一次"要写安全存储"的调用（key + 值）。
  ///
  /// 为什么需要它：`debugStorageDisabled = true` 时写操作被**静默跳过**，于是"管理员令牌
  /// 绝不落盘"这条安全底线在测试里**无法被证伪**（假接口全绿也可能藏着一次落盘）。
  /// 这里记录的是**尝试写入的意图**（在跳过之前记录），测试据此断言：
  /// 绑定/切换管理员的过程中，**没有任何一次写带着管理员令牌的键或值**。
  /// 生产路径零影响（不注册时为 null，什么都不做）。
  @visibleForTesting
  static void Function(String key, String? value)? debugOnStorageWrite;

  Future<String?> _read(String key) async => debugStorageDisabled ? null : _storage.read(key: key);

  Future<void> _write(String key, String? value) async {
    debugOnStorageWrite?.call(key, value);
    if (debugStorageDisabled) return;
    if (value == null) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  Future<void> _delete(String key) async {
    debugOnStorageWrite?.call(key, null);
    if (debugStorageDisabled) return;
    await _storage.delete(key: key);
  }

  // ---- 合并双端 · 身份切换（方案甲）：companion（伴随）会话的第二组 token 槽 ----
  static const _companionAccessKey = 'identity_companion_access';
  static const _companionRefreshKey = 'identity_companion_refresh';
  static const _identityKey = 'identity_active';
  final ApiClient _api = ApiClient();

  String? _accessToken;
  String? _refreshToken;
  AuthMe? _me;
  bool _initialized = false;
  String? _authFailureMessage;

  /// 当前这条 [authFailureMessage] 是不是**封禁**（`errorCode=ACCOUNT_BANNED`）——
  /// 决定 `SessionKickListener` 弹哪一种不可关闭提示（封禁版带原因/解封时间 + 「退出」）。
  bool _authBanned = false;

  /// 当前生效身份（老板 / 打手）。**默认老板**：未绑定过的用户走的就是原来那条路径。
  AppIdentity _identity = AppIdentity.boss;

  /// **身份"代"**：每一次「重新绑定 / 切换身份**成功**」+1（唯一入口 [_bumpIdentityEpoch]）。
  ///
  /// 它服务的具体事故（负责人 2026-10-06 实测，本批修复）：
  /// 打手态接单大厅留下「分部列表加载失败（未登录）」，用户**重新绑定成功后那句话还挂着**，
  /// 非得手点「重试」。原因是**这一整段过程中 `workerIdentity` 一直为 true**（companion 令牌换了，
  /// 身份没变）→ 宿主 `HomeShell` 的 `AnimatedSwitcher` 因为"同 key + 同 widget 类型"**复用整棵子树**
  /// → 大厅页 State（含 `_divisionError`）原样留着，没人再去拉一次。
  ///
  /// 为什么用"代"而不是让页面自己比对令牌：
  /// companion 令牌在 12h 内也会**续期**（`POST /user/identity/refresh`），拿令牌当判据会把
  /// "续期"也当成一次重绑去重拉；这里只认**身份级成功动作**（重绑 / 切身份 / 解绑 / 被顶下线）。
  ///
  /// 刻意**不**把 [debugSetIdentity] / [fetchWorkerMe] / [fetchIdentityStatus] 这类算进来 ——
  /// 那些是"摆状态"与"刷新资料"，不是一次成功切换；算进来会让既有出图与单测凭空多一轮请求。
  int _identityEpoch = 0;

  /// 身份"代"（见 [_identityEpoch] 的说明）。页面**只读**它；不要在任何地方自己 +1。
  int get identityEpoch => _identityEpoch;

  /// 记一次"身份级成功动作"——**唯一出口**，不要在别处 `_identityEpoch += 1`
  void _bumpIdentityEpoch() => _identityEpoch += 1;

  /// 打手态用的伴随令牌（`POST /user/identity/bind` 签发；**不顶掉打手的工作端登录**）
  String? _companionToken;
  String? _companionRefreshToken;

  /// 打手态身份（用 companion token 调 `GET /auth/me` 得到：工号/昵称/分部权限）
  AuthMe? _workerMe;

  // ---- 管理员态（充值审核 · 受限会话；负责人 2026-10-06 方案②）----
  //
  // **刻意只放内存、不进安全存储**：管理员态冷启动必定回到老板态，要再进必须重新输入
  // 管理员账密（审核权限不静默常驻）。因此这里没有 `_adminAccessKey` 之类的落盘槽，
  // `init()` 也不恢复它 —— 与打手态（companion 令牌落盘、可免密切回）是**有意的差别**。

  /// 受限管理员令牌（服务端若不下发独立令牌 → 保持 null，管理员态沿用 primary，见 [activeToken]）
  String? _adminToken;

  /// 管理员受限刷新令牌（服务端下发才有）
  String? _adminRefreshToken;

  /// 当前管理员态信息（`GET /recharge/me` / 绑定响应）：谁在审、还有多少待审核
  RechargeAdminMe? _adminMe;

  /// **进管理员态之前是哪个身份**（2026-10-06 直切专项）
  ///
  /// 用途只有一个：管理员会话**被动失效**（401 / 被移出白名单 / 12h 到期）时，
  /// [dropAdminIdentity] 必须把人送回**他刚才离开的那个身份** ——
  /// 「打手态 → 点切换为管理员 → 目标令牌已失效」这条路径上，如果按"有没有打手会话"
  /// 去猜，会把人扔回老板态（用户会觉得"我明明在打手态，怎么点一下掉到老板态了"）；
  /// 更糟的是若两边都不满足，就会变成"哪边都不是"的空白态 —— 本次验收明令禁止。
  AppIdentity _identityBeforeAdmin = AppIdentity.boss;

  /// 绑定状态（`GET /user/identity`；老板态「我的」页身份分组的数据源）
  IdentityBindingStatus? _identityStatus;

  /// 切换过程中的人性化提示（弹层内细带/Toast 用；不参与任何判定）
  String? _identityBusyLabel;

  /// 打手态被动失效的提示（被顶下线/解绑/绑定失效）——**刻意不复用 [authFailureMessage]**：
  /// 那条是"整机登录失效"，会弹「重新登录」并把人踢到登录页；
  /// 而打手态失效时老板态会话仍然完全有效，只是"打手身份没了"，不能把人踢出去。
  String? _identityNotice;

  bool get initialized => _initialized;
  bool get loggedIn => _accessToken != null;
  String? get accessToken => _accessToken;
  AuthMe? get me => _me;

  /// 当前生效身份
  AppIdentity get identity => _identity;

  /// 是否处于打手态（**有伴随令牌才算**：令牌被清掉时即便身份标记还在也按老板态渲染）
  bool get workerIdentity => _identity == AppIdentity.worker && _companionToken != null;

  /// 打手态的伴随令牌（仅调试/测试与切换逻辑使用；页面一律用 [activeToken]）
  String? get companionToken => _companionToken;

  /// 是否处于**管理员态**（充值审核；[AppIdentity.admin] 标记 + 会话信息在位才算）
  bool get adminIdentity => _identity == AppIdentity.admin && _adminMe != null;

  /// 管理员受限令牌（服务端没下发独立令牌时为 null —— 此时 [activeToken] 回落 primary）
  String? get adminToken => _adminToken;
  String? get adminRefreshToken => _adminRefreshToken;

  /// 当前管理员态信息（谁在审 + 待审核数）；非管理员态为 null
  RechargeAdminMe? get adminMe => _adminMe;

  /// **当前身份该用的 token**
  ///
  /// - 管理员态 → 受限管理员令牌（服务端没发就沿用 primary，见 [bindRechargeAdmin] 注释）；
  /// - 打手态 → companion；
  /// - 老板态 → primary（原 token，逐字节不变）。
  ///
  /// 这是"身份隔离"的唯一出口：打手态/管理员态的页面全部用 `AuthStore.instance.activeToken`，
  /// 老板态页面继续用 `accessToken`（= primary），几条路径物理上不会互相拿到对方的令牌。
  String? get activeToken => adminIdentity
      ? (_adminToken ?? _accessToken)
      : (workerIdentity ? _companionToken : _accessToken);

  /// 打手态资料（工号/昵称/分部权限），未拉到时为 null
  AuthMe? get workerMe => _workerMe;

  /// **当前身份的本人资料**：打手态 → 打手资料；老板态 → 老板资料（原样）
  ///
  /// 聊天页这类"两端共用同一个页面"的地方一律用它取昵称/头像/ID ——
  /// 否则打手态会顶着老板的头像和昵称发消息（身份串味）。
  AuthMe? get activeMe => workerIdentity ? (_workerMe ?? _me) : _me;

  /// **当前身份有没有客服权限**（负责人 2026-10-08：打手态底部第 4 项「客服」的出现条件）
  ///
  /// 唯一数据源 = [AuthMe.canServeCustomer]，即 `GET /auth/me` 的 `raw['worker']['canServeCustomer']`
  /// （服务端 `auth.service.ts` / `worker-identity.service.ts` 都在下发）——**没有第二份权限来源**，
  /// 客户端也**不做**任何本地开关/缓存标记：权限随 `fetchMe()` / `fetchWorkerMe()` 刷新而变。
  ///
  /// 取 [activeMe]（打手态 → 打手资料；老板态 → 老板资料）而不是写死 `workerMe`：
  /// 老板态的 `/auth/me` 里没有 `worker` 段 → 天然为 false → **老板态底部导航一行不改**；
  /// 打手态取的是打手自己的 `worker` 段 → 门控与"这本就是打手的能力"语义一致。
  ///
  /// ⚠️ 这只是**入口门控**（"要不要显示这个 tab"），不是授权判定：
  /// 服务端对 `GET /worker/cs/hall` 与 `POST .../claim` **每请求实时查库**，
  /// 权限刚被撤销时接口会回中文 403，页面据此切成说明态（见 `worker_cs_hall_page.dart`）。
  bool get canServeCustomer => activeMe?.canServeCustomer == true;

  /// 绑定状态（可能为 null = 还没拉过）
  IdentityBindingStatus? get identityStatus => _identityStatus;

  /// 已绑定的打手档案（优先取实时拉到的打手资料段）
  IdentityWorkerProfile? get boundWorker => _identityStatus?.worker;

  /// 切换中的提示文案（非空 = 正在切换；弹层据此显示顶部细带）
  String? get identityBusyLabel => _identityBusyLabel;

  /// 打手态被动失效提示（UI 取走后调用 [clearIdentityNotice]）
  String? get identityNotice => _identityNotice;

  /// 测试注入：跳过安全存储直接设置会话（widget 测试渲染需登录的页面用）
  @visibleForTesting
  void debugSetSession({String? accessToken, String? refreshToken, AuthMe? me}) {
    _accessToken = accessToken;
    if (refreshToken != null) _refreshToken = refreshToken;
    if (me != null) _me = me;
    notifyListeners();
  }

  /// 测试/出图注入：直接把当前身份、伴随令牌与绑定关系摆好（**不落安全存储、不发请求**）
  @visibleForTesting
  void debugSetIdentity({
    AppIdentity identity = AppIdentity.boss,
    String? companionToken,
    String? companionRefreshToken,
    IdentityBindingStatus? status,
    AuthMe? workerMe,
    String? notice,
    RechargeAdminMe? adminMe,
    String? adminToken,
    String? adminRefreshToken,
  }) {
    _identity = identity;
    _companionToken = companionToken;
    if (companionRefreshToken != null) _companionRefreshToken = companionRefreshToken;
    if (status != null) _identityStatus = status;
    if (workerMe != null) _workerMe = workerMe;
    if (adminMe != null) _adminMe = adminMe;
    if (adminToken != null) _adminToken = adminToken;
    if (adminRefreshToken != null) _adminRefreshToken = adminRefreshToken;
    _identityNotice = notice;
    notifyListeners();
  }

  /// 测试/出图注入：清空全部身份状态（含伴随时段内的临时标记）
  @visibleForTesting
  void debugClearIdentity() {
    _identity = AppIdentity.boss;
    _identityBeforeAdmin = AppIdentity.boss;
    _companionToken = null;
    _companionRefreshToken = null;
    _workerMe = null;
    _identityStatus = null;
    _identityBusyLabel = null;
    _identityNotice = null;
    _adminToken = null;
    _adminRefreshToken = null;
    _adminMe = null;
    notifyListeners();
  }

  /// 会话被踢出提示（"账号已在其他设备登录"等），UI 弹出后调用 [clearAuthFailure] 清除
  String? get authFailureMessage => _authFailureMessage;

  /// 这条提示是不是**封禁**（见 [_authBanned]）；UI 据此切标题与按钮（封禁版：不可关闭 + 「退出」）
  bool get authFailureIsBanned => _authBanned;

  /// 启动时恢复会话：本地有 token 则尝试拉取 me 验证有效性，失效则清理
  ///
  /// 合并双端新增（**老板态路径逐字节不变**）：额外恢复"上次停在哪个身份"。
  /// 恢复打手态要同时满足三条，缺一条就回老板态（宁可让用户重切一次，也不能用一个
  /// 失效/已解绑的伴随令牌把人送进打手态）：
  ///   ① 本地有 companion 令牌；② `GET /user/identity` 说仍处于绑定中；③ 拉得到打手资料。
  /// 任何一步抛错都**静默回落老板态**，绝不阻塞启动、也绝不把用户踢下线。
  Future<void> init() async {
    _accessToken = await _read(_accessKey);
    _refreshToken = await _read(_refreshKey);
    _companionToken = await _read(_companionAccessKey);
    _companionRefreshToken = await _read(_companionRefreshKey);
    final savedIdentity = AppIdentity.fromKey(await _read(_identityKey));
    if (_accessToken != null) {
      try {
        await fetchMe();
      } on ApiException catch (e) {
        // 仅认证失败（401）尝试刷新；网络错误保留本地会话，恢复后可用（docs/07）
        if (e.code == 401) {
          await _tryRefresh();
        }
      }
      if (savedIdentity == AppIdentity.worker && _companionToken != null && _accessToken != null) {
        await _restoreWorkerIdentity();
      }
    }
    _initialized = true;
    notifyListeners();
  }

  /// 冷启动恢复打手态（三条件校验，失败静默回落老板态）
  Future<void> _restoreWorkerIdentity() async {
    try {
      final status = await fetchIdentityStatus();
      if (!status.bound) {
        await _clearCompanion();
        return;
      }
      await fetchWorkerMe();
      if (_workerMe == null) {
        await _clearCompanion();
        return;
      }
      _identity = AppIdentity.worker;
      _bumpIdentityEpoch(); // 冷启动恢复成打手态也记一代：页面据此知道"手上那份可能过期了"
      _syncIdentityScope(reconnect: false);
    } catch (_) {
      // 网络异常/令牌失效/绑定已解绑：一律回落老板态（不清 primary，不动用户登录）
      await _clearCompanion();
    }
  }

  /// 登录。`api` 仅测试注入用（不传 → 全局单例客户端）；生产路径行为不变。
  Future<void> login({
    required String username,
    required String password,
    required String role,
    ApiClient? api,
  }) async {
    final resp = await (api ?? _api).request(
      'POST',
      '/auth/login',
      data: {'username': username, 'password': password, 'role': role},
    );
    await _completeLogin(resp);
  }

  /// 邮箱验证码登录（`POST /auth/login` 带 `email` + `emailCode`；负责人 2026-10-10 拍板 1）
  ///
  /// 与密码登录是**同一个入口、同一条落地链路**（[_completeLogin]）：服务端签发的仍是一枚
  /// **primary** 会话 → 「单设备登录」语义与密码登录完全一致（会顶掉其它设备，既有的
  /// 「账号已在其他设备登录」提示链路照常触发）。
  ///
  /// 请求体**不带 username/password**：服务端 DTO 见到 `email` 就忽略那两项
  /// （`@ValidateIf((o) => !o.email)`），硬塞一个 username 只会让人误以为走了密码路径。
  ///
  /// 失败一律是服务端中文 400「邮箱或验证码错误」（防枚举：**同一句话**同时覆盖
  /// "该邮箱未绑定任何账号"/"验证码不对"/"过期"/"错满 5 次作废"）——界面**照实展示**，
  /// 不得改写成"该邮箱未注册"。
  Future<void> loginByEmailCode({
    required String email,
    required String emailCode,
    required String role,
    ApiClient? api,
  }) async {
    final resp = await (api ?? _api).request(
      'POST',
      '/auth/login',
      data: {'email': email.trim(), 'emailCode': emailCode.trim(), 'role': role},
    );
    await _completeLogin(resp);
  }

  /// 登录成功后的**唯一**落地链路（密码登录与邮箱验证码登录共用）
  ///
  /// 顺序与历史**逐字一致**（原 [login] 的四步原样搬来，不新增也不省略）：
  /// ① 换号登录 = 换人 → 清掉上一个账号留下的打手身份（否则新老板会顶着旧 companion）；
  /// ② 落令牌（安全存储 + 会话缓存隔离）；
  /// ③ `GET /auth/me` 刷新身份态（等级/权限/资料）；
  /// ④ `notifyListeners()` → 老板端 `RootGate` 据此切主框架（更新检查与单设备提示链路一行未改）。
  ///
  /// 之所以抽出来：邮箱码登录若自己再写一遍"落令牌"，两条路径必然有一天分叉
  /// （漏清 companion、漏刷 me、漏通知都会变成"登录成功但界面不动"）。
  Future<void> _completeLogin(Map<String, dynamic> resp) async {
    await _clearCompanion();
    await _saveTokens(resp['data'] as Map<String, dynamic>);
    await fetchMe();
    notifyListeners();
  }

  /// 注册。`api` 仅测试注入用（不传 → 全局单例客户端）。
  ///
  /// 邮箱扩展（负责人 2026-10-05）：`email` / `emailCode` **都是可选参数，默认值与旧版完全一致**
  /// （都不传 → 请求体里连键都不出现，老后端与老行为零影响）。
  /// 传了 `email` 时后端强制要求 `emailCode`（缺失返回中文 400「请填写邮箱验证码」）。
  Future<void> register({
    required String username,
    required String password,
    String? nickname,
    String? email,
    String? emailCode,
    ApiClient? api,
  }) async {
    final mail = email?.trim();
    final code = emailCode?.trim();
    await (api ?? _api).request(
      'POST',
      '/auth/register',
      data: {
        'username': username,
        'password': password,
        if (nickname != null) 'nickname': nickname,
        // 只有真正填了邮箱才带这两个键：空白/未填一律不带（保证"旧注册路径"逐字节不变）
        if (mail != null && mail.isNotEmpty) 'email': mail,
        if (mail != null && mail.isNotEmpty && code != null && code.isNotEmpty) 'emailCode': code,
      },
    );
  }

  /// 获取邮箱验证码（`POST /auth/email/code`，负责人 2026-10-05）
  ///
  /// - [scene] 用 [EmailCodeScene.register] / [EmailCodeScene.reset]；
  /// - 调用方**必须先做本地邮箱格式校验**（[isEmailFormatValid]），不合法不要发这一次请求；
  /// - 服务端限流：同邮箱 60s / 同邮箱 5 次·小时 / 同 IP 10 次·小时（中文 429）；
  /// - **响应绝不回显验证码**；界面提示用 [emailCodeSentHint]（找回密码场景必须防枚举）。
  Future<EmailCodeSendResult> sendEmailCode({
    required String email,
    required String scene,
    ApiClient? api,
  }) async {
    final resp = await (api ?? _api).request(
      'POST',
      '/auth/email/code',
      data: {'email': email.trim(), 'scene': scene},
    );
    return EmailCodeSendResult.fromJson(_dataOf(resp));
  }

  /// 用邮箱验证码重置密码（`POST /auth/password/reset`，负责人 2026-10-05）
  ///
  /// 不依赖旧密码；成功后服务端**吊销该账号全部会话**（其它设备需重新登录）。
  /// 工作端账号同样可用（前提是该账号已绑定邮箱；未绑定邮箱时服务端按防枚举策略
  /// 返回与成功一致的响应，因此界面文案必须保持「若该邮箱已绑定…」，不得提示"邮箱不存在"）。
  Future<PasswordResetResult> resetPassword({
    required String email,
    required String code,
    required String newPassword,
    ApiClient? api,
  }) async {
    final resp = await (api ?? _api).request(
      'POST',
      '/auth/password/reset',
      data: {'email': email.trim(), 'emailCode': code.trim(), 'newPassword': newPassword},
    );
    return PasswordResetResult.fromJson(_dataOf(resp));
  }

  /// `GET /user/email`：当前账号的邮箱状态（**脱敏**邮箱 + 是否已验证）—— 设置页邮箱行的唯一数据源
  ///
  /// 为什么必须走服务端：邮箱是**登录凭据**，换设备、被后台改过、换绑过都要显示真值。
  /// 本地存一个"上次绑过什么"只会在真值与缓存不一致时骗用户（而且那等于本地留一份邮箱明文）。
  /// 未绑定返回 200 `bound:false`（不是错误）；异常**原样抛出**，由页面渲染"获取失败/重试"。
  ///
  /// [forceRefresh] 默认 true：设置页每次进都要真值（SWR 缓存对"凭据状态"这种一次性读不划算）。
  Future<EmailBindStatus> fetchEmailStatus({ApiClient? api, bool forceRefresh = true}) async {
    final resp = await (api ?? _api).request(
      'GET',
      '/user/email',
      token: _accessToken,
      forceRefresh: forceRefresh,
    );
    return EmailBindStatus.fromJson(_dataOf(resp));
  }

  /// `POST /user/email/bind`：绑定 / 换绑邮箱（**当前密码 + 新邮箱验证码**，负责人 2026-10-10 拍板 2）
  ///
  /// 与登录/改密**完全不同的一类动作**：不动会话、不签令牌、不顶设备（单设备铁律不涉及），
  /// 只是账号设置页的一次凭据写入。绑定与换绑是**同一个接口**（换绑 = 覆盖旧邮箱），
  /// 用响应里的 [EmailBindResult.rebound] 区分文案。
  ///
  /// 失败**原样抛出 [ApiException]**（服务端中文原文：`该邮箱已被其他账号绑定`(409) /
  /// `验证码错误`・`验证码已过期，请重新获取`・`验证码错误次数过多，请重新获取`(400) / `密码错误`(400)），
  /// 由页面映射到行内红字或浮层 —— 这里**绝不吞错、绝不改写成客户端自造文案**。
  Future<EmailBindResult> bindEmail({
    required String email,
    required String code,
    required String password,
    ApiClient? api,
  }) async {
    final resp = await (api ?? _api).request(
      'POST',
      '/user/email/bind',
      token: _accessToken,
      data: {'email': email.trim(), 'emailCode': code.trim(), 'password': password},
    );
    return EmailBindResult.fromJson(_dataOf(resp));
  }

  /// 统一响应里的 `data`（服务端失败时是 null；成功时是对象）
  Map<String, dynamic>? _dataOf(Map<String, dynamic> resp) {
    final data = resp['data'];
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  Future<void> logout() async {
    ApiCache.instance.clear(); // 退出登录清缓存，避免串号
    if (_accessToken != null) {
      try {
        await _api.request('POST', '/auth/logout', token: _accessToken, data: {'refreshToken': _refreshToken});
      } catch (_) {
        // 服务端失败也继续本地清理
      }
    }
    await _clear();
    notifyListeners();
  }

  // =====================================================================================
  // 合并双端 · 身份切换（方案甲，负责人 2026-10-06 拍板）
  // 全部新增；未绑定过的用户走不到这里，老板态既有路径逐字节不变。
  // =====================================================================================

  /// `GET /user/identity`：当前绑定状态（未绑定返回 200 `bound:false`，不是错误）
  ///
  /// **必须用 primary token**：`/user/identity/*` 是老板侧能力，伴随会话访问会被守卫 403
  /// （否则打手态就能自行解绑/换绑，等于越权）。
  Future<IdentityBindingStatus> fetchIdentityStatus({ApiClient? api, bool forceRefresh = true}) async {
    final resp = await (api ?? _api).request(
      'GET',
      '/user/identity',
      token: _accessToken,
      forceRefresh: forceRefresh,
    );
    final status = IdentityBindingStatus.fromJson(_dataOf(resp) ?? const <String, dynamic>{});
    _identityStatus = status;
    notifyListeners();
    return status;
  }

  /// `GET /auth/me`（**用 companion token**）：打手态的工号/昵称/分部权限
  ///
  /// 伴随会话白名单里明确放行了 `GET /auth/me`，因此这里不必依赖 `/user/identity` 的摘要，
  /// 拿到的就是打手自己的资料（含 `worker.divisionPermissions`，服务端实时查库）。
  Future<AuthMe?> fetchWorkerMe({ApiClient? api}) async {
    final token = _companionToken;
    if (token == null) return null;
    final resp = await (api ?? _api).request('GET', '/auth/me', token: token);
    _workerMe = AuthMe.fromJson(resp['data'] as Map<String, dynamic>);
    notifyListeners();
    return _workerMe;
  }

  /// `POST /user/identity/bind`：校验打手账密 → 建绑定 → **立即切到打手态**
  ///
  /// 老板自己的 token 不变（服务端 `bossTokenUnchanged:true`），伴随令牌只用于打手态。
  /// 失败时**原样抛出 [ApiException]**（文案是服务端的中文原文，弹层只做分类不改字）。
  ///
  /// [autoSwitch] = false 时**只建绑定不发身份**：给"绑定成功但一个分部权限都没有"这条
  /// 高频路径留出口（设计稿 A2 `noperm`：先在弹层里告知，用户仍可选择进入或留在老板态）。
  Future<IdentityBindResult> bindWorkerIdentity({
    required String username,
    required String password,
    ApiClient? api,
    bool autoSwitch = true,
  }) async {
    _identityBusyLabel = '正在绑定并切换身份…';
    notifyListeners();
    try {
      final resp = await (api ?? _api).request(
        'POST',
        '/user/identity/bind',
        token: _accessToken,
        data: {'username': username.trim(), 'password': password},
      );
      final result = IdentityBindResult.fromJson(_dataOf(resp) ?? const <String, dynamic>{});
      _companionToken = result.companionToken.isEmpty ? null : result.companionToken;
      _companionRefreshToken = result.companionRefreshToken.isEmpty ? null : result.companionRefreshToken;
      await _write(_companionAccessKey, _companionToken);
      await _write(_companionRefreshKey, _companionRefreshToken);
      _identityStatus = IdentityBindingStatus(
        bound: true,
        activeCount: 1,
        maxPerBoss: 0,
        message: '',
        bindings: [
          IdentityBinding(
            bindingId: result.bindingId,
            status: 'active',
            boundAt: null,
            worker: result.worker,
          ),
        ],
      );
      if (autoSwitch) {
        // 立即切到打手态（同一处完成"绑定 + 切换"，用户不需要再点一次）
        await switchToWorker();
        // 打手资料（工号/昵称/分部权限）用伴随令牌拉一次；失败不阻塞进入打手态
        try {
          await fetchWorkerMe(api: api);
        } catch (_) {
          // 静默：「我的」页会用绑定摘要兜底展示工号与分部权限
        }
      }
      return result;
    } finally {
      _identityBusyLabel = null;
      notifyListeners();
    }
  }

  /// 切到打手态（要求本地已有 companion 令牌）
  ///
  /// **身份隔离的三件事**（设计稿风险 ④/R3）：
  /// ① 换缓存作用域并清空旧缓存（`ApiCache.beginSession`）；
  /// ② 断掉当前 WS（老板态的订阅随 socket 一起销毁，红点不会串到打手态）；
  /// ③ 用 companion 令牌重连（打手态的事件只进打手态页面）。
  ///
  /// **打手态与管理员态可以并存**（2026-10-06 负责人截图反馈后的定案）：
  /// 两者是**不同 kind 的受限会话**（`companion` / `recharge`），服务端允许同时存在；
  /// 客户端只是"当前用哪一枚令牌 + 挂哪个 shell"。所以这里**不再丢弃管理员会话**
  /// —— 丢掉就没法"点一下切回来"了（那正是本次要修的体验问题）。
  Future<void> switchToWorker() async {
    if (_companionToken == null) return;
    _identity = AppIdentity.worker;
    /**
     * **无条件 +1**（哪怕本来就在打手态）——这正是"重新绑定"的形状：
     * 绑定成功会装上一枚**新的** companion 令牌，身份标记没变、会话已经换了，
     * 屏上那些"用旧令牌得到的失败结论"必须作废并回源（见 [_identityEpoch]）。
     *
     * 下面两行**一行未改**：换令牌后仍然要写身份标记 + 重连 WS
     * （旧 socket 握的是已失效的 companion，不重连就会一直收不到单）。
     */
    _bumpIdentityEpoch();
    await _write(_identityKey, _identity.key);
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// 切回老板态：**清理当前身份的作用域**（缓存 / WS 订阅 / 未读计数全部按身份重建）
  ///
  /// 打手那份 companion 令牌会被清掉吗？—— **不会**。设计稿 A5 明说
  /// 「切换后打手账号仍保持绑定，下次可免密切回」，所以这里只换身份，不动绑定关系；
  /// 要断开绑定得走 [unbindWorkerIdentity]。
  ///
  /// **管理员会话同样保留（本次语义变更）**：在同一 App 运行期内**留在内存**，
  /// 于是"老板 ←→ 管理员"可以来回点；但**仍然绝不落盘** —— 冷启动后
  /// [adminBound] 为 false，必须重新输入管理员账密（安全底线不变，见 [init]）。
  /// 会话真正失效（401 / 被移出白名单 / 12h 到期）时由 [dropAdminIdentity] 丢弃。
  Future<void> switchToBoss() async {
    if (_identity == AppIdentity.boss) {
      // 已经是老板态：只做一次作用域对齐（幂等）；不再顺手丢管理员会话
      _syncIdentityScope(reconnect: false);
      return;
    }
    _identity = AppIdentity.boss;
    _bumpIdentityEpoch(); // 身份级动作（切走/解绑/失效共用这一处语义：屏上结论作废）
    await _write(_identityKey, AppIdentity.boss.key);
    _workerMe = null;
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// 弹出/清空"切换中"提示（弹层关闭时调用）
  void clearIdentityBusy() {
    if (_identityBusyLabel == null) return;
    _identityBusyLabel = null;
    notifyListeners();
  }

  /// 取走打手态失效提示（UI 展示后必须调用，避免重复弹）
  void clearIdentityNotice() {
    if (_identityNotice == null) return;
    _identityNotice = null;
    notifyListeners();
  }

  /// `POST /user/identity/unbind`：解绑（保留历史行；服务端立即吊销该绑定的伴随会话）
  ///
  /// 解绑后**必定回到老板态**：伴随令牌已失效，停在打手态只会看到满屏 401。
  Future<void> unbindWorkerIdentity({ApiClient? api, String? bindingId}) async {
    final id = bindingId ?? _identityStatus?.bindingId ?? '';
    await (api ?? _api).request(
      'POST',
      '/user/identity/unbind',
      token: _accessToken,
      data: {if (id.isNotEmpty) 'bindingId': id},
    );
    await _clearCompanion();
    _identityStatus = const IdentityBindingStatus(
      bound: false,
      activeCount: 0,
      maxPerBoss: 0,
      message: '',
      bindings: [],
    );
    _identity = AppIdentity.boss;
    _bumpIdentityEpoch();
    await _write(_identityKey, AppIdentity.boss.key);
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// 身份作用域对齐：缓存 + WS（**切换身份的第三条铁律：切回老板态必须彻底**）
  ///
  /// [reconnect] = false 用于冷启动恢复：此时还没有页面建过订阅，不主动建连
  /// （避免测试环境里起真 socket）。
  ///
  /// **管理员态不建实时连接**：充值审核是拉取式界面（列表 + 下拉刷新），
  /// 不需要实时通道；而且受限会话本来就没有 WS 授权，连上去只会反复失败重连。
  /// 因此进管理员态只做"断开"，不做"重连"。
  void _syncIdentityScope({required bool reconnect}) {
    ApiCache.instance.beginSession('identity:${_identity.key}');
    if (!reconnect) return;
    RealtimeClient.shared.disconnect();
    if (_identity == AppIdentity.admin) return;
    final token = activeToken;
    if (token != null && token.isNotEmpty) {
      RealtimeClient.shared.connect(token: token);
    }
  }

  // =====================================================================================
  // 管理员态（充值审核 · 受限会话；负责人 2026-10-06 方案②）
  // 全部新增；与老板态/打手态的既有路径互不影响。
  // =====================================================================================

  /// `POST /user/identity/bind-recharge-admin`：校验管理员账密 → 建**受限会话** → 进管理员态
  ///
  /// 三条口径（与 docs/03 / docs/04 对齐）：
  /// 1. **用 primary 令牌请求**（这是老板侧能力：只有老板本人能把自己的 App 切到审核态）；
  /// 2. 服务端签发 `rechargeToken` / `rechargeRefreshToken`（`kind='recharge'`、TTL 12h、
  ///    **不顶 primary**）→ 管理员态全部请求用这枚受限令牌；
  /// 3. 失败**原样抛出 [ApiException]**（文案是服务端中文原文，弹层只分类不改字）。
  Future<RechargeAdminSession> bindRechargeAdmin({
    required String username,
    required String password,
    ApiClient? api,
    bool autoSwitch = true,
  }) async {
    _identityBusyLabel = '正在验证管理员账号…';
    notifyListeners();
    try {
      final resp = await (api ?? _api).request(
        'POST',
        '/user/identity/bind-recharge-admin',
        token: _accessToken,
        data: {'username': username.trim(), 'password': password},
      );
      final session = RechargeAdminSession.fromJson(_dataOf(resp) ?? const <String, dynamic>{});
      _adminToken = session.hasDedicatedToken ? session.token : null;
      _adminRefreshToken = session.refreshToken.isEmpty ? null : session.refreshToken;
      _adminMe = RechargeAdminMe(
        admin: session.admin,
        pendingCount: session.pendingCount,
        expiresIn: session.expiresIn,
      );
      if (autoSwitch) await switchToAdmin();
      return session;
    } finally {
      _identityBusyLabel = null;
      notifyListeners();
    }
  }

  /// 进管理员态（要求本地已有管理员会话信息）
  ///
  /// **记下"从哪来"**（[_identityBeforeAdmin]）：管理员会话失效时要原路退回 ——
  /// 这是"切换失败要能回退、绝不出现两边都不是的空白态"这条验收要求的落点。
  /// 已经在管理员态时重复调用是幂等的（不会把"来路"覆盖成 manager 自己）。
  Future<void> switchToAdmin() async {
    if (_adminMe == null) return;
    if (_identity != AppIdentity.admin) _identityBeforeAdmin = _identity;
    _identity = AppIdentity.admin;
    _bumpIdentityEpoch();
    // 刻意**不写** `_identityKey`（管理员态不落盘：冷启动一定回老板态）
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// `GET /recharge/me`：刷新管理员态信息（谁在审 + 待审核数）
  ///
  /// 用 [activeToken]（管理员态 → 受限令牌；没独立令牌时就是 primary）。
  Future<RechargeAdminMe> fetchRechargeMe({ApiClient? api}) async {
    final resp = await (api ?? _api).request(
      'GET',
      '/recharge/me',
      token: activeToken,
      forceRefresh: true,
    );
    final me = RechargeAdminMe.fromJson(_dataOf(resp) ?? const <String, dynamic>{});
    _adminMe = me;
    notifyListeners();
    return me;
  }

  /// 待审核数（页头事实行用；没拉到时为 0）
  int get adminPendingCount => _adminMe?.pendingCount ?? 0;

  /// 用服务端返回值刷新管理员态信息（管理员态页面拉到 `/recharge/me` 后调用）
  ///
  /// 只更新"谁在审 + 待审核数"，**不动身份标记**（身份切换只走 [switchToAdmin]/[switchToBoss]）。
  void applyAdminMe(RechargeAdminMe me) {
    _adminMe = me;
    notifyListeners();
  }

  /// 管理员态**被动失效**（被移出白名单 / 会话过期 / 401）：丢管理员会话 + 中文提示
  ///
  /// **回退落点 = 进管理员态之前的那个身份**（[切换前的身份][_identityBeforeAdmin]）：
  /// - 来路是打手态且打手会话还在 → **回打手态**（用户看到的仍是刚离开的那个界面）；
  /// - 其余（来路是老板态 / 打手会话已不在）→ 回老板态。
  ///
  /// 判据刻意**不用** `workerIdentity`（它要求"当前就在打手态"，而此刻当前身份正是管理员，
  /// 恒为 false）—— 用错就会把"打手态 → 管理员"这条路径的人直接扔回老板态，
  /// 也就是首版实现里的那个 bug（`identity_direct_switch_test` ⑤ 抓到）。
  ///
  /// **复用打手态那套 [identityNotice] 机制**：老板态（primary）会话分毫不动，
  /// 绝不走 `_clear()`（那会把老板登出）。幂等：重复调用只生效一次。
  Future<void> dropAdminIdentity(String message) async {
    if (_identity != AppIdentity.admin && _adminMe == null && _adminToken == null) return;
    final backToWorker = _identityBeforeAdmin == AppIdentity.worker && _companionToken != null;
    _clearAdminSession();
    _identity = backToWorker ? AppIdentity.worker : AppIdentity.boss;
    _bumpIdentityEpoch();
    _identityBeforeAdmin = AppIdentity.boss;
    _identityNotice = message.isEmpty ? '管理员身份已失效，请重新验证管理员账号' : message;
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// 本次运行内是否已有一枚**可用的管理员受限会话**（内存里有；与当前身份无关）
  ///
  /// 用途：「切换身份」弹层的管理员卡片据此决定显示「切换为管理员」还是"去验证"。
  /// **刻意只认内存**：管理员令牌不落盘，所以冷启动后这里恒为 false（必须先输账密）。
  bool get adminBound => _adminMe != null;

  /// 清掉管理员会话（内存三件套）——只有"会话真的失效"与"登出"才走这里
  ///
  /// ⚠️ 2026-10-06 语义变更：**切回老板 / 进打手态都不再调用它**
  /// （一次运行内来回切换是高频操作，每次都重新输密码是反人类；不落盘仍是安全底线）。
  void _clearAdminSession() {
    _adminToken = null;
    _adminRefreshToken = null;
    _adminMe = null;
  }

  /// 清掉打手身份相关的本地状态（令牌 + 资料 + 绑定摘要）
  ///
  /// ⚠️ 与 [dropAdminIdentity] 的差别：**这里不再强制 [AppIdentity.boss]** ——
  /// 具体回落到哪个身份由调用方（[_dropWorkerIdentity] / 解绑 / 登出）决定。
  Future<void> _clearCompanion() async {
    _companionToken = null;
    _companionRefreshToken = null;
    _workerMe = null;
    _identity = AppIdentity.boss;
    // 打手会话没了 → "管理员失效后退回打手态"这条来路也随之失效（避免回退到没有令牌的身份）
    _identityBeforeAdmin = AppIdentity.boss;
    await _delete(_companionAccessKey);
    await _delete(_companionRefreshKey);
    await _write(_identityKey, AppIdentity.boss.key);
  }

  /// 打手态失效（被顶下线 / 解绑 / 绑定被撤销）：**只丢打手身份，老板态会话分毫不动**
  ///
  /// 回退落点同 [dropAdminIdentity]：**管理员会话还在就回管理员态**（本次定案的
  /// "切换失败要能回退、不许出现两边都不是的空白态"），否则回老板态。
  Future<void> _dropWorkerIdentity(String message) async {
    if (_companionToken == null) return;
    final keepAdmin = _adminMe != null;
    await _clearCompanion(); // 里面已把 identity 标记写回 'boss'（管理员态同样不落盘）
    _identity = keepAdmin ? AppIdentity.admin : AppIdentity.boss;
    _bumpIdentityEpoch(); // 打手身份被吊销 → 屏上那些"用旧会话得到的结论"一并作废
    _identityNotice = message;
    _syncIdentityScope(reconnect: true);
    notifyListeners();
  }

  /// 401 的令牌维度处理：只有"这次 401 用的就是受限会话令牌"时才动那个身份
  ///
  /// 两条受限会话各自独立：
  /// - 管理员令牌 401 → 丢管理员态（[dropAdminIdentity]）；
  /// - companion（打手）令牌 401 → 丢打手态（[_dropWorkerIdentity]）。
  ///
  /// ⚠️ 服务端若**不给独立管理员令牌**（管理员态沿用 primary），这里的令牌判定就覆盖不到
  /// —— 那种情况下由**管理员态页面自己**捕获 401 并调用 [dropAdminIdentity]
  /// （见 `recharge_admin_shell.dart`）：两条路都汇进同一个落点，行为一致。
  Future<void> _handleUnauthorized(String? token, String message) async {
    if (token == null) return;
    if (_adminToken != null && token == _adminToken) {
      await dropAdminIdentity(message);
      return;
    }
    if (_companionToken == null || token != _companionToken) return;
    await _dropWorkerIdentity(message.isEmpty ? '打手身份已失效，请重新绑定打手账号' : message);
  }

  Future<void> fetchMe() async {
    final resp = await _api.request('GET', '/auth/me', token: _accessToken);
    _me = AuthMe.fromJson(resp['data'] as Map<String, dynamic>);
      notifyListeners(); // 资料变更后立即通知（我的页/主页重建，修复改完不显示）
    // 记录最近登录账号：主题模式按账号恢复（负责人主题系统需求）
    final uname = _me?.username;
    if (uname != null && uname.isNotEmpty) {
      AppSettings.instance.writeLastUsername(uname);
    }
  }

  Future<void> _tryRefresh() async {
    if (_refreshToken == null) {
      await _clear();
      return;
    }
    try {
      final resp = await _api.request('POST', '/auth/refresh', data: {'refreshToken': _refreshToken});
      await _saveTokens(resp['data'] as Map<String, dynamic>);
      await fetchMe();
    } on ApiException catch (e) {
      // 刷新被拒（吊销/过期）才清除；网络错误保留 token 待恢复
      if (e.code == 401) {
        await _clear();
      }
    }
  }

  /// 伴随会话续期（`POST /user/identity/refresh`，公开接口：只吃 companion 的 refreshToken）
  ///
  /// TTL 仍是 12 小时硬上限（服务端定案）：到点必须用打手账密重新切换一次，不会把 12h 续成 30 天。
  Future<void> _tryRefreshCompanion() async {
    final rt = _companionRefreshToken;
    if (rt == null) {
      await _dropWorkerIdentity('打手身份已过期，请重新绑定打手账号');
      return;
    }
    try {
      final resp = await _api.request('POST', '/user/identity/refresh', data: {'refreshToken': rt});
      final data = _dataOf(resp);
      final next = data?['companionToken'] as String?;
      final nextRefresh = data?['companionRefreshToken'] as String?;
      if (next == null || next.isEmpty) {
        await _dropWorkerIdentity('打手身份已过期，请重新绑定打手账号');
        return;
      }
      _companionToken = next;
      _companionRefreshToken = nextRefresh ?? rt;
      await _write(_companionAccessKey, _companionToken);
      await _write(_companionRefreshKey, _companionRefreshToken);
      notifyListeners();
    } on ApiException catch (e) {
      // 解绑/绑定失效/12h 到点：直接回落老板态（网络错误也回落 —— 打手态没有可用令牌了）
      if (e.code != -1) {
        await _dropWorkerIdentity(e.message);
      }
    }
  }

  Future<void>? _refreshing;
  Future<void>? _refreshingCompanion;
  Future<void>? _refreshingRecharge;

  /// 受限管理会话续期（`POST /user/identity/refresh-recharge-admin`，docs/04）
  ///
  /// - 只吃 recharge 的 refreshToken（客户端把非 recharge 令牌打进去会被服务端 401，我们不会那么做）；
  /// - TTL 仍是 **12h 硬上限**（续期不会把它变成 30 天）；被移出白名单 → 401 → 自动回落老板态 + 中文提示；
  /// - 网络类失败（code -1）**不落身份**：受限令牌还在，等下一次请求重试。
  Future<void> _tryRefreshRecharge() async {
    final rt = _adminRefreshToken;
    if (rt == null || rt.isEmpty) {
      await dropAdminIdentity('管理员身份已过期，请重新验证管理员账号');
      return;
    }
    try {
      final resp = await _api.request('POST', '/user/identity/refresh-recharge-admin', data: {'refreshToken': rt});
      final data = _dataOf(resp);
      final next = data?['rechargeToken'] as String? ?? data?['adminToken'] as String?;
      final nextRefresh = data?['rechargeRefreshToken'] as String? ?? data?['adminRefreshToken'] as String?;
      if (next == null || next.isEmpty) {
        await dropAdminIdentity('管理员身份已过期，请重新验证管理员账号');
        return;
      }
      _adminToken = next;
      _adminRefreshToken = nextRefresh ?? rt;
      notifyListeners();
    } on ApiException catch (e) {
      // 被移出白名单 / 会话被顶 / 12h 到点 → 回落老板态（文案取服务端原文）
      if (e.code != -1) await dropAdminIdentity(e.message);
    }
  }

  /// 供 ApiClient.onTokenExpired 调用：刷新令牌并返回新的 accessToken（失败返回 null）。
  /// 并发去重：多个请求同时 401 时只真正刷新一次（避免刷新令牌被反复消耗/竞态）。
  ///
  /// 合并双端（身份切换）：**按"刚刚 401 的那个令牌"选刷新通道** ——
  /// `ApiClient.lastFailedToken` 是 companion → 走 `POST /user/identity/refresh`（换 companion）；
  /// 否则走 `POST /auth/refresh`（与历史行为逐字节一致）。
  /// 直接调用（不经过 ApiClient，如单测/主动续期）时回落到"当前身份"。
  /// 两条通道各自并发去重，互不消耗对方的刷新令牌。
  Future<String?> refreshAccessToken() async {
    final failed = ApiClient.lastFailedToken;
    // 受限管理员令牌：**只走它自己的续期通道** `POST /user/identity/refresh-recharge-admin`
    // （公开接口，只吃 recharge 的 refreshToken；docs/04）。绝不拿 primary 去顶受限会话的请求，
    // 也不拿 recharge 令牌去打 `/auth/refresh`。
    if (failed != null && _adminToken != null && failed == _adminToken) {
      _refreshingRecharge ??= _tryRefreshRecharge().whenComplete(() => _refreshingRecharge = null);
      await _refreshingRecharge;
      return _adminToken;
    }
    final wantCompanion = failed != null ? (_companionToken != null && failed == _companionToken) : workerIdentity;
    if (wantCompanion) {
      _refreshingCompanion ??= _tryRefreshCompanion().whenComplete(() => _refreshingCompanion = null);
      await _refreshingCompanion;
      return _companionToken;
    }
    _refreshing ??= _tryRefresh().whenComplete(() => _refreshing = null);
    await _refreshing;
    return _accessToken;
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    final previous = _accessToken;
    _accessToken = data['accessToken'] as String?;
    _refreshToken = data['refreshToken'] as String?;
    if (_accessToken != null) await _write(_accessKey, _accessToken);
    if (_refreshToken != null) await _write(_refreshKey, _refreshToken);
    // 会话隔离（2026-10-04 性能专项）：令牌换了就是"另一个会话"，
    // 缓存键的 sessionId 必须跟着变并清空旧缓存 —— 否则换号登录后
    // B 账号会先看到 A 账号的列表（SWR 命中同步返回旧值），属于串号。
    _syncCacheSession(previous != _accessToken);
  }

  /// 把当前会话同步给 [ApiCache]（换令牌 = 换会话 → 清缓存 + 改隔离维度）
  ///
  /// 合并双端（身份切换）：这里只处理 **primary 令牌轮换**（老板态换号/刷新）。
  /// 打手态的缓存隔离维度由 [_syncIdentityScope] 用 `identity:worker` 单独设置 ——
  /// 两者是不同维度，不会互相覆盖成"看起来同一个会话"。
  void _syncCacheSession(bool tokenChanged) {
    if (tokenChanged) {
      final t = _accessToken;
      if (t == null || t.isEmpty) {
        ApiCache.instance.endSession();
      } else {
        ApiCache.instance.beginSession('identity:${_identity.key}');
      }
    }
  }

  Future<void> _clear() async {
    /**
     * 【2026-10-07 修「退出登录没退干净」——客户端这一半】
     *
     * 登出前**先把当前挂着的受限会话也注销掉**：`logout()` 只注销 primary 那一对令牌，
     * 而打手态 companion / 管理员态 recharge 是**另外两族会话**（服务端三类各自独立）。
     * 旧实现直接把 `_clearCompanion()` / `_clearAdminSession()` 当"退出"用 —— 那只是
     * **本地删掉令牌**，服务端那两族的行仍是 `revoked=0`，直到 12h TTL 到期为止
     * （刷新令牌还落过盘：`_companionRefreshKey`）。
     * 现在两类受限会话各自 `POST /auth/logout`（都在各自白名单里），请求失败也不阻塞本地清理。
     */
    final String? compToken = _companionToken;
    final String? compRefresh = _companionRefreshToken;
    final String? adminToken = _adminToken;
    final String? adminRefresh = _adminRefreshToken;
    if (compToken != null && compToken.isNotEmpty) {
      _companionToken = null; // 先摘掉，避免 401 拦截器把它当"当前令牌"去续期
      _companionRefreshToken = null;
      await _logoutRestrictedQuietly(compToken, compRefresh);
    }
    if (adminToken != null && adminToken.isNotEmpty) {
      _adminToken = null;
      _adminRefreshToken = null;
      await _logoutRestrictedQuietly(adminToken, adminRefresh);
    }
    _accessToken = null;
    _refreshToken = null;
    _me = null;
    // 登出/被踢：打手身份与管理员会话一并清掉（下次登录必然从老板态开始）
    await _clearCompanion();
    _clearAdminSession();
    _identityStatus = null;
    _identityBusyLabel = null;
    ApiCache.instance.endSession(); // 清缓存并回到匿名维度（防串号）
    await _delete(_accessKey);
    await _delete(_refreshKey);
    // 断开共享实时连接（登出/被踢后 WS 不再持有旧令牌，docs/07）
    RealtimeClient.shared.disconnect();
  }

  /// 注销一枚**受限会话**（companion / recharge）：`POST /auth/logout`
  ///
  /// 为什么受限会话也能打这个接口：服务端两条接口族白名单（`isCompanionAllowedRoute` /
  /// `isRechargeAdminAllowedRoute`）都放行了 `POST /auth/logout`（各自吊销**本族**全部令牌）。
  /// 失败一律吞掉并继续本地清理 —— 登出**绝不能**因为网络失败而把用户卡在已登录界面；
  /// 服务端侧即便这次请求没到，令牌仍受 12h TTL 与"每请求实时校验"双重约束。
  Future<void> _logoutRestrictedQuietly(String accessToken, String? refreshToken) async {
    try {
      await _api.request('POST', '/auth/logout', token: accessToken, data: {
        if (refreshToken != null && refreshToken.isNotEmpty) 'refreshToken': refreshToken,
      });
    } catch (_) {
      // 网络失败/令牌已失效：本地照常清理（不上抛，不阻塞登出流程）
    }
  }

  /// 全局踢出（API 401 或 WS 心跳被顶掉/失效）：清理本地会话并保留提示文案供 UI 展示
  ///
  /// 合并双端的关键分支：**打手态被顶下线 ≠ 整机登录失效**。
  /// 打手态用的是伴随会话，它失效时老板自己的 primary 会话完全有效，
  /// 因此这里只丢打手身份并切回老板态 —— 绝不能走 [_clear]（那会把老板一起登出）。
  Future<void> _handleSessionKicked(String message) async {
    if (_accessToken == null) return; // 已登出/未登录：忽略迟到的踢出事件，避免登录页误弹窗
    if (workerIdentity) {
      await _dropWorkerIdentity(message);
      return;
    }
    await _clear();
    _authBanned = false;
    _authFailureMessage = message;
    notifyListeners();
  }

  /**
   * **账号被封**（服务端 401 + `errorCode=ACCOUNT_BANNED`，或 WS `auth:expired` 带同一机器码）。
   *
   * 三件事，与"被顶下线"同一条落地链路（不另造一套）：
   * ① 清本地令牌（`_clear()`：primary + 两族受限会话 + 缓存 + 断 WS）→ `RootGate` 因此切回登录页；
   * ② 记下**服务端原文**（含原因与解封时间）供 `SessionKickListener` 弹不可关闭提示；
   * ③ 打上"这是封禁"的标记，让提示标题与按钮也跟着变（账户封禁 vs 普通登录失效）。
   *
   * ⚠️ **与 `_handleSessionKicked` 的差别**：这里**不早退**。
   * 封禁时服务端会同时做"吊销令牌 + 主动断开 WS"，两条通知几乎同时到达，
   * 谁先到不确定：若 WS 的通用文案先到（已清令牌），紧随其后的封禁通知仍必须把
   * 提示文案**覆盖成封禁原文**，否则用户最终看到的是「登录已失效」而不是被封原因。
   * 幂等：重复调用只更新同一句话。
   */
  Future<void> _handleAccountBanned(String message) async {
    final text = message.isEmpty ? '账号已被封禁，请联系客服' : message;
    if (_accessToken != null) {
      await _clear();
    }
    _authBanned = true;
    _authFailureMessage = text;
    notifyListeners();
  }

  void clearAuthFailure() {
    _authFailureMessage = null;
    _authBanned = false;
    notifyListeners();
  }

  // =====================================================================================
  // 回前台轻量校验（2026-10-16 负责人需求：封禁秒踢 · 缺口 3「划掉 app 后台还能用」）
  // =====================================================================================

  /// 回前台时**只发一个**轻量请求做会话校验（`GET /auth/me`）。
  ///
  /// 为什么必须有它（负责人原话：「重新划掉 app 后台还能用」）：App 切到后台再回来时，
  /// 此前**不发任何请求**，界面直接用内存里那份数据继续渲染 —— 于是"后台被杀/被封"
  /// 的账号划掉再打开，看起来照常能用（直到用户点了什么才 401）。
  ///
  /// 走 `GET /auth/me` 的三个理由：
  ///  1. **最轻**：一条按主键的单行读，返回体是当前账号资料（跨境 RTT 下也只有这一个往返）；
  ///  2. `/auth/me` 在 `ApiCache.neverCachePrefixes` 里 → **必然回源**，不会被 SWR 缓存糊弄；
  ///  3. 它就是"这枚令牌服务端还认不认"的权威入口：401 + `ACCOUNT_BANNED` 会被全局钩子接住
  ///     （清令牌 + 回登录页 + 不可关闭提示）。
  ///
  /// 刻意**不做**"全量刷新"：不拉订单/消息/首页，不 `notifyListeners()` 重建页面
  /// —— 那些才是"每次切回都卡一下"的来源（`services_page.dart` 已有自己的回前台刷新策略）。
  /// 并发去重：同一时刻只发一个（回前台可能连带来两三个 lifecycle 事件）。
  Future<void> verifySessionOnResume() async {
    final token = _accessToken;
    if (token == null || token.isEmpty) return; // 未登录/已被踢：不发
    if (_resumeCheck != null) return;
    _resumeCheck = _verifySessionOnce(token);
    try {
      await _resumeCheck;
    } finally {
      _resumeCheck = null;
    }
  }

  Future<void> _verifySessionOnce(String token) async {
    try {
      await _api.request('GET', '/auth/me', token: token, forceRefresh: true);
    } catch (_) {
      // 401（含封禁）：全局钩子已经处理（清会话 + 提示）；
      // 网络类失败/服务端错误：**静默**，绝不打扰"只是切了个后台"的用户（失败下次切回再试）。
    }
  }

  Future<void>? _resumeCheck;
}
