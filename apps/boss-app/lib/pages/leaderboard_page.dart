import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 排行榜（**方案 G 视觉重构**，负责人 2026-10-17 定案；接口 / 状态流转 / 跳转一字未改）
///
/// 负责人硬规则（CLAUDE.md 结构规则 6）：
/// - 每行只有 **名次 + 头像 + 名字 + 数值**，**不写分部、不带任何标签**
/// - 分部由上方胶囊决定；同一游戏平台数为 1 时不出现该平台选项（和平精英没有端游）
/// - 不做奖杯插画、不做并排三个大数字
///
/// 方案 G 的落地点（逐条）：
/// - 页底 `#F6F7F9`；
/// - 周/月切换 = **两枚胶囊**（选中：主色 `#2563EB` 实底 + 白字；未选中：白底 + 1px 描边），
///   与下方"分部筛选"胶囊刻意不同款（一个换周期、一个换榜），不靠颜色而靠位置区分；
/// - **前三名各一张卡**：金 `#D4A017` / 银 `#9AA3AF` / 铜 `#B87333` **1.5px 描边**，
///   白底（**不是渐变底**，docs/21 禁渐变做主视觉）；
/// - 第 4 名起 = 名次行：名次数字 **tabular**、头像字标（[AppAvatar]）、名字、数值右对齐；
/// - 全页 **零渐变、零阴影**（阴影只给弹层；列表用发丝线）—— 与既有源码级自查一致。
class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key, this.api, this.initialDivisionId});

  final ApiClient? api;
  final String? initialDivisionId;

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  /// 方案 G 页底（`#F6F7F9`）与前三名描边色 —— 本页私有常量，不新增/改动 core token
  static const Color _pageBg = AppColors.bgPageG;
  static const Color _goldBorder = Color(0xFFD4A017);
  static const Color _silverBorder = Color(0xFF9AA3AF);
  static const Color _bronzeBorder = Color(0xFFB87333);

  /// 名次数字用等宽数字（tabular）：两位数时列不会左右抖
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  late final ApiClient _api = widget.api ?? ApiClient();

  bool _loading = true;
  String? _error;
  List<_Division> _divisions = const [];
  List<_Row> _rows = const [];
  String? _divisionId;
  String _kind = 'week';

  @override
  void initState() {
    super.initState();
    _divisionId = widget.initialDivisionId;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final resp = await _api.request('GET', '/divisions');
      if (!mounted) return;
      final list = (resp['data'] as List?) ?? const [];
      setState(() => _divisions = list.map((d) => _Division.fromJson(d as Map)).toList());
    } on ApiException {
      // 分部拿不到不影响看全站榜
    }
    await _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await _api.request('GET', '/public/leaderboard', queryParameters: {
        'kind': _kind,
        'divisionId': ?_divisionId,
      });
      final data = (resp['data'] as Map?) ?? const {};
      final list = (data['list'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _rows = list.map((r) => _Row.fromJson(r as Map)).toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Scaffold(
        backgroundColor: _pageBg,
        appBar: AppBar(
          backgroundColor: AppColors.bgCard,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          // 榜名（本页只出现这一次）+ 副标题：承接原横幅里「每日 03:00 更新」的信息
          // （统计周期由下方周期胶囊右侧的小字给出 —— 同一句话不出现两次）
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text('接单榜',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const SizedBox(width: 10),
              Flexible(
                child: Text('按已完成订单金额 · 每日 03:00 更新',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
              ),
            ],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () => _load(force: true),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              // 统计周期：两枚胶囊（选中主色实底白字）+ 右侧真实周期范围小字
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    _periodPill('周榜', _kind != 'month', () {
                      setState(() => _kind = 'week');
                      _load();
                    }),
                    const SizedBox(width: 8),
                    _periodPill('月榜', _kind == 'month', () {
                      setState(() => _kind = 'month');
                      _load();
                    }),
                    const Spacer(),
                    Text(_periodLabel(), style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
                  ],
                ),
              ),
              // 分部胶囊（看哪个榜）：白底描边 / 选中浅蓝底 + 主色描边 + 主色字
              if (_divisions.isNotEmpty)
                SizedBox(
                  height: 46,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    itemCount: _divisions.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final d = _divisions[i];
                      final on = d.id == _divisionId;
                      return _chip(d.name, on, () {
                        setState(() => _divisionId = on ? null : d.id);
                        _load();
                      });
                    },
                  ),
                ),
              const SizedBox(height: 6),
              _header(),
              ..._body(),
            ],
          ),
        ),
        // 吸底说明条（措辞与「去下单 ›」原样保留 —— 老板端**没有**「我的排名」，
        // 不凭空造个人名次卡；本条的规则说明本身就是真实口径）
        bottomNavigationBar: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                AppIcon.of(AppIcon.clock, size: 15, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('每周一 03:00 重新统计 · 完成订单即可上榜',
                      style: TextStyle(fontSize: 11, color: T.mutedText)),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Text('去下单 ›',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: T.primary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 统计周期文案（按周/月给出真实范围，不写死日期）
  String _periodLabel() {
    final now = DateTime.now();
    if (_kind == 'month') {
      final last = DateTime(now.year, now.month + 1, 0);
      return '${now.month}-01 至 ${now.month}-${last.day}';
    }
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(monday.month)}-${two(monday.day)} 至 ${two(sunday.month)}-${two(sunday.day)}';
  }

  /// 周期胶囊：选中 = 主色实底 + 白字（方案 G 原文）；未选中 = 白底 + 1px 描边
  Widget _periodPill(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(
            color: on ? AppColors.primary : AppColors.bgCard,
            borderRadius: BorderRadius.circular(999),
            border: on ? null : Border.all(color: AppColors.strokeSoft),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      );

  /// 分部胶囊（看哪个榜）：与周期胶囊刻意不同款
  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            color: on ? AppColors.primarySoft : AppColors.bgCard,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: on ? AppColors.primary : AppColors.strokeSoft),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                  color: on ? AppColors.primary : AppColors.textSecondary)),
        ),
      );

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
        child: Row(
          children: [
            Text('名次', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            const SizedBox(width: 34),
            Text('陪玩', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            const Spacer(),
            Text('接单金额（¥）', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
          ],
        ),
      );

  List<Widget> _body() {
    if (_loading) {
      return [
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Row(
              children: [
                Container(width: 18, height: 14, color: T.divider),
                const SizedBox(width: 16),
                Container(width: 30, height: 30, decoration: BoxDecoration(color: T.divider, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Container(width: 70, height: 13, color: T.divider),
                const Spacer(),
                Container(width: 46, height: 13, color: T.divider),
              ],
            ),
          ),
      ];
    }
    if (_error != null) {
      return [AppEmptyState(icon: AppIcon.info, text: '加载失败：$_error', action: '重试', onAction: _load)];
    }
    if (_rows.isEmpty) {
      return [const AppEmptyState(icon: AppIcon.empty, text: '该分部本周还没有接单记录')];
    }
    // 前三名各一张卡（金/银/铜描边），第 4 名起是名次行；两段之间一条发丝线
    final podium = _rows.where((r) => r.rank >= 1 && r.rank <= 3).take(3).toList();
    final rest = _rows.where((r) => r.rank < 1 || r.rank > 3).toList();
    final out = <Widget>[];
    for (var i = 0; i < podium.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 10));
      out.add(_podiumCard(podium[i]));
    }
    if (podium.isNotEmpty && rest.isNotEmpty) {
      out.add(Divider(height: 1, thickness: 1, color: T.divider, indent: 18, endIndent: 18));
    }
    for (var i = 0; i < rest.length; i++) {
      if (i > 0) out.add(Divider(height: 1, thickness: 1, color: T.divider, indent: 18, endIndent: 18));
      out.add(_row(rest[i]));
    }
    return out;
  }

  /// 前三名卡片：白底 + 1.5px 名次描边 + 圆角 12（**不是渐变底**）
  Widget _podiumCard(_Row r) {
    final edge = switch (r.rank) {
      1 => _goldBorder,
      2 => _silverBorder,
      3 => _bronzeBorder,
      _ => AppColors.strokeSoft,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: edge, width: 1.5),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${r.rank}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: edge,
                  fontFeatures: _tabular,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 10),
            AppAvatar(nickname: r.name, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            ),
            // 榜首金额是**大字金额**（size 19 = 大字门槛）→ 按方案 G 用大字金 `AppColors.gold`；
            // 二三名仍是小字 → 深金 `T.goldText`（两档金同一支色，见 core 的 R1–R3 红线）
            AppPrice(
              value: r.amount,
              unit: '',
              size: r.rank == 1 ? 19 : 15,
              color: r.rank == 1 ? AppColors.gold : T.goldText,
            ),
          ],
        ),
      ),
    );
  }

  /// 第 4 名起的名次行：名次（tabular）+ 头像字标 + 名字 + 数值右对齐
  Widget _row(_Row r) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${r.rank}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.mutedText,
                fontFeatures: _tabular,
              ),
            ),
          ),
          const SizedBox(width: 12),
          AppAvatar(nickname: r.name, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ),
          AppPrice(value: r.amount, unit: '', size: 15, color: T.goldText),
        ],
      ),
    );
  }
}

class _Division {
  _Division({required this.id, required this.name});

  final String id;
  final String name;

  factory _Division.fromJson(Map json) => _Division(id: '${json['id']}', name: (json['name'] as String?) ?? '');
}

class _Row {
  _Row({required this.rank, required this.name, required this.amount});

  final int rank;
  final String name;
  final String amount;

  factory _Row.fromJson(Map json) {
    final amt = (json['amount'] as num?)?.toDouble() ?? 0;
    return _Row(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      name: (json['nickname'] as String?)?.trim().isNotEmpty == true ? json['nickname'] as String : '陪玩',
      // 接单金额 = 金额 → 走统一出口（¥ + 两位小数 + 千分位），不再自己拼千分位
      amount: fmtMoney(amt),
    );
  }
}
