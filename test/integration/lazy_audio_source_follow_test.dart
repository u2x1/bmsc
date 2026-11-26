@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';

import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:test/test.dart';

/// 下载中的响应改为从 .part 跟随读取（不再用 ReplaySubject 缓冲在内存）：
/// 验证数据正确性、取消与失败语义。服务端分块慢速发送，确保请求发生在
/// 下载进行中。
void main() {
  late Directory tempDir;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serverSubscription;
  final bytes = List<int>.generate(1024 * 1024, (index) => (index * 7) % 251);
  var failAfterBytes = -1;

  setUp(() async {
    tempDir = await Directory('/data/tmp/opencode').createTemp('bmsc-follow-');
    failAfterBytes = -1;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverSubscription = server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mp4');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = bytes.length;
      const chunk = 32 * 1024;
      try {
        for (var offset = 0; offset < bytes.length; offset += chunk) {
          if (failAfterBytes >= 0 && offset >= failAfterBytes) {
            // 声明完整长度但提前结束：模拟 CDN 中途断流（issue #22）
            break;
          }
          response.add(bytes.sublist(offset, (offset + chunk).clamp(0, bytes.length)));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await response.close();
      } catch (_) {}
    });
  });

  tearDown(() async {
    await serverSubscription.cancel();
    await server.close(force: true);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  LazyAudioSource source() => LazyAudioSource(
        'BVfollow',
        1,
        localFile: File('${tempDir.path}/audio.m4a'),
        debugAudioUri:
            Uri.parse('http://${server.address.host}:${server.port}/a.m4s'),
        debugSkipCacheMetadata: true,
      );

  Future<List<int>> collect(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }

  test('下载中的整段与中途 range 请求均读到正确字节', () async {
    final s = source();
    final full = await s.request().timeout(const Duration(seconds: 5));
    final fullBytes = collect(full.stream);
    // 等下载推进一段后再发起落在已下载区间内、跨越下载前沿的 range 请求
    await Future<void>.delayed(const Duration(milliseconds: 80));
    const start = 40 * 1024;
    const end = 900 * 1024;
    final ranged = await s.request(start, end).timeout(const Duration(seconds: 5));
    expect(ranged.offset, start);
    final rangedBytes = await collect(ranged.stream);
    expect(rangedBytes, bytes.sublist(start, end));
    expect(await fullBytes, bytes);
    await s.downloadComplete.timeout(const Duration(seconds: 5));
    expect(File('${tempDir.path}/audio.m4a').readAsBytesSync(), bytes);
  });

  test('消费方中途取消不影响下载完成与缓存', () async {
    final s = source();
    final response = await s.request().timeout(const Duration(seconds: 5));
    var received = 0;
    late StreamSubscription<List<int>> sub;
    final cancelled = Completer<void>();
    sub = response.stream.listen((chunk) {
      received += chunk.length;
      if (received >= 64 * 1024 && !cancelled.isCompleted) {
        cancelled.complete(sub.cancel());
      }
    });
    await cancelled.future.timeout(const Duration(seconds: 5));
    await s.downloadComplete.timeout(const Duration(seconds: 5));
    expect(File('${tempDir.path}/audio.m4a').readAsBytesSync(), bytes);
  });

  test('下载中途断流时跟随读取的流收到错误而非挂起', () async {
    failAfterBytes = 256 * 1024;
    final s = source();
    final response = await s.request().timeout(const Duration(seconds: 5));
    Object? error;
    try {
      await collect(response.stream).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      fail('跟随读取的流在下载失败后挂起');
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect(File('${tempDir.path}/audio.m4a').existsSync(), isFalse);
  });
}
