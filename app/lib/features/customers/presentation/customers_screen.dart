import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../../core/phone.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/models.dart';
import '../data/customers_repository.dart';

/// Customer list for every role. Managers can edit and resolve possible
/// duplicates; agents see the customers they work with.
class CustomersScreen extends ConsumerWidget {
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final isManager = session is SignedIn && session.role.isManagement;
    final customers = ref.watch(customersProvider);

    return PageBody(
      maxWidth: Breakpoints.expanded,
      children: [
        TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search by name or phone'),
          onChanged: (v) => ref.read(customerSearchProvider.notifier).set(v),
        ),
        if (isManager) const _MatchReviewsBanner(),
        ...customers.when(
          loading: () => [const SizedBox(height: 160, child: StateView.loading())],
          error: (e, _) => [StateView.error(message: describeError(e), onRetry: () => ref.invalidate(customersProvider))],
          data: (list) => list.isEmpty
              ? [
                  StateView.empty(
                    icon: Icons.people_outline,
                    title: 'No customers found',
                    message: isManager
                        ? 'Customers appear here when agents record them in their reports.'
                        : 'Customers you add in your daily report appear here.',
                  ),
                ]
              : [for (final c in list) _CustomerTile(customer: c, canEdit: isManager)],
        ),
      ],
    );
  }
}

class _CustomerTile extends StatelessWidget {
  const _CustomerTile({required this.customer, required this.canEdit});

  final Customer customer;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final c = customer;
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(c.fullName.characters.first.toUpperCase())),
        title: Text(c.fullName),
        subtitle: Text([
          if (c.phone != null) c.phone!,
          if (c.location != null) c.location!,
          if (c.nextFollowUp != null) 'Follow up ${formatDay(c.nextFollowUp!)}',
          if (c.lastInteractionAt != null) 'Last seen ${formatDateTime(c.lastInteractionAt!)}',
        ].join(' · ')),
        trailing: canEdit
            ? TextButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => _EditCustomerDialog(customer: c)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              )
            : null,
      ),
    );
  }
}

class _MatchReviewsBanner extends ConsumerWidget {
  const _MatchReviewsBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviews = ref.watch(matchReviewsProvider).value ?? const [];
    if (reviews.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Possible duplicate customers (${reviews.length})',
      icon: Icons.people_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in reviews) _MatchReviewRow(review: r),
        ],
      ),
    );
  }
}

class _MatchReviewRow extends ConsumerWidget {
  const _MatchReviewRow({required this.review});

  final MatchReview review;

  Future<void> _resolve(BuildContext context, WidgetRef ref, bool same) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(customersRepositoryProvider).resolveMatch(review.id, same: same);
      ref
        ..invalidate(matchReviewsProvider)
        ..invalidate(customersProvider);
      messenger.showSnackBar(SnackBar(content: Text(same ? 'Records combined' : 'Kept as separate customers')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('"${review.newName}" (added by ${review.createdByName ?? 'an agent'}) has the same phone '
              '${review.phone ?? ''} as "${review.candidateName}". Same person?'),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: () => _resolve(context, ref, true),
                icon: const Icon(Icons.merge_type),
                label: const Text('Same person — combine'),
              ),
              OutlinedButton.icon(
                onPressed: () => _resolve(context, ref, false),
                icon: const Icon(Icons.call_split),
                label: const Text('Different people'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditCustomerDialog extends ConsumerStatefulWidget {
  const _EditCustomerDialog({required this.customer});

  final Customer customer;

  @override
  ConsumerState<_EditCustomerDialog> createState() => _EditCustomerDialogState();
}

class _EditCustomerDialogState extends ConsumerState<_EditCustomerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.customer.fullName);
  late final _phone = TextEditingController(text: widget.customer.phone);
  late final _location = TextEditingController(text: widget.customer.location);
  late final _notes = TextEditingController(text: widget.customer.notes);
  late bool _consent = widget.customer.consentGiven;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _trimmed(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(customersRepositoryProvider).update(
            widget.customer,
            fullName: _name.text.trim(),
            phone: _trimmed(_phone),
            location: _trimmed(_location),
            notes: _trimmed(_notes),
            consent: _consent,
          );
      ref.invalidate(customersProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit customer'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Enter a name' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone'),
                  validator: (v) =>
                      (v ?? '').trim().isNotEmpty && normalizeGhanaPhone(v!) == null ? 'Enter a valid Ghana number' : null,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _consent,
                  onChanged: (v) => setState(() => _consent = v ?? false),
                  title: const Text('Customer agreed to share their number'),
                ),
                TextFormField(controller: _location, decoration: const InputDecoration(labelText: 'Location')),
                const SizedBox(height: AppSpacing.md),
                TextFormField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
                if (_error != null) ...[const SizedBox(height: AppSpacing.md), InlineMessage.error(_error!)],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        BusyButton(label: 'Save', busy: _busy, onPressed: _save),
      ],
    );
  }
}
