import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/errors.dart';
import '../data/profile_repository.dart';
import 'company_settings_card.dart';
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
        if (m.role == MemberRole.agent) _AssistantLanguageCard(current: session.context.preferredLanguage),
        if (can(m.role, Capability.manageCompanySettings)) const CompanySettingsCard(),
        OutlinedButton.icon(
          onPressed: () => ref.read(sessionProvider.notifier).signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _AssistantLanguageCard extends ConsumerStatefulWidget {
  const _AssistantLanguageCard({required this.current});

  final String current;

  @override
  ConsumerState<_AssistantLanguageCard> createState() => _AssistantLanguageCardState();
}

class _AssistantLanguageCardState extends ConsumerState<_AssistantLanguageCard> {
  var _busy = false;

  Future<void> _set(String language) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(profileRepositoryProvider).setPreferredLanguage(language);
      await ref.read(sessionProvider.notifier).refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Assistant language',
      icon: Icons.translate,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('The language the reporting assistant speaks with you. You can mix English and Twi either way.'),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('English')),
              ButtonSegment(value: 'tw', label: Text('Twi')),
            ],
            selected: {widget.current},
            onSelectionChanged: _busy ? null : (s) => _set(s.first),
          ),
        ],
      ),
    );
  }
}
