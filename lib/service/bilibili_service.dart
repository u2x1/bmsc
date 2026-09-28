import 'dart:async';
import 'dart:convert';

import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/comment.dart';
import 'package:bmsc/model/dynamic.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/model/history.dart';
import 'package:bmsc/model/login.dart';
import 'package:bmsc/model/myinfo.dart';
import 'package:bmsc/model/search.dart';
import 'package:bmsc/model/subtitle.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/model/user_card.dart' show UserInfoResult;
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/bili_sign.dart';
import 'package:bmsc/util/crypto.dart' as crypto;
import 'package:bmsc/util/logger.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import '../model/meta.dart';

final _logger = LoggerUtils.getLogger('BilibiliService');

class BilibiliService {
  static final instance = _init();

  static Future<BilibiliService> _init() async {
    final service = BilibiliService();
    // 登录身份：Android-HD buvid（持久化）/ deviceId（进程级）
    await service._loadLoginIdentity();

    // CookieJar 匿名身份 buvid3
    await service._bilibiliAPI.ensureBuvid3();

    final cookie = await SharedPreferencesService.getCookie();

    if (cookie != null) {
      service._bilibiliAPI.setCookie(cookie);
    } else {
      _logger.info('No cookie found, resetting cookies');
      await service._bilibiliAPI.resetCookies();
    }

    service.myInfo = await SharedPreferencesService.getMyInfo();

    final newInfo = await service._bilibiliAPI.getMyInfo();
    if (newInfo != null) {
      await SharedPreferencesService.setMyInfo(newInfo);
      service.myInfo = newInfo;
    }
    service._updateHeadersFromMyInfo();
    return service;
  }

  // ===== Android-HD 登录身份（对齐 BiliPai PiliPlusLoginIdentity） =====
  String _loginBuvid = '';
  String _deviceId = '';
  final Completer<void> _loginIdentityReady = Completer<void>();

  Future<void> _loadLoginIdentity() async {
    var buvid = await SharedPreferencesService.getLoginBuvid();
    if (buvid == null || !buvid.startsWith('XY')) {
      buvid = BiliSign.createBuvid();
      await SharedPreferencesService.setLoginBuvid(buvid);
    }
    _loginBuvid = buvid;
    _deviceId = BiliSign.createDeviceId();
    _loginIdentityReady.complete();
    _logger.info(
        'login identity loaded: buvid=$_loginBuvid deviceId=$_deviceId');
  }

  Future<(String, String)> getLoginIdentity() async {
    await _loginIdentityReady.future;
    return (_loginBuvid, _deviceId);
  }

  final BilibiliAPI _bilibiliAPI = BilibiliAPI();
  Map<String, String>? get headers => _bilibiliAPI.headers;
  MyInfo? myInfo;

  Future<void> refreshMyInfo() async {
    myInfo = await _bilibiliAPI.getMyInfo();
    if (myInfo != null) {
      await SharedPreferencesService.setMyInfo(myInfo!);
    }
    _updateHeadersFromMyInfo();
  }

  Future<void> logout() async {
    await _bilibiliAPI.resetCookies();
    _bilibiliAPI.clearCookies();
    myInfo = null;
    await SharedPreferencesService.setMyInfo(MyInfo(0, "", "", ""));
    await SharedPreferencesService.setCookie('');
    await SharedPreferencesService.setAccessToken('');
    await SharedPreferencesService.setRefreshToken('');
    await SharedPreferencesService.setAccessTokenPlatform('');
    _updateHeadersFromMyInfo();
  }

  void _updateHeadersFromMyInfo() {
    final mid = myInfo?.mid ?? 0;
    // CookieJar 模式：DedeUserID 直接注入 cookie（对齐 BiliPai）
    _bilibiliAPI.setCookieValue('DedeUserID', mid > 0 ? mid.toString() : '');
    // 持久化 cookie 串，保证重启后 DedeUserID 还在
    if (mid > 0) {
      SharedPreferencesService.setCookie(_bilibiliAPI.cookies);
    }
  }

