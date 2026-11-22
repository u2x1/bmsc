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
  const UserDetailScreen({super.key, required this.mid, this.seasonId});

  final int mid;
  final int? seasonId;

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
  bool _isLoading = false;
  bool _loadFailed = false;

  loadMore() async {
    if (pn == -1 || _isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final service = await BilibiliService.instance;
    (List<Meta>, int)? rst;
    final seasonId = widget.seasonId;
    if (seasonId != null) {
      final metas = await service.getCollectionMetas(seasonId);
      if (metas != null) {
        rst = (metas, -1);
      }
    } else {
      rst = await service.getUserUploads(widget.mid, pn);
    }
    if (!mounted) return;
    final result = rst;
    if (result == null) {
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
      return;
    }
    setState(() {
      final bvids = vidList.map((x) => x.bvid).toSet();
      vidList.addAll(result.$1.where((x) => bvids.add(x.bvid)));
      pn = result.$2;
      _isLoading = false;
    });
  }

  loadUserInfo() async {
    final rst = await (await BilibiliService.instance).getUserInfo(widget.mid);
    if (!mounted) return;
    setState(() {
      info = rst;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(widget.seasonId == null ? "用户详细" : "合集"),
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
          child: ListView.builder(
            scrollCacheExtent: ScrollCacheExtent.pixels(10000),
            itemCount: vidList.length + 2,
            itemBuilder: (context, index) => index == 0
                ? headerView()
                : index == vidList.length + 1
                    ? footerView()
                    : hisListTileView(index - 1),
          ),
        ));
  }

  Widget headerView() {
    return Column(
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
                        ? const Icon(Icons.person)
                        : CachedNetworkImage(
                            imageUrl: info!.card.face,
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                const Icon(Icons.person),
                            errorWidget: (context, url, error) =>
                                const Icon(Icons.person),
                          )),
              ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(info?.card.name ?? "",
                    style: const TextStyle(fontSize: 14),
                    softWrap: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
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
                widget.seasonId == null
                    ? "全部稿件 (${info?.archiveCount ?? 0})"
                    : "合集 (${vidList.length})",
                style: const TextStyle(fontSize: 16),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: Text(widget.seasonId == null
                    ? '播放已加载(${vidList.length})'
                    : '播放全部(${vidList.length})'),
                onPressed: widget.seasonId != null &&
                        (_isLoading || vidList.isEmpty)
                    ? null
                    : () async {
                        final bvids = vidList.map((x) => x.bvid).toList();
                        await AudioService.instance
                            .then((x) => x.playByBvids(bvids));
                      },
              ),
            )
          ],
        ),
      ],
    );
  }

  Widget footerView() {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(8.0),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_loadFailed) {
      return Center(
        child: TextButton(
          onPressed: loadMore,
          child: const Text('加载失败，点击重试'),
        ),
      );
    }
    if (vidList.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: Text('暂无稿件')),
      );
    }
    return const SizedBox.shrink();
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
