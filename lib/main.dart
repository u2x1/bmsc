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
import 'package:bmsc/service/section_habit_service.dart';
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
  // 捕获第三方库（just_audio 等）内部 print 输出到应用日志。just_audio
  // 的代理请求失败只走 print，release 下不可见，诊断代理问题必需。
  // 所有初始化（含 ensureInitialized）都必须发生在 runApp 同一个
  // zone 内，否则 debug 下报 Zone mismatch，且白耗掉 Flutter 全进程
  // 仅一次的完整异常报告名额（后续异常只剩摘要行）
  runZonedGuarded(
    () async {
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
          ErrorHandler.navigatorKey.currentState?.push(
              MaterialPageRoute<Widget>(
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
      runApp(const MyApp());
    },
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

  /// 顶部入口收进一个自定义下拉层（圆角列表 + 回弹展开 + 逐项错峰入场）
  final _appsButtonKey = GlobalKey();

  // 排序：搜索（最高频找歌）> 听歌识曲（招牌）> 动态 > 历史，设置惯例置底。
  // 「关于」不在此列——点 AppBar 标题仍可进入。
  static const _appsMenuItems = [
    (icon: Icons.search, label: '搜索', value: 0),
    (icon: Icons.graphic_eq, label: '听歌识曲', value: 1),
    (icon: Icons.wind_power_outlined, label: '动态', value: 2),
    (icon: Icons.history_outlined, label: '历史', value: 3),
    (icon: Icons.settings_outlined, label: '设置', value: 4),
  ];

  Future<void> _openAppsMenu() async {
    final ctx = _appsButtonKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final v = await Navigator.of(context)
        .push(_AppsMenuRoute(anchorRect: rect, items: _appsMenuItems));
    if (v != null) _onMenuSelected(v);
  }

  void _onMenuSelected(int i) {
    switch (i) {
      case 0:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const SearchScreen()));
      case 1:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const RecognitionScreen()));
      case 2:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const DynamicScreen()));
      case 3:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const LocalHistoryScreen()));
      case 4:
        // 从设置页返回时总是刷新主页，使「显示每日推荐」等
        // 主页相关设置即时生效（设置页不会返回 shouldRefresh）
        _pushThrottled<bool>(
          MaterialPageRoute<bool>(builder: (_) => const SettingsScreen()),
        )?.then((_) async {
          await _favScreenState?.refreshLoginState();
        });
    }
  }

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
      SectionHabitService.onAppResumed();
      _checkClipboard();
    } else if (state == AppLifecycleState.paused) {
      SectionHabitService.onAppPaused();
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
          // 入口收进一个自定义下拉层
          IconButton(
            key: _appsButtonKey,
            tooltip: '更多',
            icon: const Icon(Icons.apps),
            onPressed: _openAppsMenu,
          ),
        ],
      ),
      body: FavScreen(
        onInit: (state) => _favScreenState = state,
      ),
    );
  }
}

/// 入口下拉层路由：锚定按钮右上角，圆角列表卡片。
/// 动画：卡片自锚点角回弹展开（easeOutBack 缩放+下滑+渐显），
/// 列表项逐项错峰入场；收起快速渐隐。
class _AppsMenuRoute extends PopupRoute<int> {
  _AppsMenuRoute({required this.anchorRect, required this.items});

  final Rect anchorRect;
  final List<({IconData icon, String label, int value})> items;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭';

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final top = anchorRect.bottom + 8;
    final right =
        (MediaQuery.sizeOf(context).width - anchorRect.right).clamp(8.0, 1e9);
    return Padding(
      padding: EdgeInsets.only(top: top, right: right),
      child: Align(
        alignment: Alignment.topRight,
        child: AnimatedBuilder(
          animation: animation,
          child: _buildCard(context, animation),
          builder: (context, card) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeIn,
            );
            return Opacity(
              opacity: animation.value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.88 + 0.12 * enter.value,
                alignment: Alignment.topRight,
                child: Transform.translate(
                  offset: Offset(0, -10 * (1 - enter.value)),
                  child: card,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, Animation<double> animation) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 232),
      child: Material(
        color: cs.surfaceContainerHigh,
        elevation: 8,
        shadowColor: Colors.black45,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++)
                _tile(context, animation, i),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个列表项：色块圆角图标 + 文字，按序号错峰淡入上滑
  Widget _tile(BuildContext context, Animation<double> animation, int i) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final item = items[i];
    final stagger = CurvedAnimation(
      parent: animation,
      curve: Interval(0.06 * i, (0.5 + 0.06 * i).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: stagger,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero)
            .animate(stagger),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pop(context, item.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(item.icon,
                      size: 22, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(item.label, style: theme.textTheme.bodyLarge),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
