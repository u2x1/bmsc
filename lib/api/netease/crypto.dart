import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:crypton/crypton.dart' as crypton;
import 'package:pointycastle/export.dart' as pointy;

const _iv = '0102030405060708';
const _presetKey = '0CoJUm6Qyw8W8jud';
const _linuxapiKey = 'rFgB&h#%2?^eDg:Q';
const _base62 = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const _publicKey = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
-----END PUBLIC KEY-----''';
const _eapiKey = 'e82ckenh8dichen8';

Uint8List _aesEncrypt(String text, String mode, String key, String iv) {
  final keyBytes = utf8.encode(key);
  final ivBytes = utf8.encode(iv);
  final plaintext = utf8.encode(text);

  pointy.BlockCipher underlying;
  if (mode == 'cbc') {
    underlying = pointy.CBCBlockCipher(pointy.AESEngine());
  } else {
    underlying = pointy.ECBBlockCipher(pointy.AESEngine());
  }
  final cipher = pointy.PaddedBlockCipherImpl(pointy.PKCS7Padding(), underlying);
  final params = mode == 'cbc'
      ? pointy.PaddedBlockCipherParameters(
          pointy.ParametersWithIV(pointy.KeyParameter(keyBytes), ivBytes), null)
      : pointy.PaddedBlockCipherParameters(pointy.KeyParameter(keyBytes), null);
  cipher.init(true, params);
  return cipher.process(plaintext);
}

Uint8List _rsaEncrypt(String str) {
  final pubKey = crypton.RSAPublicKey.fromPEM(_publicKey);
  final pointyKey = pubKey.asPointyCastle;
  final cipher = pointy.RSAEngine()
    ..init(true, pointy.PublicKeyParameter<pointy.RSAPublicKey>(pointyKey));
  return cipher.process(utf8.encode(str));
}

Map<String, String> weapi(Map<String, dynamic> object) {
  final text = jsonEncode(object);
  final random = Random.secure();
  var secretKey = '';
  for (var i = 0; i < 16; i++) {
    secretKey += _base62[random.nextInt(62)];
  }
  final firstEncrypted = _aesEncrypt(text, 'cbc', _presetKey, _iv);
  final firstB64 = base64.encode(firstEncrypted);
  final secondEncrypted = _aesEncrypt(firstB64, 'cbc', secretKey, _iv);
  final params = base64.encode(secondEncrypted);
  final encSecKey = _rsaEncrypt(secretKey.split('').reversed.join());
  return {
    'params': params,
    'encSecKey': encSecKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  };
}

Map<String, String> linuxapi(Map<String, dynamic> object) {
  final text = jsonEncode(object);
  final encrypted = _aesEncrypt(text, 'ecb', _linuxapiKey, '');
  return {
    'eparams': encrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  };
}

Map<String, String> eapi(String url, dynamic object) {
  final text = object is Map ? jsonEncode(object) : object.toString();
  final digest =
      crypto.md5.convert(utf8.encode('nobody${url}use${text}md5forencrypt')).toString();
  final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  final encrypted = _aesEncrypt(data, 'ecb', _eapiKey, '');
  return {
    'params': encrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  };
}

dynamic eapiResDecrypt(String encryptedParams) {
  final keyBytes = utf8.encode(_eapiKey);
  final cipher = pointy.ECBBlockCipher(pointy.AESEngine())
    ..init(false, pointy.KeyParameter(keyBytes));
  final ciphertext = _hexToBytes(encryptedParams);
  final decrypted = Uint8List(ciphertext.length);
  var offset = 0;
  while (offset < ciphertext.length) {
    offset += cipher.processBlock(ciphertext, offset, decrypted, offset);
  }
  final unpadded = _pkcs7Unpad(decrypted);
  final str = utf8.decode(unpadded);
  try {
    return jsonDecode(str);
  } catch (_) {
    return null;
  }
}

Uint8List _pkcs7Unpad(Uint8List data) {
  final padLen = data.isNotEmpty ? data[data.length - 1] : 0;
  if (padLen < 1 || padLen > 16) return data;
  return data.sublist(0, data.length - padLen);
}

Uint8List _hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}