import 'dart:async';
import 'dart:io';

import 'package:bmsc/component/track_tile.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/screen/dynamic_screen.dart';
import 'package:bmsc/screen/fav_screen.dart';
import 'package:bmsc/screen/local_history_screen.dart';
import 'package:bmsc/screen/recognition_screen.dart';
import 'package:bmsc/service/audio_service.dart' as app_audio;
import 'package:bmsc/audio/just_audio_background_custom.dart';
import 'package:bmsc/service/overlay_recognition.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/service/stats_service.dart';
import 'package:bmsc/service/update_service.dart';
import 'package:bmsc/util/url.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/screen/search_screen.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'component/playing_card.dart';
import 'package:flutter/foundation.dart';
import 'util/error_handler.dart';
import 'screen/about_screen.dart';
import 'util/logger.dart';
import 'util/whats_new.dart';
import 'package:bmsc/screen/settings_screen.dart';
import 'package:bmsc/theme.dart';

import 'util/string.dart';

final _logger = LoggerUtils.getLogger('main');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LoggerUtils.init();
  // 匿名使用统计每日心跳（默认开启，设置 → 隐私 可关），不阻塞启动
  unawaited(StatsService.maybePing());

  if (Platform.isAndroid || Platform.isIOS) {
    _logger.info('audio platform: ${Platform.operatingSystem}');

    await JustAudioBackground.init(
      androidNotificationChannelId: 'org.u2x1.bmsc.channel.audio',
      androidNotificationChannelName: 'Audio Playback',
      androidStopForegroundOnPause: true,
    );
  }

  // 悬浮窗识曲（Android）：气泡点击 → 识别 → 点结果回链搜索
  if (Platform.isAndroid) {
    OverlayRecognitionService.instance.init();
    OverlayRecognitionService.instance.onOpenSearch = (keyword) {
      ErrorHandler.navigatorKey.currentState?.push(MaterialPageRoute<Widget>(
          builder: (_) => SearchScreen(initialKeyword: keyword)));
    };
  }

  if (Platform.isLinux || Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized();
  }

  await ThemeProvider.instance.init();
  // 后台扫描并删除无 DB 记录的孤儿缓存文件（.part 残留、失效 .mime 等），
  // 不阻塞启动。
  unawaited(DatabaseManager.sweepOrphanCacheFiles());
  if (!kDebugMode) _setupErrorHandlers();
  // 捕获第三方库（just_audio 等）内部 print 输出到应用日志。just_audio
  // 的代理请求失败只走 print，release 下不可见，诊断代理问题必需。
  runZonedGuarded(
    () => runApp(const MyApp()),
    (error, stack) => _logger.severe('zone error', error, stack),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        _logger.info('[print] $line');
      },
    ),
  );
}

