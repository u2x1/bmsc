import 'dart:convert';

import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/comment.dart';
import 'package:bmsc/model/dynamic.dart';
import 'package:bmsc/model/entity.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/model/history.dart';
import 'package:bmsc/model/myinfo.dart';
import 'package:bmsc/model/search.dart';
import 'package:bmsc/model/subtitle.dart';
import 'package:bmsc/model/track.dart';
import 'package:bmsc/model/user_card.dart' show UserInfoResult;
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import '../model/meta.dart';

final _logger = LoggerUtils.getLogger('BilibiliService');

class BilibiliService {
  static final instance = _init();

  static Future<BilibiliService> _init() async {
    final service = BilibiliService();
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
    myInfo = null;
    await SharedPreferencesService.setMyInfo(MyInfo(0, "", "", ""));
    _updateHeadersFromMyInfo();
  }

  void _updateHeadersFromMyInfo() {
    final mid = myInfo?.mid ?? 0;
    _bilibiliAPI.updateBiliHeaders(mid);
  }

  Future<List<Fav>?> getFavs(int mid, {int? rid}) async {
    final ret = await _bilibiliAPI.getFavs(mid, rid: rid);
    if (ret != null) {
      DatabaseManager.cacheFavList(ret);
    }
    return ret;
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

  Future<List<Audio>?> getAudio(String bvid, int cid) {
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

    if (lastUpdateStr != null) {}
    final lastUpdate =
        lastUpdateStr != null ? DateTime.parse(lastUpdateStr) : null;
    final now = DateTime.now();
    if (lastUpdate == null ||
        !DateUtils.isSameDay(now, lastUpdate) ||
        recommendations == null ||
        force == true) {
      final defaultFavFolder =
          await SharedPreferencesService.getDefaultFavFolder();
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
      await prefs.setString('daily_recommendations',
          jsonEncode(recommendedVideos.map((v) => v.toJson()).toList()));

      return recommendedVideos;
    }

    final List<dynamic> decoded = jsonDecode(recommendations);
    return decoded.map((v) => Meta.fromJson(v)).toList();
  }
}