  /// 登录成功后应用会话（cookie + token + 刷新用户信息）
  Future<void> applyLoginSession(
    AppLoginResult result, {
    String platform = 'android',
  }) async {
    if (result.cookies.isNotEmpty) {
      await _bilibiliAPI.applyLoginCookies(result.cookies, save: true);
    }
    if (result.accessToken.isNotEmpty) {
      await SharedPreferencesService.setAccessToken(result.accessToken);
      await SharedPreferencesService.setRefreshToken(result.refreshToken);
      await SharedPreferencesService.setAccessTokenPlatform(platform);
    }
    await refreshMyInfo();
  }

  /// TV 二维码登录成功后应用会话
  Future<void> applyTvLoginSession(TvQrPollResult result) async {
    await _bilibiliAPI
        .applyLoginCookies(result.cookies, save: true);
    if (result.accessToken.isNotEmpty) {
      await SharedPreferencesService.setAccessToken(result.accessToken);
      await SharedPreferencesService.setRefreshToken(result.refreshToken);
      await SharedPreferencesService.setAccessTokenPlatform('tv');
    }
    await refreshMyInfo();
  }

  Future<List<Fav>?> getFavs(int mid, {int? rid}) async {
    final ret = await _bilibiliAPI.getFavs(mid, rid: rid);
    if (ret != null) {
      DatabaseManager.cacheFavList(ret);
      return ret;
    }
    return DatabaseManager.getCachedFavList();
  }

  Future<List<Fav>?> getCollection(int mid) async {
    final ret = await _bilibiliAPI.getCollection(mid);
    if (ret != null) {
      DatabaseManager.cacheCollectedFavList(ret);
    }
    return ret;
  }

  Future<List<Meta>?> getCollectionMetas(int mid) async {
    final ret = await _bilibiliAPI.getCollectionMetas(mid);
    if (ret != null) {
      DatabaseManager.cacheMetas(ret);
      DatabaseManager.cacheCollectedFavListVideo(
          ret.map((x) => x.bvid).toList(), mid);
    }
    return ret;
  }

  Future<List<Meta>?> getFavMetas(int mid) async {
    final ret = await _bilibiliAPI.getFavMetas(mid);
    if (ret != null) {
      DatabaseManager.cacheMetas(ret);
      DatabaseManager.cacheFavListVideo(ret.map((x) => x.bvid).toList(), mid);
    }
    return ret;
  }

  /// 只拉取收藏夹第一页内容并增量缓存——主页封面堆叠的轻量兜底，
  /// 不拉全量分页，也不覆盖已有的完整缓存
  Future<void> cacheFavFirstPageMetas(int mid) async {
    final ret = await _bilibiliAPI.getFavMetasFirstPage(mid);
    if (ret != null) {
      DatabaseManager.cacheMetas(ret);
      DatabaseManager.mergeCacheFavListVideo(
          ret.map((x) => x.bvid).toList(), mid);
    }
  }

  /// 只拉取收藏的合集第一页内容并增量缓存（主页封面堆叠兜底）
  Future<void> cacheCollectionFirstPageMetas(int mid) async {
    final ret = await _bilibiliAPI.getCollectionMetasFirstPage(mid);
    if (ret != null) {
      DatabaseManager.cacheMetas(ret);
      DatabaseManager.mergeCacheCollectedFavListVideo(
          ret.map((x) => x.bvid).toList(), mid);
    }
  }

  Future<SearchResult?> search(String value, int pn) {
    return _bilibiliAPI.search(value, pn);
  }

  Future<UserInfoResult?> getUserInfo(int mid) {
    return _bilibiliAPI.getUserInfo(mid);
  }

  Future<(List<Meta>, int)?> getUserUploads(int mid, int pn) async {
    final ret = await _bilibiliAPI.getUserUploadMetas(mid, pn);
    if (ret == null) {
      return null;
    }
    DatabaseManager.cacheMetas(ret.$1);
    DatabaseManager.cacheFavListVideo(ret.$1.map((x) => x.bvid).toList(), mid);
    return ret;
  }

