// copy from just_audio source code
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('LazyAudioSource');

/// This is an experimental audio source that caches the audio while it is being
/// downloaded and played. It is not supported on platforms that do not provide
/// access to the file system (e.g. web).
class LazyAudioSource extends StreamAudioSource {
  Future<HttpClientResponse>? _response;
  final String bvid;
  final int cid;
  final AsyncMemoizer<Uri> _uriMemoizer = AsyncMemoizer();
  final Future<File> localFile;
  int _progress = 0;
  final bool isLocal;
  final _requests = <_StreamingByteRangeRequest>[];
  final _downloadProgressSubject = BehaviorSubject<double>();
  bool _downloading = false;

  /// 实际解析选中的音频流音质 id（B 站 dash.audio[].id），未解析前为 null。
  int? qualityId;

  /// 实验：iOS 上把未缓存内容以「直播流」形式喂给 AVPlayer（200 chunked，
  /// 无 Content-Length/Content-Range）。AVPlayer 对 localhost 渐进式 MP4
  /// 会等全量下载完才开播（实测 moov 前置、MIME 正确均无效），伪装成
  /// 无界直播流可使其收到 moov 和片段后即开播。下载完成后由
  /// AudioService 无缝替换为本地文件源，恢复完整时长与拖动能力。
  static bool liveStreamExperimentEnabled = true;

  static bool get _serveAsLiveStream =>
      Platform.isIOS && liveStreamExperimentEnabled;

  /// Creates a [LockCachingAudioSource] to that provides [uri] to the player
  /// while simultaneously caching it to [file]. If no cache file is
  /// supplied, just_audio will allocate a cache file internally.
  ///
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  LazyAudioSource(
    this.bvid,
    this.cid, {
    File? localFile,
    super.tag,
  })  : localFile = localFile != null
            ? Future.value(localFile)
            : DatabaseManager.prepareFileForCaching(bvid, cid),
        isLocal = localFile != null {
    _init();
  }

  Future<Uri> get uri async {
    return await _uriMemoizer.runOnce(() async {
      final service = await BilibiliService.instance;
      final audio = await service.getAudio(bvid, cid);
      qualityId = audio?.firstOrNull?.id;
      return Uri.parse(audio?.firstOrNull?.baseUrl ?? '');
    });
  }

  Future<void> _init() async {
    final file = await localFile;
    _downloadProgressSubject.add(file.existsSync() ? 1.0 : 0.0);
  }

  /// Returns a [UriAudioSource] resolving directly to the cache file if it
  /// exists, otherwise returns `this`. This can be
  Future<IndexedAudioSource> resolve() async {
    final file = await localFile;
    return await file.exists() ? AudioSource.uri(Uri.file(file.path)) : this;
  }

  /// Emits the current download progress as a double value from 0.0 (nothing
  /// downloaded) to 1.0 (download complete).
  Stream<double> get downloadProgressStream => _downloadProgressSubject.stream;

  /// Removes the underlying cache files. It is an error to clear the cache
  /// while a download is in progress.
  Future<void> clearCache() async {
    if (_downloading) {
      throw Exception("Cannot clear cache while download is in progress");
    }
    _response = null;
    // 主文件 + .mime + .part 一并删除
    await DatabaseManager.deleteCacheFiles((await localFile).path);
    _progress = 0;
    _downloadProgressSubject.add(0.0);
  }

  Future<File> get _partialCacheFile async =>
      File('${(await localFile).path}.part');

  /// We use this to record the original content type of the downloaded audio.
  /// NOTE: We could instead rely on the cache file extension, but the original
  /// URL might not provide a correct extension. As a fallback, we could map the
  /// MIME type to an extension but we will need a complete dictionary.
  Future<File> get _mimeFile async => File('${(await localFile).path}.mime');

