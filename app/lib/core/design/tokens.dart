import 'package:flutter/material.dart';

/// Design tokens. Widgets use these (or the theme built from them),
/// never raw numbers or colours.
class AppColors {
  const AppColors._();

  static const brand = Color(0xFF0F6E5B);
  static const accent = Color(0xFFE8A33D);
  static const success = Color(0xFF2E7D32);
  static const warning = Color(0xFFB26A00);
  static const danger = Color(0xFFC62828);
}

class AppSpacing {
  const AppSpacing._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// Side gutter for page content.
  static const page = lg;
}

class AppRadius {
  const AppRadius._();

  static const sm = Radius.circular(8);
  static const md = Radius.circular(12);
  static const lg = Radius.circular(20);
}

/// Width breakpoints for responsive layouts.
class Breakpoints {
  const Breakpoints._();

  static const medium = 600.0;
  static const expanded = 1024.0;

  /// Widest a form or reading column should grow.
  static const contentMax = 720.0;
}

enum WindowSize { compact, medium, expanded }

WindowSize windowSizeOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= Breakpoints.expanded) return WindowSize.expanded;
  if (width >= Breakpoints.medium) return WindowSize.medium;
  return WindowSize.compact;
}
