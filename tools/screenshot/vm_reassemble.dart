import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_reassemble.dart `<ws-uri>`
/// 调用 ext.flutter.reassemble 触发热重载（等价 flutter run 的 r 键）。
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final id = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 120));
  }

  ws.listen((msg) {
    final data = jsonDecode(msg as String) as Map<String, dynamic>;
    final id = data['id'] as int?;
    if (id != null && pending.containsKey(id)) {
      final c = pending.remove(id)!;
      if (data['error'] != null) {
        c.completeError(Exception('RPC error: ${jsonEncode(data['error'])}'));
      } else {
        c.complete((data['result'] as Map?)?.cast<String, dynamic>() ?? {});
      }
    }
  });

  final vm = await rpc('getVM', {});
  final isolateId = ((vm['isolates'] as List).first as Map)['id'] as String;
  final res = await rpc('ext.flutter.reassemble', {
    'isolateId': isolateId,
  });
  stdout.writeln(jsonEncode(res));
  await ws.close();
}
