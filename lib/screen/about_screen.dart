import 'package:bmsc/model/release.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../service/update_service.dart';
import 'package:flutter/services.dart';
import 'package:bmsc/screen/log_screen.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String version = '';
  String latestVersion = '';
  List<ReleaseResult>? releases;
  bool hasNewVersion = false;
  List<(String, String)> changelog = [];

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
    _checkNewVersion();
  }

  Future<void> _checkNewVersion() async {
    final x = await UpdateService.instance;
    if (mounted) {
      setState(() {
        releases = x.newVersionInfo;
        hasNewVersion = x.hasNewVersion;
        latestVersion = x.newVersionInfo?.firstOrNull?.tagName
                .replaceFirst(RegExp(r'^v'), '') ??
            '';
      });
    }
  }

  Future<void> _checkUpdateManually() async {
    final x = await UpdateService.instance;
    final info = await UpdateService.checkNewVersion();
    if (!mounted) {
      return;
    }
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败，请稍后重试')),
      );
      return;
    }
    x.newVersionInfo = info;
    x.hasNewVersion = UpdateService.isNewerVersion(
        info.firstOrNull?.tagName, x.curVersion);
    setState(() {
      releases = x.newVersionInfo;
      hasNewVersion = x.hasNewVersion;
      latestVersion = x.newVersionInfo?.firstOrNull?.tagName
              .replaceFirst(RegExp(r'^v'), '') ??
          '';
    });
    if (hasNewVersion) {
      x.showUpdateDialog(context, version);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前已是最新版本')),
      );
    }
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    List<(String, String)> c = [];
    try {
      final changelogAsset = await rootBundle.loadString('changelog.md');
      c = changelogAsset
          .split('#')
          .map((e) => e.trim())
          .map((e) => e
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList())
          .where((e) => e.isNotEmpty)
          .map((e) => (e[0], e.sublist(1).join('\n')))
          .toList();
    } catch (_) {
      // changelog 资源缺失或解析失败时静默忽略
    }
    if (mounted) {
      setState(() {
        version = currentVersion;
        changelog = c;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/icon.png',
                      width: 100,
                      height: 100,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'BMSC',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  version,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (hasNewVersion) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.system_update),
                    label: const Text('新版本'),
                    onPressed: () async {
                      if (releases != null) {
                        final x = await UpdateService.instance;
                        if (context.mounted) {
                          x.showUpdateDialog(context, version);
                        }
                      }
                    },
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('检查更新'),
                    onPressed: _checkUpdateManually,
                  ),
                ],
                const SizedBox(height: 32),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Divider(),
                        const SizedBox(height: 16),
                        Text(
                          '© ${DateTime.now().year} u2x1',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '资源版权仍归原网站或其作者所有',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8.0,
                          runSpacing: 8.0,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.code),
                              label: const Text('开源代码'),
                              onPressed: () => launchUrl(
                                Uri.parse('https://github.com/u2x1/bmsc'),
                                mode: LaunchMode.externalApplication,
                              ),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.bug_report),
                              label: const Text('问题反馈'),
                              onPressed: () => launchUrl(
                                Uri.parse(
                                    'https://github.com/u2x1/bmsc/issues'),
                                mode: LaunchMode.externalApplication,
                              ),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.article_outlined),
                              label: const Text('日志'),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (context) => const LogScreen(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text(
              '更新历史',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...changelog.map((entry) => Card(
                margin: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entry.$1,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (entry.$1 == version)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                '当前',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          const SizedBox(width: 8),
                          if (entry.$1 == latestVersion &&
                              latestVersion != version)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .tertiaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                '最新',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        entry.$2,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
