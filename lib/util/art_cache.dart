import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'logger.dart';

final _logger = LoggerUtils.getLogger('ArtCache');

final _inflight = <String, Future<Uri?>>{};

/// 将封面图下载到缓存目录并返回其 file:// URI。
///
/// audio_service 的 iOS 端不从 MediaItem.artUri 加载封面，只认
/// extras['artCacheFile'] 指向的本地文件；且 artUri 为 http://，即使
/// 原生加载也会被 ATS 拦截。这里统一下载到 Library/Caches/art（hdslb
/// 支持 https，下载时升级 scheme 以过 ATS），供锁屏/通知封面使用。
///
/// 并发同一 URL 共享一次下载；失败后下次调用可重试。
Future<Uri?> resolveArtCacheFile(Uri? artUri) {
  if (artUri == null) return Future.value(null);
  // 本地音乐封面已是本地文件，直接透传：走 HTTP 下载会因无 host
  // 报「No host specified in URI」，且无需缓存
  if (artUri.isScheme('file')) return Future.value(artUri);
  final key = artUri.toString();
  final cached = _inflight[key];
  if (cached != null) return cached;
  final future = _download(artUri).whenComplete(() => _inflight.remove(key));
  _inflight[key] = future;
  return future;
}

Future<Uri?> _download(Uri artUri) async {
  File? tmp;
  try {
    final segments = artUri.pathSegments;
    if (segments.isEmpty) return null;
    // B 站封面路径（bfs/.../<hash>.jpg）文件名本身唯一，可直接做缓存键
    final dir =
        Directory('${(await getApplicationCacheDirectory()).path}/art');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File('${dir.path}/${segments.last}');
    if (file.existsSync()) return file.uri;

    final uri =
        artUri.scheme == 'http' ? artUri.replace(scheme: 'https') : artUri;
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        await response.drain<void>();
        _logger.warning('art download ${response.statusCode}: $uri');
        return null;
      }
      // 先写临时文件、完成后 rename：中途失败不留半截文件被当缓存命中
      tmp = File('${file.path}.tmp');
      final sink = tmp.openWrite();
      await response.pipe(sink).timeout(const Duration(seconds: 15));
      await tmp.rename(file.path);
      tmp = null;
      return file.uri;
    } finally {
      client.close();
    }
  } catch (e) {
    _logger.warning('art cache download failed: $e');
    try {
      await tmp?.delete();
    } catch (_) {}
    return null;
  }
}
