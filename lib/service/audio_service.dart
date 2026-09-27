import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/silent_audio.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('AudioService');

/// 一个可用音质档位及其存储占用。
class AudioQualityInfo {
  final int id;
  final String label;

  /// 该档位音频文件的精确大小（字节），通过 Range 请求读取；
  /// 读取失败为 null。
  final int? sizeBytes;

  /// 是否为当前播放流实际使用的音质。
  final bool isCurrent;

  const AudioQualityInfo({
    required this.id,
    required this.label,
    required this.sizeBytes,
    required this.isCurrent,
  });
}

class AudioService {
  static final instance = _init();

  // ignore: deprecated_member_use
  final playlist = ConcatenatingAudioSource(
    useLazyPreparation: true,
    children: [],
  );
  final player = AudioPlayer(
    handleInterruptions: false,
    audioLoadConfiguration: AudioLoadConfiguration(
      darwinLoadControl: DarwinLoadControl(
        // localhost 代理带宽被 AVPlayer 估计为近乎无限，默认策略会尝试缓冲
        // 整个文件才开播（LazyAudioSource 无法边下边播）。限制前向缓冲为
        // 3 秒，playbackLikelyToMinimizeStalling 提前满足，缓冲约 3 秒即开播；
        // 同时关闭自动等待避免多曲队列预加载互相阻塞。音频码率低
        // （192K 时 3s ≈ 72KB），本地代理 + CDN 补缓冲很快，欠载风险小。
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: const Duration(seconds: 3),
        // 注：preferredPeakBitRate 对 localhost 渐进式 MP4 无效——真机日志
        // 实测 AVPlayer 仍吞完整资源才开播（76MB 等了 12s 全量下载）。
        // 长文件开播加速由 LazyAudioSource.advertisedLengthCapBytes 的
        // 截断宣告实现。
      ),
    ),
  );
  late AudioSession session;
  Timer? _historyReportTimer;
  Timer? _playPositionTimer;
  Timer? _sleepTimer;
  Timer? _fadeTimer;
  final _sleepTimerSubject = BehaviorSubject<int?>.seeded(null);
  final _fadeOutDuration = 15; // 15 seconds fade out
  final _speedSubject = BehaviorSubject<double>.seeded(1.0);
  static const _historyUpdateInterval = 5; // 5s
  int _historyUpdateCnt = 0;

  StreamSubscription<AudioInterruptionEvent>? _interruptionEventSubscription;
  bool _playInterrupted = false;
  bool _hijacking = false;
  double? _volumeBeforeDuck;
  double? _userVolumeBeforeFade;

  // 获取定时停止播放的流
  Stream<int?> get sleepTimerStream => _sleepTimerSubject.stream;

  // 获取播放速度的流
  Stream<double> get speedStream => _speedSubject.stream;

  // 获取当前播放速度
  double get currentSpeed => _speedSubject.value;

  static Future<AudioService> _init() async {
    final x = AudioService();
    try {
      final restored = await SharedPreferencesService.getPlaylist();
      if (restored != null) {
        await x.playlist.addAll(restored.$1);
      }
      // iOS 上对空 playlist 调 setAudioSource(preload: true) 会因原生端不再
      // 广播 ProcessingState.ready 而永久挂起（just_audio 0.10.5 iOS bug）。
      // 但完全不调用则 playlist 不会 attach 到 player，后续 addAll 不会传播、
      // play() 的 completer 永不完成，首次播放直接卡死。因此空列表时以
      // preload: false 挂载：不触发原生 load，又保证 playlist 修改正常传播。
      // 慢网络下 preload 等待首批流数据可能长时间挂起（iOS 需经 localhost
      // 代理拉流），超时放行让初始化继续，底层加载完成后播放器状态自愈。
      try {
        await x.player
            .setAudioSource(x.playlist,
                preload: x.playlist.children.isNotEmpty)
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        _logger.warning(
            'AudioService._init: setAudioSource failed/timeout: $e');
      }
      final position = await SharedPreferencesService.getPlayPosition();
      if (restored != null && restored.$2 < x.playlist.length) {
        // 以下 seek 在 iOS 上曾因 AVPlayer 等待流数据而挂起，现已有
        // 兜底超时保护：恢复失败只记录警告，不阻塞初始化。
        try {
          await x.player
              .seek(null, index: restored.$2)
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          _logger.warning('AudioService._init: seek index failed, skip restore');
        }
        // 等待播放器就绪后再恢复进度。iOS 上曾因 AVPlayer 等待流数据而
        // 挂起，缩短兜底为 1 秒；Android 保留 3 秒避免慢网络下频繁超时。
        try {
          await x.player.processingStateStream
              .firstWhere((s) => s == ProcessingState.ready)
              .timeout(Duration(seconds: Platform.isIOS ? 1 : 3),
                  onTimeout: () => ProcessingState.ready);
        } catch (e) {
          _logger.warning('AudioService._init: wait ready failed');
        }
        try {
          await x.player
              .seek(Duration(seconds: position))
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          _logger.warning('AudioService._init: seek position failed');
        }
      }
      await x.restorePlayMode();

      // 恢复定时停止播放设置
      final sleepTimerMinutes =
          await SharedPreferencesService.getSleepTimerMinutes();
      if (sleepTimerMinutes != null) {
        // 如果剩余时间小于1分钟，则不恢复定时器
        if (sleepTimerMinutes > 0) {
          await x.setSleepTimer(sleepTimerMinutes);
        }
      }

      // 恢复播放速度设置
      final speed = await SharedPreferencesService.getPlaybackSpeed();
      if (speed != null) {
        await x.setPlaybackSpeed(speed);
      }
    } catch (e) {
      _logger.severe('Failed to restore playlist', e);
    }
    try {
      x.session = await AudioSession.instance;
      await x.session.configure(const AudioSessionConfiguration.music());
      // 注：automaticallyWaitsToMinimizeStalling / preferredForwardBufferDuration
      // 已在 AudioPlayer 构造时通过 darwinLoadControl 配置（见 player 定义）。
      await x.hookEvents();
    } catch (e) {
      _logger.severe('AudioService._init: session setup failed', e);
    }
    // 注册缓存清理保护：正在播放的本地缓存文件不被删除（iOS 经本地代理
    // 流式读文件，删除会立即中断播放）
    DatabaseManager.cacheFileGuard = () async {
      final source = x.player.sequenceState.currentSource;
      if (source is LazyAudioSource && source.isLocal) {
        return {(await source.localFile).path};
      }
      return <String>{};
    };
    return x;
  }

