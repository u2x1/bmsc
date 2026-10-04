import 'package:bmsc/component/download_parts_dialog.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/download_manager.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/model/fav.dart';
import '../component/track_tile.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/component/excluded_parts_dialog.dart';
import '../component/playing_card.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/util/logger.dart';

class FavDetailScreen extends StatefulWidget {
  final Fav fav;
  final bool isCollected;

  const FavDetailScreen({
    super.key,
    required this.fav,
    required this.isCollected,
  });

  @override
  State<StatefulWidget> createState() => _FavDetailScreenState();
}

class _FavDetailScreenState extends State<FavDetailScreen> {
  List<Meta> rawFavInfo = [];
  List<Meta> favInfo = [];
  bool isLoading = false;
  bool _loadError = false;
  Map<String, (List<int>, int, int)> _itemInfoCache = {};
  bool isSelectionMode = false;
  Set<String> selectedItems = {};
  static final _logger = LoggerUtils.getLogger('FavDetailScreen');

  bool isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  /// 缩略图网格模式（false = 曲目列表模式）。全局偏好，
  /// 所有收藏夹详情页共用
  bool _isGridView = false;
  static const _gridViewPrefKey = 'fav_detail_grid_view';

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _loadViewMode();
    _searchController.addListener(_filterFavInfos);
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferencesService.instance;
    final isGrid = prefs.getBool(_gridViewPrefKey) ?? false;
    if (!mounted) return;
    setState(() {
      _isGridView = isGrid;
    });
  }

  Future<void> _toggleViewMode() async {
    final newMode = !_isGridView;
    setState(() {
      _isGridView = newMode;
    });
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool(_gridViewPrefKey, newMode);
  }

  void _filterFavInfos() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        favInfo = List.from(rawFavInfo);
      } else {
        favInfo = rawFavInfo.where((file) {
          final title = file.title.toLowerCase();
          final artist = file.artist.toLowerCase();
          final bvidTitle = file.bvid.toLowerCase();
          return title.contains(query) ||
              artist.contains(query) ||
              bvidTitle.contains(query);
        }).toList();
      }
    });
  }

  void _toggleSearch() {
    setState(() {
      if (isSearching) {
        isSearching = false;
        _searchController.clear(); // Clear search when closing
        favInfo = rawFavInfo; // Reset to show all files
      } else {
        isSearching = true;
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    _logger.info('Loading initial data for fav ${widget.fav.id}');
    final cachedData = widget.isCollected
        ? await DatabaseManager.getCachedCollectionMetas(widget.fav.id)
        : await DatabaseManager.getCachedFavMetas(widget.fav.id);
    if (cachedData.isNotEmpty) {
      _logger.info('Loaded ${cachedData.length} items from cache');
      setState(() {
        rawFavInfo = cachedData;
        favInfo = rawFavInfo;
      });
      await _loadItemInfos();
      // 本地缓存可能只是主页封面补拉写入的第一页（~20 条），
      // 不完整时后台联网拉取完整列表，完成后替换展示
      if (!await _isCacheComplete(cachedData.length)) {
        _logger.info(
            'Cache incomplete (${cachedData.length} cached, expected >= '
            '${widget.fav.mediaCount}), fetching full list');
        await loadMetas();
      }
    } else {
      _logger.info('No cached data found, loading from network');
      await loadMetas();
    }
  }

  /// 本地视频缓存是否已覆盖收藏夹全量内容。
  ///
  /// 判断依据（fav_list/collected_fav_list 表的 synced_count 列）：
  /// - synced_count >= 0：上次全量同步过，缓存行数（封面补拉是增量
  ///   merge，只会多不会少）达到该值即视为完整；
  /// - synced_count == -1：从未全量同步过，退回与收藏夹计数比较。
  ///
  /// 不直接与 mediaCount 比较作为唯一标准：B 站 media_count 包含失效
  /// 视频而列表接口不返回它们（实测 8 计数/7 条目），若只看计数差，
  /// 含失效视频的收藏夹会被判定为永远不完整而每次打开都全量拉取。
  /// （代价：上次同步后服务器新增的条目需下拉刷新才能看到）
  Future<bool> _isCacheComplete(int cachedCount) async {
    final syncedCount = widget.isCollected
        ? await DatabaseManager.getCollectedFavSyncedCount(widget.fav.id)
        : await DatabaseManager.getFavSyncedCount(widget.fav.id);
    if (syncedCount >= 0) {
      return cachedCount >= syncedCount;
    }
    return cachedCount >= widget.fav.mediaCount;
  }

  Future<void> loadMetas() async {
    if (isLoading) {
      _logger.info('Already loading metas, skipping request');
      return;
    }

    setState(() {
      isLoading = true;
      _loadError = false;
    });

    try {
      final metas = widget.isCollected
          ? await BilibiliService.instance
              .then((x) => x.getCollectionMetas(widget.fav.id))
          : await BilibiliService.instance
              .then((x) => x.getFavMetas(widget.fav.id));
      if (metas != null) {
        _logger.info('Loaded ${metas.length} metas from network');
        // 后台补全/刷新可能耗时数秒（大收藏夹分页拉取），
        // 期间用户可能已退出页面，setState 前必须校验
        if (!mounted) return;
        setState(() {
          rawFavInfo = metas;
          favInfo = rawFavInfo;
        });
        await _loadItemInfos();
      } else {
        _logger.warning('Failed to load metas from network');
        if (!mounted) return;
        setState(() {
          _loadError = true;
        });
      }
    } catch (e, stackTrace) {
      _logger.severe('Error loading metas', e, stackTrace);
      if (!mounted) return;
      setState(() {
        _loadError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _loadItemInfos() async {
    // 一次性聚合查询（3 条），替代每视频 3 条的 N+1 查询爆发
    //（496 个视频的收藏夹原需 1488 条查询）
    final infos = await DatabaseManager.getItemInfos(
        rawFavInfo.map((m) => m.bvid).toList());
    if (!mounted) return;
    setState(() {
      _itemInfoCache = infos;
    });
  }

  Future<void> _refreshItemInfo(String bvid) async {
    final info = (
      await DatabaseManager.getExcludedParts(bvid),
      await DatabaseManager.cachedCount(bvid),
      await DatabaseManager.downloadedCount(bvid),
    );
    if (!mounted) return;
    setState(() {
      _itemInfoCache[bvid] = info;
    });
  }

  Future<void> _refreshData() async {
    setState(() {
      rawFavInfo.clear();
      favInfo.clear();
    });
    await loadMetas();
  }

  void toggleSelectionMode() {
    setState(() {
      isSelectionMode = !isSelectionMode;
      if (!isSelectionMode) {
        selectedItems.clear();
      }
    });
  }

  void _toggleItemSelection(String id) {
    setState(() {
      if (selectedItems.contains(id)) {
        selectedItems.remove(id);
        _logger.info('Unselected item $id');
      } else {
        selectedItems.add(id);
        _logger.info('Selected item $id');
      }

      if (selectedItems.isEmpty) {
        isSelectionMode = false;
      } else {
        isSelectionMode = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        toggleSelectionMode();
      },
      child: Scaffold(
        appBar: AppBar(
          title: isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索标题或作者...',
                    border: InputBorder.none,
                  ),
                )
              : Text(widget.fav.title),
          leading: isSelectionMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => toggleSelectionMode(),
                )
              : null,
          actions: [
            if (isSelectionMode)
              IconButton(
                icon: const Icon(Icons.download),
                onPressed: () async {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('下载'),
                      content: Text('是否要下载${selectedItems.length}个视频？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () async {
                            Navigator.pop(context, true);
                          },
                          child: const Text('下载'),
                        ),
                      ],
                    ),
                  ).then((value) async {
                    if (value == true) {
                      final dm = await DownloadManager.instance;
                      await dm.addBvidTasks(selectedItems.toList());

                      if (!context.mounted) return;

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已添加 ${selectedItems.length} 个下载任务'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                      toggleSelectionMode();
                    }
                  });
                },
              ),
            IconButton(
              // 缩略图网格 / 曲目列表视图切换（全局偏好，记忆选择）
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
              tooltip: _isGridView ? '列表视图' : '网格视图',
              onPressed: _toggleViewMode,
            ),
            IconButton(
              icon: Icon(isSearching ? Icons.close : Icons.search),
              onPressed: _toggleSearch,
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refreshData,
          child: favInfo.isEmpty && !isLoading
              ? ListView(
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: Center(
                        child: _loadError
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('加载失败'),
                                  const SizedBox(height: 8),
                                  FilledButton(
                                    onPressed: _refreshData,
                                    child: const Text('重试'),
                                  ),
                                ],
                              )
                            : const Text('暂无内容'),
                      ),
                    ),
                  ],
                )
              : _isGridView
                  ? _buildGridView()
                  : ListView.builder(
                      // 使用默认 cacheExtent（250px）：原 10000px 会让打开
                      // 收藏夹的首帧一口气预建上百个 TrackTile，造成瞬间卡顿
                      itemCount: favInfo.length,
                      itemBuilder: (context, index) {
                        return favDetailListTileView(index);
                      },
                    ),
        ),
        bottomNavigationBar: const PlayingCard(),
      ),
    );
  }

  /// 从 [index] 播放整个收藏夹（列表/网格视图共用）。
  /// 搜索过滤中只播放过滤结果
  Future<void> _playFromIndex(int index) async {
    try {
      _logger.info('Playing fav list ${widget.fav.id} from index $index');
      final List<String> bvids;
      if (_searchController.text.isNotEmpty) {
        bvids = favInfo.map((m) => m.bvid).toList();
      } else {
        bvids = widget.isCollected
            ? await DatabaseManager.getCachedCollectionBvids(widget.fav.id)
            : await DatabaseManager.getCachedFavBvids(widget.fav.id);
      }
      await AudioService.instance
          .then((x) => x.playByBvids(bvids, index: index));
    } catch (e, stackTrace) {
      _logger.severe('Error playing fav list', e, stackTrace);
    }
  }

  /// 长按菜单（列表/网格视图共用）
  void _showItemMenu(int index) {
    if (!context.mounted) return;
    final m = favInfo[index];
    final cachedCount = _itemInfoCache[m.bvid]?.$2 ?? 0;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('查看 UP 主'),
              onTap: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => UserDetailScreen(mid: m.mid),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_remove),
              title: const Text('屏蔽分 P'),
              onTap: () {
                Navigator.pop(dialogContext);
                showDialog(
                  context: context,
                  builder: (context) => ExcludedPartsDialog(
                    bvid: m.bvid,
                    title: m.title,
                  ),
                ).then((_) {
                  _refreshItemInfo(m.bvid);
                });
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
                            CommentScreen(aid: m.aid.toString())));
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite_outline),
              title: const Text('取消收藏'),
              onTap: () async {
                Navigator.pop(dialogContext);
                final success = await BilibiliService.instance
                        .then((x) => x.favoriteVideo(
                              m.aid,
                              [],
                              [widget.fav.id],
                            )) ??
                    false;

                if (!mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? '已取消收藏' : '操作失败'),
                    duration: const Duration(seconds: 2),
                  ),
                );

                if (success) {
                  setState(() {
                    final removed = favInfo.removeAt(index);
                    rawFavInfo.removeWhere((x) => x.bvid == removed.bvid);
                    _itemInfoCache.remove(removed.bvid);
                  });
                }
              },
            ),
            if (cachedCount > 0)
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('删除所有缓存'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除缓存'),
                      content: Text('是否要删除 $cachedCount 个缓存？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () async {
                            Navigator.pop(context, true);
                          },
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  ).then((value) async {
                    if (value == true) {
                      await DatabaseManager.removeCache(m.bvid);
                      _refreshItemInfo(m.bvid);
                    }
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载管理'),
              onTap: () {
                Navigator.pop(dialogContext);
                showDialog(
                  context: context,
                  builder: (context) => DownloadPartsDialog(
                    bvid: m.bvid,
                    title: m.title,
                  ),
                ).then((_) {
                  _refreshItemInfo(m.bvid);
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 缩略图网格视图：3 列封面 + 两行标题，样式对齐主页「最近在听」
  /// 九宫格页卡（16:9 圆角封面 + 右下角时长角标）
  Widget _buildGridView() {
    const crossAxisCount = 3;
    const spacing = 10.0;
    return LayoutBuilder(builder: (context, constraints) {
      // 封面是 B 站 16:9 横图（非方形）：按实际可用宽度计算格宽，
      // 格高 = 封面高 + 间距 + 两行标题——固定比例在手机/桌面窗口
      // 宽度差异下会溢出或留白过多
      final cellWidth = (constraints.maxWidth -
              spacing * (crossAxisCount - 1) -
              20) /
          crossAxisCount;
      final cellHeight = cellWidth * 9 / 16 + 4 + 30;
      return GridView.builder(
        padding: const EdgeInsets.all(10),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cellWidth / cellHeight,
        ),
        itemCount: favInfo.length,
        itemBuilder: (context, index) => _gridCellView(index),
      );
    });
  }

  Widget _gridCellView(int index) {
    final m = favInfo[index];
    final itemInfo = _itemInfoCache[m.bvid];
    final cachedCount = itemInfo?.$2 ?? 0;
    final downloadedCount = itemInfo?.$3 ?? 0;
    final selected = selectedItems.contains(m.bvid);
    final scheme = Theme.of(context).colorScheme;
    final int min = m.duration ~/ 60;
    final int sec = m.duration % 60;
    final duration = '$min:${sec.toString().padLeft(2, '0')}';
    final placeholder = Container(
      color: scheme.primaryContainer,
      child: Icon(Icons.music_note, color: scheme.primary, size: 24),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: isSelectionMode
          ? () => _toggleItemSelection(m.bvid)
          : () => _playFromIndex(index),
      onLongPress: isSelectionMode ? null : () => _showItemMenu(index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (m.artUri.isEmpty)
                    placeholder
                  else
                    CachedNetworkImage(
                      imageUrl: '${m.artUri}@256w_144h_1c',
                      fit: BoxFit.cover,
                      placeholder: (_, __) => placeholder,
                      errorWidget: (_, __, ___) => placeholder,
                    ),
                  // 右下角时长角标
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.54),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        duration,
                        style: const TextStyle(color: Colors.white, fontSize: 9),
                      ),
                    ),
                  ),
                  // 左上角缓存/下载角标
                  if (cachedCount > 0 || downloadedCount > 0)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.54),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          downloadedCount > 0
                              ? Icons.check_circle
                              : Icons.download_done_outlined,
                          color: downloadedCount > 0
                              ? scheme.tertiary
                              : Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                  // 选择模式：蒙层 + 选中标记
                  if (isSelectionMode)
                    Positioned.fill(
                      child: Container(
                        alignment: Alignment.center,
                        color: selected
                            ? scheme.primary.withValues(alpha: 0.35)
                            : Colors.black.withValues(alpha: 0.25),
                        child: selected
                            ? const Icon(Icons.check_circle,
                                color: Colors.white, size: 28)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            m.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget favDetailListTileView(int index) {
    int min = favInfo[index].duration ~/ 60;
    int sec = favInfo[index].duration % 60;
    final duration = "$min:${sec.toString().padLeft(2, '0')}";

    final itemInfo = _itemInfoCache[favInfo[index].bvid];
    final excludedCount = itemInfo?.$1.length ?? 0;
    final cachedCount = itemInfo?.$2 ?? 0;
    final downloadedCount = itemInfo?.$3 ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: TrackTile(
        key: Key(favInfo[index].bvid),
        pic: favInfo[index].artUri,
        parts: favInfo[index].parts,
        excludedParts: excludedCount,
        title: favInfo[index].title,
        author: favInfo[index].artist,
        len: duration,
        cached: cachedCount > 0,
        downloaded: downloadedCount > 0,
        color: isSelectionMode
            ? selectedItems.contains(favInfo[index].bvid)
                ? Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.7)
                : Theme.of(context).colorScheme.surfaceContainerLow
            : null,
        onPicTap: () => _toggleItemSelection(favInfo[index].bvid),
        onTap: isSelectionMode
            ? () => _toggleItemSelection(favInfo[index].bvid)
            : () => _playFromIndex(index),
        onAddToPlaylistButtonPressed: () async {
          try {
            _logger.info('Adding ${favInfo[index].bvid} to playlist');
            await AudioService.instance.then((x) => x.appendPlaylist(
                favInfo[index].bvid,
                insertIndex: x.playlist.length == 0
                    ? 0
                    : (x.player.currentIndex ?? 0) + 1));
          } catch (e) {
            _logger.warning(
                'Failed to append to playlist, trying cached playlist', e);
            await AudioService.instance
                .then((x) => x.appendCachedPlaylist(favInfo[index].bvid));
          }
        },
        onLongPress:
            isSelectionMode ? null : () => _showItemMenu(index),
      ),
    );
  }
}
