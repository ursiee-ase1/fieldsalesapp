import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/components.dart';
import '../../../core/design/tokens.dart';
import '../../../core/errors.dart';
import '../../../core/phone.dart';
import '../../auth/domain/models.dart';
import '../../auth/domain/permissions.dart';
import '../data/members_repository.dart';

Future<void> showInviteMemberSheet(BuildContext context, {required MemberRole inviterRole}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: InviteMemberForm(inviterRole: inviterRole),
    ),
  );
}

class InviteMemberForm extends ConsumerStatefulWidget {
  const InviteMemberForm({super.key, required this.inviterRole});

  final MemberRole inviterRole;

  @override
  ConsumerState<InviteMemberForm> createState() => _InviteMemberFormState();
}

class _InviteMemberFormState extends ConsumerState<InviteMemberForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late MemberRole _role = invitableRoles(widget.inviterRole).last;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _isAgent => _role == MemberRole.agent;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(membersRepositoryProvider).invite(InviteRequest(
            fullName: _name.text.trim(),
            role: _role,
            password: _password.text,
            phone: _phone.text.trim().isEmpty ? null : normalizeGhanaPhone(_phone.text),
            email: _isAgent || _email.text.trim().isEmpty ? null : _email.text.trim(),
          ));
      ref.invalidate(membersProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${_name.text.trim()} added. Share their sign-in details with them directly.'),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = invitableRoles(widget.inviterRole);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.xl),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add a team member', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.lg),
            if (roles.length > 1) ...[
              DropdownButtonFormField<MemberRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(r.label))],
                onChanged: (r) => setState(() => _role = r!),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Enter their name' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: _isAgent ? 'Phone number (used to sign in)' : 'Phone number',
                hintText: '024 123 4567',
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return _isAgent ? 'Agents sign in with their phone number' : null;
                return normalizeGhanaPhone(value) == null ? 'Enter a valid Ghana phone number' : null;
              },
            ),
            if (!_isAgent) ...[
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty && _phone.text.trim().isEmpty) return 'Enter an email or phone number';
                  if (value.isNotEmpty && !value.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Temporary password',
                helperText: 'At least 8 characters. Share it with them privately.',
              ),
              validator: (v) => (v ?? '').length < 8 ? 'Use at least 8 characters' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              InlineMessage.error(_error!),
            ],
            const SizedBox(height: AppSpacing.lg),
            BusyButton(label: 'Add member', busy: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
