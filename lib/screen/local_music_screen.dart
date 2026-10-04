import 'dart:async';
import 'dart:io';

import 'package:bmsc/component/track_tile.dart';
import 'package:bmsc/model/local_track.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/local_music_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:bmsc/util/string.dart' as str_util;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

final _logger = LoggerUtils.getLogger('LocalMusicScreen');

/// 曲库排序方式
enum _SortOrder { importDesc, importAsc, title, artist }

extension on _SortOrder {
  String get label => switch (this) {
        _SortOrder.importDesc => '按导入时间（新→旧）',
        _SortOrder.importAsc => '按导入时间（旧→新）',
        _SortOrder.title => '按标题',
        _SortOrder.artist => '按艺术家',
      };

  String get sql => switch (this) {
        _SortOrder.importDesc => 'createdAt DESC, id DESC',
        _SortOrder.importAsc => 'createdAt ASC, id ASC',
        _SortOrder.title => 'title COLLATE NOCASE ASC, id ASC',
        _SortOrder.artist => 'artist COLLATE NOCASE ASC, title COLLATE NOCASE ASC, id ASC',
      };
}

/// 本地音乐曲库页：导入/搜索/排序/播放/删除管理。
/// 播放接入统一播放队列（随机/循环/倍速/定时停止/后台通知均可用）。
class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});

  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  List<LocalTrack> _tracks = [];
  bool _loading = true;
  bool _importing = false;
  String _query = '';
  _SortOrder _sort = _SortOrder.importDesc;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tracks = await LocalMusicService.getTracks(orderBy: _sort.sql);
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _loading = false;
    });
  }

  List<LocalTrack> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _tracks;
    return _tracks
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.album.toLowerCase().contains(q))
        .toList();
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// 当前正在播放的本地文件路径（删除保护）
  Future<String?> _playingLocalPath() async {
    final service = await AudioService.instance;
    final extras = service.player.sequenceState.currentSource?.tag?.extras;
    if (extras == null || extras['local'] != true) return null;
    return extras['filePath'] as String?;
  }

  Future<void> _play(List<LocalTrack> tracks, int index) async {
    final service = await AudioService.instance;
    await service.playLocalTracks(tracks, index: index);
  }

  Future<void> _playAll({bool shuffle = false}) async {
    if (_tracks.isEmpty) return;
    final service = await AudioService.instance;
    await service.playLocalTracks(_tracks, shuffle: shuffle);
  }

  Future<void> _import({required bool folder}) async {
    await _runImportWithProgress(
      '正在导入',
      (onProgress) => folder
          ? LocalMusicService.importFolder(onProgress: onProgress)
          : LocalMusicService.importFiles(onProgress: onProgress),
    );
  }

  /// 自动扫描设备曲库（Android 公共存储 / 桌面 Music 目录）。
  /// 先申请权限，拒绝时给出引导（iOS 平台不支持，入口不显示）。
  Future<void> _scan() async {
    if (_importing) return;
    final granted = await LocalMusicService.ensureScanPermission();
    if (!mounted) return;
    if (!granted) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('需要权限'),
          content: const Text('自动扫描需要访问设备中的音频文件，请在系统设置中授予权限。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      return;
    }
    await _runImportWithProgress(
      '正在扫描设备音乐',
      (onProgress) => LocalMusicService.scanDevice(onProgress: onProgress),
    );
  }

  /// 导入/扫描共用的进度对话框流程：不可取消（复制/哈希中途中断会
  /// 留下半成品），完成后 SnackBar 汇报新增/跳过/失败并刷新列表
  Future<void> _runImportWithProgress(
    String title,
    Future<ImportResult> Function(void Function(int done, int total)) task,
  ) async {
    if (_importing) return;
    setState(() => _importing = true);
    var done = 0, total = 0;
    final progressNotifier = ValueNotifier<(int, int)>((0, 0));
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progressNotifier,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: value.$2 > 0 ? value.$1 / value.$2 : null,
                ),
                const SizedBox(height: 12),
                Text(value.$2 > 0 ? '${value.$1} / ${value.$2}' : '正在扫描…'),
              ],
            ),
          ),
        ),
      ),
    ));
    try {
      final result = await task((d, t) {
        done = d;
        total = t;
        progressNotifier.value = (d, t);
      });
      _logger.info('import finished: $done/$total, $result');
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭进度对话框
      final parts = <String>[
        if (result.added > 0) '新增 ${result.added} 首',
        if (result.skipped > 0) '跳过重复 ${result.skipped} 首',
        if (result.failed > 0) '失败 ${result.failed} 首',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(parts.isEmpty ? '未选择文件' : parts.join('，'))),
      );
      if (result.added > 0) await _load();
    } catch (e) {
      _logger.severe('import error', e);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入失败')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _showImportMenu() {
    showDialog(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('导入本地音乐'),
        children: [
          // iOS 无共享文件系统，无法自动扫描设备曲库
          if (LocalMusicService.supportsDeviceScan)
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: const Text('自动扫描设备音乐'),
              subtitle: Text(Platform.isAndroid
                  ? '扫描 Music 与 Download 目录'
                  : '扫描系统音乐目录'),
              onTap: () {
                Navigator.pop(dialogContext);
                _scan();
              },
            ),
          ListTile(
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('选择音频文件'),
            subtitle: const Text('可多选，文件将复制到应用数据目录'),
            onTap: () {
              Navigator.pop(dialogContext);
              _import(folder: false);
            },
          ),
          // Android 的目录选择返回 content:// URI，无法按路径扫描
          if (!Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('扫描文件夹'),
              subtitle: const Text('递归导入文件夹内的全部音频'),
              onTap: () {
                Navigator.pop(dialogContext);
                _import(folder: true);
              },
            ),
        ],
      ),
    );
  }

  void _showSortMenu() {
    showDialog(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('排序方式'),
        children: [
          RadioGroup<_SortOrder>(
            groupValue: _sort,
            onChanged: (value) {
              if (value == null) return;
              Navigator.pop(dialogContext);
              setState(() => _sort = value);
              _load();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final order in _SortOrder.values)
                  RadioListTile<_SortOrder>(
                    title: Text(order.label),
                    value: order,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(LocalTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地音乐'),
        content: Text('确定要从曲库中删除「${track.title}」吗？\n导入时复制的文件将一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 删除正在播放的文件：iOS/Android 可删（fd 保持），Windows 文件锁
    // 会失败——统一禁止删除播放中曲目，行为一致且更安全
    final playingPath = await _playingLocalPath();
    if (playingPath == track.filePath) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该曲目正在播放，请先切换到其他歌曲')),
      );
      return;
    }
    await LocalMusicService.deleteTracks([track]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已删除')),
    );
    await _load();
  }

  void _showTrackMenu(LocalTrack track) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('添加到播放列表'),
              onTap: () async {
                Navigator.pop(dialogContext);
                final service = await AudioService.instance;
                await service.appendLocalTracks([track]);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已添加到播放列表')),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(dialogContext).colorScheme.error),
              title: Text('从曲库删除',
                  style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error)),
              onTap: () {
                Navigator.pop(dialogContext);
                _confirmDelete(track);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final totalSize = _tracks.fold<int>(0, (sum, t) => sum + t.fileSize);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _tracks.isEmpty ? null : () => _playAll(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放全部'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _tracks.isEmpty ? null : () => _playAll(shuffle: true),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('随机播放'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索标题 / 艺术家 / 专辑',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              filled: true,
              fillColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Text(
                '${_filtered.length} 首 · ${_formatSize(_filtered.fold<int>(0, (sum, t) => sum + t.fileSize))}'
                '${totalSize > 0 && _filtered.length != _tracks.length ? '（共 ${_formatSize(totalSize)}）' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.secondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_music_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            '暂无本地音乐',
            style: TextStyle(
                fontSize: 16, color: Theme.of(context).colorScheme.secondary),
          ),
          const SizedBox(height: 8),
          Text(
            '导入设备中的音频文件，无需联网也能听',
            style: TextStyle(
                fontSize: 13, color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: _showImportMenu,
            icon: const Icon(Icons.add),
            label: const Text('导入音乐'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: '排序',
            onPressed: _tracks.isEmpty ? null : _showSortMenu,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '导入',
            onPressed: _importing ? null : _showImportMenu,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tracks.isEmpty
              ? _buildEmpty()
              : Column(
                  children: [
                    _buildHeader(),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                '没有匹配「$_query」的曲目',
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.secondary),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final track = filtered[index];
                                return TrackTile(
                                  pic: track.coverPath != null
                                      ? 'file://${track.coverPath}'
                                      : null,
                                  title: track.title,
                                  author: track.artist,
                                  album:
                                      track.album.isEmpty ? null : track.album,
                                  len: track.duration > 0
                                      ? str_util.duration(track.duration)
                                      : '--:--',
                                  onTap: () => _play(filtered, index),
                                  onLongPress: () =>
                                      _showTrackMenu(track),
                                  onAddToPlaylistButtonPressed: () async {
                                    final service = await AudioService.instance;
                                    await service.appendLocalTracks([track]);
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('已添加到播放列表')),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}
