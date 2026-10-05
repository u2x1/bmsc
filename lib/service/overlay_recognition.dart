import 'dart:async';
import 'dart:io';

import 'package:bmsc/service/recognition_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:flutter/services.dart';

/// 悬浮窗识曲（Android）：原生 OverlayService（FGS type=microphone）提供气泡，
/// 点气泡 → 复用 RecognitionService 录制约 7 秒 → 识别 → 状态/结果回写悬浮窗；
/// 点悬浮窗结果回链 App 内搜索。识别记录同样写入识别历史（含试听片段）。
///
/// 后台录音走 Android 标准 FGS-microphone 路径：App 退后台时麦克风权限
/// （仅使用中允许）需要前台服务兜底，2026-10-05 实测验证（见 RecognitionService）。
class OverlayRecognitionService {
  OverlayRecognitionService._();
  static final OverlayRecognitionService instance =
      OverlayRecognitionService._();

  static const _ch = MethodChannel('bmsc/overlay');
  static const _recordSeconds = 7;

  final _service = RecognitionService();
  bool _busy = false;
  bool _inited = false;

  /// 点悬浮窗结果时跳转搜索（由 main 注入导航能力）
  void Function(String keyword)? onOpenSearch;

  Future<bool> isSupported() async => Platform.isAndroid;

  Future<bool> isGranted() async {
    if (!Platform.isAndroid) return false;
    return await _ch.invokeMethod<bool>('isGranted') ?? false;
  }

  Future<void> requestPermission() =>
      _ch.invokeMethod<void>('requestPermission');

  /// 初始化事件监听（App 启动时调用一次）
  void init() {
    if (_inited || !Platform.isAndroid) return;
    _inited = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'overlayTap':
          await _recognizeOnce();
        case 'openSearch':
          final kw = call.arguments as String?;
          if (kw != null && kw.isNotEmpty) onOpenSearch?.call(kw);
      }
    });
  }

  Future<void> show() => _ch.invokeMethod<void>('show');

  Future<void> hide() => _ch.invokeMethod<void>('hide');

  Future<void> _recognizeOnce() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!await _service.ensureMicPermission()) {
        await _status('无麦克风权限', '请在系统设置中允许后点气泡重试');
        return;
      }
      await _service.startRecording();
      await _status('正在聆听…', '约 $_recordSeconds 秒，保持外放');
      await Future.delayed(const Duration(seconds: _recordSeconds));
      final outcome = await _service.stopAndRecognize();
      // 成功/未中/静音/失败均入史（附试听片段），与 App 内一致
      unawaited(SharedPreferencesService.addRecognitionHistory(
          outcome.toAttempt(DateTime.now().millisecondsSinceEpoch)));
      switch (outcome.status) {
        case RecognitionStatus.ok:
          final s = outcome.songs.first;
          await _status(s.name, s.artistText, keyword: s.searchKeyword);
        case RecognitionStatus.noMatch:
          await _status('未识别到歌曲', '靠近音源后点气泡重试');
        case RecognitionStatus.silent:
          await _status('录到的是静音', '请检查麦克风权限/隐私开关');
        case RecognitionStatus.error:
          await _status('识别失败', outcome.message ?? '');
      }
    } catch (e) {
      await _status('识别失败', '$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _status(String status, String text, {String? keyword}) =>
      _ch.invokeMethod<void>(
          'setStatus', {'status': status, 'text': text, 'keyword': keyword});
}
