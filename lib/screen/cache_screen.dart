import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../globals.dart' as globals;
import '../cache_manager.dart';
import 'dart:io';

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
          return title.contains(query) || artist.contains(query);
        }).toList();
      }
    });
  }

  Future<void> loadCachedFiles() async {
    final db = await CacheManager.database;
    final results = await db.query(
      CacheManager.tableName,
      orderBy: 'createdAt DESC',
    );

    setState(() {
      cachedFiles = results;
      filteredFiles = results; // Initialize filtered list with all files
      isLoading = false;
    });
  }

  String getFileSize(String filePath) {
    try {
      final file = File(filePath);
      final sizeInBytes = file.lengthSync();
      if (sizeInBytes < 1024 * 1024) {
        return '${(sizeInBytes / 1024).toStringAsFixed(2)} KB';
      }
      return '${(sizeInBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } catch (e) {
      return 'Unknown';
    }
  }

  Future<void> deleteCache(String id, String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      
      final db = await CacheManager.database;
      await db.delete(
        CacheManager.tableName,
        where: 'id = ?',
        whereArgs: [id],
      );

      setState(() {
        cachedFiles.removeWhere((item) => item['id'] == id);
      });
    } catch (e) {
    }
  }

  Future<void> clearAllCache() async {
    try {
      for (var file in cachedFiles) {
        await deleteCache(file['id'], file['filePath']);
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (isSearching) {
                _toggleSearch();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          title: isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '搜索标题或作者...',
                    hintStyle: const TextStyle(color: Colors.black54),
                    border: InputBorder.none,
                  )
                )
              : const Text('缓存管理'),
          actions: [
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
          ],
        ),
        body: isLoading
            ? const Center(child: CircularProgressIndicator())
            : filteredFiles.isEmpty
                ? Center(
                    child: Text(
                      _searchController.text.isEmpty
                          ? '没有缓存文件'
                          : '没有找到匹配的文件',
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredFiles.length,
                    itemBuilder: (context, index) {
                      final file = filteredFiles[index];
                      final fileSize = getFileSize(file['filePath']);

                      return Dismissible(
                        key: Key(file['id']),
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20.0),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        direction: DismissDirection.endToStart,
                        onDismissed: (direction) {
                          deleteCache(file['id'], file['filePath']);
                        },
                        child: trackTile(
                          pic: file['artUri'],
                          title: file['title'],
                          author: file['artist'],
                          len: fileSize,
                          view: DateTime.fromMillisecondsSinceEpoch(
                            file['createdAt'],
                          ).toString().substring(0, 19),
                          onTap: () => globals.api.playCachedAudio(file['bvid'], file['cid']),
                        ),
                      );
                    },
                  ),
      );
  }
}
