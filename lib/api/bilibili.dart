import 'dart:convert' as convert;
import 'dart:math';

import 'package:bmsc/api/bilibili_api_constant.dart';
import 'package:bmsc/model/comment.dart';
import 'package:bmsc/model/dynamic.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/model/history.dart';
import 'package:bmsc/model/login.dart';
import 'package:bmsc/model/meta.dart';
import 'package:bmsc/model/myinfo.dart';
import 'package:bmsc/model/search.dart';
import 'package:bmsc/model/subtitle.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/model/user_card.dart';
import 'package:bmsc/model/user_upload.dart' show UserUploadResult;
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/service/connection_service.dart';
import 'package:bmsc/util/bili_sign.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/crypto.dart' as crypto;
import 'package:dio/dio.dart';

class BilibiliAPI {
  static final _logger = LoggerUtils.getLogger('BilibiliAPI');

  /// 完整 cookie 串（buvid3;SESSDATA;bili_jct;DedeUserID;...）
  late String cookies;
  late Map<String, String> headers;
  Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
  bool noNetwork = false;
  ConnectionService connectionService = ConnectionService.getInstance();

  /// cookie 组件（CookieJar 模式，对齐 BiliPai：自动注入完整 cookie 组）
  final Map<String, String> _cookieMap = {};

  String _buvid3 = '';

  BilibiliAPI({bool enableConnectivity = true}) {
    if (enableConnectivity) {
      connectionService.initialize();
      connectionService.connectionChange.listen((result) {
        noNetwork = !result;
      });
    }
    noNetwork = !connectionService.hasConnection;
  }

