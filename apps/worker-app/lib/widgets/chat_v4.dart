/// 聊天页渲染骨架（设计稿 v4：site/design/chat-ui-v4.html）
///
/// 职责边界：**只做渲染** —— 页头 / 消息行 / 时间与已读 / 输入栏 / 客服信息条与快捷问题。
/// 数据、发送、分页、撤回、WS 刷新、已读标记全部留在页面（chat_detail_page.dart）；
/// 本文件唯一状态 = 输入框文本 + 滚动位置，不持有任何业务状态。
///
/// 设计稿硬参数（逐条对齐 docs/21 反 AI 味规范：禁渐变主视觉 / 禁全大圆角 / 禁满屏阴影）：
/// - 页底纯色 `#EFF2F7`（深色 `#12151C`），**无渐变、无光斑、无玻璃页壳**
/// - 页头 56 + 底部 1px 发丝线 `#EEF1F6`；返回 21；头像 32；名字 15.5/w600 `#111827`；状态 11 `#98A2B3`
/// - 气泡：圆角 14；内边距 14×12；正文 14 / 行高 22；我方实色 `#2563EB` 白字；
///   对方白底 + 1px 发丝线 `#E5E9F0` + 1px 极轻投影（dy1 blur1 4%，只给气泡不给卡片）
/// - 首条**贝塞尔曲线尾角**（不是生硬三角）；头像 34 + 2px 白描边，底边与气泡底对齐
/// - 节奏：同发送者 6 / 换发送者 18 / 跨时段（>5 分钟）24；时间**只在每批末条**
/// - 输入栏：白底 + 顶 1px 发丝线；「+」描边入口；输入框圆角 18 底 `#EFF2F7`；文字「发送」
library;

import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// 色板：浅色严格照设计稿十六进制；深色按同语义给深色值（避免白字白底）
// ---------------------------------------------------------------------------

class _C {
  const _C(this.dark);

  final bool dark;

  /// 页底
  Color get page => dark ? const Color(0xFF12151C) : const Color(0xFFEFF2F7);

  /// 页头 / 输入栏 / 卡片底
  Color get surface => dark ? const Color(0xFF1A1E27) : Colors.white;

  /// 页头与输入栏分隔线（设计稿 #EEF1F6）
  Color get hairline => dark ? const Color(0xFF262C38) : const Color(0xFFEEF1F6);

  /// 气泡 / 卡片描边（设计稿 #E5E9F0）
  Color get hairlineStrong => dark ? const Color(0xFF333B49) : const Color(0xFFE5E9F0);

  /// 主色（我方气泡、发送键）
  Color get primary => dark ? const Color(0xFF3B82F6) : AppColors.primary;

  Color get textPrimary => dark ? const Color(0xFFE8ECF3) : const Color(0xFF111827);
  Color get textSecondary => dark ? const Color(0xFFA8B2C1) : const Color(0xFF556070);
  Color get textTertiary => dark ? const Color(0xFF8A94A6) : const Color(0xFF98A2B3);

  /// 对方气泡底
  Color get bubbleIn => dark ? const Color(0xFF1F242E) : Colors.white;

  /// 我方气泡上的时间与双勾（设计稿 #CFE0FB / #9FC0F7）
  Color get onPrimarySoft => dark ? const Color(0xFFCBDAF5) : const Color(0xFFCFE0FB);
  Color get onPrimaryTick => dark ? const Color(0xFF9BBBF0) : const Color(0xFF9FC0F7);

  /// 分隔 chip（日期 #E4E8EF/#8A94A6，系统 #E7EBF2/#556070）
  Color get chipDateBg => dark ? const Color(0xFF232935) : const Color(0xFFE4E8EF);
  Color get chipDateFg => dark ? const Color(0xFF98A2B3) : const Color(0xFF8A94A6);
  Color get chipSysBg => dark ? const Color(0xFF272E3B) : const Color(0xFFE7EBF2);
  Color get chipSysFg => dark ? const Color(0xFFA8B2C1) : const Color(0xFF556070);

  /// 输入框底（设计稿 #EFF2F7）
  Color get inputBg => dark ? const Color(0xFF232935) : const Color(0xFFEFF2F7);

  /// 发送键空内容态（设计稿 #E3E8EF + 灰字）
  Color get sendDisabledBg => dark ? const Color(0xFF2A313D) : const Color(0xFFE3E8EF);