  /// 通过 `Range: bytes=0-0` 请求读取 Content-Range 获得音频文件的
  /// 精确大小（字节）。失败返回 null。
  Future<int?> _fetchExactSize(Uri url) async {
    final client = HttpClient();
    try {
      final headers = (await BilibiliService.instance).headers;
      final request = await client.getUrl(url);
      headers?.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      int? total;
      if (response.statusCode == HttpStatus.partialContent) {
        // Content-Range: bytes 0-0/12345678
        final contentRange =
            response.headers.value(HttpHeaders.contentRangeHeader);
        if (contentRange != null && contentRange.contains('/')) {
          total = int.tryParse(contentRange.split('/').last);
        }
      } else if (response.statusCode == HttpStatus.ok &&
          response.contentLength > 0) {
        total = response.contentLength;
      }
      await response.drain();
      return total;
    } catch (e) {
      _logger.warning('fetch exact audio size failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 当前曲目的可用音质列表（含每档精确存储占用，读取失败则该档无大小）。
  /// 返回 null 表示当前无有效播放曲目或仍为 dummy 源（真实源未加载）。
  Future<List<AudioQualityInfo>?> getCurrentTrackQualities() async {
    final source = player.sequenceState.currentSource;
    final tag = source?.tag;
    final extras = tag?.extras;
    if (tag == null || extras == null || extras['dummy'] == true) return null;
    final bvid = extras['bvid'];
    final cid = extras['cid'];
    if (bvid == null || cid == null) return null;
    final audios = await (await BilibiliService.instance).getAudio(bvid, cid);
    if (audios == null || audios.isEmpty) return null;
    // LazyAudioSource 在解析后携带 qualityId；已换入本地文件源时回退到
    // 换源时写入 extras 的标记。
    final currentId = source is LazyAudioSource
        ? source.qualityId
        : extras['qualityId'] as int?;
    final seen = <int>{};
    final uniqueAudios = [
      for (final Audio a in audios)
        if (seen.add(a.id)) a,
    ];
    // 并发读取各档位精确大小
    final sizes = await Future.wait(uniqueAudios.map((a) => a.baseUrl.isNotEmpty
        ? _fetchExactSize(Uri.parse(a.baseUrl))
        : Future<int?>.value()));
    final infos = [
      for (var i = 0; i < uniqueAudios.length; i++)
        AudioQualityInfo(
          id: uniqueAudios[i].id,
          label: SharedPreferencesService.audioQualityLabels[uniqueAudios[i].id] ??
              '未知音质 (${uniqueAudios[i].id})',
          sizeBytes: sizes[i],
          isCurrent: uniqueAudios[i].id == currentId,
        ),
    ];
    // 按大小降序，未知大小排最后
    infos.sort((a, b) =>
        (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1));
    return infos;
  }

  /// 切换正在播放曲目的音质：更新全局偏好并立即重建当前播放源，
  /// 保持播放位置与播放状态。返回是否切换成功。
  Future<bool> switchCurrentTrackQuality(int qualityId) async {
    final index = player.currentIndex;
    final source = player.sequenceState.currentSource;
    final tag = source?.tag;
    final extras = tag?.extras;
    if (index == null || tag == null || extras == null) return false;
    if (extras['dummy'] == true) return false;
    final bvid = extras['bvid'];
    final cid = extras['cid'];
    if (bvid == null || cid == null) return false;
    // 与其他 playlist 变更（hijack/换源/看门狗）互斥，避免并发改坏队列。
    // 旗标必须在首个 await 之前置位，否则准备期间换源回调可并发插入。
    if (_hijacking || _swapping) {
      _logger.warning('quality switch: playlist mutation in progress, reject');
      return false;
    }

    _hijacking = true;
    _swapping = true;
    try {
      await SharedPreferencesService.setAudioQuality(qualityId);

      final position = player.position;
      final wasPlaying = player.playing;
      await player.pause();

      // 取消旧源进行中的下载并清理 .part：否则旧下载与新源的下载写同一
      // .part 路径，内容互相污染（换名/元数据也会错乱）。
      if (source is LazyAudioSource) {
        await source.cancelDownload();
      }
      // 删除旧音质缓存（同一路径将被新源复用），强制走网络按新偏好解析
      await DatabaseManager.removeCacheEntry(bvid, cid, force: true);

      // 复核时效性：上述 await 期间用户可能已切歌/队列可能已推进——
      // 旧源不再是当前项时放弃切换，绝不把播放强拽回旧曲目。
      final curIdx = _indexOfInPlaylist(source);
      if (curIdx == null ||
          !identical(player.sequenceState.currentSource, source)) {
        _logger.warning('quality switch: source no longer current, abort');
        return false;
      }

      final newSource = LazyAudioSource(
        bvid,
        cid,
        localFile: null,
        tag: MediaItem(
          id: tag.id,
          title: tag.title,
          artist: tag.artist,
          artUri: tag.artUri,
          duration: tag.duration,
          extras: {...extras, 'cached': false},
        ),
      );
      // iOS：记录切换时的位置。换源（_swapToCachedFileWhenDone）时若新源
      // 无实际播放进展（位置恒 0，渐进式 seek 未生效）则恢复到此位置；
      // 已有进展则以 player.position 为准。Android 换源监听不会注册，
      // 无需记录。
      if (Platform.isIOS) {
        _pendingSeekPositions[newSource] = position;
      }
      if (Platform.isIOS) {
        // iOS 安全顺序（同 hijack）：先插 → 显式跳 → 再删。
        // 定位一律 identical，禁用固定 index+1（推进竞态会把位置
        // 种到下一P 上——真机多P实测）。
        await doAndSavePlaylist(() async {
          await playlist.insertAll(curIdx + 1, [newSource]);
        });
        final insertIdx = _indexOfInPlaylist(newSource);
        if (insertIdx != null) {
          try {
            await player
                .seek(position, index: insertIdx)
                .timeout(const Duration(seconds: 5));
          } catch (e) {
            _logger.warning('quality switch seek failed: $e');
          }
          if (wasPlaying) await player.play();
        } else {
          _logger.warning('quality switch: new source vanished from playlist');
        }
        await doAndSavePlaylist(() async {
          final oldIdx = _indexOfInPlaylist(source);
          if (oldIdx != null) await playlist.removeAt(oldIdx);
        });
      } else {
        await doAndSavePlaylist(() async {
          await playlist.insertAll(curIdx + 1, [newSource]);
          final oldIdx = _indexOfInPlaylist(source);
          if (oldIdx != null) await playlist.removeAt(oldIdx);
        });
        final newIdx = _indexOfInPlaylist(newSource);
        if (newIdx != null) {
          await player.seek(position, index: newIdx);
        }
        if (wasPlaying) await player.play();
      }
    } finally {
      _hijacking = false;
      _swapping = false;
    }
    _logger.info('Switched quality to $qualityId for $bvid:$cid');
    return true;
  }

  Future<UriAudioSource> getDummyAudioSource(Meta x) async {
    final silenceUri = await resolveSilentAudioUri();
    return AudioSource.uri(silenceUri,
        tag: MediaItem(
            id: x.bvid,
            title: x.title,
            // http://i0.hdslb.com/bfs/archive/32ddc1acc1cba622cbcd789ff7e0b91bcf0097fe.jpg
            artUri: Uri.http(x.artUri.substring(7, 19), x.artUri.substring(19)),
            artist: x.artist,
            duration: Duration(seconds: x.duration),
            extras: {'dummy': true}));
  }

  Future<void> restorePlayMode() async {
    final mode = await SharedPreferencesService.getPlayMode();
    if (mode == 3) {
      await player.setLoopMode(LoopMode.all);
      await player.setShuffleModeEnabled(true);
    } else {
      await player.setLoopMode(LoopMode.values[mode]);
      await player.setShuffleModeEnabled(false);
    }
  }

  Future<void> setInterrupHandler(bool value) async {
    if (value) {
      _interruptionEventSubscription =
          session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (session.androidAudioAttributes?.usage ==
                  AndroidAudioUsage.game) {
                _volumeBeforeDuck ??= player.volume;
                player.setVolume(player.volume / 2);
              }
              _playInterrupted = false;
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (player.playing) {
                player.pause();
                // Although pause is async and sets _playInterrupted = false,
                // this is done in the sync portion.
                _playInterrupted = true;
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              final volumeBeforeDuck = _volumeBeforeDuck;
              _volumeBeforeDuck = null;
              if (volumeBeforeDuck != null) {
                player.setVolume(min(1.0, volumeBeforeDuck));
              }
              _playInterrupted = false;
              break;
            case AudioInterruptionType.pause:
              if (_playInterrupted) player.play();
              _playInterrupted = false;
              break;
            case AudioInterruptionType.unknown:
              _playInterrupted = false;
              break;
          }
        }
      });
    } else {
      await _interruptionEventSubscription?.cancel();
    }
  }

