// 注：core 的 identity/（老板端打手态）钱包页叫 IdentityWorkerWalletPage，与本页 push 的
// WorkerWalletPage 不再重名，直接导入即可（曾重名踩过 ambiguous_import，改名后已消除）。
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../widgets/fish_glass.dart';
import '../widgets/migration_notice.dart';
import 'edit_profile_page.dart';
import 'settings_page.dart';
import 'worker_wallet_page.dart';

/// 我的（2026-09-25 与老板端统一设计语言）：
/// 个人资料头部（头像/工号/ID/等级/权限状态）→ 积分概览卡 → **迁移说明（2026-10-06）** → 功能入口（我的积分/排名/设置）
/// 等级与积分全部服务端真实数据。
///
/// 迁移说明卡：工作端已决定停用，打手态搬进老板端「祁连山电竞」——这里是**显著位置**的说明 + 下载入口，
/// 分步骤写清绑定路径（老板端 › 我的 › 身份 › 切换身份 › 输入打手账密）。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, this.onNavigate, this.api});

  /// 切换底部 tab（我的排名 → 排行榜 tab）
  final ValueChanged<int>? onNavigate;

  /// 接口客户端（缺省自建；测试/出图注入 fixture）
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    // 2026-09-25：与老板端一致的背景图通顶设计（"我的"大标题叠在背景图上）
    return FishGlassBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedBuilder(
          animation: AuthStore.instance,
          builder: (context, _) {
            final me = AuthStore.instance.me;
            if (me == null) {
              return const Center(child: Text('加载中…', style: TextStyle(color: AppColors.textTertiary)));
            }
            final style = levelStyleOf(me.level);
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ---------- 个人资料头部 ----------
                Stack(
                  children: [
                    if ((me.backgroundMediaId?.isNotEmpty ?? false))
                      Positioned.fill(
                        child: Image.network(
                          key: ValueKey('bg-${me.backgroundMediaId}'),
                          AppConfig.resolveMediaUrl('/media/public/${me.backgroundMediaId}'),
                          fit: BoxFit.cover,
                          cacheWidth: 720,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    // 主色渐变底 + 暗色罩层（对比度受控，文字清晰）
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              AppColors.primary.withValues(alpha: 0.88),
                              AppColors.primarySecondary.withValues(alpha: 0.82),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xxl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '我的',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                                shadows: [Shadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 2))],
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2.5),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.5),
                                  ),
                                  child: AppAvatar(nickname: me.nickname, mediaId: me.avatarMediaId, size: 62),
                                ),
                              const SizedBox(width: AppSpacing.lg),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(me.nickname, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                                    const SizedBox(height: 4),
                                    Text('工号 ${me.workerNo} · ID: ${me.uid}', style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 12)),
                                    const SizedBox(height: 8),
                                    // 等级徽章（半透明玻璃贴片，与老板端一致）
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.22),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(style.icon, size: 11.5, color: Colors.white),
                                          const SizedBox(width: 4),
                                          Text('L${me.level} ${style.label}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              InkWell(
                                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditProfilePage())),
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_outlined, size: 13, color: Colors.white),
                                      SizedBox(width: 4),
                                      Text('编辑资料', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          Row(
                            children: [
                              Expanded(child: _chip(me.canTakeOrder ? '接单权限已开通' : '暂无接单权限', me.canTakeOrder)),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(child: _chip(me.canServeCustomer ? '客服权限已开通' : '暂无客服权限', me.canServeCustomer)),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          // 分部接单权限（负责人 2026-10-04）：接单权限按分部细分，这里明确列出**我能接哪些分部**
                          Align(alignment: Alignment.centerLeft, child: _divisionLine(me)),
                        ],
                      ),
                    ),
                    ),
                ],
              ),
              // ---------- 积分概览卡（压头部下沿） ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 0),
                child: Transform.translate(
                  offset: const Offset(0, -24),
                  child: _EarningsCard(api: api),
                ),
              ),
              // ---------- 迁移说明（工作端停用 → 打手态在老板端；负责人 2026-10-06） ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 0),
                child: MigrationNotice(variant: MigrationNoticeVariant.profile, api: api),
              ),
              // ---------- 功能入口 ----------
              const SizedBox(height: AppSpacing.lg),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 0),
                child: FishGlassCard(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      children: [
                        MiuixArrowPreference(
                          title: '我的积分',
                          summary: '余额、获得与消费明细',
                          startAction: MiuixIcon(vector: MiuixIcons.extended.byName('favorites')!),
                          onClick: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WorkerWalletPage())),
                        ),
                        const MiuixHorizontalDivider(),
                        MiuixArrowPreference(
                          title: '我的排名',
                          summary: '周榜/月榜成绩',
                          startAction: MiuixIcon(vector: MiuixIcons.extended.byName('stopwatch')!),
                          onClick: () => onNavigate?.call(2),
                        ),
                        const MiuixHorizontalDivider(),
                        MiuixArrowPreference(
                          title: '设置',
                          summary: '通知、账号与安全',
                          startAction: MiuixIcon(vector: MiuixIcons.extended.byName('settings')!),
                          onClick: () => Navigator.of(context).push<void>(AppMotionRoute<void>(builder: (_) => const SettingsPage())),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }

  /// 「可接分部：X / Y」——无授权时给明确中文提示（不靠前端隐藏按钮，服务端照样会拒）
  Widget _divisionLine(AuthMe me) {
    final divs = me.takeOrderDivisions;
    final text = divs.isEmpty
        ? '可接分部：暂无（请联系管理员开通）'
        : '可接分部：${divs.map((d) => d.label).join(' / ')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: Color(0xFFE3F2FD)),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      ),
    );
  }

  Widget _chip(String label, bool enabled) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: (enabled ? AppColors.success : Colors.white).withValues(alpha: enabled ? 0.2 : 0.18),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(enabled ? Icons.check_circle : Icons.block, size: 14, color: enabled ? const Color(0xFFB9F6CA) : Colors.white70),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: TextStyle(fontSize: 12, color: enabled ? const Color(0xFFB9F6CA) : Colors.white70), overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
}

/// 积分概览卡（GET /worker/my-wallet：余额/累计获得/累计消费，全部来自真实流水聚合）
class _EarningsCard extends StatefulWidget {
  const _EarningsCard({this.api});

  final ApiClient? api;

  @override
  State<_EarningsCard> createState() => _EarningsCardState();
}

class _EarningsCardState extends State<_EarningsCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await _api.request('GET', '/worker/my-wallet', token: AuthStore.instance.accessToken);
      if (!mounted) return;
      setState(() {
        _data = resp['data'] as Map<String, dynamic>?;
        _loading = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return FishGlassCard(
      insideMargin: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      child: _loading
          ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : d == null
              ? const Text('加载失败，下拉刷新重试', style: TextStyle(color: AppColors.textTertiary, fontSize: 13))
              : Row(
                  children: [
                    Expanded(child: _stat('当前积分', fmtPoints(parsePoints(d['balance'])))),
                    Container(width: 1, height: 26, color: T.divider),
                    Expanded(child: _stat('累计获得', fmtPoints(parsePoints(d['totalIncome'])))),
                    Container(width: 1, height: 26, color: T.divider),
                    Expanded(child: _stat('累计消费', fmtPoints(parsePoints(d['totalSpent'])))),
                  ],
                ),
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.primary), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ],
      );
}
