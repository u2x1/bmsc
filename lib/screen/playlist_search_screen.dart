import 'package:flutter/rendering.dart';
import 'dart:io';
import 'package:bmsc/api/music_provider.dart';
import 'package:bmsc/component/select_favlist_dialog.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../model/search.dart';
import '../util/string.dart';
import 'dart:math';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../util/logger.dart';

class PlaylistSearchScreen extends StatefulWidget {
  const PlaylistSearchScreen({super.key});

  @override
  State<StatefulWidget> createState() => _PlaylistSearchScreenState();
}

class _PlaylistSearchScreenState extends State<PlaylistSearchScreen> {
  final _textController = TextEditingController();
  final _scrollController = AutoScrollController();
  List<Map<String, dynamic>> results = [];
  bool isSearching = false;
  bool isSaving = false;
  bool autoscroll = true;
  bool isReverse = true;
  bool isSearchPaused = false;
  bool isSavingPaused = false;

  late BuildContext _context;

  int totalTracks = 0;
  int processedTracks = 0;
  int processedFavorites = 0;
  int favid = 0;

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _notificationsInitialized = false;

  final _logger = LoggerUtils.getLogger('PlaylistSearchScreen');

  @override
  void initState() {
    super.initState();
    SharedPreferencesService.getPlaylistSearchResult().then((value) {
      if (value == null) return;
      setState(() {
        results = value['result'];
        favid = value['favid'];
        _textController.text = value['text'];
        totalTracks = results.length;
        processedTracks = results.where((r) => r['bvid'] != null).length;
        processedFavorites =
            results.where((r) => r['favAddStatus'] == true).length;
        isSearchPaused = processedTracks != totalTracks;
        isSearching = processedTracks != 0;
        isSavingPaused = (processedFavorites != totalTracks);
        isSaving = processedFavorites != 0;
      });
    });
  }

  Future<void> _initializeNotifications() async {
    if (_notificationsInitialized) return;

    const initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettingsIOS = DarwinInitializationSettings();
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(settings: initializationSettings);
    _notificationsInitialized = true;
  }

  Future<bool> _onWillPop() async {
    // Check if there are unsaved results
    final hasUnsavedResults =
        results.any((result) => processedFavorites != totalTracks);

    if (!hasUnsavedResults) {
      return true;
    }

    // Show confirmation dialog
    final shouldPop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认退出'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('还有未收藏的搜索结果，确定要退出吗？'),
            SizedBox(height: 12), // Add some spacing
            Text(
              '提示：搜索和收藏是两个独立的过程，'
              '你应该在搜索结束后将结果保存到云收藏夹中。',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context, true);
              SharedPreferencesService.savePlaylistSearchResult(
                  results, _textController.text, favid);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    return shouldPop ?? false;
  }

  void _toggleSearchPause() {
    setState(() {
      isSearchPaused = !isSearchPaused;
      if (!isSearchPaused) {
        _search();
      }
    });
  }

