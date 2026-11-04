import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/worker_sunset_block_page.dart';
import 'package:worker_app/widgets/migration_notice.dart';
import 'package:worker_app/widgets/worker_sunset.dart';

/// 工作端**完全阻断版（v1.8.2 / 码 60）· 立即生效**（负责人 2026-10-06 拍板，无宽限期）
///
/// 本文件是 v1.8.1（码 59）「到期自动硬阻断」那一批用例的**就地升级**，钉四件事：
/// 1. **任何时间都不可继续**：`workerSunsetCanContinue` 在产线默认参数下
///    （`blocking = kWorkerSunsetBlocking = true`）对过去/现在/未来**一律 false**；
/// 2. **备用开关为 false 时的到期逻辑没被删**：同一个纯函数用**注入参数** `blocking: false`
///    继续覆盖"到期前 true / 到期当天 00:00 起 false"两条分支（证明日期判定仍在）；
/// 3. **文案只有一个时态**：不出现「将于 … 停止服务」、不再出现「10 月 13 日」
///    （那是服务端兜底日，客户端不再展示；兜底本身仍在线，见 docs/04）；
/// 4. **服务端时间那层还在**（备用分支的防改钟），但立即阻断下**页面不再发这次探测**
///    （[WorkerSunsetNetworkTime.probe] 的实现与 ⑥a/⑥b/⑥b3 的用例都保留）。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
    // 探测只在备用开关（blocking == false）下才发生；本文件用 ⑥b3/⑥d 直接验实现与"不探测"
    WorkerSunsetProbe.enabled = false;
    NetworkTime.resetCache();
    AuthStore.instance.debugSetSession(accessToken: 'deadline-token', me: _me());
    WorkerSunsetGate.instance.debugReset();
  });

  tearDown(() {
    WorkerSunsetProbe.enabled = true;
    NetworkTime.resetCache();
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession();
    WorkerSunsetGate.instance.debugReset();
  });

  // ──────────────────────────────────────────────── ① 立即阻断（任何时间都不可继续）
  group('立即阻断：任何时间都不可继续（kWorkerSunsetBlocking = true）', () {
    test('① 开关常量为 true（完全阻断版），且过去 / 现在 / 未来一律不可继续', () {
      expect(kWorkerSunsetBlocking, isTrue, reason: '本版就是"完全阻断版"：这一个常量是唯一开关');
      for (final now in [
        DateTime(2026, 1, 1), // 过去
        DateTime(2026, 10, 6), // 立即生效日（发布当天）
        DateTime(2026, 10, 12, 23, 59, 59, 999), // 旧宽限期最后一毫秒
        DateTime(2026, 10, 13), // 旧到期日 00:00
        DateTime(2026, 10, 14),
        DateTime(2026, 11, 1, 12),
        DateTime(2027, 1, 1),
        DateTime(2030, 1, 1), // 未来很远
        DateTime.utc(2026, 10, 20), // 传 UTC 也按"是否已过这一刻"判，不因时区标志翻车
      ]) {
        expect(workerSunsetCanContinue(now), isFalse, reason: '$now 不应还能继续使用');
        expect(workerSunsetStopped(now), isTrue, reason: '$now 应算"已停止服务"');
      }
    });

    test('② 显式传 blocking: true 与默认值逐字同结论（产线路径 == 短路路径）', () {
      final DateTime beforeDeadline = DateTime(2026, 10, 12, 12);
      expect(workerSunsetCanContinue(beforeDeadline), isFalse);
      expect(workerSunsetCanContinue(beforeDeadline, blocking: true), isFalse);
      expect(workerSunsetStopped(beforeDeadline), isTrue);
      expect(workerSunsetStopped(beforeDeadline, blocking: true), isTrue);
    });

    test('③ 备用开关为 false 时的到期逻辑**没被删**：注入参数即可覆盖两条分支', () {
      // 到期前 → 可以继续（旧口径：发布后 7 天宽限期）
      expect(workerSunsetCanContinue(DateTime(2026, 10, 6), blocking: false), isTrue, reason: '发布当天还有 7 天');
      expect(workerSunsetCanContinue(DateTime(2026, 10, 12)), isFalse, reason: '默认（生产）恒 false');
      expect(workerSunsetCanContinue(DateTime(2026, 10, 12), blocking: false), isTrue);
      expect(workerSunsetCanContinue(DateTime(2026, 10, 12, 23, 59), blocking: false), isTrue,
          reason: '到期前一天 23:59 仍是"前一天"');
      expect(workerSunsetCanContinue(DateTime(2026, 10, 12, 23, 59, 59, 999), blocking: false), isTrue,
          reason: '最后一毫秒还能点');
      // 到期当天 00:00 起 → 不可继续
      expect(workerSunsetCanContinue(DateTime(2026, 10, 13), blocking: false), isFalse, reason: '当天 00:00 就是分界点');
      expect(
        workerSunsetCanContinue(DateTime(2026, 10, 13).add(const Duration(milliseconds: 1)), blocking: false),
        isFalse,
        reason: '00:00 之后一毫秒',
      );
      expect(workerSunsetCanContinue(DateTime(2026, 10, 13, 23, 59), blocking: false), isFalse, reason: '当天 23:59 也不可继续');
      expect(workerSunsetCanContinue(DateTime(2026, 10, 14), blocking: false), isFalse);
      expect(workerSunsetCanContinue(DateTime(2027, 1, 1), blocking: false), isFalse);
      // 到期判定本身与上面逐条一致（同一天：无文案分档，只有 true/false）
      expect(workerSunsetEnded(DateTime(2026, 10, 12, 23, 59, 59, 999)), isFalse);
      expect(workerSunsetEnded(DateTime(2026, 10, 13)), isTrue);
    });

    test('④ 日期常量不变量：release + grace = sunset（备用分支口径保留，下一版只需改常量）', () {
      expect(kWorkerSunsetReleaseDate, DateTime(2026, 10, 6));
      expect(kWorkerSunsetGraceDays, 7);
      expect(kWorkerSunsetDate, DateTime(2026, 10, 13));
      expect(kWorkerSunsetDate.difference(kWorkerSunsetReleaseDate).inDays, kWorkerSunsetGraceDays);
      expect(kWorkerSunsetDateText, '10 月 13 日');
      // 停止服务日必须是**本地 00:00**（备用分支的分界点就是它自己）
      expect(kWorkerSunsetDate.hour, 0);
      expect(kWorkerSunsetDate.minute, 0);
      expect(kWorkerSunsetDate.isUtc, isFalse);
    });

    test('④b 文案是现在时：主说明/兜底说明都不含日期，也不含「将于 … 停止服务」', () {
      expect(kWorkerSunsetBlockedNote, contains('停止服务'));
      expect(kWorkerSunsetBlockedNote, contains('祁连山电竞'));
      expect(kWorkerSunsetBlockedNote, isNot(contains(kWorkerSunsetDateText)),
          reason: '立即生效还给日期 = 让人以为"还有时间"');
      expect(kWorkerSunsetBlockedNote, isNot(contains('将于')));
      expect(kWorkerSunsetServerNote, isNot(contains(kWorkerSunsetDateText)));
      expect(kWorkerSunsetServerNote, isNot(contains('将于')));
      // 引导条正文（本版恒为停止分支）同样干净
      final String body = migrationBodyText(DateTime.now());
      expect(body, contains(kWorkerSunsetBlockedNote));
      expect(body, isNot(contains('将于')));
      expect(body, isNot(contains(kWorkerSunsetDateText)));
    });
  });

  // ──────────────────────────────────────────────── ⑥ 服务端时间那一层（保留 + 本版不再触发）
  group('服务端时间校验（实现保留：备用分支的防改钟层）', () {
    test('⑥a 拿不到服务端时间 → 判定完全回退本地时间（不抛异常、不改变结果）', () {
      // 这是探测的"失败路径"契约：core 的 NetworkTime 在无 Date 头 / 解析不了时返回 null
      expect(NetworkTime.parseDateHeader(null), isNull);
      expect(NetworkTime.parseDateHeader(''), isNull);
      expect(NetworkTime.parseDateHeader('   '), isNull);
      expect(NetworkTime.parseDateHeader('not-a-date'), isNull);
      expect(NetworkTime.parseDateHeader('2026-10-13T00:00:00Z'), isNull, reason: '不是 HTTP Date 格式');

      // 回退后：判定 == 纯本地时间判定（主口径仍是 blocking，与日期无关）
      final DateTime localBefore = DateTime(2026, 10, 12, 23, 59);
      expect(workerSunsetEffectiveNow(localBefore, null), localBefore);
      expect(workerSunsetCanContinue(workerSunsetEffectiveNow(localBefore, null)), isFalse,
          reason: '本版立即阻断：回退本地时间也不放行');
      // 备用分支下这一层才决定结论（这条分支的语义没被改）
      expect(
        workerSunsetCanContinue(workerSunsetEffectiveNow(localBefore, null), blocking: false),
        isTrue,
      );
      final DateTime localAfter = DateTime(2026, 10, 14, 8);
      expect(workerSunsetEffectiveNow(localAfter, null), localAfter);
      expect(workerSunsetCanContinue(workerSunsetEffectiveNow(localAfter, null), blocking: false), isFalse);
    });

    test('⑥b 服务端给了时间 → 解析成设备本地时区（与 DateTime.now 同口径）', () {
      final DateTime? parsed = NetworkTime.parseDateHeader('Tue, 13 Oct 2026 00:00:00 GMT');
      expect(parsed, isNotNull);
      // HTTP Date 是 GMT 绝对时刻：+08:00 设备上"北京 10-13 08:00"
      expect(parsed!.toUtc(), DateTime.utc(2026, 10, 13));
      expect(parsed.isUtc, isFalse, reason: '解析结果必须转本地时区，否则与 DateTime.now() 比会差 8 小时');
      expect(workerSunsetEnded(parsed), isTrue);

      // 边界：GMT 10-12 15:59:59 = 北京 10-12 23:59:59 → 还没到期（差一秒）
      final DateTime? lastSecond = NetworkTime.parseDateHeader('Mon, 12 Oct 2026 15:59:59 GMT');
      expect(lastSecond, isNotNull);
      expect(lastSecond!.hour, 23, reason: '必须是本地小时：UTC+8 → 23 点');
      expect(workerSunsetEnded(lastSecond), isFalse, reason: '本地 10-12 23:59:59 仍算到期前（备用分支还放行）');
    });

    test('⑥b2 门禁层与纯函数一致：canContinue 恒 false、stopped 恒 true（注入任意时刻）', () {
      final gate = WorkerSunsetGate.instance;
      gate.debugNow = () => DateTime(2026, 9, 1); // 把时间调回过去
      expect(gate.canContinue, isFalse, reason: '立即阻断下改钟也放行不了');
      expect(gate.stopped, isTrue);
      gate.debugNow = () => DateTime(2026, 10, 12, 23, 59);
      expect(gate.canContinue, isFalse, reason: '旧宽限期内同样不放行');
      expect(gate.stopped, isTrue);
      gate.debugNow = () => DateTime(2030, 1, 1);
      expect(gate.canContinue, isFalse);
      // 门禁覆盖只影响判定，不影响"本次运行是否已放行"
      expect(gate.blocking, isTrue);
    });

    testWidgets('⑥b3 探测实现仍在（直接调用）：测试环境无网 → 优雅降级成 null、绝不抛异常', (tester) async {
      // ⚠️ 口径说明（免得后人以为这里"测得不够"）：core 的 `NetworkTime.probe` **刻意自建 Dio**
      // （不借用调用方实例，见其注释第 51-55 行），所以假适配器喂不进 Date 头 ——
      // "能解析出服务端时间"这一条由 ⑥b 用 `parseDateHeader` 逐字覆盖；
      // 这里覆盖的是它另一半契约：**拿不到就返回 null 且不抛异常**（调用方据此回退本地时间）。
      await tester.runAsync(() async {
        final DateTime? probed = await WorkerSunsetNetworkTime.probe(api: _api(withDateHeader: true));
        expect(probed, isNull, reason: 'flutter_test 里所有 HTTP 都返回 400 → 拿不到 Date 头 → null（不是抛异常）');
      });

      // 解析入口单独转发出来的那条照旧可用（纯函数，不需要网络）
      expect(WorkerSunsetNetworkTime.parseDateHeader('Mon, 12 Oct 2026 15:59:59 GMT'), isNotNull);
      expect(WorkerSunsetNetworkTime.parseDateHeader(null), isNull);
      expect(WorkerSunsetNetworkTime.parseDateHeader('not-a-date'), isNull);
    });

    test('⑥d 是否需要探测：立即阻断下不需要；备用分支仍需要（注入参数自证，逻辑没被删）', () {
      // 生产默认：blocking = kWorkerSunsetBlocking = true → 不发请求
      expect(workerSunsetShouldProbe(), isFalse, reason: '立即阻断 → 判定与时间无关 → 不必再探一次服务端时间');
      // 备用分支（开关改回 false）：那一层"防改钟"照旧生效
      expect(workerSunsetShouldProbe(blocking: false), isTrue, reason: '备用分支仍会探测（那一层没被删）');
      // 调用方已注入结果 / 本页不允许自探 / 探测开关关闭 → 都不探
      expect(workerSunsetShouldProbe(blocking: false, injected: true), isFalse);
      expect(workerSunsetShouldProbe(blocking: false, ownProbe: false), isFalse);
      expect(workerSunsetShouldProbe(blocking: false, probeEnabled: false), isFalse);
      // 立即阻断下这四种组合一律 false
      for (final injected in [true, false]) {
        for (final own in [true, false]) {
          for (final enabled in [true, false]) {
            expect(workerSunsetShouldProbe(injected: injected, ownProbe: own, probeEnabled: enabled), isFalse);
          }
        }
      }
    });

    testWidgets('⑥d2 立即阻断下即使放开探测开关：页面照常渲染（结论不依赖服务端时间）', (tester) async {
      WorkerSunsetProbe.enabled = true; // 生产默认就是开的
      addTearDown(() {
        WorkerSunsetProbe.enabled = false; // 交回本文件默认（见 setUp）
        NetworkTime.resetCache();
      });

      await tester.pumpWidget(_app(WorkerSunsetBlockPage(
        api: _api(),
        now: DateTime(2026, 10, 12, 23, 59), // 旧宽限期内
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });

    test('⑥c 备用分支的防改钟：判定取"本地 / 服务端"中较晚者', () {
      final DateTime localRolledBack = DateTime(2026, 9, 1); // 用户把手机日期改回 9 月
      final DateTime serverNow = DateTime(2026, 10, 20, 10); // 服务端早已过旧到期日
      final DateTime effective = workerSunsetEffectiveNow(localRolledBack, serverNow);
      expect(effective, serverNow, reason: '服务端更晚 → 以服务端为准');
      expect(workerSunsetCanContinue(effective, blocking: false), isFalse, reason: '备用分支下改钟绕过必须无效');
      // 反向：本地更晚（用户把时间调快）→ 以本地为准，只会更早被挡（方向安全）
      final DateTime localAhead = DateTime(2026, 12, 1);
      expect(workerSunsetEffectiveNow(localAhead, DateTime(2026, 10, 1)), localAhead);
      // 本地与服务端都在到期前 → 备用分支照常可继续（加了校验也没把宽限期砍掉）
      expect(
        workerSunsetCanContinue(workerSunsetEffectiveNow(DateTime(2026, 10, 10), DateTime(2026, 10, 11)), blocking: false),
        isTrue,
      );
      // 本版（默认参数）：无论怎么取，都不可继续
      expect(workerSunsetCanContinue(effective), isFalse);
      expect(workerSunsetCanContinue(workerSunsetEffectiveNow(DateTime(2026, 10, 10), DateTime(2026, 10, 11))), isFalse);
    });

    testWidgets('⑥d3 假适配器视角：阻断页挂载后本进程内**没有任何业务请求**（页面自带零请求）', (tester) async {
      // 注：core 的探测**自建 Dio**，假适配器看不到它 —— 所以"不发探测"由 ⑥d 的判定条件自证；
      // 这一条钉的是另一半事实：阻断页自己不取任何业务数据（挂载即渲染，不依赖接口成功）。
      final adapter = _RecordingAdapter(dateHeader: 'Mon, 12 Oct 2026 04:00:00 GMT');
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(
        api: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter),
        now: DateTime(2026, 10, 12, 23, 59), // 旧宽限期内
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(adapter.paths, isEmpty, reason: '阻断页没有任何业务请求（地址取运行期 AppConfig，不查接口）');
      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑥e 本地被调回过去 + 服务端时间已过期 → 同样只剩「前往下载」（现在时文案）', (tester) async {
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(
        api: _api(),
        now: DateTime(2026, 9, 1), // 本地被调回 9 月
        networkTime: DateTime(2026, 10, 20, 10), // 服务端时间：已过旧到期日
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(kWorkerSunsetContinueLabel), findsNothing, reason: '任何时间都不提供继续使用');
      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
      expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget, reason: '只剩「前往下载」');
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });
  });

  // ──────────────────────────────────────────────── 页面行为（注入日期出图同源）
  group('阻断页：过去 / 旧宽限期内 / 旧到期日 / 未来 都是同一页', () {
    testWidgets('① 注入"旧宽限期内"也照样阻断：没有「暂时继续使用」，进不去主界面', (tester) async {
      WorkerSunsetGate.instance.debugNow = () => DateTime(2026, 10, 12, 12); // v1.8.1 时这里还能继续用
      await tester.pumpWidget(_app(WorkerSunsetGateHost(child: const _FakeHome())));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(kWorkerSunsetContinueLabel), findsNothing,
          reason: '立即阻断版：旧宽限期内也不再给「暂时继续使用」');
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
      expect(find.text('主界面'), findsNothing, reason: '主界面不可达');

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('② 旧到期日 00:00：同样是"已停止服务"口径（与①逐字相同）', (tester) async {
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(api: _api(), now: DateTime(2026, 10, 13))));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
      expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
      expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('③ 未来：只剩「前往下载」；直接调 continueUsing 也进不去', (tester) async {
      final gate = WorkerSunsetGate.instance;
      gate.debugNow = () => DateTime(2030, 1, 1);
      // networkTime 直接给结果 → 页面对网络的依赖为零，用例确定性
      await tester.pumpWidget(_app(WorkerSunsetBlockPage(
        api: _api(),
        now: DateTime(2030, 1, 1),
        networkTime: DateTime(2030, 1, 1),
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
      expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);

      // 绕过 UI 直接调也无效（防"改了钟再点一次"这类尝试）
      gate.continueUsing();
      await tester.pump(const Duration(milliseconds: 100));
      expect(gate.blocking, isTrue);
      expect(gate.canContinue, isFalse);
      expect(gate.stopped, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('③b 门禁层就直接挡住：任何时刻 GateHost 都只渲染阻断页（主界面不可达）', (tester) async {
      final gate = WorkerSunsetGate.instance;
      for (final now in [DateTime(2026, 10, 6), DateTime(2026, 10, 12, 23, 59), DateTime(2030, 1, 1)]) {
        gate.debugNow = () => now;
        await tester.pumpWidget(_app(WorkerSunsetGateHost(child: const _FakeHome())));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('主界面'), findsNothing, reason: '$now 主界面永远进不去');
        expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
        expect(gate.canContinue, isFalse);

        gate.continueUsing(); // 直接调也无效
        await tester.pump(const Duration(milliseconds: 100));
        expect(gate.blocking, isTrue);
        expect(find.text('主界面'), findsNothing);
      }
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('④ 复制下载地址：提示是"已停止服务"口径（下载入口不能被自己关掉）', (tester) async {
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map)['text']}');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_app(MigrationNotice(
        variant: MigrationNoticeVariant.profile,
        now: DateTime(2026, 10, 20),
      )));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('复制下载地址'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(copied, [MigrationDownload.siteUrl], reason: '地址照旧能复制（下载入口不能被自己关掉）');
      expect(find.textContaining(kWorkerSunsetBlockedNote), findsWidgets);
      expect(find.textContaining('将于'), findsNothing, reason: '提示里也不许有未来时');

      AppToast.dismiss();
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  // ──────────────────────────────────────────────── ② 文案同步（引导条与阻断页同源）
  group('文案同步：引导条与阻断页同一份常量/函数', () {
    test('②a 引导条文案 = "已停止服务"（与阻断页同一个 [kWorkerSunsetBlockedNote]）', () {
      final String body = migrationBodyText(DateTime(2026, 10, 20));
      expect(body, contains('停止服务'));
      expect(body, contains(kWorkerSunsetBlockedNote), reason: '引导条与阻断页共用同一句停止服务说明');
      expect(body, isNot(contains('仍可继续使用')), reason: '本版不许再写"仍可继续使用"');
      expect(body, isNot(contains(kWorkerSunsetDateText)), reason: '日期不再出现在用户可见文案里');
      expect(body, isNot(contains('将于')));
    });

    test('②b 备用分支文案仍在（注入 blocking:false）：只描述机制、不给日期', () {
      final String body = migrationBodyText(DateTime(2026, 10, 10), blocking: false);
      expect(body, contains('本 App 仍可使用，但不再更新功能'));
      expect(body, isNot(contains(kWorkerSunsetBlockedNote)));
      expect(body, isNot(contains(kWorkerSunsetDateText)), reason: '备用分支也不许出现具体日期');
      expect(body, isNot(contains('将于')), reason: '不许出现"将于 … 停止服务"这类未来时');
    });

    testWidgets('②c 首页引导条：标题与正文都是"已停止服务"（注入日期不影响结论）', (tester) async {
      for (final now in [DateTime(2026, 10, 20), DateTime(2026, 9, 1), DateTime(2030, 1, 1)]) {
        await tester.pumpWidget(_app(MigrationNotice(now: now)));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text(kMigrationEndedHeadline), findsOneWidget, reason: '$now 标题应为已停止服务');
        expect(find.text(kMigrationHeadline), findsNothing, reason: '$now 不该显示"已合并进…App"这种进行时口径');
        expect(find.text(migrationBodyText(now)), findsOneWidget);
        expect(find.textContaining(kWorkerSunsetBlockedNote), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('②d 到期前注入（旧宽限期）= 与到期后逐字相同的口径：本版不再有"还剩 N 天"', (tester) async {
      final DateTime before = DateTime(2026, 10, 11, 9);
      await tester.pumpWidget(_app(MigrationNotice(now: before)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(migrationBodyText(before)), findsOneWidget);
      expect(migrationBodyText(before), migrationBodyText(DateTime(2026, 10, 20)),
          reason: '立即阻断：文案与日期无关（同一句），免得有人以为"还有几天"');
      expect(find.textContaining('还剩'), findsNothing, reason: '倒计时口径已随立即阻断删除');
      expect(tester.takeException(), isNull);
    });
  });
}

// ---------------------------------------------------------------- 测试脚手架

Widget _app(Widget home) => MiuixSystemTheme(
      child: MaterialApp(debugShowCheckedModeBanner: false, home: home),
    );

/// 被阻断的"主界面"替身（只验"进得去 / 进不去"，不牵连真实页面）
class _FakeHome extends StatelessWidget {
  const _FakeHome();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('主界面')));
}

AuthMe _me() => AuthMe.fromJson({
      'id': '77',
      'username': 'worker_demo',
      'uid': '8842019',
      'nickname': '陈默',
      'role': 'worker',
      'level': 2,
      'worker': {
        'workerNo': 'W-1042',
        'canTakeOrder': true,
        'canServeCustomer': false,
        'divisionPermissions': [
          {'divisionId': 1, 'name': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
        ],
      },
    });

/// 假通道：`/health` 按需要带 / 不带 `Date` 头（正是"服务端时间取得到 / 取不到"两种现实）
ApiClient _api({bool withDateHeader = true}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _RecordingAdapter(
    dateHeader: withDateHeader ? 'Mon, 12 Oct 2026 04:00:00 GMT' : null,
  );
  return ApiClient(dio: dio);
}

/// 假适配器：**记录每个被请求的路径**（"立即阻断下不再探测"靠它自证）
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.dateHeader});

  final String? dateHeader;

  /// 本次运行内被请求过的路径（顺序即发生顺序）
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'message': 'ok', 'data': {'status': 'up'}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        // 有值 = 服务端答话且给了标准 Date 头；null = 代理吞掉了 Date 头（要回退本地时间）
        if (dateHeader != null) 'date': [dateHeader!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
