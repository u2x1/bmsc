import 'dart:math';

/// 使用统计纯函数（匿名、无个人信息；协议见 workers/feedback/README.md）

/// 生成匿名安装 ID：32 位小写 hex（16 字节随机），
/// 与设备、账号无任何关联
String generateInstallId(Random random) =>
    List.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

/// UTC 日期（YYYY-MM-DD），心跳按此去重（与服务端一致用 UTC）
String utcDay(DateTime now) => now.toUtc().toIso8601String().substring(0, 10);

/// 是否需要今日心跳：开启统计且今日未上报
bool shouldPing({
  required bool enabled,
  required String? lastPingDay,
  required String today,
}) =>
    enabled && lastPingDay != today;
