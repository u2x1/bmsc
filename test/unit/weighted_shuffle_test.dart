import 'dart:math';

import 'package:bmsc/util/weighted_shuffle.dart';
import 'package:test/test.dart';

/// 加权随机播放测试（离线、确定性：固定种子 + 大样本聚合断言）。
/// 核心性质：dummy（多 P 视频占位源）按分 P 数加权，
/// 抽中概率 ∝ 权重；等权退化为均匀随机。
void main() {
  group('weightedPermutation（加权随机排列）', () {
    test('输出是输入的排列；initialIndex 固定首位', () {
      final r = Random(1);
      for (var t = 0; t < 100; t++) {
        final order = weightedPermutation(
            [0, 1, 2, 3, 4], (i) => i == 4 ? 10 : 1, r,
            initialIndex: 2);
        expect([...order]..sort(), [0, 1, 2, 3, 4]);
        expect(order.first, 2);
      }
    });

    test('首项抽中概率 ∝ 权重（w=9 项 ≈ 90% 居首）', () {
      final r = Random(42);
      var heavyFirst = 0;
      const trials = 4000;
      for (var t = 0; t < trials; t++) {
        if (weightedPermutation([0, 1], (i) => i == 1 ? 9 : 1, r).first == 1) {
          heavyFirst++;
        }
      }
      expect(heavyFirst / trials, closeTo(0.9, 0.03));
    });

    test('等权退化为均匀随机（各项居首 ≈ 1/n）', () {
      final r = Random(7);
      final firstCounts = [0, 0, 0];
      const trials = 4000;
      for (var t = 0; t < trials; t++) {
        firstCounts[weightedPermutation([0, 1, 2], (_) => 1, r).first]++;
      }
      for (final c in firstCounts) {
        expect(c / trials, closeTo(1 / 3, 0.03));
      }
    });

    test('权重 ≤ 0 按 1 处理（不炸、分布同 1）', () {
      final r = Random(3);
      var otherFirst = 0;
      const trials = 2000;
      for (var t = 0; t < trials; t++) {
        if (weightedPermutation([0, 1], (i) => i == 0 ? 0 : 1, r).first == 1) {
          otherFirst++;
        }
      }
      expect(otherFirst / trials, closeTo(0.5, 0.05));
    });
  });

  group('weightedInsertionIndex（加权散插）', () {
    test('空排列插入位置为 0', () {
      expect(weightedInsertionIndex([], 5, (_) => 1, Random(1)), 0);
    });

    test('插入位置合法且重项倾向靠前', () {
      final r = Random(11);
      var posZero = 0;
      const trials = 4000;
      for (var t = 0; t < trials; t++) {
        // 9 个 w=1 既有项中插入 w=9 新项：P(插到最前) = 9/(9+9) = 0.5
        final pos = weightedInsertionIndex(
            List.generate(9, (i) => i), 9, (_) => 1, r);
        expect(pos, inInclusiveRange(0, 9));
        if (pos == 0) posZero++;
      }
      expect(posZero / trials, closeTo(0.5, 0.03));
    });

    test('从空队列逐个散插 ⇔ 直接排列（同分布：首项概率 ∝ 权重）', () {
      final r = Random(21);
      var heavyFirst = 0;
      const trials = 4000;
      for (var t = 0; t < trials; t++) {
        // 模拟队列构建：w=1、w=1、w=9 三项依次散插入空随机序
        final weights = [1, 1, 9];
        final order = <int>[];
        for (var i = 0; i < weights.length; i++) {
          order.insert(
              weightedInsertionIndex(order, weights[i], (j) => weights[j], r),
              i);
        }
        expect([...order]..sort(), [0, 1, 2]);
        if (order.first == 2) heavyFirst++;
      }
      expect(heavyFirst / trials, closeTo(9 / 11, 0.03));
    });
  });
}
