import 'dart:async';
import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' show
    ChatOperation,
    ImageMessage,
    InMemoryChatController,
    Message,
    MessageStatus,
    TextMessage;
import 'package:image_picker/image_picker.dart';

import '../widgets/chat_v4.dart';

/// 聊天详情（CS 会话 / 好友会话 / 老板直聊通用，docs/07）
///
/// **2026-10-04 v4 重写渲染骨架**（site/design/chat-ui-v4.html）：消息行、页头、页底、输入栏
/// 全部自绘（`widgets/chat_v4.dart`），不再使用 flutter_chat_ui 的默认行渲染，也**移除了
/// FishGlassPage 玻璃页壳与光斑背景**（设计稿要求纯色页底）。
///
/// 业务逻辑一行未改，仍然保留：
/// - 消息加载与分页（首屏 limit=100 / 顶部触底 beforeSeq=oldest 倒序补拉）
/// - 发送（`_sendText` / `_pickAndSendImage`：WS 主通道 + HTTP 兜底 + clientMsgId 幂等）
/// - ACK 占位替换、撤回（msg:recalled）、客服结束、WS 实时刷新、已读标记、断线重连增量同步
/// - `_nicknames` 发送者昵称解析
///
/// `flutter_chat_core` 的 `InMemoryChatController` 继续托管消息状态（去重/顺序/更新），
/// 页面监听其 `operationsStream` 把状态镜像成渲染项列表 —— 列表渲染完全由我们掌控，
/// 而发送/ACK/撤回/分页的既有写路径保持不变。
class ChatDetailPage extends StatefulWidget {
  const ChatDetailPage({
    super.key,
    required this.conversationId,
    required this.title,
    this.peerAvatarMediaId,
    this.sendPath, // 发送兜底路径：/user/conversations/{id}/messages（boss）或 /worker/cs/conversations/{id}/messages（worker）
    this.csConversation = false, // 客服会话：支持"本次咨询已完成"（需求 #7）
    this.workerDirect = false, // 老板直聊（一对一，群组功能已下掉）
    this.peerNickname, // 进页直出：会话列表已有的对端昵称
    this.peerLastMessage, // 进页直出：会话列表已有的最后一条消息文本
    this.peerLastAt, // 进页直出：最后一条消息时间
    this.peerLastIsImage = false, // 最后一条是图片
    this.peerLastRecalled = false, // 最后一条已撤回
    this.peerIsMine = false, // 最后一条是否我方发出（决定占位气泡朝向）
    this.api, // 测试注入（不传则用默认 ApiClient）
  });

  final String conversationId;
  final String title;
  final String? peerAvatarMediaId;
  final String? sendPath;
  final bool csConversation;
  final bool workerDirect;
  final String? peerNickname;
  final String? peerLastMessage;
  final DateTime? peerLastAt;
  final bool peerLastIsImage;
  final bool peerLastRecalled;
  final bool peerIsMine;
  final ApiClient? api;

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;

  /// 消息状态仍由 flutter_chat_core 的控制器托管（去重/顺序/更新/ACK 替换全自动）
  final InMemoryChatController _controller = InMemoryChatController();

  /// 渲染镜像：controller.operationsStream → _items（自绘列表的唯一数据源）
  List<ChatV4Item> _items = const [];
  StreamSubscription<ChatOperation>? _opsSub;

  /// 本地图片字节（发送中立即显示本地预览，上传完成后切换为受保护网络图）
  final Map<String, Uint8List> _imageBytesByClientId = {};

  /// 待确认消息（ACK 到达时用服务端 msgId/seq 替换本地占位；保留完整内容）
  final Map<String, ChatMessageModel> _pendingByClientId = {};

  /// 发送者昵称表（消息行昵称解析用）
  final Map<String, String> _nicknames = {};

  final List<void Function()> _offEvents = [];
  bool _loading = true;
  String? _error;
  int _lastSeq = 0;
  int _oldestSeq = 0;
  bool _sendingImage = false;
  bool _closed = false; // 会话已结束（需求 #7）
  bool _closing = false;
  bool _loadingMore = false;

  String get _sendPath => widget.sendPath ?? '/worker/cs/conversations/${widget.conversationId}/messages';
  String get _historyPath => '/worker/cs/conversations/${widget.conversationId}/messages';
  String get _infoPath => '/worker/cs/conversations/${widget.conversationId}/info';

  String get _meId => AuthStore.instance.me?.id ?? 'me';

