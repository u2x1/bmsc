import 'package:bmsc/database_manager.dart';
import 'package:bmsc/screen/about_screen.dart';
import 'package:bmsc/screen/cache_screen.dart';
import 'package:bmsc/screen/download_screen.dart';
import 'package:bmsc/screen/hidden_fav_screen.dart';
import 'package:bmsc/screen/login_screen.dart';
import 'package:bmsc/screen/playlist_search_screen.dart';
import 'package:bmsc/service/audio_service.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../service/shared_preferences_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _audioQuality = SharedPreferencesService.kAudioQualityAuto;
  bool _reactToInterruption = true;
  bool _historyReported = true;
  int _reportHistoryInterval = 10;
  String _downloadPath = '/storage/emulated/0/Download/BMSC';
  int _maxConcurrentDownloads = 3;
  int _cacheLimitSize = 300;
  bool _showDailyRecommendations = true;
  bool _showRecentListening = true;
  bool _readFromClipboard = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final audioQuality = await SharedPreferencesService.getAudioQuality();
    final reactToInterruption =
        await SharedPreferencesService.getReactToInterruption();
    final historyReported = await SharedPreferencesService.getHistoryReported();
    final reportHistoryInterval =
        await SharedPreferencesService.getReportHistoryInterval();
    final downloadPath = await SharedPreferencesService.getDownloadPath();
    final maxConcurrentDownloads =
        await SharedPreferencesService.getMaxConcurrentDownloads();
    final cacheLimitSize = await SharedPreferencesService.getCacheLimitSize();
    final prefs = await SharedPreferencesService.instance;
    final showDailyRecommendations =
        prefs.getBool('show_daily_recommendations') ?? true;
    final showRecentListening = prefs.getBool('show_recent_listening') ?? true;
    final readFromClipboard =
        await SharedPreferencesService.getReadFromClipboard();
    if (mounted) {
      setState(() {
        _audioQuality = audioQuality;
        _reactToInterruption = reactToInterruption;
        _historyReported = historyReported;
        _reportHistoryInterval = reportHistoryInterval;
        _downloadPath = downloadPath;
        _maxConcurrentDownloads = maxConcurrentDownloads;
        _cacheLimitSize = cacheLimitSize;
        _showDailyRecommendations = showDailyRecommendations;
        _showRecentListening = showRecentListening;
        _readFromClipboard = readFromClipboard;
      });
    }
  }

  /// 主页板块排序：拖拽手柄调整顺序，即时保存；返回主页后生效
  ///（主页由 refreshLoginState 重新读取排序偏好）
  Future<void> _showHomeSectionOrderDialog() async {
    final order = await SharedPreferencesService.getHomeSectionOrder();
    if (!mounted) return;
    const sectionMeta = {
      kHomeSectionDaily: (Icons.auto_awesome, '每日推荐'),
      kHomeSectionRecent: (Icons.history, '最近在听'),
      kHomeSectionMine: (Icons.folder_outlined, '我的收藏夹'),
      kHomeSectionCollected: (Icons.star_outline, '收藏的收藏夹'),
    };
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('主页板块排序'),
          content: SizedBox(
            width: 360,
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                // Flutter 3.41+ 的 onReorderItem 已把 newIndex
                // 调整为「移除后插入」的最终下标
                setDialogState(() {
                  order.insert(newIndex, order.removeAt(oldIndex));
                });
                SharedPreferencesService.setHomeSectionOrder(order);
              },
              children: [
                for (final key in order)
                  ListTile(
                    key: ValueKey(key),
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 8),
                    leading: Icon(sectionMeta[key]!.$1, size: 20),
                    title: Text(sectionMeta[key]!.$2),
                    trailing: ReorderableDragStartListener(
                      index: order.indexOf(key),
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.drag_handle, size: 20),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setDialogState(() {
                  order
                    ..clear()
                    ..addAll(kDefaultHomeSectionOrder);
                });
                SharedPreferencesService.setHomeSectionOrder(order);
              },
              child: const Text('重置默认'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  String _audioQualityLabel(int quality) =>
      SharedPreferencesService.audioQualityLabels[quality] ??
      SharedPreferencesService
          .audioQualityLabels[SharedPreferencesService.kAudioQualityAuto]!;

  void _showAudioQualityPicker() {
    showDialog(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('播放音质'),
        children: [
          RadioGroup<int>(
            groupValue: _audioQuality,
            onChanged: (value) async {
              if (value == null) return;
              await SharedPreferencesService.setAudioQuality(value);
              setState(() {
                _audioQuality = value;
              });
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: SharedPreferencesService.audioQualityLabels.entries
                  .map((entry) => RadioListTile<int>(
                        title: Text(entry.value),
                        value: entry.key,
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 数字输入对话框：非法输入显示错误文案，并限制在 [min, max] 区间
  Future<int?> _showNumberInputDialog({
    required String title,
    required String label,
    required int initial,
    required int min,
    required int max,
    String? suffix,
  }) async {
    final controller = TextEditingController(text: initial.toString());
    try {
      return await showDialog<int>(
        context: context,
        builder: (context) {
          String? errorText;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(title),
              content: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: label,
                        border: const OutlineInputBorder(),
                        errorText: errorText,
                      ),
                    ),
                  ),
                  if (suffix != null) ...[
                    const SizedBox(width: 8),
                    Text(suffix),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final newValue = int.tryParse(controller.text);
                    if (newValue == null || newValue < min || newValue > max) {
                      setDialogState(() {
                        errorText = '请输入 $min - $max 之间的整数';
                      });
                      return;
                    }
                    Navigator.pop(context, newValue);
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Widget _buildLoginTile() {
    return FutureBuilder<BilibiliService?>(
        future: BilibiliService.instance,
        builder: (context, snapshot) {
          final bs = snapshot.data;
          final myInfo = bs?.myInfo;
          final isLoggedIn = myInfo != null && myInfo.mid != 0;
          final username = myInfo?.name;
          return ListTile(
            title: Text(isLoggedIn ? '退出登录' : '登录'),
            subtitle: Text(isLoggedIn ? '当前已登录: $username' : '点击登录账号'),
            leading: Icon(isLoggedIn ? Icons.logout : Icons.login),
            onTap: () {
              if (isLoggedIn) {
                final pageMessenger = ScaffoldMessenger.of(context);
                showDialog(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('退出登录'),
                    content: const Text('确定要退出登录吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          try {
                            await bs?.logout();
                            await DatabaseManager.cacheFavList([]);
                          } catch (e) {
                            pageMessenger.showSnackBar(
                              const SnackBar(content: Text('退出失败，请重试')),
                            );
                            return;
                          }
                          // 留在设置页，原地刷新登录项
                          if (mounted) {
                            setState(() {});
                          }
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              } else {
                Navigator.push<bool>(
                  context,
                  MaterialPageRoute<bool>(builder: (_) => const LoginScreen()),
                ).then((value) {
                  if (value == true && mounted) {
                    setState(() {});
                  }
                });
              }
            },
          );
        });
  }

  Widget _buildThemeModeTile() {
    return ListTile(
      title: const Text('主题模式'),
      leading: const Icon(Icons.palette),
      subtitle: Text(switch (ThemeProvider.instance.themeMode) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      }),
      onTap: () {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('选择主题模式'),
            content: RadioGroup<ThemeMode>(
              groupValue: ThemeProvider.instance.themeMode,
              onChanged: (ThemeMode? value) async {
                if (value != null) {
                  await ThemeProvider.instance.setThemeMode(value);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    title: const Text('浅色'),
                    value: ThemeMode.light,
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('深色'),
                    value: ThemeMode.dark,
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('跟随系统'),
                    value: ThemeMode.system,
                  ),
                ],
              ),
            ),
          ),
        ).then((_) {
          if (context.mounted) {
            setState(() {});
          }
        });
      },
    );
  }

  /// OLED 纯黑模式开关：深色主题下背景使用 #000000（issue #15）
  Widget _buildPureBlackTile() {
    return SwitchListTile(
      title: const Text('纯黑模式 (OLED)'),
      secondary: const Icon(Icons.contrast),
      subtitle: const Text('深色主题使用纯黑背景，OLED 屏幕更省电'),
      value: ThemeProvider.instance.pureBlack,
      onChanged: (bool value) async {
        await ThemeProvider.instance.setPureBlack(value);
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          _buildSectionTitle('账号'),
          _buildLoginTile(),
          _buildSectionTitle('音质'),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: const Text('播放音质'),
            subtitle: Text(_audioQualityLabel(_audioQuality)),
            onTap: _showAudioQualityPicker,
          ),
          _buildSectionTitle('播放'),
          SwitchListTile(
            title: const Text('忽略中断'),
            secondary: const Icon(Icons.headset),
            subtitle: const Text('允许与其他应用同时播放'),
            value: !_reactToInterruption,
            onChanged: (bool value) async {
              await SharedPreferencesService.setReactToInterruption(!value);
              (await AudioService.instance).setInterrupHandler(!value);
              setState(() {
                _reactToInterruption = !value;
              });
            },
          ),
          _buildSectionTitle('数据'),
          SwitchListTile(
            title: const Text('播放记录上报'),
            secondary: const Icon(Icons.history),
            subtitle: const Text('上报记录到 B 站'),
            value: _historyReported,
            onChanged: (bool value) async {
              await SharedPreferencesService.setHistoryReported(value);
              setState(() {
                _historyReported = value;
              });
            },
          ),
          ListTile(
            title: const Text('上报间隔'),
            leading: const Icon(Icons.timer),
            subtitle: Text('$_reportHistoryInterval s'),
            onTap: () async {
              final newValue = await _showNumberInputDialog(
                title: '设置上报间隔',
                label: '上报间隔',
                initial: _reportHistoryInterval,
                min: 1,
                max: 3600,
                suffix: 's',
              );
              if (newValue != null) {
                await SharedPreferencesService.setReportHistoryInterval(
                    newValue);
                setState(() {
                  _reportHistoryInterval = newValue;
                });
              }
            },
          ),
          _buildSectionTitle('下载'),
          ListTile(
            title: const Text('下载管理'),
            leading: const Icon(Icons.download),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(
                    builder: (_) => const DownloadScreen()),
              );
            },
          ),
          ListTile(
            title: const Text('下载路径'),
            subtitle: Text(_downloadPath),
            leading: const Icon(Icons.folder),
            onTap: () async {
              String? selectedDirectory = await FilePicker.getDirectoryPath();
              if (selectedDirectory != null) {
                await SharedPreferencesService.setDownloadPath(
                    selectedDirectory);
                setState(() {
                  _downloadPath = selectedDirectory;
                });
              }
            },
          ),
          ListTile(
            title: const Text('最大并发下载数'),
            subtitle: Text('$_maxConcurrentDownloads'),
            leading: const Icon(Icons.numbers),
            onTap: () async {
              final newValue = await _showNumberInputDialog(
                title: '设置最大并发下载数',
                label: '最大并发下载数',
                initial: _maxConcurrentDownloads,
                min: 1,
                max: 8,
              );
              if (newValue != null) {
                await SharedPreferencesService.setMaxConcurrentDownloads(
                    newValue);
                setState(() {
                  _maxConcurrentDownloads = newValue;
                });
              }
            },
          ),
          _buildSectionTitle('缓存'),
          ListTile(
            title: const Text('缓存管理'),
            leading: const Icon(Icons.storage),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(builder: (_) => const CacheScreen()),
              );
            },
          ),
          ListTile(
            title: const Text('缓存大小限制'),
            subtitle: Text('$_cacheLimitSize MB'),
            leading: const Icon(Icons.folder),
            onTap: () async {
              final newValue = await _showNumberInputDialog(
                title: '设置缓存大小限制',
                label: '缓存大小',
                initial: _cacheLimitSize,
                min: 100,
                max: 10240,
                suffix: 'MB',
              );
              if (newValue != null) {
                await SharedPreferencesService.setCacheLimitSize(newValue);
                setState(() {
                  _cacheLimitSize = newValue;
                });
              }
            },
          ),
          _buildSectionTitle('显示'),
          ListTile(
            title: const Text('隐藏收藏夹管理'),
            leading: const Icon(Icons.folder),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(
                    builder: (_) => const HiddenFavScreen()),
              );
            },
          ),
          _buildThemeModeTile(),
          _buildPureBlackTile(),
          ListTile(
            title: const Text('评论字体大小'),
            subtitle: Text('${ThemeProvider.instance.commentFontSize}'),
            leading: const Icon(Icons.format_size),
            onTap: () {
              final originalFontSize = ThemeProvider.instance.commentFontSize;
              var fontSize = originalFontSize;
              showDialog(
                context: context,
                builder: (context) => StatefulBuilder(
                  builder: (context, setDialogState) => AlertDialog(
                    title: const Text('评论字体大小'),
                    content: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Row(
                        children: [
                          Text(
                            '12',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: fontSize.toDouble(),
                              min: 12,
                              max: 20,
                              divisions: 8,
                              label: fontSize.toString(),
                              onChanged: (value) {
                                setDialogState(() {
                                  fontSize = value.toInt();
                                });
                                // 拖动时实时预览
                                ThemeProvider.instance
                                    .setCommentFontSize(fontSize);
                              },
                            ),
                          ),
                          Text(
                            '20',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          ThemeProvider.instance
                              .setCommentFontSize(originalFontSize);
                          Navigator.pop(context);
                        },
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
              ).then((_) {
                if (context.mounted) {
                  setState(() {});
                }
              });
            },
          ),
          SwitchListTile(
            title: const Text('显示每日推荐'),
            secondary: const Icon(Icons.star),
            subtitle: const Text('在收藏夹页面显示每日推荐'),
            value: _showDailyRecommendations,
            onChanged: (bool value) async {
              final prefs = await SharedPreferencesService.instance;
              await prefs.setBool('show_daily_recommendations', value);
              setState(() {
                _showDailyRecommendations = value;
              });
            },
          ),
          SwitchListTile(
            title: const Text('显示最近在听'),
            secondary: const Icon(Icons.history),
            subtitle: const Text('在收藏夹页面显示最近在听'),
            value: _showRecentListening,
            onChanged: (bool value) async {
              final prefs = await SharedPreferencesService.instance;
              await prefs.setBool('show_recent_listening', value);
              setState(() {
                _showRecentListening = value;
              });
            },
          ),
          ListTile(
            title: const Text('主页板块排序'),
            leading: const Icon(Icons.sort),
            subtitle: const Text('调整主页各板块的显示顺序'),
            onTap: _showHomeSectionOrderDialog,
          ),
          _buildSectionTitle('隐私'),
          SwitchListTile(
            title: const Text('读取剪贴板'),
            secondary: const Icon(Icons.content_paste),
            subtitle: const Text('自动提取剪贴板中的链接'),
            value: _readFromClipboard,
            onChanged: (bool value) async {
              await SharedPreferencesService.setReadFromClipboard(value);
              setState(() {
                _readFromClipboard = value;
              });
            },
          ),
          _buildSectionTitle('工具'),
          ListTile(
            title: const Text('导入歌单（已废弃）'),
            subtitle: const Text('不再维护，后续版本将移除'),
            leading: const Icon(Icons.import_export),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(
                    builder: (_) => const PlaylistSearchScreen()),
              );
            },
          ),
          _buildSectionTitle('其他'),
          ListTile(
            title: const Text('关于'),
            leading: const Icon(Icons.info_outline),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(builder: (_) => const AboutScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}
