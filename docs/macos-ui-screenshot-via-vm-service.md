# macOS 下命令行截取 Flutter 应用界面（VM Service 方案）

> 实践环境：Flutter 3.47.2 stable / Dart 3.13.2，macOS (Apple M5 Pro)，项目 bmsc
> 场景：在终端中运行 `flutter run -d macos --debug` 后，希望从命令行自动截图查看 UI 效果

## 1. 背景：为什么常规截图方式不可行

| 方式 | 结果 |
|---|---|
| `screencapture -x out.png` | 报错 `could not create image from display`，进程没有 macOS「屏幕录制」权限 |
| `flutter screenshot -d macos`（默认 `--type=device`） | 委托系统原生截图，同样受屏幕录制权限限制 |
| `flutter screenshot --type=skia` | 只能输出 `.skp` Skia 文件，无法直接查看 |
| `flutter run` 交互键 | 3.47.2 版本只有 `r/R/h/d/c/q`，没有截图命令 |

**可行方案**：debug 模式下 Flutter inspector 注册了 `ext.flutter.inspector.screenshot` 服务扩展，
它直接读取渲染树并输出 PNG，完全不依赖系统截图权限。

## 2. 原理

1. `flutter run` 启动时会打印 Dart VM Service 地址：
   ```
   A Dart VM Service on macOS is available at: http://127.0.0.1:53549/OWM-nPeQCJM=/
   ```
2. WebSocket 地址 = 该地址拼上 `ws`：`ws://127.0.0.1:53549/OWM-nPeQCJM=/ws`
3. 通过 WebSocket 发送 JSON-RPC 2.0 请求，调用 inspector 扩展：
   - `ext.flutter.inspector.getRootWidget` → 拿到根元素的 objectId（返回 JSON 里的 `valueId`）
   - `ext.flutter.inspector.screenshot` → 传入 objectId，返回 base64 PNG

## 3. 完整步骤

### 3.1 启动应用并获取 VM Service 地址

```bash
flutter run -d macos --debug 2>&1 | tee run.log
# 从日志中提取地址（注意 = 号结尾的 token 不能丢）
grep -o 'http://127.0.0.1:[0-9]*/[A-Za-z0-9_=-]*/' run.log | tail -1
```

### 3.2 用 Dart 脚本通过 WebSocket 调用 RPC

> 无需任何第三方包，用 `dart:io` 的 `WebSocket` 即可。
> 注意用 Flutter 自带的 dart：`/path/to/flutter/bin/dart`

核心 RPC 调用格式：

```dart
ws.add(jsonEncode({
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'ext.flutter.inspector.screenshot',
  'params': {
    'isolateId': isolateId,   // 建议带上
    'id': 'inspector-168',    // 目标 objectId
    'width': '1600',          // 字符串！服务扩展参数是 Map<String, String>
    'height': '3200',
    'maxPixelRatio': '2',
  },
}));
// 返回：{"result": {"result": "<base64 PNG>"}}
```

### 3.3 获取 objectId

```
方法：ext.flutter.inspector.getRootWidget
参数：{"objectGroup": "shot", "isolateId": "<isolateId>"}
返回：根节点 JSON，取其中的 "valueId" 字段（形如 "inspector-168"）
```

isolateId 可通过 `getVM` 获得（`isolates[0].id`）。

### 3.4 保存截图

对返回的 base64 解码写入 `.png` 文件即可。

输出像素比 = `min(maxPixelRatio, width/渲染宽度, height/渲染高度)`，
想要高清图就把 `width`/`height` 都设得比逻辑尺寸大。

## 4. 关键坑与经验

### 4.1 窗口被遮挡/未激活时，引擎暂停出帧 → 截到旧画面 ★最大的坑

- **症状**：滚动页面后截图，图片字节与上一张完全相同（SHA1 一致），
  且 `rootElement.renderObject.debugNeedsPaint == true`
- **原因**：当截图目标是 repaint boundary（根 RenderView、RenderViewport 都是）时，
  inspector 直接复用「最近一次渲染」的缓存图层，而不是重新绘制；
  窗口不可见时引擎不产帧，缓存图层就是旧的
