import 'dart:async';
import 'dart:io';

import 'package:bmsc/service/connection_service.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionService.recheck', () {
    test('连续探活中任一次成功即恢复，成功后不再重试', () async {
      var calls = 0;
      final service = ConnectionService.forTest(lookup: (_) {
        calls++;
        if (calls == 1) {
          return Future.error(const SocketException('offline'));
        }
        return Future.value([InternetAddress('127.0.0.1')]);
      });
      service.hasConnection = false;

      expect(await service.recheck(), isTrue);
      expect(calls, 2);
      expect(service.hasConnection, isTrue);
    });

    test('所有探活均失败时保持离线', () async {
      var calls = 0;
      final service = ConnectionService.forTest(lookup: (_) {
        calls++;
        return Future.error(const SocketException('offline'));
      });
      service.hasConnection = false;

      expect(await service.recheck(), isFalse);
      expect(calls, 2);
      expect(service.hasConnection, isFalse);
    });

    test('并发探活不吞掉本次成功结果，也不覆盖更新的共享状态', () async {
      final first = Completer<List<InternetAddress>>();
      final second = Completer<List<InternetAddress>>();
      var calls = 0;
      final service = ConnectionService.forTest(lookup: (_) {
        calls++;
        return switch (calls) {
          1 => first.future,
          2 => second.future,
          _ => Future.error(const SocketException('offline')),
        };
      });
      service.hasConnection = false;

      // A 是 recheck 的第一次探活；B 模拟随后到达的 connectivity 事件。
      final recheck = service.recheck();
      final eventCheck = service.checkConnection();
      second.completeError(const SocketException('offline'));
      expect(await eventCheck, isFalse);
      expect(service.hasConnection, isFalse);

      // A 虽已成功，但序号较旧：自身返回值仍应为 true，且不得覆盖 B 的结论。
      first.complete([InternetAddress('127.0.0.1')]);
      expect(await recheck, isTrue);
      expect(calls, 2, reason: 'A 已成功，不应再发起第三次探活');
      expect(service.hasConnection, isFalse);
    });
  });
}
