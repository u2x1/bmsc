import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_rpc.dart <ws-uri> <method> [params-json]
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final method = args[1];
  final params = args.length > 2
      ? (jsonDecode(args[2]) as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final id = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 30));
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

  final result = await rpc(method, params);
  const encoder = JsonEncoder.withIndent('  ');
  final text = encoder.convert(result);
  stdout.writeln(text.length > 20000 ? '${text.substring(0, 20000)}\n...[truncated]' : text);
  await ws.close();
}