  Future<HistoryResult?> getHistory(int? timestamp) {
    return _bilibiliAPI.getHistory(timestamp);
  }

  Future<DynamicResult?> getDynamics(String? offset) {
    return _bilibiliAPI.getDynamics(offset);
  }

  Future<VidResult?> getVidDetail({String? bvid, String? aid}) async {
    final ret = await _bilibiliAPI.getVidDetail(bvid: bvid, aid: aid);
    if (ret != null) {
      DatabaseManager.cacheMetas([
        Meta(
          bvid: ret.bvid,
          aid: ret.aid,
          title: ret.title,
          artist: ret.owner.name,
          mid: ret.owner.mid,
          duration: ret.duration,
          parts: ret.videos,
          artUri: ret.pic,
        )
      ]);
      await DatabaseManager.cacheEntities(ret.pages
          .map((x) => Entity(
                bvid: ret.bvid,
                aid: ret.aid,
                cid: x.cid,
                duration: x.duration,
                part: x.page,
                artist: ret.owner.name,
                artUri: ret.pic,
                partTitle: x.part,
                bvidTitle: ret.title,
              ))
          .toList());
    }
    return ret;
  }

  Future<List<Audio>?> getAudio(String bvid, int cid) async {
    // App 端 playurl 优先（appkey 签名 + access_key，对齐 BiliPai）；失败回退 web WBI
    final accessToken = await SharedPreferencesService.getAccessToken();
    final appResult =
        await _bilibiliAPI.getAudioApp(bvid, cid, accessToken: accessToken);
    if (appResult != null && appResult.isNotEmpty) {
      return appResult;
    }
    return _bilibiliAPI.getAudio(bvid, cid);
  }

  Future<List<LazyAudioSource>?> getAudios(String bvid) async {
    _logger.info('Fetching audio sources for BVID: $bvid');
    await getVidDetail(bvid: bvid);
    var entities = await DatabaseManager.getEntities(bvid);
    if (entities.isEmpty) {
      _logger.warning('Failed to get video details for BVID: $bvid');
      return null;
    }
    final meta = await DatabaseManager.getMeta(bvid);
    return (await Future.wait<LazyAudioSource?>(entities.map((x) async {
      final cachedSource = await DatabaseManager.getLocalAudio(bvid, x.cid);
      if (cachedSource != null) {
        return cachedSource;
      }
      final tag = MediaItem(
          id: '${bvid}_${x.cid}',
          title: entities.length > 1 ? x.partTitle : x.bvidTitle,
          artUri: Uri.parse(x.artUri),
          artist: x.artist,
          duration: Duration(seconds: x.duration),
          extras: {
            'mid': meta?.mid,
            'bvid': meta?.bvid,
            'aid': meta?.aid,
            'cid': x.cid,
            'cached': false,
            'raw_title': x.bvidTitle,
            'multi': entities.length > 1,
          });
      return LazyAudioSource(bvid, x.cid, tag: tag);
    })))
        .whereType<LazyAudioSource>()
        .toList();
  }

  Future<CommentData?> getComment(String aid, String? offset) {
    return _bilibiliAPI.getComment(aid, offset);
  }

  Future<CommentData?> getCommentsOfComment(int oid, int root, int pn) {
    return _bilibiliAPI.getCommentsOfComment(oid, root, pn);
  }

  Future<bool?> favoriteVideo(
      int avid, List<int> addMediaIds, List<int> delMediaIds) {
    return _bilibiliAPI.favoriteVideo(avid, addMediaIds, delMediaIds);
  }

  Future<bool?> isFavorited(int aid) {
    return _bilibiliAPI.isFavorited(aid);
  }

  Future<Fav?> createFavFolder(String name, {bool hide = false}) {
    return _bilibiliAPI.createFavFolder(name, hide: hide);
  }

  Future<bool?> deleteFavFolder(int fid) {
    return _bilibiliAPI.deleteFavFolder(fid);
  }

