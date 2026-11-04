import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/login_page.dart';
import 'package:boss_app/pages/security_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 表单错误呈现（负责人 2026-10-04："把下面的弹窗改得更协调一点，把英文改成中文"）
///
/// 覆盖：
/// 1) 服务端返回 `fields[]` → **对应输入框下方中文红字**（注册/登录页）
/// 2) 通用失败（无 fields）→ **品牌浮层 toast**（不是系统默认黑色 SnackBar）
/// 3) 改密页服务端字段错误 → 输入框下方红字 + 不再出现 SnackBar
/// 4) 全页断言：**不出现英文校验文案**（英文正则 findsNothing）
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false; // 登录/改密类接口不缓存，测试直接打 mock
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('注册：服务端 fields[] → 账号/密码输入框下方中文红字，且全页无英文校验文案', (tester) async {
    // 真实手机视口（2026-10-05：注册模式新增「邮箱」「验证码」两格后，
    // 默认 800×600 视口放不下主按钮，点击会落在视口外 → 统一按 390×844 渲染）
    phoneSize(tester);
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

    // 切到注册（负责人截图里的场景）：用稳定 Key 点页脚，避免 Text 命中测试的框架噪声
    await tester.tap(find.byKey(const Key('auth-switch-mode')));
    await tester.pumpAndSettle();
    expect(find.text('昵称（可选）'), findsOneWidget);

    // 协议勾选（2026-10-05 改版新增：未勾选主按钮禁用，纯前端约束）
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(0), 'ab');
    await tester.enterText(find.byType(TextField).at(1), '1234567');
    // 2026-10-05 邮箱通道：注册模式**本地**要求邮箱+6 位验证码（不合法不发请求），
    // 本用例要验的是**服务端** fields[] 的呈现，所以这两格必须填合法值，否则请求根本发不出去
    await tester.enterText(find.byKey(const Key('register-email-field')), 'sender@qq.com');
    await tester.enterText(find.byKey(const Key('register-code-field')), '123456');
    await tester.ensureVisible(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    // 行内红字：字段级消息（服务端 fields[].message）—— 输入框下方一条 + 汇总条一条
    expect(find.text('至少 3 个字符'), findsWidgets, reason: '账号输入框下方应有中文红字');
    expect(find.text('至少 8 个字符'), findsWidgets, reason: '密码输入框下方应有中文红字');
    // 行内红字确实挂在输入框下方（用 AppFieldError 组件定位，而不是只在汇总条里）
    // 2026-10-05 邮箱通道：注册模式多了「邮箱」「验证码」两格 → 账号/密码/邮箱/验证码/昵称 = 5 条
    expect(find.byType(AppFieldError), findsNWidgets(5), reason: '五个输入框各挂一条行内错误组件');
    // 汇总条：指路文案（不重复红字原文）；行内红字才是字段级详情
    expect(summaryText(tester).contains('账号、密码还需修改'), isTrue, reason: '汇总条应指路：${summaryText(tester)}');
    // 不再裸用默认黑色 SnackBar
    expect(find.byType(SnackBar), findsNothing, reason: '服务端校验失败不得再用系统默认黑条');
    // 英文校验文案绝不出现
    expect(
      find.textContaining(RegExp(r'must be|should not|should be|property |longer than|shorter than|regular expression|one of the following')),
      findsNothing,
      reason: '页面上不允许出现英文校验文案',
    );
    // errorCode 原样不得露出
    expect(find.textContaining('VALIDATION_FAILED'), findsNothing);

    // 收尾：红字动画/定时器排空
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

    await tester.enterText(find.byType(TextField).at(0), 'someone');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    // 协议勾选（2026-10-05 改版新增）+ 稳定 Key 点主按钮
    // （品牌区标题也是「登录」，故不再用 find.text('登录') —— 会匹配到两处）
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('账号或密码错误'), findsOneWidget, reason: '定位不到字段的失败走浮层提示');
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.textContaining(RegExp(r'must be|should not|property |longer than')),
      findsNothing,
    );

    // AppToast 2 秒自动消失（排空定时器，避免 pending timer 报错）
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('改密页：服务端 fields[] → 新密码输入框下方红字（不再 SnackBar）', (tester) async {
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

    // 本地校验先过（三个输入框都填合法值），把失败留给服务端
    await tester.enterText(find.byType(TextField).at(0), 'oldpassword');
    await tester.enterText(find.byType(TextField).at(1), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.tap(find.text('确认修改'));
    await tester.pumpAndSettle();

    expect(find.text('至少 8 个字符'), findsWidgets, reason: '服务端字段错误落到输入框下方（+ 汇总条）');
    expect(find.byType(AppFieldError), findsNWidgets(3), reason: '三个输入框各挂一条行内错误组件');
    expect(summaryText(tester).contains('新密码还需修改'), isTrue, reason: '汇总条应指路：${summaryText(tester)}');
    expect(find.byType(SnackBar), findsNothing, reason: '不得再用系统默认黑色 SnackBar');
    expect(
      find.textContaining(RegExp(r'must be|should not|property |longer than|regular expression')),
      findsNothing,
      reason: '页面上不允许出现英文校验文案',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('改密页：本地校验（两次新密码不一致）→ 行内红字而非黑条', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(status: 200, body: {'code': 0, 'message': 'ok', 'data': null});

    await tester.pumpWidget(MaterialApp(home: SecurityPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'oldpassword');
    await tester.enterText(find.byType(TextField).at(1), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword2');
    await tester.tap(find.text('确认修改'));
    await tester.pumpAndSettle();

    expect(find.text('两次输入的新密码不一致'), findsWidgets, reason: '确认密码框下方红字 + 汇总条');
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}

/// 汇总条文本（按钮上方 AppFormErrorSummary 渲染的文案，未出现则为空串）
String summaryText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(AppFormErrorSummary), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join(' | ');

/// 真实手机视口（390×844 @2x）；默认 800×600 放不下增加两格后的注册表单
void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// 固定响应 mock（照 refund_page_test 的既有写法）
class _Adapter implements HttpClientAdapter {  _Adapter({required this.status, required this.body});

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
