import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../auth/domain/models.dart';
import '../../members/data/members_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/inventory_repository.dart';

enum StockAction {
  receive('Receive into store', Icons.move_to_inbox_outlined),
  issue('Issue to agent', Icons.outbox_outlined),
  ret('Return from agent', Icons.assignment_return_outlined),
  damage('Record damaged', Icons.broken_image_outlined),
  loss('Record lost', Icons.report_gmailerrorred_outlined),
  adjust('Correct stock', Icons.tune);

  const StockAction(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get needsAgent => this == issue || this == ret;
  bool get allowsAgent => this != receive;
  bool get needsReason => this == damage || this == loss || this == adjust;
}

Future<void> showStockActionSheet(BuildContext context, StockAction action) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: _StockActionForm(action: action),
      ),
    );

class _StockActionForm extends ConsumerStatefulWidget {
  const _StockActionForm({required this.action});

  final StockAction action;

  @override
  ConsumerState<_StockActionForm> createState() => _StockActionFormState();
}

class _StockActionFormState extends ConsumerState<_StockActionForm> {
  final _formKey = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  // One id per form, so a retry after a network error can't apply twice.
  final _opId = newId();
  String? _productId;
  String? _agentId;
  var _add = true; // for corrections: add or remove
  var _busy = false;
  String? _error;

  StockAction get _action => widget.action;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(inventoryRepositoryProvider);
    final qty = int.parse(_qty.text.trim());
    final reason = _reason.text.trim().isEmpty ? null : _reason.text.trim();
    try {
      switch (_action) {
        case StockAction.receive || StockAction.issue || StockAction.ret:
          await repo.transfer(
            opId: _opId,
            kind: switch (_action) {
              StockAction.receive => TransferKind.receipt,
              StockAction.issue => TransferKind.issue,
              _ => TransferKind.ret,
            },
            lines: [StockLine(_productId!, qty)],
            agentId: _agentId,
            note: reason,
          );
        case StockAction.damage || StockAction.loss:
          await repo.writeOff(
              opId: _opId, type: _action.name, productId: _productId!, quantity: qty, reason: reason!, agentId: _agentId);
        case StockAction.adjust:
          await repo.adjust(
              opId: _opId, productId: _productId!, delta: _add ? qty : -qty, reason: reason!, agentId: _agentId);
      }
      invalidateInventory(ref);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_action.label}: saved')));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider).value?.where((p) => p.active).toList() ?? const [];
    final agents = ref.watch(membersProvider).value
            ?.where((m) => m.role == MemberRole.agent && m.status == MemberStatus.active)
            .toList() ??
        const [];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.xl),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(_action.icon),
              const SizedBox(width: AppSpacing.sm),
              Text(_action.label, style: Theme.of(context).textTheme.titleLarge),
            ]),
            const SizedBox(height: AppSpacing.lg),
            if (_action.allowsAgent) ...[
              DropdownButtonFormField<String?>(
                initialValue: _agentId,
                decoration: InputDecoration(labelText: _action.needsAgent ? 'Agent' : 'Location'),
                items: [
                  if (!_action.needsAgent) const DropdownMenuItem(value: null, child: Text('Company store')),
                  for (final a in agents) DropdownMenuItem(value: a.userId, child: Text(a.fullName)),
                ],
                onChanged: (v) => setState(() => _agentId = v),
                validator: (v) => _action.needsAgent && v == null ? 'Choose an agent' : null,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            DropdownButtonFormField<String>(
              initialValue: _productId,
              decoration: const InputDecoration(labelText: 'Product'),
              items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: (v) => setState(() => _productId = v),
              validator: (v) => v == null ? 'Choose a product' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            if (_action == StockAction.adjust) ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.add), label: Text('Add stock')),
                  ButtonSegment(value: false, icon: Icon(Icons.remove), label: Text('Remove stock')),
                ],
                selected: {_add},
                onSelectionChanged: (s) => setState(() => _add = s.first),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            TextFormField(
              controller: _qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quantity'),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n <= 0 ? 'Enter a whole number above 0' : null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _reason,
              decoration: InputDecoration(labelText: _action.needsReason ? 'Reason' : 'Note (optional)'),
              validator: (v) => _action.needsReason && (v ?? '').trim().isEmpty ? 'A reason is required' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.error(_error!),
            ],
            const SizedBox(height: AppSpacing.lg),
            BusyButton(label: 'Save', busy: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
