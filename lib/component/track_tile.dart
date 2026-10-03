import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    this.pic,
    required this.title,
    required this.author,
    required this.len,
    this.view,
    this.playcnt,
    this.time,
    this.parts,
    this.album,
    this.excludedParts = 0,
    required this.onTap,
    this.cached = false,
    this.downloaded = false,
    this.onLongPress,
    this.onAddToPlaylistButtonPressed,
    this.color,
    this.onPicTap,
    this.progress,
  });

  final String? pic;
  final String title;
  final String author;
  final String len;
  final String? view;
  final String? playcnt;
  final String? time;
  final int? parts;
  final String? album;
  final int excludedParts;
  final bool cached;
  final bool downloaded;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAddToPlaylistButtonPressed;
  final VoidCallback? onPicTap;
  final Color? color;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress?.clamp(0.0, 1.0).toDouble();
    final colorScheme = Theme.of(context).colorScheme;
    const coverWidth = 76.0;
    const coverHeight = 48.0;
    const metaIconSize = 12.0;
    final secondaryStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: colorScheme.secondary);
    final smallStyle = secondaryStyle?.copyWith(fontSize: 11);
    final titleStyle = Theme.of(context).textTheme.titleSmall;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      elevation: 2,
      shadowColor: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.1),
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        children: [
          if (progress != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  children: [
                    Expanded(
                      flex: (progress * 100).round(),
                      child: Container(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.1),
                      ),
                    ),
                    Expanded(
                      flex: 100 - (progress * 100).round(),
                      child: const SizedBox(),
                    ),
                  ],
                ),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Semantics(
                          button: onPicTap != null,
                          label: onPicTap != null ? '查看封面' : null,
                          child: GestureDetector(
                            onTap: onPicTap,
                            child: SizedBox(
                              width: coverWidth,
                              height: coverHeight,
                              child: pic == null || pic == ""
                                  ? Container(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      child: Icon(
                                        Icons.music_note,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        size: 20,
                                      ),
                                    )
                                  : CachedNetworkImage(
                                      imageUrl: "${pic!}@256w_144h_1c",
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        child: Icon(
                                          Icons.music_note,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          size: 20,
                                        ),
                                      ),
                                      errorWidget: (_, __, ___) => Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        child: Icon(
                                          Icons.music_note,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          size: 20,
                                        ),
                                      ),
                                    ),
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
                            Row(
                              children: [
                                if (downloaded || cached) ...[
                                  Icon(
                                    Icons.check_circle,
                                    size: 16,
                                    color: downloaded
                                        ? colorScheme.tertiary
                                        : colorScheme.outline,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    title,
                                    style: titleStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (album != null) ...[
                                  Icon(
                                    Icons.album,
                                    size: metaIconSize,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ),
                                  const SizedBox(width: 2),
                                  Flexible(
                                    child: Text(
                                      album!,
                                      style: smallStyle,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Icon(
                                  Icons.person_outline,
                                  size: metaIconSize,
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                ),
                                const SizedBox(width: 2),
                                Flexible(
                                  child: Text(
                                    author,
                                    style: secondaryStyle,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // const SizedBox(width: 24),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (parts != null) ...[
                                  Icon(
                                    Icons.playlist_play,
                                    size: metaIconSize,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '$parts',
                                    style: smallStyle,
                                  ),
                                  if (excludedParts > 0) ...[
                                    Text(
                                      ' (-$excludedParts)',
                                      style: smallStyle?.copyWith(
                                          color: colorScheme.error),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                ],
                                Icon(
                                  Icons.schedule,
                                  size: metaIconSize,
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  len,
                                  style: smallStyle,
                                ),
                                if (view != null) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.visibility_outlined,
                                    size: metaIconSize,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    view!,
                                    style: smallStyle,
                                  ),
                                ],
                                if (time != null) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.access_time,
                                    size: metaIconSize,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    time!,
                                    style: smallStyle,
                                  ),
                                ],
                                if (playcnt != null) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.play_arrow,
                                    size: metaIconSize,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    playcnt!,
                                    style: smallStyle,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (onAddToPlaylistButtonPressed != null)
                        IconButton(
                          onPressed: onAddToPlaylistButtonPressed,
                          icon: const Icon(
                            Icons.add_circle_outline_rounded,
                            size: 24,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
