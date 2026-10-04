/// 反馈 payload 组装（纯 Dart，无 Flutter 依赖，便于单元测试）。
/// 协议见 workers/feedback/README.md。
class FeedbackPayload {
  static const int maxContentLength = 4000;
  static const int maxLogsLength = 30000;

  /// bilibili 凭据 / Bearer token 脱敏。日志可能混入 Cookie 片段，
  /// 公开到 GitHub Issue 前必须打码（Worker 侧有同样规则兜底）。
  static final _sensitivePattern = RegExp(
    "(^|[^A-Za-z0-9_])((?:SESSDATA|bili_jct|DedeUserID(?:__ckMd5)?|ac_time_value|bili_ticket|access_key|access_token|refresh_token|csrf|sid)(\"?\\s*[=:]\\s*\"?))[^\\s;&,\"']+",
    caseSensitive: false,
  );
  static final _bearerPattern = RegExp(
    r'(^|[^A-Za-z0-9_])(Bearer\s+)[A-Za-z0-9\-._~+/]+=*',
    caseSensitive: false,
  );

  // Dart 的 replaceAll 替换串不解释 $1 组引用（与 JS 不同），需用 replaceAllMapped
  static String sanitize(String text) => text
      .replaceAllMapped(
          _sensitivePattern, (m) => '${m[1]}${m[2]}***')
      .replaceAllMapped(_bearerPattern, (m) => '${m[1]}${m[2]}***');

  /// 日志保留尾部（最新日志对排查最有用），超长截断并加标记
  static String tailLogs(String logs) {
    if (logs.length <= maxLogsLength) return logs;
    return '[...已截断，仅保留尾部...]\n'
        '${logs.substring(logs.length - maxLogsLength)}';
  }

  /// 组装提交 payload
  static Map<String, dynamic> build({
    required String content,
    String contact = '',
    String logs = '',
    required String version,
    required String buildNumber,
    required String platform,
    required String osVersion,
  }) {
    final trimmedContact = contact.trim();
    final cleanLogs = tailLogs(sanitize(logs)).trim();
    return {
      'content': content.trim(),
      if (trimmedContact.isNotEmpty) 'contact': trimmedContact,
      if (cleanLogs.isNotEmpty) 'logs': cleanLogs,
      'meta': {
        'version': version,
        'buildNumber': buildNumber,
        'platform': platform,
        'osVersion': osVersion,
      },
    };
  }
}