- **解决**：先把应用窗口带到前台，等新帧渲染完成再截图：

  ```bash
  open -a /path/to/build/macos/Build/Products/Debug/bmsc.app
  # 用 evaluate 确认 rootNeedsPaint == false 后再截图
  ```

- **验证表达式**：
  ```dart
  (() { final ro = WidgetsBinding.instance.rootElement!.renderObject!;
     return "rootNeedsPaint=" + ro.debugNeedsPaint.toString(); })()
  ```

### 4.2 对非 repaint boundary 的子元素截图会按需重绘

若目标元素不是 repaint boundary（例如 ListView 的某个子元素），
inspector 会调用 `debugInstrumentRepaintCompositedChild` 强制重绘子树，
并且会先 flushLayout，因此**布局变化**（如 `jumpTo` 之后）能被捕获，
但**纯 paint 变化**（滚动偏移）若没有产生新帧，仍可能拿到缓存图层。

### 4.3 懒加载列表：跳到底部要跳两次

`ListView` 的 `maxScrollExtent` 在未构建完尾部元素时是估算值。
第一次 `jumpTo(maxScrollExtent)` 后，列表继续构建新项、`max` 变大，
需要**再跳一次**才是真正的底部。

### 4.4 用 evaluate 驱动 UI（滚动等）

```
方法：evaluate
参数：{"isolateId": "...", "targetId": "<libraryId>", "expression": "<expr>"}
```

- libraryId 从 `getIsolate` 返回的 `libraries` 列表中按 URI 匹配
  （如 `package:bmsc/screen/fav_screen.dart`）
- 表达式在该库上下文中执行，可直接使用该库 import 的符号
- 遍历元素树找到 Scrollable 并跳转的示例：

  ```dart
  (() {
    void walk(Element e) {
      final s = e is StatefulElement ? e.state : null;
      if (s is ScrollableState &&
          s.axisDirection == AxisDirection.down &&
          s.position.maxScrollExtent > 500) {
        s.position.jumpTo(s.position.maxScrollExtent);
      }
      e.visitChildren(walk);
    }
    walk(WidgetsBinding.instance.rootElement!);
    return "jumped";
  })()
  ```

- 也可以用 `WidgetInspectorService.instance.toId(element, "group")`
  给任意元素注册 objectId，再对该元素截图

### 4.5 其他细节

- `getIsolate` 的返回 JSON 极大（含全部库信息），脚本里只提取
  `extensionRPCs` 等需要的字段，不要整体打印
- 用 `getIsolate.extensionRPCs` 可以发现所有可用扩展
  （本环境只有 `ext.flutter.inspector.screenshot`，
  引擎层的 `_flutter.screenshot` 并不存在）
- shell 引号：外层用单引号包住 Dart 表达式，表达式内部字符串用双引号
- `screenshot` 扩展还支持 `margin`、`debugPaint` 参数，
  后者会叠加 debugPaint 信息（布局边框等），调试布局时有用

## 5. 可复用脚本

本次实践写好的 4 个脚本（可放到任意目录）：

| 脚本 | 用途 |
|---|---|
| `vm_exts.dart` | 列出应用注册的所有服务扩展 |
| `vm_rpc.dart` | 通用 RPC 调用（打印结果 JSON） |
| `vm_shot2.dart` | 按 objectId 截图并保存 PNG |
| `vm_eval.dart` | 在指定库上下文中执行 Dart 表达式 |

### vm_shot2.dart（核心脚本）

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Usage: dart vm_shot2.dart <ws-uri> <object-id> <out.png> [w] [h] [ratio]
Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  final out = args[2];
  final width = args.length > 3 ? args[3] : '1600';
  final height = args.length > 4 ? args[4] : '1400';
  final ratio = args.length > 5 ? args[5] : '2';
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
  final result = await rpc('ext.flutter.inspector.screenshot', {
    'isolateId': isolateId,
    'id': args[1],
    'width': width,
    'height': height,
    'maxPixelRatio': ratio,
  });
  final b64 = result['result'] as String?;
  if (b64 == null || b64.isEmpty) {
    stderr.writeln('no image: ${jsonEncode(result)}');
    await ws.close();
    exit(2);
  }
  final bytes = base64Decode(b64);
  await File(out).writeAsBytes(bytes);
  stdout.writeln('saved $out (${bytes.length} bytes)');
  await ws.close();
}
```

### 使用示例

```bash
WS="ws://127.0.0.1:53549/OWM-nPeQCJM=/ws"
DART=/Users/u2x1/flutter/bin/dart

