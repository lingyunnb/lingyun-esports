import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/login_page.dart';
import 'package:worker_app/pages/security_page.dart';

/// 表单错误呈现（负责人 2026-10-04："把下面的弹窗改得更协调一点，把英文改成中文"）
///
/// 覆盖：
/// 1) 工作端登录：服务端 fields[] → 账号/密码输入框下方中文红字
/// 2) 通用失败（无 fields）→ 品牌浮层中文提示（不再系统默认黑色 SnackBar）
/// 3) 改密页服务端字段错误 → 输入框下方红字
/// 全部用例附带：**页面上不出现英文校验文案**（英文正则 findsNothing）
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('登录：服务端 fields[] → 账号/密码下方中文红字，全页无英文校验文案', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(
      status: 400,
      body: {
        'code': 400,
        'message': '账号至少 3 个字符；密码至少 8 个字符',
        'data': null,
        'errorCode': 'VALIDATION_FAILED',
        'fields': [
          {'field': 'username', 'label': '账号', 'message': '至少 3 个字符'},
          {'field': 'password', 'label': '密码', 'message': '至少 8 个字符'},
        ],
      },
    );

    await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle();
    expect(find.text('祁连山电竞内部'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'ab');
    await tester.enterText(find.byType(TextField).at(1), '1234567');
    // 协议勾选（2026-10-05 改版新增：未勾选主按钮禁用，纯前端约束）+ 主按钮稳定 Key
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('至少 3 个字符'), findsWidgets, reason: '账号输入框下方中文红字（+ 汇总条）');
    expect(find.text('至少 8 个字符'), findsWidgets, reason: '密码输入框下方中文红字（+ 汇总条）');
    expect(find.byType(AppFieldError), findsNWidgets(2), reason: '账号/密码各一条行内红字');    // 汇总条：指路文案（不重复红字原文）
    expect(summaryText(tester).contains('账号、密码还需修改'), isTrue, reason: '汇总条应指路：${summaryText(tester)}');
    expect(find.byType(SnackBar), findsNothing, reason: '不得再用系统默认黑色 SnackBar');
    expect(find.textContaining('VALIDATION_FAILED'), findsNothing);
    expect(
      find.textContaining(RegExp(r'must be|should not|should be|property |longer than|shorter than|regular expression|one of the following')),
      findsNothing,
      reason: '页面上不允许出现英文校验文案',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('登录：通用失败（无 fields）→ 品牌浮层中文提示', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(
      status: 401,
      body: {'code': 401, 'message': '账号或密码错误', 'data': null},
    );

    await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'worker01');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('账号或密码错误'), findsOneWidget, reason: '定位不到字段的失败走品牌浮层');
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining(RegExp(r'must be|should not|property |longer than')), findsNothing);
    await tester.pump(const Duration(seconds: 3)); // 浮层 2 秒自动消失
  });

  testWidgets('改密页：服务端 fields[] → 新密码下方红字（不再 SnackBar）', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(
      status: 400,
      body: {
        'code': 400,
        'message': '新密码至少 8 个字符',
        'data': null,
        'errorCode': 'VALIDATION_FAILED',
        'fields': [
          {'field': 'newPassword', 'label': '新密码', 'message': '至少 8 个字符'},
        ],
      },
    );

    await tester.pumpWidget(MaterialApp(home: SecurityPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'oldpassword');
    await tester.enterText(find.byType(TextField).at(1), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.tap(find.text('确认修改'));
    await tester.pumpAndSettle();

    expect(find.text('至少 8 个字符'), findsWidgets, reason: '服务端字段错误落到输入框下方（+ 汇总条）');
    expect(find.byType(AppFieldError), findsNWidgets(3), reason: '三个输入框各挂一条行内错误组件');
    expect(summaryText(tester).contains('新密码还需修改'), isTrue, reason: '汇总条应指路：${summaryText(tester)}');
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.textContaining(RegExp(r'must be|should not|property |longer than|regular expression')),
      findsNothing,
      reason: '页面上不允许出现英文校验文案',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}

/// 汇总条文本（按钮上方 AppFormErrorSummary 渲染的文案，未出现则为空串）
String summaryText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(AppFormErrorSummary), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join(' | ');

/// 固定响应 mock（照既有无依赖 test 写法）
class _Adapter implements HttpClientAdapter {
  _Adapter({required this.status, required this.body});

  final int status;
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
