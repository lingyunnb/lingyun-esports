/// 工作端退役 · 迁移引导（负责人 2026-10-06：工作端 App 决定停用，打手态搬进老板端「祁连山电竞」）
///
/// 设计口径（四条硬要求，逐条对应）：
/// 1. **常驻卡片**：**没有关闭按钮、不是弹窗、不加遮罩** —— 它在页头下方占一条，
///    不压任何按钮、不阻断滚动；加载中/加载失败时同样在（真正"不可忽略"）。
/// 2. **文案具体可验证**（docs/21）：说清"停到哪去、怎么绑定、现在还能不能用"，不喊口号。
/// 3. **下载入口复用既有做法**：客户端**没有** `url_launcher` 依赖（硬约束：不加依赖），
///    所以不给"点了能打开"的假象，改为**展示下载地址 + 一键复制**（与老板端宣传图外链同一处理），
///    地址来自 `AppConfig`（运行期下发地址），**不写死任何域名**。
/// 4. **v1.8.2 / 码 60 起口径与阻断页完全同源（现在时）**：正文走 [migrationBodyText]、
///    停止服务说明用 `worker_sunset.dart` 的 [kWorkerSunsetBlockedNote] ——
///    **不再出现"将于 X 月 X 日停止服务"**（立即阻断还给日期 = 误导用户以为还有时间），
///    也不再有倒计时那一行（v1.8.1 的 `_sunsetLine` 已删，倒计时函数也随之删除）。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/migration_guide_page.dart';
import 'worker_sunset.dart';

/// 引导条标题（**备用开关为 false 且未到期**时才用这一条；本版走 [kMigrationEndedHeadline]）
const String kMigrationHeadline = '工作端已合并进「祁连山电竞」App';

/// 引导条正文（负责人给定口径：同一台手机绑定打手账号 → 老板端内接单）
///
/// **时间相关的文案一律走本函数**：本版（`kWorkerSunsetBlocking == true`）恒为"已停止服务"，
/// 与阻断页共用同一个 [kWorkerSunsetBlockedNote]；`blocking: false` 那条备用分支保留，
/// 但**只描述机制、不写任何具体日期**（日期只在服务端兜底里，用户可见文案不写"将于某日停止"）。
String migrationBodyText(DateTime now, {bool blocking = kWorkerSunsetBlocking}) {
  const String head = '工作端已合并到「祁连山电竞」App：在同一台手机上绑定你的打手账号，'
      '就能在老板端里接单；';
  if (workerSunsetStopped(now, blocking: blocking)) {
    return '$head$kWorkerSunsetBlockedNote';
  }
  // 备用开关为 false 的旧口径（本版不发布）：到期前仍可使用、但不再更新功能。
  // 刻意不给日期：这一支已经不会再面向用户发布，写死日期只会成为第二个口径来源。
  return '$head本 App 仍可使用，但不再更新功能；到期日一到即停止服务。';
}

/// 打手态说明标题（「我的」页显著位置；**备用开关为 false 且未到期**时用这一条）
const String kMigrationWorkerStateTitle = '打手态已在「祁连山电竞」App 可用';

/// 打手态说明标题（**本版恒用这一条**：说的是结果，不是"可用"）
const String kMigrationWorkerStateEndedTitle = '工作端已停止服务，打手态在「祁连山电竞」App';

/// 首页引导条标题（**本版恒用这一条**：说结果 + 指向新版）
const String kMigrationEndedHeadline = '工作端已停止服务，请使用「祁连山电竞」App';

/// 绑定路径一句话（与老板端真实 UI 逐字对齐：我的 › 身份 › 切换身份）
const String kMigrationBindPath = '绑定路径：老板端 › 我的 › 身份 › 切换身份 › 输入打手账密';

/// 绑定步骤的一条：`title` 用于清单一行，`detail` 用于说明页展开
class MigrationStep {
  const MigrationStep(this.title, this.detail);
  final String title;
  final String detail;
}