  Future<bool?> editFavFolder(int fid, String name, {bool hide = false}) {
    return _bilibiliAPI.editFavFolder(fid, name, hide: hide);
  }

  Future<List<Meta>?> getRelatedVideos(int aid, {List<int>? tidWhitelist}) {
    return _bilibiliAPI.getRelatedVideos(aid, tidWhitelist: tidWhitelist);
  }

  Future<List<String>?> getSearchSuggestions(String keyword) {
    return _bilibiliAPI.getSearchSuggestions(keyword);
  }

  Future<void> reportHistory(int aid, int cid, int? progress) {
    return _bilibiliAPI.reportHistory(aid, cid, progress);
  }

  /// Returns a list of tuples containing subtitle language and URL
  /// Each tuple contains (language, subtitle_url)
  Future<List<(String, String)>?> getSubTitleInfo(int aid, int cid) {
    return _bilibiliAPI.getSubTitleInfo(aid, cid);
  }

  Future<List<BilibiliSubtitle>?> getSubTitleData(String url) {
    return _bilibiliAPI.getSubTitleData(url);
  }

  Future<(bool, String?)> passwordLogin(
      String username, String password, Map<String, dynamic> geetestResult) {
    return _bilibiliAPI.passwordLogin(
        username: username, password: password, geetestResult: geetestResult);
  }

  /// App 端密码登录（对齐 BiliPai）
  Future<AppLoginResult> passwordLoginApp(
      String username, String password, CaptchaData? captcha,
      {String? validate, String? seccode}) async {
    final (buvid, deviceId) = await getLoginIdentity();
    // 1. 获取 RSA 公钥
    final loginKey = await _bilibiliAPI.getLoginKey();
    if (loginKey == null) {
      return AppLoginResult(code: -1, message: '获取登录密钥失败');
    }
    final encryptedPassword =
        crypto.encryptPassword(password, loginKey['key']!, loginKey['hash']!);
    final encryptedDeviceToken = crypto.encryptDeviceToken(
        loginKey['key']!, BiliSign.createRandomString(16));
    // 2. 发起 App 登录
    return _bilibiliAPI.passwordLoginApp(
      username: username,
      encryptedPassword: encryptedPassword,
      captcha: captcha,
      validate: validate,
      seccode: seccode,
      buvid: buvid,
      deviceId: deviceId,
      encryptedDeviceToken: encryptedDeviceToken,
    );
  }

  /// App 端发送短信验证码（对齐 BiliPai）
  Future<(String, String?)> sendSmsCaptchaApp(
    String phone,
    CaptchaData? captcha, {
    String? validate,
    String? seccode,
  }) async {
    final (buvid, _) = await getLoginIdentity();
    return _bilibiliAPI.sendSmsCaptchaApp(
      phone: phone,
      captcha: captcha,
      validate: validate,
      seccode: seccode,
      buvid: buvid,
    );
  }

  /// App 端短信登录（对齐 BiliPai）
  Future<AppLoginResult> smsLoginApp(
      String phone, String code, String captchaKey) async {
    final (buvid, deviceId) = await getLoginIdentity();
    final loginKey = await _bilibiliAPI.getLoginKey();
    if (loginKey == null) {
      return AppLoginResult(code: -1, message: '获取登录密钥失败');
    }
    final encryptedDeviceToken = crypto.encryptDeviceToken(
        loginKey['key']!, BiliSign.createRandomString(16));
    return _bilibiliAPI.smsLoginApp(
      phone: phone,
      code: code,
      captchaKey: captchaKey,
      buvid: buvid,
      deviceId: deviceId,
      encryptedDeviceToken: encryptedDeviceToken,
    );
  }

  /// TV 二维码登录（首选，登录态含 access_token）
  Future<TvQrLoginInfo?> getTvQrcodeLoginInfo() {
    return _bilibiliAPI.getTvQrcodeLoginInfo();
  }

