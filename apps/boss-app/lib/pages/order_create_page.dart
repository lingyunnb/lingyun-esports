import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/division_platform_label.dart';
import '../widgets/order_form_fields.dart';
import 'product_list_page.dart';
import 'worker_profile_page.dart';

/// 确认订单（负责人 2026-10-04：**完全仿**参考 App 的下单页结构，用本项目青蓝主题重绘）
///
/// 结构（与参考一致）：
/// 1. 顶部商品卡：封面 + 标题 + 服务分部标签 + 价格 + 数量步进器（可换商品）
/// 2. **选择区服**（必填）：按钮组，选项来自管理端配置
/// 3. **动态表单字段**：标签/占位/必填/开关全部来自 `/public/order-form`（管理端可改）
/// 4. **选择护航员**（必填）：随机安排 / 指定护航员（指定时弹层选人，数据来自 `/public/players`）
/// 5. 商品费用：单价 ¥ × 数量
/// 6. 吸底：余额提示（余额不足 → 差额）+ 合计 ¥ + 提交订单
///
/// 客户端零硬编码：文案、字段、区服、护航员称呼全部服务端下发。
class OrderCreatePage extends StatefulWidget {
  const OrderCreatePage({super.key, this.api, this.product, this.divisionId});

  final ApiClient? api;

  /// 已选商品（来自商品列表）；为空则先引导去选商品
  final Map<String, dynamic>? product;
  final String? divisionId;

  @override
  State<OrderCreatePage> createState() => _OrderCreatePageState();
}

