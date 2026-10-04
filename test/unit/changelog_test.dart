import 'package:bmsc/util/changelog.dart';
import 'package:test/test.dart';

/// changelog.md 解析测试（离线、确定性）
void main() {
  group('parseChangelog', () {
    test('按版本分节，保持文件顺序（最新在前）', () {
      const md = '# 1.2.0\n- feat a\n- fix b\n\n# 1.1.0\n- feat c\n';
      final entries = parseChangelog(md);
      expect(entries.length, 2);
      expect(entries[0].$1, '1.2.0');
      expect(entries[1].$1, '1.1.0');
    });

    test('条目多行合并、空行剔除', () {
      const md = '# 1.2.0\n- feat a\n\n\n  - fix b  \n';
      final entries = parseChangelog(md);
      expect(entries.single.$2, '- feat a\n- fix b');
    });

    test('空输入返回空列表', () {
      expect(parseChangelog(''), isEmpty);
      expect(parseChangelog('\n\n  \n'), isEmpty);
    });
  });

  group('groupChangelog（条目分组）', () {
    test('feat/fix/perf/refactor/其他正确归类，前缀剥除', () {
      const body = '- feat 新功能A\n- feat 新功能B\n- fix 修复C\n- perf 优化D\n'
          '- refactor 重构E\n- chore 杂项F\n- 无前缀G';
      final groups = groupChangelog(body);
      expect(groups.map((g) => g.$1).toList(),
          ['feat', 'fix', 'improve', 'other']);
      expect(groups[0].$2, ['新功能A', '新功能B']);
      expect(groups[1].$2, ['修复C']);
      expect(groups[2].$2, ['优化D', '重构E']);
      expect(groups[3].$2, ['杂项F', '无前缀G']);
    });

    test('空组不返回；组内保持原始顺序', () {
      final groups = groupChangelog('- fix 修复B\n- fix 修复A');
      expect(groups.length, 1);
      expect(groups.single.$1, 'fix');
      expect(groups.single.$2, ['修复B', '修复A']);
    });

    test('空输入返回空列表', () {
      expect(groupChangelog(''), isEmpty);
      expect(groupChangelog('\n \n'), isEmpty);
    });
  });
}
