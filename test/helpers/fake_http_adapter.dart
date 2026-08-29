import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 记录请求并返回预设响应的 dio adapter（单元测试用，不引第三方 mock 库）。
///
/// 用法：
/// ```dart
/// adapter.onPath('/x/web-interface/view', {
///   'status': 200,
///   'body': {'code': 0, 'data': {...}},
///   'headers': {'set-cookie': ['SESSDATA=...']},
/// });
/// api.dio.httpClientAdapter = adapter;
/// ```
class FakeHttpAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic>> _routes = {};

  /// 捕获的所有请求（按发起顺序），断言请求头/Query 用
  final List<RequestOptions> requests = [];

  /// 未匹配路由时的默认响应
  Map<String, dynamic> fallback = {
    'status': 200,
    'body': {'code': -404, 'message': 'no route registered for ${''}'},
  };

  /// 按 URL path 注册响应（自动归一化：绝对 URL → path）
  void onPath(String path, Map<String, dynamic> response) {
    _routes[_norm(path)] = response;
  }

  static String _norm(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.path;
    return url;
  }

  void clear() {
    _routes.clear();
    requests.clear();
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final resp = _routes[_norm(options.path)] ?? fallback;
    final body = resp['body'];
    final text = body is String ? body : jsonEncode(body);
    final headers =
        Map<String, List<String>>.from((resp['headers'] as Map?) ?? const {});
    if (body is! String) {
      // dio 依据 content-type 决定是否 JSON 解码；fake 响应需显式声明
      headers.putIfAbsent('content-type',
          () => ['application/json; charset=utf-8']);
    }
    return ResponseBody.fromString(text, resp['status'] as int? ?? 200,
        headers: headers);
  }

  @override
  void close({bool force = false}) {}
}