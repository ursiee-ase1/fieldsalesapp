import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/format.dart';
import '../data/dashboard_repository.dart';
import 'reports_screen.dart';

/// Assistant conversations, for supervision and for checking Twi translations.
class ConversationsTab extends ConsumerWidget {
  const ConversationsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(conversationsProvider);
    return PageBody(
      maxWidth: Breakpoints.expanded,
      children: [
        const ReportFilters(showDimensions: false),
        ...list.when(
          loading: () => [const SizedBox(height: 200, child: StateView.loading())],
          error: (e, _) => [StateView.error(message: describeError(e), onRetry: () => ref.invalidate(conversationsProvider))],
          data: (items) => items.isEmpty
              ? [
                  const StateView.empty(
                    icon: Icons.forum_outlined,
                    title: 'No conversations in this period',
                    message: 'Reports given to the assistant by voice or chat appear here.',
                  ),
                ]
              : [
                  for (final c in items)
                    Card(
                      child: ListTile(
                        leading: Icon(c.channel == 'app_voice' ? Icons.mic_none : Icons.chat_bubble_outline),
                        title: Text('${c.agentName} · ${formatDay(c.businessDate)}'),
                        subtitle: Text([
                          c.channel == 'app_voice' ? 'Voice' : 'Chat',
                          c.language == 'tw' ? 'Twi' : 'English',
                          _statusLabel(c.status),
                          '${c.turns} messages',
                        ].join(' · ')),
                        trailing: TextButton.icon(
                          onPressed: () => showDialog<void>(context: context, builder: (_) => _TranscriptDialog(summary: c)),
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('Read'),
                        ),
                      ),
                    ),
                ],
        ),
      ],
    );
  }

  static String _statusLabel(String s) => switch (s) {
        'submitted' => 'Report sent',
        'awaiting_confirmation' => 'Waiting for confirmation',
        'abandoned' => 'Discarded',
        _ => 'In progress',
      };
}

final _transcriptProvider = FutureProvider.autoDispose.family<List<TranscriptLine>, String>(
  (ref, sessionId) => ref.watch(dashboardRepositoryProvider).transcript(sessionId),
);

class _TranscriptDialog extends ConsumerWidget {
  const _TranscriptDialog({required this.summary});

  final ConversationSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(_transcriptProvider(summary.sessionId));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text('${summary.agentName} · ${formatDay(summary.businessDate)}'),
      content: SizedBox(
        width: 560,
        child: lines.when(
          loading: () => const SizedBox(height: 160, child: StateView.loading()),
          error: (e, _) => StateView.error(message: describeError(e)),
          data: (list) => ListView(
            shrinkWrap: true,
            children: [
              for (final l in list)
                Align(
                  alignment: l.fromAgent ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    padding: const EdgeInsets.all(AppSpacing.md),
                    constraints: const BoxConstraints(maxWidth: 440),
                    decoration: BoxDecoration(
                      color: l.fromAgent ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      borderRadius: const BorderRadius.all(AppRadius.md),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${l.fromAgent ? 'Agent' : 'Assistant'}${l.voice ? ' (voice)' : ''} · ${formatDateTime(l.createdAt)}',
                          style: theme.textTheme.labelSmall),
                      const SizedBox(height: AppSpacing.xs),
                      Text(l.text),
                      // Twi turns show the English the assistant worked with, to check translations.
                      if (l.englishText != null && l.englishText != l.text) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text('English: ${l.englishText}',
                            style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                      ],
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
