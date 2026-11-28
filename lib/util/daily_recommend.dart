import '../model/meta.dart';

/// 每日推荐的目标条数
const int dailyRecommendCount = 30;

/// 生成每日推荐时抽取的收藏种子数：每个种子的相关视频可出多首，
/// 不需要 30 个种子；请求数减半，降低连续刷新触发风控（412/-352）的概率
const int dailyRecommendSeedCount = 15;

/// 拉取相关视频的并发数（原实现 30 个请求同时发出，连续刷新时后发的
/// 请求被风控返回空，表现为越刷越少）
const int dailyRecommendConcurrency = 3;

/// 推荐历史只保留最近这么多条（约 10 天的推荐）。原实现只增不减，
/// 推荐过的视频永久排除，相关视频池被逐渐耗尽
const int recommendHistoryCap = 300;

/// 相关视频的音乐区分区白名单（旧版 tid，related 接口仍返回旧 tid）：
/// 原创音乐 28、音乐现场 29、VOCALOID·UTAU 30、翻唱 31、演奏 59、
/// 音乐综合 130、MV 193、乐评盘点 243、AI 音乐 265、饭拍 266、电台 267。
/// 原白名单漏掉翻唱/VOCALOID/音乐现场等大区，翻唱类收藏的相关视频
/// 几乎全被滤掉（音乐教学 244 不是可听内容，不收）
const List<int> recommendMusicTids = [
  28, 29, 30, 31, 59, 130, 193, 243, 265, 266, 267, //
];

/// 从各种子的相关视频中挑选推荐（纯函数，便于单元测试）：
/// 按种子轮转，每轮每个种子取一首，直到凑满 [count]，保证来源分散；
/// 跳过时长不足 1 分钟、[exclude] 中（已收藏/当前列表）以及重复的视频。
/// 优先取 [seen]（近期推荐过）之外的视频，不够时再用近期推荐过的补足，
/// 宁可偶尔重复也不让列表变短。
List<Meta> pickRecommendations(
  List<List<Meta>> relatedPerSeed, {
  required int count,
  Set<String> seen = const {},
  Set<String> exclude = const {},
}) {
  final picked = <Meta>[];
  final pickedBvids = <String>{};

  void roundRobin(bool allowSeen) {
    final cursors = List<int>.filled(relatedPerSeed.length, 0);
    var progressed = true;
    while (picked.length < count && progressed) {
      progressed = false;
      for (var i = 0; i < relatedPerSeed.length && picked.length < count; i++) {
        final videos = relatedPerSeed[i];
        while (cursors[i] < videos.length) {
          final video = videos[cursors[i]++];
          if (video.duration < 60 ||
              exclude.contains(video.bvid) ||
              pickedBvids.contains(video.bvid) ||
              (!allowSeen && seen.contains(video.bvid))) {
            continue;
          }
          picked.add(video);
          pickedBvids.add(video.bvid);
          progressed = true;
          break;
        }
      }
    }
  }

  roundRobin(false);
  if (picked.length < count) roundRobin(true);
  return picked;
}

/// 把本次推荐追加到历史末尾（保持新近顺序），只保留最近 [cap] 条
List<String> appendRecommendHistory(
    List<String> history, Iterable<String> added,
    {int cap = recommendHistoryCap}) {
  final addedSet = added.toSet();
  final merged = [
    ...history.where((b) => !addedSet.contains(b)),
    ...addedSet,
  ];
  return merged.length > cap ? merged.sublist(merged.length - cap) : merged;
}
