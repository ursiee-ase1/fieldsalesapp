import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/routing/redirect.dart';
import '../application/session_controller.dart';
import '../data/auth_repository.dart';
import 'auth_layout.dart';

/// Self-serve sign-up for a company administrator. Agents and managers are
/// created by their company instead.
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final result = await ref.read(authRepositoryProvider).signUpWithEmail(_email.text, _password.text);
      if (result == SignUpResult.confirmationRequired) {
        if (mounted) setState(() => _info = 'Check your email to confirm your account, then sign in.');
      } else {
        await ref.read(sessionProvider.notifier).refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'Create your company account',
      subtitle: "You'll be the administrator. You can add managers and field agents next.",
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Work email'),
              validator: (v) => (v ?? '').contains('@') ? null : 'Enter a valid email',
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'Password', helperText: 'At least 8 characters'),
              validator: (v) => (v ?? '').length < 8 ? 'Use at least 8 characters' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.error(_error!),
            ],
            if (_info != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.success(_info!),
            ],
            const SizedBox(height: AppSpacing.lg),
            BusyButton(label: 'Create account', busy: _busy, onPressed: _submit),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: () => context.go(Routes.signIn),
              child: const Text('Already have an account? Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
