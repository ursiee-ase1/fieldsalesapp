import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../products/presentation/products_tab.dart';
import '../data/inventory_repository.dart';
import 'stock_action_sheet.dart';

class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.warehouse_outlined), text: 'Company stock'),
              Tab(icon: Icon(Icons.person_pin_outlined), text: 'By agent'),
              Tab(icon: Icon(Icons.swap_horiz), text: 'Movements'),
              Tab(icon: Icon(Icons.rule), text: 'Discrepancies'),
              Tab(icon: Icon(Icons.category_outlined), text: 'Products'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _WithStockActions(child: const _SummaryTab()),
                _WithStockActions(child: const _ByAgentTab()),
                _WithStockActions(child: const _MovementsTab()),
                const _DiscrepanciesTab(),
                const ProductsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Adds the "Stock action" button (labelled menu of ledger operations).
class _WithStockActions extends StatelessWidget {
  const _WithStockActions({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      floatingActionButton: MenuAnchor(
        menuChildren: [
          for (final a in StockAction.values)
            MenuItemButton(
              leadingIcon: Icon(a.icon),
              onPressed: () => showStockActionSheet(context, a),
              child: Text(a.label),
            ),
        ],
        builder: (context, controller, _) => FloatingActionButton.extended(
          heroTag: null,
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.inventory_outlined),
          label: const Text('Stock action'),
        ),
      ),
    );
  }
}

Widget _async<T>(AsyncValue<List<T>> value, VoidCallback retry,
    {required Widget empty, required Widget Function(List<T>) data}) {
  return value.when(
    loading: () => const StateView.loading(),
    error: (e, _) => StateView.error(message: describeError(e), onRetry: retry),
    data: (list) => list.isEmpty ? empty : data(list),
  );
}

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _async(
      ref.watch(inventorySummaryProvider),
      () => ref.invalidate(inventorySummaryProvider),
      empty: const StateView.empty(
        icon: Icons.warehouse_outlined,
        title: 'No products yet',
        message: 'Add products in the Products tab, then receive stock into the store.',
      ),
      data: (rows) => PageBody(
        maxWidth: Breakpoints.expanded,
        children: [
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Product')),
                  DataColumn(label: Text('In store'), numeric: true),
                  DataColumn(label: Text('With agents'), numeric: true),
                  DataColumn(label: Text('Total'), numeric: true),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(cells: [
                      DataCell(Text(r.active ? r.name : '${r.name} (inactive)')),
                      DataCell(Text('${r.inStore}')),
                      DataCell(Text('${r.withAgents}')),
                      DataCell(Text('${r.total}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 72),
        ],
      ),
    );
  }
}

class _ByAgentTab extends ConsumerWidget {
  const _ByAgentTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _async(
      ref.watch(stockByAgentProvider),
      () => ref.invalidate(stockByAgentProvider),
      empty: const StateView.empty(
        icon: Icons.person_pin_outlined,
        title: 'No stock with agents',
        message: 'Use "Stock action → Issue to agent" to give agents stock.',
      ),
      data: (rows) {
        final byAgent = <String, List<AgentStockRow>>{};
        for (final r in rows) {
          byAgent.putIfAbsent(r.agentName, () => []).add(r);
        }
        return PageBody(
          maxWidth: Breakpoints.expanded,
          children: [
            for (final entry in byAgent.entries)
              SectionCard(
                title: entry.key,
                icon: Icons.person_outline,
                child: Column(
                  children: [
                    for (final r in entry.value)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(r.productName),
                        trailing: Text('${r.quantity}',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: r.quantity < 0 ? Theme.of(context).colorScheme.error : null)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 72),
          ],
        );
      },
    );
  }
}

class _MovementsTab extends ConsumerWidget {
  const _MovementsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _async(
      ref.watch(movementsProvider),
      () => ref.invalidate(movementsProvider),
      empty: const StateView.empty(icon: Icons.swap_horiz, title: 'No stock movements yet'),
      data: (rows) => PageBody(
        maxWidth: Breakpoints.expanded,
        children: [
          for (final m in rows)
            Card(
              child: ListTile(
                title: Text('${movementLabel(m.type)} · ${m.quantity} × ${m.productName}'),
                subtitle: Text([
                  '${m.fromName} → ${m.toName}',
                  formatDateTime(m.createdAt),
                  if (m.performedBy != null) 'by ${m.performedBy}',
                  if (m.reason != null) m.reason!,
                ].join(' · ')),
              ),
            ),
          const SizedBox(height: 72),
        ],
      ),
    );
  }
}

class _DiscrepanciesTab extends ConsumerWidget {
  const _DiscrepanciesTab();

  Future<void> _resolve(BuildContext context, WidgetRef ref, Discrepancy d, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(inventoryRepositoryProvider).resolveDiscrepancy(d.id, action);
      invalidateInventory(ref);
      messenger.showSnackBar(const SnackBar(content: Text('Discrepancy resolved')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _async(
      ref.watch(openDiscrepanciesProvider),
      () => ref.invalidate(openDiscrepanciesProvider),
      empty: const StateView.empty(
        icon: Icons.verified_outlined,
        title: 'No open discrepancies',
        message: "Agents' daily stock counts match the records.",
      ),
      data: (rows) => PageBody(
        maxWidth: Breakpoints.expanded,
        children: [
          for (final d in rows)
            SectionCard(
              title: '${d.agentName} · ${d.productName}',
              icon: d.difference < 0 ? Icons.trending_down : Icons.trending_up,
              trailing: Text(formatDay(d.businessDate)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Expected ${d.expected}, counted ${d.reported} '
                      '(${d.difference > 0 ? '+' : ''}${d.difference})'),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _resolve(context, ref, d, 'adjust'),
                        icon: const Icon(Icons.tune),
                        label: const Text('Accept count'),
                      ),
                      if (d.difference < 0)
                        OutlinedButton.icon(
                          onPressed: () => _resolve(context, ref, d, 'write_off'),
                          icon: const Icon(Icons.report_gmailerrorred_outlined),
                          label: const Text('Record as lost'),
                        ),
                      TextButton.icon(
                        onPressed: () => _resolve(context, ref, d, 'dismiss'),
                        icon: const Icon(Icons.close),
                        label: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
