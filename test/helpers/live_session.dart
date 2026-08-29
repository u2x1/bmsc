import 'dart:convert';
import 'dart:io';

import 'package:bmsc/api/bilibili.dart';
import 'package:qr/qr.dart';

/// live 测试登录态管理：一次性扫码获取登录态，缓存复用，把人工操作降到最低。
///
/// 优先级：
/// 1. 缓存文件 test/credentials/live_session.json（SESSDATA 有效期~180天，免重复操作）
/// 2. 环境变量 BMSC_COOKIE（一次性覆盖，供 CI/特殊场景）
/// 3. 交互式 TV 扫码登录（须 BMSC_LOGIN=1 显式开启；手机 App 扫码一次即可）
class LiveSession {
  final String cookie;
  final String accessToken;
  final String refreshToken;
  final String platform; // tv / android
  final DateTime savedAt;

  LiveSession({
    required this.cookie,
    this.accessToken = '',
    this.refreshToken = '',
    this.platform = 'tv',
    DateTime? savedAt,
  }) : savedAt = savedAt ?? DateTime.now();

  static const sessionDir = 'test/credentials';
  static const sessionFile = '$sessionDir/live_session.json';

  Map<String, String> get cookies {
    final map = <String, String>{};
    for (final part in cookie.split(';')) {
      final idx = part.indexOf('=');
      if (idx > 0) {
        map[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
      }
    }
    return map;
  }

  bool get hasAccessToken => accessToken.isNotEmpty;

  /// 用 nav/myinfo 验证登录态是否仍有效（-101 表示失效）
  Future<bool> isValid(BilibiliAPI api) async {
    try {
      await api.setCookie(cookie);
      final info = await api.getMyInfo();
      return info != null && info.mid > 0;
    } catch (_) {
      return false;
    }
  }

  static LiveSession? loadFromFile() {
    try {
      final file = File(sessionFile);
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return LiveSession(
        cookie: json['cookie'] ?? '',
        accessToken: json['access_token'] ?? '',
        refreshToken: json['refresh_token'] ?? '',
        platform: json['platform'] ?? 'tv',
        savedAt:
            DateTime.tryParse(json['saved_at'] ?? '') ?? DateTime.now(),
      );
    } catch (e) {
      stderr.writeln('[live] 凭据文件解析失败: $e');
      return null;
    }
  }

  void saveToFile() {
    try {
      final dir = Directory(sessionDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(sessionFile).writeAsStringSync(jsonEncode({
        'cookie': cookie,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'platform': platform,
        'saved_at': savedAt.toIso8601String(),
      }));
      stdout.writeln('      已缓存登录态到 $sessionFile（有效期内自动复用，无需重复扫码）');
    } catch (e) {
      stderr.writeln('[live] 写入凭据文件失败: $e');
    }
  }

  /// 获取可用登录态；无法获得时返回 null（登录态测试自动降级为记录行为）
  static Future<LiveSession?> ensure(BilibiliAPI api) async {
    // 1. 缓存文件
    final cached = loadFromFile();
    if (cached != null && cached.cookie.isNotEmpty) {
      if (await cached.isValid(api)) {
        stdout.writeln('[live] 复用缓存登录态（${cached.savedAt.toLocal()} 保存）');
        return cached;
      }
      stdout.writeln('[live] 缓存登录态已失效，尝试重新获取...');
    }
    // 2. 环境变量（CI / 一次性场景）
    final envCookie = Platform.environment['BMSC_COOKIE'];
    if (envCookie != null && envCookie.isNotEmpty) {
      final session = LiveSession(cookie: envCookie, platform: 'env');
      if (await session.isValid(api)) {
        return session;
      }
      stderr.writeln('[live] BMSC_COOKIE 无效（未登录或已过期）');
      return null;
    }
    // 3. 交互式扫码（须显式开启）
    if (Platform.environment['BMSC_LOGIN'] == '1') {
      return _qrLogin(api);
    }
    if (cached == null) {
      stdout.writeln('[live] 无缓存登录态。设置 BMSC_LOGIN=1 走扫码登录（一次性），'
          '或提供 BMSC_COOKIE 覆盖。');
    }
    return null;
  }

  /// TV 二维码扫码登录（人工操作仅剩"手机扫一下"）
  static Future<LiveSession?> _qrLogin(BilibiliAPI api) async {
    stdout.writeln('[live] === 请用哔哩哔哩手机 App 扫描下方二维码（有效期 3 分钟） ===');
    final info = await api.getTvQrcodeLoginInfo();
    if (info == null || info.url.isEmpty) {
      stderr.writeln('[live] 获取二维码失败，请检查网络后重试');
      return null;
    }
    printQr(info.url);
    stdout.writeln('[live] 备用：浏览器打开 ${info.url}');

    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      final result = await api.checkTvQrcodeLoginStatus(info.authCode);
      if (result != null && result.code == 0) {
        final session = LiveSession(
          cookie: result.cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
          accessToken: result.accessToken,
          refreshToken: result.refreshToken,
          platform: 'tv',
        );
        session.saveToFile();
        return session;
      }
      if (result != null && result.code == 86090) {
        stdout.writeln('[live] 已扫码，请在手机端确认...');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    stderr.writeln('[live] 扫码超时（3 分钟），可重跑再次尝试');
    return null;
  }

  /// 终端 ASCII 二维码（半块字符渲染，每行 2 个模块）
  static void printQr(String url) {
    try {
      final qrCode = QrCode.fromData(
        data: url,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      final image = QrImage(qrCode);
      final size = qrCode.moduleCount;
      final buf = StringBuffer();
      for (int y = 0; y < size; y += 2) {
        final sb = StringBuffer('      '); // 左侧 quiet zone
        for (int x = 0; x < size; x++) {
          final top = image.isDark(y, x);
          final bottom = (y + 1 < size) && image.isDark(y + 1, x);
          sb.write(top && bottom
              ? '█'
              : top
                  ? '▀'
                  : bottom
                      ? '▄'
                      : ' ');
        }
        buf.writeln(sb);
      }
      stdout.writeln(buf);
    } catch (e) {
      stdout.writeln('[live] 终端渲染二维码失败（${e.runtimeType}）');
    }
  }
}