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
      await x.player.setAudioSource(x.playlist,
          preload: x.playlist.children.isNotEmpty);
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
    final currentId = source is LazyAudioSource ? source.qualityId : null;
    final seen = <int>{};
    final uniqueAudios = [
      for (final Audio a in audios)
        if (seen.add(a.id)) a,
    ];
    // 并发读取各档位精确大小
    final sizes = await Future.wait(uniqueAudios.map(
        (a) => a.baseUrl.isNotEmpty ? _fetchExactSize(Uri.parse(a.baseUrl)) : Future<int?>.value()));
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

    await SharedPreferencesService.setAudioQuality(qualityId);

    final position = player.position;
    final wasPlaying = player.playing;
    await player.pause();

    // 删除旧音质缓存（同一路径将被新源复用），强制走网络按新偏好解析
    await DatabaseManager.removeCacheEntry(bvid, cid, force: true);
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
    _hijacking = true;
    try {
      await doAndSavePlaylist(() async {
        await playlist.insertAll(index + 1, [newSource]);
        await playlist.removeAt(index);
      });
    } finally {
      _hijacking = false;
    }
    await player.seek(position, index: index);
    if (wasPlaying) await player.play();
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
        final prefs = await SharedPreferencesService.instance;
        await prefs.setInt('currentIndex', index);
        await _hijackDummySource(index: index);
      }
    });

    // iOS 直播流实验：未缓存源以直播流形式播放时 duration/seek 不可用，
    // 下载完成后无缝替换为本地文件源，恢复完整能力（见
    // LazyAudioSource.liveStreamExperimentEnabled）。
    player.sequenceStateStream.listen((state) {
      final source = state.currentSource;
      if (source is LazyAudioSource &&
          !source.isLocal &&
          LazyAudioSource.liveStreamExperimentEnabled &&
          Platform.isIOS) {
        _swapToCachedFileWhenDone(source);
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

  LazyAudioSource? _swapWatchingSource;

  /// 监听未缓存源（iOS 直播流模式）的下载进度，下载完成时若它仍是当前
  /// 播放源，则在原位置无缝替换为本地文件源（恢复 duration/拖动能力）。
  void _swapToCachedFileWhenDone(LazyAudioSource source) {
    if (_swapWatchingSource == source) return;
    _swapWatchingSource = source;
    source.downloadProgressStream
        .firstWhere((p) => p >= 1.0)
        .then((_) async {
      if (_swapWatchingSource == source) _swapWatchingSource = null;
      if (player.sequenceState.currentSource != source) return;
      final index = player.currentIndex;
      if (index == null || index >= playlist.length) return;
      final file = await source.localFile;
      if (!file.existsSync()) return;
      final tag = source.tag as MediaItem;
      final position = player.position;
      final wasPlaying = player.playing;
      _logger.info(
          'Download finished, swapping to local file source at $position');
      final cachedSource = AudioSource.uri(
        Uri.file(file.path),
        tag: MediaItem(
          id: tag.id,
          title: tag.title,
          artist: tag.artist,
          artUri: tag.artUri,
          duration: tag.duration,
          extras: {...?tag.extras, 'cached': true},
        ),
      );
      _hijacking = true;
      try {
        await doAndSavePlaylist(() async {
          await playlist.insertAll(index + 1, [cachedSource]);
          await playlist.removeAt(index);
        });
      } finally {
        _hijacking = false;
      }
      await player.seek(position, index: index);
      if (wasPlaying) await player.play();
    }).catchError((_) {
      // 下载失败/中断：不做替换，直播流自然结束
    });
  }

  Future<void> _hijackDummySource({int? index}) async {
    if (_hijacking) {
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
      if (srcs == null) {
        _logger.warning(
            'No audio sources found for BVID: ${currentSource.tag.id}');
        // 不自动跳歌：seekToNext 会再次触发 currentIndexStream →
        // _hijackDummySource → 又失败又跳，网络异常时表现为「一路跳歌」。
        // 停在当前曲目并暂停，用户可手动重试或切歌。
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
        if (player.loopMode == LoopMode.one) {
          await player.seek(Duration.zero, index: targetIndex + 1);
        }
        await playlist.removeAt(targetIndex);
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
