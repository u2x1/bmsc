import 'dart:math';

import '../model/play_stat.dart';

/// 「最近在听」推荐分值：综合三个维度——
/// - 最近播放时间（权重 0.45）：半衰期 24h 的指数衰减，越近越高；
/// - 播放次数（权重 0.30）：log1p 归一，压缩头部差距给长尾机会；
/// - 累计播放时长（权重 0.25）：log1p 归一，偏好真正听完的内容。
double recentPickScore(
  PlayStat s, {
  required int maxCount,
  required int maxTime,
  int? nowMs,
}) =>
    playStatScore(
      lastPlayed: s.lastPlayed,
      playCount: s.playCount,
      totalPlayTime: s.totalPlayTime,
      maxCount: maxCount,
      maxTime: maxTime,
      nowMs: nowMs,
    );

/// [recentPickScore] 的裸数值版本：不依赖 [PlayStat] 对象，
/// 供收藏夹封面挑选等直接持有统计字段的场景复用。
double playStatScore({
  required int lastPlayed,
  required int playCount,
  required int totalPlayTime,
  required int maxCount,
  required int maxTime,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final countScore =
      maxCount > 0 ? (log(1 + playCount) / log(1 + maxCount)) : 0.0;
  final timeScore =
      maxTime > 0 ? (log(1 + totalPlayTime) / log(1 + maxTime)) : 0.0;
  final hoursAgo = max(0, now - lastPlayed) / 3600000.0;
  final recencyScore = pow(0.5, hoursAgo / 24).toDouble();
  return 0.45 * recencyScore + 0.30 * countScore + 0.25 * timeScore;
}

/// 从播放统计池中为「最近在听」九宫格挑 [take] 首：
/// 不按单纯时间序（避免每次进入主页都是同样九首），而是按 [recentPickScore]
/// 分值为权做无放回加权随机抽样（Efraimidis–Spirakis：key = u^(1/w)，
/// 按 key 降序取前 take），分值高的曲目大概率入选但不保证——
/// 近期常听的常客居多，尘封旧爱偶尔回归。入选后再洗牌，页内位置不固定。
///
/// 传入 [random] 可复现（测试用）。
List<PlayStat> pickRecentListening(
  List<PlayStat> pool, {
  int take = 27,
  Random? random,
}) {
  final rnd = random ?? Random();
  if (pool.length <= take) {
    return List.of(pool)..shuffle(rnd);
  }
  final maxCount = pool.fold(0, (m, s) => max(m, s.playCount));
  final maxTime = pool.fold(0, (m, s) => max(m, s.totalPlayTime));
  final now = DateTime.now().millisecondsSinceEpoch;
  final keyed = <(PlayStat, double)>[
    for (final s in pool)
      (
        s,
        pow(rnd.nextDouble(),
                1.0 / max(recentPickScore(s, maxCount: maxCount, maxTime: maxTime, nowMs: now), 1e-6))
            .toDouble(),
      ),
  ];
  keyed.sort((a, b) => b.$2.compareTo(a.$2));
  return keyed.take(take).map((e) => e.$1).toList()..shuffle(rnd);
}
