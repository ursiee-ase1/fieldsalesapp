import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../../../core/routing/redirect.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/models.dart';
import '../../reports/data/reports_repository.dart';

class AgentHomeScreen extends ConsumerWidget {
  const AgentHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final name = session is SignedIn ? session.context.fullName?.split(' ').first : null;
    final home = ref.watch(agentHomeProvider);

    return RefreshIndicator(
      onRefresh: () => ref.refresh(agentHomeProvider.future),
      child: PageBody(
        children: [
          Text(name == null ? 'Welcome' : 'Hello, $name', style: Theme.of(context).textTheme.headlineSmall),
          ...home.when(
            loading: () => [const SizedBox(height: 200, child: StateView.loading())],
            error: (e, _) => [StateView.error(message: describeError(e), onRetry: () => ref.invalidate(agentHomeProvider))],
            data: (h) => [
              _ReportStatus(home: h),
              const _ReportActions(),
              _SalesCard(home: h),
              _TargetsCard(targets: h.targets),
              _StockCard(stock: h.stock),
              _FollowUpsCard(followUps: h.followUps, today: h.businessDate),
              const SectionCard(
                title: 'Waiting to sync',
                icon: Icons.cloud_upload_outlined,
                child: Text('Reports are sent straight away while you are online. '
                    'Saving reports offline is coming soon.'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReportStatus extends StatelessWidget {
  const _ReportStatus({required this.home});

  final AgentHome home;

  @override
  Widget build(BuildContext context) {
    final at = home.lastReportAt == null ? '' : ' at ${formatDateTime(home.lastReportAt!)}';
    return switch (home.reportState) {
      ReportState.none => const InlineMessage.error("You haven't sent today's report yet."),
      ReportState.zeroSales => InlineMessage.success('Report sent$at: no sales today.'),
      ReportState.withSales => InlineMessage.success('Report sent$at.'),
    };
  }
}

class _ReportActions extends StatelessWidget {
  const _ReportActions();

  @override
  Widget build(BuildContext context) {
    final wide = windowSizeOf(context) != WindowSize.compact;
    final form = FilledButton.icon(
      onPressed: () => context.push(Routes.agentReport),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
      icon: const Icon(Icons.edit_note),
      label: const Text('Fill in daily report'),
    );
    final voice = FilledButton.tonalIcon(
      onPressed: null,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      icon: const Icon(Icons.mic_none),
      label: const Text('Voice report (coming soon)'),
    );
    final text = FilledButton.tonalIcon(
      onPressed: null,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      icon: const Icon(Icons.chat_bubble_outline),
      label: const Text('Chat report (coming soon)'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        form,
        const SizedBox(height: AppSpacing.md),
        if (wide)
          Row(children: [Expanded(child: voice), const SizedBox(width: AppSpacing.md), Expanded(child: text)])
        else ...[
          voice,
          const SizedBox(height: AppSpacing.md),
          text,
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _SalesCard extends StatelessWidget {
  const _SalesCard({required this.home});

  final AgentHome home;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: "Today's sales",
      icon: Icons.point_of_sale_outlined,
      child: Wrap(
        spacing: AppSpacing.xxl,
        runSpacing: AppSpacing.md,
        children: [
          _Stat('Sales', '${home.salesCount}'),
          _Stat('Items sold', '${home.unitsSold}'),
          _Stat('Collected', formatMoney(home.amount)),
        ],
      ),
    );
  }
}

class _TargetsCard extends StatelessWidget {
  const _TargetsCard({required this.targets});

  final List<TargetProgress> targets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String fmt(TargetProgress t, num v) => t.isAmount ? formatMoney(v) : '$v';
    return SectionCard(
      title: 'Daily target',
      icon: Icons.flag_outlined,
      child: targets.isEmpty
          ? const Text('No target set for today.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in targets) ...[
                  Text(
                    '${t.productName ?? (t.isAmount ? 'Amount collected' : 'Items sold')}: '
                    '${fmt(t, t.achieved)} of ${fmt(t, t.target)}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  LinearProgressIndicator(
                    value: (t.progressPct / 100).clamp(0, 1).toDouble(),
                    minHeight: 8,
                    borderRadius: const BorderRadius.all(AppRadius.sm),
                    semanticsLabel: '${t.progressPct}% of target',
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(t.remaining > 0 ? '${fmt(t, t.remaining)} to go · ${t.progressPct}%' : 'Target reached 🎉',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
    );
  }
}

class _StockCard extends StatelessWidget {
  const _StockCard({required this.stock});

  final List<HeldStock> stock;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'My stock',
      icon: Icons.inventory_2_outlined,
      child: stock.isEmpty
          ? const Text('No stock issued to you right now.')
          : Column(
              children: [
                for (final s in stock)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.name),
                    trailing: Text('${s.quantity}', style: Theme.of(context).textTheme.titleMedium),
                  ),
              ],
            ),
    );
  }
}

class _FollowUpsCard extends StatelessWidget {
  const _FollowUpsCard({required this.followUps, required this.today});

  final List<DueFollowUp> followUps;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Follow-ups',
      icon: Icons.event_note_outlined,
      child: followUps.isEmpty
          ? const Text('No follow-ups in the next 7 days.')
          : Column(
              children: [
                for (final f in followUps)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(f.dueDate.isAfter(today) ? Icons.schedule : Icons.notification_important_outlined),
                    title: Text(f.customerName),
                    subtitle: Text([
                      f.dueDate.isAfter(today) ? formatDay(f.dueDate) : 'Due today',
                      if (f.phone != null) f.phone!,
                      if (f.note != null) f.note!,
                    ].join(' · ')),
                  ),
              ],
            ),
    );
  }
}
