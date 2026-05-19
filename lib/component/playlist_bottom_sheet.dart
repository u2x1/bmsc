import 'package:bmsc/service/audio_service.dart';
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final currentIndex =
          await AudioService.instance.then((x) => x.player.currentIndex);
      if (currentIndex != null) {
        _scrollController.scrollToIndex(currentIndex,
            preferPosition: AutoScrollPosition.middle);
      }
    });
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

                    return ReorderableListView.builder(
                      scrollController: _scrollController,
                      shrinkWrap: true,
                      itemCount: playlist.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        if (oldIndex < newIndex) newIndex--;
                        await service.doAndSavePlaylist(() async {
                          await service.playlist.move(oldIndex, newIndex);
                        });
                      },
                      itemBuilder: (context, index) {
                        final item = playlist[index].tag;
                        return AutoScrollTag(
                          key: ValueKey(index),
                          index: index,
                          controller: _scrollController,
                          child: StreamBuilder<SequenceState?>(
                              key: ValueKey('${item.id}_$index'),
                              stream: service.player.sequenceStateStream,
                              builder: (context, snapshot) {
                                final isPlaying =
                                    snapshot.data?.currentIndex == index;
                                return ListTile(
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
                                          ? Icon(Icons.play_arrow,
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
                                          margin:
                                              const EdgeInsets.only(right: 4),
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
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(Icons.check_circle,
                                              size: 16,
                                              color: Color(0xFF66BB6A)),
                                        ),
                                    ],
                                  ),
                                  subtitle: Row(
                                    children: [
                                      if (item.extras['multi'] ?? false) ...[
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 4),
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
                                      if (item.extras['multi'] ?? false)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(right: 8),
                                          child: InkWell(
                                            onTap: () {
                                              DatabaseManager.addExcludedPart(
                                                  item.extras['bvid'] as String,
                                                  item.extras['cid'] as int);
                                              service
                                                  .doAndSavePlaylist(() async {
                                                await service.playlist
                                                    .removeAt(index);
                                              });
                                            },
                                            child: const Icon(
                                                Icons.not_interested,
                                                size: 20),
                                          ),
                                        ),
                                      Container(
                                        margin: const EdgeInsets.only(right: 8),
                                        child: InkWell(
                                          onTap: () {
                                            service.doAndSavePlaylist(() async {
                                              await service.playlist
                                                  .removeAt(index);
                                            });
                                          },
                                          child: const Icon(Icons.delete,
                                              size: 20),
                                        ),
                                      ),
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: const Icon(Icons.drag_handle,
                                            size: 24),
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    await service.player
                                        .seek(Duration.zero, index: index);
                                    await service.player.play();
                                  },
                                );
                              }),
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
