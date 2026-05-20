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

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '账号',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          StatefulBuilder(builder: (context, setState) {
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
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('退出登录'),
                            content: const Text('确定要退出登录吗？'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () async {
                                  try {
                                    await bs?.logout();
                                    await DatabaseManager.cacheFavList([]);
                                  } catch (e) {
                                    // ignore logout error
                                  }
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    Navigator.pop(context, true);
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
                          MaterialPageRoute<bool>(
                              builder: (_) => const LoginScreen()),
                        ).then((value) async {
                          if (value == true) {
                            if (context.mounted) {
                              Navigator.pop(context, true);
                            }
                          }
                        });
                      }
                    },
                  );
                });
          }),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '音质',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<bool>(
              future: SharedPreferencesService.getHiResFirst(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return SwitchListTile(
                  title: const Text('高音质'),
                  secondary: const Icon(Icons.music_note),
                  subtitle: const Text('优先选择 Hi-Res 无损音质'),
                  value: snapshot.data!,
                  onChanged: (bool value) async {
                    await SharedPreferencesService.setHiResFirst(value);
                    setState(() {});
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '播放',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<bool>(
              future: SharedPreferencesService.getReactToInterruption(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return SwitchListTile(
                  title: const Text('忽略中断'),
                  secondary: const Icon(Icons.headset),
                  subtitle: const Text('允许与其他应用同时播放'),
                  value: !snapshot.data!,
                  onChanged: (bool value) async {
                    await SharedPreferencesService.setReactToInterruption(
                        !value);
                    (await AudioService.instance).setInterrupHandler(!value);
                    setState(() {});
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '数据',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<bool>(
              future: SharedPreferencesService.getHistoryReported(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return SwitchListTile(
                  title: const Text('播放记录上报'),
                  secondary: const Icon(Icons.history),
                  subtitle: const Text('上报记录到 B 站'),
                  value: snapshot.data!,
                  onChanged: (bool value) async {
                    await SharedPreferencesService.setHistoryReported(value);
                    setState(() {});
                  },
                );
              },
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<int>(
              future: SharedPreferencesService.getReportHistoryInterval(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return ListTile(
                  title: const Text('上报间隔'),
                  leading: const Icon(Icons.timer),
                  subtitle: Text('${snapshot.data} s'),
                  onTap: () async {
                    final controller =
                        TextEditingController(text: snapshot.data.toString());
                    if (!context.mounted) return;
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('设置上报间隔'),
                        content: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controller,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '上报间隔',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('s'),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text("取消"),
                          ),
                          FilledButton(
                            onPressed: () async {
                              final newValue = int.tryParse(controller.text);
                              if (newValue != null) {
                                await SharedPreferencesService
                                    .setReportHistoryInterval(newValue);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  setState(() {});
                                }
                              }
                            },
                            child: const Text("确定"),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '下载',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
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
          StatefulBuilder(builder: (context, setState) {
            return ListTile(
                title: const Text('下载路径'),
                subtitle: FutureBuilder<String>(
                  future: SharedPreferencesService.getDownloadPath(),
                  builder: (context, snapshot) {
                    final path =
                        snapshot.data ?? '/storage/emulated/0/Download/BMSC';
                    return Text(path);
                  },
                ),
                leading: const Icon(Icons.folder),
                onTap: () async {
                  String? selectedDirectory =
                      await FilePicker.getDirectoryPath();
                  if (selectedDirectory != null) {
                    await SharedPreferencesService.setDownloadPath(
                        selectedDirectory);
                    setState(() {});
                  }
                });
          }),
          StatefulBuilder(builder: (context, setState) {
            return ListTile(
              title: const Text('最大并发下载数'),
              subtitle: FutureBuilder<int>(
                future: SharedPreferencesService.getMaxConcurrentDownloads(),
                builder: (context, snapshot) {
                  final limit = snapshot.data ?? 3;
                  return Text('$limit');
                },
              ),
              leading: const Icon(Icons.numbers),
              onTap: () async {
                var currentLimit =
                    await SharedPreferencesService.getMaxConcurrentDownloads();
                final controller =
                    TextEditingController(text: currentLimit.toString());
                if (!context.mounted) return;
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('设置最大并发下载数'),
                    content: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '最大并发下载数',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          final newValue = int.tryParse(controller.text);
                          if (newValue != null) {
                            currentLimit = newValue;
                            await SharedPreferencesService
                                .setMaxConcurrentDownloads(currentLimit);
                            if (context.mounted) {
                              Navigator.pop(context);
                              setState(() {});
                            }
                          }
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              },
            );
          }),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '缓存',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
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
          StatefulBuilder(builder: (context, setState) {
            return ListTile(
              title: const Text('缓存大小限制'),
              subtitle: FutureBuilder<int>(
                future: SharedPreferencesService.getCacheLimitSize(),
                builder: (context, snapshot) {
                  final limit = snapshot.data ?? 300;
                  return Text('$limit MB');
                },
              ),
              leading: const Icon(Icons.folder),
              onTap: () async {
                var currentLimit =
                    await SharedPreferencesService.getCacheLimitSize();
                final controller =
                    TextEditingController(text: currentLimit.toString());
                if (!context.mounted) return;
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('设置缓存大小限制'),
                    content: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '缓存大小',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('MB'),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          final newValue = int.tryParse(controller.text);
                          if (newValue != null) {
                            currentLimit = newValue;
                            await SharedPreferencesService.setCacheLimitSize(
                                currentLimit);
                            if (context.mounted) {
                              Navigator.pop(context);
                              setState(() {});
                            }
                          }
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              },
            );
          }),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '显示',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
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
          StatefulBuilder(builder: (context, setState) {
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
          }),
          StatefulBuilder(builder: (context, setState) {
            return ListTile(
              title: const Text('评论字体大小'),
              subtitle: Text('${ThemeProvider.instance.commentFontSize}'),
              leading: const Icon(Icons.format_size),
              onTap: () {
                var fontSize = ThemeProvider.instance.commentFontSize;
                showDialog(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: const Text('评论字体大小'),
                    children: [
                      StatefulBuilder(
                        builder: (context, setState) => Column(
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                children: [
                                  Text(
                                    '12',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondary,
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
                                        setState(() {
                                          fontSize = value.toInt();
                                        });
                                      },
                                    ),
                                  ),
                                  Text(
                                    '20',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ).then((_) {
                  if (context.mounted) {
                    setState(() {
                      ThemeProvider.instance.setCommentFontSize(fontSize);
                    });
                  }
                });
              },
            );
          }),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<bool>(
              future: SharedPreferencesService.instance.then((prefs) =>
                  prefs.getBool('show_daily_recommendations') ?? true),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return SwitchListTile(
                  title: const Text('显示每日推荐'),
                  secondary: const Icon(Icons.star),
                  subtitle: const Text('在收藏夹页面显示每日推荐'),
                  value: snapshot.data!,
                  onChanged: (bool value) async {
                    final prefs = await SharedPreferencesService.instance;
                    await prefs.setBool('show_daily_recommendations', value);
                    setState(() {});
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '隐私',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          StatefulBuilder(
            builder: (context, setState) => FutureBuilder<bool>(
              future: SharedPreferencesService.getReadFromClipboard(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                return SwitchListTile(
                  title: const Text('读取剪贴板'),
                  secondary: const Icon(Icons.content_paste),
                  subtitle: const Text('自动提取剪贴板中的链接'),
                  value: snapshot.data!,
                  onChanged: (bool value) async {
                    await SharedPreferencesService.setReadFromClipboard(value);
                    setState(() {});
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '工具',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('导入歌单'),
            leading: const Icon(Icons.import_export),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<Widget>(
                    builder: (_) => const PlaylistSearchScreen()),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '其他',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
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
