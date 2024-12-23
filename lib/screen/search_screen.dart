import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/util/shared_preferences_service.dart';
import 'package:bmsc/util/url.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../globals.dart' as globals;
import '../model/search.dart';
import '../util/string.dart';
import '../component/playing_card.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:async';
import 'package:flutter/services.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<StatefulWidget> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Result> vidList = [];
  final _focusNode = FocusNode();
  final fieldTextController = TextEditingController();
  bool _hasMore = false;
  int _curPage = 1;
  String _curSearch = "";
  List<String> _searchHistory = [];
  Timer? _debounceTimer;
  List<String> _suggestions = [];
  String? _clipboardUrl;

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
    _checkClipboard();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferencesService.instance;
    setState(() {
      _searchHistory = prefs.getStringList('search_history') ?? [];
    });
  }

  Future<void> _saveSearchHistory(String query) async {
    if (query.trim().isEmpty) return;

    final prefs = await SharedPreferencesService.instance;
    _searchHistory.remove(query);
    _searchHistory.insert(0, query);

    if (_searchHistory.length > 10) {
      _searchHistory = _searchHistory.sublist(0, 10);
    }

    await prefs.setStringList('search_history', _searchHistory);
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    if (value.isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      final suggestions = await globals.api.getSearchSuggestions(value);
      if (!mounted) return;
      setState(() {
        _suggestions = suggestions;
      });
    });
  }

  Future<void> _checkClipboard() async {
    if (!(await SharedPreferencesService.getReadFromClipboard())) return;
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text == null) return;

    final text = clipboardData!.text!;
    final url = extractBiliUrl(text);
    if (url != null) {
      setState(() {
        _clipboardUrl = url;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          focusNode: _focusNode,
          controller: fieldTextController,
          decoration: const InputDecoration(
            hintText: '搜索歌曲...',
            border: InputBorder.none,
          ),
          onChanged: _onSearchChanged,
          onSubmitted: onSearching,
        ),
      ),
      body: (fieldTextController.text.isNotEmpty &&
              _suggestions.isNotEmpty &&
              _focusNode.hasFocus)
          ? _buildSuggestions()
          : _focusNode.hasFocus
              ? _buildSearchHistory()
              : (vidList.isEmpty
                  ? const Center(child: Text('输入关键词开始搜索'))
                  : _listView()),
      bottomNavigationBar: StreamBuilder<SequenceState?>(
        stream: globals.api.player.sequenceStateStream,
        builder: (_, snapshot) {
          final src = snapshot.data?.sequence;
          return (src == null || src.isEmpty)
              ? const SizedBox()
              : const PlayingCard();
        },
      ),
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
        cacheExtent: 10000,
        physics: const ClampingScrollPhysics(),
        itemCount: vidList.length,
        itemBuilder: (BuildContext context, int index) {
          return _listItemView(vidList[index]);
        },
      ),
    );
  }

  Widget _listItemView(Result vid) {
    final duration =
        vid.duration.split(':').map((x) => x.padLeft(2, '0')).join(':');
    return TrackTile(
      key: Key(vid.bvid),
      pic: vid.pic.startsWith('http')
          ? vid.pic
          : vid.pic.startsWith('//')
              ? 'https:${vid.pic}'
              : 'https://$vid.pic',
      title: stripHtmlIfNeeded(vid.title),
      author: vid.author,
      len: duration,
      view: unit(vid.play),
      onTap: () => globals.api.playByBvid(vid.bvid),
      onAddToPlaylistButtonPressed: () => globals.api.appendPlaylist(vid.bvid,
          insertIndex: globals.api.playlist.length == 0
              ? 0
              : globals.api.player.currentIndex! + 1),
      onLongPress: () async {
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('选择操作'),
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
                            builder: (context) =>
                                UserDetailScreen(mid: vid.mid)));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchHistory() {
    return ListView.builder(
      itemCount: _searchHistory.length + (_clipboardUrl != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (_clipboardUrl != null && index == 0) {
          return ListTile(
            leading: const Icon(Icons.link),
            title: Text(_clipboardUrl!),
            subtitle: const Text('从剪贴板'),
            onTap: () {
              _focusNode.unfocus();
              fieldTextController.text = _clipboardUrl!;
              onSearching(null, fromClipboard: true);
            },
          );
        }
        index = _clipboardUrl != null ? index - 1 : index;
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(_searchHistory[index]),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              setState(() {
                _searchHistory.removeAt(index);
              });
              final prefs = await SharedPreferencesService.instance;
              await prefs.setStringList('search_history', _searchHistory);
            },
          ),
          onTap: () {
            _focusNode.unfocus();
            fieldTextController.text = _searchHistory[index];
            onSearching(_searchHistory[index]);
          },
        );
      },
    );
  }

  Widget _buildSuggestions() {
    return ListView.builder(
      itemCount: _suggestions.length,
      itemBuilder: (context, index) {
        return ListTile(
          leading: const Icon(Icons.search),
          title: Text(_suggestions[index]),
          onTap: () {
            _focusNode.unfocus();
            fieldTextController.text = _suggestions[index];
            onSearching(_suggestions[index]);
          },
        );
      },
    );
  }

  void onSearching(String? value, {bool fromClipboard = false}) async {
    if (fromClipboard == true && _clipboardUrl != null) {
      final vidDetail = await getVidDetailFromUrl(_clipboardUrl!);
      if (vidDetail != null) {
        setState(() {
          _hasMore = false;
          _curPage = 1;
          vidList = [
            Result(
              author: vidDetail.owner.name,
              mid: vidDetail.owner.mid,
              typeid: "",
              typename: "",
              aid: vidDetail.aid,
              bvid: vidDetail.bvid,
              title: vidDetail.title,
              pic: vidDetail.pic,
              play: vidDetail.stat.view,
              duration: duration(vidDetail.duration),
            )
          ];
        });
        return;
      }
    }
    if (value == null) return;
    await _saveSearchHistory(value);
    setState(() {
      _curSearch = value;
      _hasMore = true;
      _curPage = 1;
      vidList.clear();
    });
    await loadMore();
  }

  Future<void> loadMore() async {
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
