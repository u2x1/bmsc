import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/bili_sign.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import '../helpers/fake_http_adapter.dart';

/// 认证层测试：cookie 注入、_callAPI 错误路径、登录接口解析。
/// 用 FakeHttpAdapter 替换真实网络，不触网。
void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  late BilibiliAPI api;
  late FakeHttpAdapter adapter;

  setUp(() async {
    adapter = FakeHttpAdapter();
    api = BilibiliAPI(enableConnectivity: false);
    api.noNetwork = false;
    api.dio.httpClientAdapter = adapter;
    // 清掉上一个用例留下的身份/会话，避免相互污染
    await SharedPreferencesService.setCookie('');
    await SharedPreferencesService.setBuvid3('');
    await SharedPreferencesService.setBuvid4('');
    await SharedPreferencesService.setBNut('');
    await SharedPreferencesService.setAccessToken('');
    await SharedPreferencesService.setAccessTokenPlatform('');
  });

  tearDown(() {
    api.dio.close(force: true);
  });

  group('CookieJar 认证层', () {
    test('setCookie 解析 k=v 并按名排序拼装', () async {
      await api.setCookie('bili_jct=abc; SESSDATA=xyz');
      expect(api.cookies, contains('SESSDATA=xyz'));
      expect(api.cookies, contains('bili_jct=abc'));
    });

    test('请求自动携带完整 cookie 头', () async {
      await api.setCookie('SESSDATA=sess1; bili_jct=csrf1; DedeUserID=42');
      adapter.onPath('/x/player/pagelist', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': [
            {'cid': 123, 'page': 1, 'part': 'p1'},
          ],
        },
      });
      final result = await api.getPageList('BV1GJ411x7h7');
      expect(result, isNotNull);
      expect(result, hasLength(1));
      final headers = adapter.requests.last.headers;
      expect(headers['cookie'], contains('SESSDATA=sess1'));
      expect(headers['cookie'], contains('bili_jct=csrf1'));
      expect(headers['cookie'], contains('DedeUserID=42'));
      // 关键：不再携带伪造设备头
      expect(headers.containsKey('env'), isFalse);
      expect(headers.containsKey('app-key'), isFalse);
      expect(headers.containsKey('x-bili-aurora-eid'), isFalse);
    });

    test('applyLoginCookies 合并会话并持久化', () async {
      await SharedPreferencesService.setCookie('');
      await api.applyLoginCookies(
        {'SESSDATA': 's1', 'bili_jct': 'c1', 'DedeUserID': '7'},
        save: true,
      );
      expect(api.cookies, contains('SESSDATA=s1'));
      final saved = await SharedPreferencesService.getCookie();
      expect(saved, contains('SESSDATA=s1'));
      expect(saved, contains('bili_jct=c1'));
    });

    test('applyLoginCookies 不覆盖匿名 buvid3/buvid4', () async {
      await SharedPreferencesService.setBuvid3(_testBuvid3);
      await SharedPreferencesService.setBuvid4(_testBuvid4);
      await api.ensureAnonymousIdentity();
      await api.applyLoginCookies({
        'SESSDATA': 's1',
        'buvid': 'XYapp-login-buvid',
        'buvid3': 'XYapp-login-buvid',
      });
      expect(api.cookies, contains('buvid3=$_testBuvid3'));
      expect(api.cookies, contains('buvid4=$_testBuvid4'));
      expect(api.cookies, isNot(contains('buvid=XYapp-login-buvid')));
    });

    test('setCookieValue 增删单个 cookie 不持久化', () async {
      await SharedPreferencesService.setCookie('');
      await api.setCookie('SESSDATA=x');
      api.setCookieValue('DedeUserID', '9');
      expect(api.cookies, contains('DedeUserID=9'));
      api.setCookieValue('DedeUserID', '');
      expect(api.cookies, isNot(contains('DedeUserID')));
      // 只改内存；持久化的 cookie 串不受影响
      final saved = await SharedPreferencesService.getCookie();
      expect(saved, isNot(contains('DedeUserID')));
      expect(saved, isNot(contains('SESSDATA=x')));
    });

    test('clearCookies 清空且后续请求无 cookie 头', () async {
      await api.setCookie('SESSDATA=x');
      api.clearCookies();
      adapter.onPath('/x/player/pagelist', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': [
            {'cid': 123, 'page': 1, 'part': 'p1'},
          ],
        },
      });
      await api.getPageList('BV1GJ411x7h7');
      expect(adapter.requests.last.headers.containsKey('cookie'), isFalse);
    });
  });

  group('匿名设备指纹（playurl 风控校验 buvid3+buvid4）', () {
    test('缺少 buvid4 时从 finger/spi 拉取并注入 cookie', () async {
      adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());
      await api.ensureAnonymousIdentity();
      expect(api.cookies, contains('buvid3=$_testBuvid3'));
      expect(api.cookies, contains('buvid4=$_testBuvid4'));
      expect(api.cookies, contains('b_nut='));
      expect(await SharedPreferencesService.getBuvid3(), _testBuvid3);
      expect(await SharedPreferencesService.getBuvid4(), _testBuvid4);
      // 必须裸请求：带旧 cookie 时服务端会沿用旧身份
      expect(adapter.requests.last.headers.containsKey('cookie'), isFalse);
    });

    test('已有真实 buvid3/buvid4 时不触网', () async {
      await SharedPreferencesService.setBuvid3(_testBuvid3);
      await SharedPreferencesService.setBuvid4(_testBuvid4);
      await SharedPreferencesService.setBNut('1234567890');
      await api.ensureAnonymousIdentity();
      expect(adapter.requests, isEmpty);
      expect(api.cookies, contains('buvid3=$_testBuvid3'));
      expect(api.cookies, contains('buvid4=$_testBuvid4'));
      expect(api.cookies, contains('b_nut=1234567890'));
    });

    test('旧版合成 buvid3（无连字符）会被真实指纹替换', () async {
      await SharedPreferencesService.setBuvid3('65e561d30be5d9bf49cdinfoc');
      adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());
      await api.ensureAnonymousIdentity();
      expect(await SharedPreferencesService.getBuvid3(), _testBuvid3);
      expect(await SharedPreferencesService.getBuvid4(), _testBuvid4);
    });
  });

  group('_callAPI 错误路径', () {
    test('接口层 code != 0 返回 null', () async {
      adapter.onPath('/x/web-interface/view', {
        'body': {'code': -101, 'message': '账号未登录'},
      });
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
    });

    test('HTTP 412 抛出明确异常（风控提示）', () async {
      adapter.onPath('/x/web-interface/view', {'status': 412, 'body': {}});
      await expectLater(api.getVidDetail(bvid: 'BV1xxx'),
          throwsA(predicate((e) => e.toString().contains('412'))));
    });

    test('HTTP 5xx 返回 null 不崩溃', () async {
      adapter.onPath('/x/web-interface/view', {
        'status': 500,
        'body': {'code': -500, 'message': 'server error'},
      });
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
    });

    test('响应 JSON 非对象（如纯文本）返回 null 不崩溃', () async {
      adapter.onPath('/x/web-interface/view', {
        'status': 200,
        'body': '<html>bad gateway</html>',
      });
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
    });

    test('data 为 null 返回 null', () async {
      adapter.onPath('/x/web-interface/view', {
        'body': {'code': 0, 'message': 'OK', 'data': null},
      });
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
    });

    test('callback 解析异常返回 null（结构变化不崩溃）', () async {
      adapter.onPath('/x/web-interface/view', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {'unexpected_field': true},
        },
      });
      // VidResult.fromJson 缺少 bvid 会抛，_callAPI 兜底返回 null
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
    });

    test('noNetwork 短路返回 null', () async {
      api.noNetwork = true;
      adapter.onPath('/x/web-interface/view', {
        'body': {
          'code': 0,
          'data': {'bvid': 'BV1GJ411x7h7'},
        }
      });
      expect(await api.getVidDetail(bvid: 'BV1xxx'), isNull);
      expect(adapter.requests, isEmpty);
    });
  });

  group('web playurl（WBI + v_voucher 风控）', () {
    setUp(() async {
      final prefs = await SharedPreferencesService.instance;
      await prefs.remove('raw_wbi_key');
      await prefs.remove('img_sub_key_last_update');
    });

    test('解析 dash.audio', () async {
      adapter.onPath('/x/web-interface/nav', _navRoute(_wbiKey1));
      adapter.onPath(
          '/x/player/wbi/playurl',
          _playUrlRoute([
            _audioStream(30232, 'https://cdn/32.m4s'),
            _audioStream(30280, 'https://cdn/80.m4s'),
          ]));
      final audio = await api.getAudio('BV1xxx', 123);
      expect(audio, hasLength(2));
      expect(audio!.first.baseUrl, 'https://cdn/32.m4s');
    });

    test('v_voucher 时刷新设备指纹与 WBI key 并重试一次', () async {
      await SharedPreferencesService.setBuvid3(_testBuvid3);
      await SharedPreferencesService.setBuvid4(_testBuvid4);
      adapter.onPathSequence('/x/player/wbi/playurl', [
        _vVoucherRoute(),
        _playUrlRoute([_audioStream(30280, 'https://cdn/80.m4s')]),
      ]);
      adapter.onPathSequence('/x/web-interface/nav', [
        _navRoute(_wbiKey1),
        _navRoute(_wbiKey2),
      ]);
      adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());

      final audio = await api.getAudio('BV1xxx', 123);
      expect(audio, hasLength(1));
      expect(audio!.first.baseUrl, 'https://cdn/80.m4s');

      int count(String path) =>
          adapter.requests.where((r) => r.uri.path == path).length;
      expect(count('/x/player/wbi/playurl'), 2);
      expect(count('/x/web-interface/nav'), 2);
      expect(count('/x/frontend/finger/spi'), 1);
    });

    test('重试仍 v_voucher 返回 null 不崩溃', () async {
      await SharedPreferencesService.setBuvid3(_testBuvid3);
      await SharedPreferencesService.setBuvid4(_testBuvid4);
      adapter.onPathSequence(
          '/x/player/wbi/playurl', [_vVoucherRoute(), _vVoucherRoute()]);
      adapter.onPathSequence(
          '/x/web-interface/nav', [_navRoute(_wbiKey1), _navRoute(_wbiKey2)]);
      adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());

      expect(await api.getAudio('BV1xxx', 123), isNull);
    });

    test('dash 缺失（非 v_voucher）返回 null 不崩溃', () async {
      adapter.onPath('/x/web-interface/nav', _navRoute(_wbiKey1));
      adapter.onPath('/x/player/wbi/playurl', {
        'body': {
          'code': 0,
          'message': '0',
          'data': {'from': 'local'},
        },
      });
      expect(await api.getAudio('BV1xxx', 123), isNull);
    });
  });

  group('会话失效信号（-101 + 本地持有 SESSDATA）', () {
    test('持有 SESSDATA 时 -101 触发 onSessionInvalid（cookie 过期场景）', () async {
      await api.setCookie('SESSDATA=stale; bili_jct=old_csrf');
      var fired = 0;
      api.onSessionInvalid = () => fired++;
      adapter.onPath('/x/space/myinfo', {
        'body': {'code': -101, 'message': '账号未登录'},
      });
      expect(await api.getMyInfo(), isNull);
      expect(fired, 1);
    });

    test('未登录（无 SESSDATA）时 -101 不触发', () async {
      var fired = 0;
      api.onSessionInvalid = () => fired++;
      adapter.onPath('/x/space/myinfo', {
        'body': {'code': -101, 'message': '账号未登录'},
      });
      expect(await api.getMyInfo(), isNull);
      expect(fired, 0);
    });

    test('code=0 成功响应不触发', () async {
      await api.setCookie('SESSDATA=ok');
      var fired = 0;
      api.onSessionInvalid = () => fired++;
      adapter.onPath('/x/space/myinfo', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {'mid': 42, 'name': 'u', 'face': 'f', 'sign': 's'},
        },
      });
      expect(await api.getMyInfo(), isNotNull);
      expect(fired, 0);
    });

    test('其他错误码（如 -400）不触发', () async {
      await api.setCookie('SESSDATA=stale');
      var fired = 0;
      api.onSessionInvalid = () => fired++;
      adapter.onPath('/x/space/myinfo', {
        'body': {'code': -400, 'message': '请求错误'},
      });
      expect(await api.getMyInfo(), isNull);
      expect(fired, 0);
    });
  });

  group('登录接口解析（fake 网络）', () {
    test('TV 二维码生成解析 url/auth_code', () async {
      adapter.onPath('/x/passport-tv-login/qrcode/auth_code', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {
            'url': 'https://passport.bilibili.com/h5/auth?auth_code=aaa',
            'auth_code': 'aaa',
          },
        },
      });
      final info = await api.getTvQrcodeLoginInfo();
      expect(info, isNotNull);
      expect(info!.authCode, 'aaa');
      expect(info.url, contains('auth_code=aaa'));
      // POST form 请求
      final req = adapter.requests.last;
      expect(req.method, 'POST');
      expect(req.headers['content-type'],
          contains('application/x-www-form-urlencoded'));
    });

    test('TV 轮询：86039 未确认（data null）与登录成功', () async {
      adapter.onPath('/x/passport-tv-login/qrcode/poll', {
        'body': {'code': 86039, 'message': '二维码尚未确认', 'data': null},
      });
      final pending = await api.checkTvQrcodeLoginStatus('auth1');
      expect(pending!.code, 86039);
      expect(pending.cookies, isEmpty);

      adapter.onPath('/x/passport-tv-login/qrcode/poll', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {
            'mid': 888,
            'access_token': 'atv',
            'refresh_token': 'rtv',
            'cookie_info': {
              'cookies': [
                {'name': 'SESSDATA', 'value': 'tv_sess'},
              ],
            },
          },
        },
      });
      final ok = await api.checkTvQrcodeLoginStatus('auth1');
      expect(ok!.code, 0);
      expect(ok.cookies['SESSDATA'], 'tv_sess');
      expect(ok.accessToken, 'atv');
    });

    test('TV 二维码生成失败（风控 412）返回 null', () async {
      adapter.onPath('/x/passport-tv-login/qrcode/auth_code', {
        'status': 412,
        'body': {},
      });
      expect(await api.getTvQrcodeLoginInfo(), isNull);
    });
  });

  group('playurl App 接口', () {
    test('无 access_token 直接返回 null（回退 web 的触发条件）', () async {
      expect(await api.getAudioApp('BV1xxx', 123, accessToken: null), isNull);
      expect(await api.getAudioApp('BV1xxx', 123, accessToken: ''), isNull);
    });

    test('access_key 失效 -101 时返回 null 并清除 token', () async {
      await SharedPreferencesService.setAccessToken('stale_tok');
      adapter.onPath('/x/player/playurl', {
        'body': {'code': -101, 'message': 'access key check failed'},
      });
      expect(await api.getAudioApp('BV1xxx', 123, accessToken: 'stale_tok'),
          isNull);
      expect(await SharedPreferencesService.getAccessToken(), '');
    });

    test('Android 登录用 HD appkey + buvid + App 头（避免 -351）', () async {
      await SharedPreferencesService.setAccessTokenPlatform('android');
      adapter.onPath('/x/player/playurl',
          _playUrlRoute([_audioStream(30280, 'https://cdn/80.m4s')]));
      final audio = await api.getAudioApp('BV1xxx', 123,
          accessToken: 'tok', buvid: 'XY1234567890');
      expect(audio, hasLength(1));

      final req = adapter.requests.last;
      expect(req.queryParameters['appkey'], BiliSign.androidHdAppKey);
      expect(req.queryParameters['mobi_app'], 'android_hd');
      expect(req.queryParameters['buvid'], 'XY1234567890');
      expect(req.queryParameters['sign'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(req.headers['app-key'], 'android_hd');
      expect(req.headers['buvid'], 'XY1234567890');
      // App 接口不混入 Web cookie/Referer
      expect(req.headers.containsKey('cookie'), isFalse);
    });

    test('-351 风控后冷却期内不再请求 App 接口', () async {
      await SharedPreferencesService.setAccessTokenPlatform('android');
      adapter.onPath('/x/player/playurl', {
        'body': {'code': -351, 'message': 'risk control'},
      });
      expect(
          await api.getAudioApp('BV1xxx', 123,
              accessToken: 'tok', buvid: 'XY1234567890'),
          isNull);
      final requestsAfterFirst = adapter.requests.length;
      expect(
          await api.getAudioApp('BV1xxx', 123,
              accessToken: 'tok', buvid: 'XY1234567890'),
          isNull);
      expect(adapter.requests.length, requestsAfterFirst);
    });
  });

  group('getLoginCaptcha / 极验参数', () {
    test('解析 data.geetest 嵌套结构', () async {
      adapter.onPath('/x/passport-login/captcha', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {
            'type': 'geetest',
            'token': 'tok',
            'geetest': {'gt': 'gg', 'challenge': 'cc'},
          },
        },
      });
      final captcha = await api.getLoginCaptcha();
      expect(captcha, isNotNull);
      expect(captcha!['gt'], 'gg');
      expect(captcha['challenge'], 'cc');
      expect(captcha['token'], 'tok');
    });

    test('type=tencent（无 geetest 字段）返回 null 不崩溃', () async {
      adapter.onPath('/x/passport-login/captcha', {
        'body': {
          'code': 0,
          'message': 'OK',
          'data': {
            'type': 'tencent',
            'token': 'tok',
            'tencent': {'appid': 'a'}
          },
        },
      });
      // 极验字段缺失 → callback 抛 → _callAPI 兜底 null
      expect(await api.getLoginCaptcha(), isNull);
    });
  });
}

