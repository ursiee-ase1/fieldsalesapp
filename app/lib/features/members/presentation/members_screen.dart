import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/models.dart';
import '../../auth/domain/permissions.dart';
import '../data/members_repository.dart';
import 'invite_member_sheet.dart';

class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session is! SignedIn) return const SizedBox.shrink();
    final role = session.role;
    final members = ref.watch(membersProvider);

    return Scaffold(
      floatingActionButton: invitableRoles(role).isEmpty
          ? null
          : FloatingActionButton.extended(
              heroTag: 'add-member',
              onPressed: () => showInviteMemberSheet(context, inviterRole: role),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add member'),
            ),
      body: members.when(
        loading: () => const StateView.loading(),
        error: (e, _) => StateView.error(message: describeError(e), onRetry: () => ref.invalidate(membersProvider)),
        data: (list) {
          final others = list.where((m) => m.userId != session.context.userId).toList();
          if (others.isEmpty) {
            return const StateView.empty(
              icon: Icons.groups_outlined,
              title: 'No team members yet',
              message: 'Add your managers and field agents to get started.',
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(membersProvider.future),
            child: PageBody(
              maxWidth: Breakpoints.expanded,
              children: [
                for (final m in others) _MemberTile(member: m, viewerRole: role),
                const SizedBox(height: 72), // room for the FAB
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.viewerRole});

  final Member member;
  final MemberRole viewerRole;

  bool get _canToggle =>
      can(viewerRole, Capability.changeRoles) ||
      (can(viewerRole, Capability.suspendAgents) && member.role == MemberRole.agent);

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final next = member.status == MemberStatus.active ? MemberStatus.suspended : MemberStatus.active;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(membersRepositoryProvider).setStatus(member.membershipId, next);
      ref.invalidate(membersProvider);
      messenger.showSnackBar(SnackBar(
          content: Text(next == MemberStatus.suspended ? '${member.fullName} suspended' : '${member.fullName} reactivated')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final suspended = member.status == MemberStatus.suspended;
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(member.fullName.characters.first.toUpperCase())),
        title: Text(member.fullName),
        subtitle: Text([member.role.label, if (member.phone != null) member.phone!].join(' · ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (suspended)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Chip(
                  label: const Text('Suspended'),
                  labelStyle: TextStyle(color: theme.colorScheme.onErrorContainer),
                  backgroundColor: theme.colorScheme.errorContainer,
                  side: BorderSide.none,
                ),
              ),
            if (_canToggle)
              PopupMenuButton<void>(
                tooltip: 'Member actions',
                itemBuilder: (_) => [
                  PopupMenuItem(
                    onTap: () => _toggle(context, ref),
                    child: Text(suspended ? 'Reactivate' : 'Suspend'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
