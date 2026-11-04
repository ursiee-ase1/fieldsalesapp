import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../products/data/products_repository.dart';
import '../data/reports_repository.dart';
import '../domain/report_draft.dart';

/// Structured daily report. Works without the AI assistant and produces the
/// same payload it will.
class ReportFormScreen extends ConsumerStatefulWidget {
  const ReportFormScreen({super.key});

  @override
  ConsumerState<ReportFormScreen> createState() => _ReportFormScreenState();
}

class _ReportFormScreenState extends ConsumerState<ReportFormScreen> {
  final _draft = ReportDraft();
  // Stable for this draft: a resend after a dropped connection is a replay.
  final _opId = newId();
  var _busy = false;
  String? _error;

  void _changed() => setState(() => _error = null);

  Future<void> _review(AgentHome home, List<Product> products) async {
    final issues = _draft.check(
      alreadyReportedToday: home.reportState != ReportState.none,
      heldProducts: {for (final s in home.stock) s.productId: s.name},
      today: home.businessDate,
    );
    if (!issues.canSubmit) {
      setState(() => _error = issues.errors.join('\n'));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _SummaryDialog(draft: _draft, products: products, home: home, warnings: issues.warnings),
    );
    if (confirmed == true) await _submit();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(reportsRepositoryProvider).submit(_opId, _draft, capturedAt: DateTime.now());
      ref.invalidate(agentHomeProvider);
      if (!mounted) return;
      final notes = [
        if (result.lateSync) 'Recorded for ${formatDay(result.businessDate)}.',
        if (result.discrepancyCount > 0)
          'Your stock count differs from our records for ${result.discrepancyCount} product(s). Your manager will check it.',
        if (result.matchReviewCount > 0) 'A possible duplicate customer will be checked by your manager.',
      ];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(['Report sent. Thank you!', ...notes].join(' ')),
      ));
      context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(agentHomeProvider);
    final products = ref.watch(productsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Daily report')),
      body: switch ((home, products)) {
        (AsyncData(value: final h), AsyncData(value: final p)) => _form(h, p.where((x) => x.active).toList()),
        (AsyncError(:final error), _) || (_, AsyncError(:final error)) => StateView.error(
            message: describeError(error),
            onRetry: () => ref
              ..invalidate(agentHomeProvider)
              ..invalidate(productsProvider),
          ),
        _ => const StateView.loading(),
      },
    );
  }

  Widget _form(AgentHome home, List<Product> products) {
    final amending = home.reportState != ReportState.none;
    return PageBody(
      children: [
        if (amending)
          const InlineMessage.success("You've already reported today. Anything you add here is added to today's report."),
        _SalesSection(draft: _draft, products: products, onChanged: _changed),
        _CustomersSection(draft: _draft, products: products, onChanged: _changed),
        if (home.followUps.isNotEmpty) _FollowUpsSection(draft: _draft, followUps: home.followUps, onChanged: _changed),
        _StockSection(draft: _draft, stock: home.stock, onChanged: _changed),
        SectionCard(
          title: 'Other notes',
          icon: Icons.notes_outlined,
          child: Column(
            children: [
              TextFormField(
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'People you spoke to who did not buy (optional)',
                  prefixIcon: Icon(Icons.record_voice_over_outlined),
                ),
                onChanged: (v) {
                  _draft.prospectsCount = int.tryParse(v.trim());
                  _changed();
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Comments (optional)', prefixIcon: Icon(Icons.comment_outlined)),
                onChanged: (v) => _draft.comments = v,
              ),
            ],
          ),
        ),
        if (_error != null) InlineMessage.error(_error!),
        BusyButton(label: 'Review and send', busy: _busy, onPressed: () => _review(home, products)),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

// --- Sales ---------------------------------------------------------------------

class _SalesSection extends StatelessWidget {
  const _SalesSection({required this.draft, required this.products, required this.onChanged});

  final ReportDraft draft;
  final List<Product> products;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Sales',
      icon: Icons.point_of_sale_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in draft.sales)
            _SaleCard(
              key: ValueKey(s.id),
              sale: s,
              products: products,
              customers: draft.customers,
              onChanged: onChanged,
              onRemove: () {
                draft.sales.remove(s);
                onChanged();
              },
            ),
          if (products.isEmpty)
            const Text('No products are set up yet. Ask your manager.')
          else
            OutlinedButton.icon(
              onPressed: () {
                draft
                  ..noSales = false
                  ..sales.add(SaleLine(productId: products.first.id));
                onChanged();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add a sale'),
            ),
          if (draft.sales.isEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: draft.noSales,
              onChanged: (v) {
                draft.noSales = v ?? false;
                onChanged();
              },
              title: const Text('I made no sales today'),
              subtitle: const Text("That's fine — it still counts as a report."),
            ),
        ],
      ),
    );
  }
}

