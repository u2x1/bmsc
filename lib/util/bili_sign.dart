import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// B 站 App 端登录签名与身份生成（移植自 BiliPai AppSignUtils / PiliPlusLoginIdentityPolicy）
/// 参考: https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/APPKey.md
class BiliSign {
  BiliSign._();

  /// TV 端 appkey/appsec（云视听小电视）。
  /// 通过某一组 APPKEY/APPSEC 获取的 access_token，后续调用也必须使用同一组。
  static const String tvAppKey = '4409e2ce8ffd12b8';
  static const String _tvAppSec = '59b43e04ad6965f34319062b478f83dd';

  /// Android 客户端 appkey/appsec（用于 playurl 等高画质接口）。
  static const String androidAppKey = '1d8b6e7d45233436';
  static const String _androidAppSec = '560c52ccd288fed045859ed18bffd973';

  /// Bilibili HD (android_hd) 客户端凭据，用于当前 SMS/密码登录接口。
  static const String androidHdAppKey = 'dfca71928277209b';

  /// App 端登录请求的 User-Agent（对齐官方 HD 客户端 / PiliPlus
  /// Constants.userAgent）。passport 风控校验 UA 与 app 签名 body 的
  /// 一致性：桌面 UA 会被以 -105「验证码错误」拒绝（真机实测）。
  static const String androidHdUserAgent =
      'Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android '
      'model/android_hd mobi_app/android_hd build/2001100 channel/master '
      'innerVer/2001100 osVer/15 network/2';

  /// App 端登录请求头（对齐 PiliPlus LoginHttp.headers）。
  static Map<String, String> androidLoginHeaders(String buvid) => {
        'buvid': buvid,
        'env': 'prod',
        'app-key': 'android_hd',
        'user-agent': androidHdUserAgent,
        'x-bili-trace-id':
            '11111111111111111111111111111111:1111111111111111:0:0',
        'x-bili-aurora-eid': '',
        'x-bili-aurora-zone': '',
        'bili-http-engine': 'cronet',
      };
  static const String _androidHdAppSec = 'b5475a8825547a4fc26c7d518eaaa02e';

  /// 与 Java URLEncoder.encode(s, UTF-8) 一致（再把 '+' 换成 '%20'，对齐 BiliPai）。
  /// 保留 [A-Za-z0-9\-_.*]，空格 -> %20，其余按 UTF-8 字节 percent 编码（大写十六进制）。
  static String percentEncode(String s) {
    final bytes = utf8.encode(s);
    final buf = StringBuffer();
    for (final b in bytes) {
      final c = String.fromCharCode(b);
      if (_safe.hasMatch(c)) {
        buf.write(c);
      } else {
        buf.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return buf.toString();
  }

  static final RegExp _safe = RegExp(r'^[A-Za-z0-9\-_.*]$');

  static String _md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// TV 登录签名：参数按 key 排序拼接 raw value，末尾加 appsec，MD5。
  static Map<String, String> signForTv(Map<String, String> params) {
    final sorted = Map<String, String>.fromEntries(
        params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    final qs = sorted.entries.map((e) => '${e.key}=${e.value}').join('&');
    final sign = _md5Hex(qs + _tvAppSec);
    return {...sorted, 'sign': sign};
  }

  /// Android-HD 登录签名：key/value 先 percent-encode 再按 key 排序拼接 + appsec，MD5。
  static Map<String, String> signForAndroidHdLogin(
      Map<String, String> params) {
    final withAppKey = params.containsKey('appkey')
        ? params
        : {...params, 'appkey': androidHdAppKey};
    final sorted = Map<String, String>.fromEntries(
        withAppKey.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    final qs = sorted.entries
        .map((e) => '${percentEncode(e.key)}=${percentEncode(e.value)}')
        .join('&');
    final sign = _md5Hex(qs + _androidHdAppSec);
    return {...sorted, 'sign': sign};
  }

  /// Android APP API 签名（playurl 等）：raw 值按 key 排序拼接 + appsec，MD5。
  static Map<String, String> signForAndroidApi(Map<String, String> params) {
    final sorted = Map<String, String>.fromEntries(
        params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    final qs = sorted.entries.map((e) => '${e.key}=${e.value}').join('&');
    final sign = _md5Hex(qs + _androidAppSec);
    return {...sorted, 'sign': sign};
  }

  /// md5(buvid + timestampMillis)，短信发送接口的 login_session_id。
  static String createLoginSessionId(String buvid, int timestampMillis) =>
      _md5Hex(buvid + timestampMillis.toString());

  /// 生成一次并持久化的 buvid（XY + 35 hex），对齐 PiliPlus Android-HD 身份。
  static String createBuvid() {
    final random = Random.secure();
    final seed = List<int>.generate(16, (_) => random.nextInt(256));
    final digest = md5.convert(seed).toString();
    return 'XY${digest[2]}${digest[12]}${digest[22]}$digest';
  }

  /// 进程级 device_id：16 随机字节 + 6 个 BCD 时间字节 + 8 随机字节，
  /// md5(字节) + 校验字节（小写 hex）。
  static String createDeviceId() {
    final random = Random.secure();
    final now = DateTime.now();
    final bytes = <int>[
      ...List<int>.generate(16, (_) => random.nextInt(256)),
      _toBcd(now.year ~/ 100),
      _toBcd(now.year % 100),
      _toBcd(now.month),
      _toBcd(now.day),
      _toBcd(now.hour),
      _toBcd(now.minute),
      _toBcd(now.second),
      ...List<int>.generate(8, (_) => random.nextInt(256)),
    ];
    final digest = md5.convert(bytes).toString();
    final checksum = (bytes.fold(0, (a, b) => a + b) & 0xFF)
        .toRadixString(16)
        .padLeft(2, '0');
    return digest + checksum;
  }

  static int _toBcd(int value) => ((value ~/ 10) << 4) | (value % 10);

  /// 随机小写字母数字串，用于 RSA 加密的设备凭据（dt）。
  static String createRandomString(int length) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return List.generate(
        length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  static String getTimestamp() => (DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .toString();
}