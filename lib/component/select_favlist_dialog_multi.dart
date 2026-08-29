import 'package:bmsc/model/fav.dart';
import 'package:bmsc/service/bilibili_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:bmsc/component/select_favlist_dialog.dart';

class SelectMultiFavlistDialog extends StatefulWidget {
  final int? aid;

  const SelectMultiFavlistDialog({super.key, this.aid});

  @override
  State<SelectMultiFavlistDialog> createState() =>
      _SelectMultiFavlistDialogState();
}

class _SelectMultiFavlistDialogState extends State<SelectMultiFavlistDialog> {
  List<Fav> favs = [];
  final Map<int, bool> _pendingFavStates = {};
  int defaultFolderId = 0;
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
    final f = await bs.getFavs(uid, rid: widget.aid) ?? [];
    final df = await SharedPreferencesService.getDefaultFavFolder();
    if (mounted) {
      setState(() {
        favs = f;
        defaultFolderId = df?.$1 ?? 0;
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
        child: isLoading
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                ],
              )
            : Column(
                children: [
                  createFavFolderListTile(context, false, callback: (folder) {
                    setState(() {
                      favs.insert(0, folder);
                      _pendingFavStates[folder.id] = true;
                    });
                  }),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: favs.length,
                      itemBuilder: (context, index) {
                        final folder = favs[index];
                        final isSelected =
                            _pendingFavStates.containsKey(folder.id)
                                ? _pendingFavStates[folder.id]!
                                : folder.favState == 1;
                        return CheckboxListTile(
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  folder.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (defaultFolderId == folder.id)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '默认',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          value: isSelected,
                          onChanged: (value) {
                            setState(() {
                              _pendingFavStates[folder.id] = value!;
                            });
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final toAdd = <int>[];
            final toRemove = <int>[];
            final favById = {for (final f in favs) f.id: f};

            _pendingFavStates.forEach((folderId, newState) {
              final originalState = favById[folderId]?.favState == 1;

              if (newState != originalState) {
                if (newState) {
                  toAdd.add(folderId);
                } else {
                  toRemove.add(folderId);
                }
              }
            });

            Navigator.pop(context, {
              'toAdd': toAdd,
              'toRemove': toRemove,
            });
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
