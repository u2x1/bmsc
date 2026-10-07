import 'dart:async';
import 'dart:convert';

import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/section_habit.dart';

final _logger = LoggerUtils.getLogger('SectionHabitService');

/// 主页板块使用习惯学习：记录「每次进入 App 后首个从主页板块发起的
/// 播放」所属板块（算法见 util/section_habit.dart），「智能排序」开启
/// 时把学习结果写回主页板块顺序偏好（home_section_order），主页在
/// 下次构建时自然生效——学习结果从不当场改变当前主页，避免板块在
/// 用户眼前移动。
///
/// 会话定义：进程启动，或退到后台超过 [_reentryThreshold] 后回到前台
/// （由 main.dart 的生命周期回调驱动）。每个会话只记录首个主页板块
/// 播放；搜索/动态/历史等非主页板块来源不记录。数据仅存本机。
class SectionHabitService {
  static const _stateKey = 'home_section_habit';
  static const _autoSortKey = 'home_section_auto_sort';
  static const _reentryThreshold = Duration(minutes: 30);

  /// 本次会话是否已记录过首个主页板块播放
  static bool _sessionRecorded = false;

  /// 上次退到后台的时间（epoch ms），0 = 未记录
  static int _backgroundedAtMs = 0;

  /// 记录一次「从主页板块发起的播放」。非主页板块 key 直接忽略；
  /// 同一会话只有第一次调用生效。fire-and-forget，调用方无需 await。
  static Future<void> recordPlaySource(String section) async {
    if (_sessionRecorded) return;
    if (!kDefaultHomeSectionOrder.contains(section)) return;
    // 先占位再异步，保证同会话并发的第二次调用被丢弃
    _sessionRecorded = true;
    try {
      final prefs = await SharedPreferencesService.instance;
      final raw = prefs.getString(_stateKey);
      final state = raw == null
          ? SectionHabitState()
          : SectionHabitState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      recordSectionPlay(state, section);
      await prefs.setString(_stateKey, jsonEncode(state.toJson()));
      _logger.info('home section play: $section (total ${state.totalEvents})');

      if (await isAutoSortEnabled()) {
        final current = await SharedPreferencesService.getHomeSectionOrder();
        final learned = learnedSectionOrder(current, state);
        if (!_listEquals(current, learned)) {
          await SharedPreferencesService.setHomeSectionOrder(learned);
          _logger.info('home section order adjusted: $learned');
        }
      }
    } catch (e) {
      _logger.warning('recordPlaySource failed: $e');
    }
  }

  /// App 退到后台（由 main.dart 生命周期回调驱动）
  static void onAppPaused() {
    _backgroundedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// App 回到前台：后台超过阈值视为「再次进入 App」，开启新会话
  static void onAppResumed() {
    if (_backgroundedAtMs <= 0) return;
    final elapsed = Duration(
        milliseconds:
            DateTime.now().millisecondsSinceEpoch - _backgroundedAtMs);
    _backgroundedAtMs = 0;
    if (elapsed >= _reentryThreshold) {
      _sessionRecorded = false;
    }
  }

  /// 智能排序开关（默认开）：关闭时仍继续记录，重新开启后学习结果
  /// 即刻参与排序；用户在设置里手动拖拽排序会自动关闭本开关
  static Future<bool> isAutoSortEnabled() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getBool(_autoSortKey) ?? true;
  }

  static Future<void> setAutoSortEnabled(bool value) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool(_autoSortKey, value);
  }

  /// 清空学习数据（设置页「重置默认」时一并调用——否则下次播放
  /// 立即把学习结果写回，重置形同虚设）
  static Future<void> resetHabit() async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.remove(_stateKey);
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
