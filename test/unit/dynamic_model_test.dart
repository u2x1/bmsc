import 'dart:convert';
import 'dart:io';

import 'package:bmsc/model/dynamic.dart';
import 'package:test/test.dart';

/// 动态协议解析回归测试。
///
/// fixture 来自真实接口响应（test/fixtures/dynamics_sample.json），
/// 覆盖 B 站数值字段「时 int 时 String」的类型漂移。
void main() {
  Map<String, dynamic> loadFixture() => jsonDecode(
        File('test/fixtures/dynamics_sample.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  group('DynamicResult.fromJson（真实 fixture）', () {
    test('整体解析成功且不丢数据', () {
      final result = DynamicResult.fromJson(loadFixture());
      expect(result.items, isNotEmpty);
      expect(result.items.length, greaterThanOrEqualTo(3));
      expect(result.offset, isNotEmpty);
      expect(result.updateBaseline, isNotEmpty);
      expect(result.hasMore, isTrue);
    });

    test('数值字段为 String 时不抛异常（回归：update_num/offset 硬转崩溃）', () {
      final json = loadFixture();
      json['offset'] = 1241796171955961863; // int 形态
      json['update_num'] = '3'; // String 形态
      json['update_baseline'] = 1241973747364134912; // int 形态
      final result = DynamicResult.fromJson(json);
      expect(result.updateNum, 3);
      expect(result.offset, '1241796171955961863');
      expect(result.updateBaseline, '1241973747364134912');
    });

    test('所有条目均可解析出有效的 archive 信息', () {
      final result = DynamicResult.fromJson(loadFixture());
      for (final item in result.items) {
        expect(item.modules.moduleAuthor.name, isNotEmpty);
        expect(item.modules.moduleDynamic.major.archive, isNotNull);
        expect(item.modules.moduleDynamic.major.archive!.bvid,
            startsWith('BV'));
      }
    });
  });

  group('DynamicResult.fromJson（健壮性）', () {
    test('单条坏 item 被跳过，整体不抛（回归：动态页白屏）', () {
      final json = loadFixture();
      final items = (json['items'] as List).toList();
      items.add({'type': 'DYNAMIC_TYPE_UNKNOWN', 'id_str': 'x'});
      items.insert(0, {'not': 'a valid item'});
      json['items'] = items;
      final result = DynamicResult.fromJson(json);
      expect(result.items, isNotEmpty);
    });

    test('空 items 不抛', () {
      final json = loadFixture();
      json['items'] = <Object>[];
      final result = DynamicResult.fromJson(json);
      expect(result.items, isEmpty);
      expect(result.hasMore, isTrue);
    });

    test('字段缺失不抛（null 安全）', () {
      final result =
          DynamicResult.fromJson({'items': null, 'has_more': null});
      expect(result.items, isEmpty);
      expect(result.offset, '');
      expect(result.updateNum, 0);
    });
  });
}