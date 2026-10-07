import 'dart:io';

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/util/widget.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../screen/detail_screen.dart';
import '../audio/audio_player_ext.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'playlist_bottom_sheet.dart';

/// 「正在播放」页路由：各平台使用与自身返回手势一致的内置转场——
/// - Android：平台默认转场（支持系统预测性返回，横向进入/退出），
///   页内不提供下滑关闭手势（见 DetailScreen.build）；
/// - iOS：原生底部模态转场 + 页内下滑关闭手势；
/// - 桌面：无系统返回手势，使用纵向滑入/滑出模态，与下滑手势连贯。
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
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
      return super
          .buildTransitions(context, animation, secondaryAnimation, child);
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

  /// AudioService 单例 future 缓存：build 中临时新建 Future 会让
  /// FutureBuilder 回到 waiting 态，父级重建时迷你播放条闪烁并
  /// 重建整棵子树
  late final Future<AudioPlayer> _playerFuture =
      AudioService.instance.then((x) => x.player);

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

  /// 进度条由高频 positionStream 单独驱动：每次位置更新只重建
  /// ProgressBar 自身（RepaintBoundary 隔离重绘范围），封面/标题/
  /// 按钮等静态部分不再随播放进度每秒重建数次
  Widget _buildProgressBar(AudioPlayer player, Duration duration) {
    final colorScheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (context, snapshot) {
          return ProgressBar(
            progress: snapshot.data ?? Duration.zero,
            total: duration,
            onSeek: player.seek,
            barHeight: 2,
            baseBarColor: colorScheme.surfaceDim,
            progressBarColor: colorScheme.primary,
            thumbRadius: 0,
            timeLabelLocation: TimeLabelLocation.none,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: _playerFuture,
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
              // 低频流：仅切歌/时长/播放状态变化时发射；
              // 播放进度的高频更新只重建 _buildProgressBar
              child: StreamBuilder<(SequenceState?, Duration?, PlayerState)>(
                stream: Rx.combineLatest3(
                  player.sequenceStateStream,
                  player.durationStream,
                  player.playerStateStream,
                  (a, b, c) => (a, b, c),
                ),
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  final state = data?.$1;
                  if (state?.sequence.isEmpty ?? true) {
                    return const SizedBox.shrink();
                  }
                  final artUri =
                      state?.currentSource?.tag.artUri?.toString() ?? "";
                  final duration = data?.$2 ?? Duration.zero;
                  final playing = data?.$3.playing ?? false;
                  final isLoadingOrBuffering = [
                    ProcessingState.loading,
                    ProcessingState.buffering
                  ].contains(data?.$3.processingState);
                  final progressBar = _buildProgressBar(player, duration);

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      progressBar,

                      // Main content
                      InkWell(
                        onTap: _openDetail,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          // 窄窗（分屏/小窗）下紧凑布局：封面缩小、
                          // 只保留播放/下一首，避免行向右溢出
                          child: LayoutBuilder(
                            builder: (context, box) {
                              final compact = box.maxWidth < 340;
                              return Row(
                            children: [
                              // Album art
                              shadow(
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: SizedBox(
                                    width: compact ? 56 : 78,
                                    height: compact ? 36 : 48,
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
                                        // 本地音乐封面为 file:// 路径
                                        : artUri.startsWith('file://')
                                            ? Image.file(
                                                File(artUri.substring(7)),
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    Container(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                  child: Icon(Icons.music_note,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary),
                                                ),
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
                                  if (!compact)
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
                                  if (!compact)
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
                                          showDragHandle: true,
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
                              );
                            },
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
