import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../util/logger.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scrollController = ScrollController();
  final Set<LogRecord> _expandedLogs = {};

  /// 范围选择模式：长按日志进入，第一次点选为起点，第二次点选为终点，
  /// 选中两点间的连续区间（含端点）；再次点选重新设置起点。
  bool _selectionMode = false;
  int? _anchorIndex;
  int? _endIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Color _getLevelColor(Level level) {
    if (level == Level.SEVERE) {
      return Colors.red;
    } else if (level == Level.WARNING) {
      return Colors.orange;
    } else if (level == Level.INFO) {
      return Colors.blue;
    } else {
      return Colors.grey;
    }
  }

  (int, int)? get _selectedRange {
    final anchor = _anchorIndex;
    if (anchor == null) return null;
    final end = _endIndex ?? anchor;
    return (anchor <= end) ? (anchor, end) : (end, anchor);
  }

  List<LogRecord> _selectedLogs() {
    final range = _selectedRange;
    if (range == null) return [];
    final logs = LoggerUtils.logs;
    final (start, end) = range;
    if (start < 0 || end >= logs.length) return [];
    return logs.sublist(start, end + 1);
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _anchorIndex = null;
      _endIndex = null;
    });
  }

  void _onEntryLongPress(int listIndex) {
    if (_selectionMode) return;
    setState(() {
      _selectionMode = true;
      _anchorIndex = listIndex;
      _endIndex = null;
    });
  }

  void _onEntryTap(int listIndex) {
    if (!_selectionMode) return;
    setState(() {
      // 已有完整范围 -> 重新设置起点；否则设置终点
      if (_anchorIndex == null || _endIndex != null) {
        _anchorIndex = listIndex;
        _endIndex = null;
      } else {
        _endIndex = listIndex;
      }
    });
  }

  bool _isSelected(int listIndex) {
    final range = _selectedRange;
    if (range == null) return false;
    return listIndex >= range.$1 && listIndex <= range.$2;
  }

  Future<void> _copyLogs([Iterable<LogRecord>? records]) async {
    final text = LoggerUtils.formatLogs(records);
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可复制的日志')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      final count = records?.length ?? LoggerUtils.logs.length;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已复制 $count 条日志')));
    }
  }

  Future<void> _shareLogs([Iterable<LogRecord>? records]) async {
    final text = LoggerUtils.formatLogs(records);
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可分享的日志')));
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/bmsc_logs_${DateTime.now().millisecondsSinceEpoch}.log');
      await file.writeAsString(text);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'BMSC 日志',
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('分享日志失败: $e')));
      }
    }
  }

  List<Widget> _buildActions() {
    if (_selectionMode) {
      final range = _selectedRange;
      final count = range != null ? range.$2 - range.$1 + 1 : 0;
      return [
        Center(
          child: Text('$count 条', style: const TextStyle(fontSize: 14)),
        ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: '复制选中日志',
          onPressed: () async {
            await _copyLogs(_selectedLogs());
            _exitSelectionMode();
          },
        ),
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: '分享选中日志',
          onPressed: () async {
            await _shareLogs(_selectedLogs());
            _exitSelectionMode();
          },
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出选择',
          onPressed: _exitSelectionMode,
        ),
      ];
    }
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Theme(
            data: Theme.of(context).copyWith(
              canvasColor: Theme.of(context).colorScheme.surface,
            ),
            child: DropdownButton<Level>(
              value: Logger.root.level,
              icon: const Icon(Icons.arrow_drop_down, size: 20),
              style: Theme.of(context).textTheme.bodyMedium,
              isDense: true,
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              items: Level.LEVELS.map((level) {
                return DropdownMenuItem(
                  alignment: AlignmentDirectional.centerStart,
                  value: level,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          level.name,
                          style: TextStyle(
                            color: _getLevelColor(level),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
              onChanged: (Level? newLevel) {
                if (newLevel != null) {
                  LoggerUtils.setLoggingLevel(newLevel);
                  setState(() {});
                }
              },
              underline: Container(),
              borderRadius: BorderRadius.circular(8),
              elevation: 4,
            ),
          ),
          const SizedBox(width: 16),
          Tooltip(
            message: '日志记录',
            child: Switch.adaptive(
              value: LoggerUtils.isLoggingEnabled,
              onChanged: (value) async {
                await LoggerUtils.setLoggingEnabled(value);
                setState(() {});
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部日志',
            onPressed: () => _copyLogs(),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享全部日志',
            onPressed: () => _shareLogs(),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空日志'),
                  content: const Text('确定要清空所有日志吗？'),
                  actions: [
                    TextButton(
                      child: const Text('取消'),
                      onPressed: () => Navigator.pop(context),
                    ),
                    FilledButton(
                      child: const Text('确定'),
                      onPressed: () {
                        LoggerUtils.clear();
                        _exitSelectionMode();
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '选择日志范围' : '日志'),
        actions: _buildActions(),
      ),
      body: StreamBuilder<LogRecord>(
        stream: LoggerUtils.logStream,
        builder: (context, _) {
          final logs = LoggerUtils.logs;

          if (logs.isEmpty) {
            return const Center(
              child: Text(
                '暂无日志',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
            );
          }

          return ListView.separated(
            controller: _scrollController,
            itemCount: logs.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final listIndex = logs.length - index - 1;
              final log = logs[listIndex];
              final selected = _selectionMode && _isSelected(listIndex);
              return ListTile(
                dense: true,
                selected: selected,
                selectedTileColor:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                onLongPress: () => _onEntryLongPress(listIndex),
                onTap: _selectionMode ? () => _onEntryTap(listIndex) : null,
                title: Text(
                  '${log.time.toString().substring(11, 19)} [${log.loggerName}] ${log.message}',
                  style: TextStyle(
                    fontSize: 12,
                    color: _getLevelColor(log.level),
                    fontFamily: 'monospace',
                  ),
                ),
                subtitle: log.error != null || log.stackTrace != null
                    ? GestureDetector(
                        onTap: () {
                          if (_selectionMode) {
                            _onEntryTap(listIndex);
                            return;
                          }
                          setState(() {
                            if (_expandedLogs.contains(log)) {
                              _expandedLogs.remove(log);
                            } else {
                              _expandedLogs.add(log);
                            }
                          });
                        },
                        child: Text(
                          '${log.error ?? ''}\n${log.stackTrace ?? ''}',
                          maxLines: _expandedLogs.contains(log) ? null : 3,
                          overflow: _expandedLogs.contains(log)
                              ? null
                              : TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      )
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
