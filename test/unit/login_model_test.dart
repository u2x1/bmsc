import 'dart:convert';

import 'package:bmsc/model/login.dart';
import 'package:test/test.dart';

/// 登录模型与 URL 解析测试（对齐 BiliPai / bilibili-API-collect 响应结构）。
void main() {
  group('AppLoginResult.fromResponse', () {
    test('成功：合并 Set-Cookie 头与 body cookie_info', () {
      final result = AppLoginResult.fromResponse({
        'code': 0,
        'message': 'OK',
        'data': {
          'status': 0,
          'mid': 123456,
          'cookie_info': {
            'cookies': [
              {'name': 'SESSDATA', 'value': 'fromBody', 'http_only': 1},
              {'name': 'bili_jct', 'value': 'csrfBody'},
            ],
          },
          'token_info': {
            'access_token': 'tok_abc',
            'refresh_token': 'tok_ref',
          },
        },
      }, [
        'SESSDATA=fromHeader; Path=/; HttpOnly',
        'DedeUserID=123456; Path=/',
      ]);
      expect(result.isSuccess, isTrue);
      expect(result.mid, 123456);
      // header 与 body 合并，同名以 body 为准
      expect(result.cookies['SESSDATA'], 'fromBody');
      expect(result.cookies['bili_jct'], 'csrfBody');
      expect(result.cookies['DedeUserID'], '123456');
      expect(result.accessToken, 'tok_abc');
      expect(result.refreshToken, 'tok_ref');
    });

    test('status=2 触发风控（needRiskVerification）', () {
      final result = AppLoginResult.fromResponse({
        'code': 0,
        'message': 'OK',
        'data': {
          'status': 2,
          'url':
              'https://passport.bilibili.com/register2/risk?source=risk&request_id=r123&tmp_code=t456',
        },
      }, []);
      expect(result.needRiskVerification, isTrue);
      expect(result.isSuccess, isFalse);
      final risk = parseRiskVerifyUrl(result.url);
      expect(risk, isNotNull);
      expect(risk!.tmpCode, 't456');
      expect(risk.requestId, 'r123');
      expect(risk.source, 'risk');
      expect(risk.refererUrl, contains('tmp_code=t456'));
    });

    test('code=-105 需要重新人机验证（needRecaptcha）', () {
      final result = AppLoginResult.fromResponse({
        'code': -105,
        'message': '需要重新验证',
        'data': {
          'url':
              'https://passport.bilibili.com/register2/captcha?gt=gt123&challenge=ch456&token=tok789',
        },
      }, []);
      expect(result.needRecaptcha, isTrue);
      final captcha = parseLoginRecaptchaUrl(result.url);
      expect(captcha, isNotNull);
      expect(captcha!.gt, 'gt123');
      expect(captcha.challenge, 'ch456');
      expect(captcha.token, 'tok789');
    });

    test('data 缺失（如接口层错误）不崩溃', () {
      final result = AppLoginResult.fromResponse({
        'code': -400,
        'message': '请求错误',
      }, []);
      expect(result.isSuccess, isFalse);
      expect(result.cookies, isEmpty);
      expect(result.accessToken, isEmpty);
    });
  });

  group('TvQrPollResult.fromJson', () {
    test('未扫码/未确认：状态码在外层 code，data 为 null（外层兜底）', () {
      final result = TvQrPollResult.fromJson({
        'code': 86039,
        'message': '二维码尚未确认',
        'data': null,
      });
      expect(result.code, 86039);
      expect(result.cookies, isEmpty);
    });

    test('登录成功：status 0 + cookie_info + access_token 解析', () {
      final result = TvQrPollResult.fromJson({
        'code': 0,
        'message': 'OK',
        'data': {
          'mid': 999,
          'access_token': 'atv_ac',
          'refresh_token': 'atv_ref',
          'cookie_info': {
            'cookies': [
              {'name': 'SESSDATA', 'value': 'tv_sess', 'http_only': 1},
              {'name': 'bili_jct', 'value': 'tv_csrf'},
              {'name': 'DedeUserID', 'value': '999'},
            ],
          },
        },
      });
      expect(result.code, 0);
      expect(result.mid, 999);
      expect(result.accessToken, 'atv_ac');
      expect(result.refreshToken, 'atv_ref');
      expect(result.cookies['SESSDATA'], 'tv_sess');
      expect(result.cookies['bili_jct'], 'tv_csrf');
      expect(result.cookies['DedeUserID'], '999');
    });

    test('已扫码待确认（86090）', () {
      final result = TvQrPollResult.fromJson(
          jsonDecode('{"code": 86090, "message": "", "data": null}'));
      expect(result.code, 86090);
    });
  });

  group('CaptchaData.fromJson', () {
    test('geetest 嵌套结构（与 B 站 captcha 接口一致）', () {
      final captcha = CaptchaData.fromJson({
        'token': 'tok1',
        'type': 'geetest',
        'geetest': {'gt': 'gt1', 'challenge': 'ch1'},
      });
      expect(captcha.token, 'tok1');
      expect(captcha.gt, 'gt1');
      expect(captcha.challenge, 'ch1');
    });

    test('tencent 类型无 geetest 字段不崩溃', () {
      final captcha = CaptchaData.fromJson({
        'token': 'tok2',
        'type': 'tencent',
        'tencent': {'appid': 'a1'},
      });
      expect(captcha.type, 'tencent');
      expect(captcha.gt, isNull);
    });

    test('无 geetest 字段（结构异常）不崩溃', () {
      final captcha = CaptchaData.fromJson({'token': 'tok3'});
      expect(captcha.gt, isNull);
    });
  });

  group('URL 解析边界', () {
    test('parseRiskVerifyUrl：缺少 tmp_code 返回 null', () {
      expect(
          parseRiskVerifyUrl('https://passport.bilibili.com/x?source=risk'),
          isNull);
    });
    test('parseRiskVerifyUrl：非法 URL 返回 null', () {
      expect(parseRiskVerifyUrl('not a url'), isNull);
    });
    test('parseLoginRecaptchaUrl：缺少 challenge 返回 null', () {
      expect(parseLoginRecaptchaUrl('https://x/?gt=a&token=b'), isNull);
    });
    test('parseLoginRecaptchaUrl：缺少 token 返回 null', () {
      expect(parseLoginRecaptchaUrl('https://x/?gt=a&challenge=b'), isNull);
    });
  });

  group('SafeCenterCaptchaPre.fromJson', () {
    test('完整参数 isReady', () {
      final pre = SafeCenterCaptchaPre.fromJson({
        'recaptcha_type': 'geetest',
        'recaptcha_token': 'rt',
        'gee_challenge': 'gc',
        'gee_gt': 'gg',
      });
      expect(pre.isReady, isTrue);
      expect(pre.geeGt, 'gg');
    });
    test('参数缺失 isReady=false', () {
      final pre = SafeCenterCaptchaPre.fromJson({'recaptcha_token': 'rt'});
      expect(pre.isReady, isFalse);
    });
  });
}