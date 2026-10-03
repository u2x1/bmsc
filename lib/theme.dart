import 'package:flutter/material.dart';

import 'service/shared_preferences_service.dart';

class ThemeProvider extends ChangeNotifier {
  static final ThemeProvider _instance = ThemeProvider._internal();
  factory ThemeProvider() => _instance;
  ThemeProvider._internal();

  static ThemeProvider get instance => _instance;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  static const int _defaultCommentFontSize = 14;

  int _commentFontSize = _defaultCommentFontSize;
  int get commentFontSize => _commentFontSize;

  /// OLED 纯黑模式：深色主题下背景使用 #000000（issue #15）
  bool _pureBlack = false;
  bool get pureBlack => _pureBlack;

  Future<void> init() async {
    final prefs = await SharedPreferencesService.instance;
    _commentFontSize =
        prefs.getInt('comment_font_size') ?? _defaultCommentFontSize;
    _pureBlack = prefs.getBool('pure_black_mode') ?? false;
    switch (prefs.getString('theme_mode') ?? '') {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      case 'system':
        _themeMode = ThemeMode.system;
        break;
      default:
        _themeMode = ThemeMode.system;
        break;
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode != mode) {
      _themeMode = mode;
      final prefs = await SharedPreferencesService.instance;
      await prefs.setString('theme_mode', mode.name);
      notifyListeners();
    }
  }

  Future<void> setCommentFontSize(int size) async {
    if (_commentFontSize != size) {
      _commentFontSize = size;
      final prefs = await SharedPreferencesService.instance;
      await prefs.setInt('comment_font_size', size);
      notifyListeners();
    }
  }

  Future<void> setPureBlack(bool enabled) async {
    if (_pureBlack != enabled) {
      _pureBlack = enabled;
      final prefs = await SharedPreferencesService.instance;
      await prefs.setBool('pure_black_mode', enabled);
      notifyListeners();
    }
  }

  static final ColorScheme _lightColorScheme = ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.light,
  );

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: _lightColorScheme,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: _lightColorScheme.surfaceContainer,
      actionTextColor: _lightColorScheme.onSurface.withValues(alpha: 0.7),
      contentTextStyle:
          TextStyle(color: _lightColorScheme.onSurface.withValues(alpha: 0.7)),
    ),
  );

  static final ColorScheme _darkColorScheme = ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.dark,
    primary: Colors.blue.shade300,
    onPrimary: Colors.black,
    surfaceContainerHighest: const Color(0xFF262626),
    surfaceContainerHigh: const Color(0xFF1F1F1F),
    surfaceContainer: const Color(0xFF191919),
    surfaceContainerLow: const Color(0xFF141414),
    surfaceContainerLowest: const Color(0xFF0A0A0A),
    error: const Color(0xFFFF5757),
    onError: Colors.black,
    secondary: Colors.blueGrey.shade200,
    onSecondary: Colors.black,
    outline: const Color(0xFF6E6E6E),
    outlineVariant: const Color(0xFF2C2C2C),
  );

  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: _darkColorScheme.surfaceContainer,
      actionTextColor: _darkColorScheme.onSurface.withValues(alpha: 0.7),
      contentTextStyle:
          TextStyle(color: _darkColorScheme.onSurface.withValues(alpha: 0.7)),
    ),
    colorScheme: _darkColorScheme,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFFE0E0E0)),
      bodyMedium: TextStyle(color: Color(0xFFE0E0E0)),
      bodySmall: TextStyle(color: Color(0xFFBDBDBD)),
    ),
  );

  /// OLED 纯黑配色：背景层为纯黑 #000000，容器层保留微弱亮度以区分层级
  static final ColorScheme _oledColorScheme = _darkColorScheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceBright: const Color(0xFF2C2C2C),
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF0D0D0D),
    surfaceContainer: const Color(0xFF141414),
    surfaceContainerHigh: const Color(0xFF1C1C1C),
    surfaceContainerHighest: const Color(0xFF262626),
  );

  static final ThemeData darkThemeOled = darkTheme.copyWith(
    colorScheme: _oledColorScheme,
    scaffoldBackgroundColor: Colors.black,
  );

  /// 当前应使用的深色主题（根据纯黑模式开关）
  ThemeData get activeDarkTheme => _pureBlack ? darkThemeOled : darkTheme;
}
