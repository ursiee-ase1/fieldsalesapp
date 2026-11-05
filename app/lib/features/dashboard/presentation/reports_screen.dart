import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/charts.dart';
import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../auth/domain/models.dart';
import '../../members/data/members_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/dashboard_repository.dart';
import '../domain/leaderboard.dart';
import 'conversations_tab.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(children: [
        TabBar(isScrollable: true, tabs: [
          Tab(icon: Icon(Icons.insert_chart_outlined), text: 'Sales report'),
          Tab(icon: Icon(Icons.forum_outlined), text: 'Conversations'),
        ]),
        Expanded(child: TabBarView(children: [_SalesReportTab(), ConversationsTab()])),
      ]),
    );
  }
}

/// Date range, agent and product filters, in one row above the charts.
/// Shared by both tabs (conversations use the date range).
class ReportFilters extends ConsumerWidget {
  const ReportFilters({super.key, this.showDimensions = true});

  final bool showDimensions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(reportFilterProvider);
    final ctrl = ref.read(reportFilterProvider.notifier);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = f.to.difference(f.from).inDays + 1;
    final preset = f.to == today && (days == 7 || days == 30) ? days : 0;
    final agents = ref.watch(membersProvider).value?.where((m) => m.role == MemberRole.agent).toList() ?? const [];
    final products = ref.watch(productsProvider).value ?? const [];

    Future<void> pickRange() async {
      final r = await showDateRangePicker(
        context: context,
        firstDate: today.subtract(const Duration(days: 366)),
        lastDate: today,
        initialDateRange: DateTimeRange(start: f.from, end: f.to),
      );
      if (r != null) ctrl.set(f.copyWith(from: r.start, to: r.end));
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 7, label: Text('7 days')),
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 0, icon: Icon(Icons.date_range), label: Text('Dates')),
          ],
          selected: {preset},
          onSelectionChanged: (s) {
            final v = s.first;
            if (v == 0) {
              pickRange();
            } else {
              ctrl.set(f.copyWith(from: today.subtract(Duration(days: v - 1)), to: today));
            }
          },
        ),
        Text('${formatDay(f.from)} – ${formatDay(f.to)}', style: Theme.of(context).textTheme.bodyMedium),
        if (showDimensions) ...[
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String?>(
              initialValue: f.agentId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Agent', isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('All agents')),
                for (final a in agents) DropdownMenuItem(value: a.userId, child: Text(a.fullName)),
              ],
              onChanged: (v) => ctrl.set(f.copyWith(agentId: () => v)),
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String?>(
              initialValue: f.productId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Product', isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('All products')),
                for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (v) => ctrl.set(f.copyWith(productId: () => v)),
            ),
          ),
        ],
      ],
    );
  }
}

class _SalesReportTab extends ConsumerWidget {
  const _SalesReportTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(salesReportProvider);
    return PageBody(
      maxWidth: Breakpoints.expanded,
      children: [
        const ReportFilters(),
        ...report.when(
          loading: () => [const SizedBox(height: 200, child: StateView.loading())],
          error: (e, _) => [StateView.error(message: describeError(e), onRetry: () => ref.invalidate(salesReportProvider))],
          data: (r) => [
            StatGrid(children: [
              StatTile(icon: Icons.payments_outlined, label: 'Total sales', value: formatMoney(r.totals.amount)),
              StatTile(icon: Icons.receipt_long_outlined, label: 'Number of sales', value: '${r.totals.salesCount}'),
              StatTile(icon: Icons.inventory_2_outlined, label: 'Items sold', value: '${r.totals.units}'),
            ]),
            SectionCard(
              title: 'Sales by day',
              icon: Icons.bar_chart,
              child: DailyBars(points: [for (final d in r.byDay) ChartPoint(d.date, d.value)], format: formatMoney),
            ),
            SectionCard(
              title: 'Sales by product',
              icon: Icons.category_outlined,
              child: BarList(items: [
                for (final p in r.byProduct) BarDatum(p.name, p.amount, '${formatMoney(p.amount)} · ${p.units} items'),
              ]),
            ),
            SectionCard(
              title: 'Best performers',
              icon: Icons.emoji_events_outlined,
              child: LeaderboardView(board: buildLeaderboard(r.byAgent, r.days)),
            ),
            SectionCard(
              title: 'Sales by agent',
              icon: Icons.groups_outlined,
              child: BarList(items: [
                for (final a in r.byAgent) BarDatum(a.name, a.amount, '${formatMoney(a.amount)} · ${a.units} items'),
              ]),
            ),
            SectionCard(
              title: 'Agent activity',
              icon: Icons.how_to_reg_outlined,
              child: _ActivityTable(agents: r.byAgent, days: r.days),
            ),
            SectionCard(
              title: 'New customers by day',
              icon: Icons.person_add_alt,
              child: DailyBars(
                points: [for (final d in r.customersByDay) ChartPoint(d.date, d.value)],
                format: (v) => '${v.toInt()} customer${v == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActivityTable extends StatelessWidget {
  const _ActivityTable({required this.agents, required this.days});

  final List<AgentActivity> agents;
  final int days;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) return const Text('No agents match these filters.');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Agent')),
          DataColumn(label: Text('Days reported'), numeric: true),
          DataColumn(label: Text('Days with no sales'), numeric: true),
          DataColumn(label: Text('Sales'), numeric: true),
          DataColumn(label: Text('Last report')),
        ],
        rows: [
          for (final a in agents)
            DataRow(cells: [
              DataCell(Text(a.name)),
              DataCell(Text('${a.daysReported} of $days')),
              DataCell(Text('${a.zeroSaleDays}')),
              DataCell(Text('${a.salesCount}')),
              DataCell(Text(a.lastReportAt == null ? '—' : formatDateTime(a.lastReportAt!))),
            ]),
        ],
      ),
    );
  }
}

class LeaderboardView extends StatelessWidget {
  const LeaderboardView({super.key, required this.board});

  final Leaderboard board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final best = board.best;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (best != null)
          Row(children: [
            const Icon(Icons.emoji_events, color: AppColors.accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '${best.agent.name}: ${formatMoney(best.perDay)} per day worked, '
                'over ${best.agent.daysReported} of ${board.periodDays} days',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ])
        else
          const Text('No one has enough days with sales in this period to rank yet.'),
        if (board.ranked.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Rank'), numeric: true),
                DataColumn(label: Text('Agent')),
                DataColumn(label: Text('Days worked'), numeric: true),
                DataColumn(label: Text('Total sales'), numeric: true),
                DataColumn(label: Text('Per day worked'), numeric: true),
                DataColumn(label: Text('Items per day'), numeric: true),
              ],
              rows: [
                for (final r in board.ranked)
                  DataRow(cells: [
                    DataCell(Text('${r.rank}')),
                    DataCell(Text(r.agent.name)),
                    DataCell(Text('${r.agent.daysReported} of ${board.periodDays}')),
                    DataCell(Text(formatMoney(r.agent.amount))),
                    DataCell(Text(formatMoney(r.perDay), style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text(r.unitsPerDay.toStringAsFixed(1))),
                  ]),
              ],
            ),
          ),
        ],
        if (board.notRanked.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Not enough days to rank (fewer than ${board.minDays}): '
            '${board.notRanked.map((a) => '${a.name} (${a.daysReported})').join(', ')}',
            style: muted,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Ranked by average sales per day worked. A day worked is any day the agent sent a report, '
          'including days with no sales. Agents need at least ${board.minDays} of ${board.periodDays} days to be ranked.',
          style: muted,
        ),
      ],
    );
  }
}
