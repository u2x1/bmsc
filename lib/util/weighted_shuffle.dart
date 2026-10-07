import 'dart:math';

/// 加权随机播放（纯函数，离线可测；调用方见
/// service/audio_service.dart 的 AnchoredShuffleOrder）。
///
/// 动机：队列中的 dummy（多 P 视频占位源）在解析时会展开为多个分 P，
/// 若与普通源同权（权重 1），它在随机序中的抽中概率只等于一个分 P——
/// 一个 50 P 的视频与一首单曲等概率出现，被抽中后又连播 50 个分 P。
/// 因此 dummy 的权重取为其内部分 P 数（weightOf 回调提供），使随机
/// 播放按分 P 均匀：多 P 视频整体的抽中概率 = 同等数量单曲之和。

/// 加权随机排列（Efraimidis–Spirakis 指数时钟竞赛）：
/// 每项 key = u^(1/w)（u∈(0,1) 均匀，w 为权重），按 key 降序。
/// 性质：P(i 排在 j 前) = w_i/(w_i+w_j)，首项被抽中概率严格 ∝ 权重；
/// 等权时退化为均匀随机排列（与 DefaultShuffleOrder.shuffle 同分布）。
/// [initialIndex] 语义与 DefaultShuffleOrder.shuffle 一致：
/// 指定项固定到首位（当前播放项不随重排移动），其余按权重排列。
List<int> weightedPermutation(
  List<int> indices,
  int Function(int index) weightOf,
  Random random, {
  int? initialIndex,
}) {
  final keyed = [
    for (final i in indices)
      (index: i, key: pow(random.nextDouble(), 1.0 / _weight(weightOf(i)))),
  ];
  keyed.sort((a, b) => b.key.compareTo(a.key));
  final order = [for (final e in keyed) e.index];
  if (initialIndex == null) return order;
  final swapPos = order.indexOf(initialIndex);
  if (swapPos <= 0) return order;
  final swapIndex = order[0];
  order[0] = initialIndex;
  order[swapPos] = swapIndex;
  return order;
}

/// 把权重为 [newWeight] 的新项插入加权随机排列 [order] 的应属位置，
/// 结果与 weightedPermutation 同分布（等价于新项参与同一轮指数时钟
/// 竞赛后的归位）。
///
/// 从前往后走，在 gap g 处停下（新项排在 order[g] 及其后所有项之前）
/// 的概率 = w_new / (w_new + R_g)，其中 R_g = Σ_{j≥g} w(order[j]) 为
/// 后缀权重和：新项的时钟须小于余下所有项的**最小**时钟（min 的
/// 指数分布率 = 率和），不是与首项两两比较——首项的时钟已被次序
/// 统计压低，两两比较会系统性高估重项靠前的概率。
/// 对应 DefaultShuffleOrder.insert 的随机散插语义；对空队列逐个插入
/// 即逐步构建出完整的加权随机排列。
int weightedInsertionIndex(
  List<int> order,
  int newWeight,
  int Function(int index) weightOf,
  Random random,
) {
  final wNew = _weight(newWeight);
  var remaining = 0.0;
  for (final i in order) {
    remaining += _weight(weightOf(i));
  }
  var pos = 0;
  while (pos < order.length) {
    if (random.nextDouble() < wNew / (wNew + remaining)) return pos;
    remaining -= _weight(weightOf(order[pos]));
    pos++;
  }
  return pos;
}

/// 权重下限钳制为 1（0/负权重无意义，且会让 1/w 幂运算爆炸）
double _weight(num w) => w > 0 ? w.toDouble() : 1.0;