  Future<TvQrPollResult?> checkTvQrcodeLoginStatus(String authCode) {
    return _bilibiliAPI.checkTvQrcodeLoginStatus(authCode);
  }

  Future<bool> refreshTvToken() async {
    final accessToken = await SharedPreferencesService.getAccessToken();
    final refreshToken = await SharedPreferencesService.getRefreshToken();
    if (accessToken == null || refreshToken == null ||
        accessToken.isEmpty || refreshToken.isEmpty) {
      return false;
    }
    final result =
        await _bilibiliAPI.refreshTvToken(accessToken, refreshToken);
    if (result == null) return false;
    await SharedPreferencesService.setAccessToken(result.accessToken);
    await SharedPreferencesService.setRefreshToken(result.refreshToken);
    if (result.cookies.isNotEmpty) {
      await _bilibiliAPI.applyLoginCookies(result.cookies, save: true);
    }
    return true;
  }

  // ===== 密码登录风控（安全中心，对齐 BiliPai） =====
  Future<SafeCenterInfo?> getSafeCenterInfo(String tmpCode) {
    return _bilibiliAPI.getSafeCenterInfo(tmpCode);
  }

  Future<SafeCenterCaptchaPre?> getSafeCenterCaptchaPre() {
    return _bilibiliAPI.getSafeCenterCaptchaPre();
  }

  Future<(String, String?)> sendSafeCenterSms({
    required String tmpCode,
    required String recaptchaToken,
    required String challenge,
    required String validate,
    required String seccode,
    required String referer,
  }) {
    return _bilibiliAPI.sendSafeCenterSms(
      tmpCode: tmpCode,
      recaptchaToken: recaptchaToken,
      challenge: challenge,
      validate: validate,
      seccode: seccode,
      referer: referer,
    );
  }

  Future<(String, String?)> verifySafeCenterSms({
    required String code,
    required String tmpCode,
    required String requestId,
    required String source,
    required String captchaKey,
    required String referer,
  }) {
    return _bilibiliAPI.verifySafeCenterSms(
      code: code,
      tmpCode: tmpCode,
      requestId: requestId,
      source: source,
      captchaKey: captchaKey,
      referer: referer,
    );
  }

  Future<AppLoginResult> oauth2AccessToken(String exchangeCode) async {
    final (buvid, _) = await getLoginIdentity();
    return _bilibiliAPI.oauth2AccessToken(code: exchangeCode, buvid: buvid);
  }

  Future<(bool, String?)> smsLogin(int tel, String code, String captchaKey) {
    return _bilibiliAPI.smslogin(tel: tel, code: code, captchaKey: captchaKey);
  }

  Future<(String, String?)> getSmsLoginCaptcha(
      int tel, Map<String, dynamic> geetestResult) {
    return _bilibiliAPI.getSmsLoginCaptcha(
        tel: tel, geetestResult: geetestResult);
  }

  Future<Map<String, String>?> getLoginCaptcha() {
    return _bilibiliAPI.getLoginCaptcha();
  }

  Future<(String, String)?> getQrcodeLoginInfo() {
    return _bilibiliAPI.getQrcodeLoginInfo();
  }

  Future<int?> checkQrcodeLoginStatus(String qrcodeKey) {
    return _bilibiliAPI.checkQrcodeLoginStatus(qrcodeKey);
  }

  Future<String?> getRawWbiKey() {
    return _bilibiliAPI.getRawWbiKey();
  }

  Future<List<Map<String, dynamic>>?> getHotSearch() {
    return _bilibiliAPI.getHotSearch();
  }

  Future<List<Meta>?> getRanking(int rid) {
    return _bilibiliAPI.getRanking(rid);
  }

  Future<List<Map<String, dynamic>>?> getPageList(String bvid) {
    return _bilibiliAPI.getPageList(bvid);
  }

  Future<Map<String, dynamic>?> getUserInfoByMid(int mid) {
    return _bilibiliAPI.getUserInfoByMid(mid);
  }

