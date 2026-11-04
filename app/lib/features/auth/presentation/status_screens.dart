import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../application/session_controller.dart';

/// Shown while the session loads, or if loading it failed.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return Scaffold(
      body: session.hasError
          ? StateView.error(
              message: describeError(session.error!),
              onRetry: () => ref.invalidate(sessionProvider),
            )
          : const StateView.loading(),
    );
  }
}

class SuspendedScreen extends ConsumerWidget {
  const SuspendedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StateView.empty(
              icon: Icons.lock_outline,
              title: 'Your account is suspended',
              message: 'Contact your manager or company administrator to restore access.',
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(
              onPressed: () => ref.read(sessionProvider.notifier).signOut(),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
