// ignore_for_file: avoid_print
// 集成测试的诊断输出使用 print 是刻意设计
/// 扫码登录最多等 3 分钟，把文件级超时调到 5 分钟（test 包默认 30s 会掐断 setUpAll）
@Timeout(Duration(minutes: 5))
library;

import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import '../helpers/live_env.dart';
import '../helpers/live_session.dart';

/// 真实 API 集成测试（只读、不发短信/不写数据、不请求任何写接口）。
///
/// 运行方式（推荐，登录态自动获取并缓存复用）：
/// ```bash
/// flutter test/test/run_live.sh          # 首次会提示扫码（仅一次），之后全自动
/// ```
///
/// 高级用法：
/// ```bash
/// BMSC_LIVE=1 flutter test test/integration                 # 未登录态
/// BMSC_LIVE=1 BMSC_COOKIE="SESSDATA=..." flutter test ...   # 手动覆盖登录态
/// BMSC_LIVE=1 BMSC_LOGIN=1 flutter test test/integration    # 强制扫码登录
/// ```
///
/// 人工介入最小化：登录态缓存于 test/credentials/live_session.json（SESSDATA
/// 约 180 天有效），只在失效时需手机扫码一次。
///
/// 注意：会真实请求护照/B 站接口，注意频率限制与 IP 风控（412）。

const testVideoBvids = ['BV1GJ411x7h7', 'BV1xx411c7mD', 'BV1Q541167Qg'];

DioException? _lastNetworkError;

