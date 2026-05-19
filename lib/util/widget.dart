import 'package:flutter/material.dart';

Widget shadow(Widget child) {
  return Builder(
    builder: (context) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: (isDark
                  ? const Color(0xFF1A1A1A).withValues(alpha: 0.95) // Darker shadow
                  : Colors.grey.withValues(alpha: 0.5)),
              spreadRadius: isDark ? 8 : 5, // Increased spread
              blurRadius: isDark ? 25 : 7, // Increased blur
              offset: const Offset(0, 4), // Slightly larger offset
            ),
            if (isDark)
              BoxShadow(
                // Enhanced highlight
                color: Colors.white.withValues(alpha: 0.05), // Slightly brighter
                spreadRadius: 2, // Increased spread
                blurRadius: 8, // Increased blur
                offset: const Offset(0, 0),
              ),
          ],
        ),
        child: child,
      );
    },
  );
}