  String _buildCookieString() {
    // 按 cookie 名排序拼接，保证稳定
    final entries = _cookieMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> setCookie(String cookie, {bool save = false}) async {
    if (save) {
      await SharedPreferencesService.setCookie(cookie);
    }
    // 解析 k=v 对合并进 cookie 组
    for (final part in cookie.split(';')) {
      final idx = part.indexOf('=');
      if (idx > 0) {
        _cookieMap[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
      }
    }
    cookies = _buildCookieString();
    _setupHeaders();
    _logger.info('setCookies: $cookie');
  }

  /// 直接设置单个 cookie 值（不持久化）
  void setCookieValue(String name, String value) {
    if (value.isEmpty) {
      _cookieMap.remove(name);
    } else {
      _cookieMap[name] = value;
    }
    cookies = _buildCookieString();
  }

  /// 登录成功后应用完整会话（cookie 合并 + buvid3/DedeUserID），可选持久化
  Future<void> applyLoginCookies(Map<String, String> sessionCookies,
      {bool save = false}) async {
    final buvid3 = sessionCookies['buvid3'] ?? sessionCookies['buvid'];
    if (buvid3 != null && buvid3.isNotEmpty) {
      _buvid3 = buvid3;
      await SharedPreferencesService.setBuvid3(buvid3);
    }
    _cookieMap.addAll(sessionCookies);
    cookies = _buildCookieString();
    if (save) {
      await SharedPreferencesService.setCookie(cookies);
    }
    _setupHeaders();
  }

  void clearCookies() {
    _cookieMap.clear();
    cookies = '';
    _setupHeaders();
  }

  void _setupHeaders() {
    final ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/113.0";
    // 只保留正常 Web 端请求头（对齐 BiliPai：不携带伪造的 app-key / x-bili-* 设备指纹头）
    headers = {
      if (cookies.isNotEmpty) 'cookie': cookies,
      'User-Agent': ua,
      'referer': "https://www.bilibili.com",
      'Origin': "https://www.bilibili.com",
    };
    dio.interceptors.clear();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // App 端登录请求（带 app-key 头）不混入 Web 端指纹头（cookie/
        // referer/Origin/桌面 UA）：passport 风控校验 UA 与 app 签名 body
        // 的一致性，桌面 UA 会以 -105「验证码错误」拒绝（真机实测）。
        if (options.headers.containsKey('app-key')) {
          return handler.next(options);
        }
        final merged = <String, dynamic>{...headers}..addAll(options.headers);
        options.headers = merged;
        return handler.next(options);
      },
      onError: (e, handler) {
        invalidateAccessKeyIfInvalid(e.response);
        return handler.next(e);
      },
    ));
  }

  Future<void> resetCookies() async {
    try {
      final response = await dio.get("https://www.bilibili.com");
      final cookie = response.headers['set-cookie'];
      _logger.info('init cookies: ${response.headers['set-cookie']}');
      if (cookie != null) {
        setCookie(cookie.join('; '), save: true);
      }
    } catch (e) {
      _logger.severe('resetCookies failed: $e');
      if (cookies.isNotEmpty) {
        setCookie(cookies, save: true);
      }
    }
  }

  /// 确保 buvid3 匿名身份存在（对齐 BiliPai CookieJar，UUID+infoc）
  Future<void> ensureBuvid3() async {
    if (_buvid3.isNotEmpty) return;
    var buvid3 = await SharedPreferencesService.getBuvid3();
    if (buvid3 == null || buvid3.isEmpty) {
      buvid3 =
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${Random().nextInt(1 << 30).toRadixString(16)}infoc';
      await SharedPreferencesService.setBuvid3(buvid3);
    }
    _buvid3 = buvid3;
    _cookieMap['buvid3'] = buvid3;
    cookies = _buildCookieString();
    _setupHeaders();
  }

  /// access_key 失效（-101）时清除，下次自动回退 web 接口
  void invalidateAccessKeyIfInvalid(Response? response) {
    if (response == null) return;
    final body = response.data;
    if (body is Map && body['code'] == -101) {
      _logger.warning('access_key invalid (-101), clearing token');
      SharedPreferencesService.setAccessToken('')
          .catchError((_) {});
    }
  }

  Future<T?> _callAPI<T>(String url,
      {Map<String, dynamic>? queryParameters,
      T? Function(dynamic data)? callback,
      Function(dynamic data)? callbackAsync,
      bool isPost = false,
      String unwrapKey = "data",
      bool needDecode = false,
      Map<String, dynamic>? extraHeaders}) async {
    try {
      if (noNetwork) {
        _logger.info("no network. return null");
        return null;
      }
      final options = Options(headers: extraHeaders ?? {});
      final response = isPost
          ? await dio.post(url,
              queryParameters: queryParameters, options: options)
          : await dio.get(url,
              queryParameters: queryParameters, options: options);
      _logger.info('calling API: ${response.requestOptions.uri}');
      var data = response.data;
      if (needDecode) {
        data = convert.jsonDecode(data);
      }
      _logger.info(
          'API response code=${data['code']} msg=${data['message']} dataKeys=${data['data'] is Map ? (data['data'] as Map).keys : data['data'].runtimeType}');
      if ((unwrapKey == "data" && data['code'] != 0) ||
          data[unwrapKey] == null) {
        _logger.info(
            '_callAPI returning null: code=${data['code']} unwrapKey=$unwrapKey hasData=${data[unwrapKey] != null}');
        return null;
      }
      data = data[unwrapKey];
      if (callback != null) {
        return callback(data);
      }
      if (callbackAsync != null) {
        return await callbackAsync(data);
      }
      return data;
    } on DioException catch (e) {
      _logger.info('DioException: ${e.response}');
      if (e.response?.statusCode == 412) {
        throw Exception('错误代码 412，可能触发了 B 站风控，请等待一段时间后重试');
      }
      return null;
    } catch (e) {
      _logger.severe('Error calling API: $e');
      return null;
    }
  }

  Future<List<T>?> _callAPIMultiPage<T>(String url,
      {Map<String, dynamic>? queryParameters,
      required Map<String, dynamic> Function(int page) params,
      required List<T> Function(dynamic data) extract,
      required bool Function(dynamic data, int len) hasMoreCheck}) async {
    List<T> ret = [];
    int pn = 1;
    dynamic data;
    do {
      data = await _callAPI(url,
          queryParameters: {...?queryParameters, ...params(pn)});
      if (data == null) {
        return null;
      }
      final pageItems = extract(data);
      // 空页即终止：hasMoreCheck 依赖的计数若包含失效内容（B 站
      // media_count 计失效条目而 medias 不返回），继续翻页只会
      // 反复请求空数据甚至死循环
      if (pageItems.isEmpty) break;
      ret.addAll(pageItems);
      ++pn;
    } while (hasMoreCheck(data, ret.length));
    return ret;
  }

  Future<MyInfo?> getMyInfo() {
    return _callAPI(apiMyInfoUrl, callback: (data) => MyInfo.fromJson(data));
  }

  /// 获取收藏夹列表
  /// rid: 视频稿件 avid ，检查收藏夹是否包含该稿件。
  /// rid 为空时用分页接口 created/list（返回收藏夹封面，供主页网格
  /// 封面兜底）；rid 非空沿用 list-all（ fav_state 标记包含关系）。
  Future<List<Fav>?> getFavs(int uid, {int? rid}) async {
    if (rid != null) {
      return _callAPI(apiFavsUrl,
          queryParameters: {'up_mid': uid, 'rid': rid},
          callback: (data) => FavResult.fromJson(data).list);
    }
    return _callAPIMultiPage(apiFavListUrl,
        params: (pn) => {'up_mid': uid, 'pn': pn, 'ps': 50, 'platform': 'web'},
        extract: (data) =>
            (data['list'] as List).map((x) => Fav.fromJson(x)).toList(),
        hasMoreCheck: (data, len) => len < (data['count'] as int? ?? 0));
  }

  Future<List<Fav>?> getCollection(int uid) async {
    return _callAPIMultiPage(apiCollectionUrl,
        params: (pn) => {'up_mid': uid, 'pn': pn, 'ps': 20, 'platform': 'web'},
        extract: (data) =>
            (data['list'] as List).map((x) => Fav.fromJson(x)).toList(),
        hasMoreCheck: (data, _) => data['has_more'] as bool);
  }

  /// 合集/收藏的合集内容：season/list 接口忽略 ps/pn 参数、一次返回
  /// 全部 medias（实测 163 条的合集 ps=20&pn=9 仍返回全量），且响应
  /// 无 has_more 字段——这里只请求一次，不做分页累加。
  /// （原 len < media_count 的翻页判断在 media_count 含失效条目而
  /// medias 不含时会多翻一轮，把同一批条目重复累加导致缓存主键冲突）
  Future<List<Meta>?> getCollectionMetas(int mid) async {
    final data = await _callAPI(apiCollectionMetasUrl,
        queryParameters: {'season_id': mid, 'ps': 20, 'pn': 1});
    if (data == null) return null;
    return _extractCollectionMetas(data);
  }

  /// 只拉取收藏的合集第一页内容（主页封面堆叠的轻量兜底）
  Future<List<Meta>?> getCollectionMetasFirstPage(int mid) async {
    final data = await _callAPI(apiCollectionMetasUrl,
        queryParameters: {'season_id': mid, 'ps': 20, 'pn': 1});
    if (data == null) return null;
    return _extractCollectionMetas(data);
  }

  List<Meta> _extractCollectionMetas(dynamic data) =>
      ((data['medias'] as List?) ?? [])
          .map((x) => x as Map<String, dynamic>)
          // 同 _extractFavMetas：过滤失效视频
          .where((x) =>
              (x['bvid'] as String?)?.isNotEmpty == true &&
              x['title'] != _invalidVideoTitle)
          .map((x) => Meta(
                bvid: x['bvid'],
                title: x['title'],
                artist: x['upper']['name'],
                mid: x['upper']['mid'],
                aid: x['id'],
                duration: x['duration'],
                artUri: x['cover'],
              ))
          .toList();

  Future<List<Meta>?> getFavMetas(int mid) async {
    return _callAPIMultiPage(apiFavMetasUrl,
        params: (pn) => {
              'media_id': mid,
              'ps': 40,
              'pn': pn,
            },
        extract: (data) => _extractFavMetas(data),
        hasMoreCheck: (data, _) => data['has_more'] as bool);
  }

  /// 只拉取收藏夹第一页内容（主页封面堆叠的轻量兜底，不拉全量分页）
  Future<List<Meta>?> getFavMetasFirstPage(int mid) async {
    final data = await _callAPI(apiFavMetasUrl,
        queryParameters: {'media_id': mid, 'ps': 20, 'pn': 1});
    if (data == null) return null;
    return _extractFavMetas(data);
  }

  /// B 站对失效视频的标题标记（fav/season 接口对已删除视频返回该
  /// 标题 + 原 UP 名 + 无封面）
  static const _invalidVideoTitle = '已失效视频';

  List<Meta> _extractFavMetas(dynamic data) => ((data['medias'] as List?) ?? [])
      .map((x) => x as Map<String, dynamic>)
      // 过滤失效视频：不可播（解析必失败，按「不自动跳歌」策略会
      // 停在静音 dummy 上），混进队列后随机播放会随机轮到并卡住
      //（实测用户收藏夹内共 74 个失效视频）。在提取层过滤保证
      // 展示列表与播放列表一致，不引入点击索引错位
      .where((x) =>
          (x['bvid'] as String?)?.isNotEmpty == true &&
          x['title'] != _invalidVideoTitle)
      .map((x) => Meta(
            bvid: x['bvid'],
            title: x['title'],
            artist: x['upper']['name'],
            mid: x['upper']['mid'],
            aid: x['id'],
            duration: x['duration'],
            artUri: x['cover'],
            parts: x['page'],
          ))
      .toList();

  Future<UserInfoResult?> getUserInfo(int mid) {
    return _callAPI(apiUserInfoUrl,
        queryParameters: {'mid': mid},
        callback: (data) => UserInfoResult.fromJson(data));
  }

  Future<(List<Meta>, int)?> getUserUploadMetas(int mid, int pn) async {
    final params = await crypto.encodeParams({
      'mid': mid,
      'ps': 30,
      'pn': pn,
      'order': 'pubdate',
      'platform': 'web',
      'web_location': 333.1387,
      'order_avoided': true,
      'dm_img_list': '[]',
      'dm_img_str': crypto.generateDmImgStr(),
      'dm_cover_img_str': crypto.generateDmCoverImgStr(),
      'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
    });
    return _callAPI(apiUserUploadsUrl, queryParameters: params, extraHeaders: {
      'referer': 'https://space.bilibili.com/$mid',
      'origin': 'https://space.bilibili.com',
      'User-Agent': headers['User-Agent'],
    }, callback: (data) {
      final uploads = UserUploadResult.fromJson(data);
      final nextPn =
          uploads.page.pn * uploads.page.ps < uploads.page.count ? pn + 1 : -1;
      return (
        uploads.list.vlist
            .map((x) => Meta(
                aid: x.aid,
                bvid: x.bvid,
                mid: mid,
                title: x.title,
                artist: x.author,
                artUri: x.pic,
                parts: x.play,
                duration: int.parse(x.length.split(':')[0]) * 60 +
                    int.parse(x.length.split(':')[1])))
            .toList(),
        nextPn
      );
    });
  }

  Future<CommentData?> getComment(String aid, String? offset) async {
    return _callAPI(apiCommentUrl,
        queryParameters: await crypto
            .encodeParams({'oid': aid, 'type': 1, 'pagination_str': offset}),
        callback: (data) => CommentData.fromJson(data));
  }

  Future<CommentData?> getCommentsOfComment(int oid, int root, int pn) {
    return _callAPI(apiCommentsOfCommentUrl,
        queryParameters: {
          'type': 1,
          'oid': oid,
          'root': root,
          'pn': pn,
          'ps': 20
        },
        callback: (data) => CommentData.fromJson(data));
  }

  Future<SearchResult?> search(String value, int pn) async {
    final params = await crypto
        .encodeParams({'search_type': 'video', 'keyword': value, 'page': pn});
    if (params == null) return null;
    return _callAPI(apiSearchUrl,
        queryParameters: params,
        callback: (data) => SearchResult.fromJson(data));
  }

  Future<HistoryResult?> getHistory(int? timestamp) {
    _logger.info('getHistory: timestamp=$timestamp');
    return _callAPI(apiHistoryUrl, queryParameters: {
      'type': 'all',
      'ps': 20,
      'max': timestamp ?? 0,
      'view_at': timestamp ?? 0,
    }, callback: (data) {
      _logger.info('getHistory: list len=${(data['list'] as List?)?.length}');
      final result = HistoryResult.fromJson(data);
      _logger.info('getHistory: parsed ${result.list.length} items');
      return result;
    });
  }

  Future<DynamicResult?> getDynamics(String? offset) {
    _logger.info('getDynamics: offset=$offset');
    return _callAPI(apiDynamicUrl, queryParameters: {
      'type': 'video',
      'offset': offset ?? '',
      'timezone_offset': '-480',
      'features': 'itemOpusStyle,listOnlyfans,onlyfansQaCard',
    }, callback: (data) {
      _logger.info(
          'getDynamics: data list len=${(data['items'] as List?)?.length} hasMore=${data['has_more']}');
      final result = DynamicResult.fromJson(data);
      _logger.info(
          'getDynamics: parsed ${result.items.length} items offset=${result.offset}');
      return result;
    });
  }

  Future<VidResult?> getVidDetail({String? bvid, String? aid}) async {
    assert(bvid != null || aid != null, 'Either bvid or aid must be provided');
    assert(!(bvid != null && aid != null), 'Cannot provide both bvid and aid');
    return _callAPI(apiVideoDetailUrl,
        queryParameters: {
          'bvid': bvid,
          'aid': aid,
        },
        callback: (data) => VidResult.fromJson(data));
  }

  /// 按音质偏好排序候选音频流：偏好音质排首位（LazyAudioSource 取 first 播放），
  /// 其余保持 API 返回顺序作为回退（_fetch 重试会遍历全部候选）。
  /// AUTO 不优先 Hi-Res：与旧版 hi_res_first=false 的默认行为一致，避免老用户
  /// 迁移后默认消耗数倍流量与内存（Hi-Res 单首可达数十上百 MB）。非 Hi-Res
  /// 偏好时 flac 追加到队尾，仅作 _fetch 重试的最后手段与音质列表展示。
  static List<Audio> _orderAudioByQuality(Dash dash, int preferredId) {
    final candidates = [...dash.audio];
    if (preferredId != SharedPreferencesService.kAudioQualityAuto &&
        preferredId != SharedPreferencesService.kAudioQualityHiRes) {
      final index = candidates.indexWhere((a) => a.id == preferredId);
      if (index > 0) {
        final preferred = candidates.removeAt(index);
        candidates.insert(0, preferred);
      }
    }
    if (dash.flac?.audio != null) {
      if (preferredId == SharedPreferencesService.kAudioQualityHiRes) {
        candidates.insert(0, dash.flac!.audio!);
      } else {
        candidates.add(dash.flac!.audio!);
      }
    }
    return candidates;
  }

  Future<List<Audio>?> getAudio(String bvid, int cid) async {
    final quality = await SharedPreferencesService.getAudioQuality();
    final params = await crypto.encodeParams({
      'bvid': bvid,
      'cid': cid,
      'fnval': 4048,
      'fnver': '0',
      'fourk': '1',
    });
    if (params == null) return null;
    return _callAPI(apiAudioUrl, queryParameters: params,
        callback: (data) =>
            _orderAudioByQuality(TrackResult.fromJson(data).dash, quality));
  }

  /// App 端 playurl（appkey 签名 + access_key，对齐 BiliPai）。
  /// 需要 access_token；拿不到（未登录/-101）时返回 null，调用方回退 web 接口。
  Future<List<Audio>?> getAudioApp(String bvid, int cid,
      {String? accessToken}) async {
    if (accessToken == null || accessToken.isEmpty) return null;
    final quality = await SharedPreferencesService.getAudioQuality();
    final usesTv = await SharedPreferencesService.getAccessTokenPlatform() ==
        'tv';
    final params = <String, String>{
      'bvid': bvid,
      'cid': cid.toString(),
      // qn=127 才会返回 Hi-Res 流；指定低档位音质时无需请求
      'qn': (quality == SharedPreferencesService.kAudioQualityAuto ||
              quality == SharedPreferencesService.kAudioQualityHiRes)
          ? '127'
          : '64',
      // fnval=16（MP4 基础格式，兼容 TV/Android 两组 appkey 签名）
      // 注意：BiliPai 视频场景的 20432(Web DASH + APP-only HDR) 在
      // App 端 playurl 会返回 -400，音频场景用 16 即可拿到 DASH audio
      'fnval': '16',
      'fnver': '0',
      'fourk': '1',
      'access_key': accessToken,
      'appkey': usesTv ? BiliSign.tvAppKey : BiliSign.androidAppKey,
      'ts': BiliSign.getTimestamp(),
      'platform': 'android',
      'mobi_app': usesTv ? 'android_tv_yst' : 'android',
      'device': 'android',
    };
    final signed = usesTv
        ? BiliSign.signForTv(params)
        : BiliSign.signForAndroidApi(params);
    try {
      final resp = await dio.get(apiAppPlayUrlUrl, queryParameters: signed);
      final body = resp.data;
      if (body['code'] != 0) {
        _logger.info('getAudioApp failed: code=${body['code']} ${body['message']}');
        if (body['code'] == -101) {
          await SharedPreferencesService.setAccessToken('');
        }
        return null;
      }
      // 与 web 版一致：TrackResult 解析的是 data 子对象（非整个响应体）
      return _orderAudioByQuality(
          TrackResult.fromJson(body['data']).dash, quality);
    } catch (e) {
      _logger.severe('getAudioApp error: $e');
      return null;
    }
  }

  Future<bool?> favoriteVideo(int avid, List<int> adds, List<int> dels) {
    return _callAPI(
      apiDoFavVideoUrl,
      queryParameters: {
        'rid': avid,
        'type': 2,
        'add_media_ids': adds.join(','),
        'del_media_ids': dels.join(','),
        'csrf': crypto.extractCSRF(cookies),
      },
      callback: (_) => true,
      isPost: true,
    );
  }

  Future<bool?> isFavorited(int aid) async {
    return _callAPI(apiIsFavoritedUrl,
        queryParameters: {'aid': aid}, callback: (data) => data['favoured']);
  }

  Future<Fav?> createFavFolder(String name, {bool hide = false}) async {
    return _callAPI(apiCreateFavFolderUrl,
        queryParameters: {
          'title': name,
          'privacy': hide ? 1 : 0,
          'csrf': crypto.extractCSRF(cookies)
        },
        callback: (data) => Fav.fromJson(data),
        isPost: true);
  }

  Future<bool?> deleteFavFolder(int mediaId) {
    return _callAPI(apiDeleteFavFolderUrl,
        queryParameters: {
          'media_ids': mediaId,
          'csrf': crypto.extractCSRF(cookies)
        },
        isPost: true);
  }

  Future<bool?> editFavFolder(int mediaId, String name, {bool hide = false}) {
    return _callAPI(apiEditFavFolderUrl,
        queryParameters: {
          'media_id': mediaId,
          'title': name,
          'privacy': hide ? 1 : 0,
          'csrf': crypto.extractCSRF(cookies)
        },
        isPost: true);
  }

  Future<List<Meta>?> getRelatedVideos(int aid,
      {List<int>? tidWhitelist}) async {
    return _callAPI(apiRelatedVideosUrl,
        queryParameters: {'aid': aid},
        callback: (data) => (data as List)
            .where((video) => tidWhitelist?.contains(video['tid']) ?? true)
            .map((video) => Meta(
                  bvid: video['bvid'],
                  title: video['title'],
                  artist: video['owner']['name'],
                  mid: video['owner']['mid'],
                  aid: video['aid'],
                  duration: video['duration'],
                  artUri: video['pic'],
                  parts: video['videos'],
                ))
            .toList());
  }

  Future<List<String>?> getSearchSuggestions(String keyword) async {
    return _callAPI(apiSearchSuggestionsUrl,
        queryParameters: {'term': keyword},
        unwrapKey: 'result',
        needDecode: true, callback: (data) {
      List<String> suggestions = [];
      for (final tag in data['tag']) {
        suggestions.add(tag['term'] as String);
      }
      return suggestions;
    });
  }

  Future<void> reportHistory(int aid, int cid, int? progress) {
    return _callAPI(apiReportHistoryUrl,
        queryParameters: {
          'aid': aid,
          'cid': cid,
          'progress': progress,
          'csrf': crypto.extractCSRF(cookies),
        },
        isPost: true);
  }

  Future<String?> getRawWbiKey() async {
    final prefs = await SharedPreferencesService.instance;
    final rawWbiKey = prefs.getString('raw_wbi_key');
    final lastUpdateDay = prefs.getInt('img_sub_key_last_update');
    final currentDay = (DateTime.now().millisecondsSinceEpoch ~/ 86400000);
    if (lastUpdateDay != null &&
        rawWbiKey != null &&
        lastUpdateDay == currentDay) {
      return rawWbiKey;
    }
    try {
      final response = await dio.get(apiNavUrl);
      final body = response.data;
      if (body['data'] == null) return null;
      final wbiImg = body['data']['wbi_img'];
      if (wbiImg == null) return null;
      final imgUrl = wbiImg['img_url'] as String?;
      final subUrl = wbiImg['sub_url'] as String?;
      if (imgUrl == null || subUrl == null) return null;
      final imgKey = _basename(imgUrl, stripExt: true);
      final subKey = _basename(subUrl, stripExt: true);
      final rawWbiKeyNew = imgKey + subKey;
      await prefs.setString('raw_wbi_key', rawWbiKeyNew);
      await prefs.setInt('img_sub_key_last_update', currentDay);
      _logger.info('New raw_wbi_key: $rawWbiKeyNew');
      return rawWbiKeyNew;
    } catch (e) {
      _logger.severe('Failed to get WBI key: $e');
      return null;
    }
  }

  String _basename(String url, {bool stripExt = false}) {
    final start = url.lastIndexOf('/') + 1;
    if (!stripExt) return url.substring(start);
    final dot = url.lastIndexOf('.');
    if (dot > start) return url.substring(start, dot);
    return url.substring(start);
  }

  Future<Map<String, String>?> getLoginCaptcha() async {
    return _callAPI(apiLoginCaptchaUrl,
        queryParameters: {'source': 'main_web'},
        callback: (data) => {
              'challenge': data['geetest']['challenge'],
              'gt': data['geetest']['gt'],
              'token': data['token'],
            });
  }

  Future<List<(String, String)>?> getSubTitleInfo(int aid, int cid) async {
    return _callAPI(apiPlayer, queryParameters: {'aid': aid, 'cid': cid},
        callback: (data) {
      final subtitles = data['subtitle']['subtitles'] as List<dynamic>;
      return subtitles.map((x) {
        var url = x['subtitle_url'] as String;
        if (url != "" && url[0] == '/') {
          url = "https:$url";
        }
        return (x['lan_doc'] as String, url);
      }).toList();
    });
  }

  Future<List<BilibiliSubtitle>?> getSubTitleData(String url) async {
    return _callAPI(url,
        unwrapKey: "body",
        callback: (data) => (data as List<dynamic>)
            .map((x) => BilibiliSubtitle.fromJson(x))
            .toList());
  }

  Future<Map<String, dynamic>?> _getLoginKey() async {
    return _callAPI(apiLoginKeyUrl);
  }

  /// 供登录流程使用的 RSA 公钥（key/hash）
  Future<Map<String, dynamic>?> getLoginKey() => _getLoginKey();

  Future<(bool, String?)> passwordLogin({
    required String username,
    required String password,
    required Map<String, dynamic> geetestResult,
  }) async {
    _logger.info('Logging in with username: $username');
    try {
      final loginKey = await _getLoginKey();
      if (loginKey == null) {
        throw Exception('Failed to get login key');
      }

      final encryptedPassword =
          crypto.encryptPassword(password, loginKey['key']!, loginKey['hash']!);

      final loginResponse = await dio.post(
        apiPasswordLoginUrl,
        queryParameters: {
          'username': username,
          'password': encryptedPassword,
          'token': geetestResult['token'],
          'go_url': 'https://www.bilibili.com',
          'source': 'main-fe-header',
          'challenge': geetestResult['challenge'],
          'validate': geetestResult['validate'],
          'seccode': geetestResult['seccode'],
        },
      );

      if (loginResponse.data['code'] != 0) {
        return (false, "网络错误");
      }

      if (loginResponse.data['data']['status'] != 0) {
        return (false, loginResponse.data['data']['message'] as String);
      }

      final cookies = loginResponse.headers['set-cookie'];
      if (cookies != null) {
        await setCookie(cookies.join(';'), save: true);
      }

      return (true, null);
    } catch (e) {
      _logger.severe('Login error: $e');
      return (false, e.toString());
    }
  }

  Future<(String, String?)> getSmsLoginCaptcha({
    required int tel,
    required Map<String, dynamic> geetestResult,
  }) async {
    try {
      final response = await dio.post(
        apiSmsCaptchaUrl,
        queryParameters: {
          'cid': "86",
          'tel': tel.toString(),
          'source': 'main-fe-header',
          'token': geetestResult['token'],
          'challenge': geetestResult['challenge'],
          'validate': geetestResult['validate'],
          'seccode': geetestResult['seccode'],
        },
      );
      _logger.info(
          'called getSmsCaptcha with url: ${response.requestOptions.uri}');
      if (response.data['code'] != 0) {
        return ("", response.data['message'] as String);
      }
      return (response.data['data']['captcha_key'] as String, null);
    } on DioException catch (e) {
      _logger.info('${e.response?.statusCode}: ${e.response?.data}');
      _logger.severe('Error getting sms captcha: $e');
      return ("", e.toString());
    } catch (e) {
      _logger.severe('Error getting sms captcha: $e');
      return ("", e.toString());
    }
  }

  Future<(bool, String?)> smslogin({
    required int tel,
    required String code,
    required String captchaKey,
  }) async {
    _logger.info('Logging in with sms: $tel');
    try {
      final loginResponse = await dio.post(
        apiSmsLoginUrl,
        queryParameters: {
          'cid': "86",
          'tel': tel.toString(),
          'code': code,
          'captcha_key': captchaKey,
          'source': 'main-fe-header'
        },
      );
      _logger
          .info('called login with url: ${loginResponse.requestOptions.uri}');

      if (loginResponse.data['code'] != 0) {
        return (false, loginResponse.data['message'] as String);
      }

      if (loginResponse.data['data']['status'] != 0) {
        return (false, loginResponse.data['data']['message'] as String);
      }

      final cookies = loginResponse.headers['set-cookie'];
      if (cookies != null) {
        await setCookie(cookies.join(';'), save: true);
      }

      return (true, null);
    } catch (e) {
      _logger.severe('Login error: $e');
      return (false, e.toString());
    }
  }

  Future<(String, String)?> getQrcodeLoginInfo() async {
    return _callAPI(apiGetQrcodeLoginUrl,
        callback: (data) =>
            (data['url'] as String, data['qrcode_key'] as String));
  }

  // ==================== TV 端二维码登录（首选，对齐 BiliPai） ====================

  /// 申请 TV 端二维码（带 appkey 签名）；成功后登录态含 access_token，支持高画质
  Future<TvQrLoginInfo?> getTvQrcodeLoginInfo() async {
    if (noNetwork) return null;
    final params = BiliSign.signForTv({
      'appkey': BiliSign.tvAppKey,
      'local_id': '0',
      'ts': BiliSign.getTimestamp(),
    });
    try {
      final resp = await dio.post(apiGetTvQrcodeLoginUrl,
          data: params,
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final body = resp.data;
      if (body['code'] != 0) {
        _logger.severe('getTvQrcodeLoginInfo failed: ${body['message']}');
        return null;
      }
      return TvQrLoginInfo.fromJson(body['data']);
    } catch (e) {
      _logger.severe('getTvQrcodeLoginInfo error: $e');
      return null;
    }
  }

  /// 轮询 TV 二维码登录状态；成功后 cookies 在 body 的 cookie_info 里返回
  Future<TvQrPollResult?> checkTvQrcodeLoginStatus(String authCode) async {
    final params = BiliSign.signForTv({
      'appkey': BiliSign.tvAppKey,
      'auth_code': authCode,
      'local_id': '0',
      'ts': BiliSign.getTimestamp(),
    });
    try {
      final resp = await dio.post(apiCheckTvQrcodeStatusUrl,
          data: params,
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final body = resp.data;
      final result = TvQrPollResult.fromJson(body);
      if (result.code == 0) {
        _logger.info('TV QR login success, mid=${result.mid}');
      }
      return result;
    } catch (e) {
      _logger.severe('checkTvQrcodeLoginStatus error: $e');
      return null;
    }
  }

  /// TV 端 token 刷新（h5/refresh），返回新 access_token/refresh_token
  Future<TvQrPollResult?> refreshTvToken(
      String accessToken, String refreshToken) async {
    final params = BiliSign.signForTv({
      'appkey': BiliSign.tvAppKey,
      'access_key': accessToken,
      'refresh_token': refreshToken,
      'ts': BiliSign.getTimestamp(),
    });
    try {
      final resp = await dio.post(apiTvTokenRefreshUrl,
          data: params,
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final body = resp.data;
      if (body['code'] != 0) {
        _logger.warning('refreshTvToken failed: ${body['message']}');
        return null;
      }
      final data = body['data'];
      final cookies = <String, String>{};
      final cookieInfo = data?['cookie_info'];
      if (cookieInfo is Map && cookieInfo['cookies'] is List) {
        for (final c in cookieInfo['cookies'] as List) {
          if (c is Map && c['name'] != null) {
            cookies[c['name'] as String] = c['value'] ?? '';
          }
        }
      }
      return TvQrPollResult(
        code: 0,
        mid: data?['mid'] ?? 0,
        accessToken: data?['access_token'] ?? '',
        refreshToken: data?['refresh_token'] ?? '',
        cookies: cookies,
      );
    } catch (e) {
      _logger.severe('refreshTvToken error: $e');
      return null;
    }
  }

  // ==================== App 端密码/短信登录（对齐 BiliPai Android-HD） ====================

  Map<String, String> _androidLoginBaseParams(int ts) => {
        'appkey': BiliSign.androidHdAppKey,
        'build': '2001100',
        'c_locale': 'zh_CN',
        'channel': 'master',
        'disable_rcmd': '0',
        'mobi_app': 'android_hd',
        'platform': 'android',
        's_locale': 'zh_CN',
        'statistics':
            '{"appId":5,"platform":3,"version":"2.0.1","abtest":""}',
        'ts': ts.toString(),
      };

  Map<String, String> _androidLoginDeviceParams(
          String buvid, String deviceId, String encryptedDeviceToken) =>
      {
        'bili_local_id': deviceId,
        'buvid': buvid,
        'device': 'phone',
        'device_id': deviceId,
        'device_name': 'vivo',
        'device_platform': 'Android14vivo',
        'dt': BiliSign.percentEncode(encryptedDeviceToken),
        'local_id': buvid,
      };

  Map<String, String> _geetestParams(CaptchaData? captcha,
          {String? validate, String? seccode, String? challenge}) {
    // challenge 必须用极验 SDK 回显值：原生 SDK 可能给回显 challenge
    // 追加后缀（实测出现 challenge+'lx'），validate 与回显 challenge
    // 绑定；回传注册时的原始 challenge 会被 B 站以 -105「验证码错误」
    // 拒绝（对齐 PiliPlus：gee_challenge 取 res['geetest_challenge']）。
    final c = challenge ?? captcha?.challenge;
    return {
      if (captcha != null && captcha.token.isNotEmpty)
        'recaptcha_token': captcha.token,
      if (c != null && c.isNotEmpty) 'gee_challenge': c,
      if (validate != null && validate.isNotEmpty) 'gee_validate': validate,
      if (seccode != null && seccode.isNotEmpty) 'gee_seccode': seccode,
    };
  }

  /// App 端密码登录（oauth2/login）
  Future<AppLoginResult> passwordLoginApp({
    required String username,
    required String encryptedPassword,
    CaptchaData? captcha,
    String? validate,
    String? seccode,
    String? challenge,
    required String buvid,
    required String deviceId,
    required String encryptedDeviceToken,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      ..._androidLoginBaseParams(ts),
      ..._androidLoginDeviceParams(buvid, deviceId, encryptedDeviceToken),
      ..._geetestParams(captcha,
          validate: validate, seccode: seccode, challenge: challenge),
      'username': username,
      'password': encryptedPassword,
      'permission': 'ALL',
      'from_pv': 'main.homepage.avatar-nologin.all.click',
      'from_url': BiliSign.percentEncode('bilibili://pegasus/promo'),
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiAppPasswordLoginUrl,
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: BiliSign.androidLoginHeaders(buvid),
          ));
      return AppLoginResult.fromResponse(
          resp.data, resp.headers['set-cookie'] ?? []);
    } catch (e) {
      _logger.severe('passwordLoginApp error: $e');
      return AppLoginResult(code: -1, message: e.toString());
    }
  }

  /// App 端发送短信验证码（sms/send）。
  ///
  /// 返回 (captchaKey, error, recaptchaUrl)。B 站当前为两段式（真机实测）：
  /// 裸调不要求验证时直接返回 captcha_key；要求验证时返回 recaptcha_url，
  /// 须用 url 内与本发送会话绑定的 gt/challenge 完成人机验证后带结果重发。
  Future<(String, String?, String?)> sendSmsCaptchaApp({
    required String phone,
    CaptchaData? captcha,
    String? validate,
    String? seccode,
    String? challenge,
    required String buvid,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final params = <String, String>{
      ..._androidLoginBaseParams(ts ~/ 1000),
      ..._geetestParams(captcha,
          validate: validate, seccode: seccode, challenge: challenge),
      'buvid': buvid,
      'local_id': buvid,
      'login_session_id':
          BiliSign.createLoginSessionId(buvid, ts),
      'cid': '86',
      'tel': phone,
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiAppSmsCaptchaUrl,
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: BiliSign.androidLoginHeaders(buvid),
          ));
      final body = resp.data;
      if (body['code'] != 0) {
        // 业务失败（code!=0）也落日志：此前只弹 SnackBar，排障无任何依据
        _logger.warning('sendSmsCaptchaApp rejected: code=${body['code']}, '
            'message=${body['message']}');
        return ("", body['message']?.toString() ?? '发送失败', null);
      }
      final data = body['data'];
      final captchaKey = data?['captcha_key']?.toString() ?? '';
      final recaptchaUrl = data?['recaptcha_url']?.toString() ?? '';
      if (captchaKey.isEmpty && recaptchaUrl.isNotEmpty) {
        // 要求先完成人机验证：把 url 交给调用方解析参数并重发
        return ("", null, recaptchaUrl);
      }
      return (captchaKey, null, null);
    } catch (e) {
      _logger.severe('sendSmsCaptchaApp error: $e');
      return ("", e.toString(), null);
    }
  }

  /// App 端短信登录（login/sms）
  Future<AppLoginResult> smsLoginApp({
    required String phone,
    required String code,
    required String captchaKey,
    required String buvid,
    required String deviceId,
    required String encryptedDeviceToken,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      ..._androidLoginBaseParams(ts),
      ..._androidLoginDeviceParams(buvid, deviceId, encryptedDeviceToken),
      'cid': '86',
      'tel': phone,
      'code': code,
      'captcha_key': captchaKey,
      'from_pv': 'main.my-information.my-login.0.click',
      'from_url': BiliSign.percentEncode('bilibili://user_center/mine'),
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiAppSmsLoginUrl,
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: BiliSign.androidLoginHeaders(buvid),
          ));
      return AppLoginResult.fromResponse(
          resp.data, resp.headers['set-cookie'] ?? []);
    } catch (e) {
      _logger.severe('smsLoginApp error: $e');
      return AppLoginResult(code: -1, message: e.toString());
    }
  }

  // ==================== 密码登录风控（安全中心，对齐 BiliPai） ====================

  /// 获取绑定手机号信息（tmp_code 来自密码登录 status=2 的 url）
  Future<SafeCenterInfo?> getSafeCenterInfo(String tmpCode) async {
    return _callAPI(apiSafeCenterUserInfoUrl,
        queryParameters: {'tmp_code': tmpCode},
        callback: (data) => SafeCenterInfo.fromJson(data));
  }

  /// 获取安全中心极验预捕获参数
  Future<SafeCenterCaptchaPre?> getSafeCenterCaptchaPre() async {
    final options =
        Options(contentType: Headers.formUrlEncodedContentType);
    try {
      final resp = await dio.post(apiSafeCenterCaptchaPreUrl,
          options: options);
      final body = resp.data;
      if (body['code'] != 0) return null;
      return SafeCenterCaptchaPre.fromJson(body['data']);
    } catch (e) {
      _logger.severe('getSafeCenterCaptchaPre error: $e');
      return null;
    }
  }

  /// 风控短信发送（参数精确对齐 BiliPai buildSafeCenterSmsSendParams）
  Future<(String, String?)> sendSafeCenterSms({
    required String tmpCode,
    required String recaptchaToken,
    required String challenge,
    required String validate,
    required String seccode,
    required String referer,
  }) async {
    final params = <String, String>{
      'disable_rcmd': '0',
      'sms_type': 'loginTelCheck',
      'tmp_code': tmpCode,
      'gee_challenge': challenge,
      'gee_validate': validate,
      'gee_seccode': seccode,
      'recaptcha_token': recaptchaToken,
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiSafeCenterSmsSendUrl,
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: {'Referer': referer},
          ));
      final body = resp.data;
      if (body['code'] != 0) {
        return ("", body['message']?.toString() ?? '发送失败');
      }
      return (body['data']?['captcha_key']?.toString() ?? "", null);
    } catch (e) {
      _logger.severe('sendSafeCenterSms error: $e');
      return ("", e.toString());
    }
  }

  /// 风控短信校验（参数精确对齐 BiliPai buildSafeCenterSmsVerifyParams），成功后返回 exchange code
  Future<(String, String?)> verifySafeCenterSms({
    required String code,
    required String tmpCode,
    required String requestId,
    required String source,
    required String captchaKey,
    required String referer,
  }) async {
    final params = <String, String>{
      'type': 'loginTelCheck',
      'code': code,
      'tmp_code': tmpCode,
      'request_id': requestId,
      'source': source,
      'captcha_key': captchaKey,
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiSafeCenterSmsVerifyUrl,
          data: signed,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: {'Referer': referer},
          ));
      final body = resp.data;
      if (body['code'] != 0) {
        return ("", body['message']?.toString() ?? '验证失败');
      }
      return (body['data']?['code']?.toString() ?? "", null);
    } catch (e) {
      _logger.severe('verifySafeCenterSms error: $e');
      return ("", e.toString());
    }
  }

  /// 用 exchange code 换 access_token（参数精确对齐 BiliPai buildOauth2AccessTokenParams）
  Future<AppLoginResult> oauth2AccessToken(
      {required String code, required String buvid}) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'appkey': BiliSign.androidHdAppKey,
      'build': '2001100',
      'buvid': buvid,
      'code': code,
      'disable_rcmd': '0',
      'grant_type': 'authorization_code',
      'local_id': buvid,
      'mobi_app': 'android_hd',
      'platform': 'android',
      'ts': ts.toString(),
    };
    final signed = BiliSign.signForAndroidHdLogin(params);
    try {
      final resp = await dio.post(apiOauth2AccessTokenUrl,
          data: signed,
          options: Options(contentType: Headers.formUrlEncodedContentType));
      return AppLoginResult.fromResponse(
          resp.data, resp.headers['set-cookie'] ?? []);
    } catch (e) {
      _logger.severe('oauth2AccessToken error: $e');
      return AppLoginResult(code: -1, message: e.toString());
    }
  }

  Future<int?> checkQrcodeLoginStatus(String qrcodeKey) async {
    try {
      final loginResponse = await dio.get(
        apiCheckQrcodeLoginStatusUrl,
        queryParameters: {
          'qrcode_key': qrcodeKey,
        },
      );
      _logger
          .info('called login with url: ${loginResponse.requestOptions.uri}');

      if (loginResponse.data['code'] != 0) {
        _logger.severe('Login error: ${loginResponse.data['message']}');
        return null;
      }

      if (loginResponse.data['data']['code'] == 0) {
        final cookies = loginResponse.headers['set-cookie'];
        if (cookies != null) {
          await setCookie(cookies.join(';'), save: true);
        }
        return 0;
      }
      return loginResponse.data['data']['code'];
    } catch (e) {
      _logger.severe('Login error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> getHotSearch() {
    return _callAPI(apiHotSearchUrl,
        queryParameters: {'limit': '10'},
        callback: (data) =>
            (data['trending']['list'] as List).cast<Map<String, dynamic>>());
  }

  Future<List<Meta>?> getRanking(int rid) {
    return _callAPI(apiRankingUrl,
        queryParameters: {'rid': rid},
        callback: (data) => (data['list'] as List)
            .map((x) => Meta(
                bvid: x['bvid'],
                title: x['title'],
                artist: x['owner']['name'],
                mid: x['owner']['mid'],
                aid: x['aid'],
                duration: x['duration'],
                artUri: x['pic']))
            .toList());
  }

  Future<List<Map<String, dynamic>>?> getPageList(String bvid) {
    return _callAPI(apiPageListUrl,
        queryParameters: {'bvid': bvid},
        callback: (data) => (data as List).cast<Map<String, dynamic>>());
  }

  Future<Map<String, dynamic>?> getUserInfoByMid(int mid) async {
    final params = await crypto.encodeParams({'mid': mid.toString()});
    return _callAPI(apiUserInfoByMidUrl, queryParameters: params);
  }

  Future<List<Map<String, dynamic>>?> getToViewList() {
    return _callAPI(apiToViewUrl,
        callback: (data) =>
            (data['list'] as List?)?.cast<Map<String, dynamic>>());
  }

  Future<bool?> deleteToViewVideo({bool? allViewed, int? avid}) {
    final params = <String, dynamic>{'csrf': crypto.extractCSRF(cookies)};
    if (allViewed == true) {
      params['viewed'] = 'true';
    } else if (avid != null) {
      params['aid'] = avid;
    }
    return _callAPI(apiToViewDelUrl,
        queryParameters: params, isPost: true, callback: (_) => true);
  }

  Future<bool?> clearToViewList() {
    return _callAPI(apiToViewClearUrl,
        queryParameters: {'csrf': crypto.extractCSRF(cookies)},
        isPost: true,
        callback: (_) => true);
  }

  Future<bool?> thumbUpVideo(String bvid, bool like) {
    return _callAPI(apiThumbUpUrl,
        queryParameters: {
          'bvid': bvid,
          'like': like ? '1' : '2',
          'csrf': crypto.extractCSRF(cookies),
        },
        isPost: true,
        callback: (_) => true);
  }

  Future<bool?> hasLikedVideo(String bvid) {
    return _callAPI(apiHasLikedUrl,
        queryParameters: {'bvid': bvid}, callback: (data) => data == 1);
  }

  Future<bool?> batchDelFavResources(int mediaId, List<String> bvids) {
    final resources = bvids.map((bvid) => '${bv2av(bvid)}:2').join(',');
    return _callAPI(apiBatchDelFavUrl,
        queryParameters: {
          'resources': resources,
          'media_id': mediaId.toString(),
          'platform': 'web',
          'csrf': crypto.extractCSRF(cookies),
        },
        isPost: true,
        callback: (_) => true);
  }
}

int bv2av(String bvid) {
  const xorCode = 23442827791579;
  const maskCode = 2251799813685247;
  const base = 58;
  const data = 'FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf';

  var bvidArr = bvid.split('');
  var tmp = bvidArr[3];
  bvidArr[3] = bvidArr[9];
  bvidArr[9] = tmp;
  tmp = bvidArr[4];
  bvidArr[4] = bvidArr[7];
  bvidArr[7] = tmp;
  bvidArr = bvidArr.sublist(3);

  BigInt result = BigInt.zero;
  for (final c in bvidArr) {
    result = result * BigInt.from(base) + BigInt.from(data.indexOf(c));
  }
  return ((result & BigInt.from(maskCode)) ^ BigInt.from(xorCode)).toInt();
}
