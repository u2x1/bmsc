import 'dart:math';

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:bmsc/audio/audio_player_ext.dart';
import 'package:bmsc/component/playlist_bottom_sheet.dart';
import 'package:bmsc/component/select_favlist_dialog_multi.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/comment.dart';
import 'package:bmsc/model/subtitle.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../component/playing_card.dart';
import '../util/widget.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:share_plus/share_plus.dart';
import 'package:bmsc/component/download_parts_dialog.dart';
import 'package:bmsc/service/download_manager.dart';
import 'package:bmsc/model/download_task.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key});

  @override
  State<StatefulWidget> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool? _isFavorite;
  String? _currentBvid;
  bool _showSubtitles = false;
  List<BilibiliSubtitle>? _subtitles;
  final AutoScrollController _subtitleScrollController = AutoScrollController();
  final Map<String, List<BilibiliSubtitle>> _subtitleCache = {};
  String? currentKey;
  final Map<String, CommentData?> _commentCache = {};

  AudioService? _audioService;
  bool _isAudioServiceLoading = true;
  SequenceState? _currentSequenceState;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isTitleExpanded = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // Initialize AudioService
    _audioService = await AudioService.instance;
    if (!mounted) return;
    setState(() {
      _isAudioServiceLoading = false;
    });

    // Set up listeners for audio state
    _audioService!.player.sequenceStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _currentSequenceState = state;
      });

      if ((state.currentSource?.tag.extras['dummy'] as bool?) == true) {
        _checkFavoriteStatus(null, state.currentSource?.tag.id);
      }

      // Check favorite status when current track changes
      final bvid = state.currentSource?.tag.extras['bvid'] as String?;
      if (bvid != _currentBvid) {
        _currentBvid = bvid;
        final aid = state.currentSource?.tag.extras['aid'] as int?;
        if (aid != null) {
          _checkFavoriteStatus(aid, state.currentSource?.tag.extras['bvid']);
        }
      }
    });

    // Set up combined position stream
    Rx.combineLatest3(
      _audioService!.player.positionStream,
      _audioService!.player.bufferedPositionStream,
      _audioService!.player.durationStream,
      (position, bufferedPosition, duration) => (
        position,
        bufferedPosition,
        duration,
      ),
    ).listen((durationState) {
      if (!mounted) return;
      setState(() {
        _position = durationState.$1;
        _bufferedPosition = durationState.$2;
        _duration = durationState.$3 ?? Duration.zero;
      });
    });

    // Initialize initial values
    _position = _audioService!.player.position;
    _bufferedPosition = _audioService!.player.bufferedPosition;
    _duration = _audioService!.player.duration ?? Duration.zero;
    _currentSequenceState = _audioService!.player.sequenceState;
  }

  Future<void> _checkFavoriteStatus(int? aid, String? bvid) async {
    if (!mounted) return;
    if (aid == null && bvid == null) {
      setState(() => _isFavorite = null);
      return;
    }
    bool isFavedDB = false;
    if (bvid != null) {
      isFavedDB = await DatabaseManager.isFaved(bvid);
      if (!mounted) return;
      setState(() => _isFavorite = isFavedDB);
    }
    if (aid != null) {
      final isFavorited =
          await (await BilibiliService.instance).isFavorited(aid);
      if (isFavedDB && bvid != null && isFavorited != null && !isFavorited) {
        DatabaseManager.rmFav(bvid);
      }
      if (!mounted) return;
      setState(() => _isFavorite = isFavorited);
    }
  }

  bool _isSmallScreen(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    // 计算屏幕对角线长度(逻辑像素)
    final diagonal =
        sqrt(screenWidth * screenWidth + screenHeight * screenHeight);

    // 判断是否为平板
    final isTablet = MediaQuery.of(context).size.shortestSide >= 600;

    // 如果是平板设备，则不认为是小屏幕
    if (isTablet) {
      return false;
    }

    // 对于手机设备，使用对角线长度和最短边长来判断
    // 对角线小于900逻辑像素或最短边小于360逻辑像素认为是小屏幕
    return diagonal < 900 || screenSize.shortestSide < 360;
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('正在播放'),
        forceMaterialTransparency: true,
        actions: [
          _buildShareButton(),
        ],
      ),
      body: _isAudioServiceLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 800,
                  ),
                  child: isLandscape
                      ? _buildLandscapeLayout(context)
                      : _buildPortraitLayout(context),
                ),
              ),
            ),
    );
  }

  Widget _buildShareButton() {
    if (_isAudioServiceLoading) {
      return const SizedBox.shrink();
    }

    final src = _currentSequenceState?.currentSource;
    return IconButton(
      icon: const Icon(Icons.share),
      onPressed: src == null
          ? null
          : () {
              final bvid = src.tag.extras['bvid'];
              final title = src.tag.title;
              final url = 'https://www.bilibili.com/video/$bvid';
              SharePlus.instance.share(ShareParams(
                text: '$title\n$url',
                subject: title,
              ));
            },
    );
  }

  Widget _buildPortraitLayout(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);
    final padding = isSmallScreen ? 12.0 : 24.0;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSubtitles && _subtitles != null)
              Column(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        child: _buildCoverImage(showTapHint: false),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: _buildTitleAndArtist(
                          context,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 24),
                  _buildSubtitlesView(),
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8.0 : 16.0),
                    child: Column(
                      children: [
                        _buildProgressBar(context),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildTransportControls(),
                      ],
                    ),
                  ),
                ],
              )
            else
              Column(
                children: [
                  _buildCoverImage(),
                  SizedBox(height: isSmallScreen ? 16 : 24),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: padding),
                    child: _buildTitleAndArtist(context),
                  ),
                  SizedBox(height: isSmallScreen ? 10 : 30),
                  _buildProgressBar(context),
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8.0 : 16.0),
                    child: Column(
                      children: [
                        _buildPlaybackControls(),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildTransportControls(),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildAdditionalControls(context),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);
    final horizontalPadding = isSmallScreen ? 8.0 : 16.0;
    final verticalSpacing = isSmallScreen ? 12.0 : 20.0;

    return Row(children: [
      Expanded(
        flex: 1,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_showSubtitles && _subtitles != null)
              Column(
                children: [
                  _buildSubtitlesView(),
                ],
              )
            else ...[
              _buildCoverImage(),
              SizedBox(height: verticalSpacing),
              _buildTitleAndArtist(context),
            ],
          ],
        ),
      ),
      SizedBox(width: 24),
      Expanded(
        flex: 1,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(horizontalPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showSubtitles && _subtitles != null) ...[
                  Row(
                    children: [
                      SizedBox(
                        child: _buildCoverImage(showTapHint: false),
                      ),
                      SizedBox(width: horizontalPadding),
                      Expanded(
                        child: _buildTitleAndArtist(
                          context,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: verticalSpacing),
                ],
                _buildProgressBar(context),
                SizedBox(height: verticalSpacing),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Column(
                    children: [
                      _buildPlaybackControls(),
                      SizedBox(height: verticalSpacing),
                      _buildTransportControls(),
                      SizedBox(height: verticalSpacing),
                      _buildAdditionalControls(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildCoverImage({bool showTapHint = true}) {
    final src = _currentSequenceState?.currentSource;
    final isSmallScreen = _isSmallScreen(context);
    double width = 355.5, height = 200.0;
    var factor = isSmallScreen ? 0.7 : 1;
    if (!showTapHint) {
      factor *= 0.4;
      width *= 0.9;
    }
    final imageSize = Size(width * factor, height * factor);

    return GestureDetector(
      onTap: showTapHint
          ? () async {
              if (src != null) {
                final aid = src.tag.extras['aid'] as int?;
                final cid = src.tag.extras['cid'] as int?;
                if (aid != null && cid != null) {
                  if (_showSubtitles) {
                    setState(() {
                      _showSubtitles = false;
                      _subtitles = null;
                    });
                  } else {
                    setState(() {
                      _showSubtitles = true;
                    });
                    await _loadSubtitles(aid, cid);
                  }
                }
              }
            }
          : null,
      child: shadow(ClipRRect(
        borderRadius: BorderRadius.circular(5.0),
        child: SizedBox(
            height: imageSize.height,
            width: imageSize.width,
            child: src == null
                ? Center(
                    child: Icon(Icons.question_mark, size: 50),
                  )
                : CachedNetworkImage(
                    imageUrl: src.tag.artUri.toString(),
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const Icon(Icons.music_note),
                    errorWidget: (context, url, error) =>
                        const Icon(Icons.music_note),
                  )),
      )),
    );
  }

  Widget _buildTitleAndArtist(BuildContext context, {bool compact = false}) {
    final src = _currentSequenceState?.currentSource;

    return Column(
      crossAxisAlignment:
          compact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Padding(
          padding: EdgeInsets.only(
            bottom: compact ? 4 : (_isSmallScreen(context) ? 4 : 8),
          ),
          child: GestureDetector(
            onTap: () => setState(() => _isTitleExpanded = !_isTitleExpanded),
            child: Text(
              src?.tag.title ?? "",
              style: TextStyle(
                fontSize: compact ? 16 : (_isSmallScreen(context) ? 16 : 18),
                fontWeight: FontWeight.w600,
              ),
              softWrap: true,
              maxLines: _isTitleExpanded ? null : (compact ? 1 : 2),
              overflow: _isTitleExpanded
                  ? TextOverflow.clip
                  : (compact ? TextOverflow.ellipsis : TextOverflow.fade),
              textAlign: compact ? TextAlign.left : TextAlign.center,
            ),
          ),
        ),
        InkWell(
          onTap: () => src == null
              ? null
              : Navigator.pushReplacement(context, MaterialPageRoute<Widget>(
                  builder: (BuildContext context) {
                    return Overlay(
                      initialEntries: [
                        OverlayEntry(builder: (context3) {
                          return Scaffold(
                            body: UserDetailScreen(
                              mid: src.tag.extras['mid'] ?? 0,
                            ),
                            bottomNavigationBar: const PlayingCard(),
                          );
                        })
                      ],
                    );
                  },
                )),
          child: src?.tag.artist != null
              ? Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    Text(
                      src?.tag.artist ?? "",
                      style: TextStyle(
                        fontSize:
                            compact ? 12 : (_isSmallScreen(context) ? 12 : 14),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      softWrap: false,
                      maxLines: 1,
                      textAlign: compact ? TextAlign.left : TextAlign.center,
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: compact ? 16 : (_isSmallScreen(context) ? 16 : 18),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                )
              : SizedBox(),
        ),
      ],
    );
  }

  Widget _buildProgressBar(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);

    return Padding(
      padding: EdgeInsets.all(isSmallScreen ? 10.0 : 20.0),
      child: ProgressBar(
        progress: _position,
        buffered: _bufferedPosition,
        total: _duration,
        onSeek: _audioService!.player.seek,
        timeLabelTextStyle: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 10,
        ),
        timeLabelPadding: 5,
        thumbRadius: 5,
      ),
    );
  }

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildPlaybackModeButton(),
        _buildFavoriteButton(),
      ],
    );
  }

  Widget _buildPlaybackModeButton() {
    return StreamBuilder<(LoopMode, bool)>(
      stream: Rx.combineLatest2(
        _audioService!.player.loopModeStream,
        _audioService!.player.shuffleModeEnabledStream,
        (a, b) => (a, b),
      ),
      builder: (context, snapshot) {
        final (loopMode, shuffleModeEnabled) =
            snapshot.data ?? (LoopMode.off, false);
        final icons = [
          Icons.playlist_play,
          Icons.repeat_one,
          Icons.repeat,
          Icons.shuffle,
        ];
        final labels = ["顺序播放", "单曲循环", "歌单循环", "随机播放"];
        final index =
            shuffleModeEnabled ? 3 : LoopMode.values.indexOf(loopMode);

        return TextButton.icon(
          icon: Icon(
            icons[index],
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          label: Text(
            labels[index],
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          onPressed: () {
            final idx = (index + 1) % labels.length;

            if (idx == 3) {
              _audioService!.player.setShuffleModeEnabled(true);
            } else {
              _audioService!.player.setLoopMode(LoopMode.values[idx]);
              _audioService!.player.setShuffleModeEnabled(false);
            }
          },
        );
      },
    );
  }

  Widget _buildFavoriteButton() {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, snapshot) {
        final src = snapshot.data?.currentSource;
        return Opacity(
            opacity: src == null ? 0.5 : 1.0,
            child: TextButton.icon(
              icon: Icon(
                _isFavorite == true ? Icons.favorite : Icons.favorite_border,
                size: 20,
                color: _isFavorite == true
                    ? Colors.red
                    : Theme.of(context).colorScheme.primary,
              ),
              label: Text(
                _isFavorite == true ? '已收藏' : '收藏',
                style: TextStyle(
                  fontSize: 12,
                  color: _isFavorite == true
                      ? Colors.red
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              onPressed: src == null
                  ? null
                  : () => _handleFavoriteAction(src, context),
            ));
      },
    );
  }

  Future<void> _handleFavoriteAction(
      IndexedAudioSource src, BuildContext context) async {
    final bs = await BilibiliService.instance;
    final uid = bs.myInfo?.mid ?? 0;
    final favs = await bs.getFavs(uid, rid: src.tag.extras['aid']);
    if (favs == null || favs.isEmpty) {
      return;
    }

    final defaultFolderId =
        await SharedPreferencesService.getDefaultFavFolder();

    if (!_isFavorite! && defaultFolderId != null) {
      final success = await bs.favoriteVideo(
            src.tag.extras['aid'],
            [defaultFolderId.$1],
            [],
          ) ??
          false;
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '已添加到收藏夹 ${defaultFolderId.$2}' : '收藏失败'),
          duration: const Duration(seconds: 2),
        ),
      );
      if (success) {
        DatabaseManager.addFav(src.tag.extras['bvid'], defaultFolderId.$1);
        Future.microtask(() => setState(() => _isFavorite = success));
      }
    } else {
      if (!context.mounted) return;
      final result = await showDialog(
          context: context,
          builder: (context) =>
              SelectMultiFavlistDialog(aid: src.tag.extras['aid']));
      if (result == null) return;
      final toAdd = result['toAdd'];
      final toRemove = result['toRemove'];
      if (toAdd.isEmpty && toRemove.isEmpty) {
        return;
      }

      final success = await (await BilibiliService.instance).favoriteVideo(
            src.tag.extras['aid'],
            toAdd,
            toRemove,
          ) ??
          false;
      if (!mounted) return;

      if (success) {
        if (toAdd.isNotEmpty) {
          Future.microtask(() => setState(() {
                _isFavorite = true;
              }));
        }

        for (var mid in toAdd) {
          await DatabaseManager.addFav(src.tag.extras['bvid'], mid);
        }
        for (var mid in toRemove) {
          await DatabaseManager.rmFav(src.tag.extras['bvid'], mid: mid);
        }

        if (toAdd.isEmpty) {
          _checkFavoriteStatus(null, src.tag.extras['bvid']);
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('收藏夹已更新'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        _checkFavoriteStatus(src.tag.extras['aid'], src.tag.extras['bvid']);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('操作失败'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Widget _buildTransportControls() {
    // 使用辅助方法判断小屏幕
    final isSmallScreen = _isSmallScreen(context);
    final iconSize = isSmallScreen ? 30.0 : 36.0;
    final player = _audioService!.player;
    final hasPrevious = player.hasPrevious;
    final hasNext = player.hasNext;
    final playerState = player.playerState;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(Icons.skip_previous, size: iconSize),
          onPressed:
              hasPrevious ? player.seekToPreviousRegardlessOfLoopMode : null,
        ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: EdgeInsets.all(isSmallScreen ? 6.0 : 8.0),
            child:
                _playPauseButton(playerState, player, context, isSmallScreen),
          ),
        ),
        IconButton(
          icon: Icon(Icons.skip_next, size: iconSize),
          onPressed: hasNext ? player.seekToNextRegardlessOfLoopMode : null,
        ),
      ],
    );
  }

  Widget _playPauseButton(PlayerState? playerState, AudioPlayer player,
      BuildContext context, bool isSmallScreen) {
    final processingState = playerState?.processingState;
    final iconSize = isSmallScreen ? 34.0 : 40.0;

    if (processingState == ProcessingState.loading ||
        processingState == ProcessingState.buffering) {
      return IconButton(
        icon: Icon(
          Icons.play_arrow,
          size: iconSize,
          color: Theme.of(context).disabledColor,
        ),
        onPressed: null,
      );
    } else if (player.playing != true) {
      return IconButton(
        icon: Icon(
          Icons.play_arrow,
          size: iconSize,
        ),
        onPressed: player.play,
      );
    } else if (processingState != ProcessingState.completed) {
      return IconButton(
        icon: Icon(
          Icons.pause,
          size: iconSize,
        ),
        onPressed: player.pause,
      );
    } else {
      return IconButton(
        icon: Icon(
          Icons.replay,
          size: iconSize,
        ),
        onPressed: () =>
            player.seek(Duration.zero, index: player.effectiveIndices.first),
      );
    }
  }

  Widget _buildAdditionalControls(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildSleepTimerButton(context, isSmallScreen),
        _buildPlaybackSpeedButton(context, isSmallScreen),
        _buildDownloadButton(context, isSmallScreen),
        _buildPlaylistButton(context, isSmallScreen),
        _buildCommentButton(context, isSmallScreen),
      ],
    );
  }

  Widget _buildSleepTimerButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<int?>(
      stream: _audioService!.sleepTimerStream,
      builder: (context, snapshot) {
        final remainingSeconds = snapshot.data;
        final isActive = remainingSeconds != null;

        return InkWell(
          onTap: () =>
              _handleSleepTimerPress(isActive, _audioService!, context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isActive ? Icons.timer : Icons.timer_outlined,
                  color:
                      isActive ? Theme.of(context).colorScheme.primary : null,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                if (isActive)
                  Text(
                    _formatTime(remainingSeconds),
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (!isActive)
                  Text(
                    '定时',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSecs = seconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remainingSecs.toString().padLeft(2, '0')}';
    } else {
      return '$minutes:${remainingSecs.toString().padLeft(2, '0')}';
    }
  }

  void _handleSleepTimerPress(
      bool isActive, AudioService audioService, BuildContext context) {
    if (isActive) {
      _showCancelSleepTimerDialog(context);
    } else {
      _showSleepTimerOptionsDialog(context);
    }
  }

  void _showCancelSleepTimerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('定时停止播放'),
        content: const Text('是否取消定时停止播放？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () {
              _audioService!.setSleepTimer(null);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已取消定时停止播放'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('取消定时'),
          ),
        ],
      ),
    );
  }

  void _showSleepTimerOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('定时停止播放'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Text('倒计时停止',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SizedBox(
                height: 200,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      dense: true,
                      title: const Text('自定义时间'),
                      onTap: () => _showCustomTimerDialog(context),
                    ),
                    ...[5, 10, 15, 30, 45, 60, 90].map((minutes) => ListTile(
                          dense: true,
                          title: Text('$minutes 分钟'),
                          onTap: () {
                            _audioService!.setSleepTimer(minutes);
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('将在 $minutes 分钟后停止播放'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        )),
                  ],
                ),
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.only(top: 8.0, bottom: 8.0),
                child: Text('指定时刻停止',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ListTile(
                dense: true,
                title: const Text('选择时间'),
                onTap: () => _showTimePickerDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCustomTimerDialog(BuildContext context) {
    Navigator.pop(context);
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置定时时间（分钟）'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '分钟',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final minutes = int.tryParse(controller.text);
              if (minutes != null && minutes > 0) {
                _audioService!.setSleepTimer(minutes);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('将在 $minutes 分钟后停止播放'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTimePickerDialog(BuildContext context) async {
    Navigator.pop(context);

    // 获取当前时间作为初始值
    final now = DateTime.now();
    final initialTime = TimeOfDay(hour: now.hour, minute: now.minute);

    // 显示时间选择器
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        );
      },
    );

    if (selectedTime != null) {
      // 创建目标DateTime
      final now = DateTime.now();
      var targetTime = DateTime(
        now.year,
        now.month,
        now.day,
        selectedTime.hour,
        selectedTime.minute,
      );

      // 如果选择的时间已经过去，则设置为明天的这个时间
      if (targetTime.isBefore(now)) {
        targetTime = targetTime.add(const Duration(days: 1));
      }

      // 设置定时器
      _audioService!.setSleepTimer(null, specificTime: targetTime);

      // 计算并显示剩余时间
      final difference = targetTime.difference(now);
      final hours = difference.inHours;
      final minutes = difference.inMinutes % 60;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '将在 ${selectedTime.format(context)} (${hours > 0 ? '$hours小时' : ''}${minutes > 0 ? '$minutes分钟' : ''}后) 停止播放'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildPlaylistButton(BuildContext context, bool isSmallScreen) {
    return InkWell(
      onTap: () {
        showModalBottomSheet(
          context: context,
          builder: (context) => const PlaylistBottomSheet(),
          backgroundColor: Theme.of(context).colorScheme.surface,
          isScrollControlled: true,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music,
              size: isSmallScreen ? 22 : 24,
            ),
            const SizedBox(height: 4),
            Text(
              '列表',
              style: TextStyle(
                fontSize: isSmallScreen ? 8 : 10,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, snapshot) {
        final src = snapshot.data?.currentSource;
        final aid = src?.tag.extras['aid']?.toString();

        Future<CommentData?> getCommentData(String aid) async {
          // Check cache first
          if (_commentCache.containsKey(aid)) {
            return _commentCache[aid];
          }

          // If not in cache, fetch and cache it
          final bs = await BilibiliService.instance;
          final data = await bs.getComment(aid, null);
          _commentCache[aid] = data;
          return data;
        }

        return InkWell(
          onTap: aid == null
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => CommentScreen(
                        aid: aid,
                      ),
                    ),
                  ),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.comment_outlined,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                if (aid != null)
                  FutureBuilder<CommentData?>(
                    future: getCommentData(aid),
                    builder: (context, snapshot) {
                      final count = snapshot.data?.cursor?.allCount ?? 0;
                      return Text(
                        count > 10000
                            ? '${(count / 10000).toStringAsFixed(1)}万'
                            : count.toString(),
                        style: TextStyle(
                          fontSize: isSmallScreen ? 8 : 10,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                      );
                    },
                  )
                else
                  Text(
                    '评论',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaybackSpeedButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<double>(
      stream: _audioService!.speedStream,
      builder: (context, snapshot) {
        final speed = snapshot.data ?? 1.0;
        final speedText = speed.toStringAsFixed(2);

        return InkWell(
          onTap: () => _showPlaybackSpeedDialog(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.speed,
                  color: speed != 1.0
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                Text(
                  '${speedText}x',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 8 : 10,
                    fontWeight:
                        speed != 1.0 ? FontWeight.bold : FontWeight.normal,
                    color: speed != 1.0
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPlaybackSpeedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StreamBuilder<double>(
          stream: _audioService!.speedStream,
          builder: (context, snapshot) {
            final currentSpeed = snapshot.data ?? 1;

            return AlertDialog(
              title: const Text('播放速度'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      value: currentSpeed,
                      min: 0.25,
                      max: 3.0,
                      divisions: 11, // 0.25的倍数
                      label: '${currentSpeed.toStringAsFixed(2)}x',
                      onChanged: (value) {
                        _audioService!.setPlaybackSpeed(value);
                      },
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((speed) {
                        return ElevatedButton(
                          onPressed: () {
                            _audioService!.setPlaybackSpeed(speed);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: currentSpeed == speed
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            foregroundColor: currentSpeed == speed
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                          child: Text('${speed}x'),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('关闭'),
                ),
              ],
            );
          }),
    );
  }

  Widget _buildDownloadButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<SequenceState?>(
        stream: _audioService!.player.sequenceStateStream,
        builder: (context, snapshot) {
          final src = snapshot.data?.currentSource;
          final bvid = src?.tag.extras['bvid'] as String?;
          final cid = src?.tag.extras['cid'] as int?;

          if (bvid == null || cid == null) {
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_outlined,
                      size: isSmallScreen ? 22 : 24,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '下载',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 8 : 10,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return FutureBuilder(
              future: DownloadManager.instance,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const SizedBox.shrink();
                }
                final dm = snapshot.data!;
                return StreamBuilder<Map<String, DownloadTask>>(
                  stream: dm.tasksStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    DownloadTask? task;

                    final tasks =
                        snapshot.data!.values.toList().reversed.toList();
                    for (final t in tasks) {
                      if (t.bvid == bvid && t.cid == cid) {
                        task = t;
                      }
                    }

                    return InkWell(
                      onTap: () async {
                        if (task == null) {
                          final title = src?.tag.title ?? "未知标题";
                          await showDialog(
                            context: context,
                            builder: (context) => DownloadPartsDialog(
                              bvid: bvid,
                              title: title,
                            ),
                          );
                        } else if (task.status == DownloadStatus.completed) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('已下载'),
                              content: const Text('是否要删除已下载的文件？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    final dm = await DownloadManager.instance;
                                    await dm.removeDownloaded([(bvid, cid)]);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('已删除下载文件'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              task?.status == DownloadStatus.completed
                                  ? Icons.download_done
                                  : task?.status == DownloadStatus.downloading
                                      ? Icons.download
                                      : task?.status == DownloadStatus.paused
                                          ? Icons.pause
                                          : task?.status ==
                                                  DownloadStatus.failed
                                              ? Icons.error
                                              : Icons.download_outlined,
                              color: task?.status == DownloadStatus.completed
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              size: isSmallScreen ? 22 : 24,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              task == null
                                  ? '下载'
                                  : task.status == DownloadStatus.completed
                                      ? '已下载'
                                      : task.status ==
                                              DownloadStatus.downloading
                                          ? '下载中'
                                          : task.status == DownloadStatus.paused
                                              ? '已暂停'
                                              : task.status ==
                                                      DownloadStatus.failed
                                                  ? '下载失败'
                                                  : '等待中',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 8 : 10,
                                fontWeight:
                                    task?.status == DownloadStatus.completed
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                color: task?.status == DownloadStatus.completed
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              });
        });
  }

  Future<void> _loadSubtitles(int aid, int cid) async {
    final subtitleKey = '${aid}_$cid';
    if (_subtitleCache.containsKey(subtitleKey)) {
      // 使用缓存的字幕数据
      setState(() {
        _subtitles = _subtitleCache[subtitleKey];
        _showSubtitles = true;
      });
      return;
    }

    final bilibiliService = await BilibiliService.instance;
    final subtitles = await bilibiliService.getSubTitleInfo(aid, cid);

    if (!mounted) return;

    if (subtitles != null && subtitles.isNotEmpty) {
      final subtitleData =
          await bilibiliService.getSubTitleData(subtitles.last.$2);
      if (subtitleData != null && mounted) {
        // 缓存字幕数据
        _subtitleCache[subtitleKey] = subtitleData;
        setState(() {
          _subtitles = subtitleData;
          _showSubtitles = true;
        });
      }
    } else {
      _subtitleCache[subtitleKey] = [];
      setState(() {
        _subtitles = [];
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有找到字幕'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildSubtitlesView() {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, sequenceSnapshot) {
        final src = sequenceSnapshot.data?.currentSource;
        final currentAid = src?.tag.extras['aid'] as int?;
        final currentCid = src?.tag.extras['cid'] as int?;

        if (currentAid == null || currentCid == null) {
          return Center(
            child: Text(
              '歌曲信息暂未加载',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          );
        }

        // 检查字幕是否与当前播放的视频匹配
        if ('${currentAid}_$currentCid' != currentKey) {
          currentKey = '${currentAid}_$currentCid';
          Future.microtask(() => _loadSubtitles(currentAid, currentCid));

          if (_subtitles == null) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        }

        return GestureDetector(
          onTap: () {
            setState(() {
              _showSubtitles = false;
              _subtitles = null;
            });
          },
          child: StreamBuilder<Duration>(
            stream: _audioService!.player.positionStream,
            builder: (context, snapshot) {
              final position = snapshot.data?.inMilliseconds ?? 0;

              if (_subtitles == null || _subtitles!.isEmpty) {
                return Center(
                  child: Text(
                    '暂无歌词',
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                );
              }

              const subTitleHeight = 36.0;

              // 找到当前歌词索引
              final currentIndex = _subtitles!.indexWhere((subtitle) =>
                  position >= subtitle.from && position <= subtitle.to);

              // 自动滚动到当前歌词
              if (currentIndex != -1) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!_subtitleScrollController.hasClients) return;
                  if (_subtitleScrollController
                      .position.isScrollingNotifier.value) {
                    return;
                  }

                  _subtitleScrollController.scrollToIndex(
                    currentIndex,
                    preferPosition: AutoScrollPosition.middle,
                    duration: const Duration(milliseconds: 300),
                  );
                });
              }

              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.5,
                child: ListView.builder(
                  controller: _subtitleScrollController,
                  padding: const EdgeInsets.symmetric(vertical: 80),
                  itemCount: _subtitles!.length,
                  physics: const ClampingScrollPhysics(),
                  itemBuilder: (context, index) {
                    final subtitle = _subtitles![index];
                    final isActive =
                        position >= subtitle.from && position <= subtitle.to;
                    final isNext = index == currentIndex + 1;

                    return AutoScrollTag(
                      key: ValueKey(index),
                      index: index,
                      controller: _subtitleScrollController,
                      child: Container(
                        height: subTitleHeight,
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 24),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          style: TextStyle(
                            fontSize: isActive ? 18 : (isNext ? 15 : 14),
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.normal,
                            color: isActive
                                ? Theme.of(context).colorScheme.primary
                                : (isNext
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.8)
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5)),
                            height: 1.2,
                          ),
                          child: Center(
                              child: GestureDetector(
                            onTap: () {
                              // 点击歌词跳转到对应时间
                              _audioService!.player
                                  .seek(Duration(milliseconds: subtitle.from));
                            },
                            child: Text(
                              subtitle.content,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          )),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _commentCache.clear();
    _subtitleScrollController.dispose();
    super.dispose();
  }
}
