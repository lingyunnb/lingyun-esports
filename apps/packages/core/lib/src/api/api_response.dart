/// 统一响应结构（docs/03）
class ApiResponse<T> {
  const ApiResponse({
    required this.code,
    required this.message,
    required this.data,
    required this.requestId,
    required this.timestamp,
  });

  final int code;
  final String message;
  final T? data;
  final String requestId;
  final int timestamp;

  bool get ok => code == 0;

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic json)? parseData,
  ) {
    return ApiResponse<T>(
      code: json['code'] as int? ?? -1,
      message: json['message'] as String? ?? '',
      data: json['data'] == null ? null : (parseData == null ? json['data'] as T : parseData(json['data'])),
      requestId: json['requestId'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
    );
  }
}

/// 分页结构（docs/03）
class PageResult<T> {
  const PageResult({required this.list, required this.total, required this.page, required this.pageSize});

  final List<T> list;
  final int total;
  final int page;
  final int pageSize;

  factory PageResult.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic json) parseItem,
  ) {
    return PageResult<T>(
      list: (json['list'] as List<dynamic>? ?? []).map((e) => parseItem(e)).toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      pageSize: json['pageSize'] as int? ?? 20,
    );
  }
}