/// 绑定步骤（**唯一数据源**：首页/我的页清单与说明页展开都用这一份，避免两处文案各写各的）
///
/// 步骤里的控件名（「切换身份」「打手端账号」「绑定并切换为打手」…）取自老板端 identity 实现，
/// 照着实机点就能对上，不是编的。
const List<MigrationStep> kMigrationBindSteps = [
  MigrationStep(
    '下载并打开「祁连山电竞」App，登录你的老板账号',
    '打手态就在老板端里。老板账号和你现在的打手账号是两个账号：还没有老板账号，'
        '就在登录页点「注册一个」新建一个（注册要填邮箱验证码）；以后两个身份可以一键互切。',
  ),
  MigrationStep(
    '进底部「我的」，找到「身份」分组',
    '底部导航最右一项就是「我的」；「身份」分组在页面上半部分。',
  ),
  MigrationStep(
    '点「切换身份」',
    '弹层标题就是「切换身份」，里面会要你先选身份。',
  ),
  MigrationStep(
    '输入打手账密',
    '「打手端账号」填登录名 / 展示 ID / 工号都可以；「密码」是你登录工作端用的那个密码，'
        '不是老板账号的密码。',
  ),
  MigrationStep(
    '点「绑定并切换为打手」',
    '绑定成功后进入打手态：底部只剩 接单 / 消息 / 我的 三项，顶部有一条细带写着'
        '「当前身份 · 打手 · 工号 …」，点细带右侧「切回老板」就回老板态；'
        '以后每次切换都不用再输密码（12 小时内有效，到期重新输一次）。',
  ),
];

/// 老板端安装包信息（老板端版本的公开接口下发值，用于把"下载哪个版本"写具体）
class MigrationApkInfo {
  const MigrationApkInfo({required this.versionName, required this.fileSize, required this.url});

  final String versionName;

  /// 字节数（0 = 服务端未给）
  final int fileSize;
  final String url;

  /// 27,368,751 → `26.1 MB`（无数据时留空，不编数字）
  String get sizeText =>
      fileSize <= 0 ? '' : '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 迁移下载地址（**复用项目既有能力，零新依赖、零硬编码域名**）
///
/// - 官网下载页：后端已用 `express.static` 把 `site/` 挂在 `/site`（`server/src/main.ts`），
///   页面本身就从云端更新接口取"双端最新版"并现画二维码 → 打进 App 也永远指向最新版本；
/// - 老板端安装包直链：复用公开接口 `GET /public/app-versions/latest?appType=boss`
///   （与工作端自身更新检查同一个接口，只是 appType 换成 boss）。
class MigrationDownload {
  MigrationDownload._();

  /// 官网下载页地址（老板端/工作端两个二维码都在这一页）
  static String get siteUrl => AppConfig.resolveMediaUrl('/site/');

