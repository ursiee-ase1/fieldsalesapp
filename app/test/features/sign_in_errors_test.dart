import 'package:field_sales/core/design/theme.dart';
import 'package:field_sales/features/auth/application/session_controller.dart';
import 'package:field_sales/features/auth/presentation/sign_in_screen.dart';
import 'package:field_sales/features/auth/presentation/sign_up_screen.dart';
import 'package:field_sales/features/onboarding/presentation/create_company_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/fake_auth_repository.dart';

Future<void> pump(WidgetTester tester, FakeAuthRepository repo, Widget screen) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => screen),
    GoRoute(path: '/sign-in', builder: (_, _) => const Scaffold(body: Text('SIGN IN PAGE'))),
    GoRoute(path: '/sign-up', builder: (_, _) => const Scaffold(body: Text('SIGN UP PAGE'))),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: [authRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('wrong email or password says so, and offers creating an account', (tester) async {
    final repo = FakeAuthRepository(wrongPassword: true);
    await pump(tester, repo, const SignInScreen());
    await tester.tap(find.text('Email'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('sign-in-identifier')), 'admin@alpha.com');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'wrongpass');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Wrong email or password. Check them and try again.'), findsOneWidget);
    expect(repo.signedIn, isFalse);
    expect(find.text('New company? Create an account'), findsOneWidget);
  });

  testWidgets('wrong phone or password names the phone, and tells agents who resets it', (tester) async {
    final repo = FakeAuthRepository(wrongPassword: true);
    await pump(tester, repo, const SignInScreen());
    await tester.enterText(find.byKey(const Key('sign-in-identifier')), '024 123 4567');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'wrongpass');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Wrong phone number or password. Check them and try again.'), findsOneWidget);
    expect(find.textContaining('ask your manager to reset it'), findsOneWidget);
  });

  testWidgets('creating an account with a registered email points to sign in instead', (tester) async {
    final repo = FakeAuthRepository(accountExists: true);
    await pump(tester, repo, const SignUpScreen());
    await tester.enterText(find.widgetWithText(TextFormField, 'Work email'), 'admin@alpha.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret123');
    await tester.enterText(find.widgetWithText(TextFormField, 'Type the password again'), 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(find.text('An account with this email already exists. Sign in instead.'), findsOneWidget);
    expect(repo.signedIn, isFalse);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('SIGN IN PAGE'), findsOneWidget);
  });

  testWidgets('mistyped passwords on sign-up are caught before an account is made', (tester) async {
    final repo = FakeAuthRepository();
    await pump(tester, repo, const SignUpScreen());
    await tester.enterText(find.widgetWithText(TextFormField, 'Work email'), 'new@beta.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret123');
    await tester.enterText(find.widgetWithText(TextFormField, 'Type the password again'), 'secret124');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(find.text('The passwords do not match'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  testWidgets('company set-up shows which account is signed in and how to switch', (tester) async {
    final repo = FakeAuthRepository(signedIn: true)..currentEmail = 'typo@alpha.com';
    await pump(tester, repo, const CreateCompanyScreen());
    expect(find.text('Signed in as typo@alpha.com'), findsOneWidget);
    expect(find.textContaining('Joining an existing company?'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Use a different account'));
    await tester.pumpAndSettle();
    expect(repo.signedIn, isFalse);
  });
}
