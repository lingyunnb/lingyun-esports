import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// core 侧「邮箱绑定/换绑 + 邮箱验证码登录」契约与纯规则（负责人 2026-10-10 邮箱能力）
///
/// 这里只压**契约与规则**（取值必须与服务端逐字一致），页面交互在老板端的
/// `test/email_bind_test.dart` / `test/email_login_test.dart` 里压：
/// 1. `EmailCodeScene` 四个取值 = 服务端 `SendEmailCodeDto` 的 `@IsIn(['register','reset','bind','login'])`；
/// 2. `emailCodeSentHint`：register/bind 与老文案**逐字不变**；reset 仍防枚举；login 是**与绑定状态无关的常量**；
/// 3. `EmailBindStatus` / `EmailBindResult` 的解析（脱敏邮箱、bound/verified/rebound）；
/// 4. `currentPasswordFormatError`：只校验非空 + 上限（服务端 `@Length(1,64)` 的登录口径）；
/// 5. `AuthErrorField.ofMessage` 的中文 → 字段归属（本轮新增的三条）；
/// 6. `AuthStore.bindEmail` 的路径/方法/请求体/令牌；
/// 7. `AuthStore.fetchEmailStatus`（GET /user/email）；
/// 8. `AuthStore.loginByEmailCode`：请求体**不含** username/password，且落进**既有**令牌落地链路
///    （令牌写入 + `/auth/me` 刷新身份态 —— 与密码登录共用 `_completeLogin`）。
///
/// 假通道只有一个实例：注入的 `ApiClient` 与 `ApiClient.debugDefaultDio`（AuthStore 内部那个客户端）
/// 共用它，所以 `/auth/me` 这种"内部调用"也能被断言。
void main() {
  setUpAll(() {
    // 必须在任何 AuthStore 静态访问之前：单例内部的 ApiClient 在**构造时**固化 Dio
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://core-email.local'))
      ..httpClientAdapter = api;
  });

  setUp(() {
    api.reset();
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    AuthStore.debugOnStorageWrite = null;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: 'primary-token');
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AuthStore.debugOnStorageWrite = null;
  });

  // ------------------------------------------------------------ scene 取值

  group('scene 取值（与服务端 DTO 逐字一致）', () {
    test('四个 scene 值不能改（改了就是 Redis 计码键分叉）', () {
      expect(EmailCodeScene.register, 'register');
      expect(EmailCodeScene.reset, 'reset');
      expect(EmailCodeScene.bind, 'bind');
      expect(EmailCodeScene.login, 'login');
    });

    test('取码提示：register/bind 与老文案逐字不变，reset 仍防枚举', () {
      expect(emailCodeSentHint(EmailCodeScene.register), '验证码已发送至邮箱，请注意查收（10 分钟内有效）');
      expect(emailCodeSentHint(EmailCodeScene.bind), '验证码已发送至邮箱，请注意查收（10 分钟内有效）');
      expect(emailCodeSentHint(EmailCodeScene.reset), '若该邮箱已绑定，验证码已发送，请查收（10 分钟内有效）');
    });

    test('登录取码提示是**与绑定状态无关的常量**（防枚举：同一场景恒同一句）', () {
      final a = emailCodeSentHint(EmailCodeScene.login);
      final b = emailCodeSentHint(EmailCodeScene.login);
      expect(a, b);
      expect(a, contains('验证码已发送'));
      for (final leak in const ['未注册', '未绑定', '不存在', '已绑定']) {
        expect(a.contains(leak), isFalse, reason: '登录取码提示不得出现「$leak」式断言（会泄露邮箱是否已绑定）');
      }
    });
  });

  // ------------------------------------------------------------ 模型解析

  group('EmailBindStatus（GET /user/email）', () {
    test('未绑定：bound=false / email=null → maskedEmail 为 null（页面据此渲染「未绑定」）', () {
      final s = EmailBindStatus.fromJson(const {
        'bound': false,
        'email': null,
        'verified': false,
        'verifiedAt': null,
      });
      expect(s.bound, isFalse);
      expect(s.maskedEmail, isNull);
      expect(s.verified, isFalse);
    });

    test('已绑定：脱敏邮箱逐字保留（客户端不还原、不拼全量）', () {
      final s = EmailBindStatus.fromJson(const {
        'bound': true,
        'email': 'ab***@qq.com',
        'verified': true,
        'verifiedAt': '2026-10-10T00:00:00.000Z',
      });
      expect(s.bound, isTrue);
      expect(s.maskedEmail, 'ab***@qq.com');
      expect(s.verified, isTrue);
    });

    test('bound=true 但 email 是空白串 → 不当作"已绑定"（不能让页面显示空白）', () {
      final s = EmailBindStatus.fromJson(const {'bound': true, 'email': '  ', 'verified': true});
      expect(s.maskedEmail, isNull);
    });

    test('data 缺失（旧服务端/异常）→ 安全默认：未绑定，不抛异常', () {
      final s = EmailBindStatus.fromJson(null);
      expect(s.bound, isFalse);
      expect(s.maskedEmail, isNull);
    });
  });

  group('EmailBindResult（POST /user/email/bind）', () {
    test('首次绑定：rebound=false + 文案「邮箱绑定成功」', () {
      final r = EmailBindResult.fromJson(const {
        'ok': true,
        'email': 'ab***@qq.com',
        'emailVerified': true,
        'rebound': false,
        'message': '邮箱绑定成功',
      });
      expect(r.ok, isTrue);
      expect(r.email, 'ab***@qq.com');
      expect(r.emailVerified, isTrue);
      expect(r.rebound, isFalse);
      expect(r.message, '邮箱绑定成功');
    });

    test('换绑：rebound=true + 文案「邮箱换绑成功」', () {
      final r = EmailBindResult.fromJson(const {
        'ok': true,
        'email': 'cd***@qq.com',
        'emailVerified': true,
        'rebound': true,
        'message': '邮箱换绑成功',
      });
      expect(r.rebound, isTrue);
      expect(r.message, '邮箱换绑成功');
    });
  });

  // ------------------------------------------------------------ 本地校验

  group('当前密码本地校验（服务端是登录口径 1-64）', () {
    test('空 → 「请输入当前密码」', () {
      expect(currentPasswordFormatError(''), '请输入当前密码');
    });

    test('短密码（1 位）**必须放行**：老账号密码规则由登录侧决定，不能比登录更严', () {
      expect(currentPasswordFormatError('a'), isNull);
      expect(kPasswordMinLength, 8, reason: '新密码口径仍是 8-64，两者刻意不同');
    });

    test('超长（>64）→ 中文上限提示', () {
      expect(currentPasswordFormatError('a' * 65), '密码最多 64 个字符');
      expect(currentPasswordFormatError('a' * 64), isNull);
    });

    test('换绑提示常量逐字（负责人点名的文案）', () {
      expect(kEmailRebindNotice, '更换后原邮箱将不再用于登录');
    });
  });

  group('中文错误 → 表单字段归属', () {
    test('「密码错误」落在当前密码格（绑定/换绑的服务端原文）', () {
      expect(AuthErrorField.ofMessage('密码错误'), AuthErrorField.password);
    });

    test('回归：登录的「账号或密码错误」**不得**被「密码错误」吞掉（整句规则，仍走浮层）', () {
      // 这是本轮真踩到的坑：把「密码错误」写成子串规则后，密码登录失败会被标到密码格行内红字，
      // 等于替服务端指认"是密码错了"（既有行为是整层浮层：账号和密码里有一个不对）。
      expect(AuthErrorField.ofMessage('账号或密码错误'), isNull);
      expect(AuthErrorField.ofMessage('原密码错误'), isNull);
    });

    test('「该邮箱已被其他账号绑定」落在邮箱格（409）', () {
      expect(AuthErrorField.ofMessage('该邮箱已被其他账号绑定'), AuthErrorField.email);
    });

    test('「验证码错误」/「验证码已过期，请重新获取」/「验证码错误次数过多，请重新获取」落在验证码格', () {
      expect(AuthErrorField.ofMessage('验证码错误'), AuthErrorField.emailCode);
      expect(AuthErrorField.ofMessage('验证码已过期，请重新获取'), AuthErrorField.emailCode);
      expect(AuthErrorField.ofMessage('验证码错误次数过多，请重新获取'), AuthErrorField.emailCode);
    });

    test('「邮箱或验证码错误」（登录统一失败）落在验证码格', () {
      expect(AuthErrorField.ofMessage('邮箱或验证码错误'), AuthErrorField.emailCode);
    });

    test('「该邮箱已被注册」仍落在邮箱格（注册老路径不受影响）', () {
      expect(AuthErrorField.ofMessage('该邮箱已被注册'), AuthErrorField.email);
    });
  });

  // ------------------------------------------- 汇总条（出图自查抓到的幽灵红条）

  group('FormErrors 汇总条', () {
    test('回归：把最后一个字段红字改对后，汇总条必须**整条消失**（不得留下「参数」填写有误）', () {
      // 本轮邮箱绑定页出图自查时抓到：改对输入框后按钮上方仍挂着一条「「参数」填写有误」，
      // 根因是 `_normalizeSummary` 把空行也送去 `localizeValidationMessage('', '参数')`，
      // 而后者把空串兜底成「「参数」填写有误」。
      final errs = FormErrors()..set('email', '邮箱格式不正确');
      expect(errs.summaryLines, ['邮箱还需修改']);
      errs.clearField('email');
      expect(errs.isEmpty, isTrue);
      expect(errs.summaryLines, isEmpty, reason: '没有错误了就不该有任何汇总文案');
    });

    test('回归：`setSummary` 的整体错误仍必须留在汇总条（本次修的是空行，不是它）', () {
      final errs = FormErrors()..setSummary('该订单当前状态不可投诉');
      expect(errs.summaryLines, ['该订单当前状态不可投诉']);
    });
  });

  // ------------------------------------------------------------ AuthStore

  group('AuthStore 邮箱接口', () {
    test('bindEmail：POST /user/email/bind + 三要素请求体 + primary 令牌', () async {
      final r = await AuthStore.instance.bindEmail(
        email: '  new_mail@qq.com  ',
        code: ' 246810 ',
        password: 'pass1234',
        api: api.client,
      );
      expect(api.paths, ['/user/email/bind']);
      expect(api.methods.single, 'POST');
      expect(api.bodies.single, {
        'email': 'new_mail@qq.com',
        'emailCode': '246810',
        'password': 'pass1234',
      }, reason: '邮箱与验证码都去空白（服务端也会 normalize，这里少传一次脏数据）');
      expect(api.authOf('/user/email/bind'), 'Bearer primary-token');
      expect(r.email, 'ab***@qq.com');
      expect(r.rebound, isFalse);
      expect(r.message, '邮箱绑定成功');
    });

    test('bindEmail 失败：原样抛出服务端中文（绝不吞错/改写）', () async {
      api.bindHttp = 409;
      api.bind = const {'code': 409, 'message': '该邮箱已被其他账号绑定', 'data': null};
      await expectLater(
        AuthStore.instance.bindEmail(email: 'a@b.com', code: '123456', password: 'p', api: api.client),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 409)
            .having((e) => e.message, 'message', '该邮箱已被其他账号绑定')),
      );
    });

    test('fetchEmailStatus：GET /user/email（primary 令牌）+ 解析脱敏状态', () async {
      api.status = const {
        'code': 0,
        'message': 'ok',
        'data': {'bound': true, 'email': 'ab***@qq.com', 'verified': true, 'verifiedAt': null},
      };
      final s = await AuthStore.instance.fetchEmailStatus(api: api.client);
      expect(api.paths, ['/user/email']);
      expect(api.methods.single, 'GET');
      expect(api.authOf('/user/email'), 'Bearer primary-token');
      expect(s.maskedEmail, 'ab***@qq.com');
      expect(s.verified, isTrue);
    });

    test('loginByEmailCode：POST /auth/login 只带 email/emailCode/role（不伪造 username/password）', () async {
      final writes = <String, String?>{};
      AuthStore.debugOnStorageWrite = (key, value) => writes[key] = value;
      await _withMe(() => AuthStore.instance.loginByEmailCode(
            email: ' boss@qq.com ',
            emailCode: ' 135790 ',
            role: 'user',
            api: api.client,
          ));
      expect(api.bodiesOf('/auth/login').single, {'email': 'boss@qq.com', 'emailCode': '135790', 'role': 'user'});
      expect(api.bodiesOf('/auth/login').single.containsKey('username'), isFalse);
      expect(api.bodiesOf('/auth/login').single.containsKey('password'), isFalse);
    });

    test('loginByEmailCode 与 login 共用落地链路：令牌写入安全存储 + /auth/me 刷新身份态', () async {
      final writes = <String, String?>{};
      AuthStore.debugOnStorageWrite = (key, value) => writes[key] = value;

      await _withMe(() => AuthStore.instance.loginByEmailCode(
            email: 'boss@qq.com',
            emailCode: '135790',
            role: 'user',
            api: api.client,
          ));

      // ① 令牌真的落进既有存储路径
      expect(writes['auth_access_token'], 'access-token-email', reason: '不是"只弹个 toast"');
      expect(writes['auth_refresh_token'], 'refresh-token-email');
      expect(AuthStore.instance.accessToken, 'access-token-email');
      expect(AuthStore.instance.loggedIn, isTrue, reason: '身份态已建立 → 老板端 RootGate 会切主框架');
      // ② 身份态刷新：既有的 GET /auth/me 被调用（AuthStore 内部客户端）
      expect(api.paths, contains('/auth/me'));
      expect(AuthStore.instance.me?.uid, '10086');
    });
  });
}

