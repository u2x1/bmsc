import 'package:bmsc/util/home_toolbar.dart';
import 'package:flutter/material.dart';

/// 主页顶栏各入口的图标与名称（主页与设置页共用）
const Map<HomeToolbarItem, (IconData, String)> kHomeToolbarMeta = {
  HomeToolbarItem.search: (Icons.search, '搜索'),
  HomeToolbarItem.recognition: (Icons.graphic_eq, '听歌识曲'),
  HomeToolbarItem.dynamic: (Icons.wind_power_outlined, '动态'),
  HomeToolbarItem.history: (Icons.history_outlined, '历史'),
  HomeToolbarItem.settings: (Icons.settings_outlined, '设置'),
};
