library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';

/// ============================================================================
/// 提现链路的**媒体挂载点**（选图 / 裁剪 / 上传）
/// ============================================================================
///
/// ## 为什么需要它
/// 打手态（含提现四页）与管理员态（含提现审核）都住在 `fish_core` 里，而
/// `fish_core` **没有也不该有** `image_picker` / `image_cropper`（那是宿主 App 的平台依赖，
/// 且 core 要同时被老板端与工作端复用）。已有的两条宿主注入先例：
/// 打手态聊天页 `IdentityWorkerChatOpener`、细带点击 `AppIdentityBar.onBandTap`。
///
/// 这里沿用同一套做法：**core 只声明"我需要一份图片字节"，宿主负责怎么拿**。
/// 未注入时不崩、不静默 —— 给一句中文可上屏原因（见 [unavailableMessage]）。
///
/// ## 注入点
/// 老板端 `main.dart` 启动时调一次 [configure]（见 `apps/boss-app/lib/main.dart`）。
/// 测试可选：
/// - 直接给页面传 `picker:` / `uploader:`（**优先于**这里注册的全局实现）；
/// - 或调 [configure] 注入假实现。
///
/// ## 上传为什么也在这里
/// 提现收款码用 `type=withdraw_qr`、打款凭证用 `type=withdraw_proof`（契约指定），
/// 二者都必须走**既有的媒体上传链路** `uploadMedia`（docs/08：进度/超时/中文失败原因
/// 只有一份实现）。core 能直接调 `uploadMedia`，之所以仍然可注入，是为了让组件测试
/// 不必真的发网络请求（与 `RechargePage.uploader` 同一个理由）。
class WithdrawMedia {
  WithdrawMedia._();

  /// 收款码媒体用途（`withdraw_qr`；docs/02：**public** —— 打手自己也要看到它）
  static const String qrType = 'withdraw_qr';

  /// 打款凭证媒体用途（`withdraw_proof`；docs/02：**protected**，资金凭证绝不公开直连）
  static const String payoutProofType = 'withdraw_proof';

  /// 单张图大小上限（10MB）—— 本地先拦一次，比让服务端 413 更早说话
  static const int maxBytes = 10 * 1024 * 1024;

  /// 未注入选图实现时的中文原因（可上屏）
  static const String unavailableMessage = '当前设备还没接入选图能力，请升级到最新版本后再试';

  /// 宿主注册的实现（null = 还没接）
  static Future<PickedWithdrawImage?> Function()? pickImage;

  /// 宿主注册的一次性配置（启动时调一次即可，重复调用覆盖）
  static void configure({Future<PickedWithdrawImage?> Function()? picker}) {
    pickImage = picker;
  }

  /// 清空（测试用；生产不调）
  static void reset() {
    pickImage = null;
  }

  /// 选图：注入的实现优先，其次宿主注册的全局实现，都没有 → null（调用方给中文原因）
  static Future<PickedWithdrawImage?> pick({Future<PickedWithdrawImage?> Function()? injected}) {
    final f = injected ?? pickImage;
    if (f == null) return Future<PickedWithdrawImage?>.value(null);
    return f();
  }

  /// 本机是否具备选图能力（页面据此决定"点了给什么反馈"）
  static bool get available => pickImage != null;
}

/// 本地选中的一张图（字节 + 文件名 + 可选裁剪框）
class PickedWithdrawImage {
  const PickedWithdrawImage({required this.bytes, required this.name, this.cropped = false});

  /// 图片字节（已按宿主策略压缩/裁剪）
  final List<int> bytes;

  /// 原始文件名（服务端按扩展名判类型）
  final String name;

  /// 是否经过裁剪（界面据此说"已裁剪"而不是"已选择"）
  final bool cropped;

  int get byteLength => bytes.length;

  /// 人类可读大小（`1.2 MB` / `860 KB`）
  ///
  /// 复用媒体上传链路那份实现（`MediaUploadProgress.formatBytes`）——
  /// 不在提现链路上再写一遍"B/KB/MB 怎么进位"。
  String get sizeLabel => MediaUploadProgress.formatBytes(byteLength);
}

