/// 工作端终止服务 · **阻断式提示页**（终版 v1.8.0 / 码 58 → **完全阻断版 v1.8.2 / 码 60**）
///
/// 定位：打开 App 后**先出这一页**，说明「工作端已停止服务」、给下载入口与 5 步绑定。
/// **本版立即生效、不可跳过**（负责人 2026-10-06：平台还没正式投用、没有未迁移的打手）：
/// [kWorkerSunsetBlocking] = `true` → [workerSunsetCanContinue] 短路 → 底部只剩「前往下载」，
/// 「暂时继续使用」那条分支（[_actions] 的 `if (_canContinue)`）**永不渲染**。
/// 机制与既有**强制更新阻断**同一套（`UpdateBlockPage` 也是在 RootGate 里替换主界面），
/// 只是这里由 [WorkerSunsetGate] 驱动。
///
/// 三条硬要求逐条对应：
/// 1. **显著但不吓人**：满屏、无返回箭头、内容不滚完也能看到按钮（按钮固定在底部）；
/// 2. **下载入口复用既有做法**：客户端没有 `url_launcher`（不加依赖），所以只做
///    **地址明文 + 一键复制**，地址取 `AppConfig.resolveMediaUrl('/site/')`（运行期下发，不写死域名），
///    「前往下载」进说明页看两个可复制地址（官网下载页 + 老板端安装包直链）；
/// 3. **文案与老板端真实控件名一致**：5 步绑定直接复用 `kMigrationBindSteps`
///    （「切换身份」「打手端账号」「绑定并切换为打手」「切回老板」都在里面）。
///
/// **文案口径（v1.8.2 / 码 60：只有一个时态 —— 现在时）**：
/// - 页头 [kWorkerSunsetEndedHeadline]「工作端已停止服务」+ 状态条 [kWorkerSunsetBlockedNote]；
/// - **不再有"将于 X 月 X 日停止服务"这种倒计时/未来时**（立即生效还给日期 = 误导用户以为还有时间），
///   所以 v1.8.1 的 30 秒重算节拍（`WorkerSunsetTicker`）也被删掉了 —— 页面结论与时间无关；
/// - 服务端兜底（`worker_app_sunset_at`，默认 2026-10-13）**不给具体日期**，
///   只用 [kWorkerSunsetServerNote] 说"旧版本入口也会被关闭"。
///
/// **改钟绕过的处理（v1.8.1 加的防绕过层，本版保留但默认不再触发）**：
/// - v1.8.1 的到期判定只由本地时间决定 → **把手机时间调回过去就能绕过**，所以那一版额外做一次
///   **服务端时间校验**（[WorkerSunsetNetworkTime.probe]：读服务端 HTTP `Date` 响应头，
///   不需要新接口），并**只取两者中较晚的一个**做判定（[workerSunsetEffectiveNow]）。
/// - 本版**立即阻断**（判定被 `kWorkerSunsetBlocking` 短路）→ 改钟已经**绕不过任何东西**，
///   于是这一层只在备用开关（`blocking == false`）下才启用（见 [workerSunsetShouldProbe]），
///   生产环境**不再发这次探测请求**（少一个无用的网络往返；探测实现与用例仍完整保留）。
library;

import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/migration_notice.dart';
import '../widgets/worker_sunset.dart';
import 'migration_guide_page.dart';

/// 备用开关为 false 时的页头（那时"已经可用"还是"已合并"两说，才需要这一句）
const String kWorkerSunsetHeadline = '工作端已合并到「祁连山电竞」App';

/// 页头（**本版恒用这一句**：立即阻断，"已停止服务"就是结果，不是"将于某日停止"）
const String kWorkerSunsetEndedHeadline = '工作端已停止服务';

/// 一句话说清"合并后我还是不是我"（打手账号没变，这是最容易让人犹豫的点）
const String kWorkerSunsetSubtitle = '打手态（接单大厅 / 消息 / 我的）已经在老板端里：还是你原来的打手账号，'
    '接单权限、订单记录、收益余额都是同一份数据，绑定后接着接单。';

/// 「暂时继续使用」按钮文案（**本版永不渲染**：立即阻断下 [_canContinue] 恒 false；
/// 留着它是为了让"备用开关为 false"的老分支一行没删，且回归用例能断言它**确实不出现**）
const String kWorkerSunsetContinueLabel = '暂时继续使用（7 天内有效）';

/// 主按钮文案
const String kWorkerSunsetDownloadLabel = '前往下载';

/// 下载说明（不假装能开外链）
const String kWorkerSunsetDownloadNote = '不能直接打开外链：点「复制下载地址」，粘到手机浏览器打开即可。'
    '页面上有老板端 / 工作端两个二维码，显示的永远是最新版本。';

