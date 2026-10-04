import 'package:bmsc/screen/feedback_screen.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/service/update_service.dart';
import 'package:bmsc/util/changelog.dart';
import 'package:bmsc/util/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

final _logger = LoggerUtils.getLogger('WhatsNew');

/// 新版本欢迎弹窗：升级后首次启动展示更新内容与新功能引导。
///
/// 内容分两层，均为通用机制：
/// 1. [_spotlights]：主打功能引导卡片（0..N 条，每版本发布前更新，
///    可带「去体验」跳转）；
/// 2. 更新内容：自动解析 changelog.md 并按 feat/fix/perf 等前缀分组展示，
///    无需额外维护。
class WhatsNew {
  static const _lastSeenVersionKey = 'last_seen_version';

  /// 在主页首帧后调用。仅在「严格更新版本」的首次启动弹窗；
  /// 全新安装不弹窗，仅记录版本。
  static Future<void> maybeShow(BuildContext context) async {
    final prefs = await SharedPreferencesService.instance;
    final packageInfo = await PackageInfo.fromPlatform();
    final current = packageInfo.version;
    final lastSeen = prefs.getString(_lastSeenVersionKey);

    if (lastSeen == null) {
      await prefs.setString(_lastSeenVersionKey, current);
      return;
    }
    if (!UpdateService.isNewerVersion(current, lastSeen)) return;

    // 先记录版本再弹窗：弹窗流程被打断也不重复展示
    await prefs.setString(_lastSeenVersionKey, current);
    _logger.info('upgraded: $lastSeen -> $current, showing what\'s new');
    final entries = await _loadChangelog(current);
    if (context.mounted) {
      await _showDialog(context, current, entries);
    }
  }

  /// 优先取与当前版本匹配的更新内容，找不到回退到最新一节
  static Future<List<(String, String)>> _loadChangelog(
      String current) async {
    try {
      final entries = parseChangelog(await rootBundle.loadString(
        'changelog.md',
      ));
      final matched = entries.where((e) => e.$1 == current);
      if (matched.isNotEmpty) return matched.toList();
      return entries.take(1).toList();
    } catch (e) {
      _logger.warning('load changelog failed: $e');
      return [];
    }
  }

  static Future<void> _showDialog(BuildContext context, String version,
      List<(String, String)> entries) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('新版本 $version'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in _spotlights) ...[
                  _spotlightCard(dialogContext, context, s),
                  const SizedBox(height: 8),
                ],
                for (final entry in entries) ...[
                  if (_spotlights.isNotEmpty) const SizedBox(height: 8),
                  ..._changelogContent(entry),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 更新内容：按条目前缀自动分组（新功能/问题修复/优化改进/其他）
  static List<Widget> _changelogContent((String, String) entry) {
    final groups = groupChangelog(entry.$2);
    if (groups.isEmpty) return [];
    return [
      const Text('更新内容', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      for (final (key, lines) in groups) ...[
        Text(
          kChangelogGroups.firstWhere((g) => g.$1 == key).$2,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        const SizedBox(height: 4),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('· $line', style: const TextStyle(fontSize: 13)),
          ),
        const SizedBox(height: 8),
      ],
    ];
  }

  /// 主打功能引导卡片：图标 + 标题 + 描述 + 可选「去体验」跳转
  static Widget _spotlightCard(BuildContext dialogContext,
      BuildContext pageContext, _Spotlight s) {
    final colorScheme = Theme.of(dialogContext).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(s.icon, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(s.description, style: const TextStyle(fontSize: 13)),
                if (s.routeBuilder != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        if (pageContext.mounted) {
                          Navigator.push(
                            pageContext,
                            MaterialPageRoute<void>(
                                builder: s.routeBuilder!),
                          );
                        }
                      },
                      child: const Text('去体验'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条主打功能引导
class _Spotlight {
  final IconData icon;
  final String title;
  final String description;

  /// 可选：「去体验」按钮跳转的页面构造器
  final Widget Function(BuildContext)? routeBuilder;

  const _Spotlight({
    required this.icon,
    required this.title,
    required this.description,
    this.routeBuilder,
  });
}

/// 本版本主打功能引导（0..N 条，每版本发布前更新；无主打功能时置空列表）
const List<_Spotlight> _spotlights = [
  _Spotlight(
    icon: Icons.feedback_outlined,
    title: '应用内问题反馈',
    description: '无需 GitHub 账号即可反馈 bug，可附带日志自动脱敏提交。入口：关于页 → 问题反馈',
    routeBuilder: _feedbackRoute,
  ),
  _Spotlight(
    icon: Icons.grid_view_outlined,
    title: '收藏夹缩略图网格视图',
    description: '收藏夹详情页点右上角图标，在曲目列表与封面网格间切换，选择全局记忆',
  ),
];

Widget _feedbackRoute(BuildContext _) => const FeedbackScreen();
