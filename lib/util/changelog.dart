/// changelog.md 解析（纯 Dart，便于单元测试）：
/// 按行首 `# ` 一级标题分节，返回 (版本号, 条目文本) 列表，保持文件顺序
/// （最新在前）。只认行首标题：条目里的 issue 编号（如 `#22`）不能分节
/// ——旧实现按任意 `#` 切分，引用 issue 后更新历史整个错乱。
List<(String, String)> parseChangelog(String markdown) {
  final entries = <(String, String)>[];
  String? title;
  final body = <String>[];
  void flush() {
    if (title != null && title.isNotEmpty) {
      entries.add((title, body.join('\n')));
    }
    body.clear();
  }

  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('# ') || line == '#') {
      flush();
      title = line.substring(1).trim();
    } else if (line.isNotEmpty && title != null) {
      body.add(line);
    }
  }
  flush();
  return entries;
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
