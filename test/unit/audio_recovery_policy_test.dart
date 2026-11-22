import 'package:bmsc/audio/audio_recovery_policy.dart';
import 'package:test/test.dart';

void main() {
  group('AudioRecoveryPolicy', () {
    test('退避为 1/2/4 秒，同一源最多快速恢复三次', () {
      final policy = AudioRecoveryPolicy();
      final source = Object();

      final first = policy.schedule(source)!;
      expect(first.delay, const Duration(seconds: 1));
      expect(policy.consume(first), isTrue);
      final second = policy.schedule(source)!;
      expect(second.delay, const Duration(seconds: 2));
      expect(policy.consume(second), isTrue);
      final third = policy.schedule(source)!;
      expect(third.delay, const Duration(seconds: 4));
      expect(policy.consume(third), isTrue);

      expect(policy.schedule(source), isNull);
      expect(policy.attemptsFor(source), 3);
    });

    test('重复错误事件不会并发安排恢复，任务只能消费一次', () {
      final policy = AudioRecoveryPolicy();
      final source = Object();
      final task = policy.schedule(source)!;

      expect(policy.schedule(source), isNull);
      expect(policy.isPending(source), isTrue);
      expect(policy.consume(task), isTrue);
      expect(policy.consume(task), isFalse);
      expect(policy.isPending(source), isFalse);
    });

    test('切歌使退避中的旧任务失效，不影响新源', () {
      final policy = AudioRecoveryPolicy();
      final oldSource = Object();
      final newSource = Object();
      final oldTask = policy.schedule(oldSource)!;

      policy.invalidatePending();
      final newTask = policy.schedule(newSource)!;

      expect(policy.consume(oldTask), isFalse);
      expect(policy.consume(newTask), isTrue);
    });

    test('await 后可识别已被新任务取代的旧恢复', () {
      final policy = AudioRecoveryPolicy();
      final oldSource = Object();
      final newSource = Object();
      final oldTask = policy.schedule(oldSource)!;
      expect(policy.consume(oldTask), isTrue);

      final newTask = policy.schedule(newSource)!;
      expect(policy.isCurrent(oldTask), isFalse);
      expect(policy.isCurrent(newTask), isTrue);
    });

    test('克隆源继承尝试次数，稳定播放或手动重试可重置', () {
      final policy = AudioRecoveryPolicy();
      final oldSource = Object();
      final freshSource = Object();
      final task = policy.schedule(oldSource)!;
      expect(policy.consume(task), isTrue);

      policy.inheritAttempt(oldSource, freshSource);
      expect(policy.attemptsFor(freshSource), 1);
      final second = policy.schedule(freshSource)!;
      expect(second.delay, const Duration(seconds: 2));
      expect(policy.consume(second), isTrue);

      policy.reset(freshSource);
      expect(policy.attemptsFor(freshSource), 0);
      expect(policy.schedule(freshSource)!.delay, const Duration(seconds: 1));
    });
  });
}
