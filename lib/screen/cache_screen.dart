import 'package:flutter/rendering.dart';
import 'package:bmsc/component/playing_card.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../database_manager.dart';
import 'dart:io';

final _logger = LoggerUtils.getLogger('CacheScreen');

class CacheScreen extends StatefulWidget {
  const CacheScreen({super.key});

  @override
  State<StatefulWidget> createState() => _CacheScreenState();
}

class _CacheScreenState extends State<CacheScreen> {
  List<Map<String, dynamic>> cachedFiles = [];
  List<Map<String, dynamic>> filteredFiles = [];
  bool isLoading = true;
  bool isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  bool isSelectionMode = false;
  Set<String> selectedItems = {};

  @override
  void initState() {
    super.initState();
    loadCachedFiles();
    _searchController.addListener(_filterFiles);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterFiles() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        filteredFiles = List.from(cachedFiles);
      } else {
        filteredFiles = cachedFiles.where((file) {
          final title = file['title'].toString().toLowerCase();
          final artist = file['artist'].toString().toLowerCase();
          final bvidTitle = file['bvid_title'].toString().toLowerCase();
          return title.contains(query) ||
              artist.contains(query) ||
              bvidTitle.contains(query);
        }).toList();
      }
    });
  }

  Future<void> loadCachedFiles() async {
    final db = await DatabaseManager.database;
    final dbResults = await db.query(
      DatabaseManager.cacheTable,
      orderBy: 'createdAt DESC',
    );
    _logger.info('loadCachedFiles: $dbResults');

    final results = (await Future.wait(dbResults.map((x) async {
      var entity = (await db.query(
        DatabaseManager.entityTable,
        where: 'bvid = ? AND cid = ?',
        whereArgs: [x['bvid'], x['cid']],
      ))
          .firstOrNull;

      if (entity == null) {
        return null;
      }

      return {
        'filePath': x['filePath'],
        'fileSize': x['fileSize'],
        'bvid': x['bvid'],
        'cid': x['cid'],
        'createdAt': x['createdAt'],
        'title': entity['part_title'],
        'artist': entity['artist'],
        'part': entity['part'],
        'bvid_title': entity['bvid_title'],
        'artUri': entity['art_uri'],
      };
    })))
        .whereType<Map<String, dynamic>>()
        .toList();

    setState(() {
      cachedFiles = results;
      filteredFiles = results;
      isLoading = false;
    });
  }

  String getFileSize(int sizeInBytes) {
    if (sizeInBytes < 1024 * 1024) {
      return '${(sizeInBytes / 1024).toStringAsFixed(2)} KB';
    }
    return '${(sizeInBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> deleteCaches(List<Map<String, dynamic>> fileDatas) async {
    final itemsToRemove = <Map<String, dynamic>>[];

    for (var fileData in fileDatas) {
      final bvid = fileData['bvid'];
      final cid = fileData['cid'];
      final filePath = fileData['filePath'];
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }

      final db = await DatabaseManager.database;
      await db.delete(
        DatabaseManager.cacheTable,
        where: 'bvid = ? AND cid = ?',
        whereArgs: [bvid, cid],
      );

      itemsToRemove.addAll(cachedFiles
          .where((item) => item['bvid'] == bvid && item['cid'] == cid));
    }

    cachedFiles.removeWhere((item) => itemsToRemove.contains(item));
    setState(() {});
  }

  Future<void> clearAllCache() async {
    try {
      await deleteCaches(cachedFiles);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('缓存已清空')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('缓存清空失败: $e')),
        );
      }
    }
  }

  void _toggleSearch() {
    setState(() {
      if (isSearching) {
        isSearching = false;
        _searchController.clear(); // Clear search when closing
        filteredFiles = cachedFiles; // Reset to show all files
      } else {
        isSearching = true;
      }
    });
  }

  Future<void> saveToDownloads(
      Map<String, dynamic> file, String downloadPath) async {
    try {
      final sourceFile = File(file['filePath']);
      if (!await sourceFile.exists()) {
        throw Exception('Source file not found');
      }

      final downloadDir = Directory(downloadPath);
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      final fileName = '${file['title']} - ${file['artist']}.m4a';
      final sanitizedFileName =
          fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final targetPath = '${downloadDir.path}/$sanitizedFileName';

      await sourceFile.copy(targetPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  void _toggleSelectionMode() {
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
      } else {
        selectedItems.add(id);
      }

      if (selectedItems.isEmpty) {
        isSelectionMode = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _toggleSelectionMode,
              )
            : null,
        title: isSelectionMode
            ? Text('已选择 ${selectedItems.length} 项')
            : (isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索标题或作者...',
                      border: InputBorder.none,
                    ),
                  )
                : const Text('缓存管理')),
        actions: [
          if (!isSelectionMode) ...[
            IconButton(
              icon: Icon(isSearching ? Icons.close : Icons.search),
              onPressed: _toggleSearch,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('清空缓存'),
                      content: const Text('确定要清空所有缓存吗？'),
                      actions: [
                        TextButton(
                          child: const Text('取消'),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        TextButton(
                          child: const Text('确定'),
                          onPressed: () {
                            Navigator.of(context).pop();
                            clearAllCache();
                          },
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: selectedItems.isEmpty
                  ? null
                  : () {
                      final ctx = context;
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('保存到本地'),
                          content: Text(
                              '确定要保存这 ${selectedItems.length} 个缓存文件到本地下载目录吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                final downloadPath =
                                    await SharedPreferencesService
                                        .getDownloadPath();

                                for (var file in filteredFiles.where((f) =>
                                    selectedItems.contains(
                                        '${f['bvid']}_${f['cid']}'))) {
                                  await saveToDownloads(file, downloadPath);
                                }
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            '已将${selectedItems.length}个文件保存到 $downloadPath')),
                                  );
                                }
                                _toggleSelectionMode();
                              },
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      );
                    },
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: selectedItems.isEmpty
                  ? null
                  : () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除缓存'),
                          content:
                              Text('确定要删除这 ${selectedItems.length} 个缓存文件吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                await deleteCaches(filteredFiles
                                    .where((f) => selectedItems
                                        .contains('${f['bvid']}_${f['cid']}'))
                                    .toList());
                                _toggleSelectionMode();
                              },
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      );
                    },
            ),
          ],
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: loadCachedFiles,
              child: filteredFiles.isEmpty
                  ? ListView(
                      // Wrap Center in ListView for RefreshIndicator to work
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height *
                              0.8, // Push content to center
                          child: Center(
                            child: Text(
                              _searchController.text.isEmpty
                                  ? '没有缓存文件'
                                  : '没有找到匹配的文件',
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                      itemCount: filteredFiles.length,
                      itemBuilder: (context, index) {
                        final file = filteredFiles[index];
                        final fileSize = getFileSize(file['fileSize']);
                        final id = '${file['bvid']}_${file['cid']}';

                        return TrackTile(
                          key: Key(id),
                          title: file['title'],
                          author: file['artist'],
                          len: fileSize,
                          pic: file['artUri'],
                          album: file['part'] == 0 ? null : file['bvid_title'],
                          view: DateTime.fromMillisecondsSinceEpoch(
                            file['createdAt'],
                          ).toString().substring(0, 19),
                          color: isSelectionMode && selectedItems.contains(id)
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          onTap: isSelectionMode
                              ? () => _toggleItemSelection(id)
                              : () => AudioService.instance.then((x) =>
                                  x.playLocalAudio(file['bvid'], file['cid'])),
                          onAddToPlaylistButtonPressed: () => AudioService
                              .instance
                              .then((x) => x.addToPlaylistCachedAudio(
                                  file['bvid'], file['cid'])),
                          onLongPress: isSelectionMode
                              ? null
                              : () {
                                  if (!isSelectionMode) {
                                    _toggleSelectionMode();
                                    _toggleItemSelection(id);
                                  }
                                },
                        );
                      },
                    ),
            ),
      bottomNavigationBar: const PlayingCard(),
    );
  }
}
