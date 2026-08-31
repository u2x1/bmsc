// ignore_for_file: avoid_print
// 一次性诊断：验证 B 站音频流 MP4 box 结构（moov 在头部还是尾部）
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import '../helpers/live_env.dart';
import '../helpers/live_session.dart';

String _readBoxType(Uint8List data, int offset) {
  if (offset + 8 > data.length) return '?';
  return String.fromCharCodes(data.sublist(offset + 4, offset + 8));
}

int _readBoxSize(Uint8List data, int offset) {
  if (offset + 8 > data.length) return -1;
  final bd = ByteData.sublistView(data, offset, offset + 8);
  final size32 = bd.getUint32(0);
  if (size32 == 1 && offset + 16 <= data.length) {
    final bd2 = ByteData.sublistView(data, offset, offset + 16);
    return bd2.getUint64(8);
  }
  return size32;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test('moov position probe', () async {
    final session = LiveSession.loadFromFile();
    SharedPreferences.setMockInitialValues({
      if (session != null && session.cookie.isNotEmpty)
        'cookie': session.cookie,
      if (session != null && session.hasAccessToken)
        'access_token': session.accessToken,
      if (session != null && session.hasAccessToken)
        'access_token_platform': session.platform,
    });
    final service = await BilibiliService.instance;
    const bvid = String.fromEnvironment('PROBE_BVID',
        defaultValue: 'BV19e9ZBXEAG');
    const cid = int.fromEnvironment('PROBE_CID',
        defaultValue: 38054857661);
    final audios = await service.getAudio(bvid, cid);
    expect(audios, isNotNull);
    expect(audios!, isNotEmpty);
    final audio = audios.first;
    print('stream id=${audio.id} codecs=${audio.codecs}');
    print('FULL_URL: ${audio.baseUrl}');

    final client = HttpClient();
    final headers = service.headers;

    Future<Uint8List> fetchRange(String range) async {
      final req = await client.getUrl(Uri.parse(audio.baseUrl));
      headers?.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$range');
      final resp = await req.close();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      print('range $range -> status ${resp.statusCode}, '
          'len ${builder.length}, '
          'contentRange=${resp.headers.value('content-range')}');
      return builder.toBytes();
    }

    // 头部 4KB：枚举顶层 box
    final head = await fetchRange('0-4095');
    var offset = 0;
    print('--- top-level boxes from head ---');
    while (offset + 8 <= head.length) {
      final type = _readBoxType(head, offset);
      final size = _readBoxSize(head, offset);
      print('  @$offset $type size=$size');
      if (size <= 0) break;
      offset += size;
      if (offset > 4096) break;
    }

    // 尾部 4KB：找 moov/mfra
    final tail = await fetchRange('-4096');
    final tailStr = String.fromCharCodes(tail);
    print('--- tail contains ---');
    print('  moov: ${tailStr.contains('moov')}');
    print('  mfra: ${tailStr.contains('mfra')}');
    print('  free: ${tailStr.contains('free')}');

    // 全量 GET（与 _fetch 相同路径）：看响应头
    print('--- plain GET headers (same as _fetch) ---');
    print('  url ends with: ...${audio.baseUrl.substring(audio.baseUrl.length - 40)}');
    final req = await client.getUrl(Uri.parse(audio.baseUrl));
    headers?.forEach(req.headers.set);
    final resp = await req.close();
    print('  status: ${resp.statusCode}');
    resp.headers.forEach((name, values) {
      print('  $name: ${values.join(',')}');
    });
    await resp.drain();

    client.close();
  }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);
}
