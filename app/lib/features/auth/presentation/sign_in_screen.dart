import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/phone.dart';
import '../../../core/routing/redirect.dart';
import '../application/session_controller.dart';
import 'auth_layout.dart';

enum _Method { phone, email }

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  var _method = _Method.phone;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    try {
      if (_method == _Method.phone) {
        await repo.signInWithPhone(normalizeGhanaPhone(_identifier.text)!, _password.text);
      } else {
        await repo.signInWithEmail(_identifier.text, _password.text);
      }
      await ref.read(sessionProvider.notifier).refresh();
    } on AuthException catch (e) {
      final wrongDetails = e.message.toLowerCase().contains('invalid login credentials');
      if (mounted) {
        setState(() => _error = !wrongDetails
            ? describeError(e)
            : _method == _Method.phone
                ? 'Wrong phone number or password. Check them and try again.'
                : 'Wrong email or password. Check them and try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = _method == _Method.phone;
    return AuthLayout(
      title: 'Sign in',
      subtitle: 'Field agents sign in with their phone number.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_Method>(
              segments: const [
                ButtonSegment(value: _Method.phone, icon: Icon(Icons.phone_outlined), label: Text('Phone')),
                ButtonSegment(value: _Method.email, icon: Icon(Icons.mail_outline), label: Text('Email')),
              ],
              selected: {_method},
              onSelectionChanged: (s) => setState(() {
                _method = s.first;
                _identifier.clear();
                _error = null;
              }),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              key: const Key('sign-in-identifier'),
              controller: _identifier,
              keyboardType: isPhone ? TextInputType.phone : TextInputType.emailAddress,
              autofillHints: [isPhone ? AutofillHints.telephoneNumber : AutofillHints.email],
              decoration: InputDecoration(
                labelText: isPhone ? 'Phone number' : 'Email',
                hintText: isPhone ? '024 123 4567' : 'you@company.com',
              ),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (isPhone) return normalizeGhanaPhone(value) == null ? 'Enter a valid Ghana phone number' : null;
                return value.contains('@') ? null : 'Enter a valid email';
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              key: const Key('sign-in-password'),
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.error(_error!),
              if (_method == _Method.phone) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Field agents: if you have forgotten your password, ask your manager to reset it.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
            const SizedBox(height: AppSpacing.lg),
            BusyButton(label: 'Sign in', busy: _busy, onPressed: _submit),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: () => context.go(Routes.signUp),
              child: const Text('New company? Create an account'),
            ),
          ],
        ),
      ),
    );
  }
}