  /// 老板端安装包直链 + 版本号；接口/网络异常一律返回 null（页面只留官网地址，不报错、不挡操作）
  static Future<MigrationApkInfo?> bossApk({ApiClient? api}) async {
    try {
      final resp = await (api ?? ApiClient()).request(
        'GET',
        '/public/app-versions/latest',
        queryParameters: {'appType': 'boss'},
      );
      final data = resp['data'];
      if (data is! Map) return null;
      final latest = data['latest'];
      if (latest is! Map) return null;
      final url = AppConfig.resolveMediaUrl('${latest['downloadUrl'] ?? ''}');
      if (url.isEmpty) return null;
      return MigrationApkInfo(
        versionName: '${latest['versionName'] ?? ''}',
        fileSize: (latest['fileSize'] as num?)?.toInt() ?? 0,
        url: url,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 复制下载地址 + 品牌提示（**点击一定有反馈**：成功提示里带上完整地址，便于自己核对）
///
/// 本版（立即阻断）反馈一律是 [kWorkerSunsetBlockedNote] 口径：复制完还要告诉用户
/// "为什么必须换 App"，而不是只报一句"已复制"（备用开关为 false 且未到期时才回"已复制"）。
Future<void> copyMigrationAddress(BuildContext context, String address, {String label = '下载地址'}) async {
  await Clipboard.setData(ClipboardData(text: address));
  if (!context.mounted) return;
  if (workerSunsetStopped(DateTime.now())) {
    AppToast.error(context, '$kWorkerSunsetBlockedNote地址已复制：$address', icon: AppIcon.info);
    return;
  }
  AppToast.success(context, '$label已复制，粘到手机浏览器即可打开：$address', icon: AppIcon.check);
}

/// 引导条形态：首页（合并说明 + 全文）／我的页（打手态说明 + 分步清单）
enum MigrationNoticeVariant { home, profile }

/// 迁移引导条（首页顶部与「我的」页共用同一个组件，文案与交互只有一处实现）
class MigrationNotice extends StatelessWidget {
  const MigrationNotice({super.key, this.variant = MigrationNoticeVariant.home, this.api, this.now});

  final MigrationNoticeVariant variant;

  /// 仅用于「查看绑定步骤」页里取老板端版本号；缺省自建（与页面其它请求同一个客户端）
  final ApiClient? api;

  /// 注入的"现在"（**测试/出图专用**：本版结论与它无关，但备用分支的文案要能确定性复现）；
  /// null = 系统本地时间（生产行为）
  final DateTime? now;

  bool get _isHome => variant == MigrationNoticeVariant.home;

  /// 生效的"现在"（缺省系统本地时间）
  DateTime get _now => now ?? DateTime.now();

  /// 是否已停止服务（引导条与阻断页共用 `worker_sunset.dart` 的同一个判定：本版恒 true）
  bool get _stopped => workerSunsetStopped(_now);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.card),
        // 发丝线（docs/21：列表用发丝线，阴影只给弹层）
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 1), child: Icon(AppIcon.info, size: 15, color: AppColors.primary)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  // 标题与判定同源（"可用"→"已停止服务"）：本版恒为"已停止服务"口径
                  _isHome
                      ? (_stopped ? kMigrationEndedHeadline : kMigrationHeadline)
                      : (_stopped ? kMigrationWorkerStateEndedTitle : kMigrationWorkerStateTitle),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // v1.8.2 / 码 60：原来这里的"将于 10 月 13 日停止服务（还剩 N 天）"整行已删 ——
          // 立即阻断没有倒计时可言；"已停止服务"由正文（首页形态）承载，与阻断页同一句常量。
          if (_isHome)
            Text(migrationBodyText(_now), style: _bodyStyle)
          else
            _stepList(),
          const SizedBox(height: 10),
          const Divider(height: 1, thickness: 1, color: AppColors.divider),
          const SizedBox(height: 10),
          _addressRow(),
          const SizedBox(height: AppSpacing.sm),
          _actions(context),
        ],
      ),
    );
  }

  static const TextStyle _bodyStyle = TextStyle(
    fontSize: 12.5,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  /// 「我的」页形态：分步骤列清楚（编号 + 一行一步），细节在说明页展开
  Widget _stepList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(kMigrationBindPath, style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < kMigrationBindSteps.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 16,
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                      height: 1.45,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(kMigrationBindSteps[i].title, style: _bodyStyle.copyWith(height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 下载入口：地址明文展示 + 一键复制（客户端无 url_launcher，不做"点了能打开"的假象）
  Widget _addressRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text('下载地址', style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            MigrationDownload.siteUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    return Row(
      children: [
        copyAddressButton(context, MigrationDownload.siteUrl),
        const SizedBox(width: AppSpacing.sm),
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => MigrationGuidePage(api: api)),
          ),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            foregroundColor: AppColors.primary,
          ),
          // 字号写在子 Text 上（**不要**写在 styleFrom(textStyle:)：那会整段替换主题的
          // labelLarge，连 fontFamily 一起丢掉 —— 中文字体一丢就是方块/走系统兜底字体）
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('查看绑定步骤', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              SizedBox(width: 2),
              Icon(AppIcon.chevronRight, size: 15),
            ],
          ),
        ),
      ],
    );
  }
}

/// 「复制下载地址」按钮（首页引导条、我的页说明、说明页下载区三处共用一个实现）
///
/// 注意：字号走子 `Text`，**不要**用 `styleFrom(textStyle:)` —— 那会把主题 labelLarge
/// 整段替换掉（含 fontFamily），中文会掉到系统兜底字体；真机看不出来，出图就是方块。
Widget copyAddressButton(BuildContext context, String address, {String label = '复制下载地址'}) {
  return OutlinedButton(
    onPressed: () => copyMigrationAddress(context, address, label: '下载地址'),
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      foregroundColor: AppColors.textSecondary,
      side: const BorderSide(color: AppColors.divider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.control)),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
  );
}