  /// 图片消息内嵌灰块（设计稿 #EDF1F7）
  Color get imageInner => dark ? const Color(0xFF2A313D) : const Color(0xFFEDF1F7);

  /// 撤回消息灰底
  Color get recalledBg => dark ? const Color(0xFF232935) : const Color(0xFFEDF0F4);

  /// 会话头像低饱和同色系（设计稿 #DFE7F4 底 / #3A5A99 字）
  Color get avatarBg => dark ? const Color(0xFF2B3242) : const Color(0xFFDFE7F4);
  Color get avatarFg => dark ? const Color(0xFFC6D6F0) : const Color(0xFF3A5A99);
}

/// 尺寸常量（设计稿 8pt 网格）
class ChatV4Metrics {
  ChatV4Metrics._();

  static const double headerHeight = 56;
  static const double bubbleRadius = 14;
  static const double bubblePadH = 14;
  static const double bubblePadV = 12;
  static const double avatarSize = 34;
  static const double avatarGap = 12;
  static const double gapSameSender = 6;
  static const double gapNewSender = 18;
  static const double gapNewBand = 24;

  /// 跨时段阈值（分钟）：超过即另起一批并插时间分隔（任务书 > 5 分钟）
  static const int bandMinutes = 5;

  /// 时间只显示到「批」的粒度；正文最大宽度（360 屏 − 侧边距 − 头像 − 时间列）
  static const double bubbleMaxWidth = 264;
}

// ---------------------------------------------------------------------------
// 页头
// ---------------------------------------------------------------------------

/// 聊天页头：返回图标（21）/ 头像 32 / 名字 15.5-w600 + 状态行（6px 绿点 + 11px 灰字）/ 最右 three-dot
class ChatV4Header extends StatelessWidget {
  const ChatV4Header({
    super.key,
    required this.nickname,
    required this.statusText,
    this.avatarMediaId,
    this.online = true,
    this.onBack,
    this.onMore,
  });

  final String nickname;
  final String statusText;
  final String? avatarMediaId;
  final bool online;
  final VoidCallback? onBack;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    return Container(
      height: ChatV4Metrics.headerHeight,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.hairline, width: 1)),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
            child: SizedBox(
              width: 44,
              height: ChatV4Metrics.headerHeight,
              child: Icon(AppIcon.arrowLeft, size: 21, color: c.textPrimary),
            ),
          ),
          _HeaderAvatar(nickname: nickname, mediaId: avatarMediaId, online: online, surface: c.surface),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: c.textPrimary, height: 1.15),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: online ? AppColors.success : c.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: c.textTertiary, height: 1.2),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 没有更多操作时不拦截点击（设计稿保留 three-dot 图标位）
            onTap: onMore,
            child: SizedBox(
              width: 44,
              height: ChatV4Metrics.headerHeight,
              child: Icon(AppIcon.dots, size: 22, color: c.textSecondary),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({required this.nickname, required this.mediaId, required this.online, required this.surface});

  final String nickname;
  final String? mediaId;
  final bool online;
  final Color surface;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          ChatV4Avatar(nickname: nickname, mediaId: mediaId, size: 32),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: surface, width: 2),
                ),
              ),
            ),
        ],
      );
}

/// 会话头像 34 + 2px 白描边（无头像时低饱和同色系首字底）
class ChatV4Avatar extends StatelessWidget {
  const ChatV4Avatar({super.key, required this.nickname, this.mediaId, this.size = ChatV4Metrics.avatarSize});

  final String nickname;
  final String? mediaId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    final hasImage = mediaId != null && mediaId!.isNotEmpty;
    final inner = size - 4; // 白描边 2px（视觉直径 = size）
    final face = hasImage
        ? ClipOval(child: AppAvatar(nickname: nickname, mediaId: mediaId, size: inner))
        : Container(
            width: inner,
            height: inner,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.avatarBg, shape: BoxShape.circle),
            child: Text(
              nickname.isNotEmpty ? nickname.characters.first : '?',
              style: TextStyle(fontSize: inner * 0.42, fontWeight: FontWeight.w600, color: c.avatarFg),
            ),
          );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
      child: face,
    );
  }
}

/// 客服信息条（仅客服会话）：白卡 + 圆角 12 + 1px 发丝线；
/// 头像 34 + 名字 13.5/w600 + 绿点「在线 · 刚回过」+ 次行「工作时间 · 工号 XX」+ 右侧「结束咨询」
class ChatV4CsBar extends StatelessWidget {
  const ChatV4CsBar({
    super.key,
    required this.nickname,
    this.avatarMediaId,
    this.staffNo = '',
    this.serviceHours = '9:00–次日 2:00',
    this.closed = false,
    this.onFinish,
  });

