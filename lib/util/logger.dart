import 'package:logging/logging.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

import '../service/shared_preferences_service.dart';

class LoggerUtils {
  static const String _loggingEnabledKey = 'logging_enabled';
  static const String _loggingLevelKey = 'logging_level';
  static final List<LogRecord> _logs = [];
  static final _logStream = StreamController<LogRecord>.broadcast();
  static bool _isLoggingEnabled = kDebugMode;

  static Future<void> init() async {
    final prefs = await SharedPreferencesService.instance;
    _isLoggingEnabled = prefs.getBool(_loggingEnabledKey) ?? kDebugMode;
    Logger.root.level = Level.ALL;
    final levelName = prefs.getString(_loggingLevelKey);
    if (levelName != null) {
      Logger.root.level = Level.LEVELS.firstWhere((e) => e.name == levelName);
    }

    Logger.root.onRecord.listen((record) {
      if (!_isLoggingEnabled) return;
      _logs.add(record);
      _logStream.add(record);

      if (!kDebugMode) {
        return;
      }
      debugPrint(
          '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
      if (record.error != null) {
        debugPrint('Error: ${record.error}');
      }
      if (record.stackTrace != null) {
        debugPrint('Stack trace:\n${record.stackTrace}');
      }
    });
  }

  static Logger getLogger(String module) {
    return Logger(module);
  }

  static List<LogRecord> get logs => _logs;
  static Stream<LogRecord> get logStream => _logStream.stream;

  /// 将日志格式化为纯文本（按时间正序），可传入子集（如选中范围）。
  static String formatLogs([Iterable<LogRecord>? records]) {
    final buffer = StringBuffer();
    for (final record in records ?? _logs) {
      buffer.writeln(
          '${record.time} [${record.level.name}] [${record.loggerName}] ${record.message}');
      if (record.error != null) {
        buffer.writeln('Error: ${record.error}');
      }
      if (record.stackTrace != null) {
        buffer.writeln('Stack trace:\n${record.stackTrace}');
      }
    }
    return buffer.toString();
  }

  static void clear() {
    _logs.clear();
  }

  static bool get isLoggingEnabled => _isLoggingEnabled;

  static Future<void> setLoggingEnabled(bool value) async {
    _isLoggingEnabled = value;
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool(_loggingEnabledKey, value);
  }

  static Future<void> setLoggingLevel(Level level) async {
    Logger.root.level = level;
    final prefs = await SharedPreferencesService.instance;
    await prefs.setString(_loggingLevelKey, level.name);
  }

  static Future<void> dispose() async {
    _logStream.close();
  }
}
