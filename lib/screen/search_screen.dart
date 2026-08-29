import 'package:flutter/rendering.dart';
import 'package:bmsc/component/download_parts_dialog.dart';
import 'package:bmsc/component/excluded_parts_dialog.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/url.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/search.dart';
import '../util/string.dart';
import '../component/playing_card.dart';
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
  bool _isLoading = false;
  bool _searchFailed = false;
  int _searchToken = 0;
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
      final suggestions =
          await (await BilibiliService.instance).getSearchSuggestions(value);
      if (!mounted) return;
      setState(() {
        _suggestions = suggestions ?? [];
      });
    });
  }

  Future<void> _checkClipboard() async {
    if (!(await SharedPreferencesService.getReadFromClipboard())) {
      final has = await Clipboard.hasStrings();
      if (has) {
        setState(() {
          _clipboardUrl = "";
        });
      }
      return;
    }
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
              : _buildSearchResult(),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  Widget _buildSearchResult() {
    if (vidList.isEmpty) {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_searchFailed) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('加载失败，请检查网络后重试'),
              const SizedBox(height: 8),
              FilledButton(onPressed: loadMore, child: const Text('重试')),
            ],
          ),
        );
      }
      return Center(
          child: Text(_curSearch.isEmpty ? '输入关键词开始搜索' : '未找到相关结果'));
    }
    return _listView();
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
        scrollCacheExtent: ScrollCacheExtent.pixels(10000),
        physics: const ClampingScrollPhysics(),
        itemCount: vidList.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == vidList.length) {
            if (_isLoading) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (_searchFailed) {
              return Center(
                child: TextButton(
                  onPressed: loadMore,
                  child: const Text('加载失败，点击重试'),
                ),
              );
            }
            return const SizedBox.shrink();
          }
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
      onTap: () => AudioService.instance.then((x) => x.playByBvid(vid.bvid)),
      onAddToPlaylistButtonPressed: () => AudioService.instance.then((x) =>
          x.appendPlaylist(vid.bvid,
              insertIndex:
                  x.playlist.length == 0
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
                            builder: (context) =>
                                UserDetailScreen(mid: vid.mid)));
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
                            builder: (context) =>
                                CommentScreen(aid: vid.aid.toString())));
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
                        bvid: vid.bvid,
                        title: vid.title,
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
                        bvid: vid.bvid,
                        title: vid.title,
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

  Widget _buildSearchHistory() {
    return ListView.builder(
      itemCount: _searchHistory.length + (_clipboardUrl != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (_clipboardUrl != null && index == 0) {
          return ListTile(
            leading: const Icon(Icons.link),
            title: Text(_clipboardUrl!.isEmpty ? '从剪贴板' : _clipboardUrl!),
            subtitle: _clipboardUrl!.isEmpty ? null : const Text('从剪贴板'),
            onTap: () async {
              if (_clipboardUrl!.isEmpty) {
                _clipboardUrl =
                    (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                if (_clipboardUrl == null || _clipboardUrl!.isEmpty) return;
                final vid = extractBiliUrl(_clipboardUrl!);
                if (vid == null) {
                  setState(() {
                    _clipboardUrl = "未找到视频";
                  });
                  return;
                } else {
                  setState(() {
                    _clipboardUrl = vid;
                  });
                  fieldTextController.text = vid;
                }
              }
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
    _searchToken++;
    if (fromClipboard == true && _clipboardUrl != null) {
      final vidDetail = await getVidDetailFromUrl(_clipboardUrl!);
      if (vidDetail != null) {
        setState(() {
          _hasMore = false;
          _searchFailed = false;
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
      _searchFailed = false;
      _curPage = 1;
      vidList.clear();
    });
    await loadMore();
  }

  Future<void> loadMore() async {
    if (!_hasMore || _isLoading) {
      return;
    }
    final token = ++_searchToken;
    final keyword = _curSearch;
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final ret =
          await (await BilibiliService.instance).search(keyword, _curPage);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searchFailed = ret == null;
        if (ret != null) {
          _hasMore = ret.page < ret.numPages;
          _curPage++;
          vidList.addAll(ret.result);
        }
      });
    } catch (_) {
      if (mounted && token == _searchToken) {
        setState(() => _searchFailed = true);
      }
    } finally {
      if (token == _searchToken) {
        _isLoading = false;
      }
    }
  }
}