  Future<List<Map<String, dynamic>>?> getToViewList() {
    return _bilibiliAPI.getToViewList();
  }

  Future<bool?> deleteToViewVideo({bool? allViewed, int? avid}) {
    return _bilibiliAPI.deleteToViewVideo(allViewed: allViewed, avid: avid);
  }

  Future<bool?> clearToViewList() {
    return _bilibiliAPI.clearToViewList();
  }

  Future<bool?> thumbUpVideo(String bvid, bool like) {
    return _bilibiliAPI.thumbUpVideo(bvid, like);
  }

  Future<bool?> hasLikedVideo(String bvid) {
    return _bilibiliAPI.hasLikedVideo(bvid);
  }

  Future<bool?> batchDelFavResources(int mediaId, List<String> bvids) {
    return _bilibiliAPI.batchDelFavResources(mediaId, bvids);
  }

  Future<List<Meta>?> getRecommendations(List<Meta> tracks) async {
    if (tracks.isEmpty) {
      return null;
    }

    final prefs = await SharedPreferencesService.instance;
    final recommendHistory = prefs.getString('recommend_history');
    Set<String> history = recommendHistory != null
        ? Set<String>.from(jsonDecode(recommendHistory))
        : {};

    const tidWhitelist = [130, 193, 267, 28, 59];

    // Fetch all related videos concurrently
    final relatedVideosResults = await Future.wait(tracks.map(
        (track) => getRelatedVideos(track.aid, tidWhitelist: tidWhitelist)));

    List<Meta> recommendedVideos = [];
    for (final videos in relatedVideosResults) {
      if (videos != null && videos.isNotEmpty) {
        for (final video in videos) {
          if (!history.contains(video.bvid) && video.duration >= 60) {
            recommendedVideos.add(video);
            history.add(video.bvid);
            break;
          }
        }
      }
    }

    await prefs.setString('recommend_history', jsonEncode(history.toList()));
    await DatabaseManager.cacheMetas(recommendedVideos);
    return recommendedVideos;
  }

  Future<List<Meta>?> getDailyRecommendations({bool force = false}) async {
    final prefs = await SharedPreferencesService.instance;
    final lastUpdateStr = prefs.getString('last_recommendations_update');
    final recommendations = prefs.getString('daily_recommendations');

    final lastUpdate =
        lastUpdateStr != null ? DateTime.parse(lastUpdateStr) : null;
    final now = DateTime.now();

    final defaultFavFolder =
        await SharedPreferencesService.getDefaultFavFolder();
    // 缓存的推荐属于哪个收藏夹；与当前默认收藏夹不一致（用户切换过）
    // 时必须重新生成，否则会一直显示上一个收藏夹的推荐
    final cachedFolderId = prefs.getInt('daily_recommendations_folder');
    final folderChanged = defaultFavFolder != null &&
        cachedFolderId != null &&
        cachedFolderId != defaultFavFolder.$1;

    if (lastUpdate == null ||
        !DateUtils.isSameDay(now, lastUpdate) ||
        recommendations == null ||
        force == true ||
        folderChanged) {
      if (defaultFavFolder == null) return null;

      var favVideos =
          await DatabaseManager.getCachedFavMetas(defaultFavFolder.$1);

      if (favVideos.isEmpty) {
        favVideos = await getFavMetas(defaultFavFolder.$1) ?? [];
      }

      if (favVideos.isEmpty) return null;

      favVideos.shuffle();
      final selectedVideos = favVideos.take(30).toList();

      final recommendedVideos = await getRecommendations(selectedVideos) ?? [];

      await prefs.setString(
          'last_recommendations_update', now.toIso8601String());
      await prefs.setInt(
          'daily_recommendations_folder', defaultFavFolder.$1);
      await prefs.setString('daily_recommendations',
          jsonEncode(recommendedVideos.map((v) => v.toJson()).toList()));

      return recommendedVideos;
    }

    final List<dynamic> decoded = jsonDecode(recommendations);
    return decoded.map((v) => Meta.fromJson(v)).toList();
  }
}
