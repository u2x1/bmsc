// 登录相关数据模型（对齐 BiliPai / bilibili-API-collect passport 接口）

/// 极验/腾讯验证参数
class CaptchaData {
  final String token;
  final String? gt;
  final String? challenge;
  final String type; // geetest / tencent

  CaptchaData({
    required this.token,
    this.gt,
    this.challenge,
    this.type = 'geetest',
  });

  factory CaptchaData.fromJson(Map<String, dynamic> json) {
    final geetest = json['geetest'];
    return CaptchaData(
      token: json['token'] ?? '',
      gt: geetest is Map ? geetest['gt'] as String? : null,
      challenge:
          geetest is Map ? geetest['challenge'] as String? : null,
      type: json['type'] ?? 'geetest',
    );
  }
}

/// TV 端二维码登录信息
class TvQrLoginInfo {
  final String url;
  final String authCode;

  TvQrLoginInfo({required this.url, required this.authCode});

  factory TvQrLoginInfo.fromJson(Map<String, dynamic> json) =>
      TvQrLoginInfo(url: json['url'] ?? '', authCode: json['auth_code'] ?? '');
}

/// TV 端二维码轮询结果
class TvQrPollResult {
  final int code; // 0 成功 / 86090 已扫码 / 86038 过期 / 86101 未扫码
  final String message;
  final int mid;
  final String accessToken;
  final String refreshToken;
  final Map<String, String> cookies;

  TvQrPollResult({
    required this.code,
    this.message = '',
    this.mid = 0,
    this.accessToken = '',
    this.refreshToken = '',
    this.cookies = const {},
  });

  factory TvQrPollResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map) {
      return TvQrPollResult(code: json['code'] ?? -1, message: json['message'] ?? '');
    }
    final cookies = <String, String>{};
    final cookieInfo = data['cookie_info'];
    if (cookieInfo is Map) {
      final list = cookieInfo['cookies'];
      if (list is List) {
        for (final c in list) {
          if (c is Map && c['name'] != null && c['value'] != null) {
            cookies[c['name'] as String] = c['value'] as String;
          }
        }
      }
    }
    return TvQrPollResult(
      code: data['code'] ?? json['code'] ?? -1,
      message: data['message'] ?? json['message'] ?? '',
      mid: data['mid'] ?? 0,
      accessToken: data['access_token'] ?? '',
      refreshToken: data['refresh_token'] ?? '',
      cookies: cookies,
    );
  }
}

/// 单个 cookie 项（登录响应 body 的 cookie_info）
class BiliCookie {
  final String name;
  final String value;

  BiliCookie(this.name, this.value);

  factory BiliCookie.fromJson(Map<String, dynamic> json) =>
      BiliCookie(json['name'] ?? '', json['value'] ?? '');
}

/// App 端/Web 端登录响应（密码 / 短信 / 风控通用）
class AppLoginResult {
  final int code; // 接口层 code
  final String message;
  final int status; // data.status，0=成功，2=风控
  final String url; // -105 时的重验证 URL / status=2 时的风控 URL
  final Map<String, String> cookies; // header + body cookie_info 合并
  final String accessToken;
  final String refreshToken;
  final int mid;

  AppLoginResult({
    required this.code,
    this.message = '',
    this.status = 0,
    this.url = '',
    this.cookies = const {},
    this.accessToken = '',
    this.refreshToken = '',
    this.mid = 0,
  });

  bool get isSuccess => code == 0 && status == 0;

  /// -105: 需要重新完成人机验证（url 里带新的 recaptcha 参数）
  bool get needRecaptcha => code == -105;

  /// status=2: 密码登录触发风控，需走安全中心短信验证
  bool get needRiskVerification => code == 0 && status == 2;

