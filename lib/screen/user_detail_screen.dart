import 'package:flutter/rendering.dart';
import 'package:bmsc/model/user_card.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/util/string.dart';
import 'package:flutter/material.dart';

import '../component/track_tile.dart';
import 'package:cached_network_image/cached_network_image.dart';

class UserDetailScreen extends StatefulWidget {
  const UserDetailScreen({super.key, required this.mid});

  final int mid;

  @override
  State<StatefulWidget> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  @override
  void initState() {
    super.initState();
    loadUserInfo();
    loadMore();
  }

  List<Meta> vidList = [];
  UserInfoResult? info;
  int pn = 1;

  loadMore() async {
    if (pn == -1) {
      return;
    }
    final rst =
        await (await BilibiliService.instance).getUserUploads(widget.mid, pn);
    if (rst == null) {
      return;
    }
    setState(() {
      pn = rst.$2;
      vidList.addAll(rst.$1);
    });
  }

  loadUserInfo() async {
    info = await (await BilibiliService.instance).getUserInfo(widget.mid);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text("用户详细"),
        ),
        body: NotificationListener<ScrollEndNotification>(
          onNotification: (scrollEnd) {
            final metrics = scrollEnd.metrics;
            if (metrics.atEdge) {
              bool isTop = metrics.pixels == 0;
              if (!isTop) {
                loadMore();
              }
            }
            return true;
          },
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 100,
                      height: 100,
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(5.0),
                          child: info == null
                              ? const Icon(Icons.question_mark)
                              : CachedNetworkImage(
                                  imageUrl: info!.card.face,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) =>
                                      const Icon(Icons.question_mark),
                                  errorWidget: (context, url, error) =>
                                      const Icon(Icons.question_mark),
                                )),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(info?.card.name ?? "",
                        style: const TextStyle(fontSize: 14),
                        softWrap: false,
                        maxLines: 1),
                  )
                ],
              ),
              const Divider(
                height: 1,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14.0),
                    child: Text(
                      "全部稿件 (${info?.archiveCount ?? 0})",
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放全部'),
                      style: ElevatedButton.styleFrom(
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(0),
                        ),
                      ),
                      onPressed: () async {
                        final bvids = vidList.map((x) => x.bvid).toList();
                        await AudioService.instance
                            .then((x) => x.playByBvids(bvids));
                      },
                    ),
                  )
                ],
              ),
              vidListView(),
            ],
          ),
        ));
  }

  vidListView() {
    return ListView.builder(
      scrollCacheExtent: ScrollCacheExtent.pixels(10000),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: vidList.length,
      itemBuilder: (context, index) => hisListTileView(index),
    );
  }

  hisListTileView(int index) {
    int min = vidList[index].duration ~/ 60;
    int sec = vidList[index].duration % 60;
    final duration = "$min:${sec.toString().padLeft(2, '0')}";
    return TrackTile(
      key: Key(vidList[index].bvid),
      pic: vidList[index].artUri,
      title: vidList[index].title,
      author: vidList[index].artist,
      len: duration,
      view: vidList[index].play == null ? null : unit(vidList[index].play!),
      onTap: () =>
          AudioService.instance.then((x) => x.playByBvid(vidList[index].bvid)),
    );
  }
}
