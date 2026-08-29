import 'dart:collection';
import 'dart:io';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/download_task.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:path/path.dart' as path;
import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sqflite/sqflite.dart';

class DownloadManager {
  int maxConcurrentDownloads = 3;
  late final String downloadPath;

  static final _logger = LoggerUtils.getLogger('DownloadManager');
  final _dio = Dio();
  final _downloadQueue = Queue<DownloadTask>();
  final _activeDownloads = <String>{};
  final _cancelTokens = <String, CancelToken>{};
  bool _processingQueue = false;

  final _taskController = BehaviorSubject<Map<String, DownloadTask>>.seeded({});

  static final instance = _instance();

  static Future<DownloadManager> _instance() async {
    final headers = (await BilibiliService.instance).headers;
    final instance = DownloadManager();
    instance.maxConcurrentDownloads =
        await SharedPreferencesService.getMaxConcurrentDownloads();
    SharedPreferencesService.maxConcurrentDownloadsStream.listen((value) {
      _logger.info('maxConcurrentDownloads changed to $value');
      instance.maxConcurrentDownloads = value;
      instance._processQueue();
    });

    instance._dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Merge default headers instead of overwriting, so per-request
        // headers (e.g. Range for resuming downloads) are preserved
        options.headers = {...?headers, ...options.headers};
        return handler.next(options);
      },
    ));
    instance._init();
    return instance;
  }

  Future<void> _init() async {
    downloadPath = await SharedPreferencesService.getDownloadPath();
    final dir = Directory(downloadPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Load tasks from database
    await _loadTasksFromDatabase();
    _processQueue();
  }

  Future<void> _loadTasksFromDatabase() async {
    // Load completed downloads
    final downloads = await DatabaseManager.getAllDownloadTasks();
    final tasks = <String, DownloadTask>{};

    for (final task in downloads) {
      final taskId = '${task.bvid}-${task.cid}';

      // Tasks stuck in downloading state mean the process was killed
      // mid-download; reset them to pending so they can be resumed.
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.pending;
        await DatabaseManager.updateDownloadTaskStatus(
            task.bvid, task.cid, DownloadStatus.pending);
      }

      tasks[taskId] = task;

      // Add pending tasks to the queue
      if (task.status == DownloadStatus.pending) {
        _downloadQueue.add(task);
      }
    }

    _taskController.add(tasks);
  }

  Stream<Map<String, DownloadTask>> get tasksStream => _taskController.stream;

  Future<Map<String, DownloadTask>> get tasks async {
    final allTasks = await DatabaseManager.getAllDownloadTasks();
    final tasksMap = <String, DownloadTask>{};
    for (final task in allTasks) {
      tasksMap['${task.bvid}-${task.cid}'] = task;
    }
    return Map.unmodifiable(tasksMap);
  }

  Future<void> addBvidTasks(List<String> bvids) async {
    await Future.wait(bvids.map((bvid) async {
      final vid =
          await (await BilibiliService.instance).getVidDetail(bvid: bvid);
      if (vid == null) {
        return;
      }

      // Check each part individually so partially downloaded bvids
      // can still enqueue their missing parts
      final downloadedParts = await DatabaseManager.getDownloadedParts(bvid);

      for (var part in vid.pages) {
        if (downloadedParts.contains(part.cid)) {
          continue;
        }

        final existingTask =
            await DatabaseManager.getDownloadTask(bvid, part.cid);
        if (existingTask != null) {
          continue;
        }

        final task = DownloadTask(
          bvid: bvid,
          cid: part.cid,
          status: DownloadStatus.pending,
        );

        await DatabaseManager.saveDownloadTask(task);
        _downloadQueue.add(task);
      }

      // Update the task controller with the latest tasks
      final updatedTasks = await tasks;
      _taskController.add(updatedTasks);
    }));

    _processQueue();
  }

  Future<void> addTasks(List<(String, int)> bvidscids) async {
    for (var (bvid, cid) in bvidscids) {
      final existingTask = await DatabaseManager.getDownloadTask(bvid, cid);
      if (existingTask != null) {
        continue;
      }

      final task = DownloadTask(
        bvid: bvid,
        cid: cid,
        status: DownloadStatus.pending,
      );

      await DatabaseManager.saveDownloadTask(task);
      _downloadQueue.add(task);
    }

    // Update the task controller with the latest tasks
    final updatedTasks = await tasks;
    _taskController.add(updatedTasks);

    _processQueue();
  }

  Future<void> removeDownloaded(List<(String, int)> bvidscids) async {
    // First, get all paths outside the transaction
    final pathsToDelete = await Future.wait(bvidscids
        .map((tuple) => DatabaseManager.getDownloadPath(tuple.$1, tuple.$2)));

    // Handle the database operations in a transaction first, so the
    // records stay consistent even if file deletion fails afterwards
    final db = await DatabaseManager.database;
    await db.transaction((txn) async {
      for (var (bvid, cid) in bvidscids) {
        await txn.delete(
          DatabaseManager.downloadTable,
          where: 'bvid = ? AND cid = ?',
          whereArgs: [bvid, cid],
        );

        await txn.delete(
          DatabaseManager.downloadTaskTable,
          where: 'bvid = ? AND cid = ?',
          whereArgs: [bvid, cid],
        );
      }
    });

    // Delete files after the database operations
    for (final path in pathsToDelete) {
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          _logger.info('Removed downloaded file: $path');
        }
      }
    }

    // Update the task controller with the latest tasks
    final updatedTasks = await tasks;
    _taskController.add(updatedTasks);
  }

  Future<void> pauseTask(String taskId) async {
    final parts = taskId.split('-');
    if (parts.length != 2) return;

    final bvid = parts[0];
    final cid = int.tryParse(parts[1]);
    if (cid == null) return;

    final task = await DatabaseManager.getDownloadTask(bvid, cid);
    if (task == null) return;

    if (task.status == DownloadStatus.downloading) {
      // Cancel the real network stream via the in-memory token; the task
      // loaded from the database never carries a live token.
      _cancelTokens[taskId]?.cancel('Paused by user');
      task.status = DownloadStatus.paused;
      await DatabaseManager.updateDownloadTaskStatus(
          bvid, cid, DownloadStatus.paused);
      // Persist the latest in-memory progress
      await DatabaseManager.updateDownloadTaskProgress(
          bvid, cid, _taskController.value[taskId]?.progress ?? task.progress);
      _activeDownloads.remove(taskId);

      // Update the task controller with the latest tasks
      final updatedTasks = await tasks;
      _taskController.add(updatedTasks);

      _processQueue();
    } else if (task.status == DownloadStatus.pending) {
      await DatabaseManager.updateDownloadTaskStatus(
          bvid, cid, DownloadStatus.paused);
      _downloadQueue.removeWhere((t) => '${t.bvid}-${t.cid}' == taskId);

      // Update the task controller with the latest tasks
      final updatedTasks = await tasks;
      _taskController.add(updatedTasks);
    }
  }

  Future<void> resumeTask(String taskId) async {
    final parts = taskId.split('-');
    if (parts.length != 2) return;

    final bvid = parts[0];
    final cid = int.tryParse(parts[1]);
    if (cid == null) return;

    final task = await DatabaseManager.getDownloadTask(bvid, cid);
    if (task == null) return;

    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      task.status = DownloadStatus.pending;
      await DatabaseManager.updateDownloadTaskStatus(
          bvid, cid, DownloadStatus.pending);
      _downloadQueue.add(task);

      // Update the task controller with the latest tasks
      final updatedTasks = await tasks;
      _taskController.add(updatedTasks);

      _processQueue();
    }
  }

  Future<void> cancelTask(String taskId) async {
    final parts = taskId.split('-');
    if (parts.length != 2) return;

    final bvid = parts[0];
    final cid = int.tryParse(parts[1]);
    if (cid == null) return;

    final task = await DatabaseManager.getDownloadTask(bvid, cid);
    if (task == null) return;

    // Cancel the real network stream via the in-memory token
    _cancelTokens[taskId]?.cancel('Cancelled by user');

    // Remove the task from the database
    await DatabaseManager.removeDownloadTask(bvid, cid);

    _downloadQueue.removeWhere((t) => '${t.bvid}-${t.cid}' == taskId);
    _activeDownloads.remove(taskId);

    if (task.targetPath != null) {
      final file = File(task.targetPath!);
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = File('${task.targetPath}.temp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    // Update the task controller with the latest tasks
    final updatedTasks = await tasks;
    _taskController.add(updatedTasks);
  }

  Future<void> _processQueue() async {
    // Guard against concurrent triggers; the running loop re-evaluates
    // the queue condition on every iteration.
    if (_processingQueue) return;
    _processingQueue = true;
    try {
      // Check the storage permission once per scheduling round instead of
      // per task; clear the queue if it is not granted.
      if (Platform.isAndroid && _downloadQueue.isNotEmpty) {
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
        }
        if (!status.isGranted) {
          _logger.warning(
              'Storage permission not granted, clearing download queue');
          _downloadQueue.clear();
          return;
        }
      }

      while (_activeDownloads.length < maxConcurrentDownloads &&
          _downloadQueue.isNotEmpty) {
        final task = _downloadQueue.removeFirst();
        final taskId = '${task.bvid}-${task.cid}';

        // Reserve a slot immediately after dequeuing so concurrently
        // triggered calls cannot exceed maxConcurrentDownloads.
        _activeDownloads.add(taskId);

        final dbTask =
            await DatabaseManager.getDownloadTask(task.bvid, task.cid);
        if (dbTask == null) {
          _activeDownloads.remove(taskId);
          continue;
        }

        final fileName = '${task.bvid}-${task.cid}.m4a';
        final targetPath =
            path.join(downloadPath, fileName.replaceAll(' ', '-'));

        // Update the target path in the database
        task.targetPath = targetPath;
        await DatabaseManager.saveDownloadTask(task);

        final localPath =
            await DatabaseManager.getCachedPath(task.bvid, task.cid);
        if (localPath != null) {
          _logger
              .info('Cached file found, copying it to target path: $localPath');
          await File(localPath).copy(targetPath);

          // Update task status to completed
          await DatabaseManager.updateDownloadTaskStatus(
              task.bvid, task.cid, DownloadStatus.completed);
          await DatabaseManager.updateDownloadTaskProgress(
              task.bvid, task.cid, 1.0);

          // Save to downloads table
          await DatabaseManager.saveDownload(task.bvid, task.cid, targetPath);

          _activeDownloads.remove(taskId);

          // Update the task controller with the latest tasks
          final updatedTasks = await tasks;
          _taskController.add(updatedTasks);

          continue;
        }

        // Update task status to downloading
        await DatabaseManager.updateDownloadTaskStatus(
            task.bvid, task.cid, DownloadStatus.downloading);
        task.status = DownloadStatus.downloading;
        final cancelToken = CancelToken();
        _cancelTokens[taskId] = cancelToken;
        task.cancelToken = cancelToken;

        // Update the task controller with the latest tasks
        final updatedTasks = await tasks;
        _taskController.add(updatedTasks);

        _logger.info('Downloading ${task.bvid}-${task.cid}');

        try {
          final audios = await (await BilibiliService.instance)
              .getAudio(task.bvid, task.cid);
          final url = audios?.first.baseUrl;
          if (url == null) {
            throw Exception('Failed to get audio URL');
          }

          final tempPath = '$targetPath.temp';
          int startBytes = 0;

          if (await File(tempPath).exists()) {
            startBytes = await File(tempPath).length();
            _logger.info('Resuming download from $startBytes bytes');
          }

          final options = Options(
            headers: {
              'Range': 'bytes=$startBytes-',
            },
            responseType: ResponseType.stream,
          );

          final response = await _dio.get(
            url,
            options: options,
            cancelToken: cancelToken,
          );

          final total =
              int.tryParse(response.headers.value('content-length') ?? '') ??
                  -1;
          final contentRange = response.headers.value('content-range');
          final totalBytes = contentRange != null
              ? int.tryParse(contentRange.split('/').last) ?? total + startBytes
              : total + startBytes;

          final file = File(tempPath);
          final raf = await file.open(mode: FileMode.append);

          int received = startBytes;
          double lastProgress = 0;
          double lastDbProgress = 0;
          int lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
          const progressThreshold = 0.01; // Update stream every 1% change
          const dbProgressThreshold = 0.05; // Persist to DB every 5% change
          const timeThreshold = 100; // Or every 100ms, whichever comes first

          try {
            await for (final List<int> chunk in response.data.stream) {
              await raf.writeFrom(chunk);
              received += chunk.length;
              if (totalBytes != -1) {
                final progress = received / totalBytes;
                final now = DateTime.now().millisecondsSinceEpoch;
                final timeDiff = now - lastUpdateTime;

                // Update if progress changed significantly or enough time has passed
                if ((progress - lastProgress).abs() >= progressThreshold ||
                    timeDiff >= timeThreshold) {
                  task.progress = progress;

                  // Update the task controller at full frequency
                  _taskController.add({..._taskController.value, taskId: task});

                  // Persist progress to the database at a lower frequency
                  if ((progress - lastDbProgress).abs() >=
                      dbProgressThreshold) {
                    DatabaseManager.updateDownloadTaskProgress(
                        task.bvid, task.cid, progress);
                    lastDbProgress = progress;
                  }

                  lastProgress = progress;
                  lastUpdateTime = now;
                }
              }
            }
          } catch (e) {
            await raf.close();
            _handleDownloadError(task, taskId, e);
            continue;
          }

          await raf.close();

          if (cancelToken.isCancelled) {
            _handleDownloadError(task, taskId, 'Download cancelled');
            continue;
          }

          try {
            // Remove any existing target file before renaming
            final targetFile = File(targetPath);
            if (await targetFile.exists()) {
              await targetFile.delete();
            }
            // Rename temp file to target file before database operations
            await file.rename(targetPath);

            _logger.info('Download task ${task.bvid}-${task.cid} completed');

            // Use a single transaction for all database operations
            final db = await DatabaseManager.database;
            await db.transaction((txn) async {
              // Save to downloads table
              await txn.insert(
                DatabaseManager.downloadTable,
                {
                  'bvid': task.bvid,
                  'cid': task.cid,
                  'filePath': targetPath,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );

              // Update task status to completed
              await txn.update(
                DatabaseManager.downloadTaskTable,
                {
                  'status': DownloadStatus.completed.index,
                  'progress': 1.0,
                },
                where: 'bvid = ? AND cid = ?',
                whereArgs: [task.bvid, task.cid],
              );
            });
          } catch (e) {
            _handleDownloadError(task, taskId, e);
            continue;
          }

          _activeDownloads.remove(taskId);
          _cancelTokens.remove(taskId);
          task.cancelToken = null;

          // Update the task controller with the latest tasks
          final allTasks = await DatabaseManager.getAllDownloadTasks();
          _taskController.add(Map.fromEntries(
              allTasks.map((t) => MapEntry('${t.bvid}-${t.cid}', t))));
        } catch (e) {
          _handleDownloadError(task, taskId, e);
        }
      }
    } finally {
      _processingQueue = false;
    }
  }

  void dispose() {
    _taskController.close();
  }

  void _handleDownloadError(DownloadTask task, String taskId, dynamic error) {
    final cancelToken = _cancelTokens.remove(taskId);
    _activeDownloads.remove(taskId);
    task.cancelToken = null;

    if (cancelToken != null && cancelToken.isCancelled) {
      // Cancelled by pauseTask/cancelTask; the status is handled there
      _processQueue();
      return;
    }

    // Update task status to failed
    DatabaseManager.updateDownloadTaskStatus(
        task.bvid, task.cid, DownloadStatus.failed);
    DatabaseManager.updateDownloadTaskProgress(
        task.bvid, task.cid, task.progress);
    task.status = DownloadStatus.failed;
    task.error = error.toString();
    _logger.severe('Download failed: $taskId', error);

    // Update the task controller
    _taskController.add({..._taskController.value, taskId: task});

    _processQueue();
  }
}
