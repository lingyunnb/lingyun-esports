import 'dart:convert';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 双端订单列表共用的 OrderBrief：用**真实接口响应**验证解析与展示。
///
/// 载荷取自 2026-09-23 生产库实测（curl /user/orders 与 /worker/order-hall）：
/// 订单 396 = 钻皮·刀 5.5 积分（小数价目首单）；订单 395 = 150 积分（整数价目）。
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  // 小数订单（服务端 DECIMAL(12,2) 经 money.transformer → JSON 数字 5.5）
  final decimalPayload = jsonDecode('''
  {"id":"396","orderNo":"ORDMUE8SIVK2535","productId":"32","quantity":1,"unitPrice":5.5,
   "totalAmount":5.5,"status":"pending_take","statusName":"待接单","workerId":null,
   "userRemark":null,"createdAt":"2026-09-23T15:12:54.417Z","duplicated":false}
  ''') as Map<String, dynamic>;

  // 整数金额订单（Number("150.00")=150 → JSON 整数）
  final intPayload = jsonDecode('''
  {"id":"395","orderNo":"ORDMUE5QE4M5648","quantity":1,"unitPrice":150,
   "totalAmount":150,"status":"completed","statusName":"已完成",
   "createdAt":"2026-09-23T14:02:11.000Z"}
  ''') as Map<String, dynamic>;

  test('小数订单：解析不抛异常，金额为 5.5', () {
    final o = OrderBrief.fromJson(decimalPayload);
    expect(o.totalAmount, 5.5);
    expect(o.amountText, '5.5'); // 展示：5.5 积分（不是 5.50）
    expect(o.orderNo, 'ORDMUE8SIVK2535');
    expect(o.status, 'pending_take');
    expect(o.statusName, '待接单');
    expect(o.id, '396'); // id 转字符串，路径拼接用
  });

  test('整数订单：展示不带小数点', () {
    final o = OrderBrief.fromJson(intPayload);
    expect(o.totalAmount, 150.0);
    expect(o.amountText, '150');
  });

  test('派单通知载荷（WS dispatch:new）金额同为小数安全', () {
    // worker-app 派单弹窗用 fmtPoints(parsePoints(map['totalAmount']))
    final map = jsonDecode('{"orderId":"396","orderNo":"ORDMUE8SIVK2535","totalAmount":5.5}') as Map<String, dynamic>;
    expect(fmtPoints(parsePoints(map['totalAmount'])), '5.5');
  });

  test('缺字段/异常值兜底不崩', () {
    final o = OrderBrief.fromJson(const {});
    expect(o.totalAmount, 0);
    expect(o.amountText, '0');
    expect(o.orderNo, 'null');
    expect(parsePoints('5.50'), 5.5);
    expect(parsePoints('abc'), 0);
  });

  test('商品内容/数量/分区/ID 解析（负责人需求 2026-09-24）', () {
    // 大厅返回：商品名+数量，无分区/ID
    final hall = OrderBrief.fromJson(jsonDecode(
        '{"id":"429","orderNo":"ORDMUEC0J843667","productId":"42","quantity":2,"totalAmount":300,"status":"pending_take","statusName":"待接单","createdAt":"2026-09-23T16:43:06.965Z","productName":"DMZ材料单","priceUnit":"单"}') as Map<String, dynamic>);
    expect(hall.productName, 'DMZ材料单');
    expect(hall.quantity, 2);
    expect(hall.quantityText, '2');
    expect(hall.gameZone, isNull);
    expect(hall.zoneText, '-');

    // 我的订单返回：带分区/ID
    final mine = OrderBrief.fromJson(jsonDecode(
        '{"id":"429","orderNo":"ORDMUEC0J843667","quantity":2,"totalAmount":300,"status":"taken","statusName":"已接单","createdAt":"2026-09-23T16:43:06.965Z","productName":"DMZ材料单","priceUnit":"单","gameZone":"qq","gamePlayerId":"88888888"}') as Map<String, dynamic>);
    expect(mine.gameZone, 'qq');
    expect(mine.zoneText, 'QQ区');
    expect(mine.gamePlayerId, '88888888');

    final wx = OrderBrief.fromJson(const {'gameZone': 'wechat'});
    expect(wx.zoneText, '微信区');
  });
}
