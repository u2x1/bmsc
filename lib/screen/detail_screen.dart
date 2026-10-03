import 'dart:async';
import 'dart:math';

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:bmsc/audio/audio_player_ext.dart';
import 'package:bmsc/component/playlist_bottom_sheet.dart';
import 'package:bmsc/component/select_favlist_dialog_multi.dart';
import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/comment.dart';
import 'package:bmsc/model/subtitle.dart';
import 'package:bmsc/screen/user_detail_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../component/playing_card.dart';
import '../util/widget.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:bmsc/screen/comment_screen.dart';
import 'package:share_plus/share_plus.dart';
import 'package:bmsc/component/download_parts_dialog.dart';
import 'package:bmsc/service/download_manager.dart';
import 'package:bmsc/model/download_task.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key});

  @override
  State<StatefulWidget> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen>
    with SingleTickerProviderStateMixin {
  bool? _isFavorite;
  String? _currentBvid;
  bool _showSubtitles = false;
  List<BilibiliSubtitle>? _subtitles;
  final AutoScrollController _subtitleScrollController = AutoScrollController();
  // 字幕数据缓存，key 为字幕文件 URL
  final Map<String, List<BilibiliSubtitle>> _subtitleCache = {};
  // 可用字幕轨道缓存，key 为 '${aid}_$cid'，值为 (语言名, 字幕 URL) 列表
  final Map<String, List<(String, String)>> _subtitleTracksCache = {};
  // 每个视频记住用户选择的字幕轨道下标，key 为 '${aid}_$cid'
  final Map<String, int> _subtitleTrackIndexCache = {};
  String? currentKey;
  final Map<String, CommentData?> _commentCache = {};

  AudioService? _audioService;
  bool _isAudioServiceLoading = true;
  SequenceState? _currentSequenceState;
  StreamSubscription<SequenceState?>? _sequenceStateSubscription;
  int _favCheckToken = 0;
  int _subtitleLoadToken = 0;
  bool _isTitleExpanded = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // Initialize AudioService
    _audioService = await AudioService.instance;
    if (!mounted) return;
    setState(() {
      _isAudioServiceLoading = false;
    });

    // Set up listeners for audio state
    _sequenceStateSubscription =
        _audioService!.player.sequenceStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _currentSequenceState = state;
      });

      if ((state.currentSource?.tag.extras['dummy'] as bool?) == true) {
        _checkFavoriteStatus(null, state.currentSource?.tag.id);
      }

      // Check favorite status when current track changes
      final bvid = state.currentSource?.tag.extras['bvid'] as String?;
      if (bvid != _currentBvid) {
        _currentBvid = bvid;
        final aid = state.currentSource?.tag.extras['aid'] as int?;
        if (aid != null) {
          _checkFavoriteStatus(aid, state.currentSource?.tag.extras['bvid']);
        }
      }
    });

    // Initialize initial values
    _currentSequenceState = _audioService!.player.sequenceState;
  }

  Future<void> _checkFavoriteStatus(int? aid, String? bvid) async {
    final token = ++_favCheckToken;
    if (!mounted) return;
    if (aid == null && bvid == null) {
      setState(() => _isFavorite = null);
      return;
    }
    bool isFavedDB = false;
    if (bvid != null) {
      isFavedDB = await DatabaseManager.isFaved(bvid);
      if (!mounted || token != _favCheckToken) return;
      setState(() => _isFavorite = isFavedDB);
    }
    if (aid != null) {
      final isFavorited =
          await (await BilibiliService.instance).isFavorited(aid);
      if (isFavedDB && bvid != null && isFavorited != null && !isFavorited) {
        await DatabaseManager.rmFav(bvid);
      }
      if (!mounted || token != _favCheckToken) return;
      setState(() => _isFavorite = isFavorited);
    }
  }

  bool _isSmallScreen(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    // 计算屏幕对角线长度(逻辑像素)
    final diagonal =
        sqrt(screenWidth * screenWidth + screenHeight * screenHeight);

    // 判断是否为平板
    final isTablet = MediaQuery.of(context).size.shortestSide >= 600;

    // 如果是平板设备，则不认为是小屏幕
    if (isTablet) {
      return false;
    }

    // 对于手机设备，使用对角线长度和最短边长来判断
    // 对角线小于900逻辑像素或最短边小于360逻辑像素认为是小屏幕
    return diagonal < 900 || screenSize.shortestSide < 360;
  }

  // ---- 下滑关闭手势（Android 不启用，见 build） ----
  // 模拟 Apple Music「播放中」页的下滑关闭：拖拽实时下移页面，释放时
  // 超过阈值或快速下滑则 pop（路由反向转场本身即纵向下滑退出，见
  // playing_card.dart 的 _NowPlayingRoute，与手势视觉连贯），否则回弹。
  double _dismissDragOffset = 0;
  AnimationController? _dismissAnimController;

  void _onDismissDragStart(DragStartDetails details) {
    _dismissAnimController?.stop();
    _dismissAnimController?.dispose();
    _dismissAnimController = null;
  }

  void _onDismissDragUpdate(DragUpdateDetails details) {
    final offset = _dismissDragOffset + details.delta.dy;
    if (offset < 0 && _dismissDragOffset == 0) return;
    setState(() {
      _dismissDragOffset = offset.clamp(0.0, double.infinity);
    });
  }

  void _onDismissDragEnd(DragEndDetails details) {
    if (_dismissDragOffset == 0) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dismissDragOffset > screenHeight * 0.25 || velocity > 700) {
      // 保持当前偏移直接 pop：反向转场从当前位置继续下滑退出
      Navigator.of(context).pop();
    } else {
      final controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      );
      _dismissAnimController = controller;
      final animation = Tween<double>(begin: _dismissDragOffset, end: 0)
          .animate(CurvedAnimation(parent: controller, curve: Curves.easeOut));
      animation.addListener(() {
        setState(() {
          _dismissDragOffset = animation.value;
        });
      });
      controller.forward().whenComplete(() {
        if (_dismissAnimController == controller) {
          _dismissAnimController = null;
        }
        controller.dispose();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // Android：不用下滑手势，返回完全交给系统（预测性返回 + 平台
    // 转场，横向进出）；iOS/桌面：保留下滑关闭手势，与 _NowPlayingRoute
    // 的纵向转场视觉连贯
    final swipeDismissEnabled =
        Theme.of(context).platform != TargetPlatform.android;

    final page = Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('正在播放'),
        forceMaterialTransparency: true,
        actions: [
          _buildShareButton(),
        ],
      ),
      body: _isAudioServiceLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 800,
                  ),
                  child: isLandscape
                      ? _buildLandscapeLayout(context)
                      : _buildPortraitLayout(context),
                ),
              ),
            ),
    );

    if (!swipeDismissEnabled) return page;
    return GestureDetector(
      onVerticalDragStart: _onDismissDragStart,
      onVerticalDragUpdate: _onDismissDragUpdate,
      onVerticalDragEnd: _onDismissDragEnd,
      child: Transform.translate(
        offset: Offset(0, _dismissDragOffset),
        child: page,
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 音质切换按钮（底部控制行风格：图标 + 文字标签，置于下载按钮旁）。
  Widget _buildQualityButton(BuildContext context, bool isSmallScreen) {
    if (_isAudioServiceLoading) {
      return const SizedBox.shrink();
    }

    final src = _currentSequenceState?.currentSource;
    return InkWell(
      onTap: src == null ? null : _showQualitySheet,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note,
              size: isSmallScreen ? 22 : 24,
            ),
            const SizedBox(height: 4),
            Text(
              '音质',
              style: TextStyle(
                fontSize: isSmallScreen ? 8 : 10,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 展示当前曲目的可用音质列表（含每档精确存储占用，按大小降序），
  /// 点击立即切换。
  Future<void> _showQualitySheet() async {
    final service = _audioService;
    if (service == null || !mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: FutureBuilder<List<AudioQualityInfo>?>(
          future: service.getCurrentTrackQualities(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final qualities = snapshot.data;
            if (qualities == null || qualities.isEmpty) {
              return const SizedBox(
                height: 120,
                child: Center(child: Text('当前曲目暂不支持切换音质')),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('播放音质',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                ...qualities.map((q) => ListTile(
                      title: Text(q.label),
                      subtitle: q.sizeBytes != null
                          ? Text(_formatSize(q.sizeBytes!))
                          : null,
                      trailing: q.isCurrent
                          ? Icon(Icons.check,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        final messenger = ScaffoldMessenger.of(this.context);
                        final ok =
                            await service.switchCurrentTrackQuality(q.id);
                        messenger.showSnackBar(SnackBar(
                            content:
                                Text(ok ? '已切换为 ${q.label}' : '切换音质失败，请稍后重试')));
                      },
                    )),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildShareButton() {
    if (_isAudioServiceLoading) {
      return const SizedBox.shrink();
    }

    final src = _currentSequenceState?.currentSource;
    return IconButton(
      icon: const Icon(Icons.share),
      onPressed: src == null
          ? null
          : () {
              final bvid = src.tag.extras['bvid'];
              final title = src.tag.title;
              final url = 'https://www.bilibili.com/video/$bvid';
              SharePlus.instance.share(ShareParams(
                text: '$title\n$url',
                subject: title,
              ));
            },
    );
  }

  Widget _buildPortraitLayout(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);
    final padding = isSmallScreen ? 12.0 : 24.0;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSubtitles && _subtitles != null)
              Column(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        child: _buildCoverImage(showTapHint: false),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: _buildTitleAndArtist(
                          context,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: isSmallScreen ? 16 : 24),
                  _buildSubtitlesView(),
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8.0 : 16.0),
                    child: Column(
                      children: [
                        _buildProgressBar(context),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildTransportControls(),
                      ],
                    ),
                  ),
                ],
              )
            else
              Column(
                children: [
                  _buildCoverImage(),
                  SizedBox(height: isSmallScreen ? 16 : 24),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: padding),
                    child: _buildTitleAndArtist(context),
                  ),
                  SizedBox(height: isSmallScreen ? 10 : 30),
                  _buildProgressBar(context),
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8.0 : 16.0),
                    child: Column(
                      children: [
                        _buildPlaybackControls(),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildTransportControls(),
                        SizedBox(height: isSmallScreen ? 8 : 16),
                        _buildAdditionalControls(context),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);
    final horizontalPadding = isSmallScreen ? 8.0 : 16.0;
    final verticalSpacing = isSmallScreen ? 12.0 : 20.0;

    return Row(children: [
      Expanded(
        flex: 1,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_showSubtitles && _subtitles != null)
              Column(
                children: [
                  _buildSubtitlesView(),
                ],
              )
            else ...[
              _buildCoverImage(),
              SizedBox(height: verticalSpacing),
              _buildTitleAndArtist(context),
            ],
          ],
        ),
      ),
      SizedBox(width: 24),
      Expanded(
        flex: 1,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(horizontalPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showSubtitles && _subtitles != null) ...[
                  Row(
                    children: [
                      SizedBox(
                        child: _buildCoverImage(showTapHint: false),
                      ),
                      SizedBox(width: horizontalPadding),
                      Expanded(
                        child: _buildTitleAndArtist(
                          context,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: verticalSpacing),
                ],
                _buildProgressBar(context),
                SizedBox(height: verticalSpacing),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Column(
                    children: [
                      _buildPlaybackControls(),
                      SizedBox(height: verticalSpacing),
                      _buildTransportControls(),
                      SizedBox(height: verticalSpacing),
                      _buildAdditionalControls(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildCoverImage({bool showTapHint = true}) {
    final src = _currentSequenceState?.currentSource;
    final isSmallScreen = _isSmallScreen(context);
    double width = 355.5, height = 200.0;
    var factor = isSmallScreen ? 0.7 : 1;
    if (!showTapHint) {
      factor *= 0.4;
      width *= 0.9;
    }
    var imageSize = Size(width * factor, height * factor);

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.hasBoundedWidth &&
          imageSize.width > constraints.maxWidth) {
        imageSize = imageSize * (constraints.maxWidth / imageSize.width);
      }
      return _buildCoverImageContent(src, imageSize, showTapHint);
    });
  }

  Widget _buildCoverImageContent(
      IndexedAudioSource? src, Size imageSize, bool showTapHint) {
    return GestureDetector(
      onTap: showTapHint
          ? () async {
              if (src != null) {
                final aid = src.tag.extras['aid'] as int?;
                final cid = src.tag.extras['cid'] as int?;
                if (aid != null && cid != null) {
                  if (_showSubtitles) {
                    setState(() {
                      _showSubtitles = false;
                      _subtitles = null;
                    });
                  } else {
                    setState(() {
                      _showSubtitles = true;
                    });
                    await _loadSubtitles(aid, cid);
                  }
                }
              }
            }
          : null,
      child: shadow(ClipRRect(
        borderRadius: BorderRadius.circular(5.0),
        child: SizedBox(
            height: imageSize.height,
            width: imageSize.width,
            child: src == null
                ? Center(
                    child: Icon(Icons.question_mark, size: 50),
                  )
                : CachedNetworkImage(
                    imageUrl: src.tag.artUri.toString(),
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const Icon(Icons.music_note),
                    errorWidget: (context, url, error) =>
                        const Icon(Icons.music_note),
                  )),
      )),
    );
  }

  Widget _buildTitleAndArtist(BuildContext context, {bool compact = false}) {
    final src = _currentSequenceState?.currentSource;

    return Column(
      crossAxisAlignment:
          compact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Padding(
          padding: EdgeInsets.only(
            bottom: compact ? 4 : (_isSmallScreen(context) ? 4 : 8),
          ),
          child: GestureDetector(
            onTap: () => setState(() => _isTitleExpanded = !_isTitleExpanded),
            child: Text(
              src?.tag.title ?? "",
              style: TextStyle(
                fontSize: compact ? 16 : (_isSmallScreen(context) ? 16 : 18),
                fontWeight: FontWeight.w600,
              ),
              softWrap: true,
              maxLines: _isTitleExpanded ? null : (compact ? 1 : 2),
              overflow: _isTitleExpanded
                  ? TextOverflow.clip
                  : (compact ? TextOverflow.ellipsis : TextOverflow.fade),
              textAlign: compact ? TextAlign.left : TextAlign.center,
            ),
          ),
        ),
        InkWell(
          onTap: () => src == null
              ? null
              : Navigator.push(context, MaterialPageRoute<Widget>(
                  builder: (BuildContext context) {
                    return Scaffold(
                      body: UserDetailScreen(
                        mid: src.tag.extras['mid'] ?? 0,
                      ),
                      bottomNavigationBar: const PlayingCard(),
                    );
                  },
                )),
          child: src?.tag.artist != null
              ? Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    Text(
                      src?.tag.artist ?? "",
                      style: TextStyle(
                        fontSize:
                            compact ? 12 : (_isSmallScreen(context) ? 12 : 14),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      softWrap: false,
                      maxLines: 1,
                      textAlign: compact ? TextAlign.left : TextAlign.center,
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: compact ? 16 : (_isSmallScreen(context) ? 16 : 18),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                )
              : SizedBox(),
        ),
      ],
    );
  }

  Widget _buildProgressBar(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);

    return _PositionProgressBar(
      player: _audioService!.player,
      isSmallScreen: isSmallScreen,
    );
  }

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildPlaybackModeButton(),
        _buildFavoriteButton(),
      ],
    );
  }

  Widget _buildPlaybackModeButton() {
    return StreamBuilder<(LoopMode, bool)>(
      stream: Rx.combineLatest2(
        _audioService!.player.loopModeStream,
        _audioService!.player.shuffleModeEnabledStream,
        (a, b) => (a, b),
      ),
      builder: (context, snapshot) {
        final (loopMode, shuffleModeEnabled) =
            snapshot.data ?? (LoopMode.off, false);
        final icons = [
          Icons.playlist_play,
          Icons.repeat_one,
          Icons.repeat,
          Icons.shuffle,
        ];
        final labels = ["顺序播放", "单曲循环", "歌单循环", "随机播放"];
        final index =
            shuffleModeEnabled ? 3 : LoopMode.values.indexOf(loopMode);

        return TextButton.icon(
          icon: Icon(
            icons[index],
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          label: Text(
            labels[index],
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          onPressed: () {
            final idx = (index + 1) % labels.length;

            if (idx == 3) {
              _audioService!.player.setShuffleModeEnabled(true);
            } else {
              _audioService!.player.setLoopMode(LoopMode.values[idx]);
              _audioService!.player.setShuffleModeEnabled(false);
            }
          },
        );
      },
    );
  }

  Widget _buildFavoriteButton() {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, snapshot) {
        final src = snapshot.data?.currentSource;
        return Opacity(
            opacity: src == null ? 0.5 : 1.0,
            child: TextButton.icon(
              icon: Icon(
                _isFavorite == true ? Icons.favorite : Icons.favorite_border,
                size: 20,
                color: _isFavorite == true
                    ? Colors.red
                    : Theme.of(context).colorScheme.primary,
              ),
              label: Text(
                _isFavorite == true ? '已收藏' : '收藏',
                style: TextStyle(
                  fontSize: 12,
                  color: _isFavorite == true
                      ? Colors.red
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              onPressed: src == null
                  ? null
                  : () => _handleFavoriteAction(src, context),
            ));
      },
    );
  }

  Future<void> _handleFavoriteAction(
      IndexedAudioSource src, BuildContext context) async {
    final bs = await BilibiliService.instance;
    final uid = bs.myInfo?.mid ?? 0;
    final favs = await bs.getFavs(uid, rid: src.tag.extras['aid']);
    if (favs == null || favs.isEmpty) {
      return;
    }

    final defaultFolderId =
        await SharedPreferencesService.getDefaultFavFolder();

    if (_isFavorite != true && defaultFolderId != null) {
      final success = await bs.favoriteVideo(
            src.tag.extras['aid'],
            [defaultFolderId.$1],
            [],
          ) ??
          false;
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '已添加到收藏夹 ${defaultFolderId.$2}' : '收藏失败'),
          duration: const Duration(seconds: 2),
        ),
      );
      if (success) {
        DatabaseManager.addFav(src.tag.extras['bvid'], defaultFolderId.$1);
        Future.microtask(() => setState(() => _isFavorite = success));
      }
    } else {
      if (!context.mounted) return;
      final result = await showDialog(
          context: context,
          builder: (context) =>
              SelectMultiFavlistDialog(aid: src.tag.extras['aid']));
      if (result == null) return;
      final toAdd = result['toAdd'];
      final toRemove = result['toRemove'];
      if (toAdd.isEmpty && toRemove.isEmpty) {
        return;
      }

      final success = await (await BilibiliService.instance).favoriteVideo(
            src.tag.extras['aid'],
            toAdd,
            toRemove,
          ) ??
          false;
      if (!mounted) return;

      if (success) {
        if (toAdd.isNotEmpty) {
          Future.microtask(() => setState(() {
                _isFavorite = true;
              }));
        }

        for (var mid in toAdd) {
          await DatabaseManager.addFav(src.tag.extras['bvid'], mid);
        }
        for (var mid in toRemove) {
          await DatabaseManager.rmFav(src.tag.extras['bvid'], mid: mid);
        }

        if (toAdd.isEmpty) {
          _checkFavoriteStatus(null, src.tag.extras['bvid']);
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('收藏夹已更新'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        _checkFavoriteStatus(src.tag.extras['aid'], src.tag.extras['bvid']);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('操作失败'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Widget _buildTransportControls() {
    // 使用辅助方法判断小屏幕
    final isSmallScreen = _isSmallScreen(context);
    final iconSize = isSmallScreen ? 30.0 : 36.0;
    final player = _audioService!.player;
    final hasPrevious = player.hasPrevious;
    final hasNext = player.hasNext;
    final playerState = player.playerState;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(Icons.skip_previous, size: iconSize),
          onPressed:
              hasPrevious ? player.seekToPreviousRegardlessOfLoopMode : null,
        ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: EdgeInsets.all(isSmallScreen ? 6.0 : 8.0),
            child:
                _playPauseButton(playerState, player, context, isSmallScreen),
          ),
        ),
        IconButton(
          icon: Icon(Icons.skip_next, size: iconSize),
          onPressed: hasNext ? player.seekToNextRegardlessOfLoopMode : null,
        ),
      ],
    );
  }

  Widget _playPauseButton(PlayerState? playerState, AudioPlayer player,
      BuildContext context, bool isSmallScreen) {
    final processingState = playerState?.processingState;
    final iconSize = isSmallScreen ? 34.0 : 40.0;

    if (processingState == ProcessingState.loading ||
        processingState == ProcessingState.buffering) {
      return IconButton(
        icon: Icon(
          Icons.play_arrow,
          size: iconSize,
          color: Theme.of(context).disabledColor,
        ),
        onPressed: null,
      );
    } else if (player.playing != true) {
      return IconButton(
        icon: Icon(
          Icons.play_arrow,
          size: iconSize,
        ),
        onPressed: player.play,
      );
    } else if (processingState != ProcessingState.completed) {
      return IconButton(
        icon: Icon(
          Icons.pause,
          size: iconSize,
        ),
        onPressed: player.pause,
      );
    } else {
      return IconButton(
        icon: Icon(
          Icons.replay,
          size: iconSize,
        ),
        onPressed: () =>
            player.seek(Duration.zero, index: player.effectiveIndices.first),
      );
    }
  }

  Widget _buildAdditionalControls(BuildContext context) {
    final isSmallScreen = _isSmallScreen(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildSleepTimerButton(context, isSmallScreen),
        _buildPlaybackSpeedButton(context, isSmallScreen),
        _buildQualityButton(context, isSmallScreen),
        _buildDownloadButton(context, isSmallScreen),
        _buildPlaylistButton(context, isSmallScreen),
        _buildCommentButton(context, isSmallScreen),
      ],
    );
  }

  Widget _buildSleepTimerButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<int?>(
      stream: _audioService!.sleepTimerStream,
      builder: (context, snapshot) {
        final remainingSeconds = snapshot.data;
        final isActive = remainingSeconds != null;

        return InkWell(
          onTap: () =>
              _handleSleepTimerPress(isActive, _audioService!, context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isActive ? Icons.timer : Icons.timer_outlined,
                  color:
                      isActive ? Theme.of(context).colorScheme.primary : null,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                if (isActive)
                  Text(
                    _formatTime(remainingSeconds),
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (!isActive)
                  Text(
                    '定时',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSecs = seconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remainingSecs.toString().padLeft(2, '0')}';
    } else {
      return '$minutes:${remainingSecs.toString().padLeft(2, '0')}';
    }
  }

  void _handleSleepTimerPress(
      bool isActive, AudioService audioService, BuildContext context) {
    if (isActive) {
      _showCancelSleepTimerDialog(context);
    } else {
      _showSleepTimerOptionsDialog(context);
    }
  }

  void _showCancelSleepTimerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('定时停止播放'),
        content: const Text('是否取消定时停止播放？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () {
              _audioService!.setSleepTimer(null);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已取消定时停止播放'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('取消定时'),
          ),
        ],
      ),
    );
  }

  void _showSleepTimerOptionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('定时停止播放'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Text('倒计时停止',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SizedBox(
                height: 200,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      dense: true,
                      title: const Text('自定义时间'),
                      onTap: () => _showCustomTimerDialog(context),
                    ),
                    ...[5, 10, 15, 30, 45, 60, 90].map((minutes) => ListTile(
                          dense: true,
                          title: Text('$minutes 分钟'),
                          onTap: () {
                            _audioService!.setSleepTimer(minutes);
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('将在 $minutes 分钟后停止播放'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        )),
                  ],
                ),
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.only(top: 8.0, bottom: 8.0),
                child: Text('指定时刻停止',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ListTile(
                dense: true,
                title: const Text('选择时间'),
                onTap: () => _showTimePickerDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCustomTimerDialog(BuildContext context) {
    Navigator.pop(context);
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置定时时间（分钟）'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '分钟',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final minutes = int.tryParse(controller.text);
              if (minutes != null && minutes > 0) {
                _audioService!.setSleepTimer(minutes);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('将在 $minutes 分钟后停止播放'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTimePickerDialog(BuildContext context) async {
    Navigator.pop(context);

    // 获取当前时间作为初始值
    final now = DateTime.now();
    final initialTime = TimeOfDay(hour: now.hour, minute: now.minute);

    // 显示时间选择器
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        );
      },
    );

    if (selectedTime != null) {
      // 创建目标DateTime
      final now = DateTime.now();
      var targetTime = DateTime(
        now.year,
        now.month,
        now.day,
        selectedTime.hour,
        selectedTime.minute,
      );

      // 如果选择的时间已经过去，则设置为明天的这个时间
      if (targetTime.isBefore(now)) {
        targetTime = targetTime.add(const Duration(days: 1));
      }

      // 设置定时器
      _audioService!.setSleepTimer(null, specificTime: targetTime);

      // 计算并显示剩余时间
      final difference = targetTime.difference(now);
      final hours = difference.inHours;
      final minutes = difference.inMinutes % 60;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '将在 ${selectedTime.format(context)} (${hours > 0 ? '$hours小时' : ''}${minutes > 0 ? '$minutes分钟' : ''}后) 停止播放'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildPlaylistButton(BuildContext context, bool isSmallScreen) {
    return InkWell(
      onTap: () {
        showModalBottomSheet(
          context: context,
          builder: (context) => const PlaylistBottomSheet(),
          backgroundColor: Theme.of(context).colorScheme.surface,
          showDragHandle: true,
          isScrollControlled: true,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music,
              size: isSmallScreen ? 22 : 24,
            ),
            const SizedBox(height: 4),
            Text(
              '列表',
              style: TextStyle(
                fontSize: isSmallScreen ? 8 : 10,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, snapshot) {
        final src = snapshot.data?.currentSource;
        final aid = src?.tag.extras['aid']?.toString();

        Future<CommentData?> getCommentData(String aid) async {
          // Check cache first
          if (_commentCache.containsKey(aid)) {
            return _commentCache[aid];
          }

          // If not in cache, fetch and cache it
          final bs = await BilibiliService.instance;
          final data = await bs.getComment(aid, null);
          _commentCache[aid] = data;
          return data;
        }

        return InkWell(
          onTap: aid == null
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => CommentScreen(
                        aid: aid,
                      ),
                    ),
                  ),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.comment_outlined,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                if (aid != null)
                  FutureBuilder<CommentData?>(
                    future: getCommentData(aid),
                    builder: (context, snapshot) {
                      final count = snapshot.data?.cursor?.allCount ?? 0;
                      return Text(
                        count > 10000
                            ? '${(count / 10000).toStringAsFixed(1)}万'
                            : count.toString(),
                        style: TextStyle(
                          fontSize: isSmallScreen ? 8 : 10,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                      );
                    },
                  )
                else
                  Text(
                    '评论',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 8 : 10,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaybackSpeedButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<double>(
      stream: _audioService!.speedStream,
      builder: (context, snapshot) {
        final speed = snapshot.data ?? 1.0;
        final speedText = speed.toStringAsFixed(2);

        return InkWell(
          onTap: () => _showPlaybackSpeedDialog(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.speed,
                  color: speed != 1.0
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  size: isSmallScreen ? 22 : 24,
                ),
                const SizedBox(height: 4),
                Text(
                  '${speedText}x',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 8 : 10,
                    fontWeight:
                        speed != 1.0 ? FontWeight.bold : FontWeight.normal,
                    color: speed != 1.0
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPlaybackSpeedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StreamBuilder<double>(
          stream: _audioService!.speedStream,
          builder: (context, snapshot) {
            final currentSpeed = snapshot.data ?? 1;

            return AlertDialog(
              title: const Text('播放速度'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      value: currentSpeed,
                      min: 0.25,
                      max: 3.0,
                      divisions: 11, // 0.25的倍数
                      label: '${currentSpeed.toStringAsFixed(2)}x',
                      onChanged: (value) {
                        _audioService!.setPlaybackSpeed(value);
                      },
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((speed) {
                        return ElevatedButton(
                          onPressed: () {
                            _audioService!.setPlaybackSpeed(speed);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: currentSpeed == speed
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            foregroundColor: currentSpeed == speed
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                          child: Text('${speed}x'),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('关闭'),
                ),
              ],
            );
          }),
    );
  }

  Widget _buildDownloadButton(BuildContext context, bool isSmallScreen) {
    return StreamBuilder<SequenceState?>(
        stream: _audioService!.player.sequenceStateStream,
        builder: (context, snapshot) {
          final src = snapshot.data?.currentSource;
          final bvid = src?.tag.extras['bvid'] as String?;
          final cid = src?.tag.extras['cid'] as int?;

          if (bvid == null || cid == null) {
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_outlined,
                      size: isSmallScreen ? 22 : 24,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '下载',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 8 : 10,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return FutureBuilder(
              future: DownloadManager.instance,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const SizedBox.shrink();
                }
                final dm = snapshot.data!;
                return StreamBuilder<Map<String, DownloadTask>>(
                  stream: dm.tasksStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    DownloadTask? task;

                    final tasks =
                        snapshot.data!.values.toList().reversed.toList();
                    for (final t in tasks) {
                      if (t.bvid == bvid && t.cid == cid) {
                        task = t;
                      }
                    }

                    return InkWell(
                      onTap: () async {
                        if (task == null) {
                          final title = src?.tag.title ?? "未知标题";
                          await showDialog(
                            context: context,
                            builder: (context) => DownloadPartsDialog(
                              bvid: bvid,
                              title: title,
                            ),
                          );
                        } else if (task.status == DownloadStatus.completed) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('已下载'),
                              content: const Text('是否要删除已下载的文件？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    final dm = await DownloadManager.instance;
                                    await dm.removeDownloaded([(bvid, cid)]);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('已删除下载文件'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              task?.status == DownloadStatus.completed
                                  ? Icons.download_done
                                  : task?.status == DownloadStatus.downloading
                                      ? Icons.download
                                      : task?.status == DownloadStatus.paused
                                          ? Icons.pause
                                          : task?.status ==
                                                  DownloadStatus.failed
                                              ? Icons.error
                                              : Icons.download_outlined,
                              color: task?.status == DownloadStatus.completed
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              size: isSmallScreen ? 22 : 24,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              task == null
                                  ? '下载'
                                  : task.status == DownloadStatus.completed
                                      ? '已下载'
                                      : task.status ==
                                              DownloadStatus.downloading
                                          ? '下载中'
                                          : task.status == DownloadStatus.paused
                                              ? '已暂停'
                                              : task.status ==
                                                      DownloadStatus.failed
                                                  ? '下载失败'
                                                  : '等待中',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 8 : 10,
                                fontWeight:
                                    task?.status == DownloadStatus.completed
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                color: task?.status == DownloadStatus.completed
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              });
        });
  }

  Future<void> _loadSubtitles(int aid, int cid) async {
    final token = ++_subtitleLoadToken;
    final subtitleKey = '${aid}_$cid';

    final cachedTracks = _subtitleTracksCache[subtitleKey];
    if (cachedTracks != null) {
      if (cachedTracks.isEmpty) {
        setState(() {
          _subtitles = [];
          _showSubtitles = true;
        });
        return;
      }
      await _loadSubtitleTrack(
          cachedTracks, _subtitleTrackIndexCache[subtitleKey] ?? 0, token);
      return;
    }

    final bilibiliService = await BilibiliService.instance;
    final tracks = await bilibiliService.getSubTitleInfo(aid, cid);

    if (!mounted || token != _subtitleLoadToken) return;

    if (tracks != null && tracks.isNotEmpty) {
      _subtitleTracksCache[subtitleKey] = tracks;
      // 默认优先选择人工上传字幕；AI 自动生成字幕会把音乐识别为
      // “♪音乐♪”，只有没有人工字幕时才回退到它（issue #13）
      var defaultIndex = tracks.indexWhere((t) => !t.$1.contains('自动生成'));
      if (defaultIndex == -1) defaultIndex = tracks.length - 1;
      _subtitleTrackIndexCache[subtitleKey] = defaultIndex;
      await _loadSubtitleTrack(tracks, defaultIndex, token);
    } else {
      _subtitleTracksCache[subtitleKey] = [];
      setState(() {
        _subtitles = [];
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有找到字幕'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 加载指定字幕轨道的数据
  Future<void> _loadSubtitleTrack(
      List<(String, String)> tracks, int index, int token) async {
    if (index < 0 || index >= tracks.length) return;
    final url = tracks[index].$2;
    final cached = _subtitleCache[url];
    if (cached != null) {
      setState(() {
        _subtitles = cached;
        _showSubtitles = true;
      });
      return;
    }
    final bilibiliService = await BilibiliService.instance;
    final subtitleData = await bilibiliService.getSubTitleData(url);
    if (subtitleData != null && mounted && token == _subtitleLoadToken) {
      _subtitleCache[url] = subtitleData;
      setState(() {
        _subtitles = subtitleData;
        _showSubtitles = true;
      });
    }
  }

  /// 切换当前视频的字幕轨道（issue #13）
  Future<void> _switchSubtitleTrack(int index) async {
    final key = currentKey;
    if (key == null) return;
    final tracks = _subtitleTracksCache[key];
    if (tracks == null || index < 0 || index >= tracks.length) return;
    if (_subtitleTrackIndexCache[key] == index && _subtitles != null) return;
    _subtitleTrackIndexCache[key] = index;
    final token = ++_subtitleLoadToken;
    setState(() {
      _subtitles = null;
    });
    await _loadSubtitleTrack(tracks, index, token);
  }

  /// 字幕轨道选择器（多轨字幕时显示在歌词上方）
  Widget _buildSubtitleTrackSelector(List<(String, String)> tracks) {
    final key = currentKey ?? '';
    final selected = _subtitleTrackIndexCache[key] ?? 0;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.subtitles_outlined, size: 16, color: colorScheme.secondary),
        const SizedBox(width: 4),
        PopupMenuButton<int>(
          tooltip: '选择字幕',
          onSelected: (index) => _switchSubtitleTrack(index),
          itemBuilder: (context) => [
            for (var i = 0; i < tracks.length; i++)
              PopupMenuItem<int>(
                value: i,
                child: Row(
                  children: [
                    i == selected
                        ? Icon(Icons.check,
                            size: 18, color: colorScheme.primary)
                        : const SizedBox(width: 18),
                    const SizedBox(width: 8),
                    Text(tracks[i].$1),
                  ],
                ),
              ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                selected < tracks.length ? tracks[selected].$1 : '',
                style: TextStyle(fontSize: 13, color: colorScheme.secondary),
              ),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: colorScheme.secondary),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubtitlesView() {
    return StreamBuilder<SequenceState?>(
      stream: _audioService!.player.sequenceStateStream,
      builder: (context, sequenceSnapshot) {
        final src = sequenceSnapshot.data?.currentSource;
        final currentAid = src?.tag.extras['aid'] as int?;
        final currentCid = src?.tag.extras['cid'] as int?;

        if (currentAid == null || currentCid == null) {
          return Center(
            child: Text(
              '歌曲信息暂未加载',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          );
        }

        // 检查字幕是否与当前播放的视频匹配
        if ('${currentAid}_$currentCid' != currentKey) {
          currentKey = '${currentAid}_$currentCid';
          Future.microtask(() => _loadSubtitles(currentAid, currentCid));

          if (_subtitles == null) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        }

        final tracks = _subtitleTracksCache[currentKey ?? ''];
        return GestureDetector(
          onTap: () {
            setState(() {
              _showSubtitles = false;
              _subtitles = null;
            });
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 多轨字幕时提供切换入口（人工/AI/多语言，issue #13）
              if (tracks != null && tracks.length > 1)
                _buildSubtitleTrackSelector(tracks),
              StreamBuilder<Duration>(
                stream: _audioService!.player.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data?.inMilliseconds ?? 0;

                  if (_subtitles == null) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  if (_subtitles!.isEmpty) {
                    return Center(
                      child: Text(
                        '暂无歌词',
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    );
                  }

                  const subTitleHeight = 36.0;

                  // 找到当前歌词索引
                  final currentIndex = _subtitles!.indexWhere((subtitle) =>
                      position >= subtitle.from && position <= subtitle.to);

                  // 自动滚动到当前歌词
                  if (currentIndex != -1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!_subtitleScrollController.hasClients) return;
                      if (_subtitleScrollController
                          .position.isScrollingNotifier.value) {
                        return;
                      }

                      _subtitleScrollController.scrollToIndex(
                        currentIndex,
                        preferPosition: AutoScrollPosition.middle,
                        duration: const Duration(milliseconds: 300),
                      );
                    });
                  }

                  return SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: ListView.builder(
                      controller: _subtitleScrollController,
                      padding: const EdgeInsets.symmetric(vertical: 80),
                      itemCount: _subtitles!.length,
                      physics: const ClampingScrollPhysics(),
                      itemBuilder: (context, index) {
                        final subtitle = _subtitles![index];
                        final isActive = position >= subtitle.from &&
                            position <= subtitle.to;
                        final isNext = index == currentIndex + 1;

                        return AutoScrollTag(
                          key: ValueKey(index),
                          index: index,
                          controller: _subtitleScrollController,
                          child: Container(
                            constraints:
                                const BoxConstraints(minHeight: subTitleHeight),
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 24),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 300),
                              style: TextStyle(
                                fontSize: isActive ? 18 : (isNext ? 15 : 14),
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isActive
                                    ? Theme.of(context).colorScheme.primary
                                    : (isNext
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.8)
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5)),
                                height: 1.2,
                              ),
                              child: Center(
                                  child: GestureDetector(
                                onTap: () {
                                  // 点击歌词跳转到对应时间
                                  _audioService!.player.seek(
                                      Duration(milliseconds: subtitle.from));
                                },
                                child: Text(
                                  subtitle.content,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _dismissAnimController?.dispose();
    _sequenceStateSubscription?.cancel();
    _commentCache.clear();
    _subtitleScrollController.dispose();
    super.dispose();
  }
}

class _PositionProgressBar extends StatelessWidget {
  final AudioPlayer player;
  final bool isSmallScreen;

  const _PositionProgressBar({
    required this.player,
    required this.isSmallScreen,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(isSmallScreen ? 10.0 : 20.0),
      child: StreamBuilder<(Duration, Duration, Duration?)>(
        stream: Rx.combineLatest3(
          player.positionStream,
          player.bufferedPositionStream,
          player.durationStream,
          (position, bufferedPosition, duration) =>
              (position, bufferedPosition, duration),
        ),
        builder: (context, snapshot) {
          final state = snapshot.data ??
              (player.position, player.bufferedPosition, player.duration);
          return ProgressBar(
            progress: state.$1,
            buffered: state.$2,
            total: state.$3 ?? Duration.zero,
            onSeek: player.seek,
            barHeight: 5,
            timeLabelTextStyle: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 10,
            ),
            timeLabelPadding: 5,
            thumbRadius: 5,
          );
        },
      ),
    );
  }
}
