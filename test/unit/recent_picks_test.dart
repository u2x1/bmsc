import 'dart:math';

import 'package:bmsc/model/play_stat.dart';
import 'package:bmsc/util/recent_picks.dart';
import 'package:test/test.dart';

PlayStat _stat(
  String bvid, {
  int playCount = 1,
  int totalPlayTime = 100,
  int lastPlayed = 0,
}) =>
    PlayStat(
      bvid: bvid,
      lastPlayed: lastPlayed,
      totalPlayTime: totalPlayTime,
      playCount: playCount,
    );

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  group('recentPickScore（推荐分值）', () {
    test('最近播放越近分越高（24h 半衰期）', () {
      final justNow = _stat('a', lastPlayed: now);
      final dayAgo = _stat('b', lastPlayed: now - 24 * 3600000);
      final weekAgo = _stat('c', lastPlayed: now - 7 * 24 * 3600000);
      double score(PlayStat s) =>
          recentPickScore(s, maxCount: 10, maxTime: 1000, nowMs: now);
      expect(score(justNow), greaterThan(score(dayAgo)));
      expect(score(dayAgo), greaterThan(score(weekAgo)));
    });

    test('播放次数与时长更高分更高（log 归一，头部差距被压缩）', () {
      double score(PlayStat s) =>
          recentPickScore(s, maxCount: 100, maxTime: 10000, nowMs: now);
      final hot = _stat('a', playCount: 100, totalPlayTime: 10000, lastPlayed: now);
      final cold = _stat('b', playCount: 1, totalPlayTime: 10, lastPlayed: now);
      expect(score(hot), greaterThan(score(cold)));
      // log 归一：100 倍次数差距不会带来 100 倍分值差距
      final countOnly = recentPickScore(
              _stat('c', playCount: 100, totalPlayTime: 1, lastPlayed: 0),
              maxCount: 100, maxTime: 10000, nowMs: now) -
          recentPickScore(_stat('d', playCount: 1, totalPlayTime: 1, lastPlayed: 0),
              maxCount: 100, maxTime: 10000, nowMs: now);
      expect(countOnly, lessThan(0.5));
    });
  });

  group('pickRecentListening（加权随机选取）', () {
    test('池子不足 take 时全部返回（有洗牌）', () {
      final pool = [_stat('a'), _stat('b'), _stat('c')];
      final picked = pickRecentListening(pool, take: 27, random: Random(1));
      expect(picked.length, 3);
      expect(picked.map((s) => s.bvid).toSet(), {'a', 'b', 'c'});
    });

    test('空池返回空，全零数据不崩溃', () {
      expect(pickRecentListening([], random: Random(1)), isEmpty);
      final zeroed = List.generate(30, (i) => _stat('z$i'));
      final picked = pickRecentListening(zeroed, take: 27, random: Random(1));
      expect(picked.length, 27);
    });

    test('同一随机种子结果可复现', () {
      final pool = List.generate(
          50, (i) => _stat('b$i', playCount: i + 1, lastPlayed: now));
      final a = pickRecentListening(pool, random: Random(42));
      final b = pickRecentListening(pool, random: Random(42));
      expect(a.map((s) => s.bvid).toList(), b.map((s) => s.bvid).toList());
    });

    test('热门曲目大概率入选，冷门曲目偶尔回归', () {
      final hot = _stat('hot',
          playCount: 100, totalPlayTime: 10000, lastPlayed: now);
      final pool = [
        hot,
        for (var i = 0; i < 50; i++)
          _stat('cold$i',
              playCount: 1,
              totalPlayTime: 10,
              lastPlayed: now - 30 * 24 * 3600000),
      ];
      final rnd = Random(7);
      var hotPicked = 0;
      final coldPickedCount = <String, int>{};
      for (var t = 0; t < 400; t++) {
        final picked = pickRecentListening(pool, take: 27, random: rnd);
        if (picked.contains(hot)) hotPicked++;
        for (final s in picked) {
          coldPickedCount[s.bvid] = (coldPickedCount[s.bvid] ?? 0) + 1;
        }
      }
      expect(hotPicked, greaterThan(390));
      // 随机性：50 首冷门在 400 轮中应几乎都被抽到至少一次
      expect(coldPickedCount.length, greaterThan(45));
    });
  });
}