/// 绑定步骤卡标题
const String kWorkerSunsetStepsTitle = '在老板端绑定打手账号（5 步）';

/// 阻断式提示页（**本版：立即生效、不可跳过**，只剩「前往下载」+ 绑定 5 步）
class WorkerSunsetBlockPage extends StatefulWidget {
  const WorkerSunsetBlockPage({super.key, this.api, this.now, this.networkTime, this.probeNetworkTime = true});

  /// 仅用于「查看绑定步骤」页取老板端版本号（缺省自建；测试/出图注入 fixture）
  final ApiClient? api;

  /// 注入的"现在"（**测试/出图专用**：过去/现在/未来都要能确定性复现 —— 本版结论与它无关）；
  /// null = 走 [WorkerSunsetGate.now]（生产 = 系统本地时间）
  final DateTime? now;

  /// 已由调用方校验过的服务端时间（**测试专用**：跳过网络探测、直接给结果）；
  /// null = 备用开关为 false 时本页自己做一次探测（[WorkerSunsetNetworkTime.probe]）
  final DateTime? networkTime;

  /// 是否自己做服务端时间探测（缺省 true = 生产行为）。
  ///
  /// 置 false 的场景只有两类，都不影响产线：
  /// - 用例已经用 [networkTime] 给了确定结果；
  /// - 用例不需要这次请求（探测只在备用开关 `blocking == false` 时才发生，
  ///   见 [_WorkerSunsetBlockPageState._probeNetworkTime]）。
  final bool probeNetworkTime;

  @override
  State<WorkerSunsetBlockPage> createState() => _WorkerSunsetBlockPageState();
}

class _WorkerSunsetBlockPageState extends State<WorkerSunsetBlockPage> {
  /// 服务端 Date 头解析出来的"现在"（拿不到就是 null → 回退本地时间）
  ///
  /// 本版立即阻断 → 它不再影响任何结论；保留它是为了让备用开关（blocking == false）
  /// 那条分支的"防改钟"判定一行没删。
  DateTime? _serverNow;

  @override
  void initState() {
    super.initState();
    _serverNow = widget.networkTime;
    // 探测只在备用开关为 false 时发生：本版（kWorkerSunsetBlocking = true）判定被短路，
    // 探测结果改变不了任何结论 —— 生产环境因此**不再发这次请求**（const 为真 → 死代码消除）。
    if (workerSunsetShouldProbe(
      injected: widget.networkTime != null,
      ownProbe: widget.probeNetworkTime,
      probeEnabled: WorkerSunsetProbe.enabled,
    )) {
      _probeNetworkTime();
    }
  }

  /// 服务端时间探测：失败/无 Date 头 → 保持 null，判定回退本地时间（优雅降级）
  Future<void> _probeNetworkTime() async {
    final DateTime? server = await WorkerSunsetNetworkTime.probe(api: widget.api);
    if (!mounted || server == null) return;
    setState(() => _serverNow = server);
  }

  /// 用于展示与判定的"现在"
  ///
  /// 本地时间（构造注入优先，缺省系统本地时间）与服务端时间**取较晚者** —— 备用开关为 false 时，
  /// 服务端说已到期而本地被人为调回也不会放行（见 [workerSunsetEffectiveNow]）。
  /// 本版立即阻断 → 这个值改变不了任何结论（[_canContinue] 与 [_stopped] 都恒为定值）。
  DateTime get _effectiveNow =>
      workerSunsetEffectiveNow(widget.now ?? WorkerSunsetGate.instance.now, _serverNow);

  /// 是否允许「暂时继续使用」（**本版恒 false**：kWorkerSunsetBlocking = true）
  bool get _canContinue => workerSunsetCanContinue(_effectiveNow);

