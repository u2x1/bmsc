import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_exts.dart <ws-uri> [filter]
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final filter = args.length > 1 ? args[1].toLowerCase() : '';
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

  final vm = await rpc('getVM', {});
  for (final iso in (vm['isolates'] as List).cast<Map>()) {
    final info = await rpc('getIsolate', {'isolateId': iso['id']});
    final exts = ((info['extensionRPCs'] as List?) ?? []).cast<String>();
    for (final e in exts.where((e) => e.toLowerCase().contains(filter))) {
      stdout.writeln(e);
    }
  }
  await ws.close();
}