  /// B 站音频响应常为 application/octet-stream（或缺失），Android 上
  /// ExoPlayer 会探测格式，但 iOS AVPlayer 见 octet-stream 直接拒绝解码。
  /// 按 URL 扩展名推断真实音频类型，兼容两端。
  static String sniffMimeFromUri(Uri uri, [String fallback = 'audio/mpeg']) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m4s') || path.endsWith('.m4a') ||
        path.endsWith('.mp4')) {
      return 'audio/mp4';
    }
    if (path.endsWith('.aac') || path.endsWith('.adts')) {
      return 'audio/aac';
    }
    if (path.endsWith('.flac')) {
      return 'audio/flac';
    }
    if (path.endsWith('.ogg') || path.endsWith('.oga')) {
      return 'audio/ogg';
    }
    if (path.endsWith('.wav')) {
      return 'audio/wav';
    }
    return fallback;
  }

  /// 按文件头魔数嗅探真实音频格式。B 站 CDN 的 URL 通常无扩展名且
  /// Content-Type 为 application/octet-stream，只能按内容判断：
  /// B 站音频实际是 fMP4（开头为 ftyp box）。若响应头被错标为
  /// audio/mpeg，AVPlayer 会用 MP3 解析器扫全文件，拖到快下完才开播。
  static String? sniffMimeFromBytes(List<int> header) {
    if (header.length < 12) return null;
    bool eq(int i, int c) => header[i] == c;
    // ftyp box（MP4/M4A/m4s）：第 4-7 字节为 'ftyp'
    if (eq(4, 0x66) && eq(5, 0x74) && eq(6, 0x79) && eq(7, 0x70)) {
      return 'audio/mp4';
    }
    // 'ID3' 标签或 MP3 帧同步字（0xFFEx）
    if (eq(0, 0x49) && eq(1, 0x44) && eq(2, 0x33)) return 'audio/mpeg';
    if (eq(0, 0xFF) && (header[1] & 0xE0) == 0xE0) return 'audio/mpeg';
    // 'OggS'
    if (eq(0, 0x4F) && eq(1, 0x67) && eq(2, 0x67) && eq(3, 0x53)) {
      return 'audio/ogg';
    }
    // 'fLaC'
    if (eq(0, 0x66) && eq(1, 0x4C) && eq(2, 0x61) && eq(3, 0x43)) {
      return 'audio/flac';
    }
    // 'RIFF'....'WAVE'
    if (eq(0, 0x52) && eq(1, 0x49) && eq(2, 0x46) && eq(3, 0x46) &&
        eq(8, 0x57) &&
        eq(9, 0x41) &&
        eq(10, 0x56) &&
        eq(11, 0x45)) {
      return 'audio/wav';
    }
    return null;
  }

  static String sanitizeMime(String mime, [String fallback = 'audio/mpeg']) {
    if (mime == 'application/octet-stream') {
      return fallback;
    }
    if (mime.isEmpty || !mime.contains('/')) {
      return fallback;
    }
    return mime;
  }

  Future<String> _readCachedMimeType() async {
    // 内容魔数最权威：旧缓存的 .mime 可能是 octet-stream 或错误的
    // audio/mpeg（实际内容为 fMP4）。
    try {
      final raf = await (await localFile).open();
      final header = await raf.read(12);
      await raf.close();
      final sniffed = sniffMimeFromBytes(header);
      if (sniffed != null) return sniffed;
    } catch (_) {
      // 文件不可读时回退到 .mime 记录
    }
    final file = await _mimeFile;
    if (file.existsSync()) {
      return sanitizeMime(await file.readAsString());
    }
    return 'audio/mpeg';
  }

  /// Start downloading the whole audio file to the cache and fulfill byte-range
  /// requests during the download. There are 3 scenarios:
  ///
  /// 1. If the byte range request falls entirely within the cache region, it is
  /// fulfilled from the cache.
  /// 2. If the byte range request overlaps the cached region, the first part is
  /// fulfilled from the cache, and the region beyond the cache is fulfilled
  /// from a memory buffer of the downloaded data.
  /// 3. If the byte range request is entirely outside the cached region, a
  /// separate HTTP request is made to fulfill it while the download of the
  /// entire file continues in parallel.
  Future<HttpClientResponse> _fetch() async {
    final sw = Stopwatch()..start();
    _logger.info('[$bvid:$cid] fetch: start');
    _downloading = true;
    final partialCacheFile = await _partialCacheFile;
    final localFile = await this.localFile;

    File getEffectiveCacheFile() =>
        partialCacheFile.existsSync() ? partialCacheFile : localFile;

    var uri = await this.uri;
    _logger.info('[$bvid:$cid] fetch: playurl resolved (${sw.elapsed})');
    final headers = (await BilibiliService.instance).headers;

    final httpClient = HttpClient();
    var httpRequest = await _getUrl(httpClient, uri, headers: headers);
    var response = await httpRequest.close();
    _logger.info(
        '[$bvid:$cid] fetch: CDN response ${response.statusCode} (${sw.elapsed})');
    // B 站 playurl 的 baseUrl/backup 均有有效期（TTL 几小时），过期后可能返回
    // 403（防盗链）或 404（URL 失效）。二者都需重新解析音频源重试，并对
    // backupUrl 兜底——否则「播放中切歌/缓存后播放」会直接 HTTP 错误失败。
    if (response.statusCode == 403 || response.statusCode == 404) {
      await response.drain<void>();
      final service = await BilibiliService.instance;
      final audio = await service.getAudio(bvid, cid);
      final candidates = audio ?? <dynamic>[];
      // 新解析结果的 baseUrl 优先，其次 backupUrl 列表
      final retryUrls = <Uri>[
        for (final a in candidates)
          if (a.baseUrl.isNotEmpty) Uri.parse(a.baseUrl),
        for (final a in candidates)
          ...?a.backupUrl?.map((u) => Uri.parse(u)),
      ];
      Uri? retried;
      for (final u in retryUrls) {
        if (u == uri) continue;
        httpRequest = await _getUrl(httpClient, u, headers: headers);
        response = await httpRequest.close();
        if (response.statusCode == 200 || response.statusCode == 206) {
          retried = u;
          uri = u;
          break;
        }
        await response.drain<void>();
      }
      if (retried == null && retryUrls.isNotEmpty) {
        // 所有候选取不到 200：最后一次响应留给下方统一报错
        uri = retryUrls.first;
        httpRequest = await _getUrl(httpClient, uri, headers: headers);
        response = await httpRequest.close();
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.drain<void>();
        }
      }
    }
    if (response.statusCode != 200) {
      httpClient.close();
      throw Exception('HTTP Status Error: ${response.statusCode}');
    }
    (await _partialCacheFile).createSync(recursive: true);
    // TODO: Should close sink after done, but it throws an error.
    // ignore: close_sinks
    final sink = (await _partialCacheFile).openWrite();
    final sourceLength =
        response.contentLength == -1 ? null : response.contentLength;
    final rawMimeType = response.headers.contentType.toString();
    // iOS AVPlayer 不认 octet-stream：优先按 URL 扩展名推断；URL 无扩展名
    // 时留空，待首个数据块到达后按文件头魔数嗅探（B 站 CDN URL 通常无
    // 扩展名，实际内容为 fMP4）。
    var mimeType = sanitizeMime(rawMimeType, sniffMimeFromUri(uri, ''));
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final originSupportsRangeRequests =
        acceptRanges != null && acceptRanges != 'none';
    final inProgressResponses = <_InProgressCacheResponse>[];
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;
    subscription = response.listen((data) async {
      if (_progress == 0) {
        // 首个数据块：URL 嗅探落空时按内容魔数定格式
        if (mimeType.isEmpty) {
          mimeType = sniffMimeFromBytes(data) ?? 'audio/mpeg';
        }
        _logger.info(
            '[$bvid:$cid] fetch: first chunk ${data.length}B (${sw.elapsed}), '
            'mime=$mimeType, pendingRequests=${_requests.length}');
      }
      _progress += data.length;
      final newPercentProgress = (sourceLength == null)
          ? 0
          : (sourceLength == 0)
              ? 100
              : (100 * _progress ~/ sourceLength);
      updateProgress(newPercentProgress);
      sink.add(data);
      final readyRequests = _requests
          .where((request) =>
              !originSupportsRangeRequests ||
              request.start == null ||
              (request.start!) < _progress)
          .toList();
      final notReadyRequests = _requests
          .where((request) =>
              originSupportsRangeRequests &&
              request.start != null &&
              (request.start!) >= _progress)
          .toList();
      // Add this live data to any responses in progress.
      for (var cacheResponse in inProgressResponses) {
        final end = cacheResponse.end;
        if (end != null && _progress >= end) {
          // We've received enough data to fulfill the byte range request.
          final subEnd =
              min(data.length, max(0, data.length - (_progress - end)));
          cacheResponse.controller.add(data.sublist(0, subEnd));
          cacheResponse.controller.close();
        } else {
          cacheResponse.controller.add(data);
        }
      }
      inProgressResponses.removeWhere((element) => element.controller.isClosed);
      if (_requests.isEmpty) return;
      // Prevent further data coming from the HTTP source until we have set up
      // an entry in inProgressResponses to continue receiving live HTTP data.
      subscription.pause();
      await sink.flush();
      // Process any requests that start within the cache.
      for (var request in readyRequests) {
        _requests.remove(request);
        int? start, end;
        if (originSupportsRangeRequests) {
          start = request.start;
          end = request.end;
        } else {
          // If the origin doesn't support range requests, the proxy should also
          // ignore range requests and instead serve a complete 200 response
          // which the client (AV or exo player) should know how to deal with.
        }
        final effectiveStart = start ?? 0;
        // 直播流模式：始终向文件尾流式输出，但响应头不携带长度/偏移，
        // 客户端（AVPlayer）按无界直播流处理
        final effectiveEnd =
            _serveAsLiveStream ? sourceLength : (end ?? sourceLength);
        Stream<List<int>> responseStream;
        if (effectiveEnd != null && effectiveEnd <= _progress) {
          responseStream =
              getEffectiveCacheFile().openRead(effectiveStart, effectiveEnd);
        } else {
          final cacheResponse = _InProgressCacheResponse(end: effectiveEnd);
          inProgressResponses.add(cacheResponse);
          responseStream = Rx.concatEager([
            // NOTE: The cache file part of the stream must not overlap with
            // the live part. "_progress" should
            // to the cache file at the time
            getEffectiveCacheFile().openRead(effectiveStart, _progress),
            cacheResponse.controller.stream,
          ]);
        }
        if (_serveAsLiveStream) {
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: false,
            sourceLength: null,
            contentLength: null,
            offset: null,
            contentType: mimeType,
            stream: responseStream.asBroadcastStream(),
          ));
        } else {
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: originSupportsRangeRequests,
            sourceLength: start != null ? sourceLength : null,
            contentLength:
                effectiveEnd != null ? effectiveEnd - effectiveStart : null,
            offset: start,
            contentType: mimeType,
            stream: responseStream.asBroadcastStream(),
          ));
        }
      }
      subscription.resume();
      // Process any requests that start beyond the cache.
      for (var request in notReadyRequests) {
        _requests.remove(request);
        final start = request.start!;
        final end = request.end ?? sourceLength;
        final httpClient = HttpClient();

        final rangeRequest = _HttpRangeRequest(start, end);
        _getUrl(httpClient, uri, headers: {
          if (headers != null) ...headers,
          HttpHeaders.rangeHeader: rangeRequest.header,
        }).then((httpRequest) async {
          final response = await httpRequest.close();
          if (response.statusCode != 206) {
            httpClient.close();
            throw Exception('HTTP Status Error: ${response.statusCode}');
          }
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: originSupportsRangeRequests,
            sourceLength: sourceLength,
            contentLength: end != null ? end - start : null,
            offset: start,
            contentType: mimeType,
            stream: response.asBroadcastStream(),
          ));
        }, onError: (dynamic e, StackTrace? stackTrace) {
          request.fail(e, stackTrace);
        }).onError((Object e, StackTrace st) {
          request.fail(e, st);
        });
      }
    }, onDone: () async {
      _logger.info('[$bvid:$cid] fetch: download complete (${sw.elapsed})');
      if (sourceLength == null) {
        updateProgress(100);
      }
      for (var cacheResponse in inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }
      (await _partialCacheFile).renameSync(localFile.path);
      // 最终确定的 mime（可能来自内容嗅探）在下载完成后写入
      await (await _mimeFile).writeAsString(mimeType);
      await subscription.cancel();
      httpClient.close();
      _downloading = false;

      // Save cache metadata first
      await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);

      // Add a small delay before cleaning up cache to avoid database lock issues
      await Future.delayed(const Duration(milliseconds: 100));

      // Clean up cache as a separate operation
      DatabaseManager.cleanupCache(ignoreFile: localFile);
    }, onError: (Object e, StackTrace stackTrace) async {
      (await _partialCacheFile).deleteSync();
      httpClient.close();
      // Fail all pending requests
      for (final req in _requests) {
        req.fail(e, stackTrace);
      }
      _requests.clear();
      // Close all in progress requests
      for (final res in inProgressResponses) {
        res.controller.addError(e, stackTrace);
        res.controller.close();
      }
      _downloading = false;
    }, cancelOnError: true);
    return response;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    _logger.info('[$bvid:$cid] proxy request: start=$start end=$end');
    final file = await localFile;
    if (file.existsSync()) {
      final sourceLength = file.lengthSync();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: start != null ? sourceLength : null,
        contentLength: (end ?? sourceLength) - (start ?? 0),
        offset: start,
        contentType: await _readCachedMimeType(),
        stream: file.openRead(start, end).asBroadcastStream(),
      );
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    _response ??=
        _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
      // So that we can restart later
      _response = null;
      // Cancel any pending request
      for (final req in _requests) {
        req.fail(error, stackTrace);
      }
      return Future<HttpClientResponse>.error(error as Object, stackTrace);
    });
    return byteRangeRequest.future.then((response) {
      response.stream.listen((event) {}, onError: (Object e, StackTrace st) {
        // So that we can restart later
        _response = null;
        // Cancel any pending request
        for (final req in _requests) {
          req.fail(e, st);
        }
      });
      return response;
    });
  }
}