  /// 是否已停止服务（**本版恒 true**：立即生效 → 页头与文案走"已停止服务"口径）
  bool get _stopped => workerSunsetStopped(_effectiveNow);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.lg),
                children: [
                  _hero(),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    // 本版页头直接说结果（"已合并"仍是合并说明的第一句，见下方 subtitle）
                    _stopped ? kWorkerSunsetEndedHeadline : kWorkerSunsetHeadline,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary, height: 1.3),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    kWorkerSunsetSubtitle,
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.6),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _statusBanner(),
                  const SizedBox(height: AppSpacing.lg),
                  _downloadCard(context),
                  const SizedBox(height: AppSpacing.lg),
                  _stepsCard(context),
                ],
              ),
            ),
            _actions(context),
          ],
        ),
      ),
    );
  }

  /// 顶部图标块（与既有强制更新阻断页同一视觉语言，面积小、不做整页渐变）
  Widget _hero() {
    return Center(
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.primarySecondary],
          ),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Icon(Icons.system_update_alt, size: 34, color: Colors.white),
      ),
    );
  }

  /// **停止服务状态条**（v1.8.2 / 码 60：与首页·我的引导条**同一句常量** [kWorkerSunsetBlockedNote]）
  ///
  /// 原来这里放的是"将于 10 月 13 日停止服务（还剩 N 天）"倒计时；立即阻断后没有倒计时可言，
  /// 改成现在时的结果句 —— 两处（阻断页 / 引导条）仍只有一处文案出处，不会各说各的。
  /// 时间参数已不参与本版结论（[_effectiveNow] 只在备用开关为 false 时才影响文案）。
  Widget _statusBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 不再是"时钟"（那暗示还有时间）：改成信息图标，说的是结论
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(AppIcon.info, size: 15, color: AppColors.warning)),
          const SizedBox(width: 6),
          Expanded(child: Text(kWorkerSunsetBlockedNote, style: kWorkerSunsetTextStyle)),
        ],
      ),
    );
  }

  /// 下载入口：地址明文 + 一键复制（零新依赖、零硬编码域名）
  Widget _downloadCard(BuildContext context) {
    return _card(
      title: '下载入口',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('官网下载页', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(
            MigrationDownload.siteUrl,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.45),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              copyAddressButton(context, MigrationDownload.siteUrl),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text(
                  kWorkerSunsetDownloadNote,
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary, height: 1.35),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 5 步绑定（步骤正文与「我的」页/说明页**同一份数据源**，控件名照老板端实机点得到）
  ///
  /// 标题 + 细节都列出来：只写"去绑定"等于没说；细节里的
  /// 「打手端账号」「绑定并切换为打手」「切回老板」就是老板端上真实存在的控件名。
  Widget _stepsCard(BuildContext context) {
    return _card(
      title: kWorkerSunsetStepsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(kMigrationBindPath, style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < kMigrationBindSteps.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.ice,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kMigrationBindSteps[i].title,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary, height: 1.4),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          kMigrationBindSteps[i].detail,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => _openGuide(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              foregroundColor: AppColors.primary,
            ),
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
      ),
    );
  }

  /// 底部按钮区（固定在屏幕底部：内容再长也点得到）
  ///
  /// **本版（立即生效）**：[_canContinue] 恒 false → 整条「暂时继续使用」分支不渲染，
  /// 只剩「前往下载」；下面那句是**服务端兜底说明** [kWorkerSunsetServerNote]
  /// （主说明已在页面上方的状态条 [_statusBanner]，两处各说一件事、不重复同一句）。
  Widget _actions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.lg),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: const Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 主按钮走项目自有的 AppButton（品牌青蓝渐变），**不用** Material 默认 FilledButton：
          // 默认色随 miuix 主题种子（紫），与三端统一设计语言（docs/14）不符
          AppButton(
            label: kWorkerSunsetDownloadLabel,
            height: 46,
            onPressed: () => _openGuide(context),
          ),
          const SizedBox(height: 8),
          // 备用开关为 false 且未到期时才渲染「暂时继续使用」（本版不可达，一行没删）
          if (_canContinue)
            AppButton(
              label: kWorkerSunsetContinueLabel,
              gradient: false,
              height: 44,
              onPressed: () => WorkerSunsetGate.instance.continueUsing(),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                kWorkerSunsetServerNote,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: AppColors.textTertiary, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  void _openGuide(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => MigrationGuidePage(api: widget.api, title: '下载与绑定步骤')),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.card),
        // 发丝线（docs/21：阴影只给弹层）
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// **服务端时间探测开关**（备用开关为 false 时才有意义；测试期也可显式关掉）
///
/// 屏蔽的是"页面自行发起探测"这一条路径；[WorkerSunsetBlockPage.networkTime] 的注入不受影响
/// （注入路径不发起任何请求）。
///
/// ⚠️ v1.8.2 / 码 60 起：立即阻断（`kWorkerSunsetBlocking == true`）→ 页面**根本不发这次探测**
/// （见 `_WorkerSunsetBlockPageState.initState` 的 const 短路），所以本开关在当前生产版本里
/// 不再改变任何行为；它连同探测实现一起保留，是为了备用开关改回 false 时那一层"防改钟"仍在。
class WorkerSunsetProbe {
  WorkerSunsetProbe._();

  /// 是否允许阻断页自行探测服务端时间（备用分支可置 false；测试同样可置）
  static bool enabled = true;
}

/// 阻断提示挂载点（RootGate 用它包住「登录页 / 主界面」）
///
/// 与既有强制更新阻断（`UpdateBlockPage` 在 RootGate 里替换主界面）**同一套机制**：
/// 冷启动先出提示页，只有 `WorkerSunsetGate` 放行才渲染 child。
/// **本版 [WorkerSunsetGate.canContinue] 恒 false（立即阻断）→ 这个 child 永远进不去**
/// ——工作端 App 到此为止（打手改在老板端「打手态」接单）。
class WorkerSunsetGateHost extends StatelessWidget {
  const WorkerSunsetGateHost({super.key, required this.child, this.api});

  /// 被阻断的真实界面（登录页或主界面）
  final Widget child;

  /// 透传给提示页（测试/出图注入 fixture；生产不传）
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: WorkerSunsetGate.instance,
      builder: (context, _) =>
          WorkerSunsetGate.instance.blocking ? WorkerSunsetBlockPage(api: api) : child,
    );
  }
}

