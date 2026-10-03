import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 采集指定时间窗内的帧耗时（Framework/GPU Workload + Flutter.Frame 事件），
/// 输出统计摘要。用于主页性能 A/B 对比。
///
/// Usage: dart vm_timeline.dart <ws-uri> <window-ms> [label]
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final windowMs = int.parse(args[1]);
  final label = args.length > 2 ? args[2] : 'run';
  var nextId = 1;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final frameEvents = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> rpc(String m, Map<String, dynamic> p) {
    final rid = nextId++;
    final c = Completer<Map<String, dynamic>>();
    pending[rid] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': rid, 'method': m, 'params': p}));
    return c.future.timeout(const Duration(seconds: 60));
  }

  ws.listen((msg) {
    final data = jsonDecode(msg as String) as Map<String, dynamic>;
    if (data['method'] == 'streamNotify') {
      final p = (data['params'] as Map).cast<String, dynamic>();
      if (p['streamId'] == 'Extension') {
        final e = (p['event'] as Map).cast<String, dynamic>();
        if (e['extensionKind'] == 'Flutter.Frame') {
          frameEvents.add((e['extensionData'] as Map).cast<String, dynamic>()
            ..['_ts'] = DateTime.now().microsecondsSinceEpoch);
        }
      }
      return;
    }
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

  await rpc('setVMTimelineFlags', {
    'recordedStreams': ['GC', 'Dart', 'Embedder'],
  });
  await rpc('clearVMTimeline', {});
  await rpc('streamListen', {'streamId': 'Extension'});

  // streamListen 会立即回放最近的帧事件缓存，先排空再开始计时
  await Future.delayed(const Duration(milliseconds: 1500));
  frameEvents.clear();

  stdout.writeln('[$label] collecting ${windowMs}ms ...');
  await Future.delayed(Duration(milliseconds: windowMs));

  await rpc('streamCancel', {'streamId': 'Extension'});
  final tl = await rpc('getVMTimeline', {});
  await ws.close();

  final events = ((tl['traceEvents'] as List?) ?? []).cast<Map<String, dynamic>>();
  final framework = _durations(events, 'Framework Workload');
  final gpu = _durations(events, 'GPU Workload');
  final builds =
      frameEvents.map((f) => (f['build'] as num?)?.toDouble() ?? 0).toList();
  final rasters =
      frameEvents.map((f) => (f['raster'] as num?)?.toDouble() ?? 0).toList();

  stdout.writeln('=== $label ===');
  if (frameEvents.isNotEmpty) {
    final t0 = (frameEvents.first['_ts'] as num).toDouble();
    final buckets = <int, int>{};
    for (final f in frameEvents) {
      final sec = (((f['_ts'] as num).toDouble() - t0) / 1e6).floor();
      buckets[sec] = (buckets[sec] ?? 0) + 1;
    }
    final sorted = buckets.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    stdout.writeln('frames/sec: ${sorted.map((e) => '${e.key}s:${e.value}').join(' ')}');
  }
  _report('Flutter.Frame build', builds);
  _report('Flutter.Frame raster', rasters);
  _report('Framework Workload', framework);
  _report('GPU Workload', gpu);
}

List<double> _durations(List<Map<String, dynamic>> events, String name) {
  return events
      .where((e) => e['name'] == name && e['ph'] == 'X')
      .map((e) => (e['dur'] as num?)?.toDouble() ?? 0)
      .toList();
}

void _report(String name, List<double> us) {
  if (us.isEmpty) {
    stdout.writeln('$name: (no events)');
    return;
  }
  us.sort();
  final avg = us.reduce((a, b) => a + b) / us.length;
  double pct(double p) => us[(us.length * p).floor().clamp(0, us.length - 1)];
  final janky = us.where((v) => v > 16667).length;
  stdout.writeln(
    '$name: n=${us.length} avg=${(avg / 1000).toStringAsFixed(2)}ms '
    'p50=${(pct(0.50) / 1000).toStringAsFixed(2)}ms '
    'p95=${(pct(0.95) / 1000).toStringAsFixed(2)}ms '
    'max=${(us.last / 1000).toStringAsFixed(2)}ms '
    '>16.7ms: ${(janky * 100 / us.length).toStringAsFixed(1)}%',
  );
}