class _OrderCreatePageState extends State<OrderCreatePage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  Map<String, dynamic>? _product;
  List<_DivisionLite> _divisions = [];
  Map<String, dynamic> _form = const {};
  final Map<String, TextEditingController> _inputs = {};

  /// 动态字段的聚焦节点（`docs/31` 第四节第 5 条：`TextField` 挂 `focusNode` → 行首 2dp 聚焦竖条）
  ///
  /// 生命周期与 `_inputs` 同规则：**页面建、页面放**（`_fieldFocus` 惰性建、`dispose` 统一释放）；
  /// 行组件只加监听器、不释放别人的对象。
  final Map<String, FocusNode> _fieldFocus = {};
  final Set<String> _missing = {};
  String? _zone;
  String _workerMode = 'random';
  _PlayerLite? _designated;
  int _qty = 1;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  /// 每周限购配额（服务端 `/user/orders/weekly-quota` 原样下发：limitText / quotaText）
  ///
  /// 客户端**不硬编码任何限购规则**：查不到（未登录/网络失败/商品不限购）就什么都不显示，
  /// 真正的拦截仍在服务端下单事务内（这里只是提前告知）。
  Map<String, dynamic>? _quota;

  /// 余额（`GET /user/wallet`，**只为"够不够"的提前告知**，失败静默为 null = 不显示）
  ///
  /// 只读展示：**不参与任何判定**，扣款与"余额不足"的最终裁决永远在服务端
  /// （客户端数据不可信；这里多一次提示只是让用户少跑一次必然失败的提交）。
  double? _balance;

  /// 「记住我的游戏 ID」：服务端在**订单创建成功时自动落库**的我的游戏账号
  /// （`GET /user/game-accounts`；客户端**不需要**、也没有写接口）。
  ///
  /// 只为**预填**：拿不到就保持空，不报错、不加必填、不挡下单（见 [_prefillGameAccount]）。
  List<_GameAccount> _gameAccounts = const [];

  /// 已经问过服务端一次（失败也算问过 —— 一次失败不该让每次重建都再打一次请求）
  bool _gameAccountsLoaded = false;

  /// 已经按哪个 gameId 做过回填：同一个游戏只回填一次，
  /// **用户把它清空后不会又被填回来**（"可清空"就靠这条守住）。
  String _prefilledForGameId = '';

  @override
  void initState() {
    super.initState();
    _product = widget.product;
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in _inputs.values) {
      c.dispose();
    }
    for (final n in _fieldFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.request('GET', '/public/order-form'),
        _api.request('GET', '/divisions'),
      ]);
      if (!mounted) return;
      final form = (results[0]['data'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      final divs = ((results[1]['data'] as List?) ?? const []).map((e) => _DivisionLite.fromJson(e as Map)).toList();
      for (final f in _fields(form)) {
        _inputs.putIfAbsent(f.key, () => TextEditingController());
      }
      setState(() {
        _form = form;
        _divisions = divs;
        final zones = _zoneOptions(form);
        _zone ??= zones.isNotEmpty ? zones.first.value : null;
        _loading = false;
      });
      unawaited(_loadQuota()); // 限购提示（服务端权威文案），失败静默不影响下单
      unawaited(_loadBalance()); // 余额提示（服务端权威数据），失败静默不影响下单
      // 「记住我的游戏 ID」回填（负责人 2026-10-15）：失败/无记录一律静默保持现状
      unawaited(_loadGameAccounts());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 拉取该商品的每周限购配额（服务端权威：限购数/已下单数/剩余/中文文案）
  ///
  /// 未登录或接口不可用时**直接不显示**这一行 —— 客户端不自己拼「每周限购 N 单」这类规则文案，
  /// 避免服务端改规则（如改成 3 单/自然周）后客户端还在说旧话术。
  Future<void> _loadQuota() async {
    final productId = '${_product?['id'] ?? ''}';
    if (productId.isEmpty) return;
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request(
        'GET',
        '/user/orders/weekly-quota',
        token: token,
        queryParameters: {'productId': productId},
      );
      if (!mounted) return;
      setState(() => _quota = (resp['data'] as Map?)?.cast<String, dynamic>());
    } catch (_) {
      if (!mounted) return;
      setState(() => _quota = null);
    }
  }

  List<({String label, String value})> _zoneOptions(Map form) => ((form['zoneOptions'] as List?) ?? const [])
      .map((e) => (label: '${(e as Map)['label']}', value: '${e['value']}'))
      .toList();

  List<OrderFormFieldDef> _fields(Map form) =>
      ((form['fields'] as List?) ?? const [])
          .where((e) => (e as Map)['enabled'] != false)
          .map((e) => (
                key: '${(e as Map)['key']}',
                label: '${e['label'] ?? ''}',
                placeholder: '${e['placeholder'] ?? ''}',
                type: '${e['type'] ?? 'text'}',
                required: e['required'] == true,
                maxLength: (e['maxLength'] as num?)?.toInt() ?? 120,
              ))
          .toList();

  /// 取（必要时新建）某字段的聚焦节点 —— 行组件按 `f.key` 要
  FocusNode _fieldFocusNode(String key) => _fieldFocus.putIfAbsent(key, FocusNode.new);

  /// 报错行被用户填上内容 → 把该项移出 `_missing`（**只影响渲染层**：
  /// `_missing` 的产生与消费方式一个字没改，仍是 `_submit` 里那一处）
  void _clearMissing(String key) {
    if (!mounted || !_missing.contains(key)) return;
    setState(() => _missing.remove(key));
  }

  /// 区服被选中 → 同样把 `zone` 移出 `_missing`（仅渲染层，不改校验）
  void _selectZone(String value) {
    setState(() {
      _zone = value;
      _missing.remove('zone');
    });
  }

  String _t(String key, String fallback) {
    final v = _form[key];
    return (v is String && v.isNotEmpty) ? v : fallback;
  }

  double get _price => parsePoints(_product?['price']);
  double get _total => _price * _qty;

  /// 拉取余额（`GET /user/wallet`）——**仅用于"余额不足"提示**，失败静默
  ///
  /// 拿不到 `balance` 字段（而不是拿到 0）时保持 `_balance == null`：宁可不说，
  /// 也不能因为一个缺字段把"余额 ¥0.00 / 还差 ¥X"这种错误信息摆在用户面前。
  Future<void> _loadBalance() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request('GET', '/user/wallet', token: token);
      final raw = (resp['data'] as Map?)?['balance'];
      if (raw == null || !mounted) return;
      setState(() => _balance = parsePoints(raw));
    } catch (_) {
      // 静默：余额提示不是下单链路的必要环节，服务端仍是唯一权威
    }
  }

  /// 余额不足的差额（null = 够用 / 余额未知）—— 文案「余额不足，还差 ¥1.20」
  double? get _shortfall {
    final b = _balance;
    if (b == null || _total <= b) return null;
    return _total - b;
  }

  // -------------------------------------------------------------------------
  // 记住我的游戏 ID（回填）
  // -------------------------------------------------------------------------

  /// 拉「记住的游戏账号」并尝试回填
  ///
  /// 口径（负责人 2026-10-15）：
  /// - 保存由**服务端在订单创建成功时自动完成**，客户端**只有读**，没有写接口；
  /// - 只回填、不改校验：必填仍是"接口说必填就必填"（`_submit` 里那一处一个字没动），
  ///   预填只是把**用户自己以前填过的值**放回输入框；
  /// - 拿不到 / 没记录 / 未登录 → **保持现状（空）**，不报错、不弹提示、不挡下单。
  Future<void> _loadGameAccounts() async {
    if (_gameAccountsLoaded) return;
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request('GET', '/user/game-accounts', token: token);
      final list = resp['data'];
      if (!mounted) return;
      setState(() {
        _gameAccountsLoaded = true;
        // 形状严格：只认数组里的对象；服务端给别的东西（老接口/网关页）→ 当"没有记录"
        _gameAccounts = list is List
            ? list.whereType<Map>().map((e) => _GameAccount.fromJson(e)).where((a) => a.gamePlayerId.isNotEmpty).toList()
            : const [];
      });
      _prefillGameAccount();
    } catch (_) {
      // 静默：这是"少打几个字"的体验增强，失败不影响任何下单能力
      _gameAccountsLoaded = true;
    }
  }

  /// 当前商品所属游戏 id（先按分部对照，其次商品自带 `gameId`；都没有 → 空）
  String get _currentGameId {
    final p = _product;
    if (p == null) return '';
    final d = _divisionOf(p);
    if (d != null && d.gameId.isNotEmpty) return d.gameId;
    return '${p['gameId'] ?? ''}'.trim();
  }

  /// 当前商品所属游戏名（`gameId` 对不上时退一步按它匹配）
  String get _currentGameName {
    final p = _product;
    if (p == null) return '';
    final d = _divisionOf(p);
    if (d != null && d.gameName.isNotEmpty) return d.gameName;
    return '${p['gameName'] ?? ''}'.trim();
  }

  /// 按「当前商品所属游戏」匹配记录 → 预填 `gamePlayerId`（命中区服选项时连 `gameZone` 一起填）
  ///
  /// 匹配口径：① `gameId` 精确相等（首选，多游戏下最准）；② 没拿到 gameId 时按**游戏名**相等兜底；
  /// ③ 同一游戏有多条 → 取 `updatedAt` 最近的一条；都匹配不到 → 什么都不做。
  void _prefillGameAccount() {
    if (!mounted) return;
    final gameId = _currentGameId;
    if (gameId.isEmpty) return;
    // 同一游戏只回填一次：用户改了/清空了都不能被覆盖回来
    if (_prefilledForGameId == gameId) return;
    final controller = _inputs['gamePlayerId'];
    // 字段没配置（后台把该字段关掉）或用户已经填过 → 不碰
    if (controller == null || controller.text.trim().isNotEmpty) return;
    final rec = _matchGameAccount(gameId);
    if (rec == null) return;
    setState(() {
      _prefilledForGameId = gameId;
      controller.text = rec.gamePlayerId;
      // 区服只在"记住的值确实在当前选项里"时才预填（选项由后台配置，不猜、不造值）
      if (rec.gameZone.isNotEmpty && _zoneOptions(_form).any((o) => o.value == rec.gameZone)) {
        _zone = rec.gameZone;
      }
    });
  }

  _GameAccount? _matchGameAccount(String gameId) {
    final byId = _gameAccounts.where((a) => a.gameId.isNotEmpty && a.gameId == gameId).toList();
    final name = _currentGameName;
    final hits = byId.isNotEmpty
        ? byId
        : _gameAccounts.where((a) => a.gameId.isEmpty && name.isNotEmpty && a.gameName == name).toList();
    if (hits.isEmpty) return null;
    hits.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return hits.first;
  }

  Future<void> _pickProduct() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ProductListPage(api: widget.api, initialDivisionId: widget.divisionId)),
    );
    if (picked != null && mounted) {
      setState(() => _product = picked);
      await _loadQuota(); // 换了商品 → 额度也要跟着换（否则会显示上一个商品的剩余数）
      // 换了商品 → 可能换了游戏：新游戏若还没回填过，也给填上（已有内容一律不动）
      _prefillGameAccount();
    }
  }

  Future<void> _submit() async {
    if (_product == null) {
      _snack('请先选择商品');
      return;
    }
    final miss = <String>{};
    if (_zone == null) miss.add('zone');
    for (final f in _fields(_form)) {
      if (f.required && (_inputs[f.key]?.text.trim().isEmpty ?? true)) miss.add(f.key);
    }
    if (miss.isNotEmpty) {
      setState(() => _missing
        ..clear()
        ..addAll(miss));
      _snack('请填写标 * 的必填项');
      return;
    }
    setState(() {
      _missing.clear();
      _submitting = true;
    });
    try {
      final token = AuthStore.instance.accessToken;
      if (token == null) throw const ApiException(401, '请先登录', '');
      final values = <String, String>{for (final f in _fields(_form)) f.key: _inputs[f.key]?.text.trim() ?? ''};
      final resp = await _api.request('POST', '/user/orders', token: token, data: {
        'productId': '${_product!['id']}',
        'quantity': _qty,
        'remark': values['remark'] ?? '',
        'gameZone': _zone,
        'gamePlayerId': values['gamePlayerId'] ?? '',
        'contactPhone': values['contactPhone'] ?? '',
        'workerMode': _workerMode,
        if (_workerMode == 'designated' && _designated != null) 'designatedWorkerId': _designated!.workerId,
        'idempotencyKey': generateIdempotencyKey(),
      });
      if (!mounted) return;
      final order = (resp['data'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      AppToast.success(context, '下单成功，正在为你安排护航员');
      Navigator.of(context).pop(order);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _snack(e.message);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.info(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(58),
        child: Container(
          color: T.bgCardSolid,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 58,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: AppIcon.of(AppIcon.arrowLeft, size: 20, color: T.textPrimary),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text('确认订单',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: T.textPrimary)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.error)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ]),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
                  children: [
                    if (_product != null) _productCard(),
                    if (_product == null)
                      AppCard(
                        onTap: _pickProduct,
                        radius: AppDecoRadius.card,
                        border: Border.all(color: AppColors.strokeSoft),
                        child: Row(
                          children: [
                            AppIcon.of(AppIcon.orders, size: 18, color: T.primary),
                            const SizedBox(width: 8),
                            Text('选择服务商品', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                            const Spacer(),
                            AppIcon.of(AppIcon.chevronRight, size: 16, color: T.textTertiary),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    // 服务/商品区上方的平台标识（负责人 2026-10-04：三角洲要标明手游还是端游）
                    // 分部对照不到时不显示（不猜、不写死）
                    if (_platformDivision != null) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DivisionPlatformLabel(
                          name: _platformDivision!.name,
                          shortName: _platformDivision!.shortName,
                          platformLabel: _platformDivision!.platformLabel,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _card(
                      title: _t('zoneLabel', '选择区服'),
                      required: true,
                      invalid: _missing.contains('zone'),
                      child: _zoneOptions(_form).isEmpty
                          ? Text('该商品暂未开放区服选择，请联系客服', style: TextStyle(fontSize: 12, color: T.textTertiary))
                          : Row(
                              children: [
                                for (var i = 0; i < _zoneOptions(_form).length; i++) ...[
                                  if (i > 0) const SizedBox(width: 10),
                                  Expanded(
                                    child: _optionButton(_zoneOptions(_form)[i].label,
                                        _zone == _zoneOptions(_form)[i].value, () => _selectZone(_zoneOptions(_form)[i].value)),
                                  ),
                                ],
                              ],
                            ),
                    ),
                    // 「填写信息」字段卡（`docs/31` 方向 A：一张卡多行 + 发丝线分行）
                    //
                    // 字段顺序 / 数量 / key / controller 映射一个不动：`_fields(_form)` 怎么算出来的、
                    // 顺序是什么，行顺序就一模一样（接口下发顺序即展示顺序）。
                    const SizedBox(height: 20),
                    OrderFormFieldsCard(
                      fields: _fields(_form),
                      controllers: _inputs,
                      focusNodeOf: _fieldFocusNode,
                      isInvalid: _missing.contains,
                      onCleared: _clearMissing,
                    ),
                    const SizedBox(height: 20),
                    _card(
                      title: _t('workerLabel', '选择护航员'),
                      required: true,
                      child: Row(
                        children: [
                          Expanded(
                            child: _optionButton(_t('workerRandomLabel', '随机安排'), _workerMode == 'random',
                                () => setState(() => _workerMode = 'random')),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _optionButton(
                              _designated == null
                                  ? _t('workerDesignatedLabel', '指定护航员')
                                  : '已指定：${_designated!.nickname}',
                              _workerMode == 'designated' && _designated != null,
                              _pickWorker,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // 商品费用行（方案 G 卡片：白底 + 1px 描边 + 圆角 14）
                    AppCard(
                      radius: AppDecoRadius.card,
                      border: Border.all(color: AppColors.strokeSoft),
                      child: Row(
                        children: [
                          Text(_t('feeTitle', '商品费用'),
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                          const Spacer(),
                          Text('${_t('feeUnitLabel', '单价')} ${fmtMoney(_price)} × $_qty 件',
                              style: TextStyle(fontSize: 12, color: T.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
      // ④ 底部：余额提示 → **结算行（合计 + 大字金）** → 提交按钮
      //
      // 方案 G 定案：整条底栏 = 白底 + 顶部 1px 描边 `#E8ECF2`；
      // 主按钮走**品牌蓝实色**（`gradient: false`，`#2563EB` 是全站唯一强调色，
      // 渐变只允许出现在极小面积/品牌位，铺在提交按钮上就是"大块渐变"）。
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          border: Border(top: BorderSide(color: AppColors.strokeSoft)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 余额提示（服务端数据，失败静默不显示）：够用 = 灰字余额；不够 = 红字差额
                //
                // 口径（负责人 2026-10-09）：金额一律 ¥ + 两位小数；"还差"用**同一个** fmtMoney，
                // 页面不自己拼钱。这里只是提前告知，提交与否仍由服务端裁决（不置灰按钮）。
                if (_balance != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _shortfall == null
                        ? Text('余额 ${fmtMoney(_balance!)}',
                            style: TextStyle(fontSize: 12, color: T.textSecondary))
                        : Row(
                            children: [
                              const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '余额不足，还差 ${fmtMoney(_shortfall!)}',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.error),
                                ),
                              ),
                            ],
                          ),
                  ),
                // 结算行：`合计：` + 金额（大字金 19px/w700 → 属"大字金额"档，走 gold）
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('${_t('totalLabel', '合计')}：',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: T.textPrimary)),
                          AppPrice(value: fmtMoney(_total), size: 19, color: T.gold),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 132,
                      height: 48,
                      child: AppButton(
                        label: _submitting ? '提交中…' : _t('submitText', '提交订单'),
                        gradient: false,
                        height: 48,
                        onPressed: _submitting ? null : _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 商品摘要卡（方案 G：白底 + 1px 描边 `#E8ECF2` + 圆角 14）
  ///
  /// 徽标与每周限购提示（负责人 2026-10-05）都在这里，与商品列表页**同一份服务端数据**：
  /// 徽标文案 = 商品上的 `badgeText`（列表带过来或详情返回），限购文案 = `/user/orders/weekly-quota`。
  ///
  /// 描边仍保留既有的「置顶推荐 = 1px 琥珀金」信号（[productCardBorder]）——那是**徽标之外**
  /// 唯一允许的金色描边，只在有 badgeText 时出现；其余商品一律方案 G 的中性描边。
  Widget _productCard() {
    final p = _product!;
    final url = _mediaUrl(p);
    final div = _divisionOf(p);
    final badge = p['badgeText'] as String?;
    return AppCard(
      padding: const EdgeInsets.all(12),
      radius: AppDecoRadius.card,
      border: ProductBadge.shows(badge)
          ? productCardBorder(badge)
          : Border.all(color: AppColors.strokeSoft),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 74,
              height: 74,
              child: url == null
                  // 无管理端封面 → 该商品所属分部的**官方游戏图**（端游仍在图片底部叠「端」角标）；
                  // 分部没挂图时回退自绘游戏图标
                  ? GameIconTile(
                      gameKey: div?.gameKey ??
                          ('${p['gameKey'] ?? ''} ${p['divisionId'] ?? ''} ${p['gameId'] ?? ''}'),
                      platform: div?.platform ?? ('${p['platform'] ?? ''}'),
                      color: div?.color,
                      size: 74,
                      radius: 10,
                      mediaId: div?.imageMediaId,
                    )
                  : CachedNetImage(url: url, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 徽标：与列表卡同一组件、同一位置逻辑（左上角，商品名之上）；空则不渲染
                if (ProductBadge.shows(p['badgeText'] as String?)) ...[
                  ProductBadge(p['badgeText'] as String?),
                  const SizedBox(height: 5),
                ],
                Row(
                  children: [
                    Expanded(
                      // 商品名：**最多 3 行**（负责人 2026-10-05 报障：确认订单页被截成「…不出保888w[老…」）
                      // 价格/数量步进器在同一个 Column 里、位于名字下方 → 卡片高度自适应，不会被文字压住。
                      child: Text('${p['name'] ?? ''}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.35, color: T.textPrimary)),
                    ),
                    GestureDetector(
                      onTap: _pickProduct,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('更换', style: TextStyle(fontSize: 11.5, color: T.primary)),
                      ),
                    ),
                  ],
                ),
                if (div != null) ...[
                  const SizedBox(height: 6),
                  AppTag(div.name, color: div.color),
                ],
                // 每周限购提示（文案来自服务端；不限购 / 查不到 → 这一行不存在）
                if (_quota != null) ...[
                  const SizedBox(height: 6),
                  WeeklyLimitNote(
                    limitText: '${_quota!['limitText'] ?? ''}',
                    quotaText: '${_quota!['quotaText'] ?? ''}',
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    AppPrice(
                      value: fmtMoney(_price),
                      unit: '${p['priceUnit'] ?? ''}'.isEmpty ? '' : '/${p['priceUnit']}',
                      size: 17,
                      color: T.goldText,
                    ),
                    const Spacer(),
                    _stepper(),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _mediaUrl(Map p) {
    final url = p['coverUrl'] as String?;
    if (url != null && url.isNotEmpty) return AppConfig.resolveMediaUrl(url);
    final id = p['coverMediaId'];
    return id == null ? null : AppConfig.resolveMediaUrl('/media/public/$id');
  }

  /// 商品所属分部：先按 `divisionId` 对照 `/divisions`；商品没挂分部时按 `gameId` 退一步
  /// （同游戏多平台时取排序在前的那个，与商品列表页规则一致）；都对照不到 → null（自绘图标兜底）
  _DivisionLite? _divisionOf(Map p) {
    final did = '${p['divisionId'] ?? ''}';
    if (did.isNotEmpty) {
      for (final d in _divisions) {
        if (d.id == did) return d;
      }
    }
    final gid = '${p['gameId'] ?? ''}';
    if (gid.isNotEmpty) {
      for (final d in _divisions) {
        if (d.gameId == gid) return d;
      }
    }
    return null;
  }

  /// 当前商品所属分部（服务区上方平台标识用）：优先按商品 divisionId 对照；
  /// 商品没挂分部时用页面 context 带入的 divisionId（商品列表页跳转时传）；
  /// 都对照不到 → null（此时不显示平台标识）
  _DivisionLite? get _platformDivision {
    final p = _product;
    if (p != null) {
      final d = _divisionOf(p);
      if (d != null) return d;
    }
    final did = widget.divisionId ?? '';
    if (did.isNotEmpty) {
      for (final d in _divisions) {
        if (d.id == did) return d;
      }
    }
    return null;
  }

  Widget _stepper() => Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.strokeSoft),
          borderRadius: BorderRadius.circular(AppDecoRadius.control),
        ),
        child: Row(
          children: [
            _stepBtn(AppIcon.minus, () {
              if (_qty > 1) setState(() => _qty -= 1);
            }),
            Container(
              width: 40,
              alignment: Alignment.center,
              child: Text('$_qty', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
            ),
            _stepBtn(AppIcon.plus, () {
              if (_qty < 99) setState(() => _qty += 1);
            }),
          ],
        ),
      );

  Widget _stepBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: SizedBox(width: 32, height: 32, child: AppIcon.of(icon, size: 15, color: T.textSecondary)),
      );

  /// 分区卡（方案 G：白底 + 1px 描边 [AppColors.strokeSoft] `#E8ECF2` + 圆角 14；
  /// 标题行左对齐，必填星号在标题前）
  ///
  /// 为什么把 `AppCard` 的默认 16 圆角收敛到 14：`docs/21`「全大圆角（一律 ≥16）」是禁项，
  /// 14 是 deco 谱系里"卡片"那一档（`AppDecoRadius.card`），也是方案 G 允许的 10/12/14 之一。
  Widget _card({required String title, required Widget child, bool required = false, bool invalid = false}) => AppCard(
        radius: AppDecoRadius.card,
        border: Border.all(color: AppColors.strokeSoft),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (required)
                  const Text('* ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.error)),
                Text(title,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: invalid ? AppColors.error : T.textPrimary)),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );

  /// 选项胶囊（方案 G「选中 = 蓝底白字胶囊」）
  ///
  /// 圆角走 `AppDecoRadius.capsule`（999）：选项是"可点的小件"，胶囊形状与
  /// 订单列表的状态筛选胶囊同一语言；未选中 = 白底 + 1px `#E8ECF2` 描边。
  Widget _optionButton(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: on ? T.primary : T.bgCardSolid,
            borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
            border: Border.all(color: on ? T.primary : AppColors.strokeSoft),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? Colors.white : T.textPrimary)),
        ),
      );

  /// 指定护航员：弹层选人（数据来自 /public/players，只显示 头像 + 名字 + 介绍）
  Future<void> _pickWorker() async {
    final picked = await showModalBottomSheet<_PlayerLite>(
      context: context,
      backgroundColor: T.bgCardSolid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PlayerPickerSheet(api: _api, divisionId: '${_product?['divisionId'] ?? widget.divisionId ?? ''}'),
    );
    if (picked != null && mounted) {
      setState(() {
        _designated = picked;
        _workerMode = 'designated';
      });
    }
  }
}

/// 指定护航员弹层
class _PlayerPickerSheet extends StatefulWidget {
  const _PlayerPickerSheet({required this.api, required this.divisionId});

  final ApiClient api;
  final String divisionId;

  @override
  State<_PlayerPickerSheet> createState() => _PlayerPickerSheetState();
}

class _PlayerPickerSheetState extends State<_PlayerPickerSheet> {
  List<_PlayerLite> _players = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      // 指定护航员**按分部取人**（负责人 2026-10-04）：服务端只返回"该分部有接单权限"的打手，
      // 客户端不做二次过滤（数据源已经是权威结果）。
      //
      // 缓存：SWR 键 = `账号|地址|/public/players?divisionId=..&page=..&pageSize=..`（查询参数参与拼键），
      // 所以**不同分部物理隔离**，绝不会出现"点手游却看到端游的人"的串缓存；
      // 这里再 forceRefresh 一次：打开选人弹层属于低频操作，保证刚授权/刚撤销的人立刻反映。
      final resp = await widget.api.request('GET', '/public/players', queryParameters: {
        if (widget.divisionId.isNotEmpty) 'divisionId': widget.divisionId,
        'page': 1,
        'pageSize': 50,
      }, forceRefresh: true);
      final list = ((resp['data'] as Map?)?['list'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _players = list.map((e) => _PlayerLite.fromJson(e as Map)).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 弹层里点头像 → 打手信息页（二级页 push 成全屏，底栏不显示）
  ///
  /// 弹层**不关**：从信息页返回后仍在选人这一步，用户可以直接接着选他。
  Future<void> _openWorkerProfile(_PlayerLite p) => Navigator.of(context).push(
        AppMotionRoute<void>(
          builder: (_) => WorkerProfilePage(
            api: widget.api,
            workerId: p.workerId,
            fallbackNickname: p.nickname,
            fallbackIntro: p.intro,
            fallbackAvatarMediaId: p.avatarMediaId,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('选择护航员', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: T.textPrimary)),
            const SizedBox(height: 4),
            Text('介绍由官方审核填写', style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
            const SizedBox(height: 10),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.2, color: T.primary)),
              )
            else if (_players.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: AppEmpty(
                    icon: AppIcon.empty,
                    // 分部隔离后的空态说清楚原因：该分部暂时没有可指定的护航员（避免以为是全局没人）
                    text: widget.divisionId.isEmpty ? '暂无在线护航员' : '该分部暂无可指定的护航员',
                  ))
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _players.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: T.divider),
                  itemBuilder: (_, i) {
                    final p = _players[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      // 2026-10-15：头像可点 → 打手信息页（与技术规则 6 不冲突：
                      // 弹层里的**行**仍然只有 头像 + 名字 + 介绍，属性在点进去的那页）
                      leading: GestureDetector(
                        key: Key('picker-avatar-${p.workerId}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _openWorkerProfile(p),
                        child: AppAvatar(nickname: p.nickname, mediaId: p.avatarMediaId, size: 40, gradient: true),
                      ),
                      title: Text(p.nickname,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                      subtitle: Text(p.intro.isEmpty ? '暂无介绍' : p.intro,
                          // 陪玩介绍：管理端填写、属于"必须看全"的信息（docs/21 找陪玩只展示 名字+介绍）
                          // → 2 行（原来是 1 行，长介绍会被截断；名字 title 不设 maxLines，本来就完整）
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: T.textTertiary, height: 1.4)),
                      onTap: () => Navigator.of(context).pop(p),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DivisionLite {
  _DivisionLite({
    required this.id,
    required this.name,
    required this.color,
    this.shortName = '',
    this.gameId = '',
    this.gameName = '',
    this.code = '',
    this.platform = '',
    this.platformLabel = '',
    this.iconMediaId,
    this.coverMediaId,
  });

  final String id;
  final String name;
  final Color color;

  /// 分部简称（如「三角洲行动」）—— 平台标识用它拼「简称 · 平台」
  final String shortName;

  /// 所属游戏 id（商品没挂分部时按它对照分部）
  final String gameId;

  /// 游戏名（游戏图标映射用）
  final String gameName;

  /// 分部 code（peace_mobile / delta_pc）
  final String code;

  /// 平台 mobile / pc（端游显示「端」角标）
  final String platform;

  /// 平台标签（管理端配置：手游 / 端游）—— 服务区上方平台标识用它
  final String platformLabel;

  /// 管理端给该分部挂的官方游戏图（`/divisions` 下发；任一有值即用图）
  final String? iconMediaId;
  final String? coverMediaId;

  /// 分部官方图：有图就用图（iconMediaId 优先，其次 coverMediaId；都空 → 自绘游戏图标回退）
  String? get imageMediaId => divisionMediaId(iconMediaId: iconMediaId, coverMediaId: coverMediaId);

  /// 游戏图标映射键（code → gameName → name 逐级兜底）
  String get gameKey => '$code $gameName $name'.trim();

  factory _DivisionLite.fromJson(Map json) {
    final hex = (json['themeColor'] as String?)?.replaceFirst('#', '');
    Color? c;
    if (hex != null && hex.length == 6) {
      final n = int.tryParse(hex, radix: 16);
      if (n != null) c = Color(0xFF000000 | n);
    }
    return _DivisionLite(
      id: '${json['id']}',
      name: '${json['name'] ?? ''}',
      color: c ?? AppColors.categoryColors[0],
      shortName: '${json['shortName'] ?? json['name'] ?? ''}',
      gameId: '${json['gameId'] ?? ''}',
      gameName: '${json['gameName'] ?? ''}',
      code: '${json['code'] ?? ''}',
      platform: '${json['platform'] ?? ''}',
      platformLabel: '${json['platformLabel'] ?? ''}',
      iconMediaId: json['iconMediaId'] == null ? null : '${json['iconMediaId']}',
      coverMediaId: json['coverMediaId'] == null ? null : '${json['coverMediaId']}',
    );
  }
}

class _PlayerLite {
  _PlayerLite({required this.workerId, required this.nickname, required this.intro, required this.avatarMediaId});

  final String workerId;
  final String nickname;
  final String intro;
  final String? avatarMediaId;

  factory _PlayerLite.fromJson(Map json) => _PlayerLite(
        workerId: '${json['workerId'] ?? json['id']}',
        nickname: '${json['nickname'] ?? ''}',
        intro: '${json['intro'] ?? ''}',
        avatarMediaId: json['avatarMediaId'] == null ? null : '${json['avatarMediaId']}',
      );
}

/// 「记住的游戏账号」一条（`GET /user/game-accounts` 的元素，字段名与接口契约逐字对齐）
///
/// `updatedAt` 只用于**排序**（同一游戏多条时取最近用的那条），不展示。
class _GameAccount {
  _GameAccount({
    required this.gameId,
    required this.gameName,
    required this.gamePlayerId,
    required this.gameZone,
    required this.updatedAt,
  });

  final String gameId;
  final String gameName;
  final String gamePlayerId;
  final String gameZone;
  final String updatedAt;

  /// 排序键：解析不了的时间当 0（最早），不抛异常、不影响"拿不到就保持空"
  int get updatedAtMs => DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ?? 0;

  factory _GameAccount.fromJson(Map json) => _GameAccount(
        gameId: '${json['gameId'] ?? ''}'.trim(),
        gameName: '${json['gameName'] ?? ''}'.trim(),
        gamePlayerId: '${json['gamePlayerId'] ?? ''}'.trim(),
        gameZone: '${json['gameZone'] ?? ''}'.trim(),
        updatedAt: '${json['updatedAt'] ?? ''}',
      );
}
