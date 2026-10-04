import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_tree_search.dart `<ws-uri>` `<substring>` [...]
/// 调用 Flutter Inspector 扩展获取 widget 树，检查给定文本是否出现。
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final needles = args.sublist(1);
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
  Map<String, dynamic> tree;
  try {
    tree = await rpc('ext.flutter.inspector.getRootWidgetSummaryTree', {
      'objectGroup': 'vm_tree_search',
      'isolateId': isolateId,
    });
  } catch (_) {
    tree = await rpc('ext.flutter.inspector.getRootWidget', {
      'objectGroup': 'vm_tree_search',
      'isolateId': isolateId,
    });
  }
  final treeJson = jsonEncode(tree);
  for (final needle in needles) {
    final count = needle.allMatches(treeJson).length;
    stdout.writeln('$needle => ${count > 0 ? "FOUND($count)" : "NOT FOUND"}');
  }
  await ws.close();
}
