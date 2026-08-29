import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../util/logger.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scrollController = ScrollController();
  final Set<LogRecord> _expandedLogs = {};

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Theme(
                data: Theme.of(context).copyWith(
                  canvasColor: theme.colorScheme.surface,
                ),
                child: DropdownButton<Level>(
                  value: Logger.root.level,
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  style: theme.textTheme.bodyMedium,
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
                            setState(() {});
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
        ],
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
              final log = logs[logs.length - index - 1];
              return ListTile(
                dense: true,
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
