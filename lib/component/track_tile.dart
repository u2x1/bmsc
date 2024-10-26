import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

Widget trackTile(
    {String? pic,
    required String title,
    required String author,
    required String len,
    required String view,
    String? time,
    required void Function()? onTap}) {
  return Stack(alignment: FractionalOffset.bottomRight, children: [
    Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListTile(
            onTap: onTap,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(5.0),
              child: SizedBox(
                  width: 50,
                  height: 50,
                  child: pic == null
                      ? const Icon(Icons.music_note)
                      : CachedNetworkImage(
                          imageUrl: pic,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => const Icon(Icons.music_note),
                          errorWidget: (context, url, error) => const Icon(Icons.music_note),
                        )),
            ),
            title: Text(
              title,
              style: const TextStyle(fontSize: 14),
              softWrap: false,
            ),
            subtitle: Row(
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 14,
                ),
                Text(author, style: const TextStyle(fontSize: 12)),
              ],
            )),
      ],
    ),
    Container(
        margin: const EdgeInsets.all(10),
        child: Text(
          "$len / $view ${time == null ? "" : " | $time"}",
          textAlign: TextAlign.left,
          style: const TextStyle(fontSize: 8),
        )),
  ]);
}