/// 跑一次会触发 `fetchMe()` 的落地链路，并把 `/auth/me` 的假响应摆好。
///
/// 为什么要有它：`fetchMe()` 用的是 AuthStore **内部**客户端（`ApiClient.debugDefaultDio`），
/// 与本用例注入的实例是同一个假通道（见文件头），所以这里只需保证 `/auth/me` 有合法响应。
Future<void> _withMe(Future<void> Function() action) async {
  api.meEnabled = true;
  try {
    await action();
  } finally {
    api.meEnabled = false;
  }
}

// ------------------------------------------------------------------ 工具

/// 记录请求的假 API（注入实例与 debugDefaultDio 共用它）
final _FakeApi api = _FakeApi();

/// 假通道实现
class _FakeApi implements HttpClientAdapter {
  static const Map<String, dynamic> _defaultStatus = {
    'code': 0,
    'message': 'ok',
    'data': {'bound': false, 'email': null, 'verified': false, 'verifiedAt': null},
  };
  static const Map<String, dynamic> _defaultBind = {
    'code': 0,
    'message': 'ok',
    'data': {
      'ok': true,
      'email': 'ab***@qq.com',
      'emailVerified': true,
      'rebound': false,
      'message': '邮箱绑定成功',
    },
  };

  Map<String, dynamic> status = _defaultStatus;
  Map<String, dynamic> bind = _defaultBind;
  int bindHttp = 200;

