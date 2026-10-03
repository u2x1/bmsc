import 'package:bmsc/component/recent_listening_grid.dart';
import 'package:bmsc/component/section_header.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import '../service/shared_preferences_service.dart';
import 'fav_detail_screen.dart';
import 'login_screen.dart';
import 'recommendation_screen.dart';
import 'package:bmsc/util/logger.dart';

final logger = LoggerUtils.getLogger('FavScreen');

/// 收藏夹封面堆叠中，每层背层相对前一层向 ↗ 探出的固定步长（px）。
/// 三张卡片同大同比（16:9），按固定步长错位——右缘与顶边的
/// 探出宽度严格相等，避免按比例换算导致的探出宽度不一。
const _favCoverStackStep = 6.0;

class FavScreen extends StatefulWidget {
  final void Function(FavScreenState state)? onInit;

  const FavScreen({super.key, this.onInit});

  @override
  State<FavScreen> createState() => FavScreenState();
}

class FavScreenState extends State<FavScreen> {
  bool signedin = false;
  bool loadFailed = false;
  List<Fav> favList = [];
  List<Fav> collectedFavList = [];
  Set<int>? hideFav;

  /// 各收藏夹的本地缓存封面（供网格拼贴缩略图），键为收藏夹 id
  Map<int, List<String>> favCovers = {};

  /// 分区开关的偏好读取 future 缓存：build 内临时新建 Future 会让
  /// FutureBuilder 每次 setState 都重新经历 waiting 态（吸顶 header
  /// 闪烁并多一轮异步等待）；设置页返回时由 refreshLoginState 重新
  /// 读取以应用变更
  late Future<bool> _showRecentFuture;
  late Future<bool> _showDailyFuture;

  void _reloadSectionToggles() {
    _showRecentFuture = SharedPreferencesService.instance
        .then((prefs) => prefs.getBool('show_recent_listening') ?? true);
    _showDailyFuture = SharedPreferencesService.instance
        .then((prefs) => prefs.getBool('show_daily_recommendations') ?? true);
  }

  @override
  void initState() {
    super.initState();
    _reloadSectionToggles();
    widget.onInit?.call(this);
    // 播放页收藏/取消收藏后本地库会 bump favListVersion，
    // 此处重读本地缓存使主页收藏夹计数与封面即时更新
    DatabaseManager.favListVersion.addListener(_onFavListChanged);
    BilibiliService.instance.then((x) {
      setState(() {
        signedin = x.myInfo?.mid != null && x.myInfo?.mid != 0;
      });
      if (signedin) {
        loadFavorites(local: true);
      }
    });
  }

  void _onFavListChanged() {
    loadFavorites(local: true);
  }

  @override
  void dispose() {
    DatabaseManager.favListVersion.removeListener(_onFavListChanged);
    super.dispose();
  }

  Future<void> refreshLoginState() async {
    // 设置页可能修改了分区开关，重新读取
    _reloadSectionToggles();
    final x = await BilibiliService.instance;
    if (!mounted) return;
    setState(() {
      signedin = x.myInfo?.mid != null && x.myInfo?.mid != 0;
    });
    if (signedin) {
      loadFavorites(local: true);
    }
  }

  Future<void> loadFavorites({bool local = false}) async {
    if (!mounted || !signedin) return;

    hideFav = await SharedPreferencesService.getFavHideList();

    if (local) {
      var cachedFavs = await DatabaseManager.getCachedFavList();
      var cachedCollectedFavs =
          await DatabaseManager.getCachedCollectedFavList();

      if (cachedFavs.isNotEmpty || cachedCollectedFavs.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          favList = cachedFavs;
          collectedFavList = cachedCollectedFavs;
        });
        _loadFavCovers();
      } else {
        // 本地缓存为空（首次登录/刚清缓存）时本地加载静默无结果——
        // 回退到网络拉取，否则主页停留在空白状态（真机实测：
        // 登录后 got 0 cached favs 即止步）
        return loadFavorites();
      }

