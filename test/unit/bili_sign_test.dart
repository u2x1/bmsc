import 'package:bmsc/util/bili_sign.dart';
import 'package:test/test.dart';

/// 签名与身份生成测试。
/// 期望值由 Python 复算 BiliPai / bilibili-API-collect 算法得到，与 Kotlin 实现一致。
void main() {
  group('BiliSign.signForTv（TV 登录签名，raw 拼接 + MD5）', () {
    test('与参考向量一致', () {
      final signed = BiliSign.signForTv({
        'appkey': '4409e2ce8ffd12b8',
        'local_id': '0',
        'ts': '1700000000',
      });
      expect(signed['sign'], 'ebb086c9f52ae7393619a89bdc320e45');
    });

    test('输入乱序时结果稳定（按 key 排序）', () {
      final a = BiliSign.signForTv({
        'ts': '1700000000',
        'local_id': '0',
        'appkey': '4409e2ce8ffd12b8',
      });
      final b = BiliSign.signForTv({
        'appkey': '4409e2ce8ffd12b8',
        'local_id': '0',
        'ts': '1700000000',
      });
      expect(a, equals(b));
      expect(a['sign'], 'ebb086c9f52ae7393619a89bdc320e45');
    });

    test('缺少 appkey 时自动补充也不影响结果一致性', () {
      // signForTv 不自动补 appkey（与 BiliPai sign() 一致），只处理传参
      final signed = BiliSign.signForTv({
        'appkey': BiliSign.tvAppKey,
        'auth_code': 'abc123',
        'local_id': '0',
        'ts': '1700000000',
      });
      expect(signed.keys, containsAll(['sign', 'auth_code']));
      expect(signed['sign'], isA<String>());
    });
  });

  group('BiliSign.signForAndroidHdLogin（Android-HD 登录签名，双编码）', () {
    test('与参考向量一致（pre-encode 后再签名，对齐 BiliPai 双编码）', () {
      final fromUrlPre = BiliSign.percentEncode('bilibili://user_center/mine');
      final dtPre = BiliSign.percentEncode('REPLACE_ME_RANDOM_DT_0123456789ab');
      final params = {
        'appkey': 'dfca71928277209b',
        'build': '2001100',
        'c_locale': 'zh_CN',
        'channel': 'master',
        'disable_rcmd': '0',
        'mobi_app': 'android_hd',
        'platform': 'android',
        's_locale': 'zh_CN',
        'statistics': '{"appId":5,"platform":3,"version":"2.0.1","abtest":""}',
        'ts': '1700000000',
        'bili_local_id': '55667788',
        'buvid': 'XY1234abcd',
        'device': 'phone',
        'device_id': '55667788',
        'device_name': 'vivo',
        'device_platform': 'Android14vivo',
        'dt': dtPre,
        'local_id': 'XY1234abcd',
        'username': '13800138000',
        'password': 'ENC_PASSWORD_0123456789abcdef',
        'permission': 'ALL',
        'from_pv': 'main.homepage.avatar-nologin.all.click',
        'from_url': fromUrlPre,
      };
      final signed = BiliSign.signForAndroidHdLogin(params);
      expect(signed['sign'], '9e3d66bdcf6d5e258a1a9152c2f5cd8d');
    });

    test('未传 appkey 时用 android_hd 默认值', () {
      final signed = BiliSign.signForAndroidHdLogin({'ts': '1'});
      expect(signed['appkey'], BiliSign.androidHdAppKey);
    });

    test('签名值固定 32 位 hex', () {
      final signed = BiliSign.signForAndroidHdLogin({'a': '1', 'b': '2'});
      expect(signed['sign'], matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('BiliSign.signForAndroidApi（playurl 签名，raw 拼接）', () {
    test('与 TV 签名算法等价（不同 appsec）且输出 32 位 hex', () {
      final signed = BiliSign.signForAndroidApi({
        'appkey': BiliSign.androidAppKey,
        'bvid': 'BV1GJ411x7h7',
        'cid': '12345',
        'qn': '64',
        'fnval': '20432',
        'ts': '1700000000',
      });
      expect(signed['appkey'], BiliSign.androidAppKey);
      expect(signed['sign'], matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('BiliSign.percentEncode（对齐 Java URLEncoder UTF-8）', () {
    test('URL 字符被编码', () {
      expect(BiliSign.percentEncode('bilibili://user_center/mine'),
          'bilibili%3A%2F%2Fuser_center%2Fmine');
    });
    test('空格 -> %20（不是 +）', () {
      expect(BiliSign.percentEncode('a b+c'), 'a%20b%2Bc');
    });
    test('-_.* 保留', () {
      expect(BiliSign.percentEncode('ab*cd-ef_gh.ij'), 'ab*cd-ef_gh.ij');
    });
    test('非 ASCII 按 UTF-8 字节编码', () {
      expect(BiliSign.percentEncode('中文'), '%E4%B8%AD%E6%96%87');
    });
  });

  group('BiliSign 身份生成', () {
    test('buvid 格式：XY + 35 hex（37 字符）', () {
      final buvid = BiliSign.createBuvid();
      expect(buvid, matches(RegExp(r'^XY[0-9a-f]{35}$')));
    });

    test('deviceId 格式：34 位 hex（md5 32 + 校验 2）', () {
      final deviceId = BiliSign.createDeviceId();
      expect(deviceId, matches(RegExp(r'^[0-9a-f]{34}$')));
    });

    test('buvid/deviceId 每次生成不同', () {
      expect(BiliSign.createBuvid(), isNot(BiliSign.createBuvid()));
      expect(BiliSign.createDeviceId(), isNot(BiliSign.createDeviceId()));
    });

    test('createLoginSessionId = md5(buvid + ts) 与参考向量一致', () {
      expect(BiliSign.createLoginSessionId('XY1234abcd', 1700000000123),
          'a82ef611e30f0c8e53cf940af900933d');
    });

    test('createRandomString：指定长度且仅含小写字母数字', () {
      final s = BiliSign.createRandomString(16);
      expect(s.length, 16);
      expect(s, matches(RegExp(r'^[0-9a-z]{16}$')));
    });
  });

  group('BiliSign 常量（与 bilibili-API-collect 登记值一致）', () {
    test('TV/Android/HD appkey 匹配官方登记', () {
      expect(BiliSign.tvAppKey, '4409e2ce8ffd12b8');
      expect(BiliSign.androidAppKey, '1d8b6e7d45233436');
      expect(BiliSign.androidHdAppKey, 'dfca71928277209b');
    });

    test('getTimestamp 为 10 位秒级时间戳', () {
      final ts = BiliSign.getTimestamp();
      expect(ts.length, 10);
      expect(int.parse(ts), closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000, 5));
    });
  });
}