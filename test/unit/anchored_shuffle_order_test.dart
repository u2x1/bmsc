import 'dart:math';

import 'package:bmsc/service/audio_service.dart';
import 'package:test/test.dart';

/// AnchoredShuffleOrder 测试（导入 audio_service → 依赖 just_audio，
/// 经 flutter test 运行）：
/// 锚定替换保持「下一首」槽位、anchorFirst 首项锚定 + 其余散插
///（分 P 也随机）、加权 shuffle 语义。
void main() {
  group('anchorAfter（1:1 换源全锚定）', () {
    test('全部新源紧随锚点槽位连续占位；锚定一次性消费', () {
      final o = AnchoredShuffleOrder(random: Random(1));
      o.insert(0, 3); // 队列 [0,1,2]
      expect([...o.indices]..sort(), [0, 1, 2]);
      o.anchorAfter(0);
      o.insert(1, 2); // 新源 playlist 下标 1,2（旧 1,2 平移为 3,4）
      final anchorPos = o.indices.indexOf(0);
      expect(o.indices.sublist(anchorPos + 1, anchorPos + 3), [1, 2]);
      expect([...o.indices]..sort(), [0, 1, 2, 3, 4]);
      // 一次性：未再设锚的插入回退为散插
      o.insert(5, 1);
      expect([...o.indices]..sort(), [0, 1, 2, 3, 4, 5]);
    });
  });

  group('anchorFirstAfter（dummy 解析：入口分 P 锚定，其余分 P 散插）', () {
    // 关键不变式：散插的分 P 可能落到锚点之前，但锚点与入口分 P 之间
    // 只可能出现本次新插入的分 P（真实源），绝不会有既有项——
    // 这保证预解析后「下一首」必为已解析的真实源
    test('入口分 P 在锚点之后，中间只含本次新分 P；整体为合法排列', () {
      final o = AnchoredShuffleOrder(random: Random(2));
      o.insert(0, 3); // 队列 [0,1,2]
      o.anchorFirstAfter(0);
      o.insert(1, 3); // 新源 playlist 下标 1,2,3（旧 1,2 平移为 4,5）
      expect([...o.indices]..sort(), [0, 1, 2, 3, 4, 5]);
      final anchorPos = o.indices.indexOf(0);
      final entryPos = o.indices.indexOf(1);
      expect(entryPos, greaterThan(anchorPos));
      expect(o.indices.sublist(anchorPos + 1, entryPos),
          everyElement(isIn([2, 3])));
    });

    test('其余分 P 确实散插（位置随种子变化），不变式恒成立', () {
      final positions = <int>{};
      for (var seed = 0; seed < 50; seed++) {
        final o = AnchoredShuffleOrder(random: Random(seed));
        o.insert(0, 1); // 队列 [0]
        o.anchorFirstAfter(0);
        o.insert(1, 4); // 新源 1..4
        final anchorPos = o.indices.indexOf(0);
        final entryPos = o.indices.indexOf(1);
        expect(entryPos, greaterThan(anchorPos));
        expect(o.indices.sublist(anchorPos + 1, entryPos),
            everyElement(isIn([2, 3, 4])));
        positions.add(o.indices.indexOf(2));
      }
      // 50 种不同种子下分 P 2 的落点不唯一 → 非连续锚定
      expect(positions.length, greaterThan(1));
    });

    test('单个新源时与 anchorAfter 等价', () {
      final o = AnchoredShuffleOrder(random: Random(3));
      o.insert(0, 2);
      o.anchorFirstAfter(0);
      o.insert(1, 1);
      expect(o.indices[o.indices.indexOf(0) + 1], 1);
    });

    test('锚点已不在随机序：回退散插（合法排列）', () {
      final o = AnchoredShuffleOrder(random: Random(4));
      o.insert(0, 2);
      o.anchorFirstAfter(9); // 不存在的下标
      o.insert(2, 2);
      expect([...o.indices]..sort(), [0, 1, 2, 3]);
    });
  });

  group('加权 shuffle（weightOfIndex）', () {
    test('重项居首概率 ∝ 权重（w=9 vs w=1，期望 90%，保守下限 75%）', () {
      var heavyFirst = 0;
      const trials = 200;
      for (var seed = 0; seed < trials; seed++) {
        final o = AnchoredShuffleOrder(random: Random(seed));
        o.weightOfIndex = (i) => i == 0 ? 9 : 1;
        o.insert(0, 2); // 两项：重项 0、普通项 1
        o.shuffle();
        if (o.indices.first == 0) heavyFirst++;
      }
      expect(heavyFirst / trials, greaterThan(0.75));
    });

    test('initialIndex 固定首位（当前播放项不随重排移动）', () {
      final o = AnchoredShuffleOrder(random: Random(5));
      o.weightOfIndex = (i) => i == 0 ? 100 : 1;
      o.insert(0, 5);
      o.shuffle(initialIndex: 3);
      expect(o.indices.first, 3);
    });
  });
}
