import 'dart:io';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectionService {
  static final ConnectionService _singleton = ConnectionService._internal();
  ConnectionService._internal();

  static ConnectionService getInstance() => _singleton;

  bool hasConnection = false;

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

  void _connectionChange(List<ConnectivityResult> result) {
    checkConnection();
  }

  Future<bool> checkConnection() async {
    bool previousConnection = hasConnection;

    try {
      final result = await InternetAddress.lookup('google.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        hasConnection = true;
      } else {
        hasConnection = false;
      }
    } on SocketException catch (_) {
      hasConnection = false;
    }

    if (previousConnection != hasConnection) {
      connectionChangeController.add(hasConnection);
    }

    return hasConnection;
  }
}
