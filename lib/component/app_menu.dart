import 'package:flutter/material.dart';

/// 全 App 弹出菜单统一的动画：减速曲线 200ms 展开、120ms 收起。
/// Flutter 默认是线性 300ms，面板先横后纵展开、菜单项逐项淡入，显得
/// 拖沓；减速曲线让大部分位移在前几十毫秒完成，逐项淡入随之压缩成
/// 一次连贯的展开。外观（圆角、配色、间距）见 theme.dart 的
/// popupMenuTheme
const AnimationStyle kMenuAnimationStyle = AnimationStyle(
  duration: Duration(milliseconds: 200),
  curve: Curves.easeOutCubic,
  reverseDuration: Duration(milliseconds: 120),
  reverseCurve: Curves.easeIn,
);

/// 统一样式的菜单项：左侧图标位放 [icon]，或在选择型菜单里放选中
/// 对勾（[selected] 非 null 时：选中为主题色对勾 + 主题色文字，未选中
/// 留空位保持文字对齐）
PopupMenuItem<T> appMenuItem<T>({
  required T value,
  required String label,
  IconData? icon,
  bool? selected,
}) {
  return PopupMenuItem<T>(
    value: value,
    child: Builder(builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final isSelected = selected ?? false;
      final leading = selected != null
          ? (isSelected ? Icons.check : null)
          : icon;
      return Row(
        children: [
          SizedBox(
            width: 20,
            child: leading == null
                ? null
                : Icon(leading,
                    size: 20,
                    color: isSelected ? cs.primary : cs.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: isSelected
                  ? TextStyle(color: cs.primary, fontWeight: FontWeight.w600)
                  : null,
            ),
          ),
        ],
      );
    }),
  );
}