  final String nickname;
  final String? avatarMediaId;
  final String staffNo;
  final String serviceHours;
  final bool closed;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.hairlineStrong, width: 1),
      ),
      child: Row(
        children: [
          ChatV4Avatar(nickname: nickname, mediaId: avatarMediaId, size: 30),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        nickname,
                        // 会话名最多 2 行（与老板端同一规则：老板/好友昵称上限 20 字，1 行 ≈14 字会截断）
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textPrimary),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: closed ? c.textTertiary : AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        closed ? '本次咨询已结束' : '在线 · 刚回过',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: c.textTertiary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  // 工号来自后端（会话 active 指派客服的真实 worker_no）；无指派 → 「人工客服」，不编造编号
                  staffNo.isEmpty ? '$serviceHours · 人工客服' : '$serviceHours · 工号 $staffNo',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: c.textTertiary),
                ),
              ],
            ),
          ),
          if (!closed)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onFinish,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text(
                  '结束咨询',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: c.textSecondary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 快捷问题 chips（仅客服会话）：白底 + 发丝线 + 圆角 14 / 11.5 灰字 / 长短不一 / 横向滚动
class ChatV4QuickAsks extends StatelessWidget {
  const ChatV4QuickAsks({super.key, required this.items, required this.onTap});

  final List<String> items;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => onTap(items[i]),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.hairlineStrong, width: 1),
            ),
            child: Text(items[i], style: TextStyle(fontSize: 11.5, color: c.textSecondary)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 消息行
// ---------------------------------------------------------------------------

/// 单条消息（渲染视图模型；页面负责从 flutter_chat_core 的 Message 映射过来）
class ChatV4Item {
  const ChatV4Item({
    required this.id,
    required this.text,
    required this.isMine,
    required this.senderId,
    required this.at,
    this.seq = 0,
    this.isImage = false,
    this.imageBytes,
    this.imageUrl,
    this.pending = false,
    this.failed = false,
    this.recalled = false,
    this.system = false,
    this.readByPeer = false,
  });

  final String id;
  final String text;
  final bool isMine;
  final String senderId;
  final DateTime at;

  /// 会话内消息序号（服务端分配；对方已读位点与它比较 → 单勾/双勾）
  final int seq;

  final bool isImage;

  /// 本地待上传图片字节（发送中立即上屏）
  final Uint8List? imageBytes;
  final String? imageUrl;
  final bool pending;
  final bool failed;
  final bool recalled;

  /// 非 text/image 的中性提示（居中灰 chip）
  final bool system;

  /// 对方已读到这条（对方已读位点 >= 本条 seq）→ 双勾；false 且已 ack → 单勾
  final bool readByPeer;
}

/// 对端信息（页面一次给全，行渲染不回查业务状态）
class ChatV4Peer {
  const ChatV4Peer({required this.nickname, this.avatarMediaId, this.senderName = ''});

  final String nickname;
  final String? avatarMediaId;

  /// 对方在会话里的显示名（好友/打手昵称；空则用会话标题）
  final String senderName;
}

/// 一条消息 + 它在分组里的位置（间距/头像/尾角/时间由布局算出）
class _Row {
  const _Row(this.item, {required this.gap, required this.showAvatar, required this.showTail, required this.showTime, this.dayChip});

  final ChatV4Item item;
  final double gap;
  final bool showAvatar;
  final bool showTail;
  final bool showTime;
  final String? dayChip;
}

class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.items,
    required this.peer,
    this.peerReadSeq = 0,
    this.showSkeleton = false,
    this.onRetry,
    this.onLoadMore,
    this.onImageTap,
    this.composer,
  });

  final List<ChatV4Item> items;
  final ChatV4Peer peer;

  /// 对方已读位点（服务端 conversationInfo.peerReadSeq + WS msg:read 实时更新）
  final int peerReadSeq;

  final bool showSkeleton;
  final ValueChanged<ChatV4Item>? onRetry;
  final VoidCallback? onLoadMore;
  final ValueChanged<String>? onImageTap;
  final Widget? composer;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final ScrollController _scroll = ScrollController();

  /// 翻页触发点：距顶部 320 内即预拉（与 flutter_chat_ui 的触底行为一致）
  static const double _loadMoreThreshold = 320;

  bool _atBottom = true;
  bool _loadingMore = false;
  double _prevExtent = 0;
  double _keyboardInset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 键盘弹起 → 可滚动区域变矮：原先贴底的会话要自动上贴（不打断正在翻历史的用户）
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final opened = inset > _keyboardInset + 1;
    _keyboardInset = inset;
    if (opened && _atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _atBottom = pos.extentAfter < 64;
    if (pos.pixels <= _loadMoreThreshold && !_loadingMore && widget.onLoadMore != null) {
      _loadingMore = true;
      _prevExtent = pos.maxScrollExtent;
      widget.onLoadMore!();
      // 页面拉取返回前不重复触发（didUpdateWidget 在消息数变化时复位）
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (mounted) _loadingMore = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _MessageList old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length) _loadingMore = false;
    if (widget.items.isEmpty) return;
    final appended = old.items.isEmpty || old.items.last.id != widget.items.last.id;
    if (!appended) return;

    // 头部补拉（更早历史）：保持视口内容不跳
    final prepended = old.items.isNotEmpty && widget.items.first.id != old.items.first.id;
    if (prepended) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final delta = _scroll.position.maxScrollExtent - _prevExtent;
        if (delta > 0) _scroll.jumpTo(_scroll.position.pixels + delta);
      });
      return;
    }
    // 自己发出的消息必定滚到底；否则仅当原本就在底部才跟随
    if (widget.items.last.isMine || _atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
  }

  void _toBottom({bool jump = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (jump) {
      _scroll.jumpTo(target);
    } else if ((_scroll.position.pixels - target).abs() > 1) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  /// 时间格式：今天 HH:mm / 昨天 HH:mm / M月d日 HH:mm
  static String formatTime(DateTime t) {
    final local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  static String formatDayBand(DateTime t) {
    final local = t.toLocal();
    final now = DateTime.now();
    final day = DateTime(local.year, local.month, local.day);
    final diff = DateTime(now.year, now.month, now.day).difference(day).inDays;
    if (diff == 0) return '今天 ${formatTime(local)}';
    if (diff == 1) return '昨天 ${formatTime(local)}';
    return '${local.month}月${local.day}日 ${formatTime(local)}';
  }

  /// 分组：同发送者紧（6）、换发送者松（18）、跨时段 >5 分钟另起一批（24）+ 时间分隔
  List<_Row> _layout() {
    final out = <_Row>[];
    for (var i = 0; i < widget.items.length; i++) {
      final cur = widget.items[i];
      if (cur.system || cur.recalled) {
        out.add(_Row(cur, gap: 18, showAvatar: false, showTail: false, showTime: false));
        continue;
      }
      final prev = i > 0 ? widget.items[i - 1] : null;
      final sameSender = prev != null && !prev.system && !prev.recalled && prev.senderId == cur.senderId;
      final gapMinutes = prev == null ? 999 : cur.at.difference(prev.at).inMinutes.abs();
      final newBand = prev == null || gapMinutes > ChatV4Metrics.bandMinutes;
      final isBatchStart = !sameSender || newBand;
      final next = i + 1 < widget.items.length ? widget.items[i + 1] : null;
      final isBatchEnd = next == null ||
          next.senderId != cur.senderId ||
          next.at.difference(cur.at).inMinutes.abs() > ChatV4Metrics.bandMinutes;
      final crossDay = prev != null && prev.at.toLocal().day != cur.at.toLocal().day;
      out.add(_Row(
        cur,
        // 节奏：同批内 6（同发送者）/ 18（换发送者仍同批）；跨时段另起一批 24
        gap: prev == null
            ? 0
            : (newBand
                ? ChatV4Metrics.gapNewBand
                : (sameSender ? ChatV4Metrics.gapSameSender : ChatV4Metrics.gapNewSender)),
        showAvatar: !cur.isMine && isBatchStart,
        showTail: isBatchStart,
        showTime: isBatchEnd,
        dayChip: prev == null || crossDay ? formatDayBand(cur.at) : null,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _layout();
    final showSkeleton = widget.showSkeleton && rows.isEmpty;
    return Column(
      children: [
        Expanded(
          child: rows.isEmpty && !showSkeleton
              ? const SizedBox.shrink()
              : ListView.builder(
                  controller: _scroll,
                  // 左右各留 10：左给"对方尾角"的溢出，右给我方尾角的溢出（8pt 网格下的安全边）
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                  itemCount: rows.length + (showSkeleton ? 1 : 0),
                  itemBuilder: (context, index) => index >= rows.length
                      ? const _BubbleSkeleton()
                      : _MessageRow(
                          row: rows[index],
                          peer: widget.peer,
                          peerReadSeq: widget.peerReadSeq,
                          onRetry: widget.onRetry,
                          onImageTap: widget.onImageTap,
                        ),
                ),
        ),
        if (widget.composer != null) widget.composer!,
      ],
    );
  }
}

/// 轻量骨架（只在消息区，绝不整页转圈）：两条对方 + 一条我方气泡轮廓。
/// 刻意不做无限循环动画：避免 pumpAndSettle 无法收敛（测试与无障碍都受益）。
class _BubbleSkeleton extends StatelessWidget {
  const _BubbleSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    final shimmer = Color.lerp(c.hairlineStrong, c.surface, 0.5)!;
    Widget block(double w, double h) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(begin: c.hairlineStrong, end: shimmer),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          builder: (context, color, _) => Container(
            width: w,
            height: h,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(width: 34, height: 34, decoration: BoxDecoration(color: c.hairlineStrong, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              block(180, 44),
            ],
          ),
          const SizedBox(height: 18),
          Padding(padding: const EdgeInsets.only(left: 46), child: block(126, 44)),
          const SizedBox(height: 18),
          Align(alignment: Alignment.centerRight, child: block(212, 44)),
        ],
      ),
    );
  }
}

/// 单行消息：我方右对齐 / 对方左对齐 + 头像（底边与气泡底对齐；连续同一发送者只首条显示）
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.row, required this.peer, this.peerReadSeq = 0, this.onRetry, this.onImageTap});

  final _Row row;
  final ChatV4Peer peer;

  /// 对方已读位点（>= 本条 seq = 双勾）
  final int peerReadSeq;

  final ValueChanged<ChatV4Item>? onRetry;
  final ValueChanged<String>? onImageTap;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    final item = row.item;
    final isChip = item.system || item.recalled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (row.dayChip != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: _chip(row.dayChip!, c.chipDateBg, c.chipDateFg)),
        Padding(
          padding: EdgeInsets.only(bottom: isChip ? 18 : row.gap),
          child: isChip
              ? _chip(item.recalled && item.text.isEmpty ? '消息已撤回' : item.text, c.chipSysBg, c.chipSysFg)
              : _bubbleRow(c),
        ),
      ],
    );
  }

  Widget _chip(String text, Color bg, Color fg) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
          child: Text(text, style: TextStyle(fontSize: 10.5, color: fg)),
        ),
      );

  Widget _bubbleRow(_C c) {
    final item = row.item;
    if (item.isMine) {
      return Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [_bubbleColumn(c)],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: ChatV4Metrics.avatarSize,
            height: ChatV4Metrics.avatarSize,
            child: row.showAvatar
                ? ChatV4Avatar(
                    nickname: peer.senderName.isNotEmpty ? peer.senderName : peer.nickname,
                    mediaId: peer.avatarMediaId,
                  )
                : null,
          ),
          const SizedBox(width: ChatV4Metrics.avatarGap),
          Flexible(child: _bubbleColumn(c)),
        ],
      ),
    );
  }

  /// 气泡 + 其下方的「时间 / 已读」（我方或图片消息的时间在气泡外）
  Widget _bubbleColumn(_C c) {
    final item = row.item;
    // 我方消息也要显示发送中（时钟）：pending 不再吞掉时间行
    final outsideTime = row.showTime && (item.isMine || item.isImage);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: item.isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _bubble(c),
        if (outsideTime)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_MessageListState.formatTime(item.at), style: TextStyle(fontSize: 10, color: c.textTertiary)),
                if (item.isMine) ...[
                  const SizedBox(width: 4),
                  // 已读回执（负责人 2026-10-04）：
                  // pending → 时钟；sent 未读 → 单勾；对方已读位点 >= 本条 seq → 双勾
                  _mineMark(c),
                ],
              ],
            ),
          ),
        if (item.failed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () => onRetry?.call(item),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 12, color: AppColors.error),
                  const SizedBox(width: 4),
                  const Text('发送失败，点击重试', style: TextStyle(fontSize: 10, color: AppColors.error)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 我方消息的送达/已读标记：
  /// - 发送失败 → 不显示勾（下方单独给「发送失败，点击重试」）
  /// - pending（未收到服务端 ack）→ 时钟
  /// - 已 ack 且对方未读 → **单勾**
  /// - 对方已读位点 >= 本条 seq → **双勾**
  Widget _mineMark(_C c) {
    final item = row.item;
    if (item.failed) return const SizedBox.shrink();
    if (item.pending || item.seq <= 0) return _ClockMark(color: c.onPrimaryTick);
    final read = item.readByPeer || (peerReadSeq > 0 && peerReadSeq >= item.seq);
    return read ? _DoubleCheck(color: c.onPrimaryTick) : _SingleCheck(color: c.onPrimaryTick);
  }

  Widget _bubble(_C c) {
    final item = row.item;
    if (item.isImage) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: CustomPaint(
          painter: _BubblePainter(
            radius: ChatV4Metrics.bubbleRadius,
            fill: c.bubbleIn,
            stroke: c.hairlineStrong,
            shadow: true,
            tailSide: row.showTail ? TailSide.left : TailSide.none,
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _imageBody(c)),
          ),
        ),
      );
    }
    // 硬性宽度上限：Flexible/Row 只给 loose 约束，长文本会把气泡撑破（真机=文字溢出气泡）
    final mine = item.isMine;
    return Container(
      margin: EdgeInsets.only(left: mine ? 0 : 6, right: mine ? 4 : 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ChatV4Metrics.bubbleMaxWidth),
        child: CustomPaint(
          painter: _BubblePainter(
            radius: ChatV4Metrics.bubbleRadius,
            fill: mine ? c.primary : c.bubbleIn,
            stroke: mine ? null : c.hairlineStrong,
            shadow: !mine,
            tailSide: row.showTail ? (mine ? TailSide.right : TailSide.left) : TailSide.none,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ChatV4Metrics.bubblePadH,
              vertical: ChatV4Metrics.bubblePadV,
            ),
            child: _bubbleText(c),
          ),
        ),
      ),
    );
  }

  /// 正文 + （对方）同行右下角时间。时间只在每批最后一条
  Widget _bubbleText(_C c) {
    final item = row.item;
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: ChatV4Metrics.bubbleMaxWidth),
      child: Text(
        item.text,
        style: TextStyle(
          fontSize: 14,
          height: 22 / 14,
          color: item.isMine ? Colors.white : c.textPrimary,
        ),
      ),
    );
    // 时间只在每批最后一条：我方与图片的时间放气泡**下方**（设计稿如此，同时避免挤压正文宽度）
    final inlineTime = row.showTime && !item.isMine && !item.isImage && !item.pending;
    if (!inlineTime) return body;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: body),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: Text(_MessageListState.formatTime(item.at), style: TextStyle(fontSize: 10, color: c.textTertiary)),
        ),
      ],
    );
  }

  Widget _imageBody(_C c) {
    final item = row.item;
    final bytes = item.imageBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(bytes, width: 138, height: 96, fit: BoxFit.cover, cacheWidth: 360);
    }
    final url = item.imageUrl;
    if (url == null || url.isEmpty) {
      return Container(
        width: 138,
        height: 96,
        color: c.imageInner,
        alignment: Alignment.center,
        child: Text('发送中…', style: TextStyle(fontSize: 11, color: c.textTertiary)),
      );
    }
    return GestureDetector(
      onTap: () => onImageTap?.call(url),
      child: Image.network(
        url,
        width: 138,
        height: 96,
        fit: BoxFit.cover,
        cacheWidth: 360,
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : Container(
                width: 138,
                height: 96,
                color: c.imageInner,
                alignment: Alignment.center,
                child: Text('加载中…', style: TextStyle(fontSize: 11, color: c.textTertiary)),
              ),
        errorBuilder: (_, _, _) => Container(
          width: 138,
          height: 96,
          color: c.imageInner,
          alignment: Alignment.center,
          child: Icon(AppIcon.image, size: 20, color: c.textTertiary),
        ),
      ),
    );
  }
}