  /// 对方已读位点（服务端 conversationInfo.peerReadSeq + WS msg:read 实时推进）
  /// → 我方消息单勾（已送达）/ 双勾（对方已读）
  int _peerReadSeq = 0;

  /// 客服工号（后端真实字段：该会话 active 指派客服的 worker.workerNo；无指派为空串 → 显示「人工客服」）
  String _csStaffNo = '';

  /// 对端显示名：优先构造参数（会话列表已拿到），否则退回会话标题
  String get _peerName {
    final nick = widget.peerNickname?.trim() ?? '';
    if (nick.isNotEmpty) return nick;
    if (widget.csConversation) return '下单用户';
    if (widget.workerDirect) return '下单老板';
    final title = widget.title.trim();
    return title.isEmpty ? '好友' : title;
  }

  @override
  void initState() {
    super.initState();
    // 进页直出：先用会话列表带过来的最后一条消息占位（无则不占位，只显示轻骨架）
    final seed = widget.peerLastMessage;
    if (seed != null && seed.trim().isNotEmpty) {
      _items = [
        ChatV4Item(
          id: 'seed',
          text: seed,
          isMine: widget.peerIsMine,
          senderId: widget.peerIsMine ? _meId : 'peer',
          at: widget.peerLastAt ?? DateTime.now(),
          isImage: widget.peerLastIsImage,
          recalled: widget.peerLastRecalled,
        ),
      ];
    }
    _opsSub = _controller.operationsStream.listen(_onOperation);
    _init();
  }

  /// 控制器状态变化 → 渲染镜像（只做映射，不改业务）
  void _onOperation(ChatOperation _) {
    if (!mounted) return;
    setState(() => _items = _controller.messages.map(_toItem).toList());
  }

