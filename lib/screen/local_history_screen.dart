import 'package:flutter/rendering.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/screen/cloud_history_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/util/string.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/play_stat.dart';
import '../component/playing_card.dart';

enum OrderBy {
  lastplay,
  playcnt,
  playtime,
}

class LocalHistoryScreen extends StatefulWidget {
  const LocalHistoryScreen({super.key});

  @override
  State<StatefulWidget> createState() => _LocalHistoryScreenState();
}

class _LocalHistoryScreenState extends State<LocalHistoryScreen> {
  List<PlayStat> hisList = [];
  OrderBy _orderBy = OrderBy.lastplay;
  @override
  void initState() {
    super.initState();
    loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地历史记录'),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<Widget>(
                  builder: (_) => const CloudHistoryScreen()),
            ),
            icon: const Icon(Icons.cloud_outlined),
          ),
          PopupMenuButton<OrderBy>(
            icon: const Icon(Icons.sort),
            onSelected: (OrderBy result) {
              // Call loadMore with the selected order
              loadMore(orderBy: result);
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<OrderBy>>[
              PopupMenuItem<OrderBy>(
                value: OrderBy.lastplay,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('最后播放时间'),
                    if (_orderBy == OrderBy.lastplay)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
              PopupMenuItem<OrderBy>(
                value: OrderBy.playcnt,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('播放次数'),
                    if (_orderBy == OrderBy.playcnt)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
              PopupMenuItem<OrderBy>(
                value: OrderBy.playtime,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('总播放时长'),
                    if (_orderBy == OrderBy.playtime)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: hisList.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('暂无本地历史记录'),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<Widget>(
                          builder: (_) => const CloudHistoryScreen()),
                    ),
                    child: const Text('去云端看看'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              scrollCacheExtent: ScrollCacheExtent.pixels(10000),
              itemCount: hisList.length,
              itemBuilder: (context, index) => hisListTileView(index),
            ),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  loadMore({OrderBy? orderBy}) async {
    _orderBy = orderBy ?? _orderBy;
    final detail = await DatabaseManager.getPlayHistory(
      orderBy: _orderBy == OrderBy.playcnt
          ? 'play_count DESC'
          : _orderBy == OrderBy.lastplay
              ? 'last_played DESC'
              : 'total_play_time DESC',
    );
    if (!mounted) return;
    setState(() {
      hisList.clear(); // Clear the list before adding new items
      hisList.addAll(detail);
    });
  }

  hisListTileView(int index) {
    String duration, totalTime;
    {
      int min = (hisList[index].duration ?? 0) ~/ 60;
      int sec = (hisList[index].duration ?? 0) % 60;
      duration = "$min:${sec.toString().padLeft(2, '0')}";
    }

    {
      int hour = hisList[index].totalPlayTime ~/ (3600);
      int min = hisList[index].totalPlayTime % 3600 ~/ 60;
      int sec = hisList[index].totalPlayTime % 3600 % 60;
      if (hour != 0) {
        totalTime =
            "$hour:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}";
      } else {
        totalTime = "$min:${sec.toString().padLeft(2, '0')}";
      }
    }
    return TrackTile(
      key: Key(hisList[index].bvid),
      pic: hisList[index].artUri,
      title: hisList[index].title ?? "?",
      author: hisList[index].artist ?? "?",
      view: time(hisList[index].lastPlayed * 1000),
      len: duration,
      time: '累计 $totalTime',
      playcnt: '共${hisList[index].playCount}次',
      onTap: () =>
          AudioService.instance.then((x) => x.playByBvid(hisList[index].bvid)),
    );
  }
}
