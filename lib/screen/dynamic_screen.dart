import 'package:flutter/rendering.dart';
import 'package:bmsc/component/excluded_parts_dialog.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/dynamic.dart';
import '../component/playing_card.dart';
import '../util/logger.dart';

class DynamicScreen extends StatefulWidget {
  const DynamicScreen({super.key});

  @override
  State<StatefulWidget> createState() => _DynamicScreenState();
}

class _DynamicScreenState extends State<DynamicScreen> {
  static final _logger = LoggerUtils.getLogger('DynamicScreen');
  bool login = true;
  List<Modules> dynList = [];
  @override
  void initState() {
    super.initState();
    loadMore();
    _checkLogin();
  }

  void _checkLogin() async {
    final info = await BilibiliService.instance.then((x) => x.myInfo);
    setState(() {
      login = info != null && info.mid != 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('动态')),
      body: login ? dynListView() : const Center(child: Text('请先登录')),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  dynListView() {
    return NotificationListener<ScrollEndNotification>(
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
          itemCount: dynList.length,
          itemBuilder: (context, index) => dynListTileView(index),
        ));
  }

  String? offset;
  loadMore() async {
    _logger.info('loadMore: offset=$offset dynList.len=${dynList.length}');
    final detail =
        await BilibiliService.instance.then((x) => x.getDynamics(offset));
    if (detail == null) {
      _logger.info('loadMore: detail is null');
      return;
    }
    _logger.info('loadMore: got ${detail.items.length} items');
    setState(() {
      dynList.addAll(detail.items
          .map((e) => e.modules)
          .where((m) => m.moduleDynamic.major.archive != null));
      offset = detail.offset;
    });
    _logger.info('loadMore: done dynList.len=${dynList.length}');
  }

  dynListTileView(int index) {
    final arc = dynList[index].moduleDynamic.major.archive!;
    return TrackTile(
      key: Key(arc.bvid),
      pic: arc.cover,
      title: arc.title,
      author: dynList[index].moduleAuthor.name,
      len: arc.durationText,
      view: arc.stat.play,
      time: dynList[index].moduleAuthor.pubTime,
      onTap: () =>
          AudioService.instance.then((x) => x.playByBvid(arc.bvid)),
      onAddToPlaylistButtonPressed: () => AudioService.instance.then((x) =>
          x.appendPlaylist(arc.bvid,
              insertIndex:
                  x.playlist.length == 0 ? 0 : x.player.currentIndex! + 1)),
      onLongPress: () async {
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.person),
                  title: const Text('查看 UP 主'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => UserDetailScreen(
                              mid: dynList[index].moduleAuthor.mid)),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.comment_outlined),
                  title: const Text('查看评论'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => CommentScreen(
                                aid: arc.aid)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_remove),
                  title: const Text('屏蔽分 P'),
                  onTap: () {
                    Navigator.pop(context);
                    showDialog(
                      context: context,
                      builder: (context) => ExcludedPartsDialog(
                        bvid: arc.bvid,
                        title: arc.title,
                      ),
                    ).then((_) {
                      setState(() {});
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}