import 'package:flutter/material.dart';

import '../../../core/design/tokens.dart';

/// Centered, narrow column used by sign-in, sign-up and onboarding.
class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.storefront_outlined, size: 44, color: theme.colorScheme.primary),
                  const SizedBox(height: AppSpacing.lg),
                  Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(subtitle!,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
