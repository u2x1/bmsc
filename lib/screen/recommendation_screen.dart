import 'package:flutter/rendering.dart';
import 'dart:convert';
import 'dart:math';

import 'package:bmsc/component/playing_card.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/meta.dart';
import '../util/logger.dart';

import '../service/shared_preferences_service.dart';

class RecommendationScreen extends StatefulWidget {
  const RecommendationScreen({super.key});

  @override
  State<RecommendationScreen> createState() => _RecommendationScreenState();
}

class _RecommendationScreenState extends State<RecommendationScreen> {
  final _logger = LoggerUtils.getLogger('RecommendationScreen');
  List<Meta> recommendations = [];
  bool isLoading = true;
  String? defaultFolderName;

  @override
  void initState() {
    super.initState();
    _loadRecommendations();
    _loadDefaultFolderName();
  }

  Future<void> _loadDefaultFolderName() async {
    final folder = await SharedPreferencesService.getDefaultFavFolder();
    if (mounted && folder != null) {
      setState(() {
        defaultFolderName = folder.$2;
      });
    }
  }

  Future<void> _showFolderSelectionDialog() async {
    final bs = await BilibiliService.instance;
    final favs = (await bs.getFavs(bs.myInfo?.mid ?? 0)) ?? [];
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择默认收藏夹'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            scrollCacheExtent: ScrollCacheExtent.pixels(10000),
            shrinkWrap: true,
            itemCount: favs.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(favs[index].title),
              subtitle: Text('${favs[index].mediaCount} 个视频'),
              onTap: () async {
                await SharedPreferencesService.setDefaultFavFolder(
                    favs[index].id, favs[index].title);

                if (context.mounted) {
                  setState(() => defaultFolderName = favs[index].title);
                  Navigator.of(context).pop();
                  _loadRecommendations();
                }
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadRecommendations({bool force = false}) async {
    _logger.info('Loading recommendations (force: $force)');
    setState(() => isLoading = true);

    final defaultFolder = await SharedPreferencesService.getDefaultFavFolder();
    if (defaultFolder == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先设置默认收藏夹')),
        );
      }
      setState(() => isLoading = false);
      return;
    }

    final recs = await BilibiliService.instance
        .then((x) => x.getDailyRecommendations(force: force));
    if (mounted) {
      if (recs != null) {
        _logger.info('Loaded ${recs.length} recommendations');
      } else {
        _logger.warning('Failed to load recommendations');
      }
      setState(() {
        recommendations = recs ?? [];
        isLoading = false;
      });
    }
  }

  Future<void> _regenerateRecommendation(int index) async {
    _logger.info('Regenerating recommendation at index $index');
    final defaultFolder = await SharedPreferencesService.getDefaultFavFolder();
    if (defaultFolder == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先设置默认收藏夹')),
        );
      }
      return;
    }

    // 获取收藏夹中的视频
    final favVideos = await BilibiliService.instance
        .then((x) => x.getFavMetas(defaultFolder.$1));
    if (favVideos == null || favVideos.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('收藏夹为空')),
        );
      }
      return;
    }

    // 随机选择一个视频
    final selectedVideo = favVideos[Random().nextInt(favVideos.length)];
    _logger.info('Selected video for recommendation: ${selectedVideo.bvid}');

    // 获取相关推荐
    final relatedVideos = await BilibiliService.instance
        .then((x) => x.getRecommendations([selectedVideo]));
    if (relatedVideos == null || relatedVideos.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取推荐视频')),
        );
      }
      return;
    }

    // 更新推荐列表中的这一项
    setState(() {
      recommendations[index] = relatedVideos.first;
    });

    // 更新缓存
    final prefs = await SharedPreferencesService.instance;
    await prefs.setString('daily_recommendations',
        jsonEncode(recommendations.map((v) => v.toJson()).toList()));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已更新推荐')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('每日推荐'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.folder_outlined),
            label: Text(
              defaultFolderName ?? '选择收藏夹',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            onPressed: _showFolderSelectionDialog,
          ),
          IconButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('重新生成'),
                  content: const Text('这将清空当前的推荐列表并生成新的推荐。确定要继续吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        await _loadRecommendations(force: true);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : recommendations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.music_note,
                          size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text(
                        '暂无推荐',
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                  itemCount: recommendations.length,
                  itemBuilder: (context, index) {
                    final video = recommendations[index];
                    return InkWell(
                      onLongPress: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.refresh),
                                  title: const Text('重新推荐'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _regenerateRecommendation(index);
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.playlist_add),
                                  title: const Text('添加到播放列表'),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    try {
                                      await AudioService.instance.then(
                                          (x) => x.appendPlaylist(video.bvid));
                                    } catch (e) {
                                      await AudioService.instance.then((x) =>
                                          x.appendCachedPlaylist(video.bvid));
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      child: TrackTile(
                        key: Key(video.bvid),
                        pic: video.artUri,
                        title: video.title,
                        author: video.artist,
                        len:
                            '${video.duration ~/ 60}:${(video.duration % 60).toString().padLeft(2, '0')}',
                        onTap: () {
                          AudioService.instance.then((x) => x.playByBvids(
                              recommendations.map((v) => v.bvid).toList(),
                              index: index));
                        },
                        onAddToPlaylistButtonPressed: () async {
                          await AudioService.instance
                              .then((x) => x.appendPlaylist(video.bvid));
                        },
                      ),
                    );
                  },
                ),
      bottomNavigationBar: const PlayingCard(),
    );
  }
}
