import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/local_track.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/local_music_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/silent_audio.dart';
import 'package:bmsc/util/weighted_shuffle.dart';
import 'package:rxdart/rxdart.dart';

final _logger = LoggerUtils.getLogger('AudioService');

/// 解析（dummy→真实分 P 源）/ 换源不扰动随机序的 [ShuffleOrder]。
///
/// [DefaultShuffleOrder.insert] 把新源**随机散插**进随机序——本应用
/// 的队列解析流程会在播放中不断把 dummy 替换为真实源（点击、预解析、
/// 下载完成换源、切音质），每次替换都会重掷「下一首」：预解析好的
/// 曲目并不是实际接下来播放的那首，随机模式下顺序反复无常。本实现
/// 默认行为与 DefaultShuffleOrder 一致（随机散插），但替换式插入
/// 可通过锚定保持被替换项的随机序槽位：
/// - [anchorAfter]：全部新源紧随槽位连续占位（1:1 换源/切音质）
/// - [anchorFirstAfter]：仅**首个**新源占据槽位，其余按权重散插——
///   dummy 解析展开为多分 P 时，入口分 P 占住槽位使「下一首」不变，
///   其余分 P 随机散落（分 P 也随机）
///
/// 抽取按 [weightOfIndex] 提供的权重加权（算法见
/// util/weighted_shuffle.dart）：dummy 在解析时会展开为多个分 P，
/// 其权重为内部分 P 数而非单个分 P——多 P 视频整体的抽中概率等于
/// 同等数量的单曲之和。dummy 占 1 个随机序槽位（权重 N）；解析展开
/// 为 N 个真实源后每源权重 1（合计 N），替换前后总权重自洽。
class AnchoredShuffleOrder extends ShuffleOrder {
  // 必须直接暴露可变列表（与 DefaultShuffleOrder 一致）：just_audio 的
  // _toMessage() 会把该列表的引用传给平台消息，应用的自定义后台
  //（just_audio_background_custom）通过 replaceRange 就地同步镜像；
  // 包一层 List.unmodifiable 会让所有队列变更直接抛
  // "Cannot remove from an unmodifiable list"（真机实测）
  @override
  final indices = <int>[];

  final Random _random;
  int? _anchorAfter;
  bool _anchorFirstOnly = false;

  AnchoredShuffleOrder({Random? random}) : _random = random ?? Random();

  /// 各项的随机抽取权重（按 playlist 下标取）；未设置一律按 1。
  /// just_audio 先更新 playlist.children 再回调本类的 insert（见
  /// ConcatenatingAudioSource.insertAll），回调可安全同步读源信息。
  int Function(int playlistIndex)? weightOfIndex;

  int _weightOf(int playlistIndex) => weightOfIndex?.call(playlistIndex) ?? 1;

  /// 下一次 [insert] 的新源在随机序中紧随 [playlistIndex]（被替换的
  /// dummy/旧源）之后按序占位。一次性：首个 insert 消费后失效。
  void anchorAfter(int playlistIndex) => _anchorAfter = playlistIndex;

  /// 同 [anchorAfter]，但只有第一个新源锚定占据槽位，其余新源按
  /// 权重散插进随机序。一次性：首个 insert 消费后失效。
  void anchorFirstAfter(int playlistIndex) {
    _anchorAfter = playlistIndex;
    _anchorFirstOnly = true;
  }

  @override
  void shuffle({int? initialIndex}) {
    if (indices.length <= 1) return;
    final shuffled = weightedPermutation(indices, _weightOf, _random,
        initialIndex: initialIndex);
    indices
      ..clear()
      ..addAll(shuffled);
  }