  /// `/auth/me` 是否回真实资料（只有登录落地用例需要）
  bool meEnabled = false;

  final List<String> paths = [];
  final List<String> methods = [];
  final List<Map<String, dynamic>> bodies = [];
  final List<String?> auth = [];

  /// 注入给页面/用例的客户端（显式 dio → 一定走本假通道）
  late final ApiClient client = ApiClient(
    dio: Dio(BaseOptions(baseUrl: 'http://core-email.local'))..httpClientAdapter = this,
  );

  String? authOf(String path) {
    final i = paths.indexOf(path);
    return i < 0 ? null : auth[i];
  }

  List<Map<String, dynamic>> bodiesOf(String path) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < paths.length; i++) {
      if (paths[i] == path) out.add(bodies[i]);
    }
    return out;
  }

  void reset() {
    paths.clear();
    methods.clear();
    bodies.clear();
    auth.clear();
    status = _defaultStatus;
    bind = _defaultBind;
    bindHttp = 200;
    meEnabled = false;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    methods.add(options.method);
    bodies.add(options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});
    auth.add(options.headers['Authorization'] as String?);

    var code = 200;
    Map<String, dynamic> body = const {'code': 0, 'message': 'ok', 'data': null};
    if (options.path == '/user/email') {
      body = status;
    } else if (options.path == '/user/email/bind') {
      code = bindHttp;
      body = bind;
    } else if (options.path == '/auth/login') {
      body = const {
        'code': 0,
        'message': 'ok',
        'data': {'accessToken': 'access-token-email', 'refreshToken': 'refresh-token-email'},
      };
    } else if (options.path == '/auth/me') {
      body = {
        'code': 0,
        'message': 'ok',
        'data': {
          'id': 'u1',
          'username': 'boss_9527',
          // meEnabled=false 时故意不给 uid：用来证明"断言到的 uid 确实来自 /auth/me 的响应"
          'uid': meEnabled ? '10086' : '',
          'nickname': '老板',
          'role': 'user',
          'level': 3,
          'totalSpent': 0,
        },
      };
    }
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
