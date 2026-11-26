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

  test('主地址建连即断开时回退备用 CDN 地址（issue #22）', () async {
    final tempDir = await Directory('/data/tmp/opencode')
        .createTemp('bmsc-lazy-fallback-');
    final cacheFile = File('${tempDir.path}/audio.m4a');
    final bytes = List<int>.generate(64 * 1024, (index) => index % 251);
    // 主地址：接受连接后不发响应头直接断开（PCDN 节点的典型表现）
    final broken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var brokenConnections = 0;
    final brokenSubscription = broken.listen((socket) {
      brokenConnections++;
      socket.destroy();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });

    try {
      final source = LazyAudioSource(
        'BVfallback',
        1,
        localFile: cacheFile,
        debugAudioUri: Uri.parse('http://127.0.0.1:${broken.port}/a.m4s'),
        debugFallbackUris: [
          Uri.parse('http://${server.address.host}:${server.port}/a.m4s'),
        ],
        debugSkipCacheMetadata: true,
      );
      final response =
          await source.request().timeout(const Duration(seconds: 5));
      final received = <int>[];
      await for (final chunk in response.stream) {
        received.addAll(chunk);
      }
      await source.downloadComplete.timeout(const Duration(seconds: 5));

      expect(brokenConnections, greaterThanOrEqualTo(1));
      expect(received, bytes);
      expect(cacheFile.readAsBytesSync(), bytes);
    } finally {
      await brokenSubscription.cancel();
      await broken.close();
      await serverSubscription.cancel();
      await server.close(force: true);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  });

  test('PCDN 候选排到正规 CDN 之后，同类保持原顺序', () {
    final ordered = LazyAudioSource.orderCdnCandidates([
      'https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/a.m4s',
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/a.m4s',
      'https://abc.szbdyd.com/upgcxcode/a.m4s',
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/a.m4s',
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/a.m4s',
      '',
    ]).map((u) => u.host).toList();
    expect(ordered, [
      'upos-sz-mirrorcos.bilivideo.com',
      'upos-sz-mirrorali.bilivideo.com',
      'xy1x2x3x4xy.mcdn.bilivideo.cn',
      'abc.szbdyd.com',
    ]);
  });
}
