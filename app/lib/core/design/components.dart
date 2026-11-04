import 'package:flutter/material.dart';

import 'tokens.dart';

/// Scrollable page body with the standard gutter and a max content width.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = Breakpoints.contentMax});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.page),
          children: _spaced(children),
        ),
      ),
    );
  }

  static List<Widget> _spaced(List<Widget> items) => [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.lg),
          items[i],
        ],
      ];
}

/// Card with a title row and arbitrary content.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.icon, this.trailing});

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                ?trailing,
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}

enum StateKind { loading, empty, error, offline }

/// One component for loading, empty, error and offline states, so every
/// screen reports them the same way.
class StateView extends StatelessWidget {
  const StateView.loading({super.key, this.message})
      : kind = StateKind.loading, title = null, icon = null, onRetry = null;

  const StateView.empty({super.key, required String this.title, this.message, this.icon})
      : kind = StateKind.empty, onRetry = null;

  const StateView.error({super.key, this.message, this.onRetry})
      : kind = StateKind.error, title = 'Something went wrong', icon = Icons.error_outline;

  const StateView.offline({super.key, this.message, this.onRetry})
      : kind = StateKind.offline, title = "You're offline", icon = Icons.cloud_off_outlined;

  final StateKind kind;
  final String? title;
  final String? message;
  final IconData? icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kind == StateKind.error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == StateKind.loading)
              const CircularProgressIndicator()
            else
              Icon(icon ?? Icons.inbox_outlined, size: 40, color: color),
            if (title != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(title!, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            ],
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(message!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline banner for errors/success inside forms.
class InlineMessage extends StatelessWidget {
  const InlineMessage.error(this.message, {super.key}) : isError = true;
  const InlineMessage.success(this.message, {super.key}) : isError = false;

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = isError ? scheme.errorContainer : scheme.primaryContainer;
    final fg = isError ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.all(AppRadius.sm)),
        child: Row(
          children: [
            Icon(isError ? Icons.error_outline : Icons.check_circle_outline, color: fg, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: TextStyle(color: fg))),
          ],
        ),
      ),
    );
  }
}

/// Primary button that shows a spinner while [busy].
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    );
  }
}
