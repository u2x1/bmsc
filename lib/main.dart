import 'dart:io';

import 'package:bmsc/component/track_tile.dart';
import 'package:bmsc/model/vid.dart';
import 'package:bmsc/screen/dynamic_screen.dart';
import 'package:bmsc/screen/fav_screen.dart';
import 'package:bmsc/screen/local_history_screen.dart';
import 'package:bmsc/service/audio_service.dart' as app_audio;
import 'package:bmsc/audio/just_audio_background_custom.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
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
import 'package:bmsc/screen/settings_screen.dart';
import 'package:bmsc/theme.dart';

import 'util/string.dart';

final _logger = LoggerUtils.getLogger('main');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    _logger.info('Android version: ${Platform.operatingSystemVersion}');

    await JustAudioBackground.init(
      androidNotificationChannelId: 'org.u2x1.bmsc.channel.audio',
      androidNotificationChannelName: 'Audio Playback',
      androidStopForegroundOnPause: true,
    );
  }

  if (Platform.isLinux || Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized();
  }

  await ThemeProvider.instance.init();
  if (!kDebugMode) _setupErrorHandlers();
  runApp(const MyApp());
  LoggerUtils.init();
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
        final isDarkMode = ThemeProvider.instance.themeMode == ThemeMode.dark ||
            (ThemeProvider.instance.themeMode == ThemeMode.system &&
                WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                    Brightness.dark);
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          systemNavigationBarColor: isDarkMode
              ? ThemeProvider.darkTheme.colorScheme.surfaceContainer
              : ThemeProvider.lightTheme.colorScheme.surfaceContainer,
        ));

        return MaterialApp(
          navigatorKey: ErrorHandler.navigatorKey,
          theme: ThemeProvider.lightTheme,
          darkTheme: ThemeProvider.darkTheme,
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UpdateService.instance.then((x) async {
      setState(() {
        curVersion = x.curVersion;
        hasNewVersion = x.hasNewVersion;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
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
    if (as.player.sequenceState.currentSource?.tag.extras['bvid'] ==
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
        title: GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<Widget>(builder: (_) => const AboutScreen()),
          ),
          child: Row(
            children: [
              const Text("BiliMusic"),
              if (hasNewVersion)
                Icon(Icons.arrow_circle_up_outlined,
                    color: Theme.of(context).colorScheme.error),
            ],
          ),
        ),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<Widget>(builder: (_) => const SearchScreen()),
            ),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<Widget>(builder: (_) => const DynamicScreen()),
            ),
            icon: const Icon(Icons.wind_power_outlined),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<Widget>(
                  builder: (_) => const LocalHistoryScreen()),
            ),
            icon: const Icon(Icons.history_outlined),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<bool>(
                builder: (_) => const SettingsScreen(),
              ),
            ).then((shouldRefresh) async {
              if (shouldRefresh == true) {
                if ((await BilibiliService.instance).myInfo?.mid == 0) {
                  _favScreenState?.setState(() {
                    _favScreenState?.signedin = false;
                  });
                } else {
                  _favScreenState?.setState(() {
                    _favScreenState?.signedin = true;
                  });
                  _favScreenState?.loadFavorites();
                }
              }
            }),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: FavScreen(
        onInit: (state) => _favScreenState = state,
      ),
    );
  }
}