  Future<void> _init() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      setState(() {
        _error = '未登录';
        _loading = false;
      });
      return;
    }
    // 页头 / 输入栏已经在首帧渲染，这里只填消息区（失败也只是消息区错误态 + 重试）
    try {
      final hist = await _api.request('GET', _historyPath, token: token, queryParameters: {'limit': 100});
      final list = ((hist['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => ChatMessageModel.fromJson(e as Map<String, dynamic>))
          .toList();
      await _controller.setMessages(list.map(_toCore).toList());
      _lastSeq = list.isEmpty ? 0 : list.last.seq;
      _oldestSeq = list.isEmpty ? 0 : list.first.seq;
      if (mounted) setState(() => _loading = false);
      // 会话状态（需求 #7：已结束会话只读+提示）+ 对端已读位点 + 客服工号（D 项：真实字段）
      try {
        final info = await _api.request('GET', _infoPath, token: token);
        final data = info['data'] as Map<String, dynamic>?;
        final closed = '${data?['status'] ?? 'open'}' == 'closed';
        final peerReadSeq = (data?['peerReadSeq'] as num?)?.toInt() ?? 0;
        final staffNo = '${data?['staffNo'] ?? ''}';
        final advanced = peerReadSeq > _peerReadSeq;
        if (mounted) {
          setState(() {
            _closed = closed;
            _csStaffNo = staffNo;
            if (advanced) {
              _peerReadSeq = peerReadSeq;
              // 位点在映射时固化进 ChatV4Item.readByPeer → 必须重算一次，否则双勾要等下次消息才出现
              _items = _controller.messages.map(_toItem).toList();
            }
          });
        }
      } on ApiException catch (e) {
        // 状态获取失败不阻断聊天；但会话**确实不存在**（订单完成结算后被物理删除）→ 只读
        if (e.message.contains('会话不存在') && mounted) setState(() => _closed = true);
      }
      _setupRealtime(token);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
          if (e.message.contains('会话不存在')) _closed = true;
        });
      }
    }
  }

  void _setupRealtime(String token) {
    _realtime.connect(token: token);
    _offEvents.add(_realtime.on('msg:new', _onMsgNew));
    _offEvents.add(_realtime.on('msg:ack', _onAck));
    _offEvents.add(_realtime.on('msg:recalled', _onRecalled));
    _offEvents.add(_realtime.on('sync:result', _onSyncResult));
    // 已读回执（负责人 2026-10-04）：对端已读到哪一条 → 我方消息单勾/双勾
    _offEvents.add(_realtime.on('msg:read', _onPeerRead));
    _offEvents.add(_realtime.on('chat:closed', _onClosed));
    // 订单完成 → 该直聊会话被结束并删除（负责人 2026-10-04）：提示并返回会话列表，避免留在死会话里
    _offEvents.add(_realtime.on('conv:removed', _onRemoved));
    // 发送被拒/撤回失败等错误：即时反馈
    _offEvents.add(_realtime.on('msg:error', _onMsgError));
    _offEvents.add(_realtime.on('conv:join:error', _onJoinError));
    // 断线重连后：重新加入房间 + 增量补拉（需求 #2：重连不丢消息、无需手动刷新）
    _offEvents.add(_realtime.on('connect', (_) {
      Future<void>.delayed(const Duration(milliseconds: 300), _resync);
    }));
    Future<void>.delayed(const Duration(milliseconds: 500), _resync);
  }

  /// 加入房间 + 增量同步 + 已读（连接建立与每次重连都执行）
  void _resync() {
    _realtime.emit('conv:join', {'conversationId': widget.conversationId});
    _realtime.emit('sync', {'conversationId': widget.conversationId, 'lastSeq': _lastSeq});
    if (!_closed) _realtime.emit('msg:read', {'conversationId': widget.conversationId});
  }

  // ---------- WS 事件（协议见 docs/07；去重铁律：msgId 唯一） ----------

  void _onClosed(dynamic data) {
    if (data is! Map) return;
    if ('${data['conversationId'] ?? ''}' != widget.conversationId) return;
    setState(() => _closed = true);
  }

  /// 会话被删除（老板确认订单完成结算）→ 关闭输入 + 提示 + 返回列表
  void _onRemoved(dynamic data) {
    if (data is! Map) return;
    if ('${data['conversationId'] ?? ''}' != widget.conversationId) return;
    if (!mounted) return;
    setState(() => _closed = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('订单已结束，会话已关闭')));
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).maybePop();
  }

  void _onMsgError(dynamic data) {
    if (data is! Map) return;
    final clientMsgId = '${data['clientMsgId'] ?? ''}';
    final message = '${data['message'] ?? '发送失败'}';
    if (clientMsgId.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    _pendingByClientId.remove(clientMsgId);
    _imageBytesByClientId.remove(clientMsgId);
    final old = _findByClientId(clientMsgId);
    if (old != null) _controller.updateMessage(old, _copyStatus(old, MessageStatus.error));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 按类型复制消息并改状态（撤回/失败/确认共用）
  Message _copyStatus(Message m, MessageStatus status) => switch (m) {
        TextMessage t => t.copyWith(status: status),
        ImageMessage i => i.copyWith(status: status),
        final other => other,
      };

  void _onJoinError(dynamic data) {
    if (data is! Map) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法进入会话（可能已结束或无权限）')));
    }
  }

  Message? _findByClientId(String clientMsgId) {
    for (final m in _controller.messages) {
      if (m.metadata?['clientMsgId'] == clientMsgId) return m;
    }
    return null;
  }

  Message? _findByMsgId(String msgId) {
    for (final m in _controller.messages) {
      if (m.id == msgId) return m;
    }
    return null;
  }

  void _onMsgNew(dynamic data) {
    if (data is! Map) return;
    if ('${data['conversationId'] ?? ''}' != widget.conversationId) return;
    final m = ChatMessageModel.fromJson(Map<String, dynamic>.from(data));
    // 去重：先按 msgId（服务端唯一）再按 seq —— 防 ACK/HTTP 双通道竞态与重复推送
    if (_findByMsgId(m.msgId) != null) return;
    if (m.seq <= _lastSeq) return;
    _lastSeq = m.seq;
    _controller.insertMessage(_toCore(m));
    _realtime.emit('msg:read', {'conversationId': widget.conversationId});
  }

  void _onAck(dynamic data) {
    if (data is! Map) return;
    final clientMsgId = '${data['clientMsgId'] ?? ''}';
    final msgId = '${data['msgId'] ?? ''}';
    final seq = (data['seq'] as num?)?.toInt() ?? 0;
    final pending = _pendingByClientId.remove(clientMsgId);
    if (pending == null || msgId.isEmpty || seq <= 0) return;
    _lastSeq = _lastSeq < seq ? seq : _lastSeq;
    _imageBytesByClientId.remove(clientMsgId);
    final old = _findByClientId(clientMsgId);
    if (old == null) return;
    // 用服务端 msgId/seq 替换本地占位（保留完整内容，修复「撤回失效」与去重锚点）
    final confirmed = pending.copyWith(msgId: msgId, seq: seq, pending: false, clearClientMsgId: true);
    _controller.updateMessage(old, _toCore(confirmed));
  }

  void _onRecalled(dynamic data) {
    if (data is! Map) return;
    final msgId = '${data['msgId'] ?? ''}';
    final old = _findByMsgId(msgId);
    if (old == null) return;
    final meta = Map<String, dynamic>.from(old.metadata ?? {})..['recalled'] = true;
    final updated = switch (old) {
      TextMessage m => m.copyWith(metadata: meta, text: ''),
      ImageMessage m => m.copyWith(metadata: meta),
      final m => m,
    };
    _controller.updateMessage(old, updated);
  }

  void _onSyncResult(dynamic data) {
    if (data is! Map) return;
    final list = data['list'] as List<dynamic>? ?? [];
    var inserted = false;
    for (final e in list) {
      final m = ChatMessageModel.fromJson(Map<String, dynamic>.from(e as Map));
      if (_findByMsgId(m.msgId) != null) continue;
      if (m.seq <= _lastSeq) continue;
      _lastSeq = m.seq;
      _controller.insertMessage(_toCore(m));
      inserted = true;
    }
    // 补拉到的新消息也要记入我的已读位点（否则对方永远只看到单勾）
    if (inserted) _realtime.emit('msg:read', {'conversationId': widget.conversationId});
  }

  /// 对端已读位点推送（服务端 markRead → msg:read；自己触发的回执按 readerUserId 过滤）
  void _onPeerRead(dynamic data) {
    if (data is! Map) return;
    if ('${data['conversationId'] ?? ''}' != widget.conversationId) return;
    if ('${data['readerUserId'] ?? ''}' == _meId) return;
    final seq = (data['lastSeq'] as num?)?.toInt() ?? 0;
    if (seq <= _peerReadSeq) return;
    if (!mounted) return;
    setState(() {
      _peerReadSeq = seq;
      // 位点在映射时固化进 ChatV4Item.readByPeer → 必须重算渲染项，否则双勾不实时
      _items = _controller.messages.map(_toItem).toList();
    });
  }

  // ---------- 发送（状态托管在 controller；WS 主通道 + HTTP 兜底） ----------

  Future<void> _sendText(String text) async {
    final content = text.trim();
    if (content.isEmpty || _closed) return;
    final clientMsgId = generateIdempotencyKey();
    final me = AuthStore.instance.me;
    final local = ChatMessageModel(
      msgId: 'local-$clientMsgId',
      seq: 0,
      senderType: 'user',
      senderId: me?.id ?? 'me',
      msgType: 'text',
      content: content,
      recalled: false,
      createdAt: DateTime.now(),
      clientMsgId: clientMsgId,
      senderNickname: me?.nickname ?? '',
      pending: true,
    );
    _pendingByClientId[clientMsgId] = local;
    await _controller.insertMessage(_toCore(local));
    try {
      _realtime.emit('msg:send', {
        'conversationId': widget.conversationId,
        'msgType': 'text',
        'content': content,
        'clientMsgId': clientMsgId,
      });
      // HTTP 兜底：WS 断线时仍可送达（服务端 msgId/seq 幂等去重）
      await _api.request('POST', _sendPath, token: AuthStore.instance.accessToken, data: {
        'msgType': 'text',
        'content': content,
        'clientMsgId': clientMsgId,
      });
    } on ApiException {
      // WS 已发出时 HTTP 失败无影响；两者都失败由 msg:error 或兜底错误提示
    }
  }

  /// 发送失败重试（同一 clientMsgId 幂等重发，服务端不会产生重复消息）
  Future<void> _retrySend(ChatV4Item item) async {
    if (item.isImage) {
      AppToast.info(context, '图片请重新选择后发送');
      return;
    }
    await _sendText(item.text);
  }

  Future<void> _pickAndSendImage() async {
    if (_sendingImage || _closed) return;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final clientMsgId = generateIdempotencyKey();
      final me = AuthStore.instance.me;
      setState(() => _sendingImage = true);
      // 本地预览立即上屏（pending 状态，上传完成后替换为服务端消息）
      final local = ChatMessageModel(
        msgId: 'local-$clientMsgId',
        seq: 0,
        senderType: 'user',
        senderId: me?.id ?? 'me',
        msgType: 'image',
        content: '', // 本地预览走 _imageBytesByClientId
        recalled: false,
        createdAt: DateTime.now(),
        clientMsgId: clientMsgId,
        senderNickname: me?.nickname ?? '',
        pending: true,
      );
      _pendingByClientId[clientMsgId] = local;
      _imageBytesByClientId[clientMsgId] = bytes;
      await _controller.insertMessage(_toCore(local));
      // 上传 → 发送（真实上传后端，服务端校验）
      final token = AuthStore.instance.accessToken;
      if (token == null) return;
      final up = await uploadMedia(type: 'chat_image', bytes: bytes, filename: picked.name, token: token);
      _realtime.emit('msg:send', {
        'conversationId': widget.conversationId,
        'msgType': 'image',
        'content': up.id,
        'clientMsgId': clientMsgId,
      });
      await _api.request('POST', _sendPath, token: token, data: {
        'msgType': 'image',
        'content': up.id,
        'clientMsgId': clientMsgId,
      });
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sendingImage = false);
    }
  }

  /// 加载更早消息（倒序分页 docs/07 beforeSeq；由自绘列表顶部触底回调驱动）
  Future<void> _loadMoreHistory() async {
    if (_loadingMore || _oldestSeq <= 1) return;
    _loadingMore = true;
    try {
      final resp = await _api.request(
        'GET',
        _historyPath,
        token: AuthStore.instance.accessToken,
        queryParameters: {'beforeSeq': _oldestSeq, 'limit': 50},
      );
      final list = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => ChatMessageModel.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isNotEmpty) {
        _oldestSeq = list.first.seq;
        await _controller.insertAllMessages(list.map(_toCore).toList(), index: 0);
      }
    } on ApiException {
      // 静默：滚动再触发
    } finally {
      _loadingMore = false;
    }
  }

  // ---------- 完成咨询（需求 #7） ----------

  Future<void> _finishConsult() async {
    if (_closing) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本次咨询已完成？'),
        content: const Text('结束后将保留聊天记录；如再次需要客服，会开启新的会话。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认完成')),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _closing = true);
    try {
      await _api.request('POST', '/worker/cs/conversations/${widget.conversationId}/close', token: AuthStore.instance.accessToken, data: {});
      if (mounted) setState(() => _closed = true);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  // ---------- 映射：服务端消息 ↔ 控制器消息 ↔ 渲染项 ----------

  String _imageUrl(String mediaId) => AppConfig.resolveMediaUrl('/media/chat/$mediaId');

  Message _toCore(ChatMessageModel m) {
    final authorId = m.senderId.isNotEmpty ? m.senderId : 'me';
    if (m.senderNickname.isNotEmpty) _nicknames[authorId] = m.senderNickname;
    final status = m.failed
        ? MessageStatus.error
        : m.pending
            ? MessageStatus.sending
            : MessageStatus.sent;
    final meta = <String, dynamic>{
      'seq': m.seq,
      if (m.clientMsgId != null) 'clientMsgId': m.clientMsgId,
      if (m.recalled) 'recalled': true,
      if (m.senderNickname.isNotEmpty) 'senderName': m.senderNickname,
      // 系统消息（订单节点：已接单/已开始/已提交待确认/已完成结算）→ 居中中性灰 chip
      if (m.msgType == 'system') 'system': true,
    };
    if (m.msgType == 'image') {
      final bytes = m.clientMsgId == null ? null : _imageBytesByClientId[m.clientMsgId];
      return ImageMessage(
        id: m.msgId,
        authorId: authorId,
        createdAt: m.createdAt.toLocal(),
        metadata: meta,
        status: status,
        // 本地未上传完成 → 显示占位；否则走受保护网络图
        source: bytes != null ? '' : _imageUrl(m.content),
        size: 240,
      );
    }
    return TextMessage(
      id: m.msgId,
      authorId: authorId,
      createdAt: m.createdAt.toLocal(),
      metadata: meta,
      status: status,
      text: m.content,
    );
  }

  /// 控制器消息 → 渲染项（自绘列表的输入）
  ChatV4Item _toItem(Message m) {
    final meta = m.metadata ?? const <String, dynamic>{};
    final clientMsgId = meta['clientMsgId'] as String?;
    final isMine = m.authorId == _meId;
    final at = m.createdAt ?? DateTime.now();
    final seq = (meta['seq'] as num?)?.toInt() ?? 0;
    // 系统消息（msgType='system'）：居中中性灰 chip（chat_v4 既有 system 渲染路径）
    if (meta['system'] == true) {
      return ChatV4Item(
        id: m.id,
        text: m is TextMessage ? m.text : '',
        isMine: false,
        senderId: 'system',
        at: at,
        seq: seq,
        system: true,
      );
    }
    // 已读回执：对方位点 >= 本条 seq → 双勾（否则单勾）
    final readByPeer = seq > 0 && _peerReadSeq >= seq;
    return switch (m) {
      ImageMessage img => ChatV4Item(
          id: m.id,
          text: '',
          isMine: isMine,
          senderId: m.authorId,
          at: at,
          seq: seq,
          isImage: true,
          imageBytes: clientMsgId == null ? null : _imageBytesByClientId[clientMsgId],
          imageUrl: img.source.toString().isEmpty ? null : img.source.toString(),
          pending: m.status == MessageStatus.sending,
          failed: m.status == MessageStatus.error,
          recalled: meta['recalled'] == true,
          readByPeer: readByPeer,
        ),
      TextMessage t => ChatV4Item(
          id: m.id,
          text: t.text,
          isMine: isMine,
          senderId: m.authorId,
          at: at,
          seq: seq,
          pending: m.status == MessageStatus.sending,
          failed: m.status == MessageStatus.error,
          recalled: meta['recalled'] == true,
          readByPeer: readByPeer,
        ),
      _ => ChatV4Item(
          id: m.id,
          text: '暂不支持的消息类型',
          isMine: false,
          senderId: 'system',
          at: at,
          seq: seq,
          system: true,
        ),
    };
  }

  /// 对方在我方视角的显示名（消息行头像首字 / 昵称表兜底）
  String get _peerDisplayName {
    for (final item in _items.reversed) {
      if (item.senderId == _meId || item.system) continue;
      final nick = _nicknames[item.senderId];
      if (nick != null && nick.isNotEmpty) return nick;
      break;
    }
    return _peerName;
  }

  /// 页头状态文案（设计稿 v4：客服 / 老板直聊 / 好友三套）
  ///
  /// 负责人 2026-10-04 报障「单子完成了还显示进行中」：老板直聊此前**写死**「接单打护 · 进行中」，
  /// 与订单真实状态无关 —— 订单已 completed、会话已 closed/删除时仍显示「进行中」。
  /// 现在按会话真实状态给文案。
  String get _statusText {
    if (widget.csConversation) return _closed ? '本次咨询已结束' : '在线客服 · 平均 1 分钟回复';
    if (widget.workerDirect) return _closed ? '本次服务已结束' : '下单老板 · 一对一';
    return '在线';
  }

  /// 客服工号：**改用后端真实字段**（D 项，负责人 2026-10-04）
  /// —— 会话 active 指派客服的 `worker.workerNo`；无指派时后端返回空串，
  /// 客户端显示「人工客服」，不再按 conversationId 派生 "CS-xx" 编造编号。
  static const List<String> _quickAsks = ['怎么接单', '提现什么时候到账', '客户要求退款怎么办', '订单超时怎么处理'];

  Future<void> _openMoreMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.csConversation && !_closed)
              ListTile(
                leading: const Icon(AppIcon.check, size: 20),
                title: const Text('结束本次咨询', style: TextStyle(fontSize: 14.5)),
                onTap: () => Navigator.pop(ctx, 'finish'),
              ),
            const ListTile(
              leading: Icon(AppIcon.clock, size: 20),
              title: Text('聊天记录已自动保存', style: TextStyle(fontSize: 14.5)),
              onTap: null,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (action == 'finish') await _finishConsult();
  }

  Future<void> _previewImage(String url) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final off in _offEvents) {
      off();
    }
    _opsSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChatV4Page(
      nickname: _peerName,
      statusText: _statusText,
      avatarMediaId: widget.peerAvatarMediaId,
      peerName: _peerDisplayName,
      // 会话已结束（客服结束 / 订单完成删除直聊）→ 对端不再显示在线；老板直聊同理
      online: !(_closed && (widget.csConversation || widget.workerDirect)),
      items: _items,
      peerReadSeq: _peerReadSeq,
      onSend: _sendText,
      onPickImage: _pickAndSendImage,
      onMore: _openMoreMenu,
      loadingHistory: _loading,
      error: _error,
      onRetryLoad: _init,
      onRetrySend: _retrySend,
      onLoadMore: _loadMoreHistory,
      onImageTap: _previewImage,
      composerEnabled: !_closed,
      sendingImage: _sendingImage,
      csBar: widget.csConversation
          ? ChatV4CsBar(
              nickname: _peerName,
              avatarMediaId: widget.peerAvatarMediaId,
              staffNo: _csStaffNo,
              closed: _closed,
              onFinish: _closing ? null : _finishConsult,
            )
          : null,
      quickAsks: widget.csConversation && !_closed ? _quickAsks : const [],
      onQuickAsk: _sendText,
    );
  }
}
