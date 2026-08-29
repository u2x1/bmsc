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
  bool? login;
  List<Modules> dynList = [];
  bool _isLoading = false;
  bool _hasMore = true;
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
      appBar: AppBar(title: const Text('动态')),
      body: login == null
          ? const Center(child: CircularProgressIndicator())
          : login! ? dynListView() : const Center(child: Text('请先登录')),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  dynListView() {
    if (dynList.isEmpty) {
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
      return const Center(child: Text('暂无动态'));
    }
    return RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollEndNotification>(
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
              key: const PageStorageKey('dynamic_list'),
              scrollCacheExtent: ScrollCacheExtent.pixels(10000),
              itemCount: dynList.length + 1,
              itemBuilder: (context, index) =>
                  index == dynList.length ? footerView() : dynListTileView(index),
            )));
  }

  Future<void> _refresh() async {
    setState(() {
      dynList.clear();
      offset = null;
      _hasMore = true;
      _loadFailed = false;
    });
    await loadMore();
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
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: Text('没有更多了')),
      );
    }
    return const SizedBox.shrink();
  }

  String? offset;
  loadMore() async {
    if (_isLoading || !_hasMore) return;
    _logger.info('loadMore: offset=$offset dynList.len=${dynList.length}');
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final detail =
        await BilibiliService.instance.then((x) => x.getDynamics(offset));
    if (!mounted) return;
    if (detail == null) {
      _logger.info('loadMore: detail is null');
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
      return;
    }
    _logger.info('loadMore: got ${detail.items.length} items');
    setState(() {
      final bvids =
          dynList.map((m) => m.moduleDynamic.major.archive!.bvid).toSet();
      dynList.addAll(detail.items
          .map((e) => e.modules)
          .where((m) => m.moduleDynamic.major.archive != null)
          .where((m) => bvids.add(m.moduleDynamic.major.archive!.bvid)));
      if (detail.items.isEmpty ||
          detail.offset.isEmpty ||
          detail.offset == offset) {
        _hasMore = false;
      } else {
        _hasMore = detail.hasMore;
        offset = detail.offset;
      }
      _isLoading = false;
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
      onTap: () => AudioService.instance.then((x) => x.playByBvid(arc.bvid)),
      onAddToPlaylistButtonPressed: () => AudioService.instance.then((x) =>
          x.appendPlaylist(arc.bvid,
              insertIndex: x.playlist.length == 0
                  ? 0
                  : (x.player.currentIndex ?? 0) + 1)),
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
                            builder: (context) => CommentScreen(aid: arc.aid)));
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
