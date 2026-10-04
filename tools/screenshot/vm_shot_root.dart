import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_shot_root.dart <ws-uri> <out.png> [w] [h] [ratio]
/// 自动取根元素 objectId 并截图（带 isolateId 调用 inspector 扩展）。
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final out = args[1];
  final width = args.length > 2 ? args[2] : '1600';
  final height = args.length > 3 ? args[3] : '1400';
  final ratio = args.length > 4 ? args[4] : '2';
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final rid = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[rid] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': rid, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 60));
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
  final root = await rpc('ext.flutter.inspector.getRootWidget',
      {'objectGroup': 'shot', 'isolateId': isolateId});
  // 服务扩展返回双层 result：data['result']['result'] 才是负载
  final payload = (root['result'] as Map?)?.cast<String, dynamic>() ?? root;
  final valueId = (payload['valueId'] ?? payload['id']) as String?;
  if (valueId == null) {
    stderr.writeln('no valueId in getRootWidget: ${jsonEncode(root)}');
    exit(2);
  }
  final result = await rpc('ext.flutter.inspector.screenshot', {
    'isolateId': isolateId,
    'id': valueId,
    'width': width,
    'height': height,
    'maxPixelRatio': ratio,
  });
  final b64 = result['result'] as String?;
  if (b64 == null || b64.isEmpty) {
    stderr.writeln('no image: ${jsonEncode(result)}');
    exit(2);
  }
  final bytes = base64Decode(b64);
  await File(out).writeAsBytes(bytes);
  stdout.writeln('saved $out (${bytes.length} bytes)');
  await ws.close();
}
