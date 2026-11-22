import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:dio/dio.dart';

import '../model/vid.dart';

final _logger = LoggerUtils.getLogger("url");

final _b23UrlPattern = RegExp(r'https?://b23\.tv/[a-zA-Z0-9]+');
final _seasonUrlPattern = RegExp(
    r'https://space\.bilibili\.com/([0-9]+)/lists/([0-9]+)\?[^\s<>]*',
    caseSensitive: false);

class SeasonLink {
  const SeasonLink(this.mid, this.seasonId);

  final int mid;
  final int seasonId;
}

(String, SeasonLink)? _findSeasonLink(String text) {
  for (final match in _seasonUrlPattern.allMatches(text)) {
    final url = match.group(0)!;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'space.bilibili.com' ||
        uri.hasPort ||
        uri.path != '/${match.group(1)}/lists/${match.group(2)}') {
      continue;
    }

    final mid = int.tryParse(match.group(1)!);
    final seasonId = int.tryParse(match.group(2)!);
    final types = uri.queryParametersAll['type'];
    if (mid == null ||
        mid <= 0 ||
        seasonId == null ||
        seasonId <= 0 ||
        types == null ||
        types.length != 1 ||
        types.single != 'season') {
      continue;
    }
    return (url, SeasonLink(mid, seasonId));
  }
  return null;
}

SeasonLink? parseSeasonLink(String text) => _findSeasonLink(text)?.$2;

Future<SeasonLink?> getSeasonLinkFromUrl(String text) async {
  final seasonLink = parseSeasonLink(text);
  if (seasonLink != null) return seasonLink;

  final urlMatch = _b23UrlPattern.firstMatch(text);
  if (urlMatch == null) return null;
  return parseSeasonLink(await getRedirectUrl(urlMatch.group(0)!));
}

/// get 302 redirect url
Future<String> getRedirectUrl(String url) async {
  try {
    final dio = Dio(BaseOptions(
      followRedirects: false,
      validateStatus: (status) {
        return status == 200 || status == 301 || status == 302;
      },
    ));
    final response = await dio.get(url);
    final ret = response.headers.value('location');
    if (ret == null) {
      _logger.severe('No redirect url found for $url');
      return url;
    }
    return ret;
  } catch (e) {
    _logger.severe('Error getting redirect url: $e');
    return url;
  }
}

Future<VidResult?> getVidDetailFromUrl(String text) async {
  VidResult? vidDetail;
  String? bvid;

  final urlMatch = _b23UrlPattern.firstMatch(text);
  if (urlMatch != null) {
    final url = urlMatch.group(0)!;
    _logger.info('b23.tv url detected, trying to get redirect url: $url');
    text = await getRedirectUrl(url);
  }

  final bvMatch = RegExp(r'[Bb][Vv][a-zA-Z0-9]{10}').firstMatch(text);
  if (bvMatch != null) {
    bvid = bvMatch.group(0)!;
    vidDetail = await (await BilibiliService.instance).getVidDetail(bvid: bvid);
  }

  final avMatch = RegExp(r'[Aa][Vv]([0-9]+)').firstMatch(text);
  if (avMatch != null) {
    final aid = avMatch.group(1)!;
    vidDetail = await (await BilibiliService.instance).getVidDetail(aid: aid);
  }
  return vidDetail;
}

String? extractBiliUrl(String text) {
  final urlMatch = _b23UrlPattern.firstMatch(text);
  if (urlMatch != null) {
    return urlMatch.group(0)!;
  }

  final seasonLink = _findSeasonLink(text);
  if (seasonLink != null) {
    return seasonLink.$1;
  }

  final bvMatch = RegExp(r'[Bb][Vv][a-zA-Z0-9]{10}').firstMatch(text);
  if (bvMatch != null) {
    return bvMatch.group(0)!;
  }

  final avMatch = RegExp(r'[Aa][Vv]([0-9]+)').firstMatch(text);
  if (avMatch != null) {
    return avMatch.group(0)!;
  }
  return null;
}