class _SaleCard extends StatelessWidget {
  const _SaleCard({
    super.key,
    required this.sale,
    required this.products,
    required this.customers,
    required this.onChanged,
    required this.onRemove,
  });

  final SaleLine sale;
  final List<Product> products;
  final List<CustomerEntry> customers;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final product = products.firstWhere((p) => p.id == sale.productId, orElse: () => products.first);
    final price = sale.unitPrice ?? product.unitPrice;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: const BorderRadius.all(AppRadius.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: product.id,
                decoration: const InputDecoration(labelText: 'Product'),
                items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name))],
                onChanged: (v) {
                  sale
                    ..productId = v!
                    ..unitPrice = null;
                  onChanged();
                },
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: '${sale.quantity}',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Quantity'),
                      onChanged: (v) {
                        sale.quantity = int.tryParse(v.trim()) ?? 0;
                        onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey('price-${sale.productId}'),
                      initialValue: '$price',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Price each (GH₵)'),
                      onChanged: (v) {
                        final n = num.tryParse(v.trim());
                        sale.unitPrice = n == product.unitPrice ? null : n;
                        onChanged();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<PaymentMethod>(
                segments: const [
                  ButtonSegment(value: PaymentMethod.cash, icon: Icon(Icons.payments_outlined), label: Text('Cash')),
                  ButtonSegment(value: PaymentMethod.momo, icon: Icon(Icons.phone_android), label: Text('Mobile Money')),
                ],
                selected: {sale.payment},
                onSelectionChanged: (s) {
                  sale.payment = s.first;
                  onChanged();
                },
              ),
              if (customers.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String?>(
                  initialValue: sale.customerRef,
                  decoration: const InputDecoration(labelText: 'Customer (optional)'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Not recorded')),
                    for (final c in customers)
                      DropdownMenuItem(value: c.ref, child: Text(c.displayName.isEmpty ? 'New customer' : c.displayName)),
                  ],
                  onChanged: (v) {
                    sale.customerRef = v;
                    onChanged();
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Text('Total ${formatMoney(price * (sale.quantity > 0 ? sale.quantity : 0))}',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  TextButton.icon(onPressed: onRemove, icon: const Icon(Icons.delete_outline), label: const Text('Remove')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Customers -------------------------------------------------------------------

class _CustomersSection extends StatelessWidget {
  const _CustomersSection({required this.draft, required this.products, required this.onChanged});

  final ReportDraft draft;
  final List<Product> products;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Customers and follow-ups',
      icon: Icons.people_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Add buyers you want to remember and people who asked you to come back.'),
          const SizedBox(height: AppSpacing.md),
          for (final c in draft.customers)
            _CustomerCard(
              key: ValueKey(c.ref),
              customer: c,
              onChanged: onChanged,
              onRemove: () {
                draft.customers.remove(c);
                for (final s in draft.sales.where((s) => s.customerRef == c.ref)) {
                  s.customerRef = null;
                }
                onChanged();
              },
            ),
          OutlinedButton.icon(
            onPressed: () {
              draft.customers.add(CustomerEntry());
              onChanged();
            },
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add a customer'),
          ),
        ],
      ),
    );
  }
}

class _CustomerCard extends ConsumerStatefulWidget {
  const _CustomerCard({super.key, required this.customer, required this.onChanged, required this.onRemove});

  final CustomerEntry customer;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  ConsumerState<_CustomerCard> createState() => _CustomerCardState();
}

class _CustomerCardState extends ConsumerState<_CustomerCard> {
  String? _checkedPhone;

  CustomerEntry get c => widget.customer;

  /// "This phone number is already associated with Ama. Is this the same customer?"
  Future<void> _checkPhone() async {
    final phone = c.normalizedPhone;
    if (phone == null || phone == _checkedPhone || c.isExisting) return;
    _checkedPhone = phone;
    List<PhoneMatch> matches;
    try {
      matches = await ref.read(reportsRepositoryProvider).findByPhone(phone);
    } catch (_) {
      return; // The server checks again on submit and flags duplicates for the manager.
    }
    matches = matches.where((m) => !c.notSameAs.contains(m.customerId)).toList();
    if (matches.isEmpty || !mounted) return;

    final chosen = await showDialog<PhoneMatch?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.person_search_outlined),
        title: const Text('Is this the same customer?'),
        content: Text(matches.length == 1
            ? 'This phone number is already associated with ${matches.first.firstName} (${matches.first.maskedPhone}).'
            : 'This phone number is already associated with: '
                '${matches.map((m) => m.firstName).join(', ')}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('No, a different person')),
          for (final m in matches)
            FilledButton(onPressed: () => Navigator.pop(context, m), child: Text('Yes, it is ${m.firstName}')),
        ],
      ),
    );
    if (chosen == null) {
      c.notSameAs.addAll(matches.map((m) => m.customerId));
    } else {
      c
        ..existingCustomerId = chosen.customerId
        ..existingFirstName = chosen.firstName;
    }
    widget.onChanged();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 90)),
      initialDate: c.followUpDate ?? now.add(const Duration(days: 1)),
      helpText: 'Follow up on',
    );
    if (picked != null) {
      c.followUpDate = picked;
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: const BorderRadius.all(AppRadius.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.isExisting)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text('Existing customer: ${c.existingFirstName}'),
                  subtitle: const Text('This visit will be added to their history.'),
                )
              else ...[
                TextFormField(
                  initialValue: c.fullName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  onChanged: (v) {
                    c.fullName = v;
                    widget.onChanged();
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                Focus(
                  onFocusChange: (hasFocus) {
                    if (!hasFocus) _checkPhone();
                  },
                  child: TextFormField(
                    initialValue: c.phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone (optional)', hintText: '024 123 4567'),
                    onChanged: (v) {
                      c.phone = v;
                      widget.onChanged();
                    },
                  ),
                ),
                if (c.phone.trim().isNotEmpty)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: c.consent,
                    onChanged: (v) {
                      c.consent = v ?? false;
                      widget.onChanged();
                    },
                    title: const Text('The customer agreed to share their number'),
                  ),
                TextFormField(
                  initialValue: c.location,
                  decoration: const InputDecoration(labelText: 'Location (optional)'),
                  onChanged: (v) => c.location = v,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_outlined),
                      label: Text(c.followUpDate == null ? 'Add follow-up date' : 'Follow up ${formatDay(c.followUpDate!)}'),
                    ),
                  ),
                  if (c.followUpDate != null)
                    IconButton(
                      tooltip: 'Remove follow-up',
                      onPressed: () {
                        c.followUpDate = null;
                        widget.onChanged();
                      },
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              if (c.followUpDate != null) ...[
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  initialValue: c.followUpNote,
                  decoration: const InputDecoration(labelText: 'What to follow up on (optional)'),
                  onChanged: (v) => c.followUpNote = v,
                ),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.onRemove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Follow-ups due ------------------------------------------------------------

class _FollowUpsSection extends StatelessWidget {
  const _FollowUpsSection({required this.draft, required this.followUps, required this.onChanged});

  final ReportDraft draft;
  final List<DueFollowUp> followUps;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Follow-ups due',
      icon: Icons.event_note_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in followUps) ...[
            Text('${f.customerName} · ${formatDay(f.dueDate)}', style: Theme.of(context).textTheme.titleSmall),
            if (f.note != null) Text(f.note!),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final o in FollowUpOutcome.values)
                  ChoiceChip(
                    label: Text(o.label),
                    selected: draft.followUpOutcomes[f.id] == o,
                    onSelected: (selected) {
                      if (selected) {
                        draft.followUpOutcomes[f.id] = o;
                      } else {
                        draft.followUpOutcomes.remove(f.id);
                      }
                      onChanged();
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ],
      ),
    );
  }
}

