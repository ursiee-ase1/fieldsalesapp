import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/auth_repository.dart';
import '../domain/models.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(Supabase.instance.client),
);

final sessionProvider = AsyncNotifierProvider<SessionController, SessionState>(SessionController.new);

/// Single source of truth for who is signed in and what they may see.
class SessionController extends AsyncNotifier<SessionState> {
  @override
  Future<SessionState> build() async {
    final repo = ref.watch(authRepositoryProvider);
    final sub = repo.sessionChanges.listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return _load(repo);
  }

  Future<SessionState> _load(AuthRepository repo) async {
    if (!repo.hasSession) return const SignedOut();
    return sessionFromContext(await repo.fetchContext());
  }

  /// Re-reads membership, e.g. after creating a company. The previous state
  /// stays visible until the new one arrives, so screens don't flash.
  Future<void> refresh() async {
    final repo = ref.read(authRepositoryProvider);
    state = await AsyncValue.guard(() => _load(repo));
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(SignedOut());
  }
}
