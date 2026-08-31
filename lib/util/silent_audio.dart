import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'logger.dart';

final _logger = LoggerUtils.getLogger('SilentAudio');

Uri? _cachedSilentAudioUri;

/// dummy 源使用的静音音频 URI。
///
/// just_audio 的 asset:// scheme 仅 Android(ExoPlayer)支持；iOS/桌面
/// (AVPlayer/media_kit) 不认识 asset://，无法加载，导致 dummy 源播放时
/// 永远卡在加载中。这里把 silent.m4a 拷贝到临时目录用 file:// 提供。
///
/// 注意：iOS 的 tmp 目录可能被系统清理、容器路径也会随重装/升级变化，
/// 因此调用方不应持久化返回的 URI，每次需要时重新调用本方法。
Future<Uri> resolveSilentAudioUri() async {
  if (Platform.isAndroid) {
    return Uri(scheme: 'asset', path: '/assets/silent.m4a');
  }
  final cached = _cachedSilentAudioUri;
  if (cached != null && File.fromUri(cached).existsSync()) {
    return cached;
  }
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/silent.m4a');
    if (!file.existsSync()) {
      final data = await rootBundle.load('assets/silent.m4a');
      await file.writeAsBytes(data.buffer.asUint8List(
          data.offsetInBytes, data.lengthInBytes));
    }
    final uri = Uri.file(file.path);
    _cachedSilentAudioUri = uri;
    return uri;
  } catch (e) {
    _logger.warning('Failed to prepare silent audio file, '
        'falling back to asset uri: $e');
    return Uri(scheme: 'asset', path: '/assets/silent.m4a');
  }
}