/// **本页挂载时是否需要探测服务端时间**（纯函数，四个参数全部可注入）
///
/// `需要 == !blocking && 调用方没给结果 && 本页允许自探 && 探测开关打开`
///
/// - 生产（`blocking = kWorkerSunsetBlocking = true`）→ **false**：判定与时间无关，
///   **不再发这次 HTTP 请求**（v1.8.1 加它是为了"改手机时间绕过"；立即阻断后改钟绕不过任何东西）；
/// - 备用开关改回 `false` → `true`：那一层"防改钟"照旧生效（实现与用例都留着，别删）。
///
/// 抽成纯函数是为了让"立即阻断后不再探测"这条**可注入地**被回归钉住
/// （探测本身在 core 里自建 Dio，从测试侧观察不到，所以判定条件必须自己可测）。
bool workerSunsetShouldProbe({
  bool blocking = kWorkerSunsetBlocking,
  bool injected = false,
  bool ownProbe = true,
  bool probeEnabled = true,
}) =>
    !blocking && !injected && ownProbe && probeEnabled;

/// **服务端时间校验**（v1.8.1 / 码 59 的防绕过层；v1.8.2 / 码 60 立即阻断后只在备用分支启用）
///
/// 实现落在 core 的 [NetworkTime]（读服务端 HTTP `Date` 响应头，**零后端改动、零新依赖**：
/// 按 HTTP 规范每个响应都带 `Date`，探测打公开的 `/health`，不需要登录态）。
/// 这里只保留工作端自己的语义：**必须优雅降级**。
///
/// 边界（三条，全部是"优雅降级"）：
/// 1. 请求失败 / 超时 / 没有 `Date` 头 / 头解析不了 → 返回 null（调用方回退本地时间，不报错）；
/// 2. 只用来**把判定往"更晚"的方向拉**（见 [workerSunsetEffectiveNow]）—— 服务端时间不会
///    让被调快的本地时间"复活"，也不会把已到期的设备放行；
/// 3. 超时 5 秒：页面先渲染（本地时间口径），探测回来只是可能把「暂时继续使用」收掉。
///
/// ⚠️ 已知边界：这一层只是**展示侧**的防绕过（HTTP `Date` 头可被中间代理改写、离线时不可用）。
/// **真正的封堵在服务端**（已上线）：`system_setting.worker_app_sunset_at`（默认 2026-10-13 00:00
/// Asia/Shanghai）到期后拒绝 `role=worker` 的 primary 会话（登录 403 / 请求 401 / WS 拒连），
/// 见 docs/04「工作端到期收口」；**打手态 companion 一律不受影响**。
class WorkerSunsetNetworkTime {
  WorkerSunsetNetworkTime._();

  /// 探测服务端时间：拿不到返回 null（绝不抛异常；内部已 try/catch）
  static Future<DateTime?> probe({ApiClient? api, Duration timeout = const Duration(seconds: 5)}) =>
      NetworkTime.probe(api: api, timeout: timeout);

  /// HTTP `Date` 头 → 本地时区的 [DateTime]（解析不了返回 null）
  ///
  /// 单独转发出来是为了**不依赖网络**就能测"取不到就回退"这一条（见 worker_sunset_deadline_test）。
  static DateTime? parseDateHeader(String? raw) => NetworkTime.parseDateHeader(raw);
}

/// **最终用于判定的"现在"**：本地时间与服务端时间取**较晚**者（服务端拿不到就用本地）
///
/// 为什么取较晚而不是直接信服务端：判定的是"是否已到停止服务日"，只要有一侧说
/// "已经到期"就应该停（把时间调快的用户只是更早被挡，无害）；而取较晚恰好覆盖了
/// **把手机时间调回过去**这个唯一的绕过点 —— 服务端说已到期时，本地再早也拦得住。
DateTime workerSunsetEffectiveNow(DateTime localNow, DateTime? serverNow) {
  if (serverNow == null) return localNow;
  return serverNow.isAfter(localNow) ? serverNow : localNow;
}
