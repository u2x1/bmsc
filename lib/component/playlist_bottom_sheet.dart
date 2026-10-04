import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../database_manager.dart';
import '../screen/user_detail_screen.dart';
import 'select_favlist_dialog.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class PlaylistBottomSheet extends StatefulWidget {
  const PlaylistBottomSheet({super.key});

  @override
  State<PlaylistBottomSheet> createState() => _PlaylistBottomSheetState();
}

class _PlaylistBottomSheetState extends State<PlaylistBottomSheet> {
  /// 双行 dense ListTile 的自然高度约 56，行高取 56 避免副标题被裁切，
  /// 同时满足 48dp 以上的触控高度
  static const double _rowHeight = 56;

  /// 在列表首次构建前（拿到 service 与视口高度后）创建，带
  /// initialScrollOffset 直接定位到当前项附近——列表第一帧就只构建
  /// 目标窗口，不再经历「先建顶部窗口、再跳转」的两个重帧。
  AutoScrollController? _scrollController;
  bool _switching = false;

  /// 批量管理模式：以「id_bvid_cid」作为选中项标识（下标会随增删重排漂移）
  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};

  /// 映射回原始序列下标的当前播放项（shuffle 不改变 currentIndex
  /// 的原始序语义，直接使用即可）
  int? _currentIndex;

  /// 「回到当前播放」浮动按钮仅当当前项滚出视口时显示
  bool _showLocate = false;

  /// 撤销/提示条：ScaffoldMessenger 的 SnackBar 会被 modal bottom sheet
  /// 遮挡，删除/屏蔽/收藏的反馈改由 sheet 内嵌的提示条呈现
  String? _noticeMessage;
  Future<void> Function()? _noticeUndo;
  Timer? _noticeTimer;

  void _showNotice(String message, [Future<void> Function()? undo]) {
    _noticeTimer?.cancel();
    setState(() {
      _noticeMessage = message;
      _noticeUndo = undo;
    });
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _noticeMessage = null;
          _noticeUndo = null;
        });
      }
    });
  }

  String _keyOf(dynamic tag) {
    final extras = tag.extras as Map<String, dynamic>?;
    return '${tag.id}_${extras?['bvid']}_${extras?['cid']}';
  }

  /// 目标项大致居中的初始偏移。[viewportHeight] 为列表可视区高度。
  double _initialOffsetFor(int? index, double viewportHeight) {
    if (index == null || index <= 0) return 0;
    final vp = viewportHeight.isFinite && viewportHeight > _rowHeight
        ? viewportHeight
        : 0.0;
    final centered = index * _rowHeight - (vp - _rowHeight) / 2;
    return centered > 0 ? centered : 0;
  }

  @override
  void initState() {
    super.initState();
    // 初次构建后把当前播放项精确居中。列表已按 initialScrollOffset
    // 预定位，这里通常只做小幅修正；等待 controller 挂载（同
    // scroll_to_index 内部的等待逻辑）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final service = await AudioService.instance;
      final currentIndex =
          _originalIndex(service.player, service.player.sequenceState);
      if (currentIndex == null || !mounted) return;
      for (var i = 0; i < 30 && (_scrollController?.hasClients != true); i++) {
        await WidgetsBinding.instance.endOfFrame;
      }
      final controller = _scrollController;
      if (!mounted || controller == null || !controller.hasClients) return;
      controller.scrollToIndex(currentIndex,
          preferPosition: AutoScrollPosition.middle);
    });
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _scrollController?.dispose();
    super.dispose();
  }

  /// 当前播放项的原始（未打乱）序列下标。
  ///
  /// 注意：sequenceState.currentIndex 本就是原始序列下标——与
  /// seek(index:)、原生端 getCurrentMediaItemIndex() 同为 playlist 序
  /// 语义，shuffle 只影响播放推进顺序（effectiveIndices 描述乱序表），
  /// 不改变 currentIndex 的含义。原实现误把 currentIndex 当作乱序位置
  /// 再经 effectiveIndices 换算，shuffle 下高亮与「回到当前播放」
  /// 会指到错误曲目（切到随机模式后播放列表正在播放项对不上）。
  int? _originalIndex(AudioPlayer player, SequenceState? state) {
    return state?.currentIndex;
  }

  void _updateLocate() {
    final c = _scrollController;
    final cur = _currentIndex;
    final show = c != null &&
        c.hasClients &&
        cur != null &&
        () {
          final first = (c.offset / _rowHeight).floor();
          final last =
              ((c.offset + c.position.viewportDimension) / _rowHeight).ceil() -
                  1;
          return cur < first || cur > last;
        }();
    if (show != _showLocate && mounted) {
      setState(() => _showLocate = show);
    }
  }

  static String _formatTotal(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:$ss'
        : '$m:$ss';
  }

  /// 删除单项 + 撤销（滑动手势与长按菜单共用）
  Future<void> _removeAt(AudioService service,
      List<IndexedAudioSource> playlist, int index) async {
    final removedSource = playlist[index];
    await service.mutatePlaylist(() async {
      await service.playlist.removeAt(index);
    });
    if (!mounted) return;
    _showNotice('已从播放列表删除', () async {
      await service.mutatePlaylist(() async {
        if (index <= service.playlist.length) {
          await service.playlist.insert(index, removedSource);
        } else {
          await service.playlist.add(removedSource);
        }
      });
    });
  }

  /// 屏蔽分 P + 撤销（长按菜单）
  Future<void> _blockPart(AudioService service,
      List<IndexedAudioSource> playlist, int index) async {
    final item = playlist[index].tag;
    final bvid = item.extras['bvid'] as String;
    final cid = item.extras['cid'] as int;
    final removedSource = playlist[index];
    await DatabaseManager.addExcludedPart(bvid, cid);
    await service.mutatePlaylist(() async {
      await service.playlist.removeAt(index);
    });
    if (!mounted) return;
    _showNotice('已屏蔽该分 P', () async {
      await DatabaseManager.removeExcludedPart(bvid, cid);
      await service.mutatePlaylist(() async {
        if (index <= service.playlist.length) {
          await service.playlist.insert(index, removedSource);
        } else {
          await service.playlist.add(removedSource);
        }
      });
    });
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedKeys.clear();
    });
  }

  /// 批量删除：先按 key 解析出下标快照，降序 removeAt 避免位移
  Future<void> _deleteSelected(AudioService service,
      List<IndexedAudioSource> playlist) async {
    final indices = <int>[
      for (var i = 0; i < playlist.length; i++)
        if (_selectedKeys.contains(_keyOf(playlist[i].tag))) i,
    ];
    if (indices.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除所选'),
        content: Text('确定要从播放列表删除 ${indices.length} 首歌曲吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = [for (final i in indices) playlist[i]];
    await service.mutatePlaylist(() async {
      for (var k = indices.length - 1; k >= 0; k--) {
        await service.playlist.removeAt(indices[k]);
      }
    });
    _toggleSelectionMode();
    if (!mounted) return;
    _showNotice('已删除 ${removed.length} 首歌曲', () async {
      await service.mutatePlaylist(() async {
        for (var k = 0; k < indices.length; k++) {
          if (indices[k] <= service.playlist.length) {
            await service.playlist.insert(indices[k], removed[k]);
          } else {
            await service.playlist.add(removed[k]);
          }
        }
      });
    });
  }

  /// 长按菜单：查看 UP 主 / 收藏 / 屏蔽该分 P / 删除
  void _showItemMenu(AudioService service, List<IndexedAudioSource> playlist,
      int index) {
    final item = playlist[index].tag;
    final extras = item.extras as Map<String, dynamic>? ?? {};
    final mid = extras['mid'] as int?;
    final aid = extras['aid'] as int?;
    final isMulti = extras['multi'] == true;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mid != null)
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('查看 UP 主'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => UserDetailScreen(mid: mid),
                    ),
                  );
                },
              ),
            if (aid != null)
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: const Text('收藏'),
                onTap: () async {
                  Navigator.pop(dialogContext);
                  final folder = await showDialog<Fav>(
                    context: context,
                    builder: (context) => const SelectFavlistDialog(),
                  );
                  if (folder == null || !mounted) return;
                  final success = await BilibiliService.instance.then(
                          (x) => x.favoriteVideo(aid, [folder.id], [])) ??
                      false;
                  if (!mounted) return;
                  _showNotice(success ? '已收藏' : '操作失败');
                },
              ),
            if (isMulti)
              ListTile(
                leading: const Icon(Icons.visibility_off),
                title: const Text('屏蔽该分 P'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _blockPart(service, playlist, index);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(dialogContext).colorScheme.error),
              title: Text('从播放列表删除',
                  style:
                      TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
              onTap: () {
                Navigator.pop(dialogContext);
                _removeAt(service, playlist, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 拖拽中的行：圆角 + 阴影浮起
  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        return Material(
          elevation: lerpDouble(0, 6, t) ?? 0,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: child,
        );
      },
      child: child,
    );
  }

  Widget _buildTitle(dynamic item, bool isPlaying) {
    final extras = item.extras as Map<String, dynamic>? ?? {};
    return Row(
      children: [
        if (extras['dummy'] ?? false)
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Tooltip(
              message: '待加载',
              child: Icon(Icons.hourglass_empty, size: 12),
            ),
          ),
        Flexible(
          child: Text(
            item.title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isPlaying
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (extras['cached'] ?? false)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Tooltip(
              message: '已缓存',
              child: Icon(Icons.check_circle,
                  size: 16, color: Theme.of(context).colorScheme.tertiary),
            ),
          ),
      ],
    );
  }

  Widget _buildSubtitle(dynamic item) {
    final extras = item.extras as Map<String, dynamic>? ?? {};
    return Row(
      children: [
        if (extras['multi'] ?? false) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.album, size: 12),
          ),
          Flexible(
            child: Text(
              extras['raw_title'] as String? ?? '',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ] else
          Flexible(
            child: Text(
              item.artist ?? '',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildNormalTile(AudioService service,
      List<IndexedAudioSource> playlist, int index, bool playing) {
    final item = playlist[index].tag;
    final isPlaying = _currentIndex == index;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      minLeadingWidth: 28,
      selected: isPlaying,
      selectedTileColor:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
      leading: SizedBox(
        width: 28,
        child: Center(
          child: isPlaying
              ? _PlayingIndicator(playing: playing)
              : Text('${index + 1}',
                  style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
      title: _buildTitle(item, isPlaying),
      subtitle: _buildSubtitle(item),
      trailing: ReorderableDragStartListener(
        index: index,
        child: const Padding(
          // 扩大拖拽手柄触控区至 48dp
          padding: EdgeInsets.all(12),
          child: Icon(Icons.drag_handle, size: 24),
        ),
      ),
      onTap: () async {
        // 防止快速重复点击导致多次 seek
        if (_switching) {
          return;
        }
        _switching = true;
        try {
          // 持互斥定位：防在途解析/预解析的插入删除使目标索引错位
          await service.mutatePlaylist(
              () async => service.player.seek(Duration.zero, index: index));
          await service.player.play();
        } finally {
          _switching = false;
        }
      },
      onLongPress: () => _showItemMenu(service, playlist, index),
    );
  }

  Widget _buildSelectionTile(List<IndexedAudioSource> playlist, int index) {
    final item = playlist[index].tag;
    final key = _keyOf(item);
    final selected = _selectedKeys.contains(key);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.only(left: 4, right: 16),
      minLeadingWidth: 40,
      selected: selected,
      selectedTileColor:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
      leading: Checkbox(
        value: selected,
        visualDensity: VisualDensity.compact,
        onChanged: (_) => setState(() {
          selected ? _selectedKeys.remove(key) : _selectedKeys.add(key);
        }),
      ),
      title: _buildTitle(item, false),
      subtitle: _buildSubtitle(item),
      onTap: () => setState(() {
        selected ? _selectedKeys.remove(key) : _selectedKeys.add(key);
      }),
    );
  }

  Widget _buildHeader(AudioService service) {
    if (_selectionMode) {
      return ListTile(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出批量管理',
          onPressed: _toggleSelectionMode,
        ),
        title: Text('已选 ${_selectedKeys.length} 项'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () {
                final playlist = service.player.sequence;
                setState(() {
                  if (_selectedKeys.length == playlist.length) {
                    _selectedKeys.clear();
                  } else {
                    _selectedKeys
                      ..clear()
                      ..addAll(playlist.map((s) => _keyOf(s.tag)));
                  }
                });
              },
              child: const Text('全选'),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除所选',
              color: Theme.of(context).colorScheme.error,
              onPressed: _selectedKeys.isEmpty
                  ? null
                  : () => _deleteSelected(service, service.player.sequence),
            ),
          ],
        ),
      );
    }
    return ListTile(
      title: StreamBuilder<(int, int)>(
        // 数量与总时长变化时才重建标题
        stream: service.player.sequenceStream.map((s) {
          var secs = 0;
          for (final src in s) {
            final duration = src.tag?.duration as Duration?;
            if (duration != null) secs += duration.inSeconds;
          }
          return (s.length, secs);
        }).distinct(),
        builder: (_, snapshot) {
          final (count, secs) = snapshot.data ?? (0, 0);
          return Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              secs > 0
                  ? '播放列表 ($count) · ${_formatTotal(secs)}'
                  : '播放列表 ($count)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.8),
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.playlist_remove, size: 20),
            tooltip: '清空',
            style: const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (service.playlist.length == 0) {
                return;
              }
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空播放列表'),
                  content: const Text('确定要清空播放列表吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        service.mutatePlaylist(() async {
                          await service.playlist.clear();
                        });
                        Navigator.pop(context);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.checklist, size: 20),
            tooltip: '批量管理',
            style: const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: service.playlist.length == 0
                ? null
                : _toggleSelectionMode,
          ),
          StreamBuilder<(LoopMode, bool)>(
            stream: Rx.combineLatest2(
              service.player.loopModeStream,
              service.player.shuffleModeEnabledStream,
              (a, b) => (a, b),
            ),
            builder: (context, snapshot) {
              final (loopMode, shuffleModeEnabled) =
                  snapshot.data ?? (LoopMode.off, false);
              const icons = [
                Icons.playlist_play,
                Icons.repeat_one,
                Icons.repeat,
                Icons.shuffle,
              ];
              const labels = ['顺序播放', '单曲循环', '列表循环', '随机播放'];
              final index = shuffleModeEnabled
                  ? 3
                  : LoopMode.values.indexOf(loopMode);

              return IconButton(
                icon: Icon(
                  icons[index],
                  size: 20,
                  // 非默认模式用主题色标识激活态
                  color: index == 0
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
                tooltip: labels[index],
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  final idx = (index + 1) % icons.length;

                  if (idx == 3) {
                    service.player.setShuffleModeEnabled(true);
                  } else {
                    service.player.setLoopMode(LoopMode.values[idx]);
                    service.player.setShuffleModeEnabled(false);
                  }
                },
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: AudioService.instance,
        builder: (context, snapshot) {
          final service = snapshot.data;
          if (service == null) {
            // 加载占位：避免弹层先闪一个空壳
            return const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          // 列表首次构建前创建 controller 并预定位到当前项附近：
          // 视口高度按弹层上限（屏高 70%）减头部与拖拽手柄估算，
          // 首帧即可只构建目标窗口；精确居中由 initState 的回调修正。
          final controller = _scrollController ??= AutoScrollController(
            suggestedRowHeight: _rowHeight,
            initialScrollOffset: _initialOffsetFor(
              _originalIndex(service.player, service.player.sequenceState),
              MediaQuery.of(context).size.height * 0.7 - 96,
            ),
          )..addListener(_updateLocate);
          return PopScope(
            // 批量管理模式下拦截返回手势：先退出模式而非关闭弹层
            canPop: !_selectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _toggleSelectionMode();
            },
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(service),

                  // Playlist
                  Flexible(
                    child: StreamBuilder<List<IndexedAudioSource>?>(
                      stream: service.player.sequenceStream,
                      builder: (_, snapshot) {
                        final playlist = snapshot.data;
                        if (playlist == null || playlist.isEmpty) {
                          final colorScheme = Theme.of(context).colorScheme;
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 32, horizontal: 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.queue_music,
                                    size: 48, color: colorScheme.outline),
                                const SizedBox(height: 12),
                                Text('暂无歌曲',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall),
                                const SizedBox(height: 4),
                                Text('从收藏夹、动态或搜索中添加歌曲',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: colorScheme.secondary)),
                                const SizedBox(height: 16),
                                FilledButton.tonal(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('去逛逛'),
                                ),
                              ],
                            ),
                          );
                        }

                        // 外层监听一次播放状态，避免每行单独订阅；
                        // 映射为 (原始下标, playing) 后 distinct——
                        // buffering 等无关状态抖动不再触发整表重建
                        return StreamBuilder<(int?, bool)>(
                          stream: Rx.combineLatest2(
                            service.player.sequenceStateStream,
                            service.player.playerStateStream,
                            (a, b) => (a, b),
                          ).map((s) => (
                                _originalIndex(service.player, s.$1),
                                s.$2.playing,
                              )).distinct(),
                          builder: (_, stateSnapshot) {
                            _currentIndex = stateSnapshot.data?.$1;
                            final playing = stateSnapshot.data?.$2 ?? false;
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) => _updateLocate());

                            // 高度 = 行数 × 固定行高（由 Flexible 约束裁剪），
                            // 短列表仍贴合内容；固定 itemExtent + 非 shrinkWrap
                            // 视口让滚动偏移精确、布局只走一趟
                            return SizedBox(
                              height: playlist.length * _rowHeight,
                              child: Stack(
                                children: [
                                  Scrollbar(
                                    controller: controller,
                                    thumbVisibility: true,
                                    interactive: true,
                                    radius: const Radius.circular(4),
                                    child: _selectionMode
                                        ? ListView.builder(
                                            controller: controller,
                                            itemExtent: _rowHeight,
                                            itemCount: playlist.length,
                                            itemBuilder: (context, index) =>
                                                KeyedSubtree(
                                              key: ValueKey(
                                                  'sel_${_keyOf(playlist[index].tag)}'),
                                              child: _buildSelectionTile(
                                                  playlist, index),
                                            ),
                                          )
                                        : ReorderableListView.builder(
                                            scrollController: controller,
                                            itemExtent: _rowHeight,
                                            // 关闭默认整行长按拖拽，避免与长按菜单冲突；
                                            // 拖拽仅由行尾手柄触发
                                            buildDefaultDragHandles: false,
                                            proxyDecorator: _proxyDecorator,
                                            itemCount: playlist.length,
                                            onReorderItem:
                                                (oldIndex, newIndex) async {
                                              // Flutter 3.41+ 的 onReorderItem 已把
                                              // newIndex 调整为「移除后插入」的最终下标
                                              //（旧 onReorder 才需要手动 -1），
                                              // 直接传给 move 即可
                                              await service.mutatePlaylist(
                                                  () async {
                                                await service.playlist
                                                    .move(oldIndex, newIndex);
                                              });
                                            },
                                            itemBuilder: (context, index) {
                                              final key = _keyOf(
                                                  playlist[index].tag);
                                              return Dismissible(
                                                key: ValueKey('del_$key'),
                                                direction:
                                                    DismissDirection.endToStart,
                                                background: Container(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  padding: const EdgeInsets
                                                      .only(right: 20),
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .errorContainer,
                                                  child: Icon(
                                                    Icons.delete_outline,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onErrorContainer,
                                                  ),
                                                ),
                                                onDismissed: (_) => _removeAt(
                                                    service, playlist, index),
                                                child: AutoScrollTag(
                                                  key: ValueKey(key),
                                                  index: index,
                                                  controller: controller,
                                                  child: _buildNormalTile(
                                                      service,
                                                      playlist,
                                                      index,
                                                      playing),
                                                ),
                                              );
                                            },
                                          ),
                                  ),
                                  if (_showLocate &&
                                      _currentIndex != null &&
                                      !_selectionMode &&
                                      _noticeMessage == null)
                                    Positioned(
                                      bottom: 12,
                                      left: 0,
                                      right: 0,
                                      child: Center(
                                        child: FilledButton.tonalIcon(
                                          style: FilledButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          icon: const Icon(Icons.music_note,
                                              size: 18),
                                          label: const Text('当前播放'),
                                          onPressed: () =>
                                              controller.scrollToIndex(
                                                  _currentIndex!,
                                                  preferPosition:
                                                      AutoScrollPosition
                                                          .middle),
                                        ),
                                      ),
                                    ),
                                  // 撤销/提示条：样式对齐 SnackBar
                                  if (_noticeMessage != null)
                                    Positioned(
                                      bottom: 12,
                                      left: 16,
                                      right: 16,
                                      child: Material(
                                        elevation: 6,
                                        borderRadius: BorderRadius.circular(4),
                                        color: Theme.of(context)
                                            .colorScheme
                                            .inverseSurface,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 6),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _noticeMessage!,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color:
                                                            Theme.of(context)
                                                                .colorScheme
                                                                .onInverseSurface,
                                                      ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (_noticeUndo != null)
                                                TextButton(
                                                  onPressed: () {
                                                    final undo = _noticeUndo;
                                                    _noticeTimer?.cancel();
                                                    setState(() {
                                                      _noticeMessage = null;
                                                      _noticeUndo = null;
                                                    });
                                                    undo?.call();
                                                  },
                                                  child: Text(
                                                    '撤销',
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .inversePrimary,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        });
  }
}

/// 正在播放行的动画均衡器指示器：播放时三根柱子起伏，暂停时收成静态低柱
class _PlayingIndicator extends StatefulWidget {
  const _PlayingIndicator({required this.playing});

  final bool playing;

  @override
  State<_PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<_PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(_PlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _barValue(int i) {
    final phase = (_controller.value + i / 3) % 1.0;
    final t = phase < 0.5 ? phase * 2 : 2 - phase * 2;
    return 0.3 + 0.7 * t;
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    // 75 次/秒的动画重绘隔离在自身 layer，不带动整行重绘
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                  child: Container(
                    width: 3,
                    height: 6 + 10 * _barValue(i),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
