import 'package:bmsc/model/release.dart';
import 'package:bmsc/util/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

final _logger = LoggerUtils.getLogger('Update');

class UpdateService {
  static Future<UpdateService> instance = _init();

  List<ReleaseResult>? newVersionInfo;
  bool hasNewVersion = false;
  String? curVersion;

  static Future<UpdateService> _init() async {
    final x = UpdateService();
    final packageInfo = await PackageInfo.fromPlatform();
    x.newVersionInfo = await checkNewVersion();
    x.curVersion = packageInfo.version;
    x.hasNewVersion = isNewerVersion(
        x.newVersionInfo?.firstOrNull?.tagName, x.curVersion);
    return x;
  }

  /// 简单语义化版本比较：只有远端版本严格更新才返回 true
  static bool isNewerVersion(String? remoteTag, String? curVersion) {
    if (remoteTag == null || curVersion == null) {
      return false;
    }
    List<int> parse(String v) => v
        .replaceFirst(RegExp(r'^v'), '')
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final remote = parse(remoteTag);
    final local = parse(curVersion);
    final length =
        remote.length > local.length ? remote.length : local.length;
    for (var i = 0; i < length; i++) {
      final r = i < remote.length ? remote[i] : 0;
      final l = i < local.length ? local[i] : 0;
      if (r != l) {
        return r > l;
      }
    }
    return false;
  }

  static Future<List<ReleaseResult>?> checkNewVersion() async {
    List<ReleaseResult>? ret;
    try {
      _logger.info("requesting latest release");
      final resp = await Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      )).get('https://api.github.com/repos/u2x1/bmsc/releases');
      ret = List.from(resp.data).map((e) => ReleaseResult.fromJson(e)).toList();
    } catch (e) {
      _logger.severe("error: $e");
      return null;
    }
    return ret;
  }

  void showUpdateDialog(BuildContext context, String curVersion) {
    if (newVersionInfo == null || newVersionInfo!.isEmpty) {
      return;
    }
    var changelog = "";
    for (var version in newVersionInfo!) {
      changelog += "# ${version.tagName}\n\n${version.body}\n\n";
      if (version.tagName == 'v$curVersion') {
        break;
      }
    }
    final newVersion = newVersionInfo!.first;

    Future<void> openUrl(String url) async {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接，请手动访问发布页')),
        );
      }
    }

    // TODO: 目前固定下载 arm64 安装包；后续可按设备 ABI
    // （需引入 device_info 等能力）从 newVersion.assets 中匹配对应 APK
    final downloadUrl =
        "https://github.com/u2x1/bmsc/releases/download/${newVersion.tagName}/bmsc-${newVersion.tagName}-arm64.apk";

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text("有新版本可用"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("检测到版本更新 ($curVersion -> ${newVersion.tagName})"),
              const SizedBox(height: 10),
              Flexible(child: SingleChildScrollView(child: Text(changelog))),
            ],
          ),
          actions: [
            TextButton(
              child: const Text("稍后"),
              onPressed: () => Navigator.pop(dialogContext),
            ),
            TextButton(
              child: const Text("查看"),
              onPressed: () => openUrl(
                  'https://github.com/u2x1/bmsc/releases/latest'),
            ),
            TextButton(
              child: const Text("下载"),
              onPressed: () {
                if (newVersion.assets.isNotEmpty) {
                  openUrl(downloadUrl);
                }
              },
            ),
          ],
        );
      },
    );
  }
}
