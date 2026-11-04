import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../inventory/data/inventory_repository.dart';
import '../data/sales_repository.dart';

class SalesScreen extends ConsumerWidget {
  const SalesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(salesPeriodProvider);
    final sales = ref.watch(salesProvider);

    return PageBody(
      maxWidth: Breakpoints.expanded,
      children: [
        SegmentedButton<SalesPeriod>(
          segments: [for (final p in SalesPeriod.values) ButtonSegment(value: p, label: Text(p.label))],
          selected: {period},
          onSelectionChanged: (s) => ref.read(salesPeriodProvider.notifier).set(s.first),
        ),
        ...sales.when(
          loading: () => [const SizedBox(height: 160, child: StateView.loading())],
          error: (e, _) => [StateView.error(message: describeError(e), onRetry: () => ref.invalidate(salesProvider))],
          data: (list) {
            if (list.isEmpty) {
              return [const StateView.empty(icon: Icons.point_of_sale_outlined, title: 'No sales in this period')];
            }
            final active = list.where((s) => !s.isVoided);
            final total = active.fold<num>(0, (sum, s) => sum + s.total);
            final units = active.fold<int>(0, (sum, s) => sum + s.quantity);
            return [
              SectionCard(
                title: 'Totals',
                icon: Icons.summarize_outlined,
                child: Text('${active.length} sales · $units items · ${formatMoney(total)}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final s in list) _SaleTile(sale: s),
            ];
          },
        ),
      ],
    );
  }
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale});

  final SaleRecord sale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = sale;
    final flags = [
      if (s.priceFlagged) 'Large discount' else if (s.priceOverride) 'Price changed',
      if (s.stockFlagged) 'More than recorded stock',
    ];
    return Card(
      child: ListTile(
        title: Text(
          '${s.quantity} × ${s.productName} · ${formatMoney(s.total)}',
          style: s.isVoided ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text([
              s.agentName,
              formatDateTime(s.recordedAt),
              s.paymentMethod == 'momo' ? 'Mobile Money' : 'Cash',
              if (s.customerName != null) s.customerName!,
            ].join(' · ')),
            if (s.isVoided) Text('Voided: ${s.voidReason}', style: TextStyle(color: theme.colorScheme.error)),
            if (flags.isNotEmpty && !s.isVoided)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Wrap(
                  spacing: AppSpacing.xs,
                  children: [
                    for (final f in flags)
                      Chip(
                        avatar: const Icon(Icons.flag_outlined, size: 16),
                        label: Text(f),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: s.isVoided
            ? null
            : TextButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => _VoidDialog(sale: s)),
                icon: const Icon(Icons.block),
                label: const Text('Void'),
              ),
      ),
    );
  }
}

class _VoidDialog extends ConsumerStatefulWidget {
  const _VoidDialog({required this.sale});

  final SaleRecord sale;

  @override
  ConsumerState<_VoidDialog> createState() => _VoidDialogState();
}

class _VoidDialogState extends ConsumerState<_VoidDialog> {
  final _reason = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _void() async {
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'A reason is required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(salesRepositoryProvider).voidSale(widget.sale.id, _reason.text.trim());
      ref.invalidate(salesProvider);
      invalidateInventory(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sale;
    return AlertDialog(
      title: const Text('Void this sale?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${s.quantity} × ${s.productName} by ${s.agentName}. The stock goes back to the agent.'),
          const SizedBox(height: AppSpacing.md),
          TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason')),
          if (_error != null) ...[const SizedBox(height: AppSpacing.md), InlineMessage.error(_error!)],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        BusyButton(label: 'Void sale', busy: _busy, onPressed: _void),
      ],
    );
  }
}
