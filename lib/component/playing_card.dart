import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/util/widget.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../screen/detail_screen.dart';
import '../audio/audio_player_ext.dart';
import '../util/route_transitions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'playlist_bottom_sheet.dart';

class PlayingCard extends StatelessWidget {
  const PlayingCard({super.key});

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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              StreamBuilder<SequenceState?>(
                stream: player.sequenceStateStream,
                builder: (context, snapshot) {
                  final state = snapshot.data;
                  if (state?.sequence.isEmpty ?? true) {
                    return const SizedBox.shrink();
                  }
                  final artUri =
                      state?.currentSource?.tag.artUri.toString() ?? "";

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Progress bar
                      StreamBuilder<Duration>(
                        stream: player.positionStream,
                        builder: (context, snapshot) {
                          return ProgressBar(
                            progress: snapshot.data ?? Duration.zero,
                            total: player.duration ?? Duration.zero,
                            onSeek: player.seek,
                            barHeight: 2,
                            baseBarColor:
                                Theme.of(context).colorScheme.surfaceDim,
                            progressBarColor:
                                Theme.of(context).colorScheme.primary,
                            thumbRadius: 0,
                            timeLabelLocation: TimeLabelLocation.none,
                          );
                        },
                      ),

                      // Main content
                      InkWell(
                        onTap: () => Navigator.push(
                          context,
                          zoomRoute(const DetailScreen()),
                        ),
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
                                            imageUrl: artUri,
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
                                    style: const ButtonStyle(
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: player.hasPrevious
                                        ? player
                                            .seekToPreviousRegardlessOfLoopMode
                                        : null,
                                  ),
                                  StreamBuilder<PlayerState>(
                                    stream: player.playerStateStream,
                                    builder: (context, snapshot) {
                                      final playing = player.playing;
                                      final processingState =
                                          snapshot.data?.processingState;
                                      final isLoadingOrBuffering = [
                                        ProcessingState.loading,
                                        ProcessingState.buffering
                                      ].contains(processingState);

                                      return Opacity(
                                        opacity:
                                            isLoadingOrBuffering ? 0.6 : 1.0,
                                        child: IconButton(
                                          style: const ButtonStyle(
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          constraints: BoxConstraints(),
                                          icon: Icon(playing
                                              ? Icons.pause
                                              : Icons.play_arrow),
                                          onPressed: playing
                                              ? player.pause
                                              : player.play,
                                        ),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next),
                                    style: const ButtonStyle(
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: player.hasNext
                                        ? player.seekToNextRegardlessOfLoopMode
                                        : null,
                                  ),
                                  // Add playlist button
                                  IconButton(
                                    icon: const Icon(Icons.queue_music),
                                    style: const ButtonStyle(
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
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
              )
            ]),
          );
        });
  }
}