// --- Closing stock -------------------------------------------------------------

class _StockSection extends StatelessWidget {
  const _StockSection({required this.draft, required this.stock, required this.onChanged});

  final ReportDraft draft;
  final List<HeldStock> stock;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Stock left with you',
      icon: Icons.inventory_2_outlined,
      child: stock.isEmpty
          ? const Text('You have no stock issued to you.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Count what you have now, including what you sold today.'),
                const SizedBox(height: AppSpacing.md),
                for (final s in stock) ...[
                  TextFormField(
                    key: ValueKey('count-${s.productId}'),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: '${s.name} — how many left?'),
                    onChanged: (v) {
                      final n = int.tryParse(v.trim());
                      if (n == null) {
                        draft.stockCounts.remove(s.productId);
                      } else {
                        draft.stockCounts[s.productId] = n;
                      }
                      onChanged();
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
    );
  }
}

// --- Confirmation ----------------------------------------------------------------

class _SummaryDialog extends StatelessWidget {
  const _SummaryDialog({required this.draft, required this.products, required this.home, required this.warnings});

  final ReportDraft draft;
  final List<Product> products;
  final AgentHome home;
  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final names = {for (final p in products) p.id: p};
    final stockNames = {for (final s in home.stock) s.productId: s.name};
    final customerNames = {for (final c in draft.customers) c.ref: c.displayName};
    final theme = Theme.of(context);
    num total = 0;
    final saleLines = [
      for (final s in draft.sales)
        () {
          final p = names[s.productId]!;
          final price = s.unitPrice ?? p.unitPrice;
          total += price * s.quantity;
          final who = s.customerRef == null ? '' : ' · ${customerNames[s.customerRef]}';
          return '${s.quantity} × ${p.name} @ ${formatMoney(price)} · ${s.payment.label}$who';
        }(),
    ];

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
          child: Text(text, style: theme.textTheme.titleSmall),
        );

    return AlertDialog(
      title: const Text('Check your report'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading('Sales'),
              if (draft.noSales) const Text('No sales today'),
              if (!draft.noSales && draft.sales.isEmpty) const Text('No new sales'),
              for (final l in saleLines) Text(l),
              if (draft.sales.isNotEmpty) Text('Total: ${formatMoney(total)}', style: theme.textTheme.titleSmall),
              if (draft.customers.isNotEmpty) ...[
                heading('Customers'),
                for (final c in draft.customers)
                  Text([
                    c.displayName,
                    if (!c.isExisting && c.normalizedPhone != null) c.normalizedPhone!,
                    if (c.followUpDate != null) 'follow up ${formatDay(c.followUpDate!)}',
                  ].join(' · ')),
              ],
              if (draft.followUpOutcomes.isNotEmpty) ...[
                heading('Follow-ups'),
                for (final f in home.followUps.where((f) => draft.followUpOutcomes.containsKey(f.id)))
                  Text('${f.customerName}: ${draft.followUpOutcomes[f.id]!.label}'),
              ],
              if (draft.stockCounts.isNotEmpty) ...[
                heading('Stock left'),
                for (final e in draft.stockCounts.entries) Text('${stockNames[e.key] ?? names[e.key]?.name}: ${e.value}'),
              ],
              if (draft.prospectsCount != null) ...[
                heading('Spoke to without a sale'),
                Text('${draft.prospectsCount}'),
              ],
              if (draft.comments.trim().isNotEmpty) ...[heading('Comments'), Text(draft.comments.trim())],
              for (final w in warnings) ...[const SizedBox(height: AppSpacing.md), InlineMessage.error(w)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Make changes'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.send_outlined),
          label: const Text('Confirm and send'),
        ),
      ],
    );
  }
}
