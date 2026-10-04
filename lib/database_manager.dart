import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path/path.dart';
import '../model/fav.dart';
import '../model/fav_detail.dart';
import '../model/meta.dart';
import '../model/play_stat.dart';
import '../util/recent_picks.dart';
import 'dart:math' as math;
import 'package:bmsc/util/logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bmsc/model/download_task.dart';

final _logger = LoggerUtils.getLogger('DatabaseManager');

const String _dbName = 'AudioCache.db';

class DatabaseManager {
  static Database? _database;
  static const String cacheTable = 'audio_cache';
  static const String downloadTable = 'audio_download';
  static const String metaTable = 'meta_cache';
  static const String favListVideoTable = 'fav_list_video';
  static const String collectedFavListVideoTable = 'collected_fav_list_video';
  static const String collectedFavListTable = 'collected_fav_list';
  static const String entityTable = 'entity_cache';
  static const String favListTable = 'fav_list';
  static const String favDetailTable = 'fav_detail';
  static const String downloadTaskTable = 'download_tasks';
  static const String excludedPartsTable = 'excluded_parts';
  static const String statTable = 'play_stat';

  /// 收藏夹内容变更版本号：addFav/rmFav 实际改库后自增。
  /// 主页收藏夹列表监听它重读本地缓存，使收藏/取消收藏后
  /// 收藏夹的媒体计数与封面堆叠无需网络刷新即即时更新
  static final ValueNotifier<int> favListVersion = ValueNotifier(0);

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDB();
    return _database!;
  }

  static Future<Database> initDB() async {
    // Initialize FFI for Linux
    if (Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    String path;
    if (Platform.isLinux) {
      // Use standard XDG data directory for Linux
      final home = Platform.environment['HOME'];
      if (home == null) {
        throw Exception('Could not find HOME directory');
      }
      final dataDir = Directory('$home/.local/share/bmsc');
      // Create directory if it doesn't exist
      if (!await dataDir.exists()) {
        await dataDir.create(recursive: true);
      }
      path = join(dataDir.path, _dbName);
    } else {
      Directory documentsDirectory = await getApplicationDocumentsDirectory();
      path = join(documentsDirectory.path, _dbName);
    }

    try {
      final db = await openDatabase(
        path,
        version: 9,
        onCreate: (db, version) async {
          _logger.info('Creating new database tables...');
          await db.execute('''
          CREATE TABLE $cacheTable (
            bvid TEXT,
            cid INTEGER,
            filePath TEXT,
            fileSize INTEGER,
            playCount INTEGER DEFAULT 0,
            lastPlayed INTEGER,
            createdAt INTEGER,
            PRIMARY KEY (bvid, cid)
          )
        ''');

          await db.execute('''
          CREATE TABLE $entityTable (
            aid INTEGER,
            cid INTEGER,
            bvid TEXT,
            artist TEXT,
            part INTEGER,
            duration INTEGER,
            part_title TEXT,
            bvid_title TEXT,
            art_uri TEXT,
            PRIMARY KEY (bvid, cid)
          )
        ''');

          await db.execute('''
          CREATE TABLE $excludedPartsTable (
            bvid TEXT,
            cid INTEGER,
            PRIMARY KEY (bvid, cid)
          )
        ''');

          await db.execute('''
          CREATE TABLE $metaTable (
            bvid TEXT PRIMARY KEY,
            aid INTEGER,
            title TEXT,
            artist TEXT,
            artUri TEXT,
            mid INTEGER,
            duration INTEGER,
            parts INTEGER,
            list_order INTEGER
          )
        ''');

          await db.execute('''
          CREATE TABLE $favListVideoTable (
            bvid TEXT,
            mid INTEGER,
            PRIMARY KEY (bvid, mid)
          )
        ''');

          await db.execute('''
          CREATE TABLE $favListTable (
            id INTEGER PRIMARY KEY,
            title TEXT,
            mediaCount INTEGER,
            cover TEXT,
            list_order INTEGER,
            synced_count INTEGER DEFAULT -1
          )
        ''');

          await db.execute('''
          CREATE TABLE $favDetailTable (
            id INTEGER,
            title TEXT,
            cover TEXT,
            page INTEGER,
            duration INTEGER,
            upper_name TEXT,
            play_count INTEGER,
            bvid TEXT,
            fav_id INTEGER,
            list_order INTEGER,
            PRIMARY KEY (id, fav_id)
          )
        ''');

          await db.execute('''
          CREATE TABLE $collectedFavListTable (
            id INTEGER PRIMARY KEY,
            title TEXT,
            mediaCount INTEGER,
            cover TEXT,
            list_order INTEGER,
            synced_count INTEGER DEFAULT -1
          )
        ''');

          await db.execute('''
          CREATE TABLE $collectedFavListVideoTable (
            bvid TEXT,
            mid INTEGER,
            PRIMARY KEY (bvid, mid)
          )
        ''');

          await db.execute('''
          CREATE TABLE IF NOT EXISTS $downloadTable (
            bvid TEXT,
            cid INTEGER,
            filePath TEXT,
            PRIMARY KEY (bvid, cid)
          )
        ''');

          await db.execute('''
          CREATE TABLE IF NOT EXISTS $downloadTaskTable (
            bvid TEXT,
            cid INTEGER,
            targetPath TEXT,
            status INTEGER,
            progress REAL,
            error TEXT,
            PRIMARY KEY (bvid, cid)
          )
        ''');

          await db.execute('''
          CREATE TABLE IF NOT EXISTS $statTable (
            bvid TEXT PRIMARY KEY,
            last_played INTEGER,
            total_play_time INTEGER DEFAULT 0,
            play_count INTEGER DEFAULT 0,
            last_cid INTEGER
          )
        ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          _logger.info('Upgrading database from v$oldVersion to v$newVersion');

          if (oldVersion <= 8) {
            // play_stat 新增 last_cid 列：记录每首歌最近播放的分 P，
            // 供「最近在听」点击时定位续播（而非从 P1 重头开始）
            await db
                .execute('ALTER TABLE $statTable ADD COLUMN last_cid INTEGER');
          }

          if (oldVersion <= 7) {
            // 收藏夹/收藏合集列表新增 synced_count 列：记录上次全量同步
            //（网络完整拉取并替换视频缓存）时的条数，供详情页判断本地
            // 缓存是否完整（封面补拉只写入第一页，不代表全量）
            await db.execute(
                'ALTER TABLE $favListTable ADD COLUMN synced_count INTEGER DEFAULT -1');
            await db.execute(
                'ALTER TABLE $collectedFavListTable ADD COLUMN synced_count INTEGER DEFAULT -1');
          }

          if (oldVersion <= 6) {
            // 收藏夹列表新增 cover 列：缓存列表 API 返回的收藏夹自身封面，
            // 供主页网格拼贴兜底
            await db.execute('ALTER TABLE $favListTable ADD COLUMN cover TEXT');
            await db.execute(
                'ALTER TABLE $collectedFavListTable ADD COLUMN cover TEXT');
          }

          if (oldVersion <= 5) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS $statTable (
                bvid TEXT PRIMARY KEY,
                last_played INTEGER,
                total_play_time INTEGER DEFAULT 0,
                play_count INTEGER DEFAULT 0
              )
            ''');
          }

          if (oldVersion <= 4) {
            await db.transaction((txn) async {
              try {
                await txn.execute('''
                  CREATE TABLE IF NOT EXISTS $excludedPartsTable (
                    bvid TEXT,
                    cid INTEGER,
                    PRIMARY KEY (bvid, cid)
                  )
                ''');

                await txn.execute('''
                  INSERT INTO $excludedPartsTable (bvid, cid)
                  SELECT bvid, cid FROM $entityTable WHERE excluded = 1
                ''');

                await txn.execute('''
                  CREATE TABLE ${entityTable}_new (
                    aid INTEGER,
                    cid INTEGER,
                    bvid TEXT,
                    artist TEXT,
                    part INTEGER,
                    duration INTEGER,
                    part_title TEXT,
                    bvid_title TEXT,
                    art_uri TEXT,
                    PRIMARY KEY (bvid, cid)
                  )
                ''');

                await txn.execute('''
                  INSERT INTO ${entityTable}_new (aid, cid, bvid, artist, part, duration, part_title, bvid_title, art_uri)
                  SELECT aid, cid, bvid, artist, part, duration, part_title, bvid_title, art_uri FROM $entityTable
                ''');

                final oldCount = Sqflite.firstIntValue(
                    await txn.rawQuery('SELECT COUNT(*) FROM $entityTable'));
                final newCount = Sqflite.firstIntValue(await txn
                    .rawQuery('SELECT COUNT(*) FROM ${entityTable}_new'));

                if (oldCount != newCount) {
                  throw Exception(
                      'Migration integrity check failed: data count mismatch');
                }

                await txn.execute('DROP TABLE $entityTable');
                await txn.execute(
                    'ALTER TABLE ${entityTable}_new RENAME TO $entityTable');
              } catch (e) {
                _logger.severe('Database migration failed', e);
                rethrow;
              }
            });
          }

          if (oldVersion <= 3) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS $downloadTaskTable (
                bvid TEXT,
                cid INTEGER,
                targetPath TEXT,
                status INTEGER,
                progress REAL,
                error TEXT,
                PRIMARY KEY (bvid, cid)
              )
            ''');
          }

          if (oldVersion <= 2) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS $downloadTable (
                bvid TEXT,
                cid INTEGER,
                filePath TEXT,
                PRIMARY KEY (bvid, cid)
              )
            ''');
          }

          if (oldVersion <= 1) {
            await db.transaction((txn) async {
              await txn.execute('''
                CREATE TABLE ${cacheTable}_new (
                  bvid TEXT,
                  cid INTEGER,
                  filePath TEXT,
                  fileSize INTEGER,
                  playCount INTEGER DEFAULT 0,
                  lastPlayed INTEGER,
                  createdAt INTEGER,
                  PRIMARY KEY (bvid, cid)
                )
              ''');

              await txn.execute('''
                INSERT INTO ${cacheTable}_new (bvid, cid, filePath, createdAt)
                SELECT bvid, cid, filePath, createdAt
                FROM $cacheTable
              ''');

              final rows = await txn.query('${cacheTable}_new');
              final batch = txn.batch();

              for (final row in rows) {
                final filePath = row['filePath'] as String;
                final file = File(filePath);
                int fileSize = 0;
                try {
                  if (await file.exists()) {
                    fileSize = await file.length();
                  }
                } catch (e) {
                  _logger.warning('Failed to get file size for $filePath: $e');
                }

                batch.update(
                  '${cacheTable}_new',
                  {
                    'fileSize': fileSize,
                    'playCount': 0,
                    'lastPlayed': DateTime.now().millisecondsSinceEpoch,
                  },
                  where: 'bvid = ? AND cid = ?',
                  whereArgs: [row['bvid'] as String, row['cid'] as int],
                );
              }

              await batch.commit();
              await txn.execute('DROP TABLE $cacheTable');
              await txn.execute(
                  'ALTER TABLE ${cacheTable}_new RENAME TO $cacheTable');
            });
          }
        },
      );
      return db;
    } catch (e, stackTrace) {
      _logger.severe('Failed to initialize database', e, stackTrace);
      rethrow;
    }
  }

  static Future<void> addExcludedPart(String bvid, int cid) async {
    final db = await database;
    await db.insert(
      excludedPartsTable,
      {'bvid': bvid, 'cid': cid},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> removeExcludedPart(String bvid, int cid) async {
    final db = await database;
    await db.delete(
      excludedPartsTable,
      where: 'bvid = ? AND cid = ?',
      whereArgs: [bvid, cid],
    );
  }

  static Future<List<int>> getExcludedParts(String bvid) async {
    final db = await database;
    final results = await db.query(
      excludedPartsTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
    return results.map((row) => row['cid'] as int).toList();
  }

  static Future<void> cacheMetas(List<Meta> metas) async {
    _logger.info('Caching ${metas.length} metas');
    try {
      final db = await database;
      final batch = db.batch();
      for (int i = 0; i < metas.length; i++) {
        var json = metas[i].toJson();
        json['list_order'] = i;
        batch.insert(metaTable, json,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit();
      _logger.info('cached ${metas.length} metas');
    } catch (e, stackTrace) {
      _logger.severe('Failed to cache metas', e, stackTrace);
      rethrow;
    }
  }

  static Future<Meta?> getMeta(String bvid) async {
    final db = await database;
    final results =
        await db.query(metaTable, where: 'bvid = ?', whereArgs: [bvid]);
    final ret = results.firstOrNull;
    if (ret == null) {
      return null;
    }
    return Meta.fromJson(ret);
  }

  static Future<List<Meta>> getMetas(List<String> bvids) async {
    if (bvids.isEmpty) {
      _logger.info('No bvids to fetch');
      return [];
    }
    _logger.info('Fetching ${bvids.length} metas from cache');
    try {
      final db = await database;
      const int chunkSize = 500;
      final List<Meta> allResults = [];

      for (var i = 0; i < bvids.length; i += chunkSize) {
        final chunk = bvids.sublist(i, math.min(i + chunkSize, bvids.length));
        final placeholders = List.filled(chunk.length, '?').join(',');
        final orderString = ',${chunk.join(',')},';

        final results = await db.rawQuery('''
          SELECT * FROM $metaTable 
          WHERE bvid IN ($placeholders)
          ORDER BY INSTR(?, ',' || bvid || ',')
        ''', [...chunk, orderString]);

        allResults.addAll(results.map((e) => Meta.fromJson(e)));
      }

      _logger.info('Retrieved ${allResults.length} metas from cache');
      return allResults;
    } catch (e, stackTrace) {
      _logger.severe('Failed to get metas from cache', e, stackTrace);
      rethrow;
    }
  }

  static Future<void> cacheEntities(List<Entity> data) async {
    final db = await database;
    final batch = db.batch();
    for (var item in data) {
      batch.insert(entityTable, item.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit();
    _logger.info('cached ${data.length} entities');
  }

  static Future<Entity?> getEntity(String bvid, int cid) async {
    final db = await database;
    final results = await db.query(
      entityTable,
      where: 'bvid = ? AND cid = ?',
      whereArgs: [bvid, cid],
    );
    return results.firstOrNull != null
        ? Entity.fromJson(results.firstOrNull!)
        : null;
  }

  static Future<List<Entity>> getEntities(String bvid) async {
    final db = await database;
    final results = await db.query(
      entityTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
      orderBy: 'part ASC',
    );
    return results.map((e) => Entity.fromJson(e)).toList();
  }

  static Future<int> cachedCount(String bvid) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $cacheTable WHERE bvid = ?',
      [bvid],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  static Future<int> downloadedCount(String bvid) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $downloadTable WHERE bvid = ?',
      [bvid],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 批量获取多个视频的「排除分P / 已缓存数 / 已下载数」，
  /// 供收藏夹详情页一次性加载，替代每视频 3 条查询的 N+1 模式。
  /// IN 查询按 500 个 bvid 分块，避免超出 SQLite 变量上限。
  static Future<Map<String, (List<int>, int, int)>> getItemInfos(
      List<String> bvids) async {
    final result = <String, (List<int>, int, int)>{};
    if (bvids.isEmpty) return result;
    final db = await database;
    final excludedMap = <String, List<int>>{};
    final cachedMap = <String, int>{};
    final downloadedMap = <String, int>{};

    const chunkSize = 500;
    for (var i = 0; i < bvids.length; i += chunkSize) {
      final chunk = bvids.sublist(i, math.min(i + chunkSize, bvids.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      for (final row in await db.rawQuery(
        'SELECT bvid, cid FROM $excludedPartsTable WHERE bvid IN ($placeholders)',
        chunk,
      )) {
        excludedMap
            .putIfAbsent(row['bvid'] as String, () => [])
            .add(row['cid'] as int);
      }
      for (final row in await db.rawQuery(
        'SELECT bvid, COUNT(*) AS count FROM $cacheTable WHERE bvid IN ($placeholders) GROUP BY bvid',
        chunk,
      )) {
        cachedMap[row['bvid'] as String] = row['count'] as int;
      }
      for (final row in await db.rawQuery(
        'SELECT bvid, COUNT(*) AS count FROM $downloadTable WHERE bvid IN ($placeholders) GROUP BY bvid',
        chunk,
      )) {
        downloadedMap[row['bvid'] as String] = row['count'] as int;
      }
    }

    for (final bvid in bvids) {
      result[bvid] = (
        excludedMap[bvid] ?? const [],
        cachedMap[bvid] ?? 0,
        downloadedMap[bvid] ?? 0,
      );
    }
    return result;
  }

  static Future<String?> getCachedPath(String bvid, int cid) async {
    final db = await database;
    final results = await db.query(
      cacheTable,
      where: "bvid = ? AND cid = ?",
      columns: ['filePath'],
      whereArgs: [bvid, cid],
    );
    return results.firstOrNull?['filePath'] as String?;
  }

  static Future<List<LazyAudioSource>?> getLocalAudioList(String bvid) async {
    final meta = await getMeta(bvid);
    if (meta == null) {
      return null;
    }

    final db = await database;
    var results = await db.query(
      downloadTable,
      where: "bvid = ?",
      whereArgs: [bvid],
    );

    if (results.isEmpty) {
      results = await db.query(
        cacheTable,
        where: "bvid = ?",
        whereArgs: [bvid],
      );
    }

    if (results.isNotEmpty) {
      final entities = await getEntities(bvid);
      return results.map((result) {
        final filePath = result['filePath'] as String;
        int cid = result['cid'] as int;
        final entity = entities
            .firstWhere((e) => e.bvid == bvid && e.cid == result['cid']);
        return LazyAudioSource(bvid, cid,
            localFile: File(filePath),
            tag: MediaItem(
              id: '${bvid}_${result['cid']}',
              title: entity.partTitle,
              artist: entity.artist,
              artUri: Uri.parse(entity.artUri),
              duration: Duration(seconds: entity.duration),
              extras: {
                'bvid': bvid,
                'aid': entity.aid,
                'cid': entity.cid,
                'mid': meta.mid,
                'multi': entity.part > 0,
                'raw_title': entity.bvidTitle,
                'cached': true
              },
            ));
      }).toList();
    }
    return null;
  }

  static Future<LazyAudioSource?> getLocalAudio(String bvid, int cid) async {
    _logger.info('Fetching local audio for bvid: $bvid, cid: $cid');
    try {
      final meta = await getMeta(bvid);
      if (meta == null) {
        return null;
      }
      final db = await database;
      var results = await db.query(
        downloadTable,
        where: "bvid = ? AND cid = ?",
        whereArgs: [bvid, cid],
      );

      _logger.info('get local audio results: $results');

      if (results.isEmpty) {
        results = await db.query(
          cacheTable,
          where: "bvid = ? AND cid = ?",
          whereArgs: [bvid, cid],
        );
      }

      if (results.isNotEmpty) {
        final filePath = results.first['filePath'] as String;
        // 缓存路径可能来自旧的安装（容器路径失效），存在性校验失败时
        // 忽略缓存记录，让调用方回退到网络解析。
        final file = File(filePath);
        if (!file.existsSync()) {
          _logger.warning(
              'Cached audio file missing (path invalid): $filePath');
          return null;
        }
        _logger.info('Found cached audio for bvid: $bvid, cid: $cid');
        final entities = await getEntities(bvid);
        final entity =
            entities.firstWhere((e) => e.bvid == bvid && e.cid == cid);
        final tag = MediaItem(
            id: '${bvid}_$cid',
            title: entity.partTitle,
            artist: entity.artist,
            artUri: Uri.parse(entity.artUri),
            duration: Duration(seconds: meta.duration),
            extras: {
              'bvid': bvid,
              'aid': entity.aid,
              'cid': cid,
              'mid': meta.mid,
              'multi': entity.part > 0,
              'raw_title': entity.bvidTitle,
              'cached': true
            });
        return LazyAudioSource(bvid, cid, localFile: file, tag: tag);
      } else {
        _logger.info('No cached audio found for bvid: $bvid, cid: $cid');
      }
      return null;
    } catch (e, stackTrace) {
      _logger.severe('Failed to get cached audio', e, stackTrace);
      rethrow;
    }
  }

  static Future<File> prepareFileForCaching(String bvid, int cid) async {
    String directory;
    if (Platform.isAndroid) {
      // Android 历史缓存都在 Documents，为兼容旧数据不迁移目录
      directory = (await getApplicationDocumentsDirectory()).path;
    } else {
      // iOS/macOS 遵循 Apple 存储规范：可重新下载的缓存放 Library/Caches，
      // 不占 iCloud 备份，系统存储紧张时可自动清理（播放路径有存在性
      // 校验兜底，被清理后自动回退网络解析）。Linux/Windows 本就如此。
      directory = (await getApplicationCacheDirectory()).path;
    }
    final fileName = '$bvid-$cid.m4a';
    final filePath = join(directory, fileName);
    return File(filePath);
  }

  /// 返回当前不应被缓存清理删除的文件路径集合（如正在播放的缓存文件）。
  /// 由 AudioService 注册，避免 database_manager 反向依赖 audio_service。
  static Future<Set<String>> Function()? cacheFileGuard;

  /// 删除缓存主文件及其伴生文件（.mime / .part），不存在的文件静默跳过。
  static Future<void> deleteCacheFiles(String filePath) async {
    for (final path in [filePath, '$filePath.mime', '$filePath.part']) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _logger.warning('Failed to delete cache file: $path, error: $e');
      }
    }
  }

  /// 扫描缓存目录，删除无 DB 记录的孤儿文件：下载中断残留的 .part、
  /// 主文件已删的 .mime，以及任何无记录的主文件，防止磁盘泄漏。
  static Future<void> sweepOrphanCacheFiles() async {
    try {
      final db = await database;
      final rows = await db.query(cacheTable, columns: ['filePath']);
      final knownPaths = rows.map((r) => r['filePath'] as String).toSet();

      final cacheFilePattern =
          RegExp(r'^BV[^/\\]+-\d+\.m4a(\.(mime|part))?$');
      // 10 分钟内修改的文件可能正在下载中，跳过避免误删
      final recentThreshold =
          DateTime.now().subtract(const Duration(minutes: 10));

      final dirs = <String>{
        (await getApplicationCacheDirectory()).path,
        // 旧版本 iOS/Android 缓存目录，一并扫描
        (await getApplicationDocumentsDirectory()).path,
      };
      for (final dirPath in dirs) {
        final dir = Directory(dirPath);
        if (!dir.existsSync()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          if (!cacheFilePattern.hasMatch(basename(entity.path))) continue;
          final stat = await entity.stat();
          if (stat.modified.isAfter(recentThreshold)) continue;
          final mainPath = entity.path.endsWith('.mime') ||
                  entity.path.endsWith('.part')
              ? entity.path.substring(0, entity.path.lastIndexOf('.'))
              : entity.path;
          if (!knownPaths.contains(mainPath)) {
            _logger.info('Removing orphan cache file: ${entity.path}');
            try {
              await entity.delete();
            } catch (e) {
              _logger.warning(
                  'Failed to remove orphan cache file: ${entity.path}, $e');
            }
          }
        }
      }
    } catch (e) {
      _logger.warning('sweepOrphanCacheFiles failed: $e');
    }
  }

  static Future<void> saveCacheMetadata(String bvid, int cid, File file) async {
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.transaction((txn) async {
        int ret = await txn.insert(
            cacheTable,
            {
              'bvid': bvid,
              'cid': cid,
              'filePath': file.path,
              'fileSize': await file.length(),
              'playCount': 0,
              'lastPlayed': now,
              'createdAt': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (ret != 0) {
          _logger.info('audio cache metadata saved');
        }
      });
    } catch (e, stackTrace) {
      _logger.severe('Failed to save audio cache metadata', e, stackTrace);
      rethrow;
    }
  }

  static Future<void> updatePlayStats(String bvid, int cid) async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE $cacheTable 
      SET playCount = playCount + 1,
          lastPlayed = ?
      WHERE bvid = ? AND cid = ?
      ''', [DateTime.now().millisecondsSinceEpoch, bvid, cid]);
  }

  static Future<int> getCacheTotalSize() async {
    try {
      final db = await database;
      final rows = await db.query(cacheTable,
          columns: ['bvid', 'cid', 'filePath', 'fileSize']);
      var totalSize = 0;
      for (final row in rows) {
        final filePath = row['filePath'] as String;
        if (await File(filePath).exists()) {
          totalSize += (row['fileSize'] as int?) ?? 0;
        } else {
          // 文件已被系统清理（如 iOS purge Caches）或路径失效，
          // 顺手清除失效记录及伴生文件，保持统计与界面一致
          _logger.info('Pruning stale cache record: $filePath');
          await db.delete(cacheTable,
              where: 'bvid = ? AND cid = ?',
              whereArgs: [row['bvid'], row['cid']]);
          await deleteCacheFiles(filePath);
        }
      }
      return totalSize;
    } catch (e, stackTrace) {
      _logger.severe('Failed to get cache total size', e, stackTrace);
      return 0; // Return 0 on error to prevent further issues
    }
  }

  static Future<void> cleanupCache({File? ignoreFile}) async {
    const double playCountWeight = 0.7;
    const double recencyWeight = 0.3;
    final currentSize = await getCacheTotalSize();
    final maxCacheSize =
        await SharedPreferencesService.getCacheLimitSize() * 1024 * 1024;
    _logger.info('currentSize: $currentSize, maxCacheSize: $maxCacheSize');
    if (currentSize <= maxCacheSize) {
      return;
    }

    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Use a transaction for all database operations
    await db.transaction((txn) async {
      // 获取所有缓存文件信息并计算分数
      final results = await txn.query(cacheTable);

      // 计算最大播放次数用于归一化
      final maxPlayCount = results.fold<int>(
          1, (max, row) => math.max(max, row['playCount'] as int));

      var files = results.map((row) {
        final playCount = row['playCount'] as int;
        final lastPlayed = row['lastPlayed'] as int;
        final daysAgo = (now - lastPlayed) / (24 * 60 * 60 * 1000);

        // 计算归一化分数
        final playScore = playCount / maxPlayCount;
        final recencyScore = math.exp(-daysAgo / 7); // 使用指数衰减

        final score =
            (playScore * playCountWeight) + (recencyScore * recencyWeight);

        return {
          'bvid': row['bvid'],
          'cid': row['cid'],
          'filePath': row['filePath'],
          'fileSize': row['fileSize'],
          'score': score,
        };
      }).toList();

      files.sort(
          (a, b) => (a['score'] as double).compareTo(b['score'] as double));

      // 受保护路径：刚下载完的文件 + 正在播放的缓存文件（iOS 经本地代理
      // 流式读文件，删除会立即中断播放）
      final protectedPaths = <String>{
        if (ignoreFile != null) ignoreFile.path,
        ...?await cacheFileGuard?.call(),
      };

      int removedSize = 0;
      for (var file in files) {
        if (protectedPaths.contains(file['filePath'])) {
          continue;
        }
        if (currentSize - removedSize <= maxCacheSize) {
          break;
        }

        final filePath = file['filePath'] as String;
        try {
          await deleteCacheFiles(filePath);

          await txn.delete(
            cacheTable,
            where: 'bvid = ? AND cid = ?',
            whereArgs: [file['bvid'], file['cid']],
          );

          removedSize += file['fileSize'] as int;
        } catch (e) {
          _logger.warning('Failed to delete cache file: $filePath, error: $e');
          // Continue with next file even if this one fails
          continue;
        }
      }
      _logger.info('Cleaned up cache, removed $removedSize bytes');
    });
  }

  /// 删除单个分 P 的缓存（文件 + DB 记录）。
  /// [force] 为 true 时跳过播放中保护（用于播放中切换音质的场景，
  /// 调用方需保证已暂停并即将替换播放源）。
  static Future<void> removeCacheEntry(String bvid, int cid,
      {bool force = false}) async {
    final db = await database;
    final rows = await db.query(cacheTable,
        where: 'bvid = ? AND cid = ?', whereArgs: [bvid, cid]);
    final protectedPaths =
        force ? const <String>{} : <String>{...?await cacheFileGuard?.call()};
    for (final row in rows) {
      final filePath = row['filePath'] as String;
      if (protectedPaths.contains(filePath)) {
        _logger.warning(
            'Skip removing cache file in use (playing): $filePath');
        continue;
      }
      await deleteCacheFiles(filePath);
      await db.delete(cacheTable,
          where: 'bvid = ? AND cid = ?', whereArgs: [bvid, cid]);
    }
  }

  static Future<void> removeCache(String bvid) async {
    final db = await database;
    final files = await db.query(cacheTable, where: 'bvid = ?', whereArgs: [bvid]);
    final protectedPaths = <String>{...?await cacheFileGuard?.call()};
    for (final fileData in files) {
      final filePath = fileData['filePath'] as String;
      if (protectedPaths.contains(filePath)) {
        _logger.warning(
            'Skip removing cache file in use (playing): $filePath');
        continue;
      }
      _logger.info("Removing cache file for bvid $bvid");
      await deleteCacheFiles(filePath);
      // 仅删除已成功清理文件的记录，受保护文件保留记录以便后续清理
      await db.delete(cacheTable,
          where: 'bvid = ? AND cid = ?',
          whereArgs: [fileData['bvid'], fileData['cid']]);
    }
  }

  static Future<void> cacheFavList(List<Fav> favs) async {
    final db = await database;

    // synced_count 记录的是「上次全量同步视频缓存」的条数，重写收藏夹
    // 列表（只是元数据）不应将其重置为 -1，否则详情页会反复全量拉取
    final oldSyncedCounts = <int, int>{
      for (final row in await db
          .query(favListTable, columns: ['id', 'synced_count']))
        row['id'] as int: (row['synced_count'] as int?) ?? -1
    };

    await db.delete(favListTable);

    final batch = db.batch();

    for (int i = 0; i < favs.length; i++) {
      batch.insert(
        favListTable,
        {
          'id': favs[i].id,
          'title': favs[i].title,
          'mediaCount': favs[i].mediaCount,
          'cover': favs[i].cover,
          'list_order': i,
          'synced_count': oldSyncedCounts[favs[i].id] ?? -1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
    _logger.info('cached ${favs.length} fav lists');
  }

  static Future<void> cacheCollectedFavList(List<Fav> favs) async {
    final db = await database;

    // 同 cacheFavList：保留已有 synced_count，避免重置
    final oldSyncedCounts = <int, int>{
      for (final row in await db
          .query(collectedFavListTable, columns: ['id', 'synced_count']))
        row['id'] as int: (row['synced_count'] as int?) ?? -1
    };

    await db.delete(collectedFavListTable);

    final batch = db.batch();

    for (int i = 0; i < favs.length; i++) {
      batch.insert(
        collectedFavListTable,
        {
          'id': favs[i].id,
          'title': favs[i].title,
          'mediaCount': favs[i].mediaCount,
          'cover': favs[i].cover,
          'list_order': i,
          'synced_count': oldSyncedCounts[favs[i].id] ?? -1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
    _logger.info('cached collected ${favs.length} fav lists');
  }

  static Future<List<Fav>> getCachedCollectedFavList() async {
    final db = await database;
    final results =
        await db.query(collectedFavListTable, orderBy: 'list_order ASC');

    return results
        .map((row) => Fav(
              id: row['id'] as int,
              title: row['title'] as String,
              mediaCount: row['mediaCount'] as int,
              cover: row['cover'] as String?,
            ))
        .toList();
  }

  /// 全量替换某收藏合集的视频缓存（网络完整拉取后调用），
  /// 并把实际条数记入 collected_fav_list.synced_count
  static Future<void> cacheCollectedFavListVideo(
      List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    batch
        .delete(collectedFavListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    for (var bvid in bvids) {
      batch.insert(collectedFavListVideoTable, {'bvid': bvid, 'mid': mid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    batch.update(collectedFavListTable, {'synced_count': bvids.length},
        where: 'id = ?', whereArgs: [mid]);
    await batch.commit();
    _logger.info('cached ${bvids.length} collected fav list videos');
  }

  /// 增量合并收藏的合集视频缓存（不删除已有记录）——用于主页封面
  /// 堆叠兜底的第一页补拉
  static Future<void> mergeCacheCollectedFavListVideo(
      List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    for (var bvid in bvids) {
      batch.insert(collectedFavListVideoTable, {'bvid': bvid, 'mid': mid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit();
    _logger.info('merged ${bvids.length} collected fav list videos');
  }

  static Future<List<String>> getCachedCollectionBvids(int mid) async {
    final db = await database;
    final results = await db
        .query(collectedFavListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    return results.map((row) => row['bvid'] as String).toList();
  }

  static Future<List<Meta>> getCachedCollectionMetas(int mid) async {
    final bvids = await DatabaseManager.getCachedCollectionBvids(mid);
    final metas = await DatabaseManager.getMetas(bvids);
    return metas;
  }

  static Future<void> cacheFavDetail(int favId, List<Medias> medias) async {
    final db = await database;
    final batch = db.batch();

    await db.delete(
      favDetailTable,
      where: 'fav_id = ?',
      whereArgs: [favId],
    );

    for (int i = 0; i < medias.length; i++) {
      final media = medias[i];
      batch.insert(
        favDetailTable,
        {
          'id': media.id,
          'title': media.title,
          'cover': media.cover,
          'page': media.page,
          'duration': media.duration,
          'upper_name': media.upper.name,
          'play_count': media.cntInfo.play,
          'bvid': media.bvid,
          'fav_id': favId,
          'list_order': i,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
    _logger.info('cached ${medias.length} fav details');
  }

  static Future<void> appendCacheFavDetail(
      int favId, List<Medias> medias) async {
    final db = await database;
    final batch = db.batch();

    final maxOrderResult = await db.rawQuery(
        'SELECT MAX(list_order) as max_order FROM $favDetailTable WHERE fav_id = ?',
        [favId]);
    final int startOrder = (maxOrderResult.first['max_order'] as int?) ?? -1;

    for (int i = 0; i < medias.length; i++) {
      final media = medias[i];
      batch.insert(
        favDetailTable,
        {
          'id': media.id,
          'title': media.title,
          'cover': media.cover,
          'page': media.page,
          'duration': media.duration,
          'upper_name': media.upper.name,
          'play_count': media.cntInfo.play,
          'bvid': media.bvid,
          'fav_id': favId,
          'list_order': startOrder + i + 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
    _logger.info('appended ${medias.length} fav details');
  }

  static Future<List<Fav>> getCachedFavList() async {
    final db = await database;
    final results = await db.query(favListTable, orderBy: 'list_order ASC');

    return results
        .map((row) => Fav(
              id: row['id'] as int,
              title: row['title'] as String,
              mediaCount: row['mediaCount'] as int,
              cover: row['cover'] as String?,
            ))
        .toList();
  }

  /// 全量替换某收藏夹的视频缓存（网络完整拉取后调用），
  /// 并把实际条数记入 fav_list.synced_count 作为「已全量同步」标记。
  /// 注：getUserUploads 也以 UP 主 mid 调用本函数，UPDATE 在
  /// fav_list 表中不命中任何收藏夹行，无副作用
  static Future<void> cacheFavListVideo(List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    batch.delete(favListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    for (var bvid in bvids) {
      batch.insert(favListVideoTable, {'bvid': bvid, 'mid': mid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    batch.update(favListTable, {'synced_count': bvids.length},
        where: 'id = ?', whereArgs: [mid]);
    await batch.commit();
    _logger.info('cached ${bvids.length} fav list videos');
  }

  /// 增量合并收藏夹视频缓存（不删除已有记录）——用于主页封面
  /// 堆叠兜底的第一页补拉，避免覆盖掉之前缓存的完整列表
  static Future<void> mergeCacheFavListVideo(
      List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    for (var bvid in bvids) {
      batch.insert(favListVideoTable, {'bvid': bvid, 'mid': mid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit();
    _logger.info('merged ${bvids.length} fav list videos');
  }

  static Future<List<String>> getCachedFavBvids(int mid) async {
    final db = await database;
    final results =
        await db.query(favListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    return results.map((row) => row['bvid'] as String).toList();
  }

  static Future<List<Meta>> getCachedFavMetas(int mid) async {
    final bvids = await DatabaseManager.getCachedFavBvids(mid);
    final metas = await DatabaseManager.getMetas(bvids);
    return metas;
  }

  /// 上次全量同步（网络完整拉取并替换视频缓存）时的条数；
  /// -1 表示从未全量同步过——本地缓存可能只是封面补拉写入的第一页
  static Future<int> getFavSyncedCount(int favId) async {
    final db = await database;
    final rows = await db
        .query(favListTable, columns: ['synced_count'], where: 'id = ?', whereArgs: [favId]);
    return (rows.firstOrNull?['synced_count'] as int?) ?? -1;
  }

  /// 收藏的合集：同 [getFavSyncedCount]
  static Future<int> getCollectedFavSyncedCount(int seasonId) async {
    final db = await database;
    final rows = await db.query(collectedFavListTable,
        columns: ['synced_count'], where: 'id = ?', whereArgs: [seasonId]);
    return (rows.firstOrNull?['synced_count'] as int?) ?? -1;
  }

  static Future<bool> isFaved(String bvid) async {
    final db = await database;
    final results = await db.query(
      favListVideoTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
    return results.isNotEmpty;
  }

  /// 主页收藏夹网格的封面堆叠：每个收藏夹取前 [perFav] 张本地缓存的
  /// 歌曲封面。仅查本地 DB（收藏夹视频表 JOIN meta_cache.artUri 与
  /// play_stat），不访问网络；无缓存的收藏夹不在返回 map 中（UI 走
  /// 收藏夹自身封面兜底或占位图）。
  ///
  /// 封面顺序不是简单按夹内顺序，而是按播放统计打分（见
  /// recent_picks.playStatScore：最近播放 + 播放次数 + 累计时长）
  /// 降序挑选——堆叠最上层的主体封面是用户最近常听、最有辨识度的
  /// 那首；从未播放过的歌曲分值为 0，按夹内原顺序垫底。
  static Future<Map<int, List<String>>> getFavCoverPreviews(
    List<int> favIds,
    List<int> collectedFavIds, {
    int perFav = 3,
  }) async {
    final db = await database;
    final result = <int, List<String>>{};

    // rows: fav_id, cover, last_played, total_play_time, play_count
    void collectScored(List<Map<String, Object?>> rows) {
      // 按收藏夹分组，保留夹内原始顺序（行号）用于同分兜底
      final byFav = <int, List<(int, Map<String, Object?>)>>{};
      for (var i = 0; i < rows.length; i++) {
        final id = rows[i]['fav_id'] as int;
        byFav.putIfAbsent(id, () => []).add((i, rows[i]));
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in byFav.entries) {
        final candidates = entry.value;
        final maxCount = candidates.fold(
            0, (m, e) => math.max(m, (e.$2['play_count'] as int?) ?? 0));
        final maxTime = candidates.fold(
            0, (m, e) => math.max(m, (e.$2['total_play_time'] as int?) ?? 0));
        final scored = <(String cover, double score, int order)>[];
        for (final (order, row) in candidates) {
          final cover = row['cover'] as String?;
          if (cover == null || cover.isEmpty) continue;
          scored.add((
            cover,
            playStatScore(
              lastPlayed: (row['last_played'] as int?) ?? 0,
              playCount: (row['play_count'] as int?) ?? 0,
              totalPlayTime: (row['total_play_time'] as int?) ?? 0,
              maxCount: maxCount,
              maxTime: maxTime,
              nowMs: now,
            ),
            order,
          ));
        }
        // 分值降序，同分保持夹内原顺序
        scored.sort((a, b) =>
            b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
        final covers = <String>[];
        for (final s in scored) {
          if (covers.length >= perFav) break;
          if (!covers.contains(s.$1)) covers.add(s.$1);
        }
        if (covers.isNotEmpty) result[entry.key] = covers;
      }
    }

    if (favIds.isNotEmpty) {
      final placeholders = List.filled(favIds.length, '?').join(',');
      collectScored(await db.rawQuery('''
        SELECT v.mid AS fav_id, m.artUri AS cover,
               s.last_played, s.total_play_time, s.play_count
        FROM $favListVideoTable v
        LEFT JOIN $metaTable m ON v.bvid = m.bvid
        LEFT JOIN $statTable s ON v.bvid = s.bvid
        WHERE v.mid IN ($placeholders)
      ''', favIds));
    }
    if (collectedFavIds.isNotEmpty) {
      final placeholders = List.filled(collectedFavIds.length, '?').join(',');
      collectScored(await db.rawQuery('''
        SELECT v.mid AS fav_id, m.artUri AS cover,
               s.last_played, s.total_play_time, s.play_count
        FROM $collectedFavListVideoTable v
        LEFT JOIN $metaTable m ON v.bvid = m.bvid
        LEFT JOIN $statTable s ON v.bvid = s.bvid
        WHERE v.mid IN ($placeholders)
      ''', collectedFavIds));
    }
    return result;
  }

  static Future<void> rmFav(String bvid, {int? mid}) async {
    final db = await database;
    // 删除前先按收藏夹统计将删行数，用于同步 fav_list 的 mediaCount
    final counts = await db.rawQuery(
      'SELECT mid, COUNT(*) AS c FROM $favListVideoTable '
      'WHERE bvid = ? ${mid != null ? 'AND mid = ?' : ''} GROUP BY mid',
      mid != null ? [bvid, mid] : [bvid],
    );
    final deleted = await db.delete(favListVideoTable,
        where: 'bvid = ? ${mid != null ? 'AND mid = ?' : ''}',
        whereArgs: mid != null ? [bvid, mid] : [bvid]);
    if (deleted > 0) {
      final batch = db.batch();
      for (final row in counts) {
        batch.rawUpdate(
          'UPDATE $favListTable SET mediaCount = MAX(mediaCount - ?, 0) '
          'WHERE id = ?',
          [row['c'], row['mid']],
        );
      }
      await batch.commit(noResult: true);
      favListVersion.value++;
    }
    _logger.info(
        'removed fav $bvid ${mid != null ? 'and mid $mid' : ''} from database');
  }

  // TODO: low performance
  static Future<void> addFav(String bvid, int mid) async {
    final db = await database;
    var inserted = false;
    await db.transaction((txn) async {
      final existing = await txn.query(
        favListVideoTable,
        where: 'bvid = ? AND mid = ?',
        whereArgs: [bvid, mid],
      );

      if (existing.isEmpty) {
        await txn.execute('''
          CREATE TEMPORARY TABLE temp_fav AS 
          SELECT * FROM $favListVideoTable
        ''');

        await txn.delete(favListVideoTable);

        await txn.insert(
          favListVideoTable,
          {'bvid': bvid, 'mid': mid},
        );

        await txn.execute('''
          INSERT INTO $favListVideoTable 
          SELECT * FROM temp_fav
        ''');

        await txn.execute('DROP TABLE temp_fav');

        // 同步收藏夹的媒体计数，主页无需等待网络刷新即显示最新值
        await txn.rawUpdate(
          'UPDATE $favListTable SET mediaCount = mediaCount + 1 WHERE id = ?',
          [mid],
        );
        inserted = true;

        _logger.info('added fav $bvid to database');
      }
    });
    if (inserted) {
      favListVersion.value++;
    }
  }

  static Future<void> removeDownloaded(List<(String, int)> bvidscids) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var (bvid, cid) in bvidscids) {
        await txn.delete(downloadTable,
            where: 'bvid = ? AND cid = ?', whereArgs: [bvid, cid]);
      }
    });
  }

  static Future<List<int>> getDownloadedParts(String bvid) async {
    final db = await database;
    final results = await db.query(
      downloadTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
    _logger.info('getDownloadedParts $bvid ${results.length}');
    return results.map((e) => e['cid'] as int).toList();
  }

  static Future<void> saveDownload(
      String bvid, int cid, String filePath) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        downloadTable,
        {
          'bvid': bvid,
          'cid': cid,
          'filePath': filePath,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    _logger.info('saved download $bvid $cid $filePath');
  }

  static Future<String?> getDownloadPath(String bvid, int cid) async {
    final db = await database;
    final result = await db.query(
      downloadTable,
      columns: ['filePath'],
      where: 'bvid = ? AND cid = ?',
      whereArgs: [bvid, cid],
    );

    if (result.isNotEmpty) {
      return result.first['filePath'] as String;
    }
    return null;
  }

  static Future<bool> isDownloaded(String bvid, int cid) async {
    final path = await getDownloadPath(bvid, cid);
    if (path == null) return false;
    return File(path).exists();
  }

  static Future<void> saveDownloadTask(DownloadTask task) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        downloadTaskTable,
        {
          'bvid': task.bvid,
          'cid': task.cid,
          'targetPath': task.targetPath,
          'status': task.status.index,
          'progress': task.progress,
          'error': task.error,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<void> updateDownloadTaskStatus(
      String bvid, int cid, DownloadStatus status) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        downloadTaskTable,
        {'status': status.index},
        where: 'bvid = ? AND cid = ?',
        whereArgs: [bvid, cid],
      );
    });
  }

  static Future<void> updateDownloadTaskProgress(
      String bvid, int cid, double progress) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        downloadTaskTable,
        {'progress': progress},
        where: 'bvid = ? AND cid = ?',
        whereArgs: [bvid, cid],
      );
    });
  }

  static Future<void> removeDownloadTask(String bvid, int cid) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        downloadTaskTable,
        where: 'bvid = ? AND cid = ?',
        whereArgs: [bvid, cid],
      );
    });
  }

  static Future<List<DownloadTask>> getAllDownloadTasks() async {
    final db = await database;
    List<Map<String, dynamic>> results = [];
    await db.transaction((txn) async {
      results = await txn.query(downloadTaskTable);
    });
    return results
        .map((row) => DownloadTask(
              bvid: row['bvid'] as String,
              cid: row['cid'] as int,
              targetPath: row['targetPath'] as String?,
              status: DownloadStatus.values[row['status'] as int],
              progress: row['progress'] as double,
              error: row['error'] as String?,
            ))
        .toList();
  }

  static Future<DownloadTask?> getDownloadTask(String bvid, int cid) async {
    final db = await database;
    List<Map<String, dynamic>> results = [];
    await db.transaction((txn) async {
      results = await txn.query(
        downloadTaskTable,
        where: 'bvid = ? AND cid = ?',
        whereArgs: [bvid, cid],
      );
    });

    if (results.isEmpty) return null;

    final row = results.first;
    return DownloadTask(
      bvid: row['bvid'] as String,
      cid: row['cid'] as int,
      targetPath: row['targetPath'] as String?,
      status: DownloadStatus.values[row['status'] as int],
      progress: row['progress'] as double,
      error: row['error'] as String?,
    );
  }

  static Future<List<DownloadTask>> getPendingDownloadTasks() async {
    final db = await database;
    List<Map<String, dynamic>> results = [];
    await db.transaction((txn) async {
      results = await txn.query(
        downloadTaskTable,
        where: 'status = ? OR status = ?',
        whereArgs: [DownloadStatus.pending.index, DownloadStatus.paused.index],
      );
    });

    return results
        .map((row) => DownloadTask(
              bvid: row['bvid'] as String,
              cid: row['cid'] as int,
              targetPath: row['targetPath'] as String?,
              status: DownloadStatus.values[row['status'] as int],
              progress: row['progress'] as double,
              error: row['error'] as String?,
            ))
        .toList();
  }

  static Future<void> updatePlayStat(
      String bvid, int playcnt, int playTimeSeconds,
      {int? cid}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final result = await txn.query(
        statTable,
        where: 'bvid = ?',
        whereArgs: [bvid],
      );

      if (result.isEmpty) {
        final newStat = PlayStat(
          bvid: bvid,
          lastPlayed: now,
          totalPlayTime: playTimeSeconds,
          playCount: 1,
          lastCid: cid,
        );

        await txn.insert(
          statTable,
          newStat.toDbJson(),
        );
      } else {
        final existingStat = PlayStat.fromJson(result.first);

        final updatedStat = PlayStat(
          bvid: bvid,
          lastPlayed: now,
          totalPlayTime: existingStat.totalPlayTime + playTimeSeconds,
          playCount: existingStat.playCount + playcnt,
          lastCid: cid ?? existingStat.lastCid,
        );

        await txn.update(
          statTable,
          updatedStat.toDbJson(),
          where: 'bvid = ?',
          whereArgs: [bvid],
        );
      }
    });
  }

  static Future<PlayStat?> getPlayStat(String bvid) async {
    final db = await database;
    final result = await db.query(
      statTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );

    if (result.isEmpty) {
      return null;
    }

    return PlayStat.fromJson(result.first);
  }

  static Future<List<PlayStat>> getPlayHistory(
      {int? limit, String? orderBy}) async {
    final db = await database;

    orderBy ??= 'last_played DESC';

    final query = '''
      SELECT s.*, m.title, m.artist, m.artUri, m.duration
      FROM $statTable s
      LEFT JOIN $metaTable m ON s.bvid = m.bvid
      ORDER BY $orderBy
      ${limit != null ? 'LIMIT $limit' : ''}
    ''';

    final results = await db.rawQuery(query);
    return results.map((row) => PlayStat.fromJson(row)).toList();
  }

  static Future<void> clearPlayStats() async {
    final db = await database;
    await db.delete(statTable);
  }

  static Future<void> removePlayStat(String bvid) async {
    final db = await database;
    await db.delete(
      statTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
  }
}
