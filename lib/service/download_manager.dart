import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/download_task.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/download_range_plan.dart';
import 'package:bmsc/util/logger.dart';
import 'package:path/path.dart' as path;
import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sqflite/sqflite.dart';

class DownloadManager {
  int maxConcurrentDownloads = 3;
  late String downloadPath;

  static final _logger = LoggerUtils.getLogger('DownloadManager');
  final _dio = Dio();
  final _downloadQueue = Queue<DownloadTask>();
  final _activeDownloads = <String>{};
  final _cancelTokens = <String, CancelToken>{};
  bool _processingQueue = false;

  final _taskController = BehaviorSubject<Map<String, DownloadTask>>.seeded({});

  static final instance = _instance();

  static Future<DownloadManager> _instance() async {
    final bili = await BilibiliService.instance;
    final instance = DownloadManager();
    instance.maxConcurrentDownloads =
        await SharedPreferencesService.getMaxConcurrentDownloads();
    SharedPreferencesService.maxConcurrentDownloadsStream.listen((value) {
      _logger.info('maxConcurrentDownloads changed to $value');
      instance.maxConcurrentDownloads = value;
      instance._processQueue();
    });

    // 下载路径变更即时生效：更新路径并重新调度队列，无需重启应用
    SharedPreferencesService.downloadPathStream.listen((value) {
      _logger.info('downloadPath changed to $value');
      instance.downloadPath = value;
      instance._processQueue();
    });

    // 下载走独立 Dio：补连接超时，防 CDN 握手挂死占住并发槽
    instance._dio.options.connectTimeout = const Duration(seconds: 15);
    instance._dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Merge the service's *current* headers (they change on
        // login/logout) rather than a snapshot taken at startup, and
        // preserve per-request headers (e.g. Range for resuming)
        options.headers = {...?bili.headers, ...options.headers};
        return handler.next(options);
      },
    ));
    instance._init();
    return instance;
  }

  Future<void> _init() async {
    downloadPath = await SharedPreferencesService.getDownloadPath();

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
    // 先中止在途下载并把任务移出队列/并发槽，否则刚被删除的记录可能
    // 被仍在收尾的下载事务重新写回（记录"复活"）。
    for (var (bvid, cid) in bvidscids) {
      final taskId = '$bvid-$cid';
      _cancelTokens.remove(taskId)?.cancel('Removed by user');
      _downloadQueue.removeWhere((t) => '${t.bvid}-${t.cid}' == taskId);
      _activeDownloads.remove(taskId);
    }

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

    // Delete files after the database operations (including leftover
    // .temp files from paused/interrupted downloads)
    for (final path in pathsToDelete) {
      if (path != null) {
        for (final p in [path, '$path.temp']) {
          final file = File(p);
          if (await file.exists()) {
            await file.delete();
            _logger.info('Removed file: $p');
          }
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
      task.error = null;
      await DatabaseManager.updateDownloadTaskStatus(
          bvid, cid, DownloadStatus.pending);
      // 清掉上次的失败原因，避免重试时旧报错残留在界面上
      await DatabaseManager.updateDownloadTaskError(bvid, cid, null);
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
      if (_downloadQueue.isEmpty) return;

      // Gate on actual writability of the download path instead of
      // Permission.storage: the app targets SDK 33+, so on Android 13+
      // the OS auto-denies WRITE_EXTERNAL_STORAGE without even showing
      // a dialog. The old permission gate therefore cleared the queue
      // on every Android 13+ device and left all tasks stuck in
      // "waiting" forever.
      if (Platform.isAndroid && !await _ensureDownloadPathWritable()) {
        // On Android 12 and below, granting WRITE_EXTERNAL_STORAGE
        // restores raw path access to shared storage, so ask once. On
        // Android 13+ this request is auto-denied (no dialog) and
        // scoped storage rules apply instead; the re-probe below
        // decides whether we can proceed.
        final status = await Permission.storage.status;
        if (!status.isGranted) {
          await Permission.storage.request();
        }
      }

      if (!await _ensureDownloadPathWritable()) {
        _logger.warning(
            'Download path not writable, failing queued tasks: $downloadPath');
        await _failQueuedTasks('无法写入下载目录，请到 设置 → 下载路径 更换目录后重试');
        return;
      }

      while (_activeDownloads.length < maxConcurrentDownloads &&
          _downloadQueue.isNotEmpty) {
        final task = _downloadQueue.removeFirst();
        final taskId = '${task.bvid}-${task.cid}';

        // Reserve a slot immediately after dequeuing so concurrently
        // triggered calls cannot exceed maxConcurrentDownloads.
        _activeDownloads.add(taskId);

        // Download in the background so up to maxConcurrentDownloads
        // tasks run at the same time; each task re-schedules the queue
        // when it finishes (success or failure).
        unawaited(_downloadTask(task));
      }
    } finally {
      _processingQueue = false;
    }
  }

  /// Download [task] in the background. Releases the task's concurrency
  /// slot and re-schedules the queue on every exit path.
  Future<void> _downloadTask(DownloadTask task) async {
    final taskId = '${task.bvid}-${task.cid}';
    try {
      final dbTask = await DatabaseManager.getDownloadTask(task.bvid, task.cid);
      if (dbTask == null) {
        _activeDownloads.remove(taskId);
        _processQueue();
        return;
      }

      // The task may have been paused/cancelled between being dequeued
      // and actually starting; only pending tasks may start.
      if (dbTask.status != DownloadStatus.pending) {
        _logger.info('Task $taskId is ${dbTask.status.name}, skipping');
        _activeDownloads.remove(taskId);
        _processQueue();
        return;
      }

      final fileName = '${task.bvid}-${task.cid}.m4a';
      final targetPath =
          path.join(downloadPath, fileName.replaceAll(' ', '-'));

      // Update the target path with a targeted column update: a full-row
      // REPLACE here would clobber a concurrently written pause/cancel
      // status with this task's stale in-memory state.
      task.targetPath = targetPath;
      await DatabaseManager.updateDownloadTaskTargetPath(
          task.bvid, task.cid, targetPath);

      // Atomically claim the task (pending -> downloading, clearing any
      // stale failure reason). Losing the race means the user paused or
      // cancelled it in the meantime; give up without touching status.
      final claimed = await DatabaseManager.tryMarkDownloadTaskDownloading(
          task.bvid, task.cid);
      if (!claimed) {
        _logger.info('Task $taskId no longer pending, skipping');
        _activeDownloads.remove(taskId);
        _processQueue();
        return;
      }

      task.status = DownloadStatus.downloading;
      final cancelToken = CancelToken();
      _cancelTokens[taskId] = cancelToken;
      task.cancelToken = cancelToken;

      final localPath =
          await DatabaseManager.getCachedPath(task.bvid, task.cid);
      if (localPath != null) {
        _logger
            .info('Cached file found, copying it to target path: $localPath');
        await File(localPath).copy(targetPath);

        // 拷贝窗口内用户可能暂停/取消：收尾前复核（否则刚被删除的
        // 下载记录会被后续写入"复活"）
        if (cancelToken.isCancelled) {
          _handleDownloadError(task, taskId, 'Download cancelled');
          return;
        }

        // 与正常完成路径一致：下载记录与任务完成态单事务落库
        final db = await DatabaseManager.database;
        await db.transaction((txn) async {
          await txn.insert(
            DatabaseManager.downloadTable,
            {
              'bvid': task.bvid,
              'cid': task.cid,
              'filePath': targetPath,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
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

        _activeDownloads.remove(taskId);
        _cancelTokens.remove(taskId);
        task.cancelToken = null;

        // Update the task controller with the latest tasks
        final updatedTasks = await tasks;
        _taskController.add(updatedTasks);

        _processQueue();
        return;
      }

      // Update the task controller with the latest tasks
      final updatedTasks = await tasks;
      _taskController.add(updatedTasks);

      _logger.info('Downloading ${task.bvid}-${task.cid}');

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
        // 416 (Range Not Satisfiable) means the temp file already holds
        // the entire file; handle it instead of failing the task.
        validateStatus: (status) =>
            status != null && (status < 300 || status == 416),
      );

      final response = await _dio
          .get(url, options: options, cancelToken: cancelToken)
          .timeout(const Duration(seconds: 60), onTimeout: () {
        _abortTask(task, taskId, '连接超时：服务器 60 秒内未响应');
        throw TimeoutException('download response timed out');
      });

      final body = response.data.stream as Stream<List<int>>;
      final plan = resolveDownloadRangePlan(
        startBytes: startBytes,
        statusCode: response.statusCode,
        contentRange: response.headers.value('content-range'),
        contentLength: response.headers.value('content-length'),
      );

      if (plan.mode == DownloadRangeMode.finalize) {
        // The temp file already contains the whole file (e.g. a previous
        // attempt died right before renaming): finalize it directly.
        _logger.info('Range not satisfiable, finalizing temp file');
        unawaited(body.drain<void>().catchError((_) {}));
      } else {
        if (plan.mode == DownloadRangeMode.restart && startBytes > 0) {
          // The server ignored the Range header and is sending the whole
          // file; appending that to the partial temp file would corrupt
          // the result, so restart from scratch.
          _logger.info('Server ignored Range header, restarting from 0');
          await File(tempPath).delete();
          startBytes = 0;
        }
        final resumed = plan.mode == DownloadRangeMode.resume;
        final totalBytes = plan.totalBytes;

        final file = File(tempPath);
        final raf =
            await file.open(mode: resumed ? FileMode.append : FileMode.write);

        int received = startBytes;
        double lastProgress = 0;
        double lastDbProgress = 0;
        int lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
        const progressThreshold = 0.01; // Update stream every 1% change
        const dbProgressThreshold = 0.05; // Persist to DB every 5% change
        const timeThreshold = 100; // Or every 100ms, whichever comes first
        const stallTimeout = Duration(seconds: 60);

        // Watchdog: without it a stalled connection keeps the task
        // "downloading" forever and holds a concurrency slot.
        Timer? stallTimer;
        void armStallTimer() {
          stallTimer?.cancel();
          stallTimer = Timer(stallTimeout, () {
            _abortTask(task, taskId,
                '下载超时：${stallTimeout.inSeconds} 秒未收到数据');
          });
        }

        armStallTimer();
        try {
          await for (final List<int> chunk in body) {
            armStallTimer();
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
                if ((progress - lastDbProgress).abs() >= dbProgressThreshold) {
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
          stallTimer?.cancel();
          await raf.close();
          _handleDownloadError(task, taskId, e);
          return;
        } finally {
          stallTimer?.cancel();
        }

        await raf.close();
      }

      if (cancelToken.isCancelled) {
        _handleDownloadError(task, taskId, 'Download cancelled');
        return;
      }

      try {
        // Remove any existing target file before renaming
        final targetFile = File(targetPath);
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        // Rename temp file to target file before database operations
        await File(tempPath).rename(targetPath);

        _logger.info('Download task ${task.bvid}-${task.cid} completed');

        // Re-check for a concurrent pause/cancel/remove right before
        // writing the completion records, so they cannot resurrect a
        // task that was just removed.
        if (cancelToken.isCancelled) {
          _handleDownloadError(task, taskId, 'Download cancelled');
          return;
        }

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
        return;
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
      return;
    }

    _processQueue();
  }

  /// Mark [taskId] as failed with [message] and abort its in-flight
  /// request. Unlike a user pause, the failure is persisted and shown;
  /// the subsequent cancel-delivered error is then treated as cleanup
  /// only (the status has already been set here).
  void _abortTask(DownloadTask task, String taskId, String message) {
    final token = _cancelTokens[taskId];
    if (token == null || token.isCancelled) return;
    task.status = DownloadStatus.failed;
    task.error = message;
    DatabaseManager.updateDownloadTaskStatus(
        task.bvid, task.cid, DownloadStatus.failed);
    DatabaseManager.updateDownloadTaskError(task.bvid, task.cid, message);
    _taskController.add({..._taskController.value, taskId: task});
    token.cancel(message);
  }

  /// Whether [downloadPath] is actually writable. A plain existence check
  /// is not enough: on scoped storage (Android 10+) the OS may reject
  /// raw path writes even for existing directories, so probe with a real
  /// write. Also creates the directory when missing.
  Future<bool> _ensureDownloadPathWritable() async {
    try {
      final dir = Directory(downloadPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File(path.join(downloadPath, '.write_probe'));
      await probe.writeAsString('probe');
      await probe.delete();
      return true;
    } catch (e) {
      _logger.warning('Download path "$downloadPath" is not writable: $e');
      return false;
    }
  }

  /// Mark every queued task as failed with [error]. Unlike the old
  /// behavior of silently clearing the queue, the user sees a failed
  /// state with the reason and can retry after fixing the cause.
  Future<void> _failQueuedTasks(String error) async {
    final queued = List<DownloadTask>.of(_downloadQueue);
    _downloadQueue.clear();

    for (final task in queued) {
      task.status = DownloadStatus.failed;
      task.error = error;
      await DatabaseManager.updateDownloadTaskStatus(
          task.bvid, task.cid, DownloadStatus.failed);
      await DatabaseManager.updateDownloadTaskError(
          task.bvid, task.cid, error);
    }

    // Merge the in-memory tasks (carrying the error text) over the fresh
    // DB snapshot so the failure reason reaches the UI.
    final updated = <String, DownloadTask>{...await tasks};
    for (final task in queued) {
      updated['${task.bvid}-${task.cid}'] = task;
    }
    _taskController.add(updated);
  }

  void dispose() {
    _taskController.close();
  }

  void _handleDownloadError(DownloadTask task, String taskId, dynamic error) {
    final cancelToken = _cancelTokens.remove(taskId);
    _activeDownloads.remove(taskId);
    task.cancelToken = null;

    if (cancelToken != null && cancelToken.isCancelled) {
      // Cancelled by pauseTask/cancelTask (status handled there) or by
      // _abortTask (failure already persisted); cleanup only.
      _processQueue();
      return;
    }

    // Update task status to failed (persist the reason too, so it
    // survives an app restart)
    task.status = DownloadStatus.failed;
    task.error = error.toString();
    DatabaseManager.updateDownloadTaskStatus(
        task.bvid, task.cid, DownloadStatus.failed);
    DatabaseManager.updateDownloadTaskError(task.bvid, task.cid, task.error);
    DatabaseManager.updateDownloadTaskProgress(
        task.bvid, task.cid, task.progress);
    _logger.severe('Download failed: $taskId', error);

    // Update the task controller
    _taskController.add({..._taskController.value, taskId: task});

    _processQueue();
  }
}