  Future<void> hookEvents() async {
    setInterrupHandler(await SharedPreferencesService.getReactToInterruption());

    session.becomingNoisyEventStream.listen((_) {
      player.pause();
    });

    // 捕获原生端播放错误（AVPlayerItem status=failed 的错误码/描述）。
    // AVQueuePlayer 对失败项是静默跳过的，不记录则完全无法诊断
    //「代理项装不上被跳过」这类问题（真机实测踩坑）。
    player.playbackEventStream.listen((event) {
      if (event.errorCode != null || event.errorMessage != null) {
        _logger.severe(
            'player error: code=${event.errorCode}, message=${event.errorMessage}');
      }
    });

    Rx.combineLatest2(player.loopModeStream, player.shuffleModeEnabledStream,
        (a, b) => (a, b)).listen((data) async {
      final (loopMode, shuffleModeEnabled) = data;

      if (shuffleModeEnabled) {
        await SharedPreferencesService.setPlayMode(3);
      } else {
        await SharedPreferencesService.setPlayMode(
            LoopMode.values.indexOf(loopMode));
      }
    });

    player.currentIndexStream.listen((index) async {
      if (index != null) {
        // hijack 必须先于 setInt 的 await 调用：等待会越过 _hijacking
        // 保护期，使 hijack 自身 seek 产生的索引事件触发连锁 hijack
        //（级联跳歌，真机实测：点第一首自动跳第二首）。
        unawaited(_hijackDummySource(index: index));
        final prefs = await SharedPreferencesService.instance;
        await prefs.setInt('currentIndex', index);
      }
    });

    // iOS：未缓存源以截断宣告的渐进式服务（见
    // LazyAudioSource.advertisedLengthCapBytes，AVPlayer 吞前 N MB 即开播），
    // 下载完成后无缝替换为本地文件源，恢复真实长度与全程拖动能力。
    player.sequenceStateStream.listen((state) {
      final source = state.currentSource;
      // 记录「当前源成为当前项」的时点；sequenceStateStream 在源不变的
      // 情况下也会因 processingState 等变化频繁触发，只在源实例变化时
      // 刷新，否则 1 秒甄别窗口永远无法流逝（换源会永远从 0 开始）。
      if (source is LazyAudioSource) {
        if (_sourceCurrentSince.isEmpty ||
            _sourceCurrentSince.keys.first != source) {
          _sourceCurrentSince.clear();
          _sourceCurrentSince[source] = DateTime.now();
        }
        if (!source.isLocal && Platform.isIOS) {
          _swapToCachedFileWhenDone(source);
        }
      } else {
        _sourceCurrentSince.clear();
      }
    });

    player.playerStateStream.listen((state) async {
      final enableHistoryReport =
          await SharedPreferencesService.getHistoryReported();
      if (state.playing) {
        if (enableHistoryReport) {
          _startCloudHistoryReporting();
        }
        _startPlayPositionSaving();
      } else {
        _stopHistoryReporting();
        _stopPlayPositionSaving();
      }

      if (state.processingState == ProcessingState.ready) {
        final index = player.currentIndex;
        if (index == null) {
          return;
        }
        if (state.playing == false) {
          return;
        }
        _historyUpdateCnt = 0;
      }
    });

    // iOS 卡死看门狗：playing=true 但进度恒为 0（AVQueuePlayer 队列卡死，
    // 媒体请求永不下发——真机日志实证）时，用全新实例替换当前源强制重载。
    // 每个源只救一次：若纯属慢网络加载，重载亦不会立即有进展，避免反复
    // 打断。注意不能对加载中的 item 发 seekToTime（会中断其资源加载）。
    if (Platform.isIOS) {
      Timer.periodic(const Duration(seconds: 5), (_) {
        // 清理已离开播放列表的「已救过」标记，避免实例无限滞留
        if (_watchdogUnwedgedSources.isNotEmpty) {
          final seq = playlist.sequence;
          _watchdogUnwedgedSources
              .removeWhere((s) => !seq.any((e) => identical(e, s)));
        }
        if (!player.playing) {
          _watchdogStallTicks = 0;
          return;
        }
        final source = player.sequenceState.currentSource;
        final extras = source?.tag?.extras;
        if (source == null || extras == null || extras['dummy'] == true) {
          _watchdogStallTicks = 0;
          return;
        }
        if (player.position > Duration.zero) {
          // 有进展：清零计数并允许该源再次被看门
          _watchdogStallTicks = 0;
          _watchdogUnwedgedSources.remove(source);
          return;
        }
        _watchdogStallTicks++;
        if (_watchdogStallTicks >= 4 &&
            !_watchdogUnwedgedSources.contains(source)) {
          _watchdogUnwedgedSources.add(source);
          _watchdogStallTicks = 0;
          final idx = player.currentIndex;
          _logger.warning(
              'watchdog: playing but stuck at 0 for 20s, replace source at index=$idx');
          if (idx != null) {
            _unwedgeCurrentSourceIOS(idx, source);
          }
        }
      });
    }
  }

