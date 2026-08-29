import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:bmsc/util/logger.dart';

final logger = LoggerUtils.getLogger('ErrorHandler');

class ErrorHandler {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static String? _lastMessage;
  static DateTime? _lastShownAt;

  static void showError(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      logger.warning('showError called without context: $message');
      return;
    }

    final now = DateTime.now();
    if (_lastMessage == message &&
        _lastShownAt != null &&
        now.difference(_lastShownAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastMessage = message;
    _lastShownAt = now;

    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: colorScheme.onError)),
        backgroundColor: colorScheme.error,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(8),
        action: SnackBarAction(
          label: '关闭',
          textColor: colorScheme.onError,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  static String _friendlyMessage(dynamic error) {
    if (error is SocketException ||
        error is HttpException ||
        error is HandshakeException) {
      return '网络连接失败，请检查网络后重试';
    }
    if (error is TimeoutException) {
      return '网络请求超时，请稍后重试';
    }
    return '发生未知错误，请稍后重试';
  }

  static void handleException(dynamic error, StackTrace? stack) {
    logger.severe("Error: ${error.toString()}\nStack: ${stack?.toString()}");
    showError(_friendlyMessage(error));
  }
}
