/// 主页顶栏布局（纯 Dart，便于离线测试）：每个入口要么显示在顶栏
/// （图标），要么收进「更多」；顺序可调。
enum HomeToolbarItem { search, recognition, dynamic, history, settings }

typedef HomeToolbarEntry = ({HomeToolbarItem item, bool pinned});

/// 默认顶栏从左到右：动态、搜索、「更多」（#25：搜索原先藏在菜单里，
/// 要点两下、新用户找不到）；听歌识曲、历史、设置收进「更多」
const List<HomeToolbarEntry> kDefaultHomeToolbar = [
  (item: HomeToolbarItem.dynamic, pinned: true),
  (item: HomeToolbarItem.search, pinned: true),
  (item: HomeToolbarItem.recognition, pinned: false),
  (item: HomeToolbarItem.history, pinned: false),
  (item: HomeToolbarItem.settings, pinned: false),
];

/// 序列化为 `dynamic:1,search:1,recognition:0,...`
String encodeHomeToolbar(List<HomeToolbarEntry> entries) =>
    entries.map((e) => '${e.item.name}:${e.pinned ? 1 : 0}').join(',');

/// 容错解析：未知/重复入口丢弃，缺少或非法的开关值取该入口默认值；
/// 缺失的入口（如新版本新增）按默认追加到末尾，保证每个入口恰好
/// 出现一次——设置等入口永远可达（不在顶栏就在「更多」里）
List<HomeToolbarEntry> parseHomeToolbar(String? raw) {
  if (raw == null || raw.trim().isEmpty) return List.of(kDefaultHomeToolbar);
  final entries = <HomeToolbarEntry>[];
  final seen = <HomeToolbarItem>{};
  for (final part in raw.split(',')) {
    final kv = part.split(':');
    final item = HomeToolbarItem.values.asNameMap()[kv.first.trim()];
    if (item == null || !seen.add(item)) continue;
    final flag = kv.length > 1 ? kv[1].trim() : '';
    final pinned = switch (flag) {
      '1' => true,
      '0' => false,
      _ => kDefaultHomeToolbar.firstWhere((d) => d.item == item).pinned,
    };
    entries.add((item: item, pinned: pinned));
  }
  for (final d in kDefaultHomeToolbar) {
    if (!seen.contains(d.item)) entries.add(d);
  }
  return entries;
}
