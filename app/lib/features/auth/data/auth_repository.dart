import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/phone.dart';
import '../domain/models.dart';

enum SignUpResult { signedIn, confirmationRequired }

/// Sign-up attempted with an email that already has an account.
class AccountExists implements Exception {
  const AccountExists();
}

abstract interface class AuthRepository {
  bool get hasSession;

  /// Email of the signed-in account (null for phone logins).
  String? get currentEmail;

  /// Emits whenever the user signs in or out.
  Stream<void> get sessionChanges;

  Future<UserContext> fetchContext();
  Future<void> signInWithPhone(String phoneE164, String password);
  Future<void> signInWithEmail(String email, String password);
  Future<SignUpResult> signUpWithEmail(String email, String password);
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  bool get hasSession => _client.auth.currentSession != null;

  @override
  String? get currentEmail {
    final email = _client.auth.currentUser?.email;
    return email == null || email.endsWith('@$phoneLoginDomain') ? null : email;
  }

  @override
  Stream<void> get sessionChanges => _client.auth.onAuthStateChange
      .where((s) => s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.signedOut)
      .map((_) {});

  @override
  Future<UserContext> fetchContext() async {
    final data = await _client.rpc('my_context');
    return UserContext.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Phone logins go through the Email provider (see [phoneLoginEmail]), so
  /// the project needs no SMS provider.
  @override
  Future<void> signInWithPhone(String phoneE164, String password) =>
      _client.auth.signInWithPassword(email: phoneLoginEmail(phoneE164), password: password);

  @override
  Future<void> signInWithEmail(String email, String password) =>
      _client.auth.signInWithPassword(email: email.trim(), password: password);

  @override
  Future<SignUpResult> signUpWithEmail(String email, String password) async {
    final AuthResponse response;
    try {
      response = await _client.auth.signUp(email: email.trim(), password: password);
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('already registered')) throw const AccountExists();
      rethrow;
    }
    // With email confirmation on, Supabase doesn't reveal existing accounts
    // with an error; it returns a user with no identities instead.
    if (response.user != null && (response.user!.identities?.isEmpty ?? false)) throw const AccountExists();
    return response.session == null ? SignUpResult.confirmationRequired : SignUpResult.signedIn;
  }

  @override
  Future<void> signOut() => _client.auth.signOut();
}
