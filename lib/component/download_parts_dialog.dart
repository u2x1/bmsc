import 'package:flutter/rendering.dart';
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
  List<Entity> entities = [];
  List<bool> modified = [];
  List<bool> downloaded = [];
  List<DownloadTask?> downloadTasks = [];
  int downloadedCount = 0;
  int downloadingCount = 0;
  int addCount = 0;
  int removeCount = 0;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  Future<void> _loadParts() async {
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
    final downloadParts = await DatabaseManager.getDownloadedParts(widget.bvid);

    // Get download tasks
    final dm = await DownloadManager.instance;
    final allTasks = await dm.tasks;
    var dt = List<DownloadTask?>.filled(es.length, null);

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

    if (es.isNotEmpty) {
      setState(() {
        isLoading = false;
        modified = List.filled(es.length, false);
        entities = es;
        downloaded = dd;
        downloadTasks = dt;
      });
    }
  }

  void _toggleAll(bool include) {
    final modifiedCopy = List<bool>.from(modified);
    addCount = 0;
    removeCount = 0;
    if (include) {
      for (var i = 0; i < modified.length; i++) {
        modifiedCopy[i] = !downloaded[i];
        if (modifiedCopy[i]) {
          addCount++;
        }
      }
    } else {
      for (var i = 0; i < modified.length; i++) {
        modifiedCopy[i] = !modified[i];
        if (modifiedCopy[i]) {
          if (downloaded[i]) {
            removeCount++;
          } else {
            addCount++;
          }
        }
      }
    }
    setState(() {
      modified = modifiedCopy;
      addCount = addCount;
      removeCount = removeCount;
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

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return Colors.blue.shade100;
      case DownloadStatus.paused:
        return Colors.grey.shade100;
      case DownloadStatus.pending:
        return Colors.amber.shade100;
      case DownloadStatus.completed:
        return Colors.green.shade100;
      case DownloadStatus.failed:
        return Colors.red.shade100;
      case DownloadStatus.canceled:
        return Colors.grey.shade100;
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
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            '${entities.length} 个分集，已下载 $downloadedCount 个，下载中 $downloadingCount 个，欲下载 $addCount 个，欲移除 $removeCount 个',
            style: TextStyle(
              fontSize: 14,
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
          : SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                shrinkWrap: true,
                itemCount: entities.length,
                itemBuilder: (context, index) {
                  final e = entities[index];
                  final shouldDownload = downloaded[index] ^ modified[index];
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
                            ? _getStatusColor(downloadTask.status)
                                .withValues(alpha: 0.3)
                            : shouldDownload
                                ? Colors.green.shade100.withValues(alpha: 0.3)
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
                            backgroundColor:
                                Theme.of(context).colorScheme.primaryContainer,
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
                                  style: const TextStyle(
                                    fontSize: 12,
                                  ),
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
                                    backgroundColor: Colors.grey.shade200,
                                    valueColor: AlwaysStoppedAnimation<Color>(
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
          onPressed: () async {
            setState(() => isLoading = true);
            await _download();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
