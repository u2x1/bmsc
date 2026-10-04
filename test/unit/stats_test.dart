import 'dart:math';

import 'package:bmsc/util/stats.dart';
import 'package:test/test.dart';

/// 使用统计纯函数测试（离线、确定性）：
/// 匿名 ID 生成、UTC 日期、每日心跳去重判断。
void main() {
  group('generateInstallId（匿名安装 ID）', () {
    test('32 位小写 hex', () {
      final id = generateInstallId(Random.secure());
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('两次生成不同（随机性）', () {
      final a = generateInstallId(Random.secure());
      final b = generateInstallId(Random.secure());
      expect(a, isNot(b));
    });
  });

  group('utcDay（UTC 日期）', () {
    test('格式 YYYY-MM-DD', () {
      expect(utcDay(DateTime(2026, 10, 4, 12, 30)),
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('按 UTC 取日而非本地日（跨日界线场景）', () {
      // 本地时间 2026-10-04 23:30（UTC+8）→ UTC 当天 15:30，仍属 10-04
      final local = DateTime(2026, 10, 4, 23, 30);
      final expectedUtc = local.toUtc();
      expect(utcDay(local),
          expectedUtc.toIso8601String().substring(0, 10));
    });
  });

  group('shouldPing（每日心跳判断）', () {
    test('开启且今日未上报 → true', () {
      expect(
          shouldPing(enabled: true, lastPingDay: '2026-10-03', today: '2026-10-04'),
          isTrue);
      expect(
          shouldPing(enabled: true, lastPingDay: null, today: '2026-10-04'),
          isTrue);
    });

    test('今日已上报 → false', () {
      expect(
          shouldPing(enabled: true, lastPingDay: '2026-10-04', today: '2026-10-04'),
          isFalse);
    });

    test('关闭统计 → false', () {
      expect(
          shouldPing(enabled: false, lastPingDay: null, today: '2026-10-04'),
          isFalse);
    });
  });
}
