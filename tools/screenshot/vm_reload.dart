import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 对运行中的 isolate 执行热重载（reloadSources + ext.flutter.reassemble）。
/// 后台 flutter run 无法接收 stdin 按键时使用。
///
/// Usage: dart vm_reload.dart <ws-uri>
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final rid = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[rid] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': rid, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 120));
  }

  ws.listen((msg) {
    final data = jsonDecode(msg as String) as Map<String, dynamic>;
    final rid = data['id'] as int?;
    if (rid != null && pending.containsKey(rid)) {
      final c = pending.remove(rid)!;
      if (data['error'] != null) {
        c.completeError(Exception('RPC error: ${jsonEncode(data['error'])}'));
      } else {
        c.complete((data['result'] as Map?)?.cast<String, dynamic>() ?? {});
      }
    }
  });

  final vm = await rpc('getVM', {});
  final isolateId = ((vm['isolates'] as List).first as Map)['id'] as String;

  final reload = await rpc('reloadSources', {
    'isolateId': isolateId,
    'pause': false,
    'rootLibUri': '',
  });
  final report = reload['report'] as Map?;
  stdout.writeln('reloadSources: success=${report?['success']}');

  final reassemble = await rpc('ext.flutter.reassemble', {
    'isolateId': isolateId,
  });
  stdout.writeln('reassemble: ${reassemble['type']}');
  await ws.close();
}
