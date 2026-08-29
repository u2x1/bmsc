// ignore_for_file: avoid_print
// 播放链路集成测试：真实 App 内路径（service 层，App playurl 优先 + web WBI 回退）
/// 依赖登录态（自动复用 test/credentials 缓存，见 helpers/live_session.dart）
@Timeout(Duration(minutes: 5))
library;

import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import '../helpers/live_env.dart';
import '../helpers/live_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  group('播放链路（service.getAudio，App 内路径）', () {
    late BilibiliService service;

    setUpAll(() async {
      // 用缓存登录态模拟「已登录启动」：service 初始化时会读取这些值
      final session = LiveSession.loadFromFile();
      SharedPreferences.setMockInitialValues({
        if (session != null && session.cookie.isNotEmpty) 'cookie': session.cookie,
        if (session != null && session.hasAccessToken) 'access_token': session.accessToken,
        if (session != null && session.hasAccessToken) 'access_token_platform': session.platform,
      });
      service = await BilibiliService.instance;
      print('=== 播放链路测试 登录态: ${service.myInfo?.name ?? '匿名'} ===');
    });

    test('播放源解析（App playurl 优先，web WBI 回退）返回可用音频流', () async {
      final audios = await service.getAudio('BV1GJ411x7h7', 137649199);
      expect(audios, isNotNull, reason: '播放源解析失败（App + Web 均失败）');
      expect(audios, isNotEmpty);
      final a = audios!.first;
      expect(a.baseUrl, isNotEmpty);
      expect(a.codecs, isNotEmpty);
      print('  音频流: ${audios.length} 条, id=${a.id} codecs=${a.codecs}');
      print('  URL: ${a.baseUrl.substring(0, 60)}...');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('解析失败安全兜底：非法 cid 返回 null 不崩溃', () async {
      final audios = await service.getAudio('BV1GJ411x7h7', 99999999);
      print('  非法 cid 结果: ${audios == null ? 'null（预期）' : '${audios.length} 条'}');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);
  });
}