/// 双勾（✓✓，#9FC0F7 描边 1.5 圆头）
class _DoubleCheck extends StatelessWidget {
  const _DoubleCheck({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(15, 9), painter: _CheckPainter(color));
}

/// 单勾（✓ = 服务端已 ack、对方尚未读到）
class _SingleCheck extends StatelessWidget {
  const _SingleCheck({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(10, 9), painter: _CheckPainter(color, marks: const [0.0]));
}

/// 发送中时钟（pending：本地已上屏、服务端尚未 ack）
class _ClockMark extends StatelessWidget {
  const _ClockMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Icon(AppIcon.clock, size: 11, color: color);
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.color, {this.marks = const [0.0, 5.5]});

  final Color color;

  /// 勾的起始 x 偏移（单勾只画一个，双勾画两个）
  final List<double> marks;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final dx in marks) {
      final p = Path()
        ..moveTo(dx, size.height * 0.5)
        ..lineTo(dx + 3, size.height * 0.85)
        ..lineTo(dx + 8, 0);
      canvas.drawPath(p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) => old.color != color || old.marks != marks;
}

// ---------------------------------------------------------------------------
// 气泡形状：圆角 14 + 首批贝塞尔曲线尾角（不是生硬三角）
// ---------------------------------------------------------------------------

enum TailSide { none, left, right }

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.radius,
    required this.fill,
    this.stroke,
    this.tailSide = TailSide.none,
    this.shadow = false,
  });

  final double radius;
  final Color fill;
  final Color? stroke;
  final TailSide tailSide;
  final bool shadow;

  /// 尾角凸出尺寸（设计稿 10 宽，视觉高度 12）
  static const double _tailW = 10;

  /// 气泡主体：圆角矩形（尾角单独画，避免路径自交被 nonZero 填充抵消）
  Path _body(Size size) {
    final r = radius;
    final w = size.width;
    final h = size.height;
    final p = Path()
      ..moveTo(r, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: Radius.circular(r))
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: Radius.circular(r))
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: Radius.circular(r))
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..close();
    return p;
  }

  /// 曲线尾角：贴气泡侧缘、尖端 10/12px 处收束（贝塞尔，不是生硬三角）
  /// 两个锚点各内缩 2px 藏进气泡，避免 1px 发丝线在接缝处露白。
  Path _tail(Size size) {
    final w = size.width;
    final h = size.height;
    final top = h < 30 ? 2.0 : h * 0.3;
    final bot = top + 12;
    final p = Path();
    if (tailSide == TailSide.right) {
      p.moveTo(w - 2, top);
      p.quadraticBezierTo(w + 5, top + 2, w + _tailW, top + 7);
      p.quadraticBezierTo(w + 4, top + 6, w - 2, bot);
      p.quadraticBezierTo(w + 4, top + 7, w - 2, top);
    } else {
      p.moveTo(2, top);
      p.quadraticBezierTo(-5, top + 2, -_tailW, top + 7);
      p.quadraticBezierTo(-4, top + 6, 2, bot);
      p.quadraticBezierTo(-4, top + 7, 2, top);
    }
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final body = _body(size);
    final tail = tailSide == TailSide.none ? null : _tail(size);
    if (tail != null) {
      canvas.save();
      // 左尾伸出 canvas 左缘，先放开裁剪
      canvas.clipRect(Rect.fromLTWH(-_tailW - 2, -2, size.width + _tailW * 2 + 4, size.height + 4));
    }
    if (shadow) {
      // 1px 极轻投影：dy 1 / blur 1 / 4%（只给气泡，不铺给卡片）
      canvas.drawPath(
        body.shift(const Offset(0, 1)),
        Paint()
          ..color = const Color(0xFF101828).withValues(alpha: 0.04)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
      );
    }
    canvas.drawPath(body, Paint()..color = fill);
    if (tail != null) canvas.drawPath(tail, Paint()..color = fill);
    if (stroke != null) {
      final pen = Paint()
        ..color = stroke!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawPath(body, pen);
      if (tail != null) canvas.drawPath(tail, pen);
    }
    if (tail != null) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) =>
      old.radius != radius || old.fill != fill || old.stroke != stroke || old.tailSide != tailSide || old.shadow != shadow;
}

