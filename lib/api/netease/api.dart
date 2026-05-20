import 'package:dio/dio.dart';

import 'crypto.dart' as encrypt;

const _domain = 'https://music.163.com';
const _apiDomain = 'https://interface3.music.163.com';

class NeteaseAPI {
  final Dio dio = Dio();

  Future<Map<String, dynamic>?> search(String keyword,
      {int limit = 30, int offset = 0}) async {
    final data = {
      's': keyword,
      'type': 1,
      'limit': limit,
      'offset': offset,
    };
    final encrypted = encrypt.weapi(data);
    try {
      final response = await dio.post(
        '$_domain/weapi/cloudsearch/get/pc',
        data: encrypted,
        options: Options(
          headers: {
            'User-Agent': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://music.163.com',
          },
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      if (response.data['code'] != 200) return null;
      return response.data;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getPlaylistDetail(String id) async {
    final data = {
      's': '0',
      'id': id,
      'n': '1000',
      't': '0',
    };
    final encrypted = encrypt.eapi('/api/v6/playlist/detail', data);
    try {
      final response = await dio.post(
        '$_apiDomain/eapi/v6/playlist/detail',
        data: encrypted,
        options: Options(
          headers: {
            'User-Agent': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://music.163.com',
            'Cookie': 'os=iphone; appver=9.0.90; osver=16.2',
          },
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      final decrypted = encrypt.eapiResDecrypt(response.data['params']);
      return decrypted;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLyrics(int id) async {
    final data = {
      'id': id,
      'lv': -1,
      'tv': -1,
      'rv': -1,
      'kv': -1,
      'yv': -1,
      'os': 'ios',
      'ver': 1,
    };
    final encrypted = encrypt.eapi('/api/song/lyric/v1', data);
    try {
      final response = await dio.post(
        '$_apiDomain/eapi/song/lyric/v1',
        data: encrypted,
        options: Options(
          headers: {
            'User-Agent': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://music.163.com',
            'Cookie': 'os=iphone; appver=9.0.90; osver=16.2',
          },
          contentType: 'application/x-www-form-urlencoded',
        ),
      );
      final decrypted = encrypt.eapiResDecrypt(response.data['params']);
      return decrypted;
    } catch (_) {
      return null;
    }
  }
}
