import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../dashboard/data/dashboard_repository.dart';

/// Admin-only company settings. The server accepts only these keys and
/// validates each value.
class CompanySettingsCard extends ConsumerStatefulWidget {
  const CompanySettingsCard({super.key});

  @override
  ConsumerState<CompanySettingsCard> createState() => _CompanySettingsCardState();
}

class _CompanySettingsCardState extends ConsumerState<CompanySettingsCard> {
  final _calls = TextEditingController();
  final _discount = TextEditingController();
  bool? _twiVoice;
  var _loaded = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _calls.dispose();
    _discount.dispose();
    super.dispose();
  }

  void _fill(CompanySettings s) {
    if (_loaded) return;
    _loaded = true;
    _twiVoice = s.twiVoiceEnabled;
    _calls.text = '${s.khayaMonthlyCalls}';
    _discount.text = '${s.maxDiscountPct}';
  }

  Future<void> _save() async {
    final calls = int.tryParse(_calls.text.trim());
    final discount = num.tryParse(_discount.text.trim());
    if (calls == null || calls < 0 || discount == null || discount < 0 || discount > 100) {
      setState(() => _error = 'Enter a whole number of Twi calls, and a discount limit from 0 to 100.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(dashboardRepositoryProvider).updateSettings({
        'twi_voice_enabled': _twiVoice ?? false,
        'khaya_monthly_calls': calls,
        'max_discount_pct': discount,
      });
      ref.invalidate(companySettingsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Company settings saved')));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(companySettingsProvider);
    return SectionCard(
      title: 'Company settings',
      icon: Icons.business_outlined,
      child: settings.when(
        loading: () => const SizedBox(height: 120, child: StateView.loading()),
        error: (e, _) => StateView.error(message: describeError(e), onRetry: () => ref.invalidate(companySettingsProvider)),
        data: (s) {
          _fill(s);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.record_voice_over_outlined),
                title: const Text('Twi voice for the assistant'),
                subtitle: const Text('Agents can speak and hear Twi. Turn on after testing with your agents. '
                    'Typed Twi works either way.'),
                value: _twiVoice ?? false,
                onChanged: (v) => setState(() => _twiVoice = v),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _calls,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Twi service calls per month',
                  helperText: 'Used this month: ${s.khayaCallsUsed}. A Twi chat turn uses about 2, a voice turn about 4.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Flag discounts larger than (%)',
                  helperText: 'Sales below the catalogue price by more than this are flagged for review.',
                  helperMaxLines: 2,
                ),
              ),
              if (_error != null) ...[const SizedBox(height: AppSpacing.md), InlineMessage.error(_error!)],
              const SizedBox(height: AppSpacing.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: BusyButton(label: 'Save settings', busy: _busy, onPressed: _save),
              ),
            ],
          );
        },
      ),
    );
  }
}
