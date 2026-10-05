import 'dart:io';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectionService {
  static final ConnectionService _singleton = ConnectionService._internal();
  ConnectionService._internal();

  static ConnectionService getInstance() => _singleton;

  bool hasConnection = true;

  StreamController<bool> connectionChangeController =
      StreamController.broadcast();

  final Connectivity _connectivity = Connectivity();

  void initialize() {
    try {
      _connectivity.onConnectivityChanged.listen(_connectionChange);
    } catch (e) {
      // 测试环境/无插件时忽略，直接依赖 DNS 探活
    }
    checkConnection();
  }

  Stream<bool> get connectionChange => connectionChangeController.stream;

  /// 连续 [attempts] 次探活任一通即视为在线。
  /// 手机 DNS 偶发单次失败（2026-10-05 实测 Redmi/MIUI：两次探活间隔数秒
  /// 一败一成），单次探活就判定离线会把网络抖动放大成用户可见故障。
  Future<bool> recheck({int attempts = 2}) async {
    for (var i = 0; i < attempts; i++) {
      if (await checkConnection()) return true;
    }
    return false;
  }

  void _connectionChange(List<ConnectivityResult> result) {
    checkConnection();
  }

  int _checkSeq = 0;

  Future<bool> checkConnection() async {
    // 并发探活竞态防护：connectivity 事件连发或 API 调用复测可能与事件探活
    // 重叠，慢速旧探活不可覆盖新结论（与 noNetwork 假阴性同属陈旧状态问题）
    final seq = ++_checkSeq;
    bool previousConnection = hasConnection;

    bool result;
    try {
      final lookup = await InternetAddress.lookup('bilibili.com')
          .timeout(const Duration(seconds: 5));
      result = lookup.isNotEmpty && lookup[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      result = false;
    } on TimeoutException catch (_) {
      result = false;
    }
    if (seq != _checkSeq) return hasConnection; // 已有更新的探活结论

    hasConnection = result;
    if (previousConnection != hasConnection) {
      connectionChangeController.add(hasConnection);
    }

    return hasConnection;
  }
}
