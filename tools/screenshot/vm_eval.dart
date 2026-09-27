import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_eval.dart <ws-uri> <library-uri-substring> <expression>
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final libUri = args[1];
  final expr = args[2];
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final id = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 60));
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
  final info = await rpc('getIsolate', {'isolateId': isolateId});
  final libs = ((info['libraries'] as List?) ?? []).cast<Map>();
  final lib = libs.firstWhere(
    (l) => (l['uri'] as String).contains(libUri),
    orElse: () => throw Exception('library not found: $libUri'),
  );
  stdout.writeln('library: ${lib['uri']} (${lib['id']})');

  final res = await rpc('evaluate', {
    'isolateId': isolateId,
    'targetId': lib['id'],
    'expression': expr,
  });
  stdout.writeln(jsonEncode(res));
  await ws.close();
}
