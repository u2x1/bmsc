// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/model/myinfo.dart';
import 'package:bmsc/model/recognition_attempt.dart';
import 'package:bmsc/model/playlist_data.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/section_habit.dart';
import 'package:bmsc/util/silent_audio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/subjects.dart';

/// 主页板块 key 与默认顺序定义于 util/section_habit.dart（纯 Dart，
/// 便于离线测试引用），此处原样 re-export 保持既有调用方不变
export 'package:bmsc/util/section_habit.dart'
    show
        kHomeSectionDaily,
        kHomeSectionRecent,
        kHomeSectionMine,
        kHomeSectionCollected,
        kHomeSectionLocal,
        kDefaultHomeSectionOrder;

final _logger = LoggerUtils.getLogger('SharedPreferencesService');

class SharedPreferencesService {
  static final instance = _instance();
  static final _maxConcurrentDownloadsController = BehaviorSubject<int>();
  static final _downloadPathController = BehaviorSubject<String>();
  static Stream<int> get maxConcurrentDownloadsStream =>
      _maxConcurrentDownloadsController.stream;
  static Stream<String> get downloadPathStream =>
      _downloadPathController.stream;

  static Future<SharedPreferences> _instance() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs;
  }

  /// 主页板块排序：读取时消毒——剔除未知 key、补齐缺失板块
  ///（未来新增板块自动追加到末尾）。
  /// 返回值始终为可变拷贝（kDefaultHomeSectionOrder 是 const，
  /// 排序对话框会直接原地增删返回的列表）
  static Future<List<String>> getHomeSectionOrder() async {
    final prefs = await instance;
    final stored = prefs.getStringList('home_section_order');
    if (stored == null) return List.of(kDefaultHomeSectionOrder);
    final order = stored.where(kDefaultHomeSectionOrder.contains).toList();
    for (final key in kDefaultHomeSectionOrder) {
      if (!order.contains(key)) order.add(key);
    }
    return order;
  }

  static Future<void> setHomeSectionOrder(List<String> order) async {
    final prefs = await instance;
    await prefs.setStringList('home_section_order', order);
  }

  /// 单位为MB
  static Future<void> setCacheLimitSize(int size) async {
    final prefs = await instance;
    await prefs.setInt('cacheLimitSize', size);
  }

  /// 单位为MB
  static Future<int> getCacheLimitSize() async {
    final prefs = await instance;
    return prefs.getInt('cacheLimitSize') ?? 300;
  }

  static Future<String> getDownloadPath() async {
    final prefs = await instance;
    var value = prefs.getString('downloadPath');
    if (value == null || value.isEmpty) {
      // Android 默认下载目录；其余平台（iOS/macOS/Windows/Linux）用
      // 各自可写的应用文档目录，避免访问 /storage 等无效路径。
      if (Platform.isAndroid) {
        value = '/storage/emulated/0/Download/BMSC';
      } else if (Platform.isIOS) {
        value =
            p.join((await getApplicationDocumentsDirectory()).path, 'Downloads');
      } else if (Platform.isWindows) {
        value = p.join((await getDownloadsDirectory())?.path ?? '.', 'BMSC');
      } else {
        value = p.join(
            (await getApplicationSupportDirectory()).path, 'Download');
      }
    }
    return value;
  }

  static Future<void> setDownloadPath(String value) async {
    final prefs = await instance;
    await prefs.setString('downloadPath', value);
    _downloadPathController.add(value);
  }

  static Future<int> getMaxConcurrentDownloads() async {
    final prefs = await instance;
    final value = prefs.getInt('maxConcurrentDownloads') ?? 3;
    return value;
  }

  static Future<void> setMaxConcurrentDownloads(int value) async {
    final prefs = await instance;
    await prefs.setInt('maxConcurrentDownloads', value);
    _maxConcurrentDownloadsController.add(value);
  }

  static Future<bool> getReadFromClipboard() async {
    final prefs = await instance;
    // 2.0.0 起默认关闭（隐私考虑）；未设置过的用户升级后不再自动读取剪贴板
    return prefs.getBool('readFromClipboard') ?? false;
  }

  /// 听歌识曲同意（v2：录音片段会保存在本机识别历史供回放——相比 v1 的
  /// 「不保存」承诺范围变大，需重新征得同意）
  static Future<bool> getRecognitionConsent() async {
    final prefs = await instance;
    return prefs.getBool('recognition_consent_v2') ?? false;
  }

  static Future<void> setRecognitionConsent(bool value) async {
    final prefs = await instance;
    await prefs.setBool('recognition_consent_v2', value);
  }

  /// 识别历史：最新在前（成功/未中/静音/失败均入史），上限 50，
  /// 兼容旧版单曲格式条目（见 RecognitionAttempt.fromStoredJson）
  static Future<List<RecognitionAttempt>> getRecognitionHistory() async {
    final prefs = await instance;
    return (prefs.getStringList('recognition_history') ?? const <String>[])
        .map((e) => RecognitionAttempt.fromStoredJson(
            jsonDecode(e) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> addRecognitionHistory(RecognitionAttempt entry) async {
    final prefs = await instance;
    final list = List<String>.from(
        prefs.getStringList('recognition_history') ?? const <String>[]);
    list.insert(0, jsonEncode(entry.toJson()));
    if (list.length > 50) {
      // 容量溢出：同步清理被挤出的最旧条目的片段文件
      for (final raw in list.sublist(50)) {
        try {
          final e = RecognitionAttempt.fromStoredJson(
              jsonDecode(raw) as Map<String, dynamic>);
          await _deleteRecognitionClip(e.clip);
        } catch (_) {}
      }
      list.length = 50;
    }
    await prefs.setStringList('recognition_history', list);
  }

  /// 单条删除（按 at 时间戳定位，同步删除片段文件）
  static Future<void> removeRecognitionHistory(int at) async {
    final prefs = await instance;
    final list = List<String>.from(
        prefs.getStringList('recognition_history') ?? const <String>[]);
    list.removeWhere((raw) {
      try {
        final e = RecognitionAttempt.fromStoredJson(
            jsonDecode(raw) as Map<String, dynamic>);
        if (e.at == at) {
          unawaited(_deleteRecognitionClip(e.clip));
          return true;
        }
      } catch (_) {}
      return false;
    });
    await prefs.setStringList('recognition_history', list);
  }

  static Future<void> clearRecognitionHistory() async {
    final prefs = await instance;
    await prefs.remove('recognition_history');
    try {
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/recognition_clips');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 试听片段完整路径（不存在返回 null）
  static Future<String?> recognitionClipPath(String? clip) async {
    if (clip == null) return null;
    final f = File(
        '${(await getApplicationDocumentsDirectory()).path}/recognition_clips/$clip');
    return await f.exists() ? f.path : null;
  }

  static Future<void> _deleteRecognitionClip(String? clip) async {
    if (clip == null) return;
    try {
      await File(
              '${(await getApplicationDocumentsDirectory()).path}/recognition_clips/$clip')
          .delete();
    } catch (_) {}
  }

  static Future<void> setReadFromClipboard(bool value) async {
    final prefs = await instance;
    await prefs.setBool('readFromClipboard', value);
  }

  static Future<void> setUID(int uid) async {
    final prefs = await instance;
    await prefs.setInt('uid', uid);
  }

  static Future<int?> getUID() async {
    final prefs = await instance;
    return prefs.getInt('uid');
  }

  // ===== 登录会话（对齐 BiliPai TokenManager） =====

  /// 完整 cookie 串（持久化）
  static Future<void> setCookie(String cookie) async {
    final prefs = await instance;
    await prefs.setString('cookie', cookie);
  }

  static Future<String?> getCookie() async {
    final prefs = await instance;
    return prefs.getString('cookie');
  }

  static Future<void> setAccessToken(String token) async {
    final prefs = await instance;
    await prefs.setString('access_token', token);
  }

  static Future<String?> getAccessToken() async {
    final prefs = await instance;
    return prefs.getString('access_token');
  }

  static Future<void> setRefreshToken(String token) async {
    final prefs = await instance;
    await prefs.setString('refresh_token', token);
  }

  static Future<String?> getRefreshToken() async {
    final prefs = await instance;
    return prefs.getString('refresh_token');
  }

  /// 登录时是否携带 TV / Android 的 access_token
  static Future<void> setAccessTokenPlatform(String platform) async {
    final prefs = await instance;
    await prefs.setString('access_token_platform', platform);
  }

  static Future<String?> getAccessTokenPlatform() async {
    final prefs = await instance;
    return prefs.getString('access_token_platform');
  }

  /// Android-HD 登录身份 buvid（XY 开头，生成一次后持久化）
  static Future<void> setLoginBuvid(String buvid) async {
    final prefs = await instance;
    await prefs.setString('login_buvid', buvid);
  }

  static Future<String?> getLoginBuvid() async {
    final prefs = await instance;
    return prefs.getString('login_buvid');
  }

  /// 匿名 web 身份 buvid3（UUID + infoc）
  static Future<void> setBuvid3(String buvid3) async {
    final prefs = await instance;
    await prefs.setString('buvid3', buvid3);
  }

  static Future<String?> getBuvid3() async {
    final prefs = await instance;
    return prefs.getString('buvid3');
  }

  /// 登录后获取到的 access_key 是否可用（App 接口签名用）
  static Future<bool> hasAccessToken() async {
    final prefs = await instance;
    final token = prefs.getString('access_token');
    return token != null && token.isNotEmpty;
  }

  static Future<(int, String)?> getDefaultFavFolder() async {
    final prefs = await instance;
    final id = prefs.getInt('default_fav_folder');
    final name = prefs.getString('default_fav_folder_name');
    return id != null && name != null ? (id, name) : null;
  }

  static Future<void> setDefaultFavFolder(int id, String name) async {
    final prefs = await instance;
    await prefs.setInt('default_fav_folder', id);
    await prefs.setString('default_fav_folder_name', name);
  }

  static Future<void> setMyInfo(MyInfo info) async {
    final prefs = await instance;
    await prefs.setInt('my_info_mid', info.mid);
    await prefs.setString('my_info_name', info.name);
    await prefs.setString('my_info_face', info.face);
    await prefs.setString('my_info_sign', info.sign);
  }

  static Future<MyInfo?> getMyInfo() async {
    final prefs = await instance;
    final mid = prefs.getInt('my_info_mid');
    final name = prefs.getString('my_info_name');
    final face = prefs.getString('my_info_face');
    final sign = prefs.getString('my_info_sign');
    return mid != null && name != null && face != null && sign != null
        ? MyInfo(mid, name, face, sign)
        : null;
  }

  static Future<int> getPlayMode() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getInt('playmode') ?? 0;
  }

  static Future<void> setPlayMode(int mode) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setInt('playmode', mode);
  }

  static Future<void> savePlaylist(
      ConcatenatingAudioSource playlist, int currentIndex) async {
    _savePlaylist(playlist, currentIndex, 'playlist', 'currentIndex');
  }

  static Future<(List<IndexedAudioSource>, int)?> getPlaylist() {
    return _getPlaylist('playlist', 'currentIndex');
  }

  static Future<void> _savePlaylist(ConcatenatingAudioSource playlist,
      int currentIndex, String playlistId, String currentIndexId) async {
    final prefs = await SharedPreferencesService.instance;
    final playlistData =
        await Future.wait(playlist.children.map((source) async {
      if ((source is UriAudioSource || source is LazyAudioSource)) {
        final String uri = source is UriAudioSource
            ? source.uri.toString()
            : (source as LazyAudioSource).isLocal
                ? "file://${(await source.localFile).path}"
                : "";
        final tag = (source as IndexedAudioSource).tag as MediaItem;

        final dummy = tag.extras?['dummy'] ?? false;
        // dummy 源保存实际 uri（iOS 上是 file:// 临时文件，Android 是
        // asset://），恢复时直接用，避免 iOS 上恢复 asset:// 无法加载。
        final dummyUri = (source is UriAudioSource && uri.isNotEmpty)
            ? uri
            : 'asset:///assets/silent.m4a';
        final isLocal = tag.extras?['local'] == true;
        return PlaylistData(
          id: tag.id,
          title: tag.title,
          artist: tag.artist ?? '',
          artUri: tag.artUri?.toString() ?? '',
          audioUri: dummy ? dummyUri : uri.toString(),
          bvid: tag.extras?['bvid'] ?? '',
          aid: tag.extras?['aid'] ?? 0,
          cid: tag.extras?['cid'] ?? 0,
          multi: tag.extras?['multi'] ?? false,
          rawTitle: tag.extras?['raw_title'] ?? '',
          mid: tag.extras?['mid'] ?? 0,
          cached: tag.extras?['cached'] ?? false,
          duration: tag.duration?.inSeconds ?? 0,
          dummy: dummy,
          // dummy 占位源的分 P 数（随机播放权重），非 dummy 为 null
          parts: tag.extras?['parts'],
          local: isLocal,
          filePath: isLocal ? (tag.extras?['filePath'] ?? '') : '',
          album: tag.album ?? '',
        ).toJson();
      }
      _logger.warning(
          'Skipping unsupported audio source type: ${source.runtimeType}');
      return null;
    }).toList());

    await prefs.setString(playlistId,
        jsonEncode(playlistData.whereType<Map<String, dynamic>>().toList()));
    await prefs.setInt(currentIndexId, currentIndex);
  }

  static Future<(List<IndexedAudioSource>, int)?> _getPlaylist(
      String playlistId, String currentIndexId) async {
    _logger.info('Restoring playlist from preferences');
    final prefs = await SharedPreferencesService.instance;
    final playlistJson = prefs.getString(playlistId);

    if (playlistJson == null) {
      _logger.info('No saved playlist found');
      return null;
    }

    final List<dynamic> playlistData = jsonDecode(playlistJson);
    // dummy 源不信任持久化的 uri：iOS 上是 tmp 目录下的 silent.m4a，可能
    // 被系统清理或容器路径失效，恢复时统一重新生成，避免加载失败卡死。
    final dummyUri = playlistData.any((item) => item['dummy'] == true)
        ? await resolveSilentAudioUri()
        : null;
    final sources = (playlistData.map((item) {
      final data = PlaylistData.fromJson(item);
      if (data.dummy) {
        return AudioSource.uri(dummyUri!,
            tag: MediaItem(
              id: data.id,
              title: data.title,
              artist: data.artist,
              artUri: Uri.parse(data.artUri),
              duration: Duration(seconds: data.duration),
              extras: {
                'dummy': true,
                // 分 P 数随队列恢复（随机播放权重用）
                if (data.parts != null && data.parts! > 1) 'parts': data.parts,
              },
            ));
      } else if (data.local) {
        // 本地音乐：文件已被用户在应用外删除时跳过该项（本地源没有
        // 网络回退，留在队列里只会播放失败）
        final file = File(data.filePath);
        if (data.filePath.isEmpty || !file.existsSync()) {
          _logger.warning(
              'Restored local track missing, drop from playlist: ${data.filePath}');
          return null;
        }
        return AudioSource.uri(
          Uri.file(data.filePath),
          tag: MediaItem(
            id: data.id,
            title: data.title,
            artist: data.artist,
            album: data.album.isEmpty ? null : data.album,
            artUri:
                data.artUri.isEmpty ? null : Uri.parse(data.artUri),
            duration: Duration(seconds: data.duration),
            extras: {
              'local': true,
              'filePath': data.filePath,
            },
          ),
        );
      } else {
        final uri = data.audioUri == "" ? null : Uri.parse(data.audioUri);
        final file = uri != null && uri.isScheme('file') ? File(uri.path) : null;
        // 恢复的本地文件可能来自旧安装（容器路径失效），失效时回退为
        // 网络源（localFile 置 null），避免 iOS 上创建文件时抛权限异常。
        if (file != null && !file.existsSync()) {
          _logger.warning(
              'Restored cached file missing, fallback to network: ${file.path}');
          return LazyAudioSource(
            data.bvid,
            data.cid,
            localFile: null,
            tag: MediaItem(
              id: data.id,
              title: data.title,
              artist: data.artist,
              artUri: Uri.parse(data.artUri),
              duration: Duration(seconds: data.duration),
              extras: {
                'bvid': data.bvid,
                'cid': data.cid,
                'aid': data.aid,
                'multi': data.multi,
                'raw_title': data.rawTitle,
                'mid': data.mid,
                'cached': false,
              },
            ),
          );
        }
        return LazyAudioSource(
          data.bvid,
          data.cid,
          localFile: file,
          tag: MediaItem(
            id: data.id,
            title: data.title,
            artist: data.artist,
            artUri: Uri.parse(data.artUri),
            duration: Duration(seconds: data.duration),
            extras: {
              'bvid': data.bvid,
              'cid': data.cid,
              'aid': data.aid,
              'multi': data.multi,
              'raw_title': data.rawTitle,
              'mid': data.mid,
              'cached': data.cached,
            },
          ),
        );
      }
    }));

    return (
      sources.whereType<IndexedAudioSource>().toList(),
      prefs.getInt(currentIndexId) ?? 0
    );
  }

  static Future<int> getPlayPosition() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getInt('play_position') ?? 0;
  }

  static Future<void> setPlayPosition(int position) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setInt('play_position', position);
  }

  static Future<void> setHistoryReported(bool value) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool('enable_history_report', value);
  }

  static Future<bool> getHistoryReported() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getBool('enable_history_report') ?? true;
  }

  static Future<void> setReportHistoryInterval(int interval) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setInt('report_history_interval', interval);
  }

  static Future<int> getReportHistoryInterval() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getInt('report_history_interval') ?? 10;
  }

  // 获取定时停止播放的时间（分钟）
  static Future<int?> getSleepTimerMinutes() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getInt('sleep_timer_minutes');
  }

  // 设置定时停止播放的时间（分钟）
  static Future<void> setSleepTimerMinutes(int? minutes) async {
    final prefs = await SharedPreferencesService.instance;
    if (minutes == null) {
      await prefs.remove('sleep_timer_minutes');
    } else {
      await prefs.setInt('sleep_timer_minutes', minutes);
    }
  }

  /// 已废弃：仅用于导入歌单功能的旧数据兼容，后续版本将随功能一并移除。
  @Deprecated('导入歌单功能已废弃，将在后续版本移除')
  static Future<void> savePlaylistSearchResult(
      List<Map<String, dynamic>> result, String text, int favid) async {
    final prefs = await SharedPreferencesService.instance;
    final content = {
      'result': jsonEncode(result),
      'favid': favid,
      'text': text,
    };
    await prefs.setString('playlist_search_result', jsonEncode(content));
  }

  /// 已废弃：仅用于导入歌单功能的旧数据兼容，后续版本将随功能一并移除。
  @Deprecated('导入歌单功能已废弃，将在后续版本移除')
  static Future<Map<String, dynamic>?> getPlaylistSearchResult() async {
    final prefs = await SharedPreferencesService.instance;
    final result = prefs.getString('playlist_search_result');
    if (result == null) return null;
    final Map<String, dynamic> decoded = jsonDecode(result);
    decoded['result'] = (jsonDecode(decoded['result']) as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    return decoded;
  }

  static Future<double?> getPlaybackSpeed() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getDouble('playback_speed');
  }

  static Future<void> setPlaybackSpeed(double speed) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setDouble('playback_speed', speed);
  }

  static Future<bool> saveFavHideList(Set<int> result) async {
    final prefs = await SharedPreferencesService.instance;
    return await prefs.setString('fav_hide_list', jsonEncode(result.toList()));
  }

  static Future<Set<int>?> getFavHideList() async {
    final prefs = await SharedPreferencesService.instance;
    final result = prefs.getString('fav_hide_list');
    if (result == null) return null;
    List<int> list = List<int>.from(jsonDecode(result));
    return Set.from(list);
  }

  /// B 站音频流音质 id（dash.audio[].id）
  static const int kAudioQualityAuto = 0; // 自动（最高可用音质）
  static const int kAudioQualityHiRes = 30251; // Hi-Res 无损
  static const int kAudioQuality192K = 30280; // 高音质 192K
  static const int kAudioQuality132K = 30232; // 标准 132K
  static const int kAudioQuality64K = 30216; // 流畅 64K

  /// 音质 id -> 展示名称
  static const Map<int, String> audioQualityLabels = {
    kAudioQualityAuto: '自动（不含 Hi-Res）',
    kAudioQualityHiRes: 'Hi-Res 无损',
    kAudioQuality192K: '高音质 192K',
    kAudioQuality132K: '标准 132K',
    kAudioQuality64K: '流畅 64K',
  };

  static Future<void> setAudioQuality(int value) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setInt('audio_quality', value);
  }

  static Future<int> getAudioQuality() async {
    final prefs = await SharedPreferencesService.instance;
    final value = prefs.getInt('audio_quality');
    if (value != null) return value;
    // 迁移旧的 hi_res_first 布尔偏好：开过高音质 -> Hi-Res，否则自动
    return (prefs.getBool('hi_res_first') ?? false)
        ? kAudioQualityHiRes
        : kAudioQualityAuto;
  }

  static Future<void> setReactToInterruption(bool value) async {
    final prefs = await SharedPreferencesService.instance;
    await prefs.setBool('react_to_interruption', value);
  }

  static Future<bool> getReactToInterruption() async {
    final prefs = await SharedPreferencesService.instance;
    return prefs.getBool('react_to_interruption') ?? true;
  }
}
