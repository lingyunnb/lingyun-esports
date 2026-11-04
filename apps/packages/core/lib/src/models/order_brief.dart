import '../util/idempotency.dart';

/// 订单概要（老板端 /user/orders、工作端 /worker/orders、/worker/order-hall 共用）
///
/// 双端订单列表共用同一份解析：金额一律 [parsePoints] 解析成 double（支持 5.5 这类小数价目），
/// 展示：**老板端与共享包的打手态**用 [fmtMoney]（`¥5.50`），[amountText] 只留给冻结的工作端。
/// 历史上两端各自复制了一份 `json['totalAmount'] as int?` 的写法，
/// 遇到小数订单会抛 TypeError 导致整页崩溃 —— 收敛到这里后只需一处修复、一处测试。
class OrderBrief {
  const OrderBrief({
    required this.id,
    required this.orderNo,
    required this.totalAmount,
    required this.status,
    required this.statusName,
    required this.createdAt,
    this.quantity = 1,
    this.productName = '',
    this.priceUnit = '',
    this.gameZone,
    this.gamePlayerId,
    this.workerNickname = '',
    this.gameKey = '',
    this.platform = '',
    this.divisionId,
    this.gameId = '',
  });

  final String id;
  final String orderNo;

  /// 订单总金额（计价单位 = 余额，1 元 = 1 元）：小数价目下单为 5.5 这类小数，禁用 int
  final double totalAmount;
  final String status;
  final String statusName;
  final String createdAt;

  /// 商品内容（工作端大厅展示「什么单 × 几局」；老板端列表不返回）
  final String productName;
  final String priceUnit;

  /// 点单数量（多个老板点同一商品 = 各自一条订单，展示各自数量）
  final int quantity;
  String get quantityText => '$quantity';

  /// 老板游戏分区（'qq' | 'wechat'）与游戏 ID —— **只有抢上单后（我的订单）才返回**，
  /// 大厅列表不携带（服务端不返回，客户端绝不可在大厅展示）
  final String? gameZone;
  final String? gamePlayerId;

  /// 打手昵称（订单卡片展示服务人员；未接单为空，2026-09-25）
  final String workerNickname;

  /// 游戏标识与平台（订单卡游戏图标用）
  ///
  /// 服务端 `orderView()` 目前**不下发**这两个字段（见报告「未做/风险」），所以正常为空：
  /// 为空时订单卡用兜底游戏图标 + 稳定品类色，且**不显示「端」角标**（无法判定就不猜）。
  /// 一旦服务端补齐（gameName/division.platform），客户端零改动即自动生效。
  final String gameKey;
  final String platform;

  /// 订单所属分部 / 游戏（2026-10-04 服务端 `orderView()` 已补下发）
  ///
  /// 订单卡据此对照 `/divisions` 里该分部的官方游戏图（`iconMediaId`）与平台：
  /// 有图就用图，端游仍在图片底部叠「端」角标。为空（老数据/未挂分部）时回退自绘图标。
  final String? divisionId;
  final String gameId;

  /// 展示文本（**旧口径，只留给冻结的工作端**）：整数不带小数点（16），小数最多两位去尾零（5.5 / 11.55）
  ///
  /// 老板端与共享包的打手态请直接用 `fmtMoney(totalAmount)`（`¥16.00` / `¥5.50`）。
  String get amountText => fmtPoints(totalAmount);

  /// 分区展示文本（QQ区/微信区；无数据返回 '-'）
  String get zoneText => switch (gameZone) {
        'qq' => 'QQ区',
        'wechat' => '微信区',
        _ => '-',
      };

  factory OrderBrief.fromJson(Map<String, dynamic> json) => OrderBrief(
        id: '${json['id']}',
        orderNo: '${json['orderNo']}',
        totalAmount: parsePoints(json['totalAmount']),
        status: '${json['status']}',
        statusName: '${json['statusName']}',
        createdAt: '${json['createdAt']}',
        productName: '${json['productName'] ?? ''}',
        priceUnit: '${json['priceUnit'] ?? ''}',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        gameZone: json['gameZone'] as String?,
        gamePlayerId: json['gamePlayerId'] as String?,
        workerNickname: '${json['workerNickname'] ?? ''}',
        gameKey: '${json['gameKey'] ?? json['gameName'] ?? ''}',
        platform: '${json['platform'] ?? json['platformLabel'] ?? ''}',
        divisionId: json['divisionId'] == null ? null : '${json['divisionId']}',
        gameId: '${json['gameId'] ?? ''}',
      );
}
