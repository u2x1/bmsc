import 'dart:io';

import 'package:bmsc/util/feedback.dart';
import 'package:bmsc/util/logger.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _logger = LoggerUtils.getLogger('Feedback');

class FeedbackSubmitException implements Exception {
  final String message;
  FeedbackSubmitException(this.message);
  @override
  String toString() => message;
}

/// 应用内反馈通道：把用户反馈 POST 到 Cloudflare Worker，
/// 由 Worker 持 GitHub PAT 自动创建 Issue（见 workers/feedback/）。
class FeedbackService {
  /// 反馈接收端（Cloudflare Worker）地址。
  /// 注：使用自定义域名（*.workers.dev 在国内被 DNS 污染不可达）。
  /// 也可用 `--dart-define=FEEDBACK_ENDPOINT=...` 覆盖。
  static const String endpoint = String.fromEnvironment('FEEDBACK_ENDPOINT',
      defaultValue: 'https://bmsc-api.u2x1.work');

  /// 与 Worker 侧 FEEDBACK_TOKEN 对应的令牌（可选，防滥用）
  static const String _token =
      String.fromEnvironment('FEEDBACK_TOKEN', defaultValue: '');

  static const int maxContentLength = FeedbackPayload.maxContentLength;

  static bool get isConfigured => endpoint.isNotEmpty;

  /// 提交反馈，成功返回创建的 GitHub Issue URL
  static Future<String> submit({
    required String content,
    String contact = '',
    String logs = '',
  }) async {
    if (!isConfigured) {
      throw FeedbackSubmitException('反馈服务尚未配置');
    }
    final packageInfo = await PackageInfo.fromPlatform();
    final payload = FeedbackPayload.build(
      content: content,
      contact: contact,
      logs: logs,
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
      platform: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
    );
    try {
      _logger.info('submitting feedback');
      final resp = await Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      )).post(
        endpoint,
        data: payload,
        options: Options(headers: {
          if (_token.isNotEmpty) 'X-Feedback-Token': _token,
        }),
      );
      final url = resp.data?['url'];
      if (url is! String || url.isEmpty) {
        throw FeedbackSubmitException('服务返回异常');
      }
      _logger.info('feedback submitted: $url');
      return url;
    } on DioException catch (e) {
      _logger.severe('feedback submit failed: $e');
      final data = e.response?.data;
      final msg = data is Map ? data['error'] : null;
      throw FeedbackSubmitException(msg is String ? msg : '网络请求失败，请稍后重试');
    }
  }
}
