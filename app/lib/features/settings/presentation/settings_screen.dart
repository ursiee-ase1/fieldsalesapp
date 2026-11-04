import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/models.dart';
import '../../auth/domain/permissions.dart';

/// Account and company settings. Used by every role; company sections only
/// appear for roles that can manage them.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session is! SignedIn) return const SizedBox.shrink();
    final m = session.membership;

    return PageBody(
      children: [
        SectionCard(
          title: 'Your account',
          icon: Icons.person_outline,
          child: Column(
            children: [
              ListTile(contentPadding: EdgeInsets.zero, title: const Text('Name'), subtitle: Text(session.context.fullName ?? '—')),
              ListTile(contentPadding: EdgeInsets.zero, title: const Text('Role'), subtitle: Text(m.role.label)),
              ListTile(contentPadding: EdgeInsets.zero, title: const Text('Company'), subtitle: Text(m.companyName)),
            ],
          ),
        ),
        if (can(m.role, Capability.manageCompanySettings))
          const SectionCard(
            title: 'Company settings',
            icon: Icons.business_outlined,
            child: Text('Products, targets, reminders and assistant settings will be managed here.'),
          ),
        OutlinedButton.icon(
          onPressed: () => ref.read(sessionProvider.notifier).signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
