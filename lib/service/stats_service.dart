import 'dart:io';
import 'dart:math';

import 'package:bmsc/service/feedback_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/stats.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _logger = LoggerUtils.getLogger('Stats');

/// 匿名使用统计：每日一次心跳（匿名 ID + 版本 + 平台），
/// 设置 → 隐私 可关闭。不含任何个人信息，失败静默不打扰用户。
class StatsService {
  static const _enabledKey = 'stats_enabled';
  static const _installIdKey = 'stats_install_id';
  static const _lastPingDayKey = 'stats_last_ping_day';

  static Future<bool> getEnabled() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool(_enabledKey, value);
  }

  /// 每日一次心跳；未开启 / 今日已上报 / 未配置端点时跳过。
  /// 任何失败静默（仅记日志，下一天重试），绝不打断启动。
  static Future<void> maybePing() async {
    try {
      final prefs = await SharedPreferencesService.instance;
      final today = utcDay(DateTime.now());
      if (!shouldPing(
        enabled: prefs.getBool(_enabledKey) ?? true,
        lastPingDay: prefs.getString(_lastPingDayKey),
        today: today,
      )) {
        return;
      }
      if (!FeedbackService.isConfigured) return;

      var id = prefs.getString(_installIdKey);
      if (id == null) {
        id = generateInstallId(Random.secure());
        await prefs.setString(_installIdKey, id);
      }
      final packageInfo = await PackageInfo.fromPlatform();
      _logger.info('daily ping');
      // 与反馈通道同一 Worker（bmsc-api），/ping 路由
      await Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      )).post('${FeedbackService.endpoint}/ping', data: {
        'id': id,
        'version': packageInfo.version,
        'platform': Platform.operatingSystem,
      });
      await prefs.setString(_lastPingDayKey, today);
    } catch (e) {
      _logger.fine('daily ping failed: $e');
    }
  }
}
