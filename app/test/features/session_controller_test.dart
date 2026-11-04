import 'package:field_sales/features/auth/application/session_controller.dart';
import 'package:field_sales/features/auth/domain/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth_repository.dart';

void main() {
  late FakeAuthRepository repo;
  late ProviderContainer container;

  ProviderContainer build() {
    final c = ProviderContainer(overrides: [authRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    return c;
  }

  test('no session means signed out', () async {
    repo = FakeAuthRepository();
    container = build();
    expect(await container.read(sessionProvider.future), isA<SignedOut>());
  });

  test('a session without a company needs onboarding', () async {
    repo = FakeAuthRepository(signedIn: true);
    container = build();
    expect(await container.read(sessionProvider.future), isA<NeedsOnboarding>());
  });

  test('a suspended membership is reported as suspended', () async {
    repo = FakeAuthRepository(
      signedIn: true,
      context: UserContext(userId: 'u1', membership: membership(MemberRole.agent, status: MemberStatus.suspended)),
    );
    container = build();
    expect(await container.read(sessionProvider.future), isA<Suspended>());
  });

  test('an active membership signs in with its role', () async {
    repo = FakeAuthRepository(
      signedIn: true,
      context: UserContext(userId: 'u1', membership: membership(MemberRole.manager)),
    );
    container = build();
    final state = await container.read(sessionProvider.future);
    expect(state, isA<SignedIn>().having((s) => s.role, 'role', MemberRole.manager));
  });

  test('refresh picks up a newly created company without flashing a loading state', () async {
    repo = FakeAuthRepository(signedIn: true);
    container = build();
    expect(await container.read(sessionProvider.future), isA<NeedsOnboarding>());

    final seen = <AsyncValue<SessionState>>[];
    container.listen(sessionProvider, (_, next) => seen.add(next));
    repo.context = UserContext(userId: 'u1', membership: membership(MemberRole.admin));
    await container.read(sessionProvider.notifier).refresh();

    expect(seen.whereType<AsyncLoading<SessionState>>(), isEmpty);
    expect(container.read(sessionProvider).value, isA<SignedIn>());
  });

  test('auth events trigger a reload', () async {
    repo = FakeAuthRepository();
    container = build();
    expect(await container.read(sessionProvider.future), isA<SignedOut>());

    repo
      ..signedIn = true
      ..context = UserContext(userId: 'u1', membership: membership(MemberRole.agent))
      ..emitChange();
    await pumpEventQueue();
    expect(container.read(sessionProvider).value, isA<SignedIn>());
  });

  test('sign out returns to signed out', () async {
    repo = FakeAuthRepository(signedIn: true, context: UserContext(userId: 'u1', membership: membership(MemberRole.agent)));
    container = build();
    await container.read(sessionProvider.future);
    await container.read(sessionProvider.notifier).signOut();
    expect(container.read(sessionProvider).value, isA<SignedOut>());
  });
}