  @override
  void insert(int index, int count) {
    // 先按插入点平移既有索引（与 DefaultShuffleOrder 相同）
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }
    final newIndices = List.generate(count, (i) => index + i);
    final anchor = _anchorAfter;
    final anchorFirst = _anchorFirstOnly;
    _anchorAfter = null;
    _anchorFirstOnly = false;
    if (anchor != null) {
      // 锚定插入：紧随锚点（插入点前一项，即被替换的 dummy/旧源）
      // 的随机序位置之后排布，替换后新源占据原槽位，随机序不变
      final pos = indices.indexOf(anchor);
      if (pos >= 0) {
        if (anchorFirst) {
          // 仅首个新源（dummy 解析的入口分 P）占住槽位：
          // 「下一首」不变；其余分 P 散插——分 P 也随机
          indices.insert(pos + 1, newIndices.first);
          for (final newIndex in newIndices.skip(1)) {
            indices.insert(
                weightedInsertionIndex(
                    indices, _weightOf(newIndex), _weightOf, _random),
                newIndex);
          }
        } else {
          indices.insertAll(pos + 1, newIndices);
        }
        return;
      }
    }
    // 默认散插：按权重选位（与 weightedPermutation 同分布；
    // DefaultShuffleOrder 为均匀散插，此处为其加权推广）
    for (final newIndex in newIndices) {
      indices.insert(
          weightedInsertionIndex(
              indices, _weightOf(newIndex), _weightOf, _random),
          newIndex);
    }
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
  }

  @override
  void clear() {
    indices.clear();
    _anchorAfter = null;
    _anchorFirstOnly = false;
  }
}

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

  /// 队列随机序：替换式插入（解析/换源/切音质）通过 anchorAfter
  /// 锚定，保持随机序不被重掷（见 [AnchoredShuffleOrder]）
  final AnchoredShuffleOrder _playlistShuffleOrder = AnchoredShuffleOrder();

  // ignore: deprecated_member_use
  late final ConcatenatingAudioSource playlist = ConcatenatingAudioSource(
    useLazyPreparation: true,
    children: [],
    shuffleOrder: _playlistShuffleOrder,
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
    x._playlistShuffleOrder.weightOfIndex = x._weightOfPlaylistIndex;
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
    // 与其他 playlist 变更（解析/换源/看门狗）互斥，避免并发改坏队列。
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
        // iOS 安全顺序（同 _replaceCurrentDummy）：先插 → 显式跳 → 再删。
        // 定位一律 identical，禁用固定 index+1（推进竞态会把位置
        // 种到下一P 上——真机多P实测）。
        _playlistShuffleOrder.anchorAfter(curIdx);
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
        _playlistShuffleOrder.anchorAfter(curIdx);
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

  /// 队列项的随机抽取权重：dummy 为其内部分 P 数（一个 dummy 槽位
  /// 在解析时会展开为多个分 P，权重不应等于单个分 P）；真实源与本地
  /// 曲目恒为 1。分 P 数来自 dummy tag 中的 meta 缓存（未缓存/未知
  /// 按 1 退化为原行为；跳过排除的分 P 不另扣减——排除是少数情况，
  /// 权重作近似即可）。
  int _weightOfPlaylistIndex(int playlistIndex) {
    final children = playlist.children;
    if (playlistIndex < 0 || playlistIndex >= children.length) return 1;
    final child = children[playlistIndex];
    if (child is! IndexedAudioSource) return 1;
    final tag = child.tag;
    if (tag is! MediaItem) return 1;
    final extras = tag.extras;
    if (extras == null || extras['dummy'] != true) return 1;
    final parts = extras['parts'];
    return parts is int && parts > 1 ? parts : 1;
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
            extras: {
              'dummy': true,
              // 随机播放权重：dummy 解析时将展开为 parts 个分 P
              //（见 AnchoredShuffleOrder.weightOfIndex）；
              // 未知/单 P 不携带，按权重 1 处理
              if (x.parts != null && x.parts! > 1) 'parts': x.parts,
            }));
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
      if (index == null) return;
      // 播放列表变更执行期间（_hijacking/_swapping），just_audio 的
      // sequenceState 是「旧 currentIndex × 新序列」的错位映射——原生端
      // 的索引事件尚未回传，currentSource 可能指向完全错误的曲目。
      // 按幻影事件处理会把播放统计/预解析打到错误曲目上，并连锁触发
      // 对错误 dummy 的解析（真机实测：点击播放后 play_stat 被大量污染、
      // 整个队列被级联预解析、播放条卡在错误歌曲上）。变更窗口内的
      // 索引事件一律跳过，待变更完成后由 _resyncCurrentTrack 补同步。
      if (_hijacking || _swapping) {
        _needsTrackResync = true;
        _scheduleTrackResync();
        return;
      }
      // 解析必须先于 setInt 的 await 调用：等待会越过 _hijacking
      // 保护期，使解析自身 seek 产生的索引事件触发连锁解析
      //（级联跳歌，真机实测：点第一首自动跳第二首）。
      _onTrackIndexChanged(index);
      final prefs = await SharedPreferencesService.instance;
      await prefs.setInt('currentIndex', index);
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
        // 本地文件源不走看门狗：_unwedgeCurrentSourceIOS 只处理
        // LazyAudioSource，本地文件也不存在代理卡死场景
        if (source == null ||
            extras == null ||
            extras['dummy'] == true ||
            extras['local'] == true) {
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

  /// 变更窗口内被跳过的索引事件是否待补同步
  bool _needsTrackResync = false;
  Timer? _trackResyncTimer;

  /// 上次已按「真实切歌」处理过的当前源（按实例身份去重）。
  /// sequenceState 在播放模式切换、playlist 变更等场景会以相同当前源
  /// 重复发射，updatePlayStats 每次 +1，不去重会把 playCount 和
  /// 「最近在听」打到错误/重复的曲目上
  IndexedAudioSource? _lastHandledCurrentSource;

  /// 变更完成后补一次当前曲目同步：届时原生索引事件已回传，
  /// sequenceState.currentSource 是可信映射，可安全地更新播放统计、
  /// 解析当前 dummy 与预解析下一首（与正常索引事件共用幂等逻辑）。
  void _scheduleTrackResync() {
    if (_trackResyncTimer?.isActive ?? false) return;
    _trackResyncTimer = Timer(const Duration(milliseconds: 200), () {
      _trackResyncTimer = null;
      if (_hijacking || _swapping) {
        // 又有变更在执行：等它结束再试
        _scheduleTrackResync();
        return;
      }
      if (!_needsTrackResync) return;
      _needsTrackResync = false;
      final index = player.currentIndex;
      if (index == null) return;
      _logger.info('track resync after playlist mutation: index=$index');
      _onTrackIndexChanged(index);
      unawaited(SharedPreferencesService.instance
          .then((prefs) => prefs.setInt('currentIndex', index)));
    });
  }

  /// iOS 看门狗解卡：用全新实例替换当前源（新实例 = 新原生 AVPlayerItem =
  /// 全新资源加载，旧 item 的内部卡死状态随之丢弃）。操作顺序与 _replaceCurrentDummy
  /// 一致：先插到当前项后面 → 显式跳 → 再删旧项，规避 removeItem(当前项)
  /// 自动推进竞态。旧源进行中的下载先取消，避免与新源写同一 .part。
  Future<void> _unwedgeCurrentSourceIOS(int index, AudioSource source) async {
    if (source is! LazyAudioSource) return;
    // 与解析/换源/其他看门狗执行互斥，避免并发 playlist 变更
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
      _playlistShuffleOrder.anchorAfter(curIdx);
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
      if (extras == null) {
        return;
      }
      // 本地曲目：保存播放位置（重启续播用）+ 本地播放统计
      //（stat 键为 MediaItem.id 即 local_<id>，「最近在听」联查
      // local_music 取标题/封面）
      if (extras['local'] == true) {
        _historyUpdateCnt++;
        unawaited(DatabaseManager.updatePlayStat(currentSource.tag.id,
            _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval));
        await SharedPreferencesService.setPlayPosition(
            player.position.inSeconds);
        return;
      }
      if (extras['aid'] == null || extras['cid'] == null) {
        return;
      }

      _logger.info('saving play position: ${player.position.inSeconds}');

      _historyUpdateCnt++;
      DatabaseManager.updatePlayStat(extras['bvid'],
          _historyUpdateCnt == 1 ? 1 : 0, _historyUpdateInterval,
          cid: extras['cid'] as int?);
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

  /// 已注册换源监听的源（按身份去重）。sequenceStateStream 在解析/
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
      // 与其他 playlist 变更（解析/切音质/看门狗）互斥：并发
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
          // iOS 安全顺序（同 _replaceCurrentDummy）：先插 → 显式跳 → 再删，
          // 避免 removeItem(当前项) 自动推进竞态与加载中 seekToTime。
          //
          // 注意：不能用固定 index+1！insertAll 异步执行期间 AVQueuePlayer
          // 可能已推进（P1 恰逢播完），固定偏移会把 seek 打到下一P 上
          //（真机多P实测：下一P继承上一P进度）。一切定位用 identical。
          _playlistShuffleOrder.anchorAfter(curIdx);
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
          _playlistShuffleOrder.anchorAfter(curIdx);
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

  /// 在途的 dummy 解析（按实例身份去重）：兜底（当前项）与预解析
  ///（下一首）共享，避免对同一 dummy 重复 fetch/插入。
  final Map<IndexedAudioSource, Future<void>> _resolvingDummies = {};

  /// seek 失败被保留、待成为非当前项后补删的 dummy。
  final Set<IndexedAudioSource> _pendingDummyRemovals = {};

  /// 索引事件入口：兜底解析当前 dummy → 更新播放统计 → 预解析下一首。
  /// 解析取锁是同步的（见 _doResolveDummy），先于监听器后续的 await，
  /// 保证级联保护不被时序越过。
  void _onTrackIndexChanged(int index) {
    // seek 失败被保留的 dummy：此刻已非当前项，补删（非当前项删除安全）
    if (_pendingDummyRemovals.isNotEmpty) {
      final current = player.sequenceState.currentSource;
      for (final d in _pendingDummyRemovals.toList()) {
        if (!identical(current, d)) {
          _pendingDummyRemovals.remove(d);
          unawaited(_removeSourceWhenIdle(d));
        }
      }
    }
    final seq = playlist.sequence;
    if (index >= seq.length) return;
    final source = seq[index];
    final extras = source.tag.extras;
    if (extras == null) return;
    // 同一源重复触发（播放模式切换、变更后 resync 等）时不再重复计
    // 统计、不再重复预解析：updatePlayStats 每次 playCount +1，
    // 重复事件会污染 playCount 与「最近在听」
    final isCurrentChanged = !identical(source, _lastHandledCurrentSource);
    if (extras['dummy'] == true) {
      if (isCurrentChanged) {
        _lastHandledCurrentSource = source;
      }
      unawaited(_resolveDummySource(source));
    } else if (extras['bvid'] != null && extras['cid'] != null) {
      if (isCurrentChanged) {
        _lastHandledCurrentSource = source;
        unawaited(
            DatabaseManager.updatePlayStats(extras['bvid'], extras['cid']));
        _logger.info(
            'update play stats for bvid: ${extras['bvid']} cid: ${extras['cid']}');
      }
    }
    // 预解析只在真实切歌时进行：解析下一首 → 其完成又预解析下一首 →…
    // 的链式触发会把整个队列全部解析（每首一次网络请求，且期间的
    // 插入/删除让 sequenceState 反复错位，真机实测级联在数秒内解析了
    // 44 个视频的整个队列并使播放条反复跳变）
    if (isCurrentChanged) {
      _schedulePreResolveAhead();
    }
  }

  /// 预解析：提前把播放序下一首的 dummy 替换为真实源，使自然切歌不再
  /// 需要任何「当前播放项」变更（iOS 上唯一危险的操作）。nextIndex 已
  /// 包含 shuffle/loop 语义；单曲循环（nextIndex == currentIndex）与
  /// 队尾时无事可做。
  void _schedulePreResolveAhead() {
    final current = player.currentIndex;
    final next = player.nextIndex;
    if (current == null || next == null || next == current) return;
    final seq = playlist.sequence;
    if (next >= seq.length) return;
    final source = seq[next];
    final extras = source.tag.extras;
    if (extras == null || extras['dummy'] != true) return;
    unawaited(_resolveDummySource(source));
  }

  /// 等待 playlist 变更锁释放（解析/换源/切音质/看门狗互斥）。超时放弃：
  /// 解析类操作由后续索引事件链式自愈，无需无限等待。
  Future<bool> _waitMutationFree(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_hijacking || _swapping) {
      if (DateTime.now().isAfter(deadline)) {
        _logger.warning('wait for playlist mutation lock timed out');
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  Future<void> _resolveDummySource(IndexedAudioSource dummy) {
    final inflight = _resolvingDummies[dummy];
    if (inflight != null) return inflight;
    final f = _doResolveDummy(dummy);
    _resolvingDummies[dummy] = f;
    unawaited(f.catchError((Object e) {
      _logger.warning('resolve dummy failed: $e');
    }).whenComplete(() {
      if (identical(_resolvingDummies[dummy], f)) {
        _resolvingDummies.remove(dummy);
      }
    }));
    return f;
  }

  Future<void> _doResolveDummy(IndexedAudioSource dummy) async {
    // 锁空闲时同步取锁：索引事件链式触发（解析自身 seek 产生的）在下一次
    // 事件循环前必然看到旗标已置位，级联保护不依赖 await 时序。锁被持有
    //（换源/切音质/看门狗）时改拒绝为等待——拒绝会让 dummy 播满 60s
    // 静音后才等下次索引事件重试。
    if (_hijacking || _swapping) {
      if (!await _waitMutationFree()) return;
    }
    if (_indexOfInPlaylist(dummy) == null) return;
    _hijacking = true;
    try {
      final srcs = await _fetchRealSourcesForDummy(dummy);
      // fetch 的 await 窗口内 dummy 可能已被移除（用户删歌/清空/换队列）
      if (_indexOfInPlaylist(dummy) == null) return;
      if (srcs.isEmpty) {
        // 不自动跳歌：seekToNext 会再次触发索引事件 → 又失败又跳，网络
        // 异常时表现为「一路跳歌」。仅在 dummy 已是当前项时暂停，等用户
        // 手动重试或切歌。
        if (identical(player.sequenceState.currentSource, dummy) &&
            player.playing) {
          await player.pause();
        }
        return;
      }
      // 分 P 也随机：随机模式下打乱分 P 顺序——入口分 P（打乱后首个）
      // 锚定占据 dummy 的随机序槽位（「下一首」不变），其余分 P 散插
      // 进随机序（见 AnchoredShuffleOrder.anchorFirstAfter）；
      // 非随机模式保持 P1..PN 原序连播（专辑语义）
      if (player.shuffleModeEnabled && srcs.length > 1) {
        srcs.shuffle();
      }
      if (identical(player.sequenceState.currentSource, dummy)) {
        // 兜底路径：dummy 已成为当前播放项（用户直接跳转/预解析未及时
        // 覆盖），用 iOS 安全顺序替换（先插→显式跳→再删）。
        await _replaceCurrentDummy(dummy, srcs, alreadyInserted: false);
      } else {
        // 预解析路径：dummy 不是当前项，insert/remove 不触碰当前播放项，
        // 无 seek、无 shuffle 干预、无 currentIndex 事件。
        await _replaceIdleDummy(dummy, srcs);
      }
    } finally {
      _hijacking = false;
      // 注意：这里不能链式预解析下一首。原实现「解析完成 → 预解析下一首
      // → 其完成又预解析下一首 → …」会把整个队列全部解析（每首一次网络
      // 请求；且大量插入/删除使 sequenceState 反复错位，真机实测 4 秒内
      // 级联解析了 44 个视频的队列、播放条反复跳变并卡在错误曲目）。
      // 预解析只由真实切歌驱动（_onTrackIndexChanged），每次恰好解析
      // 「播放序下一首」一首，切歌时下一首自然已就绪。
    }
  }

  /// 解析 dummy 对应视频的真实音频源（网络失败回退本地缓存列表），
  /// 并按用户设置排除指定分 P。返回空列表表示无可用源。
  Future<List<IndexedAudioSource>> _fetchRealSourcesForDummy(
      IndexedAudioSource dummy) async {
    List<IndexedAudioSource>? srcs;
    try {
      srcs = await (await BilibiliService.instance).getAudios(dummy.tag.id);
    } catch (e) {
      _logger.warning('Failed to get audio sources: $e');
      srcs = await DatabaseManager.getLocalAudioList(dummy.tag.id);
    }
    final excludedCids = await DatabaseManager.getExcludedParts(dummy.tag.id);
    for (var cid in excludedCids) {
      srcs?.removeWhere((src) => src.tag.extras?['cid'] == cid);
    }
    if (srcs == null || srcs.isEmpty) {
      _logger.warning('No audio sources found for BVID: ${dummy.tag.id}');
      return const [];
    }
    return srcs;
  }

  /// 预解析替换：dummy 不是当前播放项时的安全替换。insert/remove 均不
  /// 触碰当前播放项（iOS 上 removeItem 仅作用于非当前项，无自动推进
  /// 竞态），也不需要 seek/shuffle 干预，不产生 currentIndex 事件。
  ///
  /// 唯一危险窗口：insertAll 的 await 期间当前曲目恰好播完（或用户恰好
  /// 跳转）使 dummy 成为当前项——此时升级为 _replaceCurrentDummy 的
  /// 安全顺序完成替换，绝不在此直接删除。
  Future<void> _replaceIdleDummy(
      IndexedAudioSource dummy, List<IndexedAudioSource> srcs) async {
    _logger.info(
        'pre-resolve idle dummy: bvid=${dummy.tag.id}, parts=${srcs.length}');
    var upgraded = false;
    await doAndSavePlaylist(() async {
      final dummyIdx = _indexOfInPlaylist(dummy);
      if (dummyIdx == null) return;
      // 入口分 P 锚定占据 dummy 的随机序槽位（替换不重掷「下一首」），
      // 其余分 P 散插进随机序（分 P 也随机）
      _playlistShuffleOrder.anchorFirstAfter(dummyIdx);
      await playlist.insertAll(dummyIdx + 1, srcs);
      // insertAll 的 await 窗口内自然推进/用户跳转可能使 dummy 刚成为当前项
      if (identical(player.sequenceState.currentSource, dummy)) {
        upgraded = true;
        return;
      }
      final removeIdx = _indexOfInPlaylist(dummy);
      if (removeIdx != null) {
        await playlist.removeAt(removeIdx);
      }
    });
    if (upgraded) {
      _logger.info('pre-resolve upgraded: dummy became current mid-mutation');
      await _replaceCurrentDummy(dummy, srcs, alreadyInserted: true);
    }
  }

  /// 兜底替换：dummy 已是当前播放项。iOS 安全顺序：先插到 dummy 后面 →
  /// 显式跳到真实源（distant jump → enqueueFrom 干净加载新 item）→ 再删
  /// dummy。避免两种已实测的卡死：
  /// 1) removeItem(当前播放项) 触发 AVQueuePlayer 自动推进竞态
  ///    → playing=true 但永不下发媒体请求；
  /// 2) 对加载中的 item 发 seekToTime → AVFoundation 中断资源加载且不重试。
  ///
  /// seek 失败时保留 dummy 不删（静音播完自然推进到真实源，或用户切歌
  /// 后由 _pendingDummyRemovals 补删），绝不 removeItem(当前项)。
  Future<void> _replaceCurrentDummy(
      IndexedAudioSource dummy, List<IndexedAudioSource> srcs,
      {required bool alreadyInserted}) async {
    _logger.info(
        'resolve CURRENT dummy (fallback): bvid=${dummy.tag.id}, parts=${srcs.length}, alreadyInserted=$alreadyInserted');
    final isShuffle = player.shuffleModeEnabled;
    await doAndSavePlaylist(() async {
      if (isShuffle) {
        await player.setShuffleModeEnabled(false);
      }
      if (!alreadyInserted) {
        final dummyIdx = _indexOfInPlaylist(dummy);
        if (dummyIdx == null) {
          if (isShuffle) await player.setShuffleModeEnabled(true);
          return;
        }
        // 入口分 P 锚定占据 dummy 的随机序槽位（替换不重掷「下一首」），
        // 其余分 P 散插进随机序（分 P 也随机）；本路径结尾重新开启
        // shuffle 会整体重排，锚定与否无实际差异，仅为语义一致
        _playlistShuffleOrder.anchorFirstAfter(dummyIdx);
        await playlist.insertAll(dummyIdx + 1, srcs);
      }
      // shuffle/insert 的 await 窗口内用户可能已跳到其他曲目或 dummy 已
      // 被移除：dummy 不再是当前项时无需 seek，直接安全删除；dummy 已不
      // 在队列时无事可做。
      if (_indexOfInPlaylist(dummy) == null) {
        if (isShuffle) await player.setShuffleModeEnabled(true);
        return;
      }
      final needSeek =
          identical(player.sequenceState.currentSource, dummy);
      var seekOk = true;
      if (needSeek) {
        // seek 目标用 identical 定位第一个新源：insertAll 异步期间队列可能
        // 漂移，固定 index+1 在多 P 下可能跳到下一 P。
        final firstIdx = _indexOfInPlaylist(srcs.first);
        if (firstIdx != null) {
          if (Platform.isIOS || player.loopMode == LoopMode.one) {
            try {
              await player
                  .seek(Duration.zero, index: firstIdx)
                  .timeout(const Duration(seconds: 5));
            } catch (e) {
              _logger.warning('resolve: seek to real source failed: $e');
              seekOk = false;
            }
          }
        } else {
          seekOk = false;
        }
      }
      if (seekOk) {
        final removeIdx = _indexOfInPlaylist(dummy);
        if (removeIdx != null) {
          await playlist.removeAt(removeIdx);
        } else {
          _logger.warning('resolve: dummy source vanished before removal');
        }
      } else {
        // seek 目标丢失/失败：保留 dummy 注册延迟删除（下一次索引事件时
        // dummy 已非当前项，补删是安全操作）。
        _pendingDummyRemovals.add(dummy);
      }
      if (isShuffle) {
        await player.setShuffleModeEnabled(true);
      }
    });
  }

  /// 延迟补删：等变更锁并复核目标已非当前播放项后从队列移除。
  Future<void> _removeSourceWhenIdle(IndexedAudioSource source) async {
    if (!await _waitMutationFree()) return;
    _hijacking = true;
    try {
      if (identical(player.sequenceState.currentSource, source)) {
        // 等锁期间又被跳回：重新挂起，等下一次索引事件再补删
        _pendingDummyRemovals.add(source);
        return;
      }
      await doAndSavePlaylist(() async {
        final i = _indexOfInPlaylist(source);
        if (i != null) await playlist.removeAt(i);
      });
    } finally {
      _hijacking = false;
    }
  }

  /// [preferCid]：定位到该分 P 再播（「最近在听」续播用）；
  /// 为空或找不到（被屏蔽等）时从第一个分 P 开始
  Future<void> playByBvid(String bvid, {int? preferCid}) async {
    _logger.info('Playing by BVID: $bvid (preferCid: $preferCid)');
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
      // 定位与 seek 同处变更互斥窗口：其间在途的解析/预解析不会插入
      // 删除队列项，target 计算与 seek 落点一致（否则多 P 插入会使
      // seek 落到错误曲目）
      if (!await _waitMutationFree()) return;
      _hijacking = true;
      try {
        int target = idx;
        if (preferCid != null) {
          // 在播放列表中定位该 bvid 下目标分 P 的位置（含该视频
          // 已在列表中被去重命中的情况）；找不到保持从 P1 开始
          final i = playlist.children.indexWhere((c) =>
              c is IndexedAudioSource &&
              c.tag is MediaItem &&
              (c.tag as MediaItem).extras?['bvid'] == bvid &&
              (c.tag as MediaItem).extras?['cid'] == preferCid);
          if (i >= 0) {
            target = i;
            _logger.info('Located to part cid=$preferCid at index $i');
          }
        }
        await player.seek(Duration.zero, index: target);
      } finally {
        _hijacking = false;
      }
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
    // 等在途的解析/换源/预解析变更完成再换队列：原实现直接覆写
    // _hijacking 旗标，与在途变更并发执行 clear/addAll 会互相改坏队列
    if (!await _waitMutationFree()) return;
    _hijacking = true;
    try {
      await doAndSavePlaylist(() async {
        await playlist.clear();
        await playlist.addAll(srcs);
      });
      // 先定位、后解析，且定位期间保持互斥：子序列化/预解析的插入
      // 删除不会发生，[index] 一定落在点击的曲目上。原实现解析先于
      // seek 且此刻旗标已释放，多 P 视频的插入会使 seek 落到错误曲目
      //（随机播放下预解析目标分散在队列各处，错位概率更高）
      await player.seek(Duration.zero, index: index);
      // 启动恢复等场景下播放器可能仍在 loading，just_audio 会把该
      // seek 静默丢弃——等就绪后重试一次，确保定位到点击曲目
      if (index < srcs.length &&
          !identical(player.sequenceState.currentSource, srcs[index])) {
        try {
          await player.processingStateStream
              .firstWhere((s) => s == ProcessingState.ready)
              .timeout(const Duration(seconds: 5));
          await player.seek(Duration.zero, index: index);
        } catch (_) {
          // 拉起失败由后续索引事件链自愈
        }
      }
    } finally {
      _hijacking = false;
    }
    // 直接传 dummy 实例（而非索引捕获）：取锁同步进行，与 seek/resync
    // 触发的索引事件经 _resolvingDummies 去重，不会重复解析。
    if (index < srcs.length) {
      unawaited(_resolveDummySource(srcs[index]));
    }
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
      // 同 playByBvid：定位 seek 与队列变更互斥，防索引错位
      if (!await _waitMutationFree()) return;
      _hijacking = true;
      try {
        await player.seek(Duration.zero, index: idx);
      } finally {
        _hijacking = false;
      }
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

  /// 播放本地音乐：替换整个播放队列并从 [index] 开始播放。
  /// 本地源为 file:// 直接加载，无需 dummy 解析流程。
  /// [shuffle] 为 true 时切换到随机播放模式（列表循环 + shuffle，
  /// 与播放模式 3 语义一致，自动持久化），并从随机曲目开始。
  Future<void> playLocalTracks(List<LocalTrack> tracks,
      {int index = 0, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    if (shuffle) {
      index = Random().nextInt(tracks.length);
    }
    _logger.info(
        'Playing ${tracks.length} local tracks from index $index (shuffle=$shuffle)');
    final srcs = tracks.map(LocalMusicService.buildSource).toList();
    await player.pause();
    if (!await _waitMutationFree()) return;
    _hijacking = true;
    try {
      await doAndSavePlaylist(() async {
        await playlist.clear();
        await playlist.addAll(srcs);
      });
      if (index >= srcs.length) index = 0;
      await player.seek(Duration.zero, index: index);
      // loading 态（启动恢复期间）seek 会被静默丢弃，就绪后重试一次
      if (index < srcs.length &&
          !identical(player.sequenceState.currentSource, srcs[index])) {
        try {
          await player.processingStateStream
              .firstWhere((s) => s == ProcessingState.ready)
              .timeout(const Duration(seconds: 5));
          await player.seek(Duration.zero, index: index);
        } catch (_) {}
      }
    } finally {
      _hijacking = false;
    }
    if (shuffle) {
      // 播放模式 3 = 列表循环 + 随机（hookEvents 监听自动持久化）
      await player.setLoopMode(LoopMode.all);
      await player.setShuffleModeEnabled(true);
    }
    await player.play();
  }

  /// 按曲库 id 播放单个本地曲目（「最近在听」/「本地历史」点击续播）。
  /// 曲目已被删除时清理其播放统计并忽略。
  Future<void> playLocalTrackById(int localId) async {
    final track = await DatabaseManager.getLocalTrackById(localId);
    if (track == null) {
      _logger.warning('local track $localId missing, prune its play stat');
      await DatabaseManager.removePlayStat('local_$localId');
      return;
    }
    await playLocalTracks([track]);
  }

  /// 把本地曲目插入到当前播放项之后（不影响正在播放的曲目，去重）。
  Future<void> appendLocalTracks(List<LocalTrack> tracks) async {
    if (tracks.isEmpty) return;
    final srcs = tracks.map(LocalMusicService.buildSource).toList();
    await _addUniqueSourcesToPlaylist(srcs,
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

  /// UI 层队列变更统一入口：先等在途的解析/换源/预解析完成，再持互斥
  /// 执行变更。直接调 doAndSavePlaylist 改队列会与在途变更并发互相
  /// 改坏队列；且变更期间 sequenceState 的「旧索引 × 新序列」错位映射
  /// 若被索引监听误当真实切歌处理，会把统计/预解析打到错误曲目上
  ///（幻影事件，真机实测会连锁解析整个队列）。已在 _hijacking 内执行
  /// 的内部流程不应使用本方法（会等自己）。
  Future<void> mutatePlaylist(Future<void> Function() func) async {
    final lockAcquired = await _waitMutationFree();
    if (lockAcquired) _hijacking = true;
    try {
      await doAndSavePlaylist(func);
    } finally {
      if (lockAcquired) _hijacking = false;
    }
  }

  // 去重依据：B 站源以 extras 中的 bvid + cid（dummy 源与真实源的
  // id 体系不同）；本地曲目以 filePath（bvid/cid 体系不适用）
  static bool _isSameMedia(MediaItem a, MediaItem b) {
    final aLocal = a.extras?['local'] == true;
    final bLocal = b.extras?['local'] == true;
    if (aLocal || bLocal) {
      return aLocal &&
          bLocal &&
          a.extras?['filePath'] != null &&
          a.extras?['filePath'] == b.extras?['filePath'];
    }
    return a.extras?['bvid'] != null &&
        a.extras?['bvid'] == b.extras?['bvid'] &&
        a.extras?['cid'] == b.extras?['cid'];
  }

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
      // 插入也持有变更互斥：插入期间的 sequenceState 错位映射若被索引
      // 监听当真实切歌处理，会把统计/预解析打到插入的曲目上
      final lockAcquired = await _waitMutationFree();
      if (lockAcquired) _hijacking = true;
      try {
        // 批量插入后只保存一次
        await doAndSavePlaylist(() async {
          if (index != null) {
            await playlist.insertAll(index, uniqueSources);
          } else {
            await playlist.addAll(uniqueSources);
          }
        });
      } finally {
        if (lockAcquired) _hijacking = false;
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
