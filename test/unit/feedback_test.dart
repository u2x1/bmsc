import 'package:bmsc/util/feedback.dart';
import 'package:test/test.dart';

/// 反馈通道纯函数测试（离线、确定性）：
/// 凭据脱敏、日志截断、payload 组装。
void main() {
  group('sanitize（凭据脱敏）', () {
    test('cookie 片段中的 bilibili 凭据被打码', () {
      const text = 'cookie: SESSDATA=abc123xyz; bili_jct=token999; '
          'DedeUserID=12345; other=keep';
      final result = FeedbackPayload.sanitize(text);
      expect(result, contains('SESSDATA=***'));
      expect(result, contains('bili_jct=***'));
      expect(result, contains('DedeUserID=***'));
      expect(result, contains('other=keep'));
      expect(result, isNot(contains('abc123xyz')));
      expect(result, isNot(contains('token999')));
    });

    test('JSON 风格与大小写不敏感', () {
      const text = '{"sessdata": "secret_value", "Access_Token":"tok_abc"}';
      final result = FeedbackPayload.sanitize(text);
      expect(result, isNot(contains('secret_value')));
      expect(result, isNot(contains('tok_abc')));
    });

    test('DedeUserID__ckMd5 与 DedeUserID 均打码', () {
      final result = FeedbackPayload.sanitize(
          'DedeUserID__ckMd5=md5val; DedeUserID=uid1;');
      expect(result, isNot(contains('md5val')));
      expect(result, isNot(contains('uid1')));
    });

    test('Bearer token 打码', () {
      final result =
          FeedbackPayload.sanitize('Authorization: Bearer abc.def.ghi-jkl');
      expect(result, contains('Bearer ***'));
      expect(result, isNot(contains('abc.def.ghi')));
    });

    test('普通日志文本不受影响', () {
      const text = '2025-01-01 [INFO] [main] playByBvid: BV1xx411c7mD';
      expect(FeedbackPayload.sanitize(text), text);
    });
  });

  group('tailLogs（日志截断）', () {
    test('未超限原样返回', () {
      const logs = 'line1\nline2';
      expect(FeedbackPayload.tailLogs(logs), logs);
    });

    test('超限保留尾部并带截断标记', () {
      final logs = 'HEAD${'x' * (FeedbackPayload.maxLogsLength + 100)}TAIL';
      final result = FeedbackPayload.tailLogs(logs);
      expect(result, startsWith('[...已截断'));
      expect(result, endsWith('TAIL'));
      expect(result, isNot(contains('HEAD')));
    });
  });

  group('buildPayload（payload 组装）', () {
    Map<String, dynamic> payload({
      String content = '播放卡顿',
      String contact = '',
      String logs = '',
    }) =>
        FeedbackPayload.build(
          content: content,
          contact: contact,
          logs: logs,
          version: '1.20.0',
          buildNumber: '1',
          platform: 'android',
          osVersion: 'Linux 5.4',
        );

    test('content 去空白，空 contact/logs 字段省略', () {
      final p = payload(content: '  播放卡顿  ');
      expect(p['content'], '播放卡顿');
      expect(p.containsKey('contact'), isFalse);
      expect(p.containsKey('logs'), isFalse);
    });

    test('非空 contact/logs 保留，logs 经过脱敏', () {
      final p = payload(contact: ' user@example.com ', logs: 'SESSDATA=leak');
      expect(p['contact'], 'user@example.com');
      expect(p['logs'], contains('SESSDATA=***'));
      expect(p['logs'], isNot(contains('leak')));
    });

    test('meta 字段齐全', () {
      final meta = payload()['meta'] as Map<String, dynamic>;
      expect(meta['version'], '1.20.0');
      expect(meta['buildNumber'], '1');
      expect(meta['platform'], 'android');
      expect(meta['osVersion'], 'Linux 5.4');
    });
  });
}