void main() {
  group('真实接口冒烟（BMSC_LIVE=1 启用）', () {
    late BilibiliAPI api;
    LiveSession? session;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      api = BilibiliAPI(enableConnectivity: false);
      api.noNetwork = false;
      await api.ensureBuvid3();
      session = await LiveSession.ensure(api);
      if (session != null) {
        await api.applyLoginCookies(session!.cookies, save: false);
        // 让 App playurl 走与 token 匹配的签名组（TV 登录 -> TV appkey）
        await SharedPreferencesService.setAccessToken(session!.accessToken);
        await SharedPreferencesService.setAccessTokenPlatform(
            session!.platform);
      }
      print('=== live 测试：${session != null ? '已登录(自动获取)' : '未登录'} ===');
    });

    tearDownAll(() {
      api.dio.close(force: true);
    });

    Future<T> probe<T>(String name, Future<T> Function() fn) async {
      try {
        final r = await fn();
        print('  [PASS] $name');
        return r;
      } on DioException catch (e) {
        _lastNetworkError = e;
        print('  [NET]  $name -> DioException ${e.type} '
            'status=${e.response?.statusCode}');
        rethrow;
      } on Exception catch (e) {
        print('  [ERR]  $name -> $e');
        rethrow;
      }
    }

    test('WBI key 可获取（历史痛点回归）', () async {
      final key = await probe('getRawWbiKey', () => api.getRawWbiKey());
      expect(key, isNotNull, reason: 'WBI key 拉取失败');
      expect(key!.length, greaterThanOrEqualTo(64));
      print('  WBI raw key: ${key.substring(0, 16)}...');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('极验参数接口（captcha 结构）', () async {
      final captcha = await probe('getLoginCaptcha', () => api.getLoginCaptcha());
      expect(captcha, isNotNull);
      print('  captcha: gt=${captcha!['gt'].toString().substring(0, 6)}... challenge=${captcha['challenge'].toString().substring(0, 6)}... token=${captcha['token'].toString().substring(0, 6)}...');
      // 只有 geetest 类型才有 gt/challenge；tencent 类型至少要有 token
      expect(captcha['token'], isNotNull);
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('TV 二维码可生成与轮询', () async {
      final info = await probe('getTvQrcodeLoginInfo', () => api.getTvQrcodeLoginInfo());
      expect(info, isNotNull);
      expect(info!.authCode, isNotEmpty);
      print('  TV QR auth_code=${info.authCode.substring(0, 8)}...');

      final poll = await probe('checkTvQrcodeLoginStatus',
          () => api.checkTvQrcodeLoginStatus(info.authCode));
      expect(poll, isNotNull);
      // 未扫码/未确认/已扫码 均为合理状态；-400/网络层错误失败
      expect(poll!.code, anyOf(0, 86038, 86039, 86090, 86101),
          reason: 'TV poll 状态异常: ${poll.code} ${poll.message}');
      print('  TV poll: code=${poll.code} ${poll.message}');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('排行榜（公共）→ 取首个视频做详情/分P/UP主互证', () async {
      final ranking =
          await probe('getRanking(3)', () => api.getRanking(3));
      expect(ranking, isNotNull);
      expect(ranking, isNotEmpty);
      final first = ranking!.first;
      print('  排行第一: ${first.title} (${first.bvid})');

      final detail = await probe('getVidDetail',
          () => api.getVidDetail(bvid: first.bvid));
      expect(detail, isNotNull);
      expect(detail!.title, isNotEmpty);
      print('  详情: ${detail.title} / ${detail.owner.name}');

      final pages = await probe('getPageList', () => api.getPageList(first.bvid));
      expect(pages, isNotNull);
      expect(pages, isNotEmpty);

      final user = await probe('getUserInfo', () => api.getUserInfo(first.mid));
      expect(user, isNotNull);
      print('  UP主: ${user!.card.name}');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('热门搜索（公共）', () async {
      final hot = await probe('getHotSearch', () => api.getHotSearch());
      expect(hot, isNotNull);
      expect(hot, isNotEmpty);
      print('  热搜数: ${hot!.length}');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('web 二维码可生成', () async {
      final info =
          await probe('getQrcodeLoginInfo', () => api.getQrcodeLoginInfo());
      expect(info, isNotNull);
      expect(info!.$1, contains('qrcode_key'));
      print('  web QR url: ${info.$1.substring(0, 60)}...');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('安全中心预捕获（无副作用）', () async {
      final pre =
          await probe('getSafeCenterCaptchaPre', () => api.getSafeCenterCaptchaPre());
      if (pre == null) {
        print('  [NOTE] 未登录时返回 null（预期内）');
      } else {
        print('  pre: gt=${pre.geeGt.substring(0, 6)}... ready=${pre.isReady}');
      }
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    test('视频详情兜底：固定 BV 列表至少一个可用', () async {
      String? fallback;
      for (final bv in testVideoBvids) {
        try {
          final d = await api.getVidDetail(bvid: bv);
          if (d != null) {
            fallback = '$bv: ${d.title}';
            break;
          }
        } catch (_) {}
      }
      expect(fallback, isNotNull, reason: '所有固定 BV 均不可用');
      print('  fallback: $fallback');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

    group('登录态接口（自动获取登录态；未登录时降级为记录行为）', () {
      test('getMyInfo：未登录返回 null，已登录返回 mid>0', () async {
        final myInfo = await probe('getMyInfo', () => api.getMyInfo());
        if (session != null) {
          expect(myInfo, isNotNull, reason: '已获取登录态但 myinfo 未返回');
          expect(myInfo!.mid, greaterThan(0));
          print('  当前账号: mid=${myInfo.mid} ${myInfo.name}');
        } else {
          print('  [NOTE] 未登录: myinfo 返回 null（预期）');
        }
      }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

      test('历史记录接口可达（空/未登录不视为失败）', () async {
        final history = await probe('getHistory', () => api.getHistory(null));
        if (session != null && history != null) {
          print('  历史条数: ${history.list.length}');
        } else {
          print('  [NOTE] ${session != null ? '空历史' : '未登录'} -> null 或空');
        }
      }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

      test('动态接口可达', () async {
        final dynamics =
            await probe('getDynamics', () => api.getDynamics(null));
        if (session != null && dynamics != null) {
          print('  动态条数: ${dynamics.items.length}');
        } else {
          print('  [NOTE] ${session != null ? '无动态' : '未登录'} -> null');
        }
      }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

      test('收藏夹（已登录时核心场景）', () async {
        final myInfo = await api.getMyInfo();
        if (myInfo == null || myInfo.mid == 0) {
          print('  [SKIP] 未获取到登录态（可 BMSC_LOGIN=1 扫码，或设 BMSC_COOKIE）');
          return;
        }
        final favs = await probe('getFavs', () => api.getFavs(myInfo.mid));
        expect(favs, isNotNull, reason: '登录态下收藏夹接口失败');
        print('  收藏夹数: ${favs!.length}');
      }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);

      test('App playurl（扫码/TV 登录自动获得 access_token；自动回退仅记录）', () async {
        final token = session?.accessToken ?? '';
        if (token.isEmpty) {
          print('  [SKIP] 无 access_token（BMSC_COOKIE 场景不提供 token；'
              '扫码登录场景自动具备）');
          return;
        }
        // cid 动态获取（避免硬编码错误 cid）
        final pages = await api.getPageList('BV1GJ411x7h7');
        if (pages == null || pages.isEmpty) {
          print('  [SKIP] 无法获取视频分P信息');
          return;
        }
        final cid = pages.first['cid'] as int;
        final audios = await probe('getAudioApp',
            () => api.getAudioApp('BV1GJ411x7h7', cid, accessToken: token));
        if (audios != null) {
          print('  音频流数: ${audios.length}');
          expect(audios, isNotEmpty);
        } else {
          print('  [NOTE] App playurl 返回 null（token 失效或接口拒绝，回退 web）');
        }
      }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);
    });

    test('网络层健康检查', () {
      if (_lastNetworkError != null) {
        print('  期间网络错误: $_lastNetworkError');
      }
      expect(_lastNetworkError, isNull,
          reason: '出现 DioException，见上方 [NET] 输出');
    }, skip: !isLive ? 'BMSC_LIVE=1 时启用' : null);
  });
}