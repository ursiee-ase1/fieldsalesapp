import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/routing/redirect.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/models.dart';
import '../../reports/data/reports_repository.dart';
import '../application/conversation_controller.dart';
import '../data/assistant_repository.dart';
import '../data/voice.dart';

/// Voice or chat report with the AI assistant. Both modes run the same
/// conversation; voice only adds the microphone and speech.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key, required this.voice});

  final bool voice;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  late final ConversationController _c;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider).value;
    final preferred = session is SignedIn ? session.context.preferredLanguage : 'en';
    _c = ConversationController(
      api: ref.read(assistantApiProvider),
      voice: ref.read(voiceProvider),
      voiceMode: widget.voice,
      language: AssistantLanguage.parse(preferred),
    )..addListener(_onChange);
    _c.start();
  }

  void _onChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _c
      ..removeListener(_onChange)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    _input.clear();
    _c.sendText(text);
  }

  void _close() {
    ref.invalidate(agentHomeProvider);
    context.pop();
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this report?'),
        content: const Text('Nothing you said in this conversation will be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok == true) {
      await _c.discard();
      if (mounted) _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(_c.voiceMode ? 'Voice report' : 'Chat report'),
          actions: [
            PopupMenuButton<AssistantLanguage>(
              tooltip: 'Language',
              onSelected: _c.setLanguage,
              itemBuilder: (_) => [
                for (final l in AssistantLanguage.values)
                  CheckedPopupMenuItem(value: l, checked: l == _c.language, child: Text(l.label)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Row(children: [const Icon(Icons.translate), const SizedBox(width: AppSpacing.xs), Text(_c.language.label)]),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'form') context.pushReplacement(Routes.agentReport);
                if (v == 'discard') _discard();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'form', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Use the form instead'))),
                PopupMenuItem(value: 'discard', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Discard this report'))),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Breakpoints.contentMax),
              child: Column(
                children: [
                  Expanded(child: _transcript()),
                  _bottom(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _transcript() {
    final theme = Theme.of(context);
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        for (final n in _c.notices)
          Padding(padding: const EdgeInsets.only(bottom: AppSpacing.md), child: InlineMessage.success(n)),
        for (final line in _c.lines) _Bubble(line: line),
        if (_c.partial.isNotEmpty) _Bubble(line: ChatLine(fromAgent: true, text: _c.partial), faded: true),
        if (_c.phase == ConversationPhase.thinking || _c.phase == ConversationPhase.starting)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Row(children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: AppSpacing.sm),
              Text('Thinking…'),
            ]),
          ),
        if (_c.error != null) ...[
          InlineMessage.error(_c.error!),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.sm, children: [
            if (_c.lines.isEmpty)
              OutlinedButton.icon(onPressed: _c.start, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            OutlinedButton.icon(
              onPressed: () => context.pushReplacement(Routes.agentReport),
              icon: const Icon(Icons.edit_note),
              label: Text(_c.needsConnection ? 'Use the form (works offline soon)' : 'Use the form instead'),
            ),
          ]),
        ],
        if (_c.summary != null && !_c.submitted)
          SectionCard(
            title: 'Check your report',
            icon: Icons.fact_check_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final s in _c.summary!)
                  Padding(padding: const EdgeInsets.only(bottom: AppSpacing.xs), child: Text('• $s')),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    FilledButton.icon(
                      onPressed: _c.busy ? null : _c.confirm,
                      icon: const Icon(Icons.send_outlined),
                      label: const Text('Confirm and send'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _c.busy ? null : _c.makeChanges,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Make changes'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (_c.submitted)
          SectionCard(
            title: 'Report sent',
            icon: Icons.check_circle_outline,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(onPressed: _close, icon: const Icon(Icons.home_outlined), label: const Text('Back to home')),
            ),
          ),
        if (_c.phase == ConversationPhase.finished && !_c.submitted && _c.lines.isNotEmpty && _c.error == null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(onPressed: _close, icon: const Icon(Icons.home_outlined), label: const Text('Back to home')),
          ),
        Text(
          'The assistant needs internet. Anything it records is only saved after you confirm.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _bottom() {
    if (_c.submitted || _c.phase == ConversationPhase.finished) return const SizedBox.shrink();
    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: _c.voiceMode ? _voiceControls() : _textControls(),
      ),
    );
  }

  Widget _textControls() {
    return Row(
      children: [
        if (_c.canUseVoice) ...[
          OutlinedButton.icon(onPressed: _c.switchToVoice, icon: const Icon(Icons.mic_none), label: const Text('Speak')),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: TextField(
            controller: _input,
            enabled: !_c.busy,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(hintText: 'Type your answer'),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton.icon(
          onPressed: _c.busy ? null : _send,
          icon: const Icon(Icons.send),
          label: const Text('Send'),
        ),
      ],
    );
  }

  Widget _voiceControls() {
    final theme = Theme.of(context);
    final (IconData icon, String label) = switch (_c.phase) {
      ConversationPhase.listening => (Icons.stop, 'Listening… tap when you finish'),
      ConversationPhase.recording => (Icons.send, 'Recording… tap to send'),
      ConversationPhase.speaking => (Icons.front_hand_outlined, 'Speaking… tap to interrupt'),
      ConversationPhase.thinking || ConversationPhase.starting => (Icons.hourglass_top, 'Thinking…'),
      _ => (Icons.mic, 'Tap to talk'),
    };
    final active = _c.phase == ConversationPhase.listening || _c.phase == ConversationPhase.recording;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          child: SizedBox.square(
            dimension: 76,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                backgroundColor: active ? theme.colorScheme.error : null,
              ),
              onPressed: _c.busy ? null : _c.tapMic,
              child: Icon(icon, size: 34),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(label, style: theme.textTheme.titleSmall),
        TextButton.icon(onPressed: _c.switchToTyping, icon: const Icon(Icons.keyboard_outlined), label: const Text('Type instead')),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.line, this.faded = false});

  final ChatLine line;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = line.fromAgent;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: faded ? 0.6 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          constraints: const BoxConstraints(maxWidth: 520),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.all(AppRadius.md),
          ),
          child: Text(line.text, style: TextStyle(color: mine ? scheme.onPrimaryContainer : scheme.onSurface)),
        ),
      ),
    );
  }
}
