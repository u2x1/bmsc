import 'package:bmsc/util/section_habit.dart';
import 'package:test/test.dart';

/// 主页板块习惯学习算法测试（离线、确定性）：
/// 纯累计计数打分（不随时间衰减）、带反超阈值的相邻上浮排序、
/// 冷启动门槛、状态序列化与旧版本数据兼容。
void main() {
  group('recordSectionPlay（纯累计计数，无时间衰减）', () {
    test('记录：目标 +1、累计 +1', () {
      final s = SectionHabitState();
      recordSectionPlay(s, 'recent');
      expect(s.scores, {'recent': 1.0});
      expect(s.totalEvents, 1);
      recordSectionPlay(s, 'mine');
      recordSectionPlay(s, 'recent');
      expect(s.scores, {'recent': 2.0, 'mine': 1.0});
      expect(s.totalEvents, 3);
    });

    test('分数只随真实行为变化：不播放的板块计数不变（置顶不自动下沉）', () {
      final s = SectionHabitState();
      for (var i = 0; i < 50; i++) {
        recordSectionPlay(s, 'recent');
      }
      // 之后只在其他板块产生事件（无论间隔多久），recent 计数不变
      for (var i = 0; i < 30; i++) {
        recordSectionPlay(s, 'local');
      }
      expect(s.scores['recent'], 50.0);
      expect(s.scores['local'], 30.0);
      expect(s.totalEvents, 80);
    });

    test('习惯迁移靠累计反超：挑战者需累计超过在位者 ×(1+阈值)', () {
      final s = SectionHabitState();
      final order = List.of(kDefaultHomeSectionOrder);
      void learn() {
        final next = learnedSectionOrder(order, s);
        order
          ..clear()
          ..addAll(next);
      }

      for (var i = 0; i < 30; i++) {
        recordSectionPlay(s, 'recent');
      }
      learn(); // recent: 30 > daily: 0 → 置顶
      expect(order.first, kHomeSectionRecent);

      // 改用 local：34 次仍不足以反超（34 < 30×1.15），recent 不让位
      for (var i = 0; i < 34; i++) {
        recordSectionPlay(s, 'local');
        learn();
      }
      expect(order.indexOf(kHomeSectionRecent),
          lessThan(order.indexOf(kHomeSectionLocal)));
      // 第 35 次：35 > 34.5 → 反超
      recordSectionPlay(s, 'local');
      learn();
      expect(order.indexOf(kHomeSectionLocal),
          lessThan(order.indexOf(kHomeSectionRecent)));
    });
  });

  group('learnedSectionOrder（带阈值的相邻上浮）', () {
    test('样本不足门槛：原样返回', () {
      final s = SectionHabitState();
      for (var i = 0; i < kSectionHabitMinEvents - 1; i++) {
        recordSectionPlay(s, 'local');
      }
      expect(learnedSectionOrder(kDefaultHomeSectionOrder, s),
          kDefaultHomeSectionOrder);
    });

    test('每个事件最多上移一位：末尾板块逐次浮到顶部', () {
      final s = SectionHabitState();
      final order = List.of(kDefaultHomeSectionOrder);
      expect(order.last, kHomeSectionLocal);
      // 从第 5 个事件（达到门槛）起每次上移一位：
      // 位次 4→3→2→1→0，共 8 次到顶
      for (var i = 0; i < 8; i++) {
        recordSectionPlay(s, kHomeSectionLocal);
        final next = learnedSectionOrder(order, s);
        order
          ..clear()
          ..addAll(next);
      }
      expect(order.first, kHomeSectionLocal);
      // 其余板块相对顺序不变
      expect(order.sublist(1), [
        kHomeSectionDaily,
        kHomeSectionRecent,
        kHomeSectionMine,
        kHomeSectionCollected,
      ]);
    });

    test('差距不足 15% 阈值不交换（防抖）', () {
      final s = SectionHabitState(
        scores: {'daily': 100, 'recent': 114},
        totalEvents: kSectionHabitMinEvents,
      );
      expect(learnedSectionOrder(kDefaultHomeSectionOrder, s),
          kDefaultHomeSectionOrder);
      // 恰好反超（116 > 100×1.15）则交换
      s.scores['recent'] = 116;
      expect(learnedSectionOrder(kDefaultHomeSectionOrder, s).first,
          kHomeSectionRecent);
    });

    test('未使用板块分数视为 0，可被任何使用过的板块超越', () {
      final s = SectionHabitState(
        scores: {'local': 1},
        totalEvents: kSectionHabitMinEvents,
      );
      final order = learnedSectionOrder(kDefaultHomeSectionOrder, s);
      expect(order.indexOf(kHomeSectionLocal),
          lessThan(order.indexOf(kHomeSectionCollected)));
    });

    test('等分不交换（稳定），且不改入参', () {
      final s = SectionHabitState(
        scores: {'daily': 100, 'recent': 100},
        totalEvents: kSectionHabitMinEvents,
      );
      final input = List.of(kDefaultHomeSectionOrder);
      final out = learnedSectionOrder(input, s);
      expect(out, kDefaultHomeSectionOrder);
      expect(input, kDefaultHomeSectionOrder);
    });
  });

  group('SectionHabitState JSON', () {
    test('序列化往返', () {
      final s = SectionHabitState(
        scores: {'recent': 3, 'local': 1.25},
        totalEvents: 7,
      );
      final restored = SectionHabitState.fromJson(s.toJson());
      expect(restored.scores, s.scores);
      expect(restored.totalEvents, s.totalEvents);
    });

    test('坏数据容忍：缺字段/类型错回退默认值', () {
      final s = SectionHabitState.fromJson(
          {'scores': {'a': 'bad', 'b': 2}, 'totalEvents': 'x'});
      expect(s.scores, {'b': 2.0});
      expect(s.totalEvents, 0);
      expect(SectionHabitState.fromJson(const {}).scores, isEmpty);
    });

    test('旧版本数据兼容：多余字段（lastEventAtMs）直接忽略', () {
      final s = SectionHabitState.fromJson({
        'scores': {'recent': 9.5},
        'lastEventAtMs': 123456789,
        'totalEvents': 12,
      });
      expect(s.scores, {'recent': 9.5});
      expect(s.totalEvents, 12);
      // 重新持久化后不再携带旧字段
      expect(s.toJson().containsKey('lastEventAtMs'), isFalse);
    });
  });
}
