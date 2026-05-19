import 'dart:math';

import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/util/logger.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:crypton/crypton.dart' as crypton;

final _logger = LoggerUtils.getLogger('Crypto');

String encryptPassword(String password, String key, String hash) {
  final pubKey = crypton.RSAPublicKey.fromPEM(key);
  final encryptedPassword = pubKey.encryptData(utf8.encode(hash + password));
  final b64Password = base64.encode(encryptedPassword);
  return b64Password;
}

String extractCSRF(String cookies) {
  final csrfMatch = RegExp(r'bili_jct=([^;]+)').firstMatch(cookies);
  return csrfMatch?.group(1) ?? '';
}

String _getMixinKey(String rawWbiKey) {
  const mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52
  ];

  return mixinKeyEncTab.map((e) => rawWbiKey[e]).join('').substring(0, 32);
}

Future<Map<String, dynamic>?> encodeParams(Map<String, dynamic> params) async {
  final rawWbiKey = await (await BilibiliService.instance).getRawWbiKey();
  if (rawWbiKey == null) return null;
  final mixinKey = _getMixinKey(rawWbiKey);
  final wts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  params['wts'] = wts.toString();
  final chrFilter = RegExp(r"[!'()*]");
  params = Map.fromEntries(
      params.entries
          .map((e) => MapEntry(e.key, e.value.toString().replaceAll(chrFilter, '')))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key)));
  final query = Uri(queryParameters: params).query;
  final encryptedQuery = query + mixinKey;
  final wRid = md5.convert(utf8.encode(encryptedQuery)).toString();
  _logger.info('encoded params with w_rid and wts');
  return {
    ...params,
    'w_rid': wRid,
  };
}

String generateDmImgStr() {
  final random = Random.secure();
  final length = 16 + random.nextInt(49);
  final bytes = List<int>.generate(length, (_) => 0x26 + random.nextInt(0x59));
  return base64.encode(bytes).substring(0, base64.encode(bytes).length - 2);
}

String generateDmCoverImgStr() {
  final random = Random.secure();
  final length = 32 + random.nextInt(97);
  final bytes = List<int>.generate(length, (_) => 0x26 + random.nextInt(0x59));
  return base64.encode(bytes).substring(0, base64.encode(bytes).length - 2);
}

String genAuroraEid(int uid) {
  if (uid == 0) return '';
  final midByte = utf8.encode(uid.toString());
  const key = 'ad1va46a7lza';
  for (int i = 0; i < midByte.length; i++) {
    midByte[i] ^= key.codeUnitAt(i % key.length);
  }
  return base64.encode(midByte).replaceAll('=', '');
}
