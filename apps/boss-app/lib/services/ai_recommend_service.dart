/// 找陪玩 · AI 按需求推荐打手 —— 数据源（`POST /user/ai/recommend`）
///
/// 与 `ai_chat_service.dart` 同一套做法：**页面只依赖抽象 [AiRecommendSource]**，
/// 后端字段微调时只改本文件；单元测试注入假数据源，不需要真后端。
///
/// 接口契约（2026-10-04 与后端联调确认版）：
/// - `POST /user/ai/recommend` body `{need, divisionId?}` → **201**
///   `{reply, picks:[{workerId,name,intro,divisionName,reason}], degraded, cached, conversationId?, messageId?}`
/// - `degraded=true`：模型超时/报错，服务端已按介绍规则推荐（文案与 picks 仍可用，页面加一行灰字说明）
/// - 错误码沿用 AI 客服那一套（`AI_RATE_LIMITED` / `AI_BUSY` / `AI_DISABLED` / `AI_INPUT_TOO_LONG`）
///   → 复用 [friendlyAiError] 转成能直接给用户看的中文
/// - **展示规则（负责人硬规则，docs/21 + CLAUDE.md 结构规则 6）**：
///   推荐卡里只有 头像 / 名字 / 介绍 / 一句推荐理由；服务端也只返回这四个字段，
///   没有价格、评分、等级、标签、下单人数、在线状态 —— 客户端不得自己造。
library;

import 'package:fish_core/fish_core.dart';

/// 找陪玩页搜索框的提示文案（设计稿口径：说需求，不下命令）
const String kAiRecommendHint = '说说你的需求，让祁小山帮你挑';

/// 入口引导行文案（任务书原文）
const String kAskQishanLabel = '有疑问？问祁小山';

/// 一条被推荐的打手（**只有展示级四字段**：名字 + 介绍 + 推荐理由（+ 分部名，仅用于说明理由来源））
class AiPick {
  const AiPick({
    required this.workerId,
    required this.name,
    required this.intro,
    required this.divisionName,
    required this.reason,
  });

  final String workerId;
  final String name;

  /// 介绍（管理端填写，服务端原文下发）
  final String intro;

  /// 所属分部名（理由可能引用它；卡片不单独展示分部）
  final String divisionName;

  /// 一句推荐理由（≤30 字，来自介绍或分部；服务端已保证非空）
  final String reason;

  /// 宽容解析：字段缺失不抛错，缺失的名字用「陪玩」兜底（与列表卡同一口径）
  factory AiPick.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? json['nickname'] ?? ''}'.trim();
    return AiPick(
      workerId: '${json['workerId'] ?? json['id'] ?? ''}'.trim(),
      name: name.isEmpty ? '陪玩' : name,
      intro: '${json['intro'] ?? ''}'.trim(),
      divisionName: '${json['divisionName'] ?? ''}'.trim(),
      reason: '${json['reason'] ?? ''}'.trim(),
    );
  }
}

/// 一次推荐的结果（`reply` 是祁小山的口语化回答；`picks` 是挑中的打手，可能为空）
class AiRecommendResult {
  const AiRecommendResult({
    required this.reply,
    this.picks = const [],
    this.degraded = false,
    this.cached = false,
  });

  final String reply;
  final List<AiPick> picks;

  /// 服务端降级（模型超时/报错 → 按介绍规则推荐）：页面加一行灰字说明，不谎称是 AI 精选
  final bool degraded;

  /// 命中 30 秒同问缓存
  final bool cached;

  factory AiRecommendResult.fromJson(Map<String, dynamic>? json) {
    final raw = (json?['picks'] as List<dynamic>? ?? const []);
    return AiRecommendResult(
      reply: '${json?['reply'] ?? ''}'.trim(),
      picks: raw.whereType<Map>().map((e) => AiPick.fromJson(e.cast<String, dynamic>())).toList(),
      degraded: json?['degraded'] == true,
      cached: json?['cached'] == true,
    );
  }
}

/// 推荐数据源（页面唯一依赖）
abstract class AiRecommendSource {
  /// `POST /user/ai/recommend`：按需求挑打手（服务端最多 20 秒内一定给答复）
  Future<AiRecommendResult> recommend(String token, {required String need, String? divisionId});
}

/// HTTP 实现（走既有 [ApiClient]：鉴权/重试/错误码统一）
class HttpAiRecommendSource implements AiRecommendSource {
  HttpAiRecommendSource({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  @override
  Future<AiRecommendResult> recommend(String token, {required String need, String? divisionId}) async {
    final resp = await _api.request('POST', '/user/ai/recommend', token: token, data: {
      'need': need,
      if (divisionId != null && divisionId.isNotEmpty) 'divisionId': divisionId,
    });
    return AiRecommendResult.fromJson(resp['data'] as Map<String, dynamic>?);
  }
}