// ---------------------------------------------------------------------------
// 输入栏
// ---------------------------------------------------------------------------

/// 输入栏：白底 + 顶 1px 发丝线；左「+」描边入口（相册）/ 输入框圆角 18 底 #EFF2F7 /
/// 右文字「发送」（有内容实色主色白字，空内容 #E3E8EF 灰字，点击校验空内容用 AppToast 提示）
class ChatV4Composer extends StatefulWidget {
  const ChatV4Composer({
    super.key,
    required this.onSend,
    required this.onPickImage,
    this.hint = '发消息…',
    this.enabled = true,
    this.sendingImage = false,
  });

  final ValueChanged<String> onSend;
  final VoidCallback onPickImage;
  final String hint;
  final bool enabled;
  final bool sendingImage;

  @override
  State<ChatV4Composer> createState() => _ChatV4ComposerState();
}

class _ChatV4ComposerState extends State<ChatV4Composer> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _input.text.trim();
    if (text.isEmpty) {
      AppToast.info(context, '先输入内容再发送');
      return;
    }
    _input.clear();
    setState(() {});
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    final active = _input.text.trim().isNotEmpty && widget.enabled;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.enabled && !widget.sendingImage ? widget.onPickImage : null,
                child: SizedBox(
                  width: 32,
                  height: 40,
                  child: widget.sendingImage
                      ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                      : Icon(AppIcon.plus, size: 21, color: c.textSecondary),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(color: c.inputBg, borderRadius: BorderRadius.circular(18)),
                  child: TextField(
                    controller: _input,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    style: TextStyle(fontSize: 13.5, color: c.textPrimary, height: 1.4),
                    decoration: InputDecoration(
                      hintText: widget.enabled ? widget.hint : '本次会话已结束',
                      hintStyle: TextStyle(fontSize: 13.5, color: c.textTertiary),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.enabled ? _submit : null,
                child: Container(
                  height: 34,
                  constraints: const BoxConstraints(minWidth: 64),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: active ? c.primary : c.sendDisabledBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '发送',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : c.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 页面骨架
// ---------------------------------------------------------------------------

/// 聊天页骨架：纯色页底 + 自绘页头 + 消息区（自绘列表）+ 输入栏。
/// **不使用 FishGlassPage / FishGlassBackdrop**（v4 明确去掉玻璃与光斑）。
/// 进页即渲染页头与输入栏；历史未到时消息区只显示轻量骨架，绝不整页转圈。
class ChatV4Page extends StatelessWidget {
  const ChatV4Page({
    super.key,
    required this.nickname,
    required this.statusText,
    required this.items,
    required this.onSend,
    required this.onPickImage,
    this.avatarMediaId,
    this.peerName = '',
    this.online = true,
    this.peerReadSeq = 0,
    this.csBar,
    this.quickAsks = const [],
    this.onQuickAsk,
    this.loadingHistory = false,
    this.error,
    this.onRetryLoad,
    this.onRetrySend,
    this.onLoadMore,
    this.onImageTap,
    this.composerEnabled = true,
    this.sendingImage = false,
    this.onMore,
  });

  final String nickname;
  final String statusText;
  final String? avatarMediaId;
  final String peerName;
  final bool online;

  /// 对方已读位点（conversationInfo.peerReadSeq + WS msg:read 实时推进）→ 我方消息单勾/双勾
  final int peerReadSeq;

  final List<ChatV4Item> items;
  final ValueChanged<String> onSend;
  final VoidCallback onPickImage;
  final Widget? csBar;
  final List<String> quickAsks;
  final ValueChanged<String>? onQuickAsk;
  final bool loadingHistory;
  final String? error;
  final VoidCallback? onRetryLoad;
  final ValueChanged<ChatV4Item>? onRetrySend;
  final VoidCallback? onLoadMore;
  final ValueChanged<String>? onImageTap;
  final bool composerEnabled;
  final bool sendingImage;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = _C(Theme.of(context).brightness == Brightness.dark);
    final composer = ChatV4Composer(
      onSend: onSend,
      onPickImage: onPickImage,
      enabled: composerEnabled,
      sendingImage: sendingImage,
    );
    return Scaffold(
      backgroundColor: c.page,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: ChatV4Header(
              nickname: nickname,
              statusText: statusText,
              avatarMediaId: avatarMediaId,
              online: online,
              onMore: onMore,
            ),
          ),
          ?csBar,
          if (quickAsks.isNotEmpty) ChatV4QuickAsks(items: quickAsks, onTap: onQuickAsk ?? (_) {}),
          Expanded(
            child: error != null
                ? Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(error!, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                              const SizedBox(height: 14),
                              FilledButton(onPressed: onRetryLoad, child: const Text('重试')),
                            ],
                          ),
                        ),
                      ),
                      composer,
                    ],
                  )
                : _MessageList(
                    items: items,
                    peer: ChatV4Peer(nickname: nickname, avatarMediaId: avatarMediaId, senderName: peerName),
                    peerReadSeq: peerReadSeq,
                    showSkeleton: loadingHistory,
                    onLoadMore: onLoadMore,
                    onRetry: onRetrySend,
                    onImageTap: onImageTap,
                    composer: composer,
                  ),
          ),
        ],
      ),
    );
  }
}
