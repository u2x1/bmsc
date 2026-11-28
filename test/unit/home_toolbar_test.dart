import 'package:bmsc/util/home_toolbar.dart';
import 'package:test/test.dart';

/// 主页顶栏布局解析（#25 及顶栏自定义）
void main() {
  List<String> names(List<HomeToolbarEntry> e) =>
      e.map((x) => '${x.item.name}:${x.pinned ? 1 : 0}').toList();

  test('未设置时为默认布局：顶栏从左到右动态、搜索，其余在「更多」', () {
    expect(parseHomeToolbar(null), kDefaultHomeToolbar);
    expect(parseHomeToolbar(''), kDefaultHomeToolbar);
    expect(names(kDefaultHomeToolbar), [
      'dynamic:1',
      'search:1',
      'recognition:0',
      'history:0',
      'settings:0',
    ]);
  });

  test('编码后解析往返一致，保留顺序', () {
    final layout = [
      (item: HomeToolbarItem.history, pinned: true),
      (item: HomeToolbarItem.search, pinned: false),
      (item: HomeToolbarItem.settings, pinned: true),
      (item: HomeToolbarItem.dynamic, pinned: false),
      (item: HomeToolbarItem.recognition, pinned: false),
    ];
    expect(parseHomeToolbar(encodeHomeToolbar(layout)), layout);
  });

  test('未知/重复入口丢弃，缺失入口按默认追加，每个入口恰好一次', () {
    final parsed = parseHomeToolbar('bogus:1,settings:1,settings:0');
    expect(names(parsed), [
      'settings:1',
      'dynamic:1',
      'search:1',
      'recognition:0',
      'history:0',
    ]);
  });

  test('缺少或非法的开关值取该入口默认值', () {
    final parsed = parseHomeToolbar('search:x,history,dynamic:0');
    expect(names(parsed).take(3), ['search:1', 'history:0', 'dynamic:0']);
  });
}
