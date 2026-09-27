import 'package:flutter/material.dart';

/// 主页分区标题行：图标 + 加粗标题 + 可选数量计数 + 可选尾部动作。
///
/// 主页四个分区（最近在听 / 每日推荐 / 我的收藏夹 / 收藏的收藏夹）
/// 统一使用该组件，保证 header 风格一致；配合 [SectionDivider]
/// 通栏分隔条使分区之间界限明确。自带不透明背景，配合
/// SliverStickyHeader 使用时滚动内容不会从 header 下透出。
class SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.count,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(fontSize: 13, color: scheme.secondary),
            ),
          ],
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// 分区之间的通栏分隔条：淡底 8px，让分区界限明确。
class SectionDivider extends StatelessWidget {
  const SectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.45),
    );
  }
}
