@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:test/test.dart';

void main() {
  test('CDN 中途断流不保留坏缓存，fresh source 可完整重下', () async {
    final tempDir = await Directory('/data/tmp/opencode')
        .createTemp('bmsc-lazy-interruption-');
    final cacheFile = File('${tempDir.path}/audio.m4a');
    final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
    var connections = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      connections++;
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mp4');
      response.contentLength = bytes.length;
      if (connections == 1) {
        // 声明完整 Content-Length，但只发前缀就断开，模拟 issue #22。
        try {
          response.add(bytes.sublist(0, 4096));
          await response.flush();
          await response.close();
        } catch (_) {
          // 服务端也会发现实际长度不足；连接此时已经关闭。
        }
      } else {
        response.add(bytes);
        await response.close();
      }
    });

    LazyAudioSource source() => LazyAudioSource(
          'BVinterruption',
          1,
          localFile: cacheFile,
          debugAudioUri: Uri.parse(
              'http://${server.address.host}:${server.port}/audio.m4s'),
          debugSkipCacheMetadata: true,
        );

    try {
      final first = source();
      try {
        final interruptedResponse =
            await first.request().timeout(const Duration(seconds: 5));
        await interruptedResponse.stream.drain<void>();
      } catch (_) {
        // 播放侧收到断流错误是预期行为。
      }
      Object? downloadError;
      try {
        await first.downloadComplete.timeout(const Duration(seconds: 5));
      } catch (error) {
        downloadError = error;
      }

      expect(downloadError, isNotNull);
      expect(cacheFile.existsSync(), isFalse,
          reason: '截断文件不得提升为正式缓存');
      expect(File('${cacheFile.path}.part').existsSync(), isFalse,
          reason: '失败后必须清理 .part');

      final fresh = source();
      final completeResponse =
          await fresh.request().timeout(const Duration(seconds: 5));
      final received = <int>[];
      await for (final chunk in completeResponse.stream) {
        received.addAll(chunk);
      }
      await fresh.downloadComplete.timeout(const Duration(seconds: 5));

      expect(connections, 2);
      expect(received, bytes);
      expect(cacheFile.existsSync(), isTrue);
      expect(cacheFile.readAsBytesSync(), bytes);
    } finally {
      await serverSubscription.cancel();
      await server.close(force: true);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  });
}
