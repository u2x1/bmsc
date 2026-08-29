import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/download_task.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/download_manager.dart';
import 'package:flutter/material.dart';
import '../component/track_tile.dart';
import '../component/playing_card.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  bool isSelectionMode = false;
  Set<String> selectedItems = {};
  final Map<String, Entity> _entityCache = {};
  Set<String> _taskIds = {};

  Future<void> _handleTasksChanged(Map<String, DownloadTask> tasks) async {
    final ids = tasks.keys.toSet();
    _entityCache.removeWhere((id, _) => !ids.contains(id));

    // Drop selection entries whose tasks disappeared
    if (selectedItems.any((id) => !ids.contains(id))) {
      setState(() {
        selectedItems.removeWhere((id) => !ids.contains(id));
        if (selectedItems.isEmpty) {
          isSelectionMode = false;
        }
      });
    }

    // Batch-fetch entities for new tasks only, progress updates reuse
    // the cache without hitting the database again.
    final missing = ids.where((id) => !_entityCache.containsKey(id)).toList();
    if (missing.isEmpty) return;
    await Future.wait(missing.map((id) async {
      final task = tasks[id]!;
      final entity = await DatabaseManager.getEntity(task.bvid, task.cid);
      if (entity != null) {
        _entityCache[id] = entity;
      }
    }));
    if (mounted) {
      setState(() {});
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
      } else {
        isSelectionMode = true;
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
            ? Text('${selectedItems.length} 项')
            : const Text('下载管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            onPressed: () async {
              final dm = await DownloadManager.instance;
              final tasks = (await dm.tasks).values.toList();
              final newSelectedItems =
                  tasks.map((task) => '${task.bvid}-${task.cid}').toSet();

              setState(() {
                selectedItems = newSelectedItems;
                isSelectionMode = true;
              });
            },
          ),
          if (isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.cancel),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('取消下载'),
                    content: Text('确定要取消这 ${selectedItems.length} 个下载任务吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          final dm = await DownloadManager.instance;
                          for (var id in selectedItems) {
                            await dm.cancelTask(id);
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
              icon: const Icon(Icons.pause),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () async {
                final dm = await DownloadManager.instance;
                for (var id in selectedItems) {
                  dm.pauseTask(id);
                }
                _toggleSelectionMode();
              },
            ),
            IconButton(
              icon: const Icon(Icons.play_arrow),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () async {
                final dm = await DownloadManager.instance;
                for (var id in selectedItems) {
                  await dm.resumeTask(id);
                }
                _toggleSelectionMode();
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
                          title: const Text('删除下载'),
                          content:
                              Text('确定要删除这 ${selectedItems.length} 个下载文件吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                final dm = await DownloadManager.instance;
                                for (var id in selectedItems) {
                                  final parts = id.split('-');
                                  await dm.cancelTask(id);
                                  await DatabaseManager.removeDownloaded(
                                      [(parts[0], int.parse(parts[1]))]);
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
          ],
        ],
      ),
      body: FutureBuilder(
          future: DownloadManager.instance,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final dm = snapshot.data!;
            return StreamBuilder<Map<String, DownloadTask>>(
              stream: dm.tasksStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final tasksMap = snapshot.data!;
                final tasks = tasksMap.values.toList().reversed.toList();
                tasks.sort((a, b) => Enum.compareByIndex(a.status, b.status));

                // Batch-fetch entities and prune stale selection when the
                // task set changes; progress-only updates reuse the cache.
                final ids = tasksMap.keys.toSet();
                if (_taskIds.length != ids.length ||
                    !ids.every(_taskIds.contains) ||
                    selectedItems.any((id) => !ids.contains(id))) {
                  _taskIds = ids;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _handleTasksChanged(tasksMap);
                  });
                }

                if (tasks.isEmpty) {
                  return Center(
                    child: ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.8,
                          child: const Center(child: Text('没有下载任务')),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final id = '${task.bvid}-${task.cid}';
                    final entity = _entityCache[id];
                    if (entity == null) {
                      return const SizedBox.shrink();
                    }

                    return TrackTile(
                      title: entity.partTitle,
                      author: entity.artist,
                      len: _getStatusText(task.status),
                      pic: entity.artUri,
                      album: entity.part == 0 ? null : entity.bvidTitle,
                      color: isSelectionMode
                          ? selectedItems.contains(id)
                              ? Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: 0.7)
                              : null
                          : _getColor(context, task.status)
                              .withValues(alpha: 0.3),
                      onTap: isSelectionMode
                          ? () => _toggleItemSelection(id)
                          : () async {
                              if (task.status == DownloadStatus.completed) {
                                final service = await AudioService.instance;
                                service.playLocalAudio(task.bvid, task.cid);
                              } else if (task.status ==
                                      DownloadStatus.downloading ||
                                  task.status == DownloadStatus.pending) {
                                (await DownloadManager.instance).pauseTask(id);
                              } else if (task.status == DownloadStatus.paused ||
                                  task.status == DownloadStatus.failed) {
                                (await DownloadManager.instance).resumeTask(id);
                              }
                            },
                      onPicTap: () => _toggleItemSelection(id),
                      onLongPress: isSelectionMode
                          ? null
                          : () {
                              if (!isSelectionMode) {
                                _toggleSelectionMode();
                                _toggleItemSelection(id);
                              }
                            },
                      progress: task.status == DownloadStatus.downloading ||
                              task.status == DownloadStatus.paused ||
                              task.status == DownloadStatus.pending
                          ? task.progress
                          : null,
                    );
                  },
                );
              },
            );
          }),
      bottomNavigationBar: const PlayingCard(),
    );
  }

  String _getStatusText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending:
        return '等待中';
      case DownloadStatus.downloading:
        return '下载中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '下载失败';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }

  Color _getColor(BuildContext context, DownloadStatus status) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (status) {
      case DownloadStatus.downloading:
        return colorScheme.primaryContainer;
      case DownloadStatus.paused:
        return colorScheme.surfaceContainerHighest;
      case DownloadStatus.pending:
        return colorScheme.tertiaryContainer;
      case DownloadStatus.completed:
        return colorScheme.secondaryContainer;
      case DownloadStatus.failed:
        return colorScheme.errorContainer;
      case DownloadStatus.canceled:
        return colorScheme.surfaceContainerHighest;
    }
  }
}
