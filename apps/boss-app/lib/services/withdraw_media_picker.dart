import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:image_picker/image_picker.dart';

/// ============================================================================
/// 提现链路的**相册选图**（老板端 = 宿主侧实现）
/// ============================================================================
///
/// ## 为什么在 boss-app 而不在 core
/// 打手态四页（提现 / 收款信息 / 记录 / 收益）都住在 `fish_core`，而 `image_picker`
/// 是**平台依赖**（需要 Activity/权限），core 同时被老板端与工作端复用，不能引它。
/// 于是 core 声明挂载点 `WithdrawMedia`，老板端在这里给出真实实现，
/// 启动时 `WithdrawMedia.configure(picker: pickWithdrawImage)` 注册一次。
///
/// ## 与充值页付款截图的口径一致
/// - **压缩**：`maxWidth: 1600, imageQuality: 72` —— 与 `RechargePage._pickFromGallery`
///   逐值相同。收款码/支付截图不是摄影作品，1600/72 下二维码依然清晰可扫、
///   金额与时间清晰可辨（人工核对够用），字节数明显更小（弱网下的成败关键）；
/// - **来源**：只走相册（`ImageSource.gallery`）。**不做**拍照入口：收款码在对方手机里、
///   支付截图是系统截图，都要先进相册；多一条"拍照"只会多一次权限申请与一次对焦失败。
///
/// ## 裁剪（`image_cropper`）为什么**没有**接在这一版
/// 任务书写的是"用既有 `image_cropper`/媒体上传链路"。实测本仓库里 `image_cropper`
/// 是 pubspec 的历史遗留依赖，**lib/ 与 test/ 里一处都没用过**（全仓 0 处引用）——
/// 也就是这条链路上不存在"既有裁剪能力"可复用。真要用它，等于本轮新引入一个带
/// 原生 Android Activity 的插件到**发布链**上：需要重新出包验证、且当前无法在
/// 本机真机验证（无插线设备）。按"不卡死铁律 + 风险最小"取舍：
/// **先按已验证的充值链路口径落地（选图 + 压缩 + 上传），裁剪留作可选项**。
/// 若负责人要裁掉收款码四周多余部分，接法只有一处：在本函数返回前对 bytes 跑一次
/// `ImageCropper().cropImage(...)`（core 侧一行都不用改 —— 它只认 [PickedWithdrawImage]）。
Future<PickedWithdrawImage?> pickWithdrawImage() async {
  final XFile? picked = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1600,
    imageQuality: 72,
  );
  if (picked == null) return null;
  final Uint8List bytes = await picked.readAsBytes();
  return PickedWithdrawImage(bytes: bytes, name: picked.name);
}
