import 'dart:io';

/// live 集成测试开关：`BMSC_LIVE=1 dart test test/integration`
bool get isLive => Platform.environment['BMSC_LIVE'] == '1';

/// 可选：提供已登录 cookie（如 `SESSDATA=...; bili_jct=...`）验证登录态接口
String? get liveCookie => Platform.environment['BMSC_COOKIE'];