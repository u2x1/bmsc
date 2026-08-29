import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/theme.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../database_manager.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class PlaylistBottomSheet extends StatefulWidget {
  const PlaylistBottomSheet({super.key});

  @override
  State<PlaylistBottomSheet> createState() => _PlaylistBottomSheetState();
}

class _PlaylistBottomSheetState extends State<PlaylistBottomSheet> {
  final AutoScrollController _scrollController = AutoScrollController();
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    // 只在初次构建时滚动到当前播放项，避免重建时拽回用户滚动位置
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final currentIndex =
          await AudioService.instance.then((x) => x.player.currentIndex);
      if (currentIndex != null && mounted) {
        _scrollController.scrollToIndex(currentIndex,
            preferPosition: AutoScrollPosition.middle);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: AudioService.instance,
        builder: (context, snapshot) {
          final service = snapshot.data;
          if (service == null) {
            return const SizedBox.shrink();
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with loop mode control
              ListTile(
                title: StreamBuilder<List<IndexedAudioSource>?>(
                  stream: service.player.sequenceStream,
                  builder: (_, snapshot) {
                    return Row(
                      children: [
                        SizedBox(width: 10),
                        Text(
                          "播放列表 (${snapshot.data?.length ?? 0})",
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.8),
                                  ),
                        )
                      ],
                    );
                  },
                ),
                trailing: SizedBox(
                  width: 140,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.playlist_remove, size: 20),
                        tooltip: '清空',
                        style: const ButtonStyle(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {
                          if (service.playlist.length == 0) {
                            return;
                          }
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('清空播放列表'),
                              content: const Text('确定要清空播放列表吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () {
                                    service.doAndSavePlaylist(() async {
                                      await service.playlist.clear();
                                    });
                                    Navigator.pop(context);
                                  },
                                  child: const Text('确定'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      StreamBuilder<(LoopMode, bool)>(
                        stream: Rx.combineLatest2(
                          service.player.loopModeStream,
                          service.player.shuffleModeEnabledStream,
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
                          final index = shuffleModeEnabled
                              ? 3
                              : LoopMode.values.indexOf(loopMode);

                          return IconButton(
                            icon: Icon(
                              icons[index],
                              size: 20,
                            ),
                            style: const ButtonStyle(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              final idx = (index + 1) % icons.length;

                              if (idx == 3) {
                                service.player.setShuffleModeEnabled(true);
                              } else {
                                service.player
                                    .setLoopMode(LoopMode.values[idx]);
                                service.player.setShuffleModeEnabled(false);
                              }
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              // Playlist
              Flexible(
                child: StreamBuilder<List<IndexedAudioSource>?>(
                  stream: service.player.sequenceStream,
                  builder: (_, snapshot) {
                    final playlist = snapshot.data;
                    if (playlist == null || playlist.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无歌曲'),
                      );
                    }

                    // 外层监听一次播放状态，避免每行单独订阅
                    return StreamBuilder<(SequenceState?, PlayerState)>(
                      stream: Rx.combineLatest2(
                        service.player.sequenceStateStream,
                        service.player.playerStateStream,
                        (a, b) => (a, b),
                      ),
                      builder: (_, stateSnapshot) {
                        final currentIndex =
                            stateSnapshot.data?.$1?.currentIndex;
                        final playing = stateSnapshot.data?.$2.playing ?? false;

                        // 保留 shrinkWrap 让弹层高度贴合内容
                        return ReorderableListView.builder(
                          scrollController: _scrollController,
                          shrinkWrap: true,
                          itemCount: playlist.length,
                          onReorderItem: (oldIndex, newIndex) async {
                            // 长辈模式下不允许重排
                            if (ThemeProvider.instance.elderMode) return;
                            if (oldIndex < newIndex) newIndex--;
                            await service.doAndSavePlaylist(() async {
                              await service.playlist.move(oldIndex, newIndex);
                            });
                          },
                          itemBuilder: (context, index) {
                            final item = playlist[index].tag;
                            final isPlaying = currentIndex == index;
                            return AutoScrollTag(
                              key: ValueKey(
                                  '${item.id}_${item.extras['bvid']}_${item.extras['cid']}'),
                              index: index,
                              controller: _scrollController,
                              child: ListTile(
                                dense: true,
                                visualDensity:
                                    const VisualDensity(vertical: -2),
                                contentPadding:
                                    const EdgeInsets.only(left: 16, right: 8),
                                minLeadingWidth: 24,
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    isPlaying
                                        ? Icon(
                                            playing
                                                ? Icons.play_arrow
                                                : Icons.pause,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            size: 20)
                                        : Text('${index + 1}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                  ],
                                ),
                                title: Row(
                                  children: [
                                    if (item.extras['dummy'] ?? false)
                                      Container(
                                        margin: const EdgeInsets.only(right: 4),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 2, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Icon(Icons.hourglass_empty,
                                            size: 12),
                                      ),
                                    Flexible(
                                      // Added Flexible widget here
                                      child: Text(
                                        item.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: isPlaying
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                  : null,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (item.extras['cached'] ?? false)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4),
                                        child: Icon(Icons.check_circle,
                                            size: 16,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .tertiary),
                                      ),
                                  ],
                                ),
                                subtitle: Row(
                                  children: [
                                    if (item.extras['multi'] ?? false) ...[
                                      const Padding(
                                        padding:
                                            EdgeInsets.symmetric(horizontal: 4),
                                        child: Icon(Icons.album, size: 12),
                                      ),
                                      Flexible(
                                        child: Text(
                                          item.extras['raw_title'] as String,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ] else
                                      Flexible(
                                        child: Text(
                                          item.artist ?? '',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 长辈模式下隐藏屏蔽/删除，防止误删
                                    if (ThemeProvider.instance.elderMode)
                                      const SizedBox.shrink()
                                    else ...[
                                      if (item.extras['multi'] ?? false)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(right: 8),
                                          child: IconButton(
                                            tooltip: '屏蔽该分 P',
                                            style: const ButtonStyle(
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            constraints: const BoxConstraints(
                                                minWidth: 40, minHeight: 40),
                                            padding: EdgeInsets.zero,
                                            iconSize: 20,
                                            icon: const Icon(
                                                Icons.not_interested),
                                            onPressed: () async {
                                              final bvid =
                                                  item.extras['bvid'] as String;
                                              final cid =
                                                  item.extras['cid'] as int;
                                              final removedSource =
                                                  playlist[index];
                                              await DatabaseManager
                                                  .addExcludedPart(bvid, cid);
                                              await service
                                                  .doAndSavePlaylist(() async {
                                                await service.playlist
                                                    .removeAt(index);
                                              });
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content:
                                                      const Text('已屏蔽该分 P'),
                                                  action: SnackBarAction(
                                                    label: '撤销',
                                                    onPressed: () async {
                                                      await DatabaseManager
                                                          .removeExcludedPart(
                                                              bvid, cid);
                                                      await service
                                                          .doAndSavePlaylist(
                                                              () async {
                                                        if (index <=
                                                            service.playlist
                                                                .length) {
                                                          await service.playlist
                                                              .insert(index,
                                                                  removedSource);
                                                        } else {
                                                          await service.playlist
                                                              .add(
                                                                  removedSource);
                                                        }
                                                      });
                                                    },
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      Container(
                                        margin: const EdgeInsets.only(right: 8),
                                        child: IconButton(
                                          tooltip: '删除',
                                          style: const ButtonStyle(
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          constraints: const BoxConstraints(
                                              minWidth: 40, minHeight: 40),
                                          padding: EdgeInsets.zero,
                                          iconSize: 20,
                                          icon: const Icon(Icons.delete),
                                          onPressed: () async {
                                            final removedSource =
                                                playlist[index];
                                            await service
                                                .doAndSavePlaylist(() async {
                                              await service.playlist
                                                  .removeAt(index);
                                            });
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: const Text('已从播放列表删除'),
                                                action: SnackBarAction(
                                                  label: '撤销',
                                                  onPressed: () async {
                                                    await service
                                                        .doAndSavePlaylist(
                                                            () async {
                                                      if (index <=
                                                          service.playlist
                                                              .length) {
                                                        await service.playlist
                                                            .insert(index,
                                                                removedSource);
                                                      } else {
                                                        await service.playlist
                                                            .add(removedSource);
                                                      }
                                                    });
                                                  },
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                    if (!ThemeProvider.instance.elderMode)
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: const Icon(Icons.drag_handle,
                                            size: 24),
                                      ),
                                  ],
                                ),
                                onTap: () async {
                                  // 防止快速重复点击导致多次 seek
                                  if (_switching) {
                                    return;
                                  }
                                  _switching = true;
                                  try {
                                    await service.player
                                        .seek(Duration.zero, index: index);
                                    await service.player.play();
                                  } finally {
                                    _switching = false;
                                  }
                                },
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        });
  }
}
