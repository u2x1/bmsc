import 'dart:io';
import 'dart:async';
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
        version: 6,
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
            list_order INTEGER
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
            list_order INTEGER
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
            play_count INTEGER DEFAULT 0
          )
        ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          _logger.info('Upgrading database from v$oldVersion to v$newVersion');

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
        _logger.info('Found cached audio for bvid: $bvid, cid: $cid');
        final filePath = results.first['filePath'] as String;
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
        final file = File(filePath);
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
    if (Platform.isLinux || Platform.isWindows) {
      directory = (await getApplicationCacheDirectory()).path;
    } else {
      directory = (await getApplicationDocumentsDirectory()).path;
    }
    final fileName = '$bvid-$cid.m4a';
    final filePath = join(directory, fileName);
    return File(filePath);
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
              'fileSize': file.lengthSync(),
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
      int totalSize = 0;

      await db.transaction((txn) async {
        final result = await txn
            .rawQuery('SELECT SUM(fileSize) as total FROM $cacheTable');
        totalSize = (result.first['total'] as int?) ?? 0;
      });

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

      int removedSize = 0;
      for (var file in files) {
        if (ignoreFile != null && file['filePath'] == ignoreFile.path) {
          continue;
        }
        if (currentSize - removedSize <= maxCacheSize) {
          break;
        }

        final filePath = file['filePath'] as String;
        final fileObj = File(filePath);
        try {
          if (await fileObj.exists()) {
            await fileObj.delete();
          }

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

  static Future<void> removeCache(String bvid) async {
    final db = await database;
    List<Map<String, dynamic>> files = [];
    await db.transaction((txn) async {
      files = await txn.query(cacheTable, where: 'bvid = ?', whereArgs: [bvid]);
      await txn.delete(cacheTable, where: 'bvid = ?', whereArgs: [bvid]);
    });
    for (final fileData in files) {
      _logger.info("Removing cache file for bvid $bvid");
      final filePath = fileData['filePath'];
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<void> cacheFavList(List<Fav> favs) async {
    final db = await database;

    await db.delete(favListTable);

    final batch = db.batch();

    for (int i = 0; i < favs.length; i++) {
      batch.insert(
        favListTable,
        {
          'id': favs[i].id,
          'title': favs[i].title,
          'mediaCount': favs[i].mediaCount,
          'list_order': i,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
    _logger.info('cached ${favs.length} fav lists');
  }

  static Future<void> cacheCollectedFavList(List<Fav> favs) async {
    final db = await database;

    await db.delete(collectedFavListTable);

    final batch = db.batch();

    for (int i = 0; i < favs.length; i++) {
      batch.insert(
        collectedFavListTable,
        {
          'id': favs[i].id,
          'title': favs[i].title,
          'mediaCount': favs[i].mediaCount,
          'list_order': i,
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
            ))
        .toList();
  }

  static Future<void> cacheCollectedFavListVideo(
      List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    batch
        .delete(collectedFavListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    for (var bvid in bvids) {
      batch.insert(collectedFavListVideoTable, {'bvid': bvid, 'mid': mid});
    }
    await batch.commit();
    _logger.info('cached ${bvids.length} collected fav list videos');
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
            ))
        .toList();
  }

  static Future<void> cacheFavListVideo(List<String> bvids, int mid) async {
    final db = await database;
    final batch = db.batch();
    batch.delete(favListVideoTable, where: 'mid = ?', whereArgs: [mid]);
    for (var bvid in bvids) {
      batch.insert(favListVideoTable, {'bvid': bvid, 'mid': mid});
    }
    await batch.commit();
    _logger.info('cached ${bvids.length} fav list videos');
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

  static Future<bool> isFaved(String bvid) async {
    final db = await database;
    final results = await db.query(
      favListVideoTable,
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
    return results.isNotEmpty;
  }

  static Future<void> rmFav(String bvid, {int? mid}) async {
    final db = await database;
    await db.delete(favListVideoTable,
        where: 'bvid = ? ${mid != null ? 'AND mid = ?' : ''}',
        whereArgs: [bvid, mid]);
    _logger.info(
        'removed fav $bvid ${mid != null ? 'and mid $mid' : ''} from database');
  }

  // TODO: low performance
  static Future<void> addFav(String bvid, int mid) async {
    final db = await database;
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

        _logger.info('added fav $bvid to database');
      }
    });
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
      String bvid, int playcnt, int playTimeSeconds) async {
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
