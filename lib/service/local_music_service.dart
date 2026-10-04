import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/local_track.dart';
import 'package:bmsc/util/local_file_names.dart';
import 'package:bmsc/util/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

final _logger = LoggerUtils.getLogger('LocalMusicService');

/// 导入结果统计：新增 / 跳过（重复）/ 失败
typedef ImportResult = ({int added, int skipped, int failed});

/// 单文件导入产物（isolate 内生成）
class _ImportedFile {
  final String filePath;
  final String contentHash;
  final String title;
  final String artist;
  final String album;
  final int duration;
  final int fileSize;
  final String? coverPath;

  const _ImportedFile({
    required this.filePath,
    required this.contentHash,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.fileSize,
    required this.coverPath,
  });
}

/// isolate 入参
class _ImportJob {
  final String srcPath;
  final String destDir;
  final String coverDir;
  const _ImportJob(this.srcPath, this.destDir, this.coverDir);
}

/// 轻量内容哈希：文件大小 + 首尾各 64KB 的 SHA-256。
/// 全量哈希对百 MB 级无损文件太慢，首尾采样已足够区分日常曲目。
Future<String> _hashFile(File file) async {
  final length = await file.length();
  const sample = 64 * 1024;
  final raf = await file.open();
  try {
    final head = await raf.setPosition(0).then((_) => raf.read(sample));
    final tail = length > sample
        ? await raf.setPosition(length - sample).then((_) => raf.read(sample))
        : <int>[];
    return sha256
        .convert([...length.toString().codeUnits, ...head, ...tail])
        .toString();
  } finally {
    await raf.close();
  }
}

/// 在 isolate 中执行：复制入沙盒 → 哈希 → 解析元数据 → 抽取封面。
/// 任何一步失败都抛异常，由调用方计入失败数。
Future<_ImportedFile> _processFile(_ImportJob job) async {
  final src = File(job.srcPath);
  if (!await src.exists()) {
    throw StateError('源文件不存在: ${job.srcPath}');
  }
  final destDir = Directory(job.destDir);
  if (!destDir.existsSync()) destDir.createSync(recursive: true);

  final hash = await _hashFile(src);
  final safeName = sanitizeFileName(p.basename(job.srcPath));
  final destName = uniqueFileName(
      safeName, (candidate) => File(p.join(job.destDir, candidate)).existsSync());
  final destPath = p.join(job.destDir, destName);
  await src.copy(destPath);
  final dest = File(destPath);

  String title = titleFromFileName(destName);
  String artist = '未知艺术家';
  String album = '';
  int duration = 0;
  String? coverPath;

  try {
    final meta = readMetadata(dest, getImage: true);
    if (meta.title?.trim().isNotEmpty == true) title = meta.title!.trim();
    if (meta.artist?.trim().isNotEmpty == true) artist = meta.artist!.trim();
    album = meta.album?.trim() ?? '';
    duration = meta.duration?.inSeconds ?? 0;
    // 优先 front cover，否则第一张图
    Picture? picture;
    for (final pic in meta.pictures) {
      if (pic.pictureType == PictureType.coverFront) {
        picture = pic;
        break;
      }
      picture ??= pic;
    }
    if (picture != null && picture.bytes.isNotEmpty) {
      final coverDir = Directory(job.coverDir);
      if (!coverDir.existsSync()) coverDir.createSync(recursive: true);
      final ext = coverExtensionForMime(picture.mimetype);
      final file = File(p.join(job.coverDir, '$hash$ext'));
      await file.writeAsBytes(picture.bytes, flush: true);
      coverPath = file.path;
    }
  } catch (e) {
    // 元数据解析失败不阻塞导入（无标签文件仍可播放）
    _logger.info('metadata parse failed for $destPath: $e');
  }

  return _ImportedFile(
    filePath: destPath,
    contentHash: hash,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    fileSize: await dest.length(),
    coverPath: coverPath,
  );
}

/// 本地音乐曲库服务：导入（复制入沙盒 + 元数据抽取）、查询、删除、
/// 构建可接入统一播放队列的 AudioSource。
class LocalMusicService {
  /// 支持导入的音频扩展名（按平台能力过滤）：
  /// darwin（iOS/macOS）AVPlayer 不支持 ogg/opus，
  /// 其余平台（Android ExoPlayer / Linux、Windows media_kit）可以。
  static List<String> get supportedExtensions =>
      Platform.isIOS || Platform.isMacOS
          ? const ['mp3', 'flac', 'm4a', 'aac', 'wav', 'aiff', 'mp4']
          : const [
              'mp3', 'flac', 'm4a', 'aac', 'wav', 'aiff', 'mp4',
              'ogg', 'oga', 'opus',
            ];

