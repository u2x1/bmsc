import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/theme.dart';
import 'package:bmsc/util/widget.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../screen/detail_screen.dart';
import '../audio/audio_player_ext.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'playlist_bottom_sheet.dart';

/// 「正在播放」页路由：类 Apple Music 的底部滑入模态。
/// MaterialPageRoute(fullscreenDialog: true) 仅在 iOS 上是底部滑入，
/// Android 等平台走平台默认转场（侧向/淡入淡出），系统返回时与
/// 页内的下滑关闭手势方向不一致；这里统一为非 iOS 平台也使用
/// 纵向滑入/滑出，保证系统返回与下滑手势视觉连贯。
class _NowPlayingRoute extends MaterialPageRoute<void> {
  _NowPlayingRoute()
      : super(
          builder: (context) => const DetailScreen(),
          fullscreenDialog: true,
        );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // iOS 保留原生模态转场（底部滑入 + 背景压暗）
      return super.buildTransitions(
          context, animation, secondaryAnimation, child);
    }
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(curved),
      child: child,
    );
  }
}

class PlayingCard extends StatefulWidget {
  const PlayingCard({super.key});

  @override
  State<PlayingCard> createState() => _PlayingCardState();
}

class _PlayingCardState extends State<PlayingCard> {
  bool _navigating = false;

  Future<void> _openDetail() async {
    // 防止重复点击 push 多个 DetailScreen
    if (_navigating) {
      return;
    }
    _navigating = true;
    try {
      // 底部滑入模态样式（类 Apple Music「播放中」页），各平台一致；
      // 不支持左缘手势返回，由 DetailScreen 自行实现下滑关闭手势
      await Navigator.push(context, _NowPlayingRoute());
    } finally {
      _navigating = false;
    }
  }

