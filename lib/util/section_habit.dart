/// 主页板块 key（排序偏好的存储值）。
/// 定义于此（而非 shared_preferences_service）以便纯 Dart 测试引用；
/// shared_preferences_service 原样 re-export，既有调用方不受影响。
const String kHomeSectionDaily = 'daily';
const String kHomeSectionRecent = 'recent';
const String kHomeSectionMine = 'mine';
const String kHomeSectionCollected = 'collected';
const String kHomeSectionLocal = 'local';

/// 主页板块默认顺序：每日推荐 → 最近在听 → 我的收藏夹 → 收藏的收藏夹 → 本地音乐
///（新增板块对老用户自动追加到末尾，见 getHomeSectionOrder）
const List<String> kDefaultHomeSectionOrder = [
  kHomeSectionDaily,
  kHomeSectionRecent,
  kHomeSectionMine,
  kHomeSectionCollected,
  kHomeSectionLocal,
];

/// 主页板块使用习惯学习（纯函数，离线可测；持久化与会话判定见
/// service/section_habit_service.dart）。
///
/// 算法设计：
/// - 每个会话只记录一次「进入 App 后首个从主页板块发起的播放」
/// - 打分为**纯累计计数，不随时间衰减**：用户习惯不会因时间流逝
///   而过期——置顶的板块不会自己沉下去，它只在另一个板块的累计
///   播放次数实际反超（×反超阈值）时才让位。分数只在真实行为
///   发生时变化，因此也无需存事件时间、无需周期性重算
/// - 排序采用「带反超阈值的相邻上浮」：下方板块累计次数需超过
///   上方板块 (1+[kSectionHabitOvertakeMargin]) 倍才与之交换，一次
///   事件最多让一个板块上移一位——避免两个热度接近的板块逐日
///   互换（UI 抖动），排序变化对用户可预期。不直接按分数全排
///   也是这个原因
/// - 冷启动保护：累计样本不足 [kSectionHabitMinEvents] 时不做任何
///   自动调整，避免头几次使用就移动板块

/// 反超阈值：挑战者累计次数需超过在位者 (1+margin) 倍才能交换位置
const kSectionHabitOvertakeMargin = 0.15;

/// 自动排序生效所需的最少播放样本数
const kSectionHabitMinEvents = 5;

/// 板块习惯学习状态（持久化为 JSON）
class SectionHabitState {
  SectionHabitState({
    Map<String, double>? scores,
    this.totalEvents = 0,
  }) : scores = scores ?? {};

  /// 各板块累计的「首个播放」次数（无条目的板块视为 0）。
  /// 用 double 存储仅为兼容旧版本曾写入的小数分数
  final Map<String, double> scores;

  /// 累计事件数（冷启动门槛用）
  int totalEvents;

  Map<String, dynamic> toJson() => {
        'scores': scores,
        'totalEvents': totalEvents,
      };

  /// 反序列化：容忍坏数据（缺字段/类型错回退默认值）与旧版本
  /// 多余字段（如 lastEventAtMs，直接忽略）
  static SectionHabitState fromJson(Map<String, dynamic> json) {
    int toInt(Object? v) => v is num ? v.toInt() : 0;
    return SectionHabitState(
      scores: {
        for (final e in (json['scores'] as Map? ?? {}).entries)
          if (e.value is num) e.key.toString(): (e.value as num).toDouble(),
      },
      totalEvents: toInt(json['totalEvents']),
    );
  }
}

/// 记录一次播放（原地更新并返回 [state]）：[section] 累计次数 +1。
SectionHabitState recordSectionPlay(SectionHabitState state, String section) {
  state.scores[section] = (state.scores[section] ?? 0) + 1;
  state.totalEvents++;
  return state;
}

/// 由当前顺序与分数计算自动排序结果（返回新列表，不改入参）：
/// 从上到下扫描，下方板块累计次数超过上方 (1+[kSectionHabitOvertakeMargin])
/// 倍时交换二者——每个板块一次事件最多上移一位；
/// 样本不足 [kSectionHabitMinEvents] 或顺序无需变化时返回原顺序拷贝。
List<String> learnedSectionOrder(
  List<String> currentOrder,
  SectionHabitState state,
) {
  final order = List.of(currentOrder);
  if (state.totalEvents < kSectionHabitMinEvents) return order;
  for (var i = 1; i < order.length; i++) {
    final below = state.scores[order[i]] ?? 0;
    final above = state.scores[order[i - 1]] ?? 0;
    if (below > above * (1 + kSectionHabitOvertakeMargin)) {
      final tmp = order[i - 1];
      order[i - 1] = order[i];
      order[i] = tmp;
    }
  }
  return order;
}
