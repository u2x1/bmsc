import 'package:flutter/material.dart';

/// 封面图统一外观：圆角裁剪 + 发丝描边 + 柔和投影，让封面与背景、
/// 与堆叠中的相邻层都有清晰边界（原先只是圆角裁剪，浅色/灰色封面会
/// 和卡片背景融成一片）。深色模式下投影几乎不可见，主要靠浅色描边。
/// [shadow] 调节投影强度：1 为标准（收藏夹主封面）；0 不画投影——
/// 描边几乎零成本，模糊投影是唯一有开销的部分，长列表与堆叠背层
/// 应传 0（圆角裁剪为 Clip.antiAlias，不触发 saveLayer）
class CoverFrame extends StatelessWidget {
  const CoverFrame({
    super.key,
    required this.child,
    this.radius = 8,
    this.shadow = 1,
  });

  final Widget child;
  final double radius;
  final double shadow;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow > 0
            ? [
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: (dark ? 0.5 : 0.18) * shadow),
                  blurRadius: 3 + 5 * shadow,
                  offset: Offset(0, 1 + shadow),
                ),
              ]
            : null,
      ),
      // 描边画在图片之上（前景），不被图片内容盖住
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.8,
        ),
      ),
      child: ClipRRect(borderRadius: borderRadius, child: child),
    );
  }
}
