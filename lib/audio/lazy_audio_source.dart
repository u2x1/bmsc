// copy from just_audio source code
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
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
  /// 无 Content-Length/Content-Range）。
  ///
  /// ⚠️ 真机实测（iPhone, iOS 27）该模式不可播：AVPlayer 对 localhost
  ///  chunked 无界流始终不开播（进度恒 0），下载虽在后台完成（产生缓存），
  /// 播放却永久卡住。已默认关闭——未缓存内容改走与缓存文件完全一致的
  /// 渐进式响应（正确 MIME + 长度 + range），由 DarwinLoadControl 的
  /// 3 秒前向缓冲控制开播延迟。保留开关仅供后续排查参考。
  static bool liveStreamExperimentEnabled = false;

  /// 直播流模式的最大文件体积。直播流模式下 AVPlayer 只超前消费前向
  /// 缓冲（3s），其余已下载数据全部堆在代理的内存缓冲
  ///（_InProgressCacheResponse 的 ReplaySubject）里，峰值 ≈ 文件大小
  /// × 并发流数。超过阈值（如 Hi-Res 大文件）回退为带长度 + range 的
  /// 渐进式响应，由 DarwinLoadControl 的 3 秒前向缓冲控制开播延迟，
  /// 以开播延迟换取内存峰值上限，避免触发 jetsam。
  static int liveStreamMaxBytes = 32 * 1024 * 1024;

  /// iOS 开播加速：对外宣告的资源长度上限。真机实测（日志佐证）：
  /// AVPlayer 对 localhost 渐进式 MP4 一律吞完整资源才 readyToPlay，
  /// preferredForwardBufferDuration / preferredPeakBitRate 均无效
  ///（76MB 文件播前等 ~12s 全量下载）。既然它按宣告长度全量吞，就把
  /// 宣告长度截断为前 N MB——moov 前置时长信息完整，吞 N MB 即开播；
  /// 后台下载完成后由 AudioService 换入完整文件源，恢复真实长度与
  /// 全程拖动。仅对 moov 前置内容启用（moov 在尾部时截断会让
  /// AVPlayer 找不到 moov，回退为不截断）。
  static int advertisedLengthCapBytes = 4 * 1024 * 1024;

  /// 本次下载是否以直播流形式服务。响应头到达后按文件体积决定
  ///（见 _fetch），决定后本次下载内保持不变。
  bool _serveAsLiveStream = false;

  static bool _shouldServeAsLiveStream(int? sourceLength) =>
      Platform.isIOS &&
      liveStreamExperimentEnabled &&
      (sourceLength == null || sourceLength <= liveStreamMaxBytes);

  /// 下载完整结束（.part 已改名为主文件、元数据已落库）时完成；
  /// 下载失败/被取消时以错误完成。不能用 downloadProgressStream 的
  /// 1.0 事件代替：该事件在最后一个数据块回调中同步发出，早于 onDone
  /// 中的 renameSync——此时监听者检查主文件必然不存在（microtask
  /// 时序竞态，已实测复现）。
  final _downloadCompleteCompleter = Completer<void>();
  Future<void> get downloadComplete => _downloadCompleteCompleter.future;

  /// 全局下载互斥：同一 bvid:cid 同时只允许一个实例下载。重复源（收藏夹
  /// 中同一视频出现两次、看门狗克隆与 hijack 撞车等）若并发写同一
  /// .part，内容互相污染，且先完成的 onDone 改名后后者 rename 必炸
  ///（真机 SEVERE 日志实证）。键用 bvid:cid 而非文件路径：路径需要
  /// await 才能得到，无法保证「检查+占位」的原子性。
  static final Map<String, Future<void>> _inflightDownloads = {};

  String get _downloadKey => '$bvid:$cid';

  StreamSubscription<List<int>>? _subscription;
  HttpClient? _httpClient;
  IOSink? _sink;
  final _inProgressResponses = <_InProgressCacheResponse>[];

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
    // 避免 downloadComplete 在无监听者时以错误完成触发 unhandled error
    _downloadCompleteCompleter.future.ignore();
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
    if (file.existsSync()) {
      _downloadProgressSubject.add(1.0);
      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.complete();
      }
    } else {
      _downloadProgressSubject.add(0.0);
    }
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

  /// 取消进行中的下载并清理半成品（.part、内存缓冲、挂起请求）。
  /// 用于播放中切换音质等需要立即废弃当前下载的场景：旧下载若不取消，
  /// 会与新源的下载写同一 .part 路径，内容互相污染。调用后可通过
  /// request() 重新开始下载（downloadComplete 已完成，不会再次触发）。
  Future<void> cancelDownload() async {
    if (!_downloading) return;
    _downloading = false;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    try {
      _httpClient?.close(force: true);
    } catch (_) {}
    _httpClient = null;
    for (final req in _requests) {
      req.fail(Exception('download cancelled'));
    }
    _requests.clear();
    for (final res in _inProgressResponses) {
      if (!res.controller.isClosed) {
        res.controller.addError(Exception('download cancelled'));
        res.controller.close();
      }
    }
    _inProgressResponses.clear();
    try {
      final part = await _partialCacheFile;
      if (part.existsSync()) await part.delete();
    } catch (_) {}
    // onDone 可能在 await 窗口内已完整跑完（rename + 落库 + completer
    // 成功完成）：此时缓存实际已成功，不能把进度重置为 0。
    if (!_downloadCompleteCompleter.isCompleted) {
      _progress = 0;
      _downloadProgressSubject.add(0.0);
    }
    _response = null;
    if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
      _inflightDownloads.remove(_downloadKey);
    }
    if (!_downloadCompleteCompleter.isCompleted) {
      _downloadCompleteCompleter
          .completeError(Exception('download cancelled'));
    }
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
    // styp box（DASH 分片开头）：同为 fMP4 结构
    if (eq(4, 0x73) && eq(5, 0x74) && eq(6, 0x79) && eq(7, 0x70)) {
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

    final httpClient = _httpClient = HttpClient();
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
      // 新解析结果的 baseUrl 优先，其次 backupUrl 列表；记录每个候选
      // 对应的音质 id，重试落到其他音质流时同步更正 qualityId。
      final retryCandidates = <({Uri url, int id})>[
        for (final a in candidates)
          if (a.baseUrl.isNotEmpty) (url: Uri.parse(a.baseUrl), id: a.id as int),
        for (final a in candidates)
          ...?a.backupUrl?.map((u) => (url: Uri.parse(u), id: a.id as int)),
      ];
      Uri? retried;
      for (final c in retryCandidates) {
        if (c.url == uri) continue;
        httpRequest = await _getUrl(httpClient, c.url, headers: headers);
        response = await httpRequest.close();
        if (response.statusCode == 200 || response.statusCode == 206) {
          retried = c.url;
          uri = c.url;
          qualityId = c.id;
          break;
        }
        await response.drain<void>();
      }
      if (retried == null && retryCandidates.isNotEmpty) {
        // 所有候选取不到 200：最后一次响应留给下方统一报错
        uri = retryCandidates.first.url;
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
    final sink = _sink = (await _partialCacheFile).openWrite();
    final sourceLength =
        response.contentLength == -1 ? null : response.contentLength;
    // 响应头到达后按文件体积决定本次下载是否以直播流形式服务
    _serveAsLiveStream = _shouldServeAsLiveStream(sourceLength);
    final rawMimeType = response.headers.contentType.toString();
    // iOS AVPlayer 不认 octet-stream：优先按 URL 扩展名推断；URL 无扩展名
    // 时留空，待首个数据块到达后按文件头魔数嗅探（B 站 CDN URL 通常无
    // 扩展名，实际内容为 fMP4）。
    var mimeType = sanitizeMime(rawMimeType, sniffMimeFromUri(uri, ''));
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final originSupportsRangeRequests =
        acceptRanges != null && acceptRanges != 'none';
    final inProgressResponses = _inProgressResponses;
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;
    /// 实际宣告的截断长度：静态上限 advertisedLengthCapBytes，且至少覆盖
    /// 约 45s 可播时长（按 tag 时长与真实大小折算码率）——否则慢网络下
    /// AVPlayer 播完宣告的数据而完整下载未竟，item 会提前结束或卡死
    ///（如 Hi-Res：4MB 仅约 16s，下载需 >5MB/s 才能赶在播完前完成）。
    /// 普通 192K 文件 4MB 已覆盖约 170s，行为不变。
    int advertisedLengthCap(int realLength) {
      var cap = advertisedLengthCapBytes;
      final t = tag;
      final duration = t is MediaItem ? t.duration : null;
      final seconds = duration?.inSeconds ?? 0;
      if (seconds > 45) {
        final bytesFor45s = realLength * 45 ~/ seconds;
        if (bytesFor45s > cap) cap = bytesFor45s;
      }
      return min(cap, realLength);
    }

    // iOS 截断宣告的 moov 位置探测：逐个数据块走过顶层 box，
    // moov 先于 mdat 出现才允许截断宣告（见 advertisedLengthCapBytes）。
    final moovProbe = BytesBuilder(copy: false);
    var moovFront = false;
    var moovTail = false;
    void probeMoovPosition(List<int> data) {
      if (moovFront || moovTail) return;
      moovProbe.add(data);
      final bytes = moovProbe.toBytes();
      final bd = ByteData.sublistView(bytes);
      var offset = 0;
      while (offset + 8 <= bytes.length) {
        final size32 = bd.getUint32(offset);
        final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
        if (type == 'moov') {
          moovFront = true;
          final real = sourceLength;
          if (real != null && real > advertisedLengthCapBytes) {
            _logger.info('[$bvid:$cid] moov front: advertising length cap '
                '${advertisedLengthCap(real)}/$real');
          }
          return;
        }
        if (type == 'mdat') {
          moovTail = true;
          return;
        }
        int advance;
        if (size32 == 1) {
          if (offset + 16 > bytes.length) return;
          advance = bd.getUint64(offset + 8);
        } else if (size32 == 0) {
          return; // box 延伸至 EOF，无法继续扫描
        } else {
          advance = size32;
        }
        if (advance < 8) return;
        offset += advance;
      }
      // 1MB 内未见到 moov/mdat：保守按 moov 在尾部处理，不做截断
      if (moovProbe.length > 1024 * 1024) moovTail = true;
    }

    /// 对客户端（AVPlayer）宣告的资源长度：moov 前置的大文件截断为
    /// advertisedLengthCap(real)，使其吞 N MB 即开播；其余情况如实。
    int? advertisedSourceLength() {
      final real = sourceLength;
      if (Platform.isIOS &&
          moovFront &&
          real != null &&
          real > advertisedLengthCapBytes) {
        return advertisedLengthCap(real);
      }
      return real;
    }

    subscription = _subscription = response.listen((data) async {
      if (_progress == 0) {
        // 首个数据块：内容魔数最权威，总是覆盖响应头/URL 推断（CDN 可能
        // 把 fMP4 错标为 audio/mpeg，AVPlayer 会用 MP3 解析器扫全文件，
        // 拖到快下完才开播）；魔数无法识别时才回退到既有推断。
        final sniffed = sniffMimeFromBytes(data);
        if (sniffed != null) {
          mimeType = sniffed;
        } else if (mimeType.isEmpty) {
          mimeType = 'audio/mpeg';
        }
        _logger.info(
            '[$bvid:$cid] fetch: first chunk ${data.length}B (${sw.elapsed}), '
            'mime=$mimeType, pendingRequests=${_requests.length}');
      }
      probeMoovPosition(data);
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
        // 客户端（AVPlayer）按无界直播流处理；
        // 渐进式模式：对外宣告的长度可能被截断（见 advertisedLengthCapBytes），
        // 数据服务范围同步钳制在宣告长度内（宣告范围内的数据随下载按序到达）。
        final advertised = advertisedSourceLength();
        var effectiveEnd = _serveAsLiveStream ? sourceLength : (end ?? advertised);
        if (!_serveAsLiveStream &&
            effectiveEnd != null &&
            advertised != null &&
            effectiveEnd > advertised) {
          effectiveEnd = advertised;
        }
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
            sourceLength: start != null ? advertised : null,
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
      // 注：此处如实宣告真实 sourceLength（不做截断）——截断宣告后 AVPlayer
      // 视资源为 N MB，只有拖动越过宣告边界时才可能产生这类请求，此时
      // 如实服务才是正确行为。
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
      // 防御式改名：.part 可能已被并发清理（取消/其他实例）。主文件已
      // 存在视为成功（同路径在途下载已完成并改名）；两者都不存在则
      // 下载产物丢失，按失败收尾（不落库、以错误完成 completer）。
      try {
        final part = await _partialCacheFile;
        if (part.existsSync()) {
          part.renameSync(localFile.path);
        }
      } catch (e) {
        _logger.warning('[$bvid:$cid] rename partial cache failed: $e');
      }
      if (!localFile.existsSync()) {
        _logger.severe('[$bvid:$cid] download artifact missing after done');
        _downloading = false;
        if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
          _inflightDownloads.remove(_downloadKey);
        }
        if (!_downloadCompleteCompleter.isCompleted) {
          _downloadCompleteCompleter
              .completeError(StateError('download artifact missing'));
        }
        await subscription.cancel();
        httpClient.close();
        return;
      }
      // 最终确定的 mime（可能来自内容嗅探）在下载完成后写入
      await (await _mimeFile).writeAsString(mimeType);
      await subscription.cancel();
      httpClient.close();
      _downloading = false;

      // Save cache metadata first
      await DatabaseManager.saveCacheMetadata(bvid, cid, localFile);

      // 文件已改名、元数据已落库：此刻起换源监听者可安全使用主文件
      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.complete();
      }
      if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
        _inflightDownloads.remove(_downloadKey);
      }

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
      if (identical(_inflightDownloads[_downloadKey], downloadComplete)) {
        _inflightDownloads.remove(_downloadKey);
      }
      if (!_downloadCompleteCompleter.isCompleted) {
        _downloadCompleteCompleter.completeError(e, stackTrace);
      }
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
    // 同 bvid:cid 的他方实例正在下载同一文件：等待其完成后改从文件
    // 服务（他方失败则落空到下方自己的下载流程）
    if (!_downloading) {
      final inflight = _inflightDownloads[_downloadKey];
      if (inflight != null && !identical(inflight, downloadComplete)) {
        _logger.info('[$bvid:$cid] request: waiting for in-flight download');
        try {
          await inflight;
        } catch (_) {}
        if (file.existsSync()) {
          _logger.info('[$bvid:$cid] request: serving from in-flight result');
          _downloadProgressSubject.add(1.0);
          if (!_downloadCompleteCompleter.isCompleted) {
            _downloadCompleteCompleter.complete();
          }
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
      }
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    if (_response == null) {
      // 占位注册与启动下载之间无 await，并发 request 在此原子交错：
      // 后到者在上方 inflight 检查处必然看到占位并转为等待
      _inflightDownloads[_downloadKey] ??= downloadComplete;
      _response =
          _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
        // So that we can restart later
        _response = null;
        // Cancel any pending request
        for (final req in _requests) {
          req.fail(error, stackTrace);
        }
        return Future<HttpClientResponse>.error(error as Object, stackTrace);
      });
    }
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