  int _watchdogStallTicks = 0;
  final Set<AudioSource> _watchdogUnwedgedSources = {};

  /// iOS 看门狗解卡：用全新实例替换当前源（新实例 = 新原生 AVPlayerItem =
  /// 全新资源加载，旧 item 的内部卡死状态随之丢弃）。操作顺序与 hijack
  /// 一致：先插到当前项后面 → 显式跳 → 再删旧项，规避 removeItem(当前项)
  /// 自动推进竞态。旧源进行中的下载先取消，避免与新源写同一 .part。
  Future<void> _unwedgeCurrentSourceIOS(int index, AudioSource source) async {
    if (source is! LazyAudioSource) return;
    // 与 hijack/换源/其他看门狗执行互斥，避免并发 playlist 变更
    if (_hijacking || _swapping) return;
    final tag = source.tag;
    if (tag is! MediaItem) return;
    final extras = tag.extras;
    final bvid = extras?['bvid'];
    final cid = extras?['cid'];
    if (bvid == null || cid == null) return;
    final position = player.position;
    final wasPlaying = player.playing;
    await source.cancelDownload();
    final file = await source.localFile;
    // 复核时效性：cancelDownload 的 await 窗口内用户可能已切歌/队列
    // 可能已推进——旧源不再是当前项时放弃解卡，绝不把播放强拽回旧曲目；
    // 插入点也用旧源身份现查，不用捕获的固定 index。
    final curIdx = _indexOfInPlaylist(source);
    if (curIdx == null ||
        !identical(player.sequenceState.currentSource, source)) {
      _logger.warning('watchdog: source no longer current, abort unwedge');
      return;
    }
    final fresh = LazyAudioSource(
      bvid,
      cid,
      localFile: file.existsSync() ? file : null,
      tag: tag,
    );
    // 切音质待恢复的位置迁移到克隆源：原源被解卡替换后，克隆源换源时
    // 仍能恢复切音质时记录的位置。
    final pending = _pendingSeekPositions.remove(source);
    if (pending != null) {
      _pendingSeekPositions[fresh] = pending;
    }
    // 克隆体继承「已救过」标记：慢网络下若克隆体仍无进展，不再反复
    // 重载；一旦有播放进展，标记会被看门狗清除并重新武装。
    _watchdogUnwedgedSources.add(fresh);
    _hijacking = true;
    _swapping = true;
    try {
      await doAndSavePlaylist(() async {
        await playlist.insertAll(curIdx + 1, [fresh]);
      });
      // 同 swap：不能用固定 index+1（推进会导致 seek 落到下一P
      // ——下一P继承本P进度），一律 identical 定位。
      final insertIdx = _indexOfInPlaylist(fresh);
      if (insertIdx != null) {
        try {
          await player
              .seek(position, index: insertIdx)
              .timeout(const Duration(seconds: 5));
        } catch (e) {
          _logger.warning('watchdog unwedge seek failed: $e');
        }
        if (wasPlaying) await player.play();
      } else {
        _logger.warning('watchdog: fresh source vanished from playlist');
      }
      await doAndSavePlaylist(() async {
        final oldIdx = _indexOfInPlaylist(source);
        if (oldIdx != null) await playlist.removeAt(oldIdx);
      });
    } catch (e) {
      _logger.warning('watchdog unwedge failed: $e');
    } finally {
      _hijacking = false;
      _swapping = false;
    }
  }

