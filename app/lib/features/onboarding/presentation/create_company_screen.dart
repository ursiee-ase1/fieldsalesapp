import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/phone.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/presentation/auth_layout.dart';
import '../data/company_repository.dart';

class CreateCompanyScreen extends ConsumerStatefulWidget {
  const CreateCompanyScreen({super.key});

  @override
  ConsumerState<CreateCompanyScreen> createState() => _CreateCompanyScreenState();
}

class _CreateCompanyScreenState extends ConsumerState<CreateCompanyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _company = TextEditingController();
  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _company.dispose();
    _fullName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(companyRepositoryProvider).createCompany(
            name: _company.text,
            adminFullName: _fullName.text,
            phone: _phone.text,
          );
      await ref.read(sessionProvider.notifier).refresh();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'Set up your company',
      subtitle: 'Your data is private to your company.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AccountNotice(email: ref.read(authRepositoryProvider).currentEmail),
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              controller: _company,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Company name'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the company name' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _fullName,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Your full name'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Your phone (optional)', hintText: '024 123 4567'),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return null;
                return normalizeGhanaPhone(value) == null ? 'Enter a valid Ghana phone number' : null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.error(_error!),
            ],
            const SizedBox(height: AppSpacing.lg),
            BusyButton(label: 'Create company', busy: _busy, onPressed: _submit),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () => ref.read(sessionProvider.notifier).signOut(),
              icon: const Icon(Icons.switch_account_outlined),
              label: const Text('Use a different account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Makes it obvious which account is signed in, so a mistyped email or a
/// manager who should have been invited doesn't create a stray company.
class _AccountNotice extends StatelessWidget {
  const _AccountNotice({required this.email});

  final String? email;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.account_circle_outlined),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(email == null ? 'You are signed in.' : 'Signed in as $email',
                    style: theme.textTheme.titleSmall),
              ),
            ]),
            const SizedBox(height: AppSpacing.sm),
            const Text("This account isn't part of a company yet."),
            const SizedBox(height: AppSpacing.xs),
            const Text('• Setting up a new company? Fill in the details below.'),
            const Text('• Joining an existing company? Ask its administrator to add you, '
                'then sign in with the details they give you.'),
            const Text('• Wrong account? Tap "Use a different account".'),
          ],
        ),
      ),
    );
  }
}
