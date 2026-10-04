/// changelog.md 解析（纯 Dart，便于单元测试）：
/// 按 `# ` 分节，返回 (版本号, 条目文本) 列表，保持文件顺序（最新在前）。
List<(String, String)> parseChangelog(String markdown) {
  return markdown
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
}

/// changelog 条目的分组 key
const String kChangelogGroupFeat = 'feat';
const String kChangelogGroupFix = 'fix';
const String kChangelogGroupImprove = 'improve';
const String kChangelogGroupOther = 'other';

/// 分组展示顺序与中文名
const List<(String, String)> kChangelogGroups = [
  (kChangelogGroupFeat, '新功能'),
  (kChangelogGroupFix, '问题修复'),
  (kChangelogGroupImprove, '优化改进'),
  (kChangelogGroupOther, '其他'),
];

/// 把一个版本的条目文本按前缀分组（feat/fix 独立成组，
/// perf/refactor 归为优化改进，其余归为其他）。
/// 返回 (分组 key, 条目列表) 的有序列表，空组不返回；
/// 条目前的 `- feat ` 等前缀会被剥掉。
List<(String, List<String>)> groupChangelog(String body) {
  final groups = <String, List<String>>{
    for (final g in kChangelogGroups) g.$1: <String>[],
  };
  for (final raw in body.split('\n')) {
    var text = raw.trim();
    if (text.isEmpty) continue;
    if (text.startsWith('- ')) text = text.substring(2);
    final firstSpace = text.indexOf(' ');
    final prefix =
        (firstSpace > 0 ? text.substring(0, firstSpace) : '').toLowerCase();
    final key = switch (prefix) {
      kChangelogGroupFeat => kChangelogGroupFeat,
      kChangelogGroupFix => kChangelogGroupFix,
      'perf' || 'refactor' => kChangelogGroupImprove,
      _ => kChangelogGroupOther,
    };
    groups[key]!
        .add(prefix.isEmpty ? text : text.substring(prefix.length).trim());
  }
  return [
    for (final g in kChangelogGroups)
      if (groups[g.$1]!.isNotEmpty) (g.$1, groups[g.$1]!),
  ];
}