/// When a byte range request on a [LockCachingAudioSource] overlaps partially
/// with the cache file and partially with the live HTTP stream, the consumer
/// needs to first consume the cached part before the live part. This class
/// provides a place to buffer the live part until the consumer reaches it, and
/// also keeps track of the [end] of the byte range so that the producer knows
/// when to stop adding data.
class _InProgressCacheResponse {
  // NOTE: This isn't necessarily memory efficient. Since the entire audio file
  // will likely be downloaded at a faster rate than the rate at which the
  // player is consuming audio data, it is also likely that this buffered data
  // will never be used.
  // TODO: Improve this code.
  // ignore: close_sinks
  final controller = ReplaySubject<List<int>>();
  final int? end;
  _InProgressCacheResponse({
    required this.end,
  });
}

/// Request parameters for a [StreamAudioSource].
class _StreamingByteRangeRequest {
  /// The start of the range request.
  final int? start;

  /// The end of the range request.
  final int? end;

  /// Completes when the response is available.
  final _completer = Completer<StreamAudioResponse>();

  _StreamingByteRangeRequest(this.start, this.end);

  /// The response for this request.
  Future<StreamAudioResponse> get future => _completer.future;

  /// Completes this request with the given [response].
  void complete(StreamAudioResponse response) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(response);
  }

  /// Fails this request with the given [error] and [stackTrace].
  void fail(dynamic error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.completeError(error as Object, stackTrace);
  }
}

Future<HttpClientRequest> _getUrl(HttpClient client, Uri uri,
    {Map<String, String>? headers}) async {
  final request = await client.getUrl(uri);
  if (headers != null) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    request.headers.clear();
    request.headers.set(HttpHeaders.contentLengthHeader, '0');
    headers.forEach((name, value) => request.headers.set(name, value));
    if (host != null) {
      request.headers.set(HttpHeaders.hostHeader, host);
    }
    if (client.userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, client.userAgent!);
    }
  }
  // Match ExoPlayer's native behavior
  request.maxRedirects = 20;
  return request;
}

/// Encapsulates the start and end of an HTTP range request.
class _HttpRangeRequest {
  /// The starting byte position of the range request.
  final int start;

  /// The last byte position of the range request, or `null` if requesting
  /// until the end of the media.
  final int? end;

  /// The end byte position (exclusive), defaulting to `null`.
  int? get endEx => end == null ? null : end! + 1;

  _HttpRangeRequest(this.start, this.end);

  /// Format a range header for this request.
  String get header =>
      'bytes=$start-${end != null ? (end! - 1).toString() : ""}';
}
