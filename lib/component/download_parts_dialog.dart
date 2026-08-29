import 'dart:async';
import 'package:bmsc/model/download_task.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/download_manager.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/util/logger.dart';

final _logger = LoggerUtils.getLogger('DownloadPartsDialog');

class DownloadPartsDialog extends StatefulWidget {
  final String bvid;
  final String title;

  const DownloadPartsDialog({
    super.key,
    required this.bvid,
    required this.title,
  });

  @override
  State<DownloadPartsDialog> createState() => _DownloadPartsDialogState();
}

class _DownloadPartsDialogState extends State<DownloadPartsDialog> {
  bool isLoading = true;
  bool isSaving = false;
  String? loadError;
  List<Entity> entities = [];
  List<bool> modified = [];
  List<bool> downloaded = [];
  List<DownloadTask?> downloadTasks = [];
  int downloadedCount = 0;
  int downloadingCount = 0;
  int addCount = 0;
  int removeCount = 0;
  StreamSubscription<Map<String, DownloadTask>>? _tasksSubscription;

  @override
  void initState() {
    super.initState();
    _loadParts();
    DownloadManager.instance.then((dm) {
      _tasksSubscription = dm.tasksStream.listen(_onTasksChanged);
    });
  }

  @override
  void dispose() {
    _tasksSubscription?.cancel();
    super.dispose();
  }

  void _onTasksChanged(Map<String, DownloadTask> allTasks) {
    if (!mounted || entities.isEmpty) return;
    var downloading = 0;
    for (var i = 0; i < entities.length; i++) {
      final task = allTasks['${widget.bvid}-${entities[i].cid}'];
      downloadTasks[i] = task;
      if (task != null && task.status != DownloadStatus.completed) {
        downloading++;
      } else if (task != null &&
          task.status == DownloadStatus.completed &&
          !downloaded[i]) {
        // Part finished downloading while the dialog is open
        downloaded[i] = true;
        downloadedCount++;
      }
    }
    setState(() {
      downloadingCount = downloading;
    });
  }

