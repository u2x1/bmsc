import 'dart:math' as math;

import 'package:bmsc/database_manager.dart';
import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';

class SelectFavlistDialog extends StatefulWidget {
  const SelectFavlistDialog({super.key});

  @override
  State<SelectFavlistDialog> createState() => _SelectFavlistDialogState();
}

class _SelectFavlistDialogState extends State<SelectFavlistDialog> {
  List<Fav> favs = [];
  bool isLoading = true;
  bool isLoggedIn = true;

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

  Future<void> _loadFavs() async {
    final bs = await BilibiliService.instance;
    final uid = bs.myInfo?.mid ?? 0;
    if (uid == 0) {
      if (mounted) {
        setState(() {
          isLoading = false;
          isLoggedIn = false;
        });
      }
      return;
    }
    final f = await bs.getFavs(uid) ??
        await DatabaseManager.getCachedFavList();
    if (mounted) {
      setState(() {
        favs = f;
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn) {
      return const AlertDialog(
        title: Text('未登录'),
        content: Text('请先登录'),
      );
    }
    return AlertDialog(
      title: const Text('选择收藏夹'),
      content: SizedBox(
        width: double.maxFinite,
        height: math.min(MediaQuery.of(context).size.height * 0.4, 400),
        child: isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  createFavFolderListTile(context, true),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: favs.length,
                      itemBuilder: (context, index) {
                        final folder = favs[index];
                        return ListTile(
                          title: Text(folder.title),
                          subtitle: Text('${folder.mediaCount} 首曲目'),
                          onTap: () async {
                            Navigator.pop(context, folder);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

Widget createFavFolderListTile(BuildContext context, bool exitOnTap,
    {void Function(Fav folder)? callback}) {
  bool isCreating = false;
  return StatefulBuilder(
    builder: (context, setTileState) {
      return ListTile(
        leading: isCreating
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        title: const Text('新建收藏夹'),
        onTap: isCreating
            ? null
            : () async {
                final nameController = TextEditingController();
                final (String, bool)? result;
                try {
                  result = await showDialog<(String, bool)>(
                    context: context,
                    builder: (BuildContext context) {
                      bool isPrivate = false;
                      String? nameError;
                      return StatefulBuilder(
                        builder: (context, setState) {
                          return AlertDialog(
                            title: const Text('新建收藏夹'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  controller: nameController,
                                  decoration: InputDecoration(
                                    labelText: '收藏夹名称',
                                    errorText: nameError,
                                  ),
                                ),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: isPrivate,
                                      onChanged: (value) {
                                        setState(() {
                                          isPrivate = value ?? false;
                                        });
                                      },
                                    ),
                                    const Text('设为私密'),
                                  ],
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () {
                                  if (nameController.text.isEmpty) {
                                    setState(() {
                                      nameError = '名称不能为空';
                                    });
                                    return;
                                  }
                                  Navigator.pop(
                                      context, (nameController.text, isPrivate));
                                },
                                child: const Text('确定'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                } finally {
                  nameController.dispose();
                }

                if (result != null) {
                  setTileState(() => isCreating = true);
                  try {
                    final bs = await BilibiliService.instance;
                    final folder = await bs.createFavFolder(
                      result.$1,
                      hide: result.$2,
                    );

                    if (folder != null && context.mounted) {
                      if (exitOnTap) {
                        Navigator.pop(context, folder);
                      }
                      if (callback != null) {
                        callback(folder);
                      }
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('创建失败')),
                        );
                      }
                    }
                  } finally {
                    if (context.mounted) {
                      setTileState(() => isCreating = false);
                    }
                  }
                }
              },
      );
    },
  );
}