/// 提现打款凭证的**专用上传通道**（App 内管理员态唯一能用的上传路径）
///
/// ## 为什么不能直接用 `uploadMedia`
/// App 内「管理员身份」是**受限会话**（`kind='recharge'`）。它的白名单**刻意不含 `/media/*`**
/// （`/media/protected/:id` 对 `role=admin` 放行任意受保护媒体 —— 受限会话不该拿到这个面，
/// 与"凭证读取单开 `/recharge/proof/:requestId`"是同一条取舍）。
/// 于是服务端为提现单独开了一条**收窄到"这一张申请"**的上传通道：
///
/// ```
/// POST /withdraw/requests/:id/pay-proof   （multipart，字段名 `file`）
/// → { mediaId, url }                       （类型固定 withdraw_proof / protected）
/// ```
///
/// **约束（服务端的，客户端照做）**：只能给**自己那张 `pending` 申请**传图。
///
/// ## 进度/超时/中文失败原因
/// 与 `uploadMedia` 走**同一份**实现口径（`kMediaUpload*Timeout` + `MediaUploadProgresser`
/// + `mediaUploadErrorMessage`）：连接池复用、真实进度、错误翻中文都只有一份实现，
/// 不因为"换了个 URL"就再写一套上传逻辑。
Future<MediaUploadResult> uploadWithdrawPayProof({
  required String requestId,
  required List<int> bytes,
  required String filename,
  required String token,
  void Function(MediaUploadProgress progress)? onProgress,
}) async {
  final dio = ApiClient.sharedDio;
  final fd = FormData.fromMap({
    // 字段名固定 `file`（契约）：服务端按 multipart 单文件读，**不需要** type 字段
    // —— 类型由这条通道自己定死为 withdraw_proof，客户端传什么都不影响。
    'file': MultipartFile.fromBytes(bytes, filename: filename),
  });

  final MediaUploadProgresser progresser = MediaUploadProgresser(emit: onProgress)..start();

  final resp = await dio.post<Map<String, dynamic>>(
    '/withdraw/requests/$requestId/pay-proof',
    data: fd,
    onSendProgress: progresser.onSend,
    options: Options(
      headers: {'Authorization': 'Bearer $token'},
      sendTimeout: kMediaUploadSendTimeout,
      receiveTimeout: kMediaUploadReceiveTimeout,
    ),
  );

  final body = resp.data ?? const <String, dynamic>{};
  final code = body['code'] as int? ?? -1;
  if (code != 0) {
    final String msg = (body['message'] as String?)?.trim() ?? '';
    throw ApiException(
      code,
      msg.isEmpty ? '打款凭证上传失败，请重试' : msg,
      '${body['requestId'] ?? ''}',
    );
  }
  final data = body['data'];
  final m = data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{};
  final id = '${m['mediaId'] ?? m['id'] ?? ''}';
  if (id.isEmpty) throw const ApiException(-1, '服务端没有返回凭证编号，请重试', '');
  return MediaUploadResult(id: id, mimeType: '${m['mimeType'] ?? 'image/png'}');
}

/// ============================================================================
/// 「余额立即扣除」后的一致性刷新器（**唯一实现**）
/// ============================================================================
///
/// ## 为什么必须有它
/// 一笔提现申请成功后，余额出现在**三个地方**：提现页（可用余额）、
/// 打手态「我的」页（收益卡的余额）、「我的收益」页（当前余额 + 流水）。
/// 只刷其中一处 = 用户切回「我的」还能看到**旧的、多出来的**余额 ——
/// 那是"钱已经扣了但界面说没扣"，比不刷新更糟（负责人 2026-10-11 点名要求"不要只刷一处"）。
///
/// ## 机制
/// 一个极小的 Listener：页面在 `initState` 注册自己的重载回调、`dispose` 注销；
/// 提现申请成功后调一次 [refresh] → **所有还挂着的余额页面一起回源**。
/// - 打手态三页在 `IndexedStack` 里**都保持挂载**，所以「我的」页的监听一定还在 → 一定被刷到；
/// - 「我的收益」页是 push 出来的，没打开时没有监听（不需要刷）；
/// - 记录页每次进入都自己回源，不依赖它。
///
/// 为什么不用全局 store/状态管理：余额的唯一权威是服务端，页面之间共享的只是
/// "该重新拉一次了"这一个信号；引入状态容器会把余额变成客户端状态（与铁律冲突）。
class WithdrawRefreshNotifier extends ChangeNotifier {
  WithdrawRefreshNotifier._();

  static final WithdrawRefreshNotifier instance = WithdrawRefreshNotifier._();

  /// 上一次成功的申请金额（供页面/测试断言"刷的是哪一笔"；null = 还没提过）
  num? lastAppliedAmount;

  /// 上一次申请后服务端下发的余额（权威值，可直接就地显示）
  num? lastBalanceAfter;

  /// 余额变了（申请成功 / 打款成功）—— 所有余额页面回源
  void refresh({num? amount, num? balanceAfter}) {
    if (amount != null) lastAppliedAmount = amount;
    if (balanceAfter != null) lastBalanceAfter = balanceAfter;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }

  /// 测试用：清掉跨用例残留
  void debugReset() {
    lastAppliedAmount = null;
    lastBalanceAfter = null;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}
