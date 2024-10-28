import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../globals.dart' as globals;
import '../model/search.dart';
import '../util/string.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<StatefulWidget> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Result> vidList = [];
  final fieldTextController = TextEditingController();
  bool _hasMore = false;
  int _curPage = 1;
  String _curSearch = "";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: fieldTextController,
          decoration: const InputDecoration(
            hintText: '搜索歌曲...',
            border: InputBorder.none,
          ),
          onSubmitted: onSearching,
        ),
      ),
      body: vidList.isEmpty
          ? const Center(child: Text('输入关键词开始搜索'))
          : _listView(),
    );
  }

  Widget _listView() {
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
        physics: const ClampingScrollPhysics(),
        itemCount: vidList.length,
        itemBuilder: (BuildContext context, int index) {
          return _listItemView(vidList[index]);
        },
      ),
    );
  }

  Widget _listItemView(Result vid) {
    final duration = vid.duration.split(':').map((x) => x.padLeft(2, '0')).join(':');
    return TrackTile(
      key: Key(vid.bvid),
      pic: 'https:${vid.pic}',
      title: stripHtmlIfNeeded(vid.title),
      author: vid.author,
      len: duration,
      view: unit(vid.play),
      onTap: () => globals.api.playByBvid(vid.bvid),
    );
  }

  void onSearching(String value) async {
    _curSearch = value;
    _hasMore = true;
    _curPage = 1;
    vidList.clear();
    loadMore();
  }

  void loadMore() async {
    if (!_hasMore) {
      return;
    }
    final ret = await globals.api.search(_curSearch, _curPage);
    if (ret != null) {
      setState(() {
        _hasMore = ret.page < ret.numPages;
        _curPage++;
        vidList.addAll(ret.result);
      });
    }
  }
}
