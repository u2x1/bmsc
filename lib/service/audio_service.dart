import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/util/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';

final _logger = LoggerUtils.getLogger('AudioService');

class AudioService {
  static final instance = _init();

  // ignore: deprecated_member_use
  final playlist = ConcatenatingAudioSource(
    useLazyPreparation: true,
    children: [],
  );
  final player = AudioPlayer(handleInterruptions: false);
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
      await x.player.setAudioSource(x.playlist);
      final position = await SharedPreferencesService.getPlayPosition();
      if (restored != null && restored.$2 < x.playlist.length) {
        await x.player.seek(null, index: restored.$2);
        await Future.delayed(const Duration(milliseconds: 100));
        await x.player.seek(Duration(seconds: position));
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
    x.session = await AudioSession.instance;
    await x.session.configure(const AudioSessionConfiguration.music());
    await x.hookEvents();
    return x;
  }

  UriAudioSource getDummyAudioSource(Meta x) {
    final silenceUri = Uri(scheme: 'asset', path: '/assets/silent.m4a');
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
              if (session.androidAudioAttributes!.usage ==
                  AndroidAudioUsage.game) {
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
              player.setVolume(min(1.0, player.volume * 2));
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

    // 恢复音量
    await player.setVolume(1);

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

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remainingSeconds = durationInSeconds - timer.tick;

      if (remainingSeconds <= 0) {
        // 时间到，停止播放
        player.pause();
        _sleepTimer?.cancel();
        _sleepTimer = null;
        _fadeTimer?.cancel();
        _fadeTimer = null;
        _sleepTimerSubject.add(null);
        SharedPreferencesService.setSleepTimerMinutes(null);
        // 恢复音量
        player.setVolume(1);
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
      _logger
          .warning('No audio sources found for BVID: ${currentSource.tag.id}');
      if (player.loopMode != LoopMode.one &&
          player.currentIndex != null &&
          player.currentIndex! < playlist.length - 1) {
        await player.seekToNext();
        await player.play();
      }
      _hijacking = false;
      return;
    }
    await doAndSavePlaylist(() async {
      final isShuffle = player.shuffleModeEnabled;
      if (isShuffle) {
        await player.setShuffleModeEnabled(false);
      }
      await playlist.insertAll(index! + 1, srcs!);
      if (player.loopMode == LoopMode.one) {
        await player.seek(Duration.zero, index: index + 1);
      }
      await playlist.removeAt(index);
      if (isShuffle) {
        await player.setShuffleModeEnabled(true);
      }
    });
    _hijacking = false;
  }

  Future<void> playByBvid(String bvid) async {
    _logger.info('Playing by BVID: $bvid');
    await player.pause();
    final srcs = await (await BilibiliService.instance).getAudios(bvid);
    if (srcs == null) {
      _logger.warning('No audio sources found for BVID: $bvid');
      return;
    }
    final excludedCids = await DatabaseManager.getExcludedParts(bvid);
    for (var cid in excludedCids) {
      srcs.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }

    final idx = await _addUniqueSourcesToPlaylist(srcs,
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);
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
    final srcs = metas.map(getDummyAudioSource).toList();
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
    _logger.info('playByBvids done');
  }

  Future<void> playLocalAudio(String bvid, int cid) async {
    await player.pause();
    final cachedSource = await DatabaseManager.getLocalAudio(bvid, cid);
    if (cachedSource == null) {
      return;
    }
    final idx = await _addUniqueSourcesToPlaylist([cachedSource],
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);

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
        insertIndex: playlist.length == 0 ? 0 : player.currentIndex! + 1);
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
    SharedPreferencesService.savePlaylist(playlist, player.currentIndex ?? 0);
  }

  Future<int?> _addUniqueSourcesToPlaylist(List<IndexedAudioSource> sources,
      {int? insertIndex, Map<String, dynamic>? extraExtras}) async {
    int? ret;
    for (var source in sources) {
      if (source.tag is MediaItem) {
        var mediaItem = source.tag as MediaItem;
        var duplicatePos = playlist.children.indexWhere((child) {
          if (child is IndexedAudioSource && child.tag is MediaItem) {
            return (child.tag as MediaItem).id == mediaItem.id;
          }
          return false;
        });

        if (duplicatePos == -1) {
          if (extraExtras != null) {
            mediaItem.extras?.addAll(extraExtras);
          }
          if (insertIndex != null) {
            await doAndSavePlaylist(() async {
              await playlist.insert(insertIndex!, source);
            });
            ret ??= insertIndex;
            insertIndex++;
          } else {
            await doAndSavePlaylist(() async {
              await playlist.add(source);
            });
            ret ??= playlist.length - 1;
          }
        } else {
          ret = duplicatePos;
        }
      }
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
