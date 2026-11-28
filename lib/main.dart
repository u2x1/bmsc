import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bmsc/component/home_toolbar_meta.dart';
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
import 'package:bmsc/util/home_toolbar.dart';
import 'package:bmsc/util/url.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
          // 界面文案均为中文：Material 内置组件（时间选择器、文本选择菜单、
          // 返回按钮的无障碍标签等）也固定中文，否则显示英文
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
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

  final _moreButtonKey = GlobalKey();

  /// 磁贴菜单打开期间隐藏原按钮：菜单层在同一位置画会变成 × 的按钮
  bool _moreOpen = false;

  Future<void> _openMoreTiles(List<HomeToolbarItem> items) async {
    final box = _moreButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _moreOpen = true);
    final route = _TileMenuRoute(anchorRect: anchor, items: items);
    // 收起动画（× 转回）播完再恢复原按钮；push 的结果在出栈瞬间即返回
    unawaited(route.completed.then((_) {
      if (mounted) setState(() => _moreOpen = false);
    }));
    final picked = await Navigator.of(context).push(route);
    if (picked != null) _openToolbarItem(picked);
  }

  void _openToolbarItem(HomeToolbarItem item) {
    switch (item) {
      case HomeToolbarItem.search:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const SearchScreen()));
      case HomeToolbarItem.recognition:
        _pushThrottled<Widget>(MaterialPageRoute<Widget>(
            builder: (_) => const RecognitionScreen()));
      case HomeToolbarItem.dynamic:
        _pushThrottled<Widget>(
            MaterialPageRoute<Widget>(builder: (_) => const DynamicScreen()));
      case HomeToolbarItem.history:
        _pushThrottled<Widget>(MaterialPageRoute<Widget>(
            builder: (_) => const LocalHistoryScreen()));
      case HomeToolbarItem.settings:
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
    SharedPreferencesService.loadHomeToolbar();
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
    return ValueListenableBuilder<List<HomeToolbarEntry>>(
      valueListenable: SharedPreferencesService.homeToolbar,
      child: FavScreen(
        onInit: (state) => _favScreenState = state,
      ),
      builder: (context, toolbar, body) {
        final iconItems = [
          for (final e in toolbar)
            if (e.pinned) e.item,
        ];
        final menuItems = [
          for (final e in toolbar)
            if (!e.pinned) e.item,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Tooltip(
              message: '关于',
              child: Semantics(
                button: true,
                label: '关于',
                child: GestureDetector(
                  onTap: () => _pushThrottled<Widget>(
                    MaterialPageRoute<Widget>(
                        builder: (_) => const AboutScreen()),
                  ),
                  child: Row(
                    children: [
                      // 顶栏图标较多时标题省略，不溢出
                      const Flexible(
                        child: Text("BiliMusic",
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
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
              for (final item in iconItems)
                IconButton(
                  tooltip: kHomeToolbarMeta[item]!.$2,
                  icon: Icon(kHomeToolbarMeta[item]!.$1),
                  onPressed: () => _openToolbarItem(item),
                ),
              // 「更多」：放进菜单的入口以悬浮磁贴弹出（_TileMenuRoute），
              // 顺序同用户设置。全部入口都放到顶栏时不显示
              if (menuItems.isNotEmpty)
                IconButton(
                  key: _moreButtonKey,
                  tooltip: '更多',
                  icon: Opacity(
                      opacity: _moreOpen ? 0 : 1,
                      child: const Icon(Icons.apps)),
                  onPressed: () => _openMoreTiles(menuItems),
                ),
            ],
          ),
          body: body,
        );
      },
    );
  }
}

/// 「更多」的悬浮磁贴菜单：没有面板也没有遮罩，每个入口是一块方形
/// 「图标 + 文字」磁贴，排在**以按钮为圆心**的四分之一圆弧上（正下方
/// 到左下方）——每块磁贴到按钮（手指刚点的位置）距离相同，展开时沿
/// 各自半径从按钮射出、收起时缩回圆心，一眼可见出自这个按钮。弧线
/// 不进入左上方，避免压住顶栏的其他图标；入口多时加大半径防止重叠。
/// 展开期间按钮原位变成 ×（旋转交叉淡入），点它或点空白处收起——
/// 在哪儿打开就在哪儿关闭
class _TileMenuRoute extends PopupRoute<HomeToolbarItem> {
  _TileMenuRoute({required this.anchorRect, required this.items});

  final Rect anchorRect;
  final List<HomeToolbarItem> items;

  static const _tileSize = 68.0;
  static const _minGap = 8.0; // 相邻磁贴中心距至少 _tileSize + _minGap
  static const _minRadius = 140.0;
  // 弧线起止角（屏幕坐标，0 为正右、顺时针）：正下方 → 左下
  static const _startAngle = 90 * pi / 180;
  static const _endAngle = 150 * pi / 180;
  static const _stagger = 0.1;

  @override
  Duration get transitionDuration =>
      Duration(milliseconds: 220 + 25 * (items.length - 1));

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭';

  @override
  Color? get barrierColor => null;

  /// 弧线布局：半径与起始角互相依赖——相邻磁贴不重叠决定半径（弦长
  /// 2R·sin(步进/2) ≥ 边长 + 间距），磁贴不越出屏幕右缘决定起始角
  /// （按钮贴着右缘，正下方那块会出界，被钳回后与邻块重叠）。迭代
  /// 几次即收敛；返回 (半径, 起始角)
  (double, double) _layout(double maxCenterX) {
    var start = _startAngle;
    var radius = _minRadius;
    for (var k = 0; k < 4; k++) {
      if (items.length > 1) {
        final step = (_endAngle - start) / (items.length - 1);
        radius =
            max(_minRadius, (_tileSize + _minGap) / (2 * sin(step / 2)));
      }
      final c = ((maxCenterX - anchorRect.center.dx) / radius).clamp(-1.0, 1.0);
      start = max(_startAngle, acos(c));
    }
    return (radius, start);
  }

  double _angle(int i, double start) => items.length < 2
      ? (start + _endAngle) / 2
      : start + (_endAngle - start) * i / (items.length - 1);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final screen = MediaQuery.sizeOf(context);
    final center = anchorRect.center;
    final (radius, start) = _layout(screen.width - 8 - _tileSize / 2);
    final n = items.length;
    // 每块磁贴自身的动画时长占比（入口最多 5 个，span ≥ 0.6）
    final span = 1 - _stagger * (n - 1);
    return Stack(
      children: [
        Positioned.fromRect(
          rect: anchorRect,
          child: IconButton(
            tooltip: '收起',
            onPressed: () => Navigator.pop(context),
            icon: AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                final t = Curves.easeOutCubic.transform(animation.value);
                return Transform.rotate(
                  angle: t * pi / 2,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                          opacity: 1 - t, child: const Icon(Icons.apps)),
                      Opacity(opacity: t, child: const Icon(Icons.close)),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        for (var i = 0; i < n; i++)
          Builder(builder: (context) {
            final target = center +
                Offset(cos(_angle(i, start)), sin(_angle(i, start))) * radius;
            // 终点钳制在屏幕内；动画沿「圆心 → 终点」直线进行
            final end = Offset(
              target.dx.clamp(8 + _tileSize / 2, screen.width - 8 - _tileSize / 2),
              target.dy.clamp(8 + _tileSize / 2, screen.height - 8 - _tileSize / 2),
            );
            return Positioned(
              left: end.dx - _tileSize / 2,
              top: end.dy - _tileSize / 2,
              width: _tileSize,
              height: _tileSize,
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, child) {
                  final double t;
                  if (animation.status == AnimationStatus.reverse) {
                    t = Curves.easeInCubic.transform(animation.value);
                  } else {
                    t = Curves.easeOutCubic.transform(
                        ((animation.value - _stagger * i) / span)
                            .clamp(0.0, 1.0));
                  }
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: (center - end) * (1 - t),
                      child: Transform.scale(scale: 0.4 + 0.6 * t, child: child),
                    ),
                  );
                },
                child: _tile(context, items[i]),
              ),
            );
          }),
      ],
    );
  }

  Widget _tile(BuildContext context, HomeToolbarItem item) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (icon, label) = kHomeToolbarMeta[item]!;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: cs.secondaryContainer,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(context, item),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: cs.onSecondaryContainer),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSecondaryContainer,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
