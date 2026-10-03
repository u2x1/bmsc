import 'package:dio/dio.dart';

/// 第三方平台歌单抓取。
///
/// 已废弃：导入歌单功能不再维护，后续版本将随功能一并移除。
/// 请勿新增调用方。
@Deprecated('导入歌单功能已废弃，将在后续版本移除')
class MusicProvider {
  @Deprecated('导入歌单功能已废弃，将在后续版本移除')
  static Future<List<Map<String, dynamic>>?> fetchNeteasePlaylistTracks(
      String playlistId) async {
    try {
      final response = await Dio().get(
          'https://rp.u2x1.work/playlist/track/all',
          queryParameters: {'id': playlistId});
      final List<Map<String, dynamic>> tracks = [];
      for (final song in response.data['songs']) {
        tracks.add({
          'name': song['name'],
          'artist': song['ar'][0]['name'],
          'duration': song['dt'] ~/ 1000,
        });
      }
      return tracks;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return [];
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  @Deprecated('导入歌单功能已废弃，将在后续版本移除')
  static Future<List<Map<String, dynamic>>?> fetchTencentPlaylistTracks(
      String playlistId) async {
    try {
      final response = await Dio().get(
          'https://api.timelessq.com/music/tencent/songList',
          queryParameters: {'disstid': playlistId});
      if (response.data['errno'] != 0) {
        return [];
      }
      final List<Map<String, dynamic>> tracks = [];
      for (final song in response.data['data']['songlist']) {
        tracks.add({
          'name': song['songname'],
          'artist': song['singer'].map((e) => e['name']).join(', '),
          'duration': song['interval'],
        });
      }
      return tracks;
    } catch (e) {
      return null;
    }
  }

  @Deprecated('导入歌单功能已废弃，将在后续版本移除')
  static Future<List<Map<String, dynamic>>?> fetchKuGouPlaylistTracks(
      String playlistId) async {
    try {
      if (playlistId.startsWith("gcid")) {
        final response =
            await Dio().get("https://www.kugou.com/songlist/$playlistId/");
        final html = response.data as String;
        final RegExp regExp = RegExp(r'"list_create_gid":"([^"]+)"');
        final match = regExp.firstMatch(html);
        if (match != null) {
          final gid = match.group(1)!;
          playlistId = gid;
        }
      }

      final response = await Dio().get(
          'https://kg.u2x1.work/playlist/track/all?id=$playlistId&pagesize=300');
      if (response.data['status'] == 0) {
        return [];
      }
      final total = response.data['data']['count'];
      final List<Map<String, dynamic>> tracks = [];
      for (final song in response.data['data']['info']) {
        final fullname = song['name'];
        final pos = fullname.indexOf('-');
        final name = pos == -1 ? fullname : fullname.substring(0, pos);
        final artist = pos == -1 ? '' : fullname.substring(pos + 1).trim();
        tracks.add({
          'name': name,
          'artist': artist,
          'duration': song['timelen'] ~/ 1000,
        });
      }
      if (total > 300) {
        final pageSize = (total / 300).ceil();
        for (int i = 2; i <= pageSize; i++) {
          final response = await Dio().get(
              'https://kg.u2x1.work/playlist/track/all?id=$playlistId&pagesize=300&page=$i');
          for (final song in response.data['data']['info']) {
            final fullname = song['name'];
            final pos = fullname.indexOf('-');
            final name = pos == -1 ? fullname : fullname.substring(0, pos);
            final artist = pos == -1 ? '' : fullname.substring(pos + 1).trim();
            tracks.add({
              'name': name,
              'artist': artist,
              'duration': song['timelen'] ~/ 1000,
            });
          }
        }
      }
      return tracks;
    } catch (e) {
      return null;
    }
  }
}
