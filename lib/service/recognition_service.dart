import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:bmsc/model/recognition_attempt.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/wav.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

export 'package:bmsc/model/recognition_attempt.dart'
    show RecognizedSong, RecognitionOutcome, RecognitionStatus;

final _logger = LoggerUtils.getLogger('RecognitionService');

/// 麦克风识曲：录 8kHz 单声道 WAV → （必要时重采样）→ 上传 Worker。
/// 每次识别另存一份 16kHz 试听片段到 documents/recognition_clips/（识别历史回放用）。
class RecognitionService {
  RecognitionService({Dio? dio, String endpoint = defaultEndpoint})
      : _dio = dio ?? Dio(),
        _endpoint = endpoint;

  /// workers/recognize 生产端点
  static const defaultEndpoint = 'https://bmsc-recognize.u2x1.work/recognize';

  final Dio _dio;
  final String _endpoint;
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordingPath;

  Future<bool> ensureMicPermission() => _recorder.hasPermission();

  /// 录音期间的实时电平（dBFS），供 UI 可视化
  Stream<Amplitude> watchAmplitude() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 120));

  /// 开始录音（48kHz 单声道 WAV；不抢音频焦点，关闭会抑制本机外放的回声消除/降噪）
  Future<void> startRecording() async {
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/recognition_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        // 用设备原生 48kHz 录制：部分机型（如 MIUI）的 8kHz 输入走语音
        // 通道，增益异常低。识别前在 Dart 里重采样到 8kHz（resampleS16To8k）。
        sampleRate: 48000,
        numChannels: 1,
        // 关键：默认 pause 模式会让插件请求音频焦点 → 本应用自己的播放被
        // 系统暂停 → 录到的全是静音（边播边录识别必败）。none = 不抢焦点。
        audioInterruption: AudioInterruptionMode.none,
        autoGain: true,
        // 回声消除/降噪在支持这些效果的机型上会主动抑制"本机外放"信号，
        // 而识别自己手机放的歌恰恰要捕获它，一并关闭
        echoCancel: false,
        noiseSuppress: false,
      ),
      path: _recordingPath!,
    );
  }

  Future<void> cancelRecording() async {
    await _recorder.cancel();
    _cleanupFile();
  }

  /// 停止录音并识别。业务失败（无匹配/静音/网络）编码在 [RecognitionOutcome]，
  /// 不再抛异常。[onCaptured] 在拿到原始 PCM 后、上传前回调（供 UI 生成频谱图）。
  Future<RecognitionOutcome> stopAndRecognize({
    void Function(Uint8List pcm, int sampleRate)? onCaptured,
  }) async {
    final path = await _recorder.stop();
    if (path == null) {
      return const RecognitionOutcome(
          status: RecognitionStatus.error, message: '录音失败');
    }
    try {
      final bytes = await File(path).readAsBytes();
      final WavInfo info;
      try {
        info = parseWavHeader(bytes);
      } on FormatException catch (e) {
        return RecognitionOutcome(
            status: RecognitionStatus.error, message: '录音格式异常：${e.message}');
      }
      if (info.bitsPerSample != 16 || info.channels != 1) {
        return RecognitionOutcome(
            status: RecognitionStatus.error,
            message: '录音格式异常（${info.bitsPerSample}bit ${info.channels}ch）');
      }
      _logger.info('recorded wav: ${info.sampleRate}Hz, '
          '${(info.dataLength / 2 / info.sampleRate).toStringAsFixed(1)}s');
      var pcm = Uint8List.sublistView(
          bytes, info.dataOffset, info.dataOffset + info.dataLength);
      onCaptured?.call(pcm, info.sampleRate);

      // 诊断：录音峰值/RMS（静音 ≈ 权限被拒或没采集到声音）
      final view = ByteData.sublistView(pcm);
      var peak = 0;
      var sumSq = 0.0;
      for (var i = 0; i < pcm.length; i += 2) {
        final s = view.getInt16(i, Endian.little);
        if (s.abs() > peak) peak = s.abs();
        sumSq += s * s;
      }
      final rms = pcm.isEmpty ? 0.0 : sqrt(sumSq / (pcm.length >> 1));
      _logger
          .info('recorded level: peak=$peak rms=${rms.toStringAsFixed(1)}');

      final durationSec0 = pcm.length / 2 / info.sampleRate;
      // 16kHz 试听片段（识别历史回放；~224KB/7s）。静音/失败也存——正是排障证据。
      final clipPath = await _saveClip(pcm, info.sampleRate);

      // 全零静音：系统麦克风隐私总开关/空白录音保护会让平台给 App 喂静音
      // （dumpsys audio 中显示 silenced），此时识别必为空，提前给可操作错误。
      // 2026-10-05 实测于 Redmi M2007J22C（MIUI/Android 13）：权限 allow 但
      // rec 会话 silenced → 录音全零。
      if (peak == 0) {
        return RecognitionOutcome(
            status: RecognitionStatus.silent,
            message: '录到的是静音——请检查系统「麦克风」隐私开关是否关闭，'
                '或本应用是否被系统隐私保护限制了录音',
            clipPath: clipPath,
            durationSec: durationSec0);
      }

      pcm = resampleS16To8k(pcm, info.sampleRate);
      final durationSec = pcm.length / 2 / 8000;
      if (durationSec < 1.5) {
        return RecognitionOutcome(
            status: RecognitionStatus.error,
            message: '录音时间太短',
            clipPath: clipPath,
            durationSec: durationSec);
      }
      return await _upload(pcm, durationSec, clipPath);
    } finally {
      _cleanupFile();
    }
  }

  /// 保存 16kHz 试听片段（重采样 + 标准 WAV 头）；失败返回 null
  Future<String?> _saveClip(Uint8List pcm, int sampleRate) async {
    try {
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/recognition_clips');
      await dir.create(recursive: true);
      final path =
          '${dir.path}/clip_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(path)
          .writeAsBytes(writeWavS16(resampleS16(pcm, sampleRate, 16000), 16000));
      return path;
    } catch (_) {
      return null;
    }
  }

  void _cleanupFile() {
    final path = _recordingPath;
    _recordingPath = null;
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  Future<RecognitionOutcome> _upload(
      Uint8List pcm, double durationSec, String? clipPath) async {
    _logger.info(
        'uploading ${pcm.length} bytes (${durationSec.toStringAsFixed(2)}s)');
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        // 实测矩阵（2026-10-05，连续真实音乐）：duration=5 是网易接口毒值（任意
        // 实际时长报 5 均返回空）；duration 与实际时长相差 >1 同样返回空。向下
        // 取整，毒值 5 重映射为 6（实际 5.0~5.9s 报 6，距离 ≤1，已验证）。
        // 配合 UI 侧 7 秒录音（实际产出 ~6.9s → 报 6）落在安全区。
        '$_endpoint?duration=${durationSec.floor() == 5 ? 6 : durationSec.floor()}',
        data: pcm,
        options: Options(
          headers: {'Content-Type': 'application/octet-stream'},
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final results = (res.data?['results'] as List?)
              ?.map((e) => RecognizedSong.fromJson(e as Map<String, dynamic>))
              .where((e) => e.name.isNotEmpty)
              .toList() ??
          const <RecognizedSong>[];
      _logger.info('recognized ${results.length} songs');
      return RecognitionOutcome(
        status: results.isEmpty
            ? RecognitionStatus.noMatch
            : RecognitionStatus.ok,
        songs: results,
        clipPath: clipPath,
        durationSec: durationSec,
      );
    } on DioException catch (e) {
      _logger.warning('recognize upload failed', e);
      final status = e.response?.statusCode;
      return RecognitionOutcome(
        status: RecognitionStatus.error,
        message: switch (status) {
          429 => '识别请求过于频繁，请一分钟后再试',
          400 => '音频数据异常',
          502 => '识别服务暂时不可用，请稍后再试',
          _ => '网络异常，请检查连接',
        },
        clipPath: clipPath,
        durationSec: durationSec,
      );
    }
  }

  void dispose() {
    _recorder.dispose();
  }
}
