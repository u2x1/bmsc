import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import '../service/shared_preferences_service.dart';
import 'fav_detail_screen.dart';
import 'package:bmsc/util/logger.dart';

final logger = LoggerUtils.getLogger('HiddenFavScreen');

class HiddenFavScreen extends StatefulWidget {
  final void Function(HiddenFavScreenState state)? onInit;

  const HiddenFavScreen({super.key, this.onInit});

  @override
  State<HiddenFavScreen> createState() => HiddenFavScreenState();
}

class HiddenFavScreenState extends State<HiddenFavScreen> {
  bool signedin = false;
  List<Fav> favList = [];
  List<Fav> collectedFavList = [];
  Set<int>? hideFav;

  @override
  void initState() {
    super.initState();
    widget.onInit?.call(this);
    BilibiliService.instance.then((x) {
      setState(() {
        signedin = x.myInfo?.mid != null &&
            x.myInfo?.mid != 0 &&
            !x.sessionExpired.value;
      });
      if (signedin) {
        loadFavorites(local: true);
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
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
          final ret = (await x.getFavs(uid)) ?? [];
          final collectedRet = (await x.getCollection(uid)) ?? [];

          if (ret.isNotEmpty || collectedRet.isNotEmpty) {
            if (!mounted) return;
            setState(() {
              favList = ret;
              collectedFavList = collectedRet;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('加载成功')),
            );
            logger.info(
                'got ${ret.length} favs and ${collectedRet.length} collected favs from network');
          }
        } catch (e) {
          logger.severe('loadFavorites error: $e');

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('加载失败')),
          );
        }
        logger.info('loadFavorites done');
      });
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

  Future<void> _cancelHide(Fav fav) async {
    hideFav ??= <int>{};
    hideFav!.remove(fav.id);
    final success = await SharedPreferencesService.saveFavHideList(hideFav!);
    if (success == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取消隐藏成功')),
        );
        setState(() {});
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取消隐藏失败')),
        );
      }
      hideFav!.add(fav.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hiddenFavs =
        favList.where((f) => hideFav?.contains(f.id) ?? false).toList();
    final hiddenCollectedFavs =
        collectedFavList.where((f) => hideFav?.contains(f.id) ?? false).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('隐藏的收藏夹',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: !signedin
          ? const Center(child: Text('请先登录'))
          : ListView(
              children: [
                if (hiddenFavs.isEmpty && hiddenCollectedFavs.isEmpty)
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.folder_outlined,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            '无隐藏项',
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 我的收藏夹标题
                if (hiddenFavs.isNotEmpty)
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                    child: Text(
                      '我的收藏夹',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                // 我的收藏夹列表
                ...buildFavList(hiddenFavs, true),

                // 收藏的收藏夹标题
                if (hiddenCollectedFavs.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                    child: Text(
                      '收藏的收藏夹',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  // 收藏的收藏夹列表
                  ...buildFavList(hiddenCollectedFavs, false),
                ],

                // 显示空状态
              ],
            ),
    );
  }

  List<Widget> buildFavList(List<Fav> favs, bool isOwned) {
    return favs
        .map((fav) => (hideFav == null || !hideFav!.contains(fav.id))
            ? SizedBox()
            : Column(
                children: [
                  ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24.0,
                      ),
                      leading: Icon(
                        Icons.folder_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(
                        fav.title,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text('${fav.mediaCount} 个视频'),
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
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => showDialog(
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
                                      final bvids = await DatabaseManager
                                          .getCachedFavBvids(fav.id);
                                      if (!context.mounted) return;
                                      if (bvids.isEmpty) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                              content:
                                                  Text('本地缓存为空，请先打开收藏夹加载内容')),
                                        );
                                        return;
                                      }
                                      await AudioService.instance
                                          .then((x) => x.playByBvids(bvids));
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.star_outline),
                                    title: const Text('设为默认收藏夹'),
                                    onTap: () async {
                                      Navigator.pop(context);
                                      await SharedPreferencesService
                                          .setDefaultFavFolder(
                                              fav.id, fav.title);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('已将 ${fav.title} 设为默认收藏夹'),
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
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error),
                                    title: Text('删除收藏夹',
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _showDeleteConfirmation(fav);
                                    },
                                  ),
                                ],
                                ListTile(
                                  leading: const Icon(Icons.visibility),
                                  title: const Text('取消隐藏收藏夹'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _cancelHide(fav);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      )),
                  const Divider(),
                ],
              ))
        .toList();
  }
}