const _wbiKey1 =
    '7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45';
const _wbiKey2 =
    'ea1db124af3c7062474693fa704f4ff8ea1db124af3c7062474693fa704f4ff8';
const _testBuvid3 = 'D9656DA8-9BEF-F464-5B72-C4849AFD336379044infoc';
const _testBuvid4 =
    'F6E0FD4B-520C-1902-4F7B-E461D8D1F5AB79044-024072309-666onEZSnlHVPjoRp4kDYg==';

Map<String, dynamic> _fingerSpiRoute() => {
      'body': {
        'code': 0,
        'message': 'ok',
        'data': {'b_3': _testBuvid3, 'b_4': _testBuvid4},
      },
    };

Map<String, dynamic> _navRoute(String key) => {
      'body': {
        'code': 0,
        'message': '0',
        'data': {
          'wbi_img': {
            'img_url': 'https://i0.hdslb.com/bfs/wbi/$key.png',
            'sub_url': 'https://i0.hdslb.com/bfs/wbi/${key}sub.png',
          },
        },
      },
    };

Map<String, dynamic> _vVoucherRoute() => {
      'body': {
        'code': 0,
        'message': '0',
        'data': {'v_voucher': 'voucher_84a8c3ce-33f5-4551-9552-9c6b13aa7938'},
      },
    };

Map<String, dynamic> _audioStream(int id, String url) => {
      'id': id,
      'base_url': url,
      'backup_url': <String>[],
      'bandwidth': 1000,
      'mime_type': 'audio/mp4',
      'codecs': 'mp4a.40.2',
      'frame_rate': '',
      'sar': '',
      'start_with_sap': 1,
      'codecid': 0,
    };

Map<String, dynamic> _playUrlRoute(List<Map<String, dynamic>> audio) => {
      'body': {
        'code': 0,
        'message': '0',
        'data': {
          'dash': {
            'duration': 1000,
            'min_buffer_time': 1.0,
            'video': <dynamic>[],
            'audio': audio,
          },
        },
      },
    };
