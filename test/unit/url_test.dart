import 'package:bmsc/util/url.dart';
import 'package:test/test.dart';

void main() {
  const issueUrl =
      'https://space.bilibili.com/327901592/lists/1519400?type=season';

  group('SeasonLink', () {
    test('解析 issue 示例', () {
      final link = parseSeasonLink(issueUrl);

      expect(link, isNotNull);
      expect(link!.mid, 327901592);
      expect(link.seasonId, 1519400);
      expect(extractBiliUrl(issueUrl), issueUrl);
    });

    test('从分享文案中提取并允许额外 query', () async {
      const url = 'https://space.bilibili.com/327901592/lists/1519400'
          '?type=season&spm_id_from=333.1387.0.0';
      const text = '【音乐合集】快来听听吧 $url 分享自哔哩哔哩';

      final link = parseSeasonLink(text);
      expect(link, isNotNull);
      expect(link!.mid, 327901592);
      expect(link.seasonId, 1519400);
      expect(extractBiliUrl(text), url);
      expect((await getSeasonLinkFromUrl(text))!.seasonId, 1519400);

      expect(
          parseSeasonLink('https://space.bilibili.com/327901592/lists/1519400'
              '?from=share&type=season'),
          isNotNull);
    });

    test('拒绝错误 scheme、host、port 和 path', () {
      const invalidUrls = [
        'http://space.bilibili.com/327901592/lists/1519400?type=season',
        'https://www.bilibili.com/327901592/lists/1519400?type=season',
        'https://space.bilibili.com.evil.test/327901592/lists/1519400?type=season',
        'https://space.bilibili.com:443/327901592/lists/1519400?type=season',
        'https://space.bilibili.com/327901592/list/1519400?type=season',
        'https://space.bilibili.com/327901592/lists/1519400/?type=season',
        'https://space.bilibili.com/327901592/lists/1519400/extra?type=season',
      ];

      for (final url in invalidUrls) {
        expect(parseSeasonLink(url), isNull, reason: url);
      }
    });

    test('拒绝缺失、错误或重复的 type', () {
      const invalidUrls = [
        'https://space.bilibili.com/327901592/lists/1519400',
        'https://space.bilibili.com/327901592/lists/1519400?from=share',
        'https://space.bilibili.com/327901592/lists/1519400?type=video',
        'https://space.bilibili.com/327901592/lists/1519400?type=season&type=video',
      ];

      for (final url in invalidUrls) {
        expect(parseSeasonLink(url), isNull, reason: url);
      }
    });

    test('拒绝非正整数 mid 和 seasonId', () {
      const invalidUrls = [
        'https://space.bilibili.com/0/lists/1519400?type=season',
        'https://space.bilibili.com/327901592/lists/0?type=season',
        'https://space.bilibili.com/-327901592/lists/1519400?type=season',
        'https://space.bilibili.com/327901592/lists/-1519400?type=season',
        'https://space.bilibili.com/mid/lists/1519400?type=season',
        'https://space.bilibili.com/327901592/lists/season?type=season',
      ];

      for (final url in invalidUrls) {
        expect(parseSeasonLink(url), isNull, reason: url);
      }
    });

    test('season 与 BV 同现时优先 season', () {
      const text = 'BV1GJ411x7h7 $issueUrl';

      expect(parseSeasonLink(text)!.seasonId, 1519400);
      expect(extractBiliUrl(text), issueUrl);
    });
  });

  group('原链接提取', () {
    test('BV、AV 和 b23 短链不回归', () {
      expect(extractBiliUrl('视频 BV1GJ411x7h7 分享'), 'BV1GJ411x7h7');
      expect(extractBiliUrl('视频 av170001 分享'), 'av170001');
      expect(extractBiliUrl('视频 https://b23.tv/abc123 分享'),
          'https://b23.tv/abc123');
      expect(extractBiliUrl('普通搜索关键词'), isNull);
    });

    test('非法 season 不影响原有 BV 识别', () {
      const text = 'https://space.bilibili.com/327901592/lists/1519400'
          '?type=video BV1GJ411x7h7';

      expect(parseSeasonLink(text), isNull);
      expect(extractBiliUrl(text), 'BV1GJ411x7h7');
    });
  });
}