      logger.info(
          'got ${cachedFavs.length} cached favs and ${cachedCollectedFavs.length} collected favs');
    } else {
      BilibiliService.instance.then((x) async {
        if (!mounted) return;
        final uid = x.myInfo?.mid;
        if (uid == null || uid == 0) {
          return;
        }

        try {
          final ret = await x.getFavs(uid);
          final collectedRet = await x.getCollection(uid);

          if (!mounted) return;
          if (ret == null && collectedRet == null) {
            setState(() {
              loadFailed = true;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('加载失败')),
            );
            return;
          }
          setState(() {
            loadFailed = false;
            // 单侧加载失败（如瞬断网）时保留已有缓存数据，
            // 避免列表被清空
            favList = ret ?? favList;
            collectedFavList = collectedRet ?? collectedFavList;
          });
          _loadFavCovers();

          if (favList.isNotEmpty || collectedFavList.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('加载成功')),
            );
            logger.info(
                'got ${favList.length} favs and ${collectedFavList.length} collected favs from network');
          }
        } catch (e) {
          logger.severe('loadFavorites error: $e');

          if (!mounted) return;
          setState(() {
            loadFailed = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('加载失败')),
          );
        }
        logger.info('loadFavorites done');
      });
    }
  }

  /// 本次运行中已发起过封面补拉的收藏夹 id（每个收藏夹只补一次，
  /// 同时保证 _loadFavCovers ↔ _backfillMissingCovers 不会无限递归）
  final Set<int> _coverBackfillRequested = {};

  /// 加载各收藏夹的封面（仅 DB 查询，不访问网络），
  /// 供主页收藏夹网格的封面拼贴缩略图使用；
  /// 无本地歌曲封面缓存的回退到列表 API 返回的收藏夹自身封面。
  Future<void> _loadFavCovers() async {
    final covers = await DatabaseManager.getFavCoverPreviews(
      favList.map((f) => f.id).toList(),
      collectedFavList.map((f) => f.id).toList(),
    );
    for (final fav in [...favList, ...collectedFavList]) {
      final cover = fav.cover;
      if ((covers[fav.id] ?? []).isEmpty && cover != null && cover.isNotEmpty) {
        covers[fav.id] = [cover];
      }
    }
    if (!mounted) return;
    setState(() => favCovers = covers);
    _backfillMissingCovers(covers);
  }

  /// 封面不足 3 张的收藏夹：只有收藏夹自身封面一张图时堆叠会失效
  ///（只能垫纯色层），后台低并发补拉其第一页内容增量缓存，
  /// 让真实封面堆叠生效；完成后重新加载封面。
  Future<void> _backfillMissingCovers(Map<int, List<String>> covers) async {
    final missing = [
      for (final f in favList)
        if ((covers[f.id] ?? []).length < 3 &&
            !_coverBackfillRequested.contains(f.id))
          (f.id, true),
      for (final f in collectedFavList)
        if ((covers[f.id] ?? []).length < 3 &&
            !_coverBackfillRequested.contains(f.id))
          (f.id, false),
    ];
    if (missing.isEmpty) return;
    _coverBackfillRequested.addAll(missing.map((e) => e.$1));
    final bs = await BilibiliService.instance;
    // 逐个补齐（低并发），避免短时间大量请求触发风控
    for (final (id, isOwned) in missing) {
      if (isOwned) {
        await bs.cacheFavFirstPageMetas(id);
      } else {
        await bs.cacheCollectionFirstPageMetas(id);
      }
      if (!mounted) return;
    }
    if (!mounted) return;
    await _loadFavCovers();
  }

  Future<void> _showCreateFolderDialog() async {
    final nameController = TextEditingController();
    bool isPrivate = false;

    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('创建收藏夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '收藏夹名称',
                  hintText: '请输入收藏夹名称',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: isPrivate,
                    onChanged: (value) => setState(() => isPrivate = value!),
                  ),
                  const Text('设为私密收藏夹'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入收藏夹名称')),
                  );
                  return;
                }
                Navigator.pop(context, (
                  nameController.text.trim(),
                  isPrivate,
                ));
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final folderId =
          await BilibiliService.instance.then((x) => x.createFavFolder(
                result.$1,
                hide: result.$2,
              ));

      if (folderId != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('创建成功')),
          );
          loadFavorites();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('创建失败')),
          );
        }
      }
    }
  }

  Future<void> _showEditFolderDialog(Fav fav) async {
    final nameController = TextEditingController(text: fav.title);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('编辑收藏夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '收藏夹名称',
                  hintText: '请输入收藏夹名称',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入收藏夹名称')),
                  );
                  return;
                }
                Navigator.pop(context, nameController.text.trim());
              },
              child: const Text('保存'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final success =
          await BilibiliService.instance.then((x) => x.editFavFolder(
                fav.id,
                result,
              ));

      if (success == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('修改成功')),
          );
          loadFavorites();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('修改失败')),
          );
        }
      }
    }
  }

  Future<void> _showDeleteConfirmation(Fav fav) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏夹'),
        content: Text('确定要删除收藏夹"${fav.title}"吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success =
          await BilibiliService.instance.then((x) => x.deleteFavFolder(fav.id));
      if (success == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除成功')),
          );
          loadFavorites();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除失败')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 不使用顶部「云收藏夹」栏，新建/刷新入口
      // 移至「我的收藏夹」分区标题行
      body: !signedin
          ? Center(
              // 未登录：点击直接进入登录页，登录成功后原地刷新收藏夹
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final loggedIn = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute<bool>(
                        builder: (_) => const LoginScreen()),
                  );
                  if (loggedIn == true && mounted) {
                    await refreshLoginState();
                  }
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline,
                          size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        '请先登录',
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '点击登录',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : loadFailed && favList.isEmpty && collectedFavList.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text(
                        '加载失败',
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: loadFavorites,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    // 板块一：每日推荐（header 吸顶，整行可点击），
                    // 推荐基于收藏夹，无收藏夹时不显示
                    if (favList.isNotEmpty || collectedFavList.isNotEmpty)
                      _buildDailyRecommendSection(),

                    // 板块二：最近在听（九宫格页卡，header 吸顶，
                    // 受「显示最近在听」设置开关控制）
                    _buildRecentSection(),

                    // 板块三：我的收藏夹（header 吸顶 + 封面拼贴九宫格）。
                    // 标题行常驻，保证空列表时仍可从尾部按钮新建/刷新
                    SliverStickyHeader(
                      header: SectionHeader(
                        icon: Icons.folder_outlined,
                        title: '我的收藏夹',
                        count: favList.isEmpty ? null : _visibleCount(favList),
                        trailing: _buildFavActions(),
                      ),
                      sliver: _buildFavSectionBody(favList, true),
                    ),

                    // 板块四：收藏的收藏夹（header 吸顶 + 封面拼贴九宫格，
                    // 顶部通栏分隔条与上一分区界限明确）
                    if (collectedFavList.isNotEmpty) ...[
                      const SliverToBoxAdapter(child: SectionDivider()),
                      SliverStickyHeader(
                        header: SectionHeader(
                          icon: Icons.star_outline,
                          title: '收藏的收藏夹',
                          count: _visibleCount(collectedFavList),
                        ),
                        sliver: _buildFavSectionBody(collectedFavList, false),
                      ),
                    ],
                  ],
                ),
    );
  }

  /// 收藏夹板块内容（返回 sliver）：封面拼贴九宫格；
  /// 两个板块都为空时显示占位提示。
  /// 使用懒加载 SliverGrid 替代原 shrinkWrap GridView：
  /// 单元格按需构建，滚动经过时不再整区全量布局/重绘
  Widget _buildFavSectionBody(List<Fav> favs, bool isOwned) {
    if (favList.isEmpty && collectedFavList.isEmpty) {
      return SliverToBoxAdapter(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.folder_outlined, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  '暂无收藏夹',
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final visible =
        favs.where((f) => hideFav == null || !hideFav!.contains(f.id)).toList();
    return _buildFavGrid(visible, isOwned);
  }

  /// 板块二「最近在听」：受「显示最近在听」设置开关控制。
  /// 返回 sliver 供 CustomScrollView 使用。
  Widget _buildRecentSection() {
    return FutureBuilder<bool>(
      future: _showRecentFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        return const RecentListeningGrid();
      },
    );
  }

  /// 板块一「每日推荐」：吸顶分区标题，整行可点击进入推荐页，
  /// 底部通栏分隔条与下一分区界限明确。
  /// 仍受「显示每日推荐」设置开关控制。
  /// 返回 sliver 供 CustomScrollView 使用。
  Widget _buildDailyRecommendSection() {
    return FutureBuilder<bool>(
      future: _showDailyFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!) {
          return const SliverToBoxAdapter(child: SizedBox());
        }
        final scheme = Theme.of(context).colorScheme;
        return SliverStickyHeader(
          header: SectionHeader(
            icon: Icons.auto_awesome,
            title: '每日推荐',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '基于收藏夹的推荐',
                  style: TextStyle(fontSize: 13, color: scheme.secondary),
                ),
                Icon(Icons.chevron_right, size: 18, color: scheme.secondary),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<Widget>(
                  builder: (_) => const RecommendationScreen()),
            ),
          ),
          sliver: const SliverToBoxAdapter(child: SectionDivider()),
        );
      },
    );
  }

  /// 「我的收藏夹」标题行尾部动作：刷新 + 新建收藏夹
  ///（顶部「云收藏夹」栏移除后入口移至此处）。
  Widget _buildFavActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.refresh, size: 20),
          tooltip: '刷新',
          visualDensity: VisualDensity.compact,
          onPressed: loadFavorites,
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          tooltip: '创建收藏夹',
          visualDensity: VisualDensity.compact,
          onPressed: _showCreateFolderDialog,
        ),
      ],
    );
  }

  int _visibleCount(List<Fav> favs) =>
      favs.where((f) => hideFav == null || !hideFav!.contains(f.id)).length;

  /// 收藏夹九宫格（返回 sliver）：与「最近在听」一致的 3 列网格布局，
  /// 更紧凑；封面为夹内歌曲封面的堆叠拼贴（本地缓存），点击进入收藏夹，
  /// 封面右上角 ⋮ 按钮弹出操作菜单。
  /// SliverGrid.builder 懒加载：仅构建可视区附近的格子。
  Widget _buildFavGrid(List<Fav> favs, bool isOwned) {
    const spacing = 10.0;
    // 封面区高 = 主体封面（恰好 16:9）+ 两层固定步长探出；
    // 格高 = 封面区高 + 间距 + 两行标题 + 一行计数
    final cellWidth = (MediaQuery.sizeOf(context).width - 48 - spacing * 2) / 3;
    final coverHeight =
        (cellWidth - _favCoverStackStep * 2) * 9 / 16 + _favCoverStackStep * 2;
    final cellHeight = coverHeight + 4 + 30 + 14;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: spacing + 6,
          crossAxisSpacing: spacing,
          childAspectRatio: cellWidth / cellHeight,
        ),
        itemCount: favs.length,
        itemBuilder: (context, i) => _buildFavCell(favs[i], isOwned),
      ),
    );
  }

  Widget _buildFavCell(Fav fav, bool isOwned) {
    final scheme = Theme.of(context).colorScheme;
    final covers = favCovers[fav.id] ?? const <String>[];
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FavDetailScreen(
              fav: fav,
              isCollected: !isOwned,
            ),
          ),
        );
      },
      onLongPress: () => _showFavActions(fav, isOwned),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面堆叠：三张 16:9 卡片按固定步长向 ↗ 错位；
          // 圆角 6px 由堆叠内部各层自裁剪（见 _buildFavCover），
          // 不再包外层 ClipRRect（省一个 saveLayer）
          _buildFavCover(covers, scheme),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fav.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, height: 1.3),
                    ),
                    Text(
                      '${fav.mediaCount} 个视频',
                      style: TextStyle(fontSize: 10, color: scheme.secondary),
                    ),
                  ],
                ),
              ),
              // 操作入口放在文字元信息旁（语义对象是收藏夹而非封面图），
              // 不再遮挡封面；长按格子亦可触发同样菜单
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _showFavActions(fav, isOwned),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child:
                      Icon(Icons.more_vert, size: 16, color: scheme.secondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 封面堆叠：三张完全同大的 16:9 卡片，按固定步长 [_favCoverStackStep]
  /// 向 ↗ 逐级错位——打分最高的封面为视觉主体（左下），背层的右缘
  /// 与顶边探出宽度严格相等（各一个步长），翻页方向明确且步进均匀；
  /// 不足 3 张封面时用纯色卡片垫底，保持「一叠」的形态。
  /// 无缓存时整体回退文件夹图标占位。
  ///（封面图为 B 站 CDN 16:9 裁剪 320×180，适配 3x 视网膜）
  Widget _buildFavCover(List<String> covers, ColorScheme scheme) {
    final placeholder = Container(
      color: scheme.primaryContainer,
      child: Icon(Icons.folder_outlined, color: scheme.primary, size: 32),
    );
    if (covers.isEmpty) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: placeholder,
        ),
      );
    }

    // i 为 null 时用纯色卡片垫底，半透明黑罩压暗分层次；
    // 黑罩替代 ColorFiltered(darken)：对半透明黑色两者效果一致
    //（均为 (1-a)·I），但省去每层的 ColorFiltered saveLayer
    Widget layer(int? i, double scrim) => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              i != null
                  ? _coverImage(
                      covers[i], Container(color: scheme.primaryContainer))
                  : Container(color: scheme.primaryContainer),
              if (scrim > 0)
                Container(color: Colors.black.withValues(alpha: scrim)),
            ],
          ),
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        const step = _favCoverStackStep;
        // 三张卡片同大同比（16:9）：宽扣掉两个步长，高加回两个步长
        final cardW = constraints.maxWidth - step * 2;
        final cardH = cardW * 9 / 16;
        return SizedBox(
          height: cardH + step * 2,
          child: Stack(
            children: [
              // 底层（第三张或纯色层）：最右上
              Positioned(
                right: 0,
                top: 0,
                width: cardW,
                height: cardH,
                child: layer(covers.length > 2 ? 2 : null, 0.3),
              ),
              // 中层（第二张或纯色层）：向左下退一个步长
              Positioned(
                left: step,
                top: step,
                width: cardW,
                height: cardH,
                child: layer(covers.length > 1 ? 1 : null, 0.15),
              ),
              // 主体（第一张）：左下
              Positioned(
                left: 0,
                bottom: 0,
                width: cardW,
                height: cardH,
                child: layer(0, 0),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _coverImage(String url, Widget fallback) {
    return CachedNetworkImage(
      // 与「最近在听」一致的 16:9 裁剪（320×180 适配 3x 视网膜），
      // 方形裁剪会把 16:9 原图两侧裁掉再放大，辨识度差
      imageUrl: '$url@320w_180h_1c',
      fit: BoxFit.cover,
      placeholder: (_, __) => fallback,
      errorWidget: (_, __, ___) => fallback,
    );
  }

  /// 收藏夹操作菜单（网格 ⋮ 按钮或长按触发）
  void _showFavActions(Fav fav, bool isOwned) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isOwned) ...[
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('添加到播放列表'),
                onTap: () async {
                  Navigator.pop(context);
                  final bvids = await DatabaseManager.getCachedFavBvids(fav.id);
                  if (!context.mounted) return;
                  if (bvids.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('本地缓存为空，请先打开收藏夹加载内容')),
                    );
                    return;
                  }
                  await AudioService.instance.then((x) => x.playByBvids(bvids));
                },
              ),
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('设为默认收藏夹'),
                onTap: () async {
                  Navigator.pop(context);
                  await SharedPreferencesService.setDefaultFavFolder(
                      fav.id, fav.title);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已将 ${fav.title} 设为默认收藏夹'),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('编辑收藏夹'),
                onTap: () {
                  Navigator.pop(context);
                  _showEditFolderDialog(fav);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete,
                    color: Theme.of(context).colorScheme.error),
                title: Text('删除收藏夹',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteConfirmation(fav);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.visibility_off),
              title: const Text('隐藏收藏夹'),
              onTap: () async {
                Navigator.pop(context);
                hideFav ??= <int>{};
                hideFav!.add(fav.id);
                final success =
                    await SharedPreferencesService.saveFavHideList(hideFav!);
                if (success == true) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('隐藏成功')),
                    );
                    setState(() {});
                  }
                } else {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('隐藏失败')),
                    );
                  }
                  hideFav!.remove(fav.id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