  void _toggleSavingPause() {
    setState(() {
      isSavingPaused = !isSavingPaused;
      if (!isSavingPaused) {
        _save();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _context = context;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        final bool shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('歌单导入'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: TextField(
                controller: _textController,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText:
                      '[示例1] 歌名 \$ 作者 \$ 时长(秒)\n夏日已所剩无几 \$ 泠鸢yousa \$ 271\n[示例2] 平台:歌单ID\nnetease:1234567890\ntencent:1207922987\nkugou:gcid_3z18k3yjxz3z089',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.all(8),
                ),
                style: TextStyle(fontSize: 12),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: isSearching ? _toggleSearchPause : null,
                  child: Text(isSearchPaused ? '继续搜索' : '暂停搜索'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: (isSearching && !isSearchPaused) ||
                          (isSaving && !isSavingPaused)
                      ? null
                      : _processPlaylistSearch,
                  child: Text('开始搜索'),
                ),
                Row(
                  children: [
                    Checkbox(
                      value: isReverse,
                      onChanged: (isSearching)
                          ? null
                          : (bool? value) {
                              setState(() {
                                isReverse = value ?? false;
                              });
                            },
                    ),
                    const Text('倒序'),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: '此选项仅控制搜索顺序，不影响收藏顺序。\n'
                          '收藏顺序一定是自上而下的。\n'
                          '选项默认开启，这样收藏结束时\n收藏夹视频顺序便会与歌单歌曲顺序相同。',
                      triggerMode: TooltipTriggerMode.tap,
                      showDuration: Duration(seconds: 10),
                      child: const Icon(Icons.help_outline, size: 18),
                    ),
                  ],
                ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  if (results.isNotEmpty)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: isSearching && !isSearchPaused
                              ? null
                              : isSaving
                                  ? () => _toggleSavingPause()
                                  : () async {
                                      final folder = await showDialog<Fav>(
                                        context: context,
                                        builder: (context) =>
                                            SelectFavlistDialog(),
                                      );
                                      if (folder == null || !context.mounted) {
                                        return;
                                      }
                                      await _processPlaylistSave(
                                          folder, context);
                                    },
                          child: isSaving
                              ? isSavingPaused
                                  ? const Text('继续收藏')
                                  : const Text('暂停收藏')
                              : const Text('开始收藏'),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            Checkbox(
                              value: autoscroll,
                              onChanged: (bool? value) {
                                setState(() {
                                  autoscroll = value ?? true;
                                });
                              },
                            ),
                            const Text('自动滚动'),
                          ],
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  if (isSearching && totalTracks > 0)
                    LinearProgressIndicator(
                      value: processedTracks / totalTracks,
                    ),
                  if (isSaving && totalTracks > 0)
                    LinearProgressIndicator(
                      value: processedFavorites / totalTracks,
                      color: Colors.green,
                    ),
                  Expanded(
                    child: ListView.builder(
                      scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                      controller: _scrollController,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        return AutoScrollTag(
                          key: ValueKey(index),
                          index: index,
                          controller: _scrollController,
                          child: ListTile(
                            title: Text(
                                "${result['artist']} - ${result['track']}",
                                style: TextStyle(fontSize: 14)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('result: ${result['title'] ?? '未找到'}',
                                    style: TextStyle(fontSize: 12)),
                                if (result['bvid'] != null)
                                  Text(
                                      '(∑: ${result['score']}) (|Δ|: ${result['durationDiff']}s) (ε: ${result['play']}) (§: ${result['typename']})',
                                      style: TextStyle(fontSize: 12)),
                                if (result['favAddStatus'] != null)
                                  Text(
                                    result['favAddStatus']!
                                        ? '已添加到收藏夹'
                                        : '添加失败',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: result['favAddStatus']!
                                          ? Colors.green
                                          : Colors.red,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.search),
                                      onPressed: isSearching && !isSearchPaused
                                          ? null
                                          : () async {
                                              FocusManager.instance.primaryFocus
                                                  ?.unfocus();
                                              final track = result['track'];
                                              final artist = result['artist'];
                                              final duration =
                                                  result['duration'];
                                              final trackResults =
                                                  await _searchTracks(
                                                      track, artist, duration);
                                              if (trackResults.isEmpty) {
                                                showErrorSnackBar("搜索失败");
                                              }

                                              if (!context.mounted) return;

                                              final selectedVideo =
                                                  await showDialog<int?>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) {
                                                  return AlertDialog(
                                                    title: Text('选择视频'),
                                                    content: SizedBox(
                                                      width: double.maxFinite,
                                                      height: 400,
                                                      child: ListView.builder(
                                                        scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                                                        shrinkWrap: true,
                                                        itemCount:
                                                            trackResults.length,
                                                        itemBuilder:
                                                            (context, i) {
                                                          final video =
                                                              trackResults[i];

                                                          return ListTile(
                                                            title: Text(
                                                                stripHtmlIfNeeded(
                                                                    video[
                                                                        'title']),
                                                                style: TextStyle(
                                                                    fontSize:
                                                                        12)),
                                                            subtitle: Text(
                                                                '(∑: ${video['score']}) (|Δ|: ${video['durationDiff']}s) (ε: ${video['play']}) (§: ${video['typename']})',
                                                                style: TextStyle(
                                                                    fontSize:
                                                                        12)),
                                                            onTap: () {
                                                              Navigator.pop(
                                                                  context, i);
                                                            },
                                                          );
                                                        },
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () {
                                                          Navigator.pop(
                                                              context);
                                                        },
                                                        child: Text('取消'),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              );
                                              if (selectedVideo == null) return;
                                              setState(() {
                                                results[index] =
                                                    trackResults[selectedVideo];
                                              });
                                            },
                                    ),
                                    if (result['bvid'] != null)
                                      const Icon(Icons.check,
                                          color: Colors.green)
                                    else
                                      const Icon(Icons.close,
                                          color: Colors.red),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showErrorSnackBar(String message) {
    _logger.warning('Error: $message');
    if (_context.mounted) {
      ScaffoldMessenger.of(_context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red[700],
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: '关闭',
            textColor: Colors.white,
            onPressed: () {
              ScaffoldMessenger.of(_context).hideCurrentSnackBar();
            },
          ),
        ),
      );
    }
  }

  Future<void> _processPlaylistSave(Fav folder, BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('确认'),
          content: Text('确定要添加 ${results.length} 首曲目到 ${folder.title} 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    favid = folder.id;
    setState(() {
      isSaving = true;
      isSavingPaused = false;
      processedFavorites = 0;
    });

    await _save();
  }

  Future<void> _processPlaylistSearch() async {
    _logger.info('Starting playlist processing');
    if (Platform.isAndroid) {
      Permission.notification.request();
    }
    await _initializeNotifications();

    if (totalTracks != 0) {
      if (!mounted) return;
      final shouldBreak = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新搜索'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已有搜索结果，确定要重新搜索吗？'),
              SizedBox(height: 12), // Add some spacing
              Text(
                '当前的搜索结果将被清空。',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (shouldBreak == true) return;
    }

    final text = _textController.text;
    final neteaseRegex = RegExp(r'playlist\?.*?id=(\d+)');
    final match = neteaseRegex.firstMatch(text);

    if (match != null) {
      final playlistId = match.group(1)!;
      _textController.text = 'netease:$playlistId';
    }

    await flutterLocalNotificationsPlugin.show(
      id: 0,
      title: '歌单搜索',
      body: '准备处理...',
      notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
        'playlist_search',
        'Playlist Search',
        channelDescription: 'Notifications for playlist search progress',
        importance: Importance.high,
        priority: Priority.high,
        showProgress: true,
        onlyAlertOnce: true,
        playSound: false,
        ongoing: true,
        autoCancel: false,
      )),
    );

    setState(() {
      isSearching = true;
      isSaving = false;
      isSearchPaused = false;
      results = [];
      processedFavorites = 0;
      processedTracks = 0;
      totalTracks = 0;
    });

    List<Map<String, dynamic>> tracks = [];

    final lines = _textController.text.split('\n');
    _logger.info('Processing ${lines.length} input lines');

    for (final line in lines) {
      List<Map<String, dynamic>> appendTracks = [];
      if (line.startsWith('netease:')) {
        final playlistId = line.split(':')[1].trim();
        _logger.info('Fetching Netease playlist: $playlistId');
        final tracks =
            await MusicProvider.fetchNeteasePlaylistTracks(playlistId);
        if (tracks == null) {
          _logger.warning('Failed to fetch Netease playlist: $playlistId');
          showErrorSnackBar("获取歌单 netease:$playlistId 失败");
          continue;
        } else if (tracks.isEmpty) {
          showErrorSnackBar("查无歌单 netease:$playlistId");
          continue;
        }
        _logger.info('Found ${tracks.length} tracks in Netease playlist');
        appendTracks.addAll(tracks);
      } else if (line.startsWith('tencent:')) {
        final playlistId = line.split(':')[1].trim();
        final tracks =
            await MusicProvider.fetchTencentPlaylistTracks(playlistId);
        if (tracks == null) {
          showErrorSnackBar("获取歌单 tencent:$playlistId 失败");
          continue;
        } else if (tracks.isEmpty) {
          showErrorSnackBar("查无歌单 tencent:$playlistId");
          continue;
        }
        appendTracks.addAll(tracks);
      } else if (line.startsWith('kugou:')) {
        final playlistId = line.split(':')[1].trim();
        final tracks = await MusicProvider.fetchKuGouPlaylistTracks(playlistId);
        if (tracks == null) {
          showErrorSnackBar("获取歌单 kugou:$playlistId 失败");
          continue;
        } else if (tracks.isEmpty) {
          showErrorSnackBar("查无歌单 kugou:$playlistId");
          continue;
        }
        appendTracks.addAll(tracks);
      } else {
        final parts = line.split('\$').map((e) => e.trim()).toList();
        if (parts.length != 3) continue;
        appendTracks.add({
          'name': parts[0],
          'artist': parts[1],
          'duration': int.parse(parts[2]),
        });
      }
      tracks.addAll(appendTracks);
    }

    if (tracks.isEmpty) {
      showErrorSnackBar("输入错误");
      return;
    }

    _logger.info('Total tracks to process: ${tracks.length}');

    if (isReverse) {
      tracks = tracks.reversed.toList();
    }

    setState(() {
      results = tracks
          .map((track) => {
                'track': track['name'],
                'artist': track['artist'],
                'duration': track['duration'],
                'title': '等待搜索...', // "Waiting for search..."
              })
          .toList();
      totalTracks = tracks.length;
    });

    await _search();
  }

  Future<void> _search() async {
    for (; processedTracks < results.length;) {
      await flutterLocalNotificationsPlugin.show(
        id: 0,
        title: '歌单搜索',
        body: '处理中: $processedTracks/$totalTracks',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'playlist_search',
            'Playlist Search',
            channelDescription: 'Notifications for playlist search progress',
            importance: Importance.high,
            priority: Priority.high,
            ongoing: true,
            showProgress: true,
            maxProgress: totalTracks,
            progress: processedTracks,
            onlyAlertOnce: true,
            playSound: false,
          ),
        ),
      );
      if (isSearchPaused) {
        await flutterLocalNotificationsPlugin.show(
          id: 0,
          title: '歌单搜索',
          body: '已暂停: $processedTracks/${results.length}',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'playlist_search',
              'Playlist Search',
              channelDescription: 'Notifications for playlist search progress',
              importance: Importance.high,
              priority: Priority.high,
              ongoing: true,
              showProgress: true,
              maxProgress: results.length,
              progress: processedTracks,
              onlyAlertOnce: true,
              playSound: false,
            ),
          ),
        );
        return;
      }
      await Future.delayed(const Duration(milliseconds: 1200));
      final track = results[processedTracks];
      _logger.info(
          'Searching track ${processedTracks + 1}/${results.length}: ${track['track']} - ${track['artist']}');

      final result = await _searchTrack(
          track['track'], track['artist'], track['duration']);
      if (result == null) {
        _logger.warning('Search failed for track: ${track['track']}');
        showErrorSnackBar("搜索失败，已暂停");
        _toggleSearchPause();
        continue;
      }

      _logger.info(
          'Found match for "${track['track']}": ${result['title']} (score: ${result['score']})');

      setState(() {
        results[processedTracks] = result;
        processedTracks++;
      });

      if (autoscroll && !isSearchPaused) {
        _scrollController.scrollToIndex(processedTracks,
            preferPosition: AutoScrollPosition.middle);
      }
    }
    await flutterLocalNotificationsPlugin.show(
      id: 0,
      title: '歌单搜索',
      body: '处理完成: $totalTracks 首歌曲',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'playlist_search',
          'Playlist Search',
          channelDescription: 'Notifications for playlist search progress',
          importance: Importance.high,
          priority: Priority.high,
          onlyAlertOnce: true,
          playSound: false,
        ),
      ),
    );

    setState(() {
      isSearching = false;
    });

    _logger.info('Playlist processing completed');
  }

  Future<void> _save() async {
    for (; processedFavorites < results.length;) {
      await flutterLocalNotificationsPlugin.show(
        id: 1,
        title: '添加收藏',
        body: '处理中: $processedFavorites/${results.length}',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'favorite_progress',
            'Favorite Progress',
            channelDescription: 'Notifications for favorite progress',
            importance: Importance.high,
            priority: Priority.high,
            ongoing: true,
            showProgress: true,
            maxProgress: results.length,
            progress: processedFavorites,
            onlyAlertOnce: true,
            playSound: false,
          ),
        ),
      );
      if (isSavingPaused) {
        await flutterLocalNotificationsPlugin.show(
          id: 1,
          title: '添加收藏',
          body: '已暂停: $processedFavorites/${results.length}',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'favorite_progress',
              'Favorite Progress',
              channelDescription: 'Notifications for favorite progress',
              importance: Importance.high,
              priority: Priority.high,
              ongoing: true,
              showProgress: true,
              maxProgress: results.length,
              progress: processedFavorites,
              onlyAlertOnce: true,
              playSound: false,
            ),
          ),
        );
        return;
      }
      final track = results[processedFavorites];
      if (track['aid'] == null) {
        showErrorSnackBar("歌曲没有搜索结果，已暂停");
        _toggleSavingPause();
        continue;
      }
      final success =
          await BilibiliService.instance.then((x) => x.favoriteVideo(
                track['aid'],
                [favid],
                [],
              ));
      if (success == null) {
        showErrorSnackBar("收藏失败，已暂停");
        _toggleSavingPause();
        continue;
      }

      setState(() {
        results[processedFavorites]['favAddStatus'] = success;
        processedFavorites++;
      });

      if (autoscroll) {
        _scrollController.scrollToIndex(processedFavorites,
            preferPosition: AutoScrollPosition.middle);
      }

      await Future.delayed(const Duration(milliseconds: 1200));
    }

    // Show completion notification
    await flutterLocalNotificationsPlugin.show(
      id: 1,
      title: '添加收藏',
      body: '完成: 已添加 ${results.length} 首曲目到收藏夹',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'favorite_progress',
          'Favorite Progress',
          channelDescription: 'Notifications for favorite progress',
          importance: Importance.high,
          priority: Priority.high,
          onlyAlertOnce: true,
          playSound: false,
        ),
      ),
    );

    setState(() {
      isSaving = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${results.length} 首曲目到收藏夹'),
        ),
      );
    }
  }

  int _parseDuration(String duration) {
    final parts = duration.split(':');
    if (parts.length != 2) return 0;
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  static const _minCommonSubstringLength = 4;

  Set<String> allTypeNames = {};
  static const int inf = 999;

  final RegExp wordRegex = RegExp(r'([^a-zA-Z0-9_\u4e00-\u9fa5]+)');

  Future<List<Map<String, dynamic>>> _searchTracks(
      String track, String artist, int duration) async {
    final searchString = '$track - $artist';
    _logger.info('Searching for: $searchString (duration: ${duration}s)');

    final searchResult =
        await BilibiliService.instance.then((x) => x.search(searchString, 1));
    if (searchResult == null) {
      _logger.warning('Search API returned null for: $searchString');
      return [];
    }

    _logger.info('Found ${searchResult.result.length} initial results');

    List<Map<String, dynamic>> ret = [];

    final trackWords = track
        .toLowerCase()
        .split(wordRegex)
        .where((e) => e.isNotEmpty)
        .toList();
    final artistWords = artist
        .toLowerCase()
        .split(wordRegex)
        .where((e) => e.isNotEmpty)
        .toList();

    final searchWords = searchString
        .toLowerCase()
        .split(wordRegex)
        .where((e) => e.isNotEmpty)
        .toList();
    final searchWordsSet = searchWords.toSet();
    final searchChinese = RegExp(r'[\u4e00-\u9fa5]+')
        .allMatches(searchString)
        .map((m) => m.group(0)!)
        .join();

    int rankScore(Result video) {
      // 音Mad, 音乐现场, 翻唱, 科学科普, 运动综合
      const list = [26, 29, 31, 201, 238];
      if (list.contains(int.parse(video.typeid))) return -inf;

      final durationDiff = (_parseDuration(video.duration) - duration).abs();
      if (durationDiff > 3 * 60) return -inf;

      final result = stripHtmlIfNeeded(video.title);
      final resultWords = result
          .toLowerCase()
          .split(wordRegex)
          .where((e) => e.isNotEmpty)
          .toList();

      bool hasTrack = containsSubarrayKMP(resultWords, trackWords);
      bool hasArtist = containsSubarrayKMP(resultWords, artistWords);
      if (hasTrack && hasArtist) return inf;

      if (durationDiff > 20) return -inf;

      if (hasTrack || hasArtist) return 10;

      bool hasWordMatch =
          searchWordsSet.intersection(resultWords.toSet()).isNotEmpty;
      if (hasWordMatch) return 5;

      bool hasLongChineseCommonSubstring = false;
      final resultChinese = RegExp(r'[\u4e00-\u9fa5]+')
          .allMatches(result)
          .map((m) => m.group(0)!)
          .join();

      int maxLen = 0;

      final List<List<int>> dp = List.generate(
        searchChinese.length + 1,
        (_) => List.filled(resultChinese.length + 1, 0),
      );

      for (int i = 1; i <= searchChinese.length; i++) {
        for (int j = 1; j <= resultChinese.length; j++) {
          if (searchChinese[i - 1] == resultChinese[j - 1]) {
            dp[i][j] = dp[i - 1][j - 1] + 1;
            if (dp[i][j] > maxLen) {
              maxLen = dp[i][j];
              if (maxLen >= _minCommonSubstringLength) {
                hasLongChineseCommonSubstring = true;
                break;
              }
            }
          }
        }
        if (hasLongChineseCommonSubstring) break;
      }

      return 0;
    }

    for (final video in searchResult.result) {
      if (video.typeid == '') continue;

      int priority = switch (video.typeid) {
        '193' => 1, // MV
        '130' => 1, // 音乐综合
        '267' => 1, // 电台
        _ => 0,
      };

      int score = rankScore(video);
      // if (score == -inf) continue;
      int durationDiff = (_parseDuration(video.duration) - duration).abs();
      final videoPlayCountLog =
          video.play > 0 ? (log(video.play) / log(10)) : 0;
      score += priority * 1000 - durationDiff + (videoPlayCountLog * 5).round();
      ret.add({
        'track': track,
        'artist': artist,
        'duration': duration,
        'bvid': video.bvid,
        'aid': video.aid,
        'typename': video.typename,
        'typeid': video.typeid,
        'title': stripHtmlIfNeeded(video.title),
        'durationDiff': durationDiff,
        'play': videoPlayCountLog.round(),
        'score': score,
      });
    }

    _logger.info('Filtered to ${ret.length} relevant results');
    return ret;
  }

  Future<Map<String, dynamic>?> _searchTrack(
      String track, String artist, int duration) async {
    final tracks = await _searchTracks(track, artist, duration);
    if (tracks.isEmpty) return null;
    return tracks.reduce((a, b) => a['score'] > b['score'] ? a : b);
  }

  @override
  void dispose() {
    _textController.dispose();
    flutterLocalNotificationsPlugin.cancelAll();
    super.dispose();
  }
}