void _setupErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    ErrorHandler.handleException(details.exception, details.stack);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorHandler.handleException(error, stack);
    return true;
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeProvider.instance,
      builder: (context, child) {
        return MaterialApp(
          navigatorKey: ErrorHandler.navigatorKey,
          theme: ThemeProvider.lightTheme,
          darkTheme: ThemeProvider.instance.activeDarkTheme,
          themeMode: ThemeProvider.instance.themeMode,
          home: Builder(builder: (context) {
            return Scaffold(
              body: MyHomePage(title: 'BiliMusic'),
              bottomNavigationBar: const PlayingCard(),
            );
          }),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  String? curVersion;
  bool hasNewVersion = false;
  FavScreenState? _favScreenState;
  String? _clipboardText;
  DateTime? _lastNavAt;

  /// 顶部按钮折叠展开状态（5 个入口收进一个按钮，点按横向展开）
  bool _actionsExpanded = false;

  /// 包装 actions 按钮：跳转后自动收起
  void Function() _act(void Function() f) => () {
        setState(() => _actionsExpanded = false);
        f();
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ThemeProvider.instance.addListener(_updateSystemUiOverlay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemUiOverlay();
      // 升级后首次启动的新版本欢迎弹窗（内部自行判断是否需要展示）
      WhatsNew.maybeShow(context);
    });
    UpdateService.instance.then((x) async {
      if (!mounted) return;
      setState(() {
        curVersion = x.curVersion;
        hasNewVersion = x.hasNewVersion;
      });
    });
  }

  @override
  void dispose() {
    ThemeProvider.instance.removeListener(_updateSystemUiOverlay);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  @override
  void didChangePlatformBrightness() {
    _updateSystemUiOverlay();
  }

  void _updateSystemUiOverlay() {
    if (!mounted) return;
    final themeMode = ThemeProvider.instance.themeMode;
    final isDarkMode = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      systemNavigationBarColor: isDarkMode
          ? ThemeProvider.instance.activeDarkTheme.colorScheme.surfaceContainer
          : ThemeProvider.lightTheme.colorScheme.surfaceContainer,
    ));
  }

  Future<T?>? _pushThrottled<T>(Route<T> route) {
    final now = DateTime.now();
    if (_lastNavAt != null &&
        now.difference(_lastNavAt!) < const Duration(milliseconds: 500)) {
      return null;
    }
    _lastNavAt = now;
    return Navigator.push<T>(context, route);
  }

  Future<void> _checkClipboard() async {
    if (!(await SharedPreferencesService.getReadFromClipboard())) return;
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text == null) return;
    if (clipboardData?.text == _clipboardText) return;
    _clipboardText = clipboardData?.text;
    _logger.info('clipboard data detected: ${clipboardData?.text}');

    var text = _clipboardText!;

    VidResult? vidDetail = await getVidDetailFromUrl(text);
    if (vidDetail == null) return;

    final as = await app_audio.AudioService.instance;
    if (as.player.sequenceState.currentSource?.tag.extras?['bvid'] ==
        vidDetail.bvid) {
      _logger.info('clipboard detected, but already playing');
      return;
    }

    int min = vidDetail.duration ~/ 60;
    int sec = vidDetail.duration % 60;
    final duration = "$min:${sec.toString().padLeft(2, '0')}";

    if (!context.mounted) return;

    final dialogContext = context;
    showDialog(
      context: dialogContext,
      builder: (context) => AlertDialog(
          title: const Text('检测到剪贴板视频'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TrackTile(
                  title: vidDetail.title,
                  author: vidDetail.owner.name,
                  len: duration,
                  pic: vidDetail.pic,
                  view: unit(vidDetail.stat.view),
                  onTap: () {
                    Navigator.pop(context);
                    app_audio.AudioService.instance
                        .then((x) => x.playByBvid(vidDetail.bvid));
                  }),
            ],
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Tooltip(
          message: '关于',
          child: Semantics(
            button: true,
            label: '关于',
            child: GestureDetector(
              onTap: () => _pushThrottled<Widget>(
                MaterialPageRoute<Widget>(builder: (_) => const AboutScreen()),
              ),
              child: Row(
                children: [
                  const Text("BiliMusic"),
                  if (hasNewVersion)
                    Tooltip(
                      message: '有新版本',
                      child: Icon(Icons.arrow_circle_up_outlined,
                          color: Theme.of(context).colorScheme.error),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          // 5 个入口折叠为一个按钮，点按在 AppBar 下方向下展开/收起
          IconButton(
            tooltip: _actionsExpanded ? '收起' : '更多',
            onPressed: () =>
                setState(() => _actionsExpanded = !_actionsExpanded),
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) =>
                  RotationTransition(turns: anim, child: child),
              child: Icon(
                _actionsExpanded ? Icons.close : Icons.apps,
                key: ValueKey(_actionsExpanded),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 入口面板：AppBar 下方向下展开/收起
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _actionsExpanded
                  ? Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            width: 0.5,
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _actionEntry(
                            icon: Icons.graphic_eq,
                            label: '识曲',
                            onTap: () => _pushThrottled<Widget>(
                              MaterialPageRoute<Widget>(
                                  builder: (_) => const RecognitionScreen()),
                            ),
                          ),
                          _actionEntry(
                            icon: Icons.search,
                            label: '搜索',
                            onTap: () => _pushThrottled<Widget>(
                              MaterialPageRoute<Widget>(
                                  builder: (_) => const SearchScreen()),
                            ),
                          ),
                          _actionEntry(
                            // B 站「动态」官方图标为风车造型
                            icon: Icons.wind_power_outlined,
                            label: '动态',
                            onTap: () => _pushThrottled<Widget>(
                              MaterialPageRoute<Widget>(
                                  builder: (_) => const DynamicScreen()),
                            ),
                          ),
                          _actionEntry(
                            icon: Icons.history_outlined,
                            label: '历史',
                            onTap: () => _pushThrottled<Widget>(
                              MaterialPageRoute<Widget>(
                                  builder: (_) => const LocalHistoryScreen()),
                            ),
                          ),
                          _actionEntry(
                            icon: Icons.settings_outlined,
                            label: '设置',
                            // 从设置页返回时总是刷新主页，使「显示每日推荐」等
                            // 主页相关设置即时生效（设置页不会返回 shouldRefresh）
                            onTap: () {
                              _pushThrottled<bool>(
                                MaterialPageRoute<bool>(
                                  builder: (_) => const SettingsScreen(),
                                ),
                              )?.then((_) async {
                                await _favScreenState?.refreshLoginState();
                              });
                            },
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Expanded(
            child: FavScreen(
              onInit: (state) => _favScreenState = state,
            ),
          ),
        ],
      ),
    );
  }

  /// 入口面板的单项（图标+文字），点击后自动收起面板
  Widget _actionEntry({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _act(onTap),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
