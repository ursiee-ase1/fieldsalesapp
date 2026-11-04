import 'package:flutter/material.dart';

import 'tokens.dart';

/// System fonts only: nothing is downloaded at runtime, so the app looks the
/// same offline.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
      tertiary: AppColors.accent,
      error: brightness == Brightness.light ? AppColors.danger : null,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(AppRadius.md));
    const minButton = Size(64, 48); // comfortable touch target outdoors

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(AppRadius.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: minButton, shape: shape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: minButton, shape: shape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48), shape: shape),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: const OutlineInputBorder(borderRadius: BorderRadius.all(AppRadius.sm)),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      // Icons always carry their text label, so their meaning never has to be guessed.
      navigationBarTheme: const NavigationBarThemeData(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      navigationRailTheme: const NavigationRailThemeData(labelType: NavigationRailLabelType.all),
      tabBarTheme: const TabBarThemeData(tabAlignment: TabAlignment.start),
    );
  }
}
