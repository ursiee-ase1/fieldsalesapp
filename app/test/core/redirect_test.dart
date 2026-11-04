import 'package:field_sales/core/routing/redirect.dart';
import 'package:field_sales/features/auth/domain/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth_repository.dart';

AsyncValue<SessionState> signedIn(MemberRole role) =>
    AsyncData(SignedIn(const UserContext(userId: 'u1'), membership(role)));

void main() {
  group('resolveRedirect', () {
    test('sends everyone to splash while the session first loads', () {
      expect(resolveRedirect(const AsyncLoading(), Routes.overview), Routes.splash);
      expect(resolveRedirect(const AsyncLoading(), Routes.splash), isNull);
    });

    test('keeps signed-out users on public routes', () {
      const out = AsyncData<SessionState>(SignedOut());
      expect(resolveRedirect(out, Routes.signIn), isNull);
      expect(resolveRedirect(out, Routes.signUp), isNull);
      expect(resolveRedirect(out, Routes.overview), Routes.signIn);
      expect(resolveRedirect(out, Routes.agentHome), Routes.signIn);
    });

    test('forces onboarding for users without a company', () {
      const s = AsyncData<SessionState>(NeedsOnboarding(UserContext(userId: 'u1')));
      expect(resolveRedirect(s, Routes.overview), Routes.onboarding);
      expect(resolveRedirect(s, Routes.onboarding), isNull);
    });

    test('locks suspended users out', () {
      const s = AsyncData<SessionState>(Suspended(UserContext(userId: 'u1')));
      expect(resolveRedirect(s, Routes.agentHome), Routes.suspended);
      expect(resolveRedirect(s, Routes.suspended), isNull);
    });

    test('keeps agents out of the management area', () {
      final agent = signedIn(MemberRole.agent);
      expect(resolveRedirect(agent, Routes.overview), Routes.agentHome);
      expect(resolveRedirect(agent, Routes.settings), Routes.agentHome);
      expect(resolveRedirect(agent, Routes.signIn), Routes.agentHome);
      expect(resolveRedirect(agent, Routes.agentCustomers), isNull);
    });

    test('keeps admins and managers in the management area', () {
      for (final role in [MemberRole.admin, MemberRole.manager]) {
        final s = signedIn(role);
        expect(resolveRedirect(s, Routes.agentHome), Routes.overview, reason: role.name);
        expect(resolveRedirect(s, Routes.manage), Routes.overview);
        expect(resolveRedirect(s, Routes.inventory), isNull);
      }
    });

    test('does not treat look-alike paths as inside an area', () {
      expect(resolveRedirect(signedIn(MemberRole.agent), '/agentx'), Routes.agentHome);
    });
  });
}
