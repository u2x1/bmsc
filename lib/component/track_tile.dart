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
    this.time,
    this.parts,
    this.cached,
    required this.onTap,
  });

  final String? pic;
  final String title;
  final String author;
  final String len;
  final String? view;
  final String? time;
  final int? parts;
  final bool? cached;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      elevation: 2,
      shadowColor: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
      color: cached == true ? Colors.green.withOpacity(0.1) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: pic == null
                      ? Container(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(
                            Icons.music_note,
                            color: Theme.of(context).colorScheme.primary,
                            size: 20,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: pic!,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.music_note,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.music_note,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                          ),
                          memCacheWidth: 96,
                          memCacheHeight: 96,
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
                        if (cached == true) ...[
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 2),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 12,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(
                            author,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        
                        if (parts != null) ...[
                          Icon(
                            Icons.playlist_play,
                            size: 12,
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            parts.toString(),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Icon(
                          Icons.schedule,
                          size: 12,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          len,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                        ),
                        if (view != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.visibility_outlined,
                            size: 12,
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            view!,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                        ],
                        if (time != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.access_time,
                            size: 12,
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            time!,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
