/// 迁移说明页（工作端退役 · 打手态在老板端「祁连山电竞」）
///
/// 「我的」页与首页引导条都进这一页；本页只说三件事：
/// 1. 怎么在老板端里绑上打手账号（分步骤，与老板端真实控件名对齐）
/// 2. 装哪个包、地址是什么（**展示地址 + 一键复制**，无新依赖、不假装能直接打开外链）
/// 3. 大家一定会问的三件事（工作端还能不能用 / 权限会不会变 / 订单收益会不会丢）
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';
import '../widgets/migration_notice.dart';
import '../widgets/worker_sunset.dart';

class MigrationGuidePage extends StatefulWidget {
  const MigrationGuidePage({super.key, this.api, this.title = '迁移说明'});

  /// 取老板端版本号用的客户端（缺省自建；测试/出图注入 fixture）
  final ApiClient? api;

  /// 页头标题：默认「迁移说明」；从终版阻断提示页的「前往下载」进来时叫「下载与绑定步骤」
  /// （同一页两个入口，标题随意图走 —— 不改默认值，既有调用与用例逐字不变）
  final String title;

  @override
  State<MigrationGuidePage> createState() => _MigrationGuidePageState();
}

class _MigrationGuidePageState extends State<MigrationGuidePage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  MigrationApkInfo? _apk;

  @override
  void initState() {
    super.initState();
    _loadBossApk();
  }

  /// 老板端版本信息：拿不到就只显示官网下载页地址（不报错、不转圈卡住）
  Future<void> _loadBossApk() async {
    final info = await MigrationDownload.bossApk(api: _api);
    if (!mounted || info == null) return;
    setState(() => _apk = info);
  }

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: widget.title,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.lg, AppSpacing.page, AppSpacing.xxl),
        children: [
          _card(
            title: '为什么会有这条说明',
            // 与首页引导条**同一个函数**：v1.8.2 / 码 60 起恒为"工作端已停止服务"（现在时，
            // 与阻断页共用同一句 `kWorkerSunsetBlockedNote`）——不再有"将于 X 月 X 日停止"的倒计时口径
            child: Text(migrationBodyText(DateTime.now()), style: _body),
          ),
          const SizedBox(height: AppSpacing.lg),
          _card(
            title: kMigrationWorkerStateTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(kMigrationBindPath, style: _body),
                const SizedBox(height: AppSpacing.md),
                for (var i = 0; i < kMigrationBindSteps.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.md),
                    child: _step(i + 1, kMigrationBindSteps[i]),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _card(title: '下载地址', child: _downloadSection()),
          const SizedBox(height: AppSpacing.lg),
          _card(title: '常见问题', child: _faq()),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 下载区

  Widget _downloadSection() {
    final apk = _apk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '客户端没有打开外链的能力（同一个刻意不加依赖的决定）：下面的地址请点「复制」，'
          '再粘到手机浏览器打开即可。官网下载页上有老板端/工作端两个二维码，'
          '页面显示的永远是当时的最新版本。',
          style: _body,
        ),
        const SizedBox(height: AppSpacing.md),
        _addressBlock(
          label: '官网下载页',
          value: MigrationDownload.siteUrl,
          note: '双端最新版 + 二维码都在这一页；以后换版本不用再改这条地址。',
        ),
        const SizedBox(height: AppSpacing.md),
        // 老板端安装包直链：版本号/大小来自服务端下发，拿不到就整块不显示（不编数字）
        if (apk != null)
          _addressBlock(
            label: '老板端安装包（直接下载）',
            value: apk.url,
            note: apk.versionName.isEmpty
                ? '安卓安装包，点开即下。'
                : '当前老板端 v${apk.versionName}'
                    '${apk.sizeText.isEmpty ? '' : ' · ${apk.sizeText}'}，安卓安装包，点开即下。',
          ),
      ],
    );
  }

  Widget _addressBlock({required String label, required String value, required String note}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.45)),
        const SizedBox(height: 6),
        Row(
          children: [
            copyAddressButton(context, value),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(note, style: const TextStyle(fontSize: 11, color: AppColors.textTertiary, height: 1.35))),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 步骤 / 问答

  Widget _step(int no, MigrationStep step) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.ice,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Text('$no', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary, height: 1.4)),
              const SizedBox(height: 3),
              Text(step.detail, style: _body),
            ],
          ),
        ),
      ],
    );
  }

  Widget _faq() {
    // 第一条问答与阻断页**同一个判定**（v1.8.2 / 码 60：立即阻断 → 恒为"不能了"口径），
    // 避免"FAQ 说还能用、阻断页说已停止"的自相矛盾。备用开关为 false 时那一支也不写日期。
    final bool stopped = workerSunsetStopped(DateTime.now());
    final items = [
      (
        '工作端现在还能用吗？',
        stopped
            ? '不能了。$kWorkerSunsetBlockedNote绑定路径与步骤见上面第二条，绑定后接着接单。'
            : '能，但会在到期日当天 00:00 起停止服务。接单、抢单、收益、消息都照旧，'
                '这次只是提前告诉你迁移方式，请在这之前完成绑定。',
      ),
      ('接单权限会变吗？', '不会。能接哪些分部还是管理员按分部给你开通的那几个，绑过去在同一台手机上接着接单。'),
      ('订单和收益会丢吗？', '不会。绑的是同一个打手账号，订单记录、收益余额、和老板的私聊都还在，用哪个入口看都是同一份数据。'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('问：${items[i].$1}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary, height: 1.4)),
                const SizedBox(height: 3),
                Text('答：${items[i].$2}', style: _body),
              ],
            ),
          ),
      ],
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.card),
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

  static const TextStyle _body = TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.55);
}
