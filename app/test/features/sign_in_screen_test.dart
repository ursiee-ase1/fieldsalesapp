import 'package:field_sales/core/design/theme.dart';
import 'package:field_sales/features/auth/application/session_controller.dart';
import 'package:field_sales/features/auth/presentation/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth_repository.dart';

void main() {
  late FakeAuthRepository repo;

  Future<void> pump(WidgetTester tester) async {
    repo = FakeAuthRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(theme: AppTheme.light(), home: const SignInScreen()),
    ));
  }

  testWidgets('rejects an invalid phone number before calling the backend', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('sign-in-identifier')), '12345');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid Ghana phone number'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  testWidgets('signs in with the normalized phone number', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('sign-in-identifier')), '024 123 4567');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(repo.calls, ['phone:+233241234567']);
  });

  testWidgets('can switch to email sign-in', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Email'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('sign-in-identifier')), 'admin@alpha.com');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(repo.calls, ['email:admin@alpha.com']);
  });
}
