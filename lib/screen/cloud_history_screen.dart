import 'package:flutter/rendering.dart';
import 'package:bmsc/component/download_parts_dialog.dart';
import 'package:bmsc/component/excluded_parts_dialog.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/history.dart';
import '../util/string.dart';
import '../component/playing_card.dart';
import '../util/logger.dart';

class CloudHistoryScreen extends StatefulWidget {
  const CloudHistoryScreen({super.key});

  @override
  State<StatefulWidget> createState() => _CloudHistoryScreenState();
}

class _CloudHistoryScreenState extends State<CloudHistoryScreen> {
  static final _logger = LoggerUtils.getLogger('CloudHistoryScreen');
  bool? login;
  List<HistoryData> hisList = [];
  bool _isLoading = false;
  bool _loadFailed = false;
  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  void _checkLogin() async {
    final info = await BilibiliService.instance.then((x) => x.myInfo);
    if (!mounted) return;
    setState(() {
      login = info != null && info.mid != 0;
    });
    if (login == true) {
      loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云端历史记录')),
      body: login == null
          ? const Center(child: CircularProgressIndicator())
          : login! ? hisListView() : const Center(child: Text('请先登录')),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  hisListView() {
    if (hisList.isEmpty) {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_loadFailed) {
        return Center(
          child: TextButton(
            onPressed: loadMore,
            child: const Text('加载失败，点击重试'),
          ),
        );
      }
      return const Center(child: Text('暂无云端历史记录'));
    }
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
          itemCount: hisList.length + 1,
          itemBuilder: (context, index) =>
              index == hisList.length ? footerView() : hisListTileView(index),
        ));
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
    return const SizedBox.shrink();
  }

  int viewat = 0;
  loadMore() async {
    if (_isLoading) return;
    _logger.info('loadMore: viewat=$viewat hisList.len=${hisList.length}');
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final detail =
        await BilibiliService.instance.then((x) => x.getHistory(viewat));
    if (!mounted) return;
    if (detail == null) {
      _logger.info('loadMore: detail is null');
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
      return;
    }
    _logger.info('loadMore: got ${detail.list.length} items');
    setState(() {
      hisList.addAll(detail.list.where((x) => x.history.bvid.isNotEmpty));
      viewat = detail.cursor.viewAt;
      _isLoading = false;
    });
    _logger.info('loadMore: done hisList.len=${hisList.length}');
  }

  hisListTileView(int index) {
    int min = hisList[index].duration ~/ 60;
    int sec = hisList[index].duration % 60;
    final duration = "$min:${sec.toString().padLeft(2, '0')}";
    return TrackTile(
      key: Key('${hisList[index].history.bvid}-${hisList[index].viewAt}'),
      pic: hisList[index].cover,
      title: hisList[index].title,
      author: hisList[index].authorName,
      len: duration,
      view: time(hisList[index].viewAt * 1000000),
      onTap: () => AudioService.instance
          .then((x) => x.playByBvid(hisList[index].history.bvid)),
      onAddToPlaylistButtonPressed: () => AudioService.instance.then((x) =>
          x.appendPlaylist(hisList[index].history.bvid,
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
                                mid: hisList[index].authorMid)));
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
                                aid: hisList[index].history.oid.toString())));
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
                        bvid: hisList[index].history.bvid,
                        title: hisList[index].title,
                      ),
                    ).then((_) {
                      setState(() {});
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('下载'),
                  onTap: () {
                    Navigator.pop(context);
                    showDialog(
                      context: context,
                      builder: (context) => DownloadPartsDialog(
                        bvid: hisList[index].history.bvid,
                        title: hisList[index].title,
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