  /// 是否支持设备曲库自动扫描。iOS 无共享文件系统
  ///（系统曲库经 MediaPlayer 框架访问且受保护，无法复制文件），
  /// 只能手动导入。
  static bool get supportsDeviceScan =>
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  /// 申请自动扫描所需权限：Android 13+ 为 READ_MEDIA_AUDIO，
  /// 旧版为 READ_EXTERNAL_STORAGE（任一获批即可）。
  /// 其余平台无需权限。
  static Future<bool> ensureScanPermission() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [Permission.audio, Permission.storage].request();
    return statuses[Permission.audio]?.isGranted == true ||
        statuses[Permission.storage]?.isGranted == true;
  }

  /// 自动扫描的默认根目录：
  /// - Android：公共 Music 与 Download 目录（Android/data 等私有目录
  ///   自 Android 11 起不可达，其他音乐 App 的私有下载无法扫描）
  /// - 桌面：系统 Music 目录
  static Future<List<Directory>> defaultScanRoots() async {
    if (Platform.isAndroid) {
      return [
        Directory('/storage/emulated/0/Music'),
        Directory('/storage/emulated/0/Download'),
      ];
    }
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return const [];
    return [Directory(p.join(home, 'Music'))];
  }

  /// 自动扫描设备曲库并导入。调用前需已通过 [ensureScanPermission]
  /// 获得权限；未授权时扫描结果会因逐文件读取失败而计入 failed。
  static Future<ImportResult> scanDevice(
      {void Function(int done, int total)? onProgress}) async {
    if (!supportsDeviceScan) {
      throw UnsupportedError('device scan not supported on this platform');
    }
    final exts = supportedExtensions.map((e) => '.$e').toSet();
    final paths = <String>[];
    const cap = 3000;
    for (final root in await defaultScanRoots()) {
      if (!root.existsSync()) continue;
      try {
        await for (final entity in root.list(recursive: true)) {
          if (entity is! File) continue;
          // 跳过隐藏目录/文件（.thumbnails、.Trash 等）
          final rel = p.relative(entity.path, from: root.path);
          if (rel.split(p.separator).any((seg) => seg.startsWith('.'))) {
            continue;
          }
          if (!exts.contains(p.extension(entity.path).toLowerCase())) continue;
          paths.add(entity.path);
          if (paths.length >= cap) break;
        }
      } catch (e) {
        _logger.warning('scan root failed: ${root.path}, $e');
      }
      if (paths.length >= cap) break;
    }
    paths.sort();
    _logger.info('device scan found ${paths.length} audio files');
    return importPaths(paths, onProgress: onProgress);
  }

  static Future<Directory> localMusicDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'local_music'));
  }

  static Future<Directory> _coversDir() async {
    final dir = await localMusicDir();
    return Directory(p.join(dir.path, 'covers'));
  }

  /// 文件选择器多选导入。
  static Future<ImportResult> importFiles(
      {void Function(int done, int total)? onProgress}) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
      allowMultiple: true,
    );
    if (result == null) return (added: 0, skipped: 0, failed: 0);
    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList(growable: false);
    return importPaths(paths, onProgress: onProgress);
  }

  /// 文件夹递归扫描导入。Android 的 getDirectoryPath 返回 content://
  /// URI，无法按路径扫描，调用方应在 Android 上隐藏该入口。
  static Future<ImportResult> importFolder(
      {void Function(int done, int total)? onProgress}) async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return (added: 0, skipped: 0, failed: 0);
    final exts = supportedExtensions.map((e) => '.$e').toSet();
    final paths = <String>[];
    try {
      await for (final entity in Directory(dirPath).list(recursive: true)) {
        if (entity is File &&
            exts.contains(p.extension(entity.path).toLowerCase())) {
          paths.add(entity.path);
          // 防御：超大目录不至于一次性卡死导入流程
          if (paths.length >= 2000) break;
        }
      }
    } catch (e) {
      _logger.warning('scan folder failed: $dirPath, $e');
    }
    paths.sort();
    return importPaths(paths, onProgress: onProgress);
  }

  /// 逐文件导入：复制入沙盒（isolate 内完成复制/哈希/元数据/封面），
  /// 内容哈希去重；重复文件清理复制产物后计入跳过。
  static Future<ImportResult> importPaths(List<String> paths,
      {void Function(int done, int total)? onProgress}) async {
    var added = 0, skipped = 0, failed = 0;
    if (paths.isEmpty) return (added: added, skipped: skipped, failed: failed);
    final destDir = (await localMusicDir()).path;
    final coverDir = (await _coversDir()).path;
    final knownHashes = await DatabaseManager.getLocalTrackHashes();

    for (var i = 0; i < paths.length; i++) {
      try {
        final imported =
            await compute(_processFile, _ImportJob(paths[i], destDir, coverDir));
        if (knownHashes.contains(imported.contentHash)) {
          skipped++;
          // 只删重复复制的音频文件；封面按内容哈希命名，与已入库
          // 曲目共用同一路径，删除会把已入库曲目的封面一并删掉
          await _deleteQuietly(File(imported.filePath));
        } else {
          final track = await DatabaseManager.insertLocalTrack(
            filePath: imported.filePath,
            contentHash: imported.contentHash,
            title: imported.title,
            artist: imported.artist,
            album: imported.album,
            duration: imported.duration,
            fileSize: imported.fileSize,
            coverPath: imported.coverPath,
          );
          if (track == null) {
            skipped++;
            // 同上：封面与已入库曲目共用，不可删
            await _deleteQuietly(File(imported.filePath));
          } else {
            knownHashes.add(imported.contentHash);
            added++;
          }
        }
      } catch (e) {
        _logger.warning('import failed: ${paths[i]}, $e');
        failed++;
      }
      onProgress?.call(i + 1, paths.length);
    }
    _logger.info('import done: +$added, skip $skipped, fail $failed');
    return (added: added, skipped: skipped, failed: failed);
  }

  /// 曲库列表。[pruneMissing] 时顺带清理文件已丢失的记录
  ///（用户在应用外删了文件的情况）。
  static Future<List<LocalTrack>> getTracks({
    bool pruneMissing = true,
    String orderBy = 'createdAt DESC',
  }) async {
    final tracks = await DatabaseManager.getLocalTracks(orderBy: orderBy);
    if (!pruneMissing) return tracks;
    final missing = <int>[];
    for (final t in tracks) {
      if (!File(t.filePath).existsSync()) missing.add(t.id);
    }
    if (missing.isNotEmpty) {
      _logger.info('prune ${missing.length} missing local tracks');
      await DatabaseManager.removeLocalTracks(missing);
      return tracks.where((t) => !missing.contains(t.id)).toList();
    }
    return tracks;
  }

  /// 删除曲目：DB 记录 + 音频文件 + 封面（封面可能被其他记录复用——
  /// 以内容哈希命名，剩余记录仍引用同一路径时不删）+ 播放统计。
  static Future<void> deleteTracks(List<LocalTrack> tracks) async {
    if (tracks.isEmpty) return;
    final removed =
        await DatabaseManager.removeLocalTracks(tracks.map((t) => t.id).toList());
    final remaining = await DatabaseManager.getLocalTracks();
    final usedCovers = remaining.map((t) => t.coverPath).whereType<String>().toSet();
    for (final t in removed) {
      await _deleteQuietly(File(t.filePath));
      final cover = t.coverPath;
      if (cover != null && !usedCovers.contains(cover)) {
        await _deleteQuietly(File(cover));
      }
      // 清理「最近在听」/本地历史中的统计记录（stat 键 local_<id>）
      await DatabaseManager.removePlayStat('local_${t.id}');
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      _logger.warning('delete file failed: ${file.path}, $e');
    }
  }

  /// 构建接入统一播放队列的音频源。extras 标记 local/filePath，
  /// 供去重、持久化与 UI 降级判断。
  static IndexedAudioSource buildSource(LocalTrack track) {
    final cover = track.coverPath;
    final hasCover = cover != null && File(cover).existsSync();
    return AudioSource.uri(
      Uri.file(track.filePath),
      tag: MediaItem(
        id: 'local_${track.id}',
        title: track.title,
        artist: track.artist,
        album: track.album.isEmpty ? null : track.album,
        artUri: hasCover ? Uri.file(cover) : null,
        duration:
            track.duration > 0 ? Duration(seconds: track.duration) : null,
        extras: {
          'local': true,
          'filePath': track.filePath,
        },
      ),
    );
  }
}