# 1. 列出可用扩展
$DART vm_exts.dart "$WS" inspector

# 2. 获取根元素 objectId
$DART vm_rpc.dart "$WS" ext.flutter.inspector.getRootWidget \
  '{"objectGroup":"shot"}' | grep valueId

# 3. 截图（假设 id 为 inspector-168）
$DART vm_shot2.dart "$WS" inspector-168 shot.png 1600 3200 2

# 4. 驱动滚动（在 fav_screen 库上下文执行表达式）
$DART vm_eval.dart "$WS" fav_screen '<expression>'
```

## 6. 性能采集（帧耗时 timeline + 合成滚动）

在截图方案基础上还有两个 profiling 工具（tools/screenshot/）：

### vm_timeline.dart（帧耗时统计）

```bash
dart vm_timeline.dart <ws-uri> <window-ms> [label]
```

- 订阅 VM Service 的 `Extension` 事件流，统计窗口内的 `Flutter.Frame`
  事件（profile/debug 模式均可用；**profile 模式无 evaluate/inspector，
  但帧耗时事件照常有**）
- 输出 build/raster 的 n/avg/p50/p95/max 及 >16.7ms 占比，
  并打印每秒帧数分布
- 注意 `streamListen` 会**立即回放最近的帧事件缓存**，脚本已内置
  1.5s 排空，勿把回放数据当实时数据
- 窗口被遮挡/未激活时引擎**完全不出帧**（0 事件），先 `open -a` 激活，
  可用 `osascript -e 'tell application "System Events" to tell process
  "<name>" to get frontmost'` 确认

### scroll.swift（合成滚轮事件，驱动滚动）

```bash
swiftc -O scroll.swift -o scroll_bin
./scroll_bin <x> <y> <dyPxPerEvent> <count> <intervalMs>   # dy<0 向下
```

- 基于 CGEventPost 合成滚轮事件，需要**辅助功能权限**
  （profile 模式无 evaluate，无法代码驱动滚动，只能合成输入事件）
- 窗口几何可用 osascript 读取/设置：
  `tell application "System Events" to tell process "<name>" to
   get {position, size} of window 1`
- 滚动速度过快会快速触顶/触底后停止出帧，建议交替上下滚动保持持续运动

### click.swift（合成鼠标点击，驱动导航）

```bash
swiftc -O click.swift -o click_bin
./click_bin <x> <y>   # 屏幕坐标
```

- 点击目标控件坐标可用 debug 模式的 evaluate 动态获取
  （`renderObject.localToGlobal(...)` 返回**窗口内**坐标，
  屏幕坐标 = 窗口 position + 窗口内坐标 + 标题栏高度 28）

### 测量注意事项

- 同包名多实例（Debug/Profile 并存）会干扰 `open -a` 激活与 AX 查询，
  先 `pkill` 多余实例
- debug 模式数值普遍放大 5~20 倍，绝对值以 profile 为准，
  相对对比用 debug 也可
- 滚动本身不触发 build（仅 layout/paint）；build 耗时反映的是
  StreamBuilder/setState 驱动的重建

## 7. 备选方案

| 方案 | 说明 |
|---|---|
| 授予终端「屏幕录制」权限 | 之后 `screencapture` / `flutter screenshot -d macos` 可直接用 |
| `flutter drive` + `integration_test` | 官方 CI 截图方案（`takeScreenshot`），需添加测试依赖和 driver 文件 |
| DevTools | 浏览器打开 flutter run 输出的 DevTools 地址，用界面上的截图按钮 |
| `screencapture -l<windowId>` | 按窗口截图，同样需要屏幕录制权限 |

## 附录：其余脚本

### vm_exts.dart（列出服务扩展）

```dart
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
```

### vm_rpc.dart（通用 RPC 调用）

```dart
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
```

### vm_eval.dart（在指定库上下文执行表达式）

```dart
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
```
