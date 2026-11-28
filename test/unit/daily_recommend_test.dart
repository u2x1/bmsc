import 'package:bmsc/model/meta.dart';
import 'package:bmsc/util/daily_recommend.dart';
import 'package:test/test.dart';

Meta _meta(String bvid, {int duration = 200}) => Meta(
      bvid: bvid,
      aid: bvid.hashCode,
      title: bvid,
      artist: 'up',
      mid: 1,
      duration: duration,
      artUri: '',
    );

List<Meta> _videos(String prefix, int n) =>
    [for (var i = 0; i < n; i++) _meta('$prefix$i')];

/// 每日推荐挑选（issue #24：只出 7～8 首、越刷越少）
void main() {
  group('pickRecommendations', () {
    test('种子少于目标条数时每个种子出多首，凑满目标', () {
      // 原实现每个种子最多一首：8 个种子封顶 8 首
      final related = [for (var s = 0; s < 8; s++) _videos('s$s-', 10)];
      final picked = pickRecommendations(related, count: 30);
      expect(picked.length, 30);
      expect(picked.map((v) => v.bvid).toSet().length, 30);
    });

    test('按种子轮转挑选，来源分散', () {
      final related = [_videos('a', 5), _videos('b', 5), _videos('c', 5)];
      final picked = pickRecommendations(related, count: 6);
      expect(picked.map((v) => v.bvid).toList(),
          ['a0', 'b0', 'c0', 'a1', 'b1', 'c1']);
    });

    test('跳过短视频、排除项与跨种子重复', () {
      final related = [
        [_meta('short', duration: 30), _meta('fav'), _meta('dup'), _meta('a')],
        [_meta('dup'), _meta('b')],
      ];
      final picked = pickRecommendations(related, count: 10, exclude: {'fav'});
      expect(picked.map((v) => v.bvid).toList(), ['dup', 'b', 'a']);
    });

    test('优先未推荐过的；不够时用近期推荐过的补足而非缩短列表', () {
      final related = [_videos('x', 4)];
      final fresh = pickRecommendations(related, count: 2, seen: {'x0'});
      expect(fresh.map((v) => v.bvid).toList(), ['x1', 'x2']);

      final filled =
          pickRecommendations(related, count: 4, seen: {'x0', 'x1', 'x2'});
      expect(filled.map((v) => v.bvid).toList(), ['x3', 'x0', 'x1', 'x2']);
    });

    test('部分种子拉取失败（空列表）不影响其余种子凑满', () {
      final related = [const <Meta>[], _videos('ok', 40), const <Meta>[]];
      expect(pickRecommendations(related, count: 30).length, 30);
    });

    test('无候选时返回空列表', () {
      expect(pickRecommendations(const [], count: 30), isEmpty);
      expect(pickRecommendations([const <Meta>[]], count: 30), isEmpty);
    });
  });

  group('appendRecommendHistory', () {
    test('追加到末尾并去重，再次推荐的移到最新位置', () {
      expect(appendRecommendHistory(['a', 'b', 'c'], ['b', 'd']),
          ['a', 'c', 'b', 'd']);
    });

    test('超过上限时丢弃最旧的', () {
      final history = [for (var i = 0; i < 10; i++) 'h$i'];
      expect(appendRecommendHistory(history, ['n0', 'n1'], cap: 5),
          ['h7', 'h8', 'h9', 'n0', 'n1']);
    });
  });

  test('音乐区白名单包含翻唱/VOCALOID/音乐现场', () {
    expect(recommendMusicTids, containsAll([29, 30, 31]));
    expect(recommendMusicTids, isNot(contains(244)));
  });
}