  /// 长辈模式：两行布局——上行封面+歌名，下行三个带文字的超大按钮
  Widget _buildElderLayout(
    BuildContext context,
    AudioPlayer player,
    String artUri, {
    required String title,
    required String artist,
    required Duration position,
    required Duration duration,
    required bool playing,
    required bool isLoadingOrBuffering,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontWeight: FontWeight.w600);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProgressBar(
          progress: position,
          total: duration,
          onSeek: player.seek,
          barHeight: 6,
          baseBarColor: colorScheme.surfaceDim,
          progressBarColor: colorScheme.primary,
          thumbRadius: 8,
          thumbColor: colorScheme.primary,
          timeLabelLocation: TimeLabelLocation.none,
        ),
        InkWell(
          onTap: _openDetail,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                shadow(
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: artUri == ""
                          ? Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.music_note,
                                  size: 32, color: colorScheme.primary),
                            )
                          : CachedNetworkImage(
                              imageUrl: "$artUri@256w_144h_1c",
                              placeholder: (context, url) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 32, color: colorScheme.primary),
                              ),
                              errorWidget: (context, url, error) => Container(
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.music_note,
                                    size: 32, color: colorScheme.primary),
                              ),
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        artist,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 32, color: colorScheme.secondary),
              ],
            ),
          ),
        ),
        // 三个带文字的超大按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: _elderControlButton(
                  icon: Icons.skip_previous,
                  label: '上一首',
                  iconSize: 36,
                  labelStyle: labelStyle,
                  onPressed: player.hasPrevious
                      ? player.seekToPreviousRegardlessOfLoopMode
                      : null,
                ),
              ),
              Expanded(
                child: _elderControlButton(
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  label: isLoadingOrBuffering
                      ? '加载中'
                      : playing
                          ? '暂停'
                          : '播放',
                  iconSize: 44,
                  emphasized: true,
                  labelStyle: labelStyle,
                  onPressed: isLoadingOrBuffering
                      ? null
                      : playing
                          ? player.pause
                          : player.play,
                ),
              ),
              Expanded(
                child: _elderControlButton(
                  icon: Icons.skip_next,
                  label: '下一首',
                  iconSize: 36,
                  labelStyle: labelStyle,
                  onPressed: player.hasNext
                      ? player.seekToNextRegardlessOfLoopMode
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 长辈模式大按钮：图标在上、文字在下，整块区域可点
  Widget _elderControlButton({
    required IconData icon,
    required String label,
    required double iconSize,
    required TextStyle? labelStyle,
    required VoidCallback? onPressed,
    bool emphasized = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final iconColor = !enabled
        ? colorScheme.outline.withValues(alpha: 0.4)
        : emphasized
            ? colorScheme.onPrimary
            : colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            emphasized
                ? Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: enabled
                          ? colorScheme.primary
                          : colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: iconSize, color: iconColor),
                  )
                : Icon(icon, size: iconSize, color: iconColor),
            const SizedBox(height: 4),
            Text(
              label,
              style: labelStyle?.copyWith(
                color:
                    enabled ? null : colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: AudioService.instance.then((x) => x.player),
        builder: (context, snapshot) {
          final player = snapshot.data;
          if (player == null) {
            return const SizedBox.shrink();
          }
          return Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            elevation: 8,
            // edge-to-edge 下系统导航栏会覆盖底部内容，SafeArea 内缩避免
            // 迷你播放条被手势条/三键导航遮挡（issue #14）
            child: SafeArea(
              top: false,
              child: StreamBuilder<
                  (SequenceState?, Duration, Duration?, PlayerState)>(
                stream: Rx.combineLatest4(
                  player.sequenceStateStream,
                  player.positionStream,
                  player.durationStream,
                  player.playerStateStream,
                  (a, b, c, d) => (a, b, c, d),
                ),
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  final state = data?.$1;
                  if (state?.sequence.isEmpty ?? true) {
                    return const SizedBox.shrink();
                  }
                  final artUri =
                      state?.currentSource?.tag.artUri?.toString() ?? "";
                  final position = data?.$2 ?? Duration.zero;
                  final duration = data?.$3 ?? Duration.zero;
                  final playing = data?.$4.playing ?? false;
                  final isLoadingOrBuffering = [
                    ProcessingState.loading,
                    ProcessingState.buffering
                  ].contains(data?.$4.processingState);

                  if (ThemeProvider.instance.elderMode) {
                    return _buildElderLayout(
                      context,
                      player,
                      artUri,
                      title: state?.currentSource?.tag.title ?? "",
                      artist: state?.currentSource?.tag.artist ?? "",
                      position: position,
                      duration: duration,
                      playing: playing,
                      isLoadingOrBuffering: isLoadingOrBuffering,
                    );
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Progress bar
                      ProgressBar(
                        progress: position,
                        total: duration,
                        onSeek: player.seek,
                        barHeight: 2,
                        baseBarColor: Theme.of(context).colorScheme.surfaceDim,
                        progressBarColor: Theme.of(context).colorScheme.primary,
                        thumbRadius: 0,
                        timeLabelLocation: TimeLabelLocation.none,
                      ),

                      // Main content
                      InkWell(
                        onTap: _openDetail,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Row(
                            children: [
                              // Album art
                              shadow(
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: SizedBox(
                                    width: 78,
                                    height: 48,
                                    child: artUri == ""
                                        ? Container(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            child: Icon(Icons.music_note,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary),
                                          )
                                        : CachedNetworkImage(
                                            imageUrl: "$artUri@256w_144h_1c",
                                            placeholder: (context, url) =>
                                                Container(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              child: Icon(Icons.music_note,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary),
                                            ),
                                            errorWidget:
                                                (context, url, error) =>
                                                    Container(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              child: Icon(Icons.music_note,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary),
                                            ),
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                              ),

                              const SizedBox(width: 12),

                              // Title and artist
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      state?.currentSource?.tag.title ?? "",
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      state?.currentSource?.tag.artist ?? "",
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),

                              // Controls
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous),
                                    onPressed: player.hasPrevious
                                        ? player
                                            .seekToPreviousRegardlessOfLoopMode
                                        : null,
                                  ),
                                  Opacity(
                                    opacity: isLoadingOrBuffering ? 0.6 : 1.0,
                                    child: IconButton(
                                      icon: Icon(playing
                                          ? Icons.pause
                                          : Icons.play_arrow),
                                      onPressed: isLoadingOrBuffering
                                          ? null
                                          : playing
                                              ? player.pause
                                              : player.play,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next),
                                    onPressed: player.hasNext
                                        ? player.seekToNextRegardlessOfLoopMode
                                        : null,
                                  ),
                                  // Add playlist button
                                  IconButton(
                                    icon: const Icon(Icons.queue_music),
                                    onPressed: () {
                                      showModalBottomSheet(
                                        context: context,
                                        builder: (context) =>
                                            const PlaylistBottomSheet(),
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .surface,
                                        isScrollControlled: true,
                                        constraints: BoxConstraints(
                                          maxHeight: MediaQuery.of(context)
                                                  .size
                                                  .height *
                                              0.7,
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        });
  }
}
