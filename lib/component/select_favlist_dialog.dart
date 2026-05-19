import 'package:flutter/rendering.dart';
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
  bool isLoggedIn = true;

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

  Future<void> _loadFavs() async {
    final bs = await BilibiliService.instance;
    final uid = bs.myInfo?.mid ?? 0;
    final f = await bs.getFavs(uid) ?? [];
    setState(() {
      favs = f;
      isLoggedIn = uid != 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return !isLoggedIn
        ? const AlertDialog(
            title: Text('未登录'),
            content: Text('请先登录'),
          )
        : AlertDialog(
            title: const Text('选择收藏夹'),
            content: SizedBox(
              width: double.maxFinite,
              height: 300,
              child: Column(
                children: [
                  createFavFolderListTile(context, true),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      scrollCacheExtent: ScrollCacheExtent.pixels(10000),
                      shrinkWrap: true,
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
    {Function? callback}) {
  return ListTile(
    leading: const Icon(Icons.add),
    title: const Text('新建收藏夹'),
    onTap: () async {
      final result = await showDialog<(String, bool)>(
        context: context,
        builder: (BuildContext context) {
          final nameController = TextEditingController();
          bool isPrivate = false;
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: const Text('新建收藏夹'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: '收藏夹名称',
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
                      if (nameController.text.isEmpty) return;
                      Navigator.pop(context, (nameController.text, isPrivate));
                    },
                    child: const Text('确定'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (result != null) {
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
      }
    },
  );
}
