/// 同一播放源的恢复任务状态。与播放器实现解耦，便于确定性地测试
/// 重试上限、退避、重复错误事件及切歌后的失效处理。
class AudioRecoveryPolicy {
  static const maxAttempts = 3;
  static const _delays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  final Map<Object, int> _attempts = {};
  final Map<Object, int> _pending = {};
  int _generation = 0;

  /// 为 [source] 安排一次恢复；已有待执行任务或达到上限时返回 null。
  AudioRecoveryTask? schedule(Object source) {
    if (_pending.containsKey(source)) return null;
    final attempt = attemptsFor(source) + 1;
    if (attempt > maxAttempts) return null;

    _attempts[source] = attempt;
    final token = ++_generation;
    _pending[source] = token;
    return AudioRecoveryTask(
      source: source,
      attempt: attempt,
      delay: _delays[attempt - 1],
      token: token,
    );
  }

  /// 定时器触发时消费任务。重复触发、旧任务及切歌后的任务均返回 false。
  bool consume(AudioRecoveryTask task) {
    if (_pending[task.source] != task.token) return false;
    _pending.remove(task.source);
    return isCurrent(task);
  }

  /// 执行中的恢复在 await 后复核时效性。
  bool isCurrent(AudioRecoveryTask task) => task.token == _generation;

  bool isPending(Object source) => _pending.containsKey(source);

  int attemptsFor(Object source) => _attempts[source] ?? 0;

  /// 克隆源继承旧源已尝试次数，避免每次换源都重新获得三次机会。
  void inheritAttempt(Object from, Object to) {
    final attempt = _attempts[from];
    if (attempt != null) _attempts[to] = attempt;
  }

  /// 用户手动重试或恢复后稳定播放时，允许重新计数。
  void reset(Object source) => _attempts.remove(source);

  /// 真实切歌/队列变化后使所有退避及在途恢复失效。
  void invalidatePending() {
    _generation++;
    _pending.clear();
  }
}

class AudioRecoveryTask {
  final Object source;
  final int attempt;
  final Duration delay;
  final int token;

  const AudioRecoveryTask({
    required this.source,
    required this.attempt,
    required this.delay,
    required this.token,
  });
}