  void _startCloudHistoryReporting() async {
    _historyReportTimer?.cancel();
    final interval = await SharedPreferencesService.getReportHistoryInterval();
    _historyReportTimer =
        Timer.periodic(Duration(seconds: interval), (timer) async {
      final currentSource = player.sequenceState.currentSource;
      if (currentSource == null || !player.playing) {
        return;
      }

      final extras = currentSource.tag.extras;
      if (extras == null || extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      final length = currentSource.duration?.inSeconds;

      if (await SharedPreferencesService.getHistoryReported()) {
        await (await BilibiliService.instance).reportHistory(
            extras['aid'],
            extras['cid'],
            length != null && length - player.position.inSeconds <= interval
                ? length
                : player.position.inSeconds);
      }
    });
  }

  void _stopHistoryReporting() {
    _historyReportTimer?.cancel();
    _historyReportTimer = null;
  }

  void _startPlayPositionSaving() {
    _playPositionTimer?.cancel();
    _playPositionTimer = Timer.periodic(
        const Duration(seconds: _historyUpdateInterval), (timer) async {
      final currentSource = player.sequenceState.currentSource;
      if (currentSource == null || !player.playing) {
        return;
      }

      final extras = currentSource.tag.extras;
      if (extras == null || extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      _logger.info('saving play position: ${player.position.inSeconds}');

      _historyUpdateCnt++;
      DatabaseManager.updatePlayStat(extras['bvid'],
          _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval);
      await SharedPreferencesService.setPlayPosition(player.position.inSeconds);
    });
  }

  void _stopPlayPositionSaving() {
    _playPositionTimer?.cancel();
    _playPositionTimer = null;
  }

  // 设置定时停止播放
  Future<void> setSleepTimer(int? minutes, {DateTime? specificTime}) async {
    // 取消现有的定时器
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;

    // 如果之前有淡出，恢复用户原音量
    final userVolume = _userVolumeBeforeFade;
    _userVolumeBeforeFade = null;
    if (userVolume != null) {
      await player.setVolume(userVolume);
    }

    // 更新设置
    await SharedPreferencesService.setSleepTimerMinutes(minutes);

    // 如果minutes和specificTime都为null，表示取消定时
    if (minutes == null && specificTime == null) {
      _sleepTimerSubject.add(null);
      return;
    }

    int durationInSeconds;

    if (specificTime != null) {
      // 计算从现在到指定时刻的秒数
      final now = DateTime.now();
      final difference = specificTime.difference(now);

      // 如果指定时间已经过去，则不设置定时器
      if (difference.isNegative) {
        _sleepTimerSubject.add(null);
        return;
      }

      durationInSeconds = difference.inSeconds;
      // 保存为分钟，用于恢复
      await SharedPreferencesService.setSleepTimerMinutes(
          durationInSeconds ~/ 60);
    } else {
      // 使用分钟计算
      durationInSeconds = minutes! * 60;
    }

    _sleepTimerSubject.add(durationInSeconds);

    // 记录淡出前的用户音量，结束/取消时恢复
    _userVolumeBeforeFade = player.volume;

    // 用截止时间计算剩余秒数，避免后台挂起时 timer.tick 不准
    final deadline = DateTime.now().add(Duration(seconds: durationInSeconds));

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remainingSeconds = deadline.difference(DateTime.now()).inSeconds;

      if (remainingSeconds <= 0) {
        // 时间到，停止播放
        player.pause();
        _sleepTimer?.cancel();
        _sleepTimer = null;
        _fadeTimer?.cancel();
        _fadeTimer = null;
        _sleepTimerSubject.add(null);
        SharedPreferencesService.setSleepTimerMinutes(null);
        // 恢复用户原音量
        final userVolume = _userVolumeBeforeFade;
        _userVolumeBeforeFade = null;
        player.setVolume(userVolume ?? 1.0);
      } else if (remainingSeconds <= _fadeOutDuration && _fadeTimer == null) {
        // 开始淡出
        _startFadeOut(remainingSeconds);
      } else {
        // 更新剩余时间
        _sleepTimerSubject.add(remainingSeconds);
      }
    });
  }