  factory AppLoginResult.fromResponse(
      Map<String, dynamic> body, List<String> setCookieHeaders) {
    final cookies = <String, String>{};
    // header Set-Cookie 解析
    for (final line in setCookieHeaders) {
      for (final part in line.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          cookies[part.substring(0, idx).trim()] = part.substring(idx + 1);
        }
      }
    }
    final data = body['data'];
    final mid = data is Map ? data['mid'] ?? 0 : 0;
    if (data is Map) {
      // body cookie_info 双保险
      final cookieInfo = data['cookie_info'];
      if (cookieInfo is Map) {
        final list = cookieInfo['cookies'];
        if (list is List) {
          for (final c in list) {
            if (c is Map && c['name'] != null && c['value'] != null) {
              cookies[c['name'] as String] = c['value'] as String;
            }
          }
        }
      }
    }
    return AppLoginResult(
      code: body['code'] ?? -1,
      message: body['message'] ?? '',
      status: data is Map ? data['status'] ?? 0 : 0,
      url: data is Map ? data['url'] ?? '' : '',
      cookies: cookies,
      accessToken:
          data is Map && data['token_info'] is Map ? data['token_info']['access_token'] ?? '' : '',
      refreshToken:
          data is Map && data['token_info'] is Map ? data['token_info']['refresh_token'] ?? '' : '',
      mid: mid,
    );
  }
}

/// 安全中心信息（风控流程）
class SafeCenterInfo {
  final String hideTel;
  final bool telVerify;

  SafeCenterInfo({required this.hideTel, required this.telVerify});

  factory SafeCenterInfo.fromJson(Map<String, dynamic> json) {
    final account = json['account_info'];
    return SafeCenterInfo(
      hideTel: account is Map ? account['hide_tel'] ?? '' : '',
      telVerify: account is Map ? account['tel_verify'] ?? false : false,
    );
  }
}

/// 安全中心极验预捕获参数
class SafeCenterCaptchaPre {
  final String recaptchaType;
  final String recaptchaToken;
  final String geeChallenge;
  final String geeGt;

  SafeCenterCaptchaPre({
    this.recaptchaType = '',
    this.recaptchaToken = '',
    this.geeChallenge = '',
    this.geeGt = '',
  });

  bool get isReady =>
      geeGt.isNotEmpty && geeChallenge.isNotEmpty && recaptchaToken.isNotEmpty;

  factory SafeCenterCaptchaPre.fromJson(Map<String, dynamic> json) =>
      SafeCenterCaptchaPre(
        recaptchaType: json['recaptcha_type'] ?? '',
        recaptchaToken: json['recaptcha_token'] ?? '',
        geeChallenge: json['gee_challenge'] ?? '',
        geeGt: json['gee_gt'] ?? '',
      );
}

/// 风控验证 URL（tmp_code / request_id / source）解析
class RiskVerifyParams {
  final String tmpCode;
  final String requestId;
  final String source;
  final String refererUrl;

  RiskVerifyParams({
    required this.tmpCode,
    required this.requestId,
    required this.source,
    required this.refererUrl,
  });

  bool get isValid => tmpCode.isNotEmpty;
}

/// 解析 -105 / status=2 返回的验证 URL。
/// 形如 https://passport.bilibili.com/register2/risk?source=risk&request_id=xxx&tmp_code=xxx
/// tmp_code 与 request_id 缺任一返回 null（对齐 BiliPai LoginRiskPolicy）
RiskVerifyParams? parseRiskVerifyUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final params = uri.queryParameters;
  final tmpCode = (params['tmp_code'] ?? params['tmpToken'] ?? '').trim();
  final requestId = (params['request_id'] ?? '').trim();
  if (tmpCode.isEmpty || requestId.isEmpty) return null;
  final source = (params['source'] ?? 'risk').trim().isEmpty
      ? 'risk'
      : params['source']!.trim();
  return RiskVerifyParams(
    tmpCode: tmpCode,
    requestId: requestId,
    source: source,
    refererUrl: url,
  );
}

/// -105 recaptcha URL 解析（新的极验参数）
CaptchaData? parseLoginRecaptchaUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final params = uri.queryParameters;
  final gt = params['gt'];
  final challenge = params['challenge'];
  final token = params['token'];
  if (gt == null || challenge == null || (token ?? '').isEmpty) return null;
  return CaptchaData(gt: gt, challenge: challenge, token: token!);
}