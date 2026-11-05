import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/charts.dart';
import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../../core/routing/redirect.dart';
import '../../reports/data/reports_repository.dart';
import '../data/dashboard_repository.dart';

class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(overviewProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(overviewProvider.future),
      child: overview.when(
        loading: () => const StateView.loading(),
        error: (e, _) => StateView.error(message: describeError(e), onRetry: () => ref.invalidate(overviewProvider)),
        data: (o) => PageBody(
          maxWidth: Breakpoints.expanded,
          children: [
            _DateBar(date: o.date),
            StatGrid(children: [
              StatTile(
                icon: Icons.point_of_sale_outlined,
                label: 'Sales',
                value: formatMoney(o.today.amount),
                caption: '${o.today.salesCount} sales · ${o.today.units} items',
              ),
              StatTile(
                icon: Icons.date_range_outlined,
                label: 'Last 7 days',
                value: formatMoney(o.week.amount),
                caption: '${o.week.salesCount} sales · ${o.week.units} items',
              ),
              StatTile(
                icon: Icons.how_to_reg_outlined,
                label: 'Agents reported',
                value: '${o.reportedCount} of ${o.agents.length}',
                caption: o.agents.length == o.reportedCount ? 'Everyone has reported' : null,
              ),
              StatTile(
                icon: Icons.person_add_alt,
                label: 'New customers',
                value: '${o.newCustomersToday}',
                caption: '${o.newCustomersWeek} in the last 7 days',
              ),
            ]),
            _AttentionCard(o: o),
            _AgentsCard(agents: o.agents),
            SectionCard(
              title: 'Sales, last 7 days',
              icon: Icons.bar_chart,
              child: DailyBars(
                points: [for (final d in o.weekByDay) ChartPoint(d.date, d.value)],
                format: formatMoney,
              ),
            ),
            SectionCard(
              title: 'Stock',
              icon: Icons.inventory_2_outlined,
              trailing: TextButton.icon(
                onPressed: () => context.go(Routes.inventory),
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Inventory'),
              ),
              child: Wrap(spacing: AppSpacing.xxl, runSpacing: AppSpacing.md, children: [
                _Figure('In the store', '${o.stockInStore}'),
                _Figure('With agents', '${o.stockWithAgents}'),
                _Figure('Total', '${o.stockInStore + o.stockWithAgents}'),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateBar extends ConsumerWidget {
  const _DateBar({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A selected date is always in the past: the notifier turns "today or
    // later" back into the live view.
    final isToday = ref.watch(overviewDateProvider) == null;
    final notifier = ref.read(overviewDateProvider.notifier);
    DateTime shift(int days) => DateTime(date.year, date.month, date.day + days);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.sm,
      children: [
        OutlinedButton.icon(
          onPressed: () => notifier.set(shift(-1)),
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous day'),
        ),
        Text(isToday ? 'Today, ${formatDay(date)}' : formatDay(date), style: Theme.of(context).textTheme.titleMedium),
        if (!isToday) ...[
          OutlinedButton.icon(
            onPressed: () => notifier.set(shift(1)),
            icon: const Icon(Icons.chevron_right),
            label: const Text('Next day'),
          ),
          TextButton.icon(onPressed: () => notifier.set(null), icon: const Icon(Icons.today), label: const Text('Today')),
        ],
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: theme.textTheme.titleLarge),
      Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.o});

  final Overview o;

  @override
  Widget build(BuildContext context) {
    final notReported = o.agents.length - o.reportedCount;
    final items = [
      if (notReported > 0)
        (Icons.schedule, '$notReported agent${notReported == 1 ? ' has' : 's have'} not reported', null as String?),
      if (o.openDiscrepancies > 0)
        (Icons.rule, '${o.openDiscrepancies} stock count${o.openDiscrepancies == 1 ? '' : 's'} to check', Routes.inventory),
      if (o.duplicateReviews > 0)
        (Icons.people_alt_outlined, '${o.duplicateReviews} possible duplicate customer${o.duplicateReviews == 1 ? '' : 's'}',
            Routes.customers),
      if (o.flaggedSalesToday > 0)
        (Icons.flag_outlined, '${o.flaggedSalesToday} flagged sale${o.flaggedSalesToday == 1 ? '' : 's'}', Routes.sales),
      if (o.followUpsDue > 0)
        (Icons.event_note_outlined, '${o.followUpsDue} customer follow-up${o.followUpsDue == 1 ? '' : 's'} due', Routes.customers),
    ];
    return SectionCard(
      title: 'Needs attention',
      icon: Icons.notifications_none,
      child: items.isEmpty
          ? const Row(children: [Icon(Icons.check_circle_outline, color: AppColors.success), SizedBox(width: AppSpacing.sm),
              Text('Nothing needs attention.')])
          : Column(children: [
              for (final (icon, text, route) in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon, color: AppColors.warning),
                  title: Text(text),
                  trailing: route == null
                      ? null
                      : TextButton.icon(
                          onPressed: () => context.go(route),
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Open'),
                        ),
                ),
            ]),
    );
  }
}

/// Report state is shown with an icon and words, never colour alone.
class ReportStatusLabel extends StatelessWidget {
  const ReportStatusLabel({super.key, required this.state});

  final ReportState state;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (state) {
      ReportState.none => (Icons.schedule, 'Not reported', AppColors.warning),
      ReportState.zeroSales => (Icons.check_circle_outline, 'Reported, no sales', AppColors.success),
      ReportState.withSales => (Icons.check_circle, 'Reported', AppColors.success),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: AppSpacing.xs),
      Flexible(child: Text(text, style: Theme.of(context).textTheme.labelLarge)),
    ]);
  }
}

class _AgentsCard extends StatelessWidget {
  const _AgentsCard({required this.agents});

  final List<AgentToday> agents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SectionCard(
      title: 'Agents',
      icon: Icons.groups_outlined,
      child: agents.isEmpty
          ? const Text('No active agents yet. Add them under Agents.')
          : Column(children: [
              for (final a in agents) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xs),
                      ReportStatusLabel(state: a.state),
                      Text(
                        a.lastReportAt != null
                            ? 'Last report ${formatDateTime(a.lastReportAt!)}'
                            : a.lastReportAny != null
                                ? 'Last report ${formatDateTime(a.lastReportAny!)}'
                                : 'Has never reported',
                        style: muted,
                      ),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(formatMoney(a.amount), style: theme.textTheme.titleSmall),
                    Text('${a.units} items', style: muted),
                  ]),
                ]),
                if (a.mainTarget != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _TargetBar(target: a.mainTarget!),
                ],
                if (a.missingCounts > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('${a.missingCounts} product${a.missingCounts == 1 ? '' : 's'} not counted', style: muted),
                  ),
                const Divider(height: AppSpacing.xl),
              ],
            ]),
    );
  }
}

class _TargetBar extends StatelessWidget {
  const _TargetBar({required this.target});

  final TargetProgress target;

  @override
  Widget build(BuildContext context) {
    String fmt(num v) => target.isAmount ? formatMoney(v) : '$v';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Target: ${fmt(target.achieved)} of ${fmt(target.target)} (${target.progressPct}%)',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: AppSpacing.xs),
      LinearProgressIndicator(
        value: (target.progressPct / 100).clamp(0, 1).toDouble(),
        minHeight: 6,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        semanticsLabel: 'Target progress',
        semanticsValue: '${target.progressPct}%',
      ),
    ]);
  }
}