  Future<void> _loadParts() async {
    try {
      var es = await DatabaseManager.getEntities(widget.bvid);
      var dd = List.filled(es.length, false);
      if (es.isEmpty) {
        _logger
            .info('entities of ${widget.bvid} not in cache, fetching from API');
        await (await BilibiliService.instance).getVidDetail(bvid: widget.bvid);
        es = await DatabaseManager.getEntities(widget.bvid);
        dd = List.filled(es.length, false);
      }

      // Get downloaded parts
      final downloadParts =
          await DatabaseManager.getDownloadedParts(widget.bvid);

      // Get download tasks
      final dm = await DownloadManager.instance;
      final allTasks = await dm.tasks;
      var dt = List<DownloadTask?>.filled(es.length, null);

      downloadedCount = 0;
      downloadingCount = 0;
      for (var i = 0; i < es.length; i++) {
        dd[i] = downloadParts.contains(es[i].cid);
        if (dd[i]) downloadedCount++;

        // Check if this part is in the download queue
        final taskId = '${widget.bvid}-${es[i].cid}';
        if (allTasks.containsKey(taskId)) {
          dt[i] = allTasks[taskId];
          if (dt[i]!.status != DownloadStatus.completed) {
            downloadingCount++;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        isLoading = false;
        loadError = null;
        modified = List.filled(es.length, false);
        entities = es;
        downloaded = dd;
        downloadTasks = dt;
      });
    } catch (e) {
      _logger.severe('Failed to load parts of ${widget.bvid}', e);
      if (!mounted) return;
      setState(() {
        isLoading = false;
        loadError = e.toString();
      });
    }
  }

  void _toggleAll(bool include) {
    bool isDownloading(int i) =>
        downloadTasks[i] != null &&
        downloadTasks[i]!.status != DownloadStatus.completed;

    setState(() {
      addCount = 0;
      removeCount = 0;
      if (include) {
        for (var i = 0; i < modified.length; i++) {
          // Skip downloading parts, mirroring the disabled item tap
          if (isDownloading(i)) {
            modified[i] = false;
            continue;
          }
          modified[i] = !downloaded[i];
          if (modified[i]) {
            addCount++;
          }
        }
      } else {
        for (var i = 0; i < modified.length; i++) {
          if (isDownloading(i)) {
            continue;
          }
          modified[i] = !modified[i];
          if (modified[i]) {
            if (downloaded[i]) {
              removeCount++;
            } else {
              addCount++;
            }
          }
        }
      }
    });
  }

  Future<void> _download() async {
    List<(String, int)> rm = [], add = [];
    for (var i = 0; i < modified.length; i++) {
      if (!modified[i]) continue;
      if (downloaded[i]) {
        rm.add((widget.bvid, entities[i].cid));
      } else {
        add.add((widget.bvid, entities[i].cid));
      }
    }
    _logger.info('remove $rm, add $add');
    final dm = await DownloadManager.instance;
    await dm.removeDownloaded(rm);
    await dm.addTasks(add);
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
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

  Color _getStatusColor(BuildContext context, DownloadStatus status) {
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '${entities.length} 个分集，已下载 $downloadedCount 个，下载中 $downloadingCount 个，欲下载 $addCount 个，欲移除 $removeCount 个',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
          ),
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('全选'),
                onPressed: () => _toggleAll(true),
              ),
              TextButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('反选'),
                onPressed: () => _toggleAll(false),
              ),
            ],
          ),
        ],
      ),
      content: isLoading
          ? const Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
            ])
          : loadError != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('加载失败: $loadError'),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                      onPressed: () {
                        setState(() {
                          isLoading = true;
                          loadError = null;
                        });
                        _loadParts();
                      },
                    ),
                  ],
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    itemCount: entities.length,
                    itemBuilder: (context, index) {
                      final e = entities[index];
                      final shouldDownload =
                          downloaded[index] ^ modified[index];
                      final downloadTask = downloadTasks[index];
                      final isDownloading = downloadTask != null &&
                          downloadTask.status != DownloadStatus.completed;

                      return InkWell(
                        onTap: isDownloading
                            ? null
                            : () {
                                setState(() {
                                  modified[index] = !modified[index];
                                  if (modified[index]) {
                                    if (downloaded[index]) {
                                      removeCount++;
                                    } else {
                                      addCount++;
                                    }
                                  } else {
                                    if (downloaded[index]) {
                                      removeCount--;
                                    } else {
                                      addCount--;
                                    }
                                  }
                                });
                              },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isDownloading
                                ? _getStatusColor(context, downloadTask.status)
                                    .withValues(alpha: 0.3)
                                : shouldDownload
                                    ? Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.3)
                                    : null,
                            border: Border(
                              bottom: BorderSide(
                                color: Theme.of(context).dividerColor,
                                width: 0.5,
                              ),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                child: Text('P${index + 1}'),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.partTitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                    Row(
                                      children: [
                                        Text(
                                          _formatDuration(e.duration),
                                          style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .secondary,
                                          ),
                                        ),
                                        if (isDownloading) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                            _getStatusText(downloadTask.status),
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .secondary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (downloadTask.status ==
                                              DownloadStatus.downloading) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              '${(downloadTask.progress * 100).toStringAsFixed(0)}%',
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .secondary,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ],
                                    ),
                                    if (isDownloading &&
                                        downloadTask.status ==
                                            DownloadStatus.downloading)
                                      LinearProgressIndicator(
                                        value: downloadTask.progress,
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Theme.of(context).colorScheme.primary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      actions: [
        TextButton(
          onPressed: () {
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: isSaving
              ? null
              : () async {
                  setState(() {
                    isSaving = true;
                    isLoading = true;
                  });
                  try {
                    await _download();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    _logger.severe('Failed to update download tasks', e);
                    if (context.mounted) {
                      setState(() {
                        isSaving = false;
                        isLoading = false;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('操作失败: $e')),
                      );
                    }
                  }
                },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
