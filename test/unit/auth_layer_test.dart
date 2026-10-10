import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
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

  setUp(() {
    adapter = FakeHttpAdapter();
    api = BilibiliAPI(enableConnectivity: false);
    api.noNetwork = false;
    api.dio.httpClientAdapter = adapter;
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
      expect(req.headers['content-type'], contains('application/x-www-form-urlencoded'));
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
          'data': {'type': 'tencent', 'token': 'tok', 'tencent': {'appid': 'a'}},
        },
      });
      // 极验字段缺失 → callback 抛 → _callAPI 兜底 null
      expect(await api.getLoginCaptcha(), isNull);
    });
  });
}