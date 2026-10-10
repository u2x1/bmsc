import 'package:flutter/rendering.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bmsc/component/playing_card.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/section_habit_service.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../model/fav.dart';
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
  bool _isLoadingLock = false;
  bool _noDefaultFolder = false;
  int? defaultFolderId;
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
        defaultFolderId = folder.$1;
        defaultFolderName = folder.$2;
      });
    }
  }

  Future<void> _showFolderSelectionDialog() async {
    await showDialog(
      context: context,
      builder: (context) => _FolderPickerDialog(
        selectedId: defaultFolderId,
        onSelected: (fav) async {
          await SharedPreferencesService.setDefaultFavFolder(
              fav.id, fav.title);
          if (!mounted) return;
          setState(() {
            defaultFolderId = fav.id;
            defaultFolderName = fav.title;
          });
          // 切换收藏夹后必须强制重新生成，否则会显示上一个收藏夹
          // 当天已缓存的推荐
          _loadRecommendations(force: true);
        },
      ),
    );
  }

  Future<void> _loadRecommendations({bool force = false}) async {
    if (_isLoadingLock) return;
    _isLoadingLock = true;
    try {
      _logger.info('Loading recommendations (force: $force)');
      setState(() => isLoading = true);

      final defaultFolder =
          await SharedPreferencesService.getDefaultFavFolder();
      if (defaultFolder == null) {
        if (mounted) {
          setState(() {
            recommendations = [];
            _noDefaultFolder = true;
            isLoading = false;
          });
        }
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
          if (recs != null) {
            recommendations = recs;
          }
          _noDefaultFolder = false;
          isLoading = false;
        });
      }
    } finally {
      _isLoadingLock = false;
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

    // 获取收藏夹中的视频（优先本地缓存）
    var favVideos = await DatabaseManager.getCachedFavMetas(defaultFolder.$1);
    if (favVideos.isEmpty) {
      favVideos = await BilibiliService.instance
              .then((x) => x.getFavMetas(defaultFolder.$1)) ??
          [];
    }
    if (!mounted) return;

    // 排除当前列表已有的视频（含被替换的原项），避免重复推荐
    final existingBvids = recommendations.map((v) => v.bvid).toSet();
    final candidates =
        favVideos.where((v) => !existingBvids.contains(v.bvid)).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('收藏夹为空或没有更多可推荐的视频')),
      );
      return;
    }

    // 随机选择一个视频
    final selectedVideo = candidates[Random().nextInt(candidates.length)];
    _logger.info('Selected video for recommendation: ${selectedVideo.bvid}');

    // 获取相关推荐
    final relatedVideos = await BilibiliService.instance
        .then((x) => x.getRecommendations([selectedVideo]));
    final newVideos = (relatedVideos ?? [])
        .where((v) => !existingBvids.contains(v.bvid))
        .toList();
    if (!mounted) return;
    if (newVideos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法获取推荐视频')),
      );
      return;
    }

    // 更新推荐列表中的这一项
    setState(() {
      recommendations[index] = newVideos.first;
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
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                defaultFolderName ?? '选择收藏夹',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
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
      body: Column(
        children: [
          if (isLoading && recommendations.isNotEmpty)
            const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadRecommendations(force: true),
              child: isLoading && recommendations.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : recommendations.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          scrollCacheExtent:
                              ScrollCacheExtent.pixels(10000),
                          physics: const AlwaysScrollableScrollPhysics(),
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
                                          leading:
                                              const Icon(Icons.playlist_add),
                                          title: const Text('添加到播放列表'),
                                          onTap: () async {
                                            Navigator.pop(context);
                                            try {
                                              await AudioService.instance.then(
                                                  (x) => x.appendPlaylist(
                                                      video.bvid));
                                            } catch (e) {
                                              await AudioService.instance.then(
                                                  (x) => x.appendCachedPlaylist(
                                                      video.bvid));
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
                                  // 习惯学习：主页「每日推荐」板块播放来源
                                  unawaited(
                                      SectionHabitService.recordPlaySource(
                                          kHomeSectionDaily));
                                  AudioService.instance.then((x) =>
                                      x.playByBvids(
                                          recommendations
                                              .map((v) => v.bvid)
                                              .toList(),
                                          index: index));
                                },
                                onAddToPlaylistButtonPressed: () async {
                                  try {
                                    await AudioService.instance.then(
                                        (x) => x.appendPlaylist(video.bvid));
                                  } catch (e) {
                                    await AudioService.instance.then((x) =>
                                        x.appendCachedPlaylist(video.bvid));
                                  }
                                },
                              ),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  Widget _buildEmptyState() {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: constraints.maxHeight,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _noDefaultFolder
                      ? Icons.folder_off_outlined
                      : Icons.music_note,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  _noDefaultFolder ? '尚未设置默认收藏夹' : '暂无推荐',
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
                if (_noDefaultFolder) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _showFolderSelectionDialog,
                    child: const Text('去设置'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 默认收藏夹选择对话框：立即弹出并显示加载态（原实现先拉取再弹窗，
/// 接口慢/失败时表现为空白列表，像是「没有任何收藏夹可选」），
/// 并区分未登录 / 加载失败（可重试）/ 暂无收藏夹三种状态。
class _FolderPickerDialog extends StatefulWidget {
  final int? selectedId;
  final ValueChanged<Fav> onSelected;

  const _FolderPickerDialog({this.selectedId, required this.onSelected});

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  bool _loading = true;
  bool _needLogin = false;
  String? _error;
  List<Fav> _favs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _needLogin = false;
      _error = null;
    });
    try {
      final bs = await BilibiliService.instance;
      final mid = bs.myInfo?.mid ?? 0;
      if (mid == 0 || bs.sessionExpired.value) {
        if (mounted) {
          setState(() {
            _loading = false;
            _needLogin = true;
          });
        }
        return;
      }
      // 网络失败时 getFavs 内部会回退到本地缓存
      final favs = (await bs.getFavs(mid)) ?? [];
      if (!mounted) return;
      setState(() {
        _favs = favs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择默认收藏夹'),
      content: SizedBox(
        width: double.maxFinite,
        child: _buildContent(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_needLogin) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('请先登录后再选择收藏夹'),
      );
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载收藏夹失败\n$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      );
    }
    if (_favs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('暂无收藏夹'),
      );
    }
    return ListView.builder(
      scrollCacheExtent: ScrollCacheExtent.pixels(10000),
      shrinkWrap: true,
      itemCount: _favs.length,
      itemBuilder: (context, index) {
        final fav = _favs[index];
        return ListTile(
          selected: fav.id == widget.selectedId,
          title: Text(fav.title),
          subtitle: Text('${fav.mediaCount} 个视频'),
          onTap: () {
            widget.onSelected(fav);
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}
