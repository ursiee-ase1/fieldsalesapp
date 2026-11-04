import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../auth/domain/models.dart';
import '../../members/data/members_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/targets_repository.dart';

class TargetsTab extends ConsumerWidget {
  const TargetsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(targetsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'set-target',
        onPressed: () => showDialog<void>(context: context, builder: (_) => const _SetTargetDialog()),
        icon: const Icon(Icons.flag_outlined),
        label: const Text('Set target'),
      ),
      body: targets.when(
        loading: () => const StateView.loading(),
        error: (e, _) => StateView.error(message: describeError(e), onRetry: () => ref.invalidate(targetsProvider)),
        data: (list) => list.isEmpty
            ? const StateView.empty(
                icon: Icons.flag_outlined,
                title: 'No daily targets',
                message: 'Set a target for every agent, or a different one for a specific agent.',
              )
            : PageBody(
                maxWidth: Breakpoints.expanded,
                children: [
                  const Text('A target for a specific agent replaces the company-wide target for that agent.'),
                  for (final t in list)
                    Card(
                      child: ListTile(
                        leading: Icon(t.scope == 'agent' ? Icons.person_outline : Icons.groups_outlined),
                        title: Text('${t.appliesTo}: ${t.metric == TargetMetric.amount ? formatMoney(t.value) : '${t.value} items'} a day'),
                        subtitle: Text([
                          t.productName ?? 'All products',
                          'from ${formatDay(t.effectiveFrom)}',
                        ].join(' · ')),
                      ),
                    ),
                  const SizedBox(height: 72),
                ],
              ),
      ),
    );
  }
}

class _SetTargetDialog extends ConsumerStatefulWidget {
  const _SetTargetDialog();

  @override
  ConsumerState<_SetTargetDialog> createState() => _SetTargetDialogState();
}

class _SetTargetDialogState extends ConsumerState<_SetTargetDialog> {
  final _formKey = GlobalKey<FormState>();
  final _value = TextEditingController();
  String? _agentId; // null = every agent
  String? _productId; // null = all products
  var _metric = TargetMetric.units;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(targetsRepositoryProvider).set(
            scope: _agentId == null ? TargetScope.company : TargetScope.agent,
            metric: _metric,
            value: num.parse(_value.text.trim()),
            agentId: _agentId,
            productId: _productId,
          );
      ref.invalidate(targetsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref.watch(membersProvider).value?.where((m) => m.role == MemberRole.agent).toList() ?? const [];
    final products = ref.watch(productsProvider).value?.where((p) => p.active).toList() ?? const [];
    return AlertDialog(
      title: const Text('Set a daily target'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: _agentId,
                decoration: const InputDecoration(labelText: 'Applies to'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Every agent')),
                  for (final a in agents) DropdownMenuItem(value: a.userId, child: Text(a.fullName)),
                ],
                onChanged: (v) => setState(() => _agentId = v),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String?>(
                initialValue: _productId,
                decoration: const InputDecoration(labelText: 'Product'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All products')),
                  for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => setState(() => _productId = v),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<TargetMetric>(
                initialValue: _metric,
                decoration: const InputDecoration(labelText: 'Measure'),
                items: [for (final m in TargetMetric.values) DropdownMenuItem(value: m, child: Text(m.label))],
                onChanged: (v) => setState(() => _metric = v!),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Target per day'),
                validator: (v) {
                  final n = num.tryParse((v ?? '').trim());
                  return n == null || n <= 0 ? 'Enter a number above 0' : null;
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text('Starts today and replaces any earlier target for the same choice.'),
              if (_error != null) ...[const SizedBox(height: AppSpacing.md), InlineMessage.error(_error!)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        BusyButton(label: 'Save target', busy: _busy, onPressed: _save),
      ],
    );
  }
}
