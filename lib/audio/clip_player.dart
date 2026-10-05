import 'dart:async';
import 'dart:io';

import 'package:bmsc/service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// 识别历史片段试听器。开播前显式暂停主播放器（双方都不抢音频焦点，无焦点纠缠）。
///
/// Android：App 定制的 just_audio_background 只支持单播放器实例
/// （lib/audio/just_audio_background_custom.dart），第二个 AudioPlayer 必抛
/// PlatformException，故走原生 MediaPlayer（bmsc/overlay 通道），位置轮询驱动进度。
/// iOS 同为单实例定制，暂复用 just_audio（会失败）——TODO: iOS 需补
/// AVAudioPlayer 通道实现。桌面端 just_audio 多实例无此限制。
class ClipPlayer extends ChangeNotifier {
  static const _ch = MethodChannel('bmsc/overlay');

  AudioPlayer? _jaPlayer; // 非 Android 路径
  final _posController = StreamController<Duration>.broadcast();

  /// 正在播放的片段 id（= 片段文件名）
  String? _playingId;

  int _durationMs = 0;

  String? get playingId => _playingId;

  Stream<Duration> get positionStream => _posController.stream;

  Duration? get duration => Platform.isAndroid
      ? Duration(milliseconds: _durationMs)
      : _jaPlayer?.duration;

  Future<void> toggle(String id, String path) async {
    if (_playingId == id) {
      await stop();
      return;
    }
    await stop();
    _playingId = id;
    notifyListeners();
    try {
      // 显式暂停主播放器
      (await AudioService.instance).player.pause();
      if (Platform.isAndroid) {
        _durationMs =
            await _ch.invokeMethod<int>('playClip', {'path': path}) ?? 0;
        // 轮询位置直至自然播完或被 stop()/切换
        while (_playingId == id) {
          await Future.delayed(const Duration(milliseconds: 250));
          if (_playingId != id) break;
          final ms = await _ch.invokeMethod<int>('clipPosition') ?? _durationMs;
          _posController.add(Duration(milliseconds: ms));
          if (_durationMs > 0 && ms >= _durationMs - 100) break;
        }
        await _ch.invokeMethod<void>('stopClip');
      } else {
        final p = AudioPlayer(handleInterruptions: false);
        _jaPlayer = p;
        final sub = p.positionStream.listen(_posController.add);
        await p.setFilePath(path);
        await p.play(); // play() 在播放结束或停止时才完成
        await sub.cancel();
        await p.dispose();
        if (identical(_jaPlayer, p)) _jaPlayer = null;
      }
    } catch (_) {
      // 片段丢失/解码失败：复位即可
    } finally {
      if (_playingId == id) {
        _playingId = null;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _ch.invokeMethod<void>('stopClip');
    }
    final p = _jaPlayer;
    _jaPlayer = null;
    await p?.stop();
    await p?.dispose();
    if (_playingId != null) {
      _playingId = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    _posController.close();
    super.dispose();
  }
}
