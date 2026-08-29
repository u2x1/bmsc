import 'package:bmsc/util/crypto.dart';
import 'package:bmsc/util/bili_sign.dart';
import 'package:test/test.dart';

/// WBI 签名与 RSA 加密测试（离线、确定性）。
const _testPublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDB7hV02Mx9geu6Vlc+zCq5hwbz
H2UliApty2q1UOTqFGGhIjPc1CTXjXROb4L61gixS5qkZbRUsigZBpoLBXaCZS+z
wx9WM/eoLuLk0RU7nvbh6XK/eXa13Hr/f50QpM6LCadGXojlQdpW+qGFGEWev16+
0LFosCLQLH57BLCPEQIDAQAB
-----END PUBLIC KEY-----
''';

void main() {
  group('getMixinKey（WBI mixin key 置换表）', () {
    test('与参考向量一致（bilibili-API-collect 算法）', () {
      const raw64 = 'ea1db124af3c7062474693fa704f4ff8'
          'ea1db124af3c7062474693fa704f4ff8';
      expect(getMixinKey(raw64), '62413aae24384d0dfc17af36f46472f0');
    });

    test('输出恒为 32 字符 hex', () {
      final raw =
          List.generate(64, (i) => (i % 16).toRadixString(16)).join();
      expect(getMixinKey(raw), matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('RSA 加密（encryptPassword / encryptDeviceToken）', () {
    test('encryptPassword 输出 base64 且两次结果不同（随机填充）', () {
      final a = encryptPassword('password123', _testPublicKeyPem, 'hash01');
      final b = encryptPassword('password123', _testPublicKeyPem, 'hash01');
      expect(a, isNot(b));
      expect(a, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
    });

    test('不同 hash 前缀产出不同密文', () {
      final a = encryptPassword('password123', _testPublicKeyPem, 'h1');
      final b = encryptPassword('password123', _testPublicKeyPem, 'h2');
      expect(a, isNot(b));
    });

    test('encryptDeviceToken 输出 base64', () {
      final token = BiliSign.createRandomString(16);
      final encrypted =
          encryptDeviceToken(_testPublicKeyPem, token);
      expect(encrypted, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
      expect(encrypted.length, greaterThan(100)); // 1024-bit RSA 密文 > 100B
    });

    test('非法 PEM 抛出异常（调用方自行兜底）', () {
      expect(() => encryptPassword('p', 'not-a-pem', 'h'),
          throwsA(anything));
    });
  });

  group('extractCSRF', () {
    test('从 cookie 串提取 bili_jct', () {
      expect(extractCSRF('SESSDATA=abc; bili_jct=csrf123; DedeUserID=1'),
          'csrf123');
    });
    test('无 bili_jct 返回空串', () {
      expect(extractCSRF('SESSDATA=abc'), '');
    });
  });
}