  void _startFadeOut(int remainingSeconds) {
    final startVolume = player.volume;
    final volumeStep = startVolume / remainingSeconds;

    _fadeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick >= remainingSeconds) {
        _fadeTimer?.cancel();
        _fadeTimer = null;
        return;
      }
      final newVolume = startVolume - (volumeStep * timer.tick);
      player.setVolume(newVolume.clamp(0.0, 1.0));
    });
  }

  // 获取当前定时器剩余时间（秒）
  int? get sleepTimerRemainingSeconds => _sleepTimerSubject.valueOrNull;

  /// 已注册换源监听的源（按身份去重）。sequenceStateStream 在 hijack/
  /// 换源期间会多次触发（dummy→real、unwedge seek 等），单槽守卫会被
  /// 绕过导致同一源注册多个监听——并发执行 insertAll+removeAt 把
  /// playlist 改坏（真机日志：换源执行 3 次后当前项变成 dummy）。
  final Set<LazyAudioSource> _swapWatchedSources = {};

  /// 各源成为当前播放项的时点。换源时用它甄别 player.position 是否可信：
  /// 若源刚成为当前项（<1s，位置不连续事件尚未由 just_audio 处理），
  /// player.position 可能仍是上一项（上一P）的进度——此时换源必须从 0
  /// 开始，否则下一P会继承上一P的进度（真机多P实测）。
  final Map<LazyAudioSource, DateTime> _sourceCurrentSince = {};

  /// 是否有换源正在执行（playlist 变更互斥）。
  bool _swapping = false;

  /// 切音质后待恢复的播放位置（iOS 新源渐进式 seek 可能不生效、位置恒
  /// 0，待新源下载完成换入文件源时恢复；新源已有实际进展时以
  /// player.position 为准），键为切音质创建的新源；看门狗克隆时迁移。
  final Map<LazyAudioSource, Duration> _pendingSeekPositions = {};

  /// 在 playlist 中按真实身份（identical）定位源实例的当前索引。
  ///
  /// 异步队列变更（insertAll/removeAt/AVQueuePlayer 推进）期间，预先捕获
  /// 的固定索引会漂移错位：真机多P实测——P1 换源时恰逢其播完推进到 P2，
  /// 固定 index+1 的 seek 落到了 P2 上，把 P1 的播放进度种进了 P2
  ///（下一P继承上一P进度）。一切 index 运算都必须用本源身份现查。
  int? _indexOfInPlaylist(Object? source) {
    if (source == null) return null;
    final seq = playlist.sequence;
    for (var i = 0; i < seq.length; i++) {
      if (identical(seq[i], source)) return i;
    }
    return null;
  }

  /// 监听未缓存源（iOS 直播流模式）的下载完成事件，完成时若它仍是当前
  /// 播放源，则在原位置无缝替换为本地文件源（恢复 duration/拖动能力）。
  ///
  /// 必须等待 downloadComplete（.part 已改名、元数据已落库）而非下载
  /// 进度 1.0：进度事件在最后一个数据块回调中发出，早于 onDone 的
  /// renameSync，此时检查主文件必然不存在，替换会静默流产（microtask
  /// 时序竞态）。
  void _swapToCachedFileWhenDone(LazyAudioSource source) {
    if (!_swapWatchedSources.add(source)) return;
    source.downloadComplete.then((_) async {
      _swapWatchedSources.remove(source);
      // 与其他 playlist 变更（hijack/切音质/看门狗）互斥：并发
      // insertAll+removeAt 会改坏 playlist。放弃后 sequenceStateStream
      // 的后续事件会为该源重新注册监听，自愈重试。
      if (_swapping || _hijacking) {
        _pendingSeekPositions.remove(source);
        return;
      }
      if (!identical(player.sequenceState.currentSource, source)) {
        _pendingSeekPositions.remove(source);
        return;
      }
      final file = await source.localFile;
      if (!file.existsSync()) {
        _pendingSeekPositions.remove(source);
        return;
      }
      final tag = source.tag as MediaItem;
      final becameCurrent = _sourceCurrentSince[source];
      final currentPos = player.position;
      // 复核时效性：await localFile 窗口内可能已有其他 playlist 变更
      // 开始，或当前项已切换（P1 恰逢播完推进到 P2）——此时放弃换源，
      // 绝不把播放强拽回旧曲目。
      if (_swapping || _hijacking ||
          !identical(player.sequenceState.currentSource, source)) {
        _logger.info('swap aborted: playlist state changed during preparation');
        return;
      }
      // 位置优先级：
      // 1. 已有实际播放进展（含切音质后 iOS 渐进式 seek 成功的情形）——
      //    以真实进度为准，pendingSeek 是切换时刻的旧值，直接用会回跳；
      // 2. 切音质记录的位置——新源位置恒 0（iOS 渐进式 seek 未生效）时恢复；
      // 3. 源刚成为当前项（<1s）——player.position 可能还残留上一项
      //    （上一P）的进度（位置不连续事件未处理），此时必须从 0 开始——
      //    否则下一P继承上一P的进度（真机多P实测）；
      // 4. 其余用当前播放位置。
      final pending = _pendingSeekPositions.remove(source);
      final Duration position;
      if (pending != null) {
        position = currentPos > Duration.zero ? currentPos : pending;
      } else if (becameCurrent != null &&
          DateTime.now().difference(becameCurrent) <
              const Duration(seconds: 1)) {
        position = Duration.zero;
      } else {
        position = currentPos;
      }
      final wasPlaying = player.playing;
      _logger.info(
          'Download finished, swapping to local file source at $position '
          '(bvid=${tag.id}, becameCurrent=${becameCurrent == null ? '?' : DateTime.now().difference(becameCurrent).inMilliseconds}ms)');
      final cachedSource = AudioSource.uri(
        Uri.file(file.path),
        tag: MediaItem(
          id: tag.id,
          title: tag.title,
          artist: tag.artist,
          artUri: tag.artUri,
          duration: tag.duration,
          extras: {
            ...?tag.extras,
            'cached': true,
            // 保留实际音质标记，供音质弹窗高亮当前档位
            if (source.qualityId != null) 'qualityId': source.qualityId,
          },
        ),
      );
      // 插入点用旧源身份现查（currentIndex 在 await 窗口内可能漂移）
      final curIdx = _indexOfInPlaylist(source);
      if (curIdx == null) {
        _logger.warning('swap: source vanished from playlist');
        return;
      }
      _swapping = true;
      _hijacking = true;
      try {
        if (Platform.isIOS) {
          // iOS 安全顺序（同 hijack）：先插 → 显式跳 → 再删，
          // 避免 removeItem(当前项) 自动推进竞态与加载中 seekToTime。
          //
          // 注意：不能用固定 index+1！insertAll 异步执行期间 AVQueuePlayer
          // 可能已推进（P1 恰逢播完），固定偏移会把 seek 打到下一P 上
          //（真机多P实测：下一P继承上一P进度）。一切定位用 identical。
          await doAndSavePlaylist(() async {
            await playlist.insertAll(curIdx + 1, [cachedSource]);
          });
          final insertIdx = _indexOfInPlaylist(cachedSource);
          if (insertIdx != null) {
            try {
              await player
                  .seek(position, index: insertIdx)
                  .timeout(const Duration(seconds: 5));
            } catch (e) {
              _logger.warning('swap seek to cached source failed: $e');
            }
            if (wasPlaying) await player.play();
          } else {
            _logger.warning('swap: cached source vanished from playlist');
          }
          await doAndSavePlaylist(() async {
            final oldIdx = _indexOfInPlaylist(source);
            if (oldIdx != null) await playlist.removeAt(oldIdx);
          });
        } else {
          await doAndSavePlaylist(() async {
            await playlist.insertAll(curIdx + 1, [cachedSource]);
            final oldIdx = _indexOfInPlaylist(source);
            if (oldIdx != null) await playlist.removeAt(oldIdx);
          });
          final newIdx = _indexOfInPlaylist(cachedSource);
          if (newIdx != null) {
            await player.seek(position, index: newIdx);
          }
          if (wasPlaying) await player.play();
        }
      } finally {
        _hijacking = false;
        _swapping = false;
      }
    }).catchError((_) {
      // 下载失败/中断/被取消：不做替换，直播流自然结束；
      // 允许该源后续（如下次成为当前曲目时）重新注册监听。
      _swapWatchedSources.remove(source);
      _pendingSeekPositions.remove(source);
    });
  }

  Future<void> _hijackDummySource({int? index}) async {
    if (_hijacking || _swapping) {
      return;
    }
    index ??= player.currentIndex;
    if (index == null) {
      _logger.warning('No current index available for hijacking');
      return;
    }
    if (index >= playlist.length) {
      return;
    }

    final currentSource = playlist.sequence[index];

    final extras = currentSource.tag.extras;
    if (extras == null) {
      return;
    }
    if (extras['dummy'] != true) {
      if (extras['bvid'] != null && extras['cid'] != null) {
        await DatabaseManager.updatePlayStats(extras['bvid'], extras['cid']);
        _logger.info(
            'update play stats for bvid: ${extras['bvid']} cid: ${extras['cid']}');
      }
      return;
    }
    _logger.info('Hijacking dummy source for index: $index');
    _hijacking = true;

    try {
      List<IndexedAudioSource>? srcs;
      try {
        srcs = await (await BilibiliService.instance)
            .getAudios(currentSource.tag.id);
      } catch (e) {
        _logger.warning('Failed to get audio sources: $e');
        srcs = await DatabaseManager.getLocalAudioList(currentSource.tag.id);
      }
      final excludedCids =
          await DatabaseManager.getExcludedParts(currentSource.tag.id);
      for (var cid in excludedCids) {
        srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
      }
      if (srcs == null || srcs.isEmpty) {
        _logger.warning(
            'No audio sources found for BVID: ${currentSource.tag.id}');
        // 不自动跳歌：seekToNext 会再次触发 currentIndexStream →
        // _hijackDummySource → 又失败又跳，网络异常时表现为「一路跳歌」。
        // 停在当前曲目并暂停，用户可手动重试或切歌。
        // srcs 为空（全部分 P 被排除）同理：此时 iOS 分支跳不了新源，
        // 删除当前 dummy 会触发 removeItem(当前项) 自动推进竞态。
        if (player.playing) {
          await player.pause();
        }
        return;
      }
      await doAndSavePlaylist(() async {
        // 闭包内无法利用外部的 null 检查做类型提升，取局部非空变量
        final targetIndex = index!;
        final newSources = srcs!;
        final isShuffle = player.shuffleModeEnabled;
        if (isShuffle) {
          await player.setShuffleModeEnabled(false);
        }
        await playlist.insertAll(targetIndex + 1, newSources);
        if (Platform.isIOS && player.currentIndex == targetIndex) {
          // iOS：先显式跳到新源（distant jump → enqueueFrom 干净加载新
          // item），再删除 dummy。避免两种已实测的卡死：
          // 1) removeItem(当前播放项) 触发 AVQueuePlayer 自动推进竞态
          //    → playing=true 但永不下发媒体请求；
          // 2) 对加载中的 item 发 seekToTime → AVFoundation 中断资源
          //    加载且不重试。
          //
          // 关键前置条件：被 hijack 的 dummy 必须仍是当前播放项。hijack
          // 的跳转 seek 会产生新的 currentIndex 事件，经监听器延迟回调
          // 又会触发对「下一个 dummy」的 hijack——若不甄别，跳转 seek 会
          // 形成级联，把播放从第一首一路强拽到第二首、第三首……
          //（真机实测：点收藏夹第一首自动跳第二首）。
          // seek 目标用 identical 定位第一个新源：insertAll 异步期间
          // 队列可能漂移，固定 targetIndex+1 在多P下可能跳到下一P。
          final firstIdx = newSources.isEmpty
              ? null
              : _indexOfInPlaylist(newSources.first);
          if (firstIdx != null) {
            try {
              await player
                  .seek(Duration.zero, index: firstIdx)
                  .timeout(const Duration(seconds: 5));
            } catch (e) {
              _logger.warning('hijack seek to real source failed: $e');
            }
          }
        } else if (!Platform.isIOS && player.loopMode == LoopMode.one) {
          await player.seek(Duration.zero, index: targetIndex + 1);
        }
        // 按 dummy 实例身份现查索引再删除：insertAll/seek 的 await 期间
        // 队列可能漂移，固定 targetIndex 可能删错项。
        final removeIdx = _indexOfInPlaylist(currentSource);
        if (removeIdx != null) {
          await playlist.removeAt(removeIdx);
        } else {
          _logger.warning('hijack: dummy source vanished before removal');
        }
        if (isShuffle) {
          await player.setShuffleModeEnabled(true);
        }
      });
    } finally {
      _hijacking = false;
    }
  }

  Future<void> playByBvid(String bvid) async {
    _logger.info('Playing by BVID: $bvid');
    await player.pause();
    List<IndexedAudioSource>? srcs;
    try {
      srcs = await (await BilibiliService.instance).getAudios(bvid);
    } catch (e) {
      _logger.warning('Failed to get audio sources: $e');
      srcs = await DatabaseManager.getLocalAudioList(bvid);
    }
    if (srcs == null) {
      _logger.warning('No audio sources found for BVID: $bvid');
      return;
    }
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }

    final idx = await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);
    if (idx != null) {
      await player.seek(Duration.zero, index: idx);
    }
    await player.play();
  }

  Future<void> playByBvids(List<String> bvids, {int index = 0}) async {
    if (bvids.isEmpty) {
      return;
    }
    final metas = await DatabaseManager.getMetas(bvids);
    final srcs = <UriAudioSource>[];
    for (final meta in metas) {
      srcs.add(await getDummyAudioSource(meta));
    }
    await player.pause();
    _hijacking = true;
    await doAndSavePlaylist(() async {
      await playlist.clear();
      await playlist.addAll(srcs);
    });
    _hijacking = false;
    _hijackDummySource(index: index);
    await player.seek(Duration.zero, index: index);
    await player.play();
  }

  Future<void> playLocalAudio(String bvid, int cid) async {
    await player.pause();
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    final idx = await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);

    if (idx != null) {
      await player.seek(Duration.zero, index: idx);
    }
    await player.play();
  }

  Future<void> addToPlaylistCachedAudio(String bvid, int cid) async {
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: (player.currentIndex ?? playlist.length - 1) + 1);
  }

  Future<void> appendPlaylist(String bvid,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    final srcs = await (await BilibiliService.instance).getAudios(bvid);
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: insertIndex, extraExtras: extraExtras);
  }

  Future<void> appendCachedPlaylist(String bvid,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    final srcs = await DatabaseManager.getLocalAudioList(bvid);
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null) {
      return;
    }
    await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: insertIndex, extraExtras: extraExtras);
  }

  Future<void> doAndSavePlaylist(Future<void> Function() func) async {
    await func();
    await SharedPreferencesService.savePlaylist(
        playlist, player.currentIndex ?? 0);
  }

  // 以 extras 中的 bvid + cid 作为去重依据（dummy 源与真实源的 id 体系不同）
  static bool _isSameMedia(MediaItem a, MediaItem b) =>
      a.extras?['bvid'] != null &&
      a.extras?['bvid'] == b.extras?['bvid'] &&
      a.extras?['cid'] == b.extras?['cid'];

  Future<int?> _addUniqueSourcesToPlaylist(List<IndexedAudioSource> sources,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    int? ret;
    final uniqueSources = <IndexedAudioSource>[];
    for (var source in sources) {
      if (source.tag is! MediaItem) {
        continue;
      }
      final mediaItem = source.tag as MediaItem;
      final duplicatePos = playlist.children.indexWhere((child) =>
          child is IndexedAudioSource &&
          child.tag is MediaItem &&
          _isSameMedia(child.tag as MediaItem, mediaItem));
      final pendingPos = uniqueSources.indexWhere((child) =>
          child.tag is MediaItem &&
          _isSameMedia(child.tag as MediaItem, mediaItem));

      if (duplicatePos == -1 && pendingPos == -1) {
        if (extraExtras != null) {
          mediaItem.extras?.addAll(extraExtras);
        }
        uniqueSources.add(source);
        ret ??= insertIndex != null
            ? insertIndex + uniqueSources.length - 1
            : playlist.length + uniqueSources.length - 1;
      } else if (duplicatePos != -1) {
        ret = duplicatePos;
      } else {
        ret ??= insertIndex != null
            ? insertIndex + pendingPos
            : playlist.length + pendingPos;
      }
    }
    if (uniqueSources.isNotEmpty) {
      final index = insertIndex;
      // 批量插入后只保存一次
      await doAndSavePlaylist(() async {
        if (index != null) {
          await playlist.insertAll(index, uniqueSources);
        } else {
          await playlist.addAll(uniqueSources);
        }
      });
    }
    return ret;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (speed < 0.25 || speed > 3.0) {
      return;
    }

    await player.setSpeed(speed);
    _speedSubject.add(speed);
    await SharedPreferencesService.setPlaybackSpeed(speed);
    _logger.info('Playback speed set to: $speed');
  }
}
