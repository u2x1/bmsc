const String _baseUrl = 'https://api.bilibili.com';
const String _passportUrl = 'https://passport.bilibili.com';
const String _searchUrl = 'https://s.search.bilibili.com';
const String apiUserInfoUrl = '$_baseUrl/x/web-interface/card';
const String apiCommentUrl = '$_baseUrl/x/v2/reply/wbi/main';
const String apiCommentsOfCommentUrl = '$_baseUrl/x/v2/reply/reply';
const String apiUserUploadsUrl = '$_baseUrl/x/space/wbi/arc/search';
const String apiMyInfoUrl = '$_baseUrl/x/space/myinfo';
const String apiFavsUrl = '$_baseUrl/x/v3/fav/folder/created/list-all';
const String apiFavListUrl = '$_baseUrl/x/v3/fav/folder/created/list';
const String apiCollectionUrl = '$_baseUrl/x/v3/fav/folder/collected/list';
const String apiCollectionMetasUrl = '$_baseUrl/x/space/fav/season/list';
const String apiFavMetasUrl = '$_baseUrl/x/v3/fav/resource/list';
const String apiSearchUrl = '$_baseUrl/x/web-interface/wbi/search/type';
const String apiHistoryUrl = '$_baseUrl/x/web-interface/history/cursor';
const String apiDynamicUrl = '$_baseUrl/x/polymer/web-dynamic/v1/feed/all';
const String apiAudioUrl = '$_baseUrl/x/player/wbi/playurl';
const String apiHotSearchUrl = '$_baseUrl/x/web-interface/search/square';
const String apiRankingUrl = '$_baseUrl/x/web-interface/ranking/v2';
const String apiPageListUrl = '$_baseUrl/x/player/pagelist';
const String apiUserInfoByMidUrl = '$_baseUrl/x/space/wbi/acc/info';
const String apiToViewUrl = '$_baseUrl/x/v2/history/toview';
const String apiToViewDelUrl = '$_baseUrl/x/v2/history/toview/del';
const String apiToViewClearUrl = '$_baseUrl/x/v2/history/toview/clear';
const String apiThumbUpUrl = '$_baseUrl/x/web-interface/archive/like';
const String apiHasLikedUrl = '$_baseUrl/x/web-interface/archive/has/like';
const String apiBatchDelFavUrl = '$_baseUrl/x/v3/fav/resource/batch-del';
const String apiFavResourceIdsUrl = '$_baseUrl/x/v3/fav/resource/ids';
const String apiVideoDetailUrl = '$_baseUrl/x/web-interface/view';
const String apiDoFavVideoUrl = '$_baseUrl/x/v3/fav/resource/deal';
const String apiIsFavoritedUrl = '$_baseUrl/x/v2/fav/video/favoured';
const String apiCreateFavFolderUrl = '$_baseUrl/x/v3/fav/folder/add';
const String apiDeleteFavFolderUrl = '$_baseUrl/x/v3/fav/folder/del';
const String apiEditFavFolderUrl = '$_baseUrl/x/v3/fav/folder/edit';
const String apiRelatedVideosUrl = '$_baseUrl/x/web-interface/archive/related';
const String apiSearchSuggestionsUrl = '$_searchUrl/main/suggest';
const String apiNavUrl = '$_baseUrl/x/web-interface/nav';
const String apiGeetestParamsUrl = '$_passportUrl/x/passport-login/web/key';
const String apiLoginCaptchaUrl = '$_passportUrl/x/passport-login/captcha';
const String apiLoginKeyUrl = '$_passportUrl/x/passport-login/web/key';
const String apiSmsCaptchaUrl = '$_passportUrl/x/passport-login/web/sms/send';
const String apiPasswordLoginUrl = '$_passportUrl/x/passport-login/web/login';
const String apiSmsLoginUrl = '$_passportUrl/x/passport-login/web/login/sms';
const String apiReportHistoryUrl = '$_baseUrl/x/v2/history/report';
const String apiGetQrcodeLoginUrl =
    '$_passportUrl/x/passport-login/web/qrcode/generate';
const String apiCheckQrcodeLoginStatusUrl =
    '$_passportUrl/x/passport-login/web/qrcode/poll';
const String apiGetTvQrcodeLoginUrl =
    '$_passportUrl/x/passport-tv-login/qrcode/auth_code';
const String apiCheckTvQrcodeStatusUrl =
    '$_passportUrl/x/passport-tv-login/qrcode/poll';
const String apiTvTokenRefreshUrl =
    '$_passportUrl/x/passport-tv-login/h5/refresh';
// App 端登录接口实际由 passport 域名服务（api.bilibili.com 上这些路径
// 已 404；实测 passport 域名正常返回 JSON）。
const String apiAppPasswordLoginUrl =
    '$_passportUrl/x/passport-login/oauth2/login';
const String apiAppSmsCaptchaUrl = '$_passportUrl/x/passport-login/sms/send';
const String apiAppSmsLoginUrl = '$_passportUrl/x/passport-login/login/sms';
const String apiAppPlayUrlUrl = '$_baseUrl/x/player/playurl';
const String apiOauth2AccessTokenUrl =
    '$_passportUrl/x/passport-login/oauth2/access_token';
const String apiSafeCenterUserInfoUrl = '$_passportUrl/x/safecenter/user/info';
const String apiSafeCenterCaptchaPreUrl =
    '$_passportUrl/x/safecenter/captcha/pre';
const String apiSafeCenterSmsSendUrl =
    '$_passportUrl/x/safecenter/common/sms/send';
const String apiSafeCenterSmsVerifyUrl =
    '$_passportUrl/x/safecenter/login/tel/verify';
const String apiPlayer = '$_baseUrl/x/player/wbi/v2';
