import 'package:flutter/rendering.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/util/logger.dart';

final _logger = LoggerUtils.getLogger('ExcludedPartsDialog');

class ExcludedPartsDialog extends StatefulWidget {
  final String bvid;
  final String title;

  const ExcludedPartsDialog({
    super.key,
    required this.bvid,
    required this.title,
  });

  @override
  State<ExcludedPartsDialog> createState() => _ExcludedPartsDialogState();
}

class _ExcludedPartsDialogState extends State<ExcludedPartsDialog> {
  bool isLoading = true;
  bool hasError = false;
  List<Entity> entities = [];
  List<bool> modified = [];
  int excludeCnt = 0;
  Set<int> excludedParts = {};

  @override
  void initState() {
    super.initState();
    _loadExcludedParts();
  }

  Future<void> _loadExcludedParts() async {
    var es = await DatabaseManager.getEntities(widget.bvid);
    if (es.isEmpty) {
      _logger
          .info('entities of ${widget.bvid} not in cache, fetching from API');
      await (await BilibiliService.instance).getVidDetail(bvid: widget.bvid);
      es = await DatabaseManager.getEntities(widget.bvid);
    }

    final excludedCids = await DatabaseManager.getExcludedParts(widget.bvid);

    if (es.isNotEmpty) {
      setState(() {
        isLoading = false;
        entities = es;
        excludedParts = Set.from(excludedCids);
        excludeCnt = excludedCids.length;
        modified = List.filled(es.length, false);
      });
    } else {
      setState(() {
        isLoading = false;
        hasError = true;
        _logger.severe('Failed to load entities for ${widget.bvid}');
      });
    }
  }

  void _selectAll() {
    final modifiedCopy = List<bool>.from(modified);
    for (var i = 0; i < modified.length; i++) {
      final isExcluded = excludedParts.contains(entities[i].cid);
      modifiedCopy[i] = !isExcluded;
      excludeCnt += !isExcluded ? 0 : 1;
    }
    setState(() {
      modified = modifiedCopy;
      excludeCnt = entities.length;
    });
  }

  void _selectInvert() {
    final modifiedCopy = List<bool>.from(modified);
    int s = 0;
    for (var i = 0; i < modified.length; i++) {
      modifiedCopy[i] = !modified[i];
    }
    s = entities.length - excludeCnt;
    setState(() {
      modified = modifiedCopy;
      excludeCnt = s;
    });
  }

  Future<void> _saveChanges() async {
    for (var i = 0; i < modified.length; i++) {
      if (!modified[i]) continue;
      final isExcluded = excludedParts.contains(entities[i].cid);
      if (isExcluded) {
        await DatabaseManager.removeExcludedPart(widget.bvid, entities[i].cid);
      } else {
        await DatabaseManager.addExcludedPart(widget.bvid, entities[i].cid);
      }
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
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
            '${entities.length} 个分集，已跳过 $excludeCnt 个',
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
                onPressed: _selectAll,
              ),
              TextButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('反选'),
                onPressed: _selectInvert,
              ),
            ],
          ),
        ],
      ),
      content: isLoading
          ? const Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
            ])
          : hasError
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '无法加载分集信息，请稍后重试',
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                    shrinkWrap: true,
                    itemCount: entities.length,
                    itemBuilder: (context, index) {
                      final e = entities[index];
                      final isExcluded =
                          excludedParts.contains(e.cid) ^ modified[index];

                      return InkWell(
                        onTap: () {
                          setState(() {
                            modified[index] = !modified[index];
                            excludeCnt += isExcluded ? -1 : 1;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isExcluded
                                ? Theme.of(context)
                                    .colorScheme
                                    .errorContainer
                                    .withValues(alpha: 0.3)
                                : Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.3),
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
                                      style: TextStyle(
                                        fontSize: 12,
                                        decoration: isExcluded
                                            ? TextDecoration.lineThrough
                                            : null,
                                        color: isExcluded
                                            ? Theme.of(context)
                                                .colorScheme
                                                .error
                                            : null,
                                      ),
                                    ),
                                    Text(
                                      _formatDuration(e.duration),
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .secondary,
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
            await _saveChanges();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
