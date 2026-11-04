import 'package:field_sales/core/design/theme.dart';
import 'package:field_sales/features/agent/presentation/agent_home_screen.dart';
import 'package:field_sales/features/products/data/products_repository.dart';
import 'package:field_sales/features/reports/data/reports_repository.dart';
import 'package:field_sales/features/reports/presentation/report_form_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/fake_reports_repository.dart';

void main() {
  late FakeReportsRepository repo;

  Future<void> pumpApp(WidgetTester tester, Widget home, {bool openReport = false}) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: openReport
              ? Center(child: TextButton(onPressed: () => context.push('/report'), child: const Text('open')))
              : home,
        ),
      ),
      GoRoute(path: '/report', builder: (_, _) => const ReportFormScreen()),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reportsRepositoryProvider.overrideWithValue(repo),
        productsProvider.overrideWith((ref) async => [bookA]),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    if (openReport) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }
  }

  group('agent home shows the three report states', () {
    testWidgets('no report', (tester) async {
      repo = FakeReportsRepository(home: agentHome());
      await pumpApp(tester, const AgentHomeScreen());
      expect(find.text("You haven't sent today's report yet."), findsOneWidget);
    });

    testWidgets('zero-sales report', (tester) async {
      repo = FakeReportsRepository(home: agentHome(state: ReportState.zeroSales));
      await pumpApp(tester, const AgentHomeScreen());
      expect(find.textContaining('no sales today'), findsOneWidget);
    });

    testWidgets('report with sales', (tester) async {
      repo = FakeReportsRepository(home: agentHome(state: ReportState.withSales, salesCount: 3));
      await pumpApp(tester, const AgentHomeScreen());
      expect(find.textContaining('Report sent at'), findsOneWidget);
      expect(find.text('GH₵ 150.00'), findsOneWidget);
    });
  });

  testWidgets('a first report needs sales or "no sales" before it can be reviewed', (tester) async {
    repo = FakeReportsRepository(home: agentHome());
    await pumpApp(tester, const SizedBox(), openReport: true);
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tick "I made no sales today"'), findsOneWidget);
    expect(repo.submitted, isEmpty);
  });

  testWidgets('the agent confirms a summary before anything is sent', (tester) async {
    repo = FakeReportsRepository(home: agentHome(stock: const [HeldStock('p-a', 'Book A', 6, 50)]));
    await pumpApp(tester, const SizedBox(), openReport: true);

    await tester.tap(find.text('I made no sales today'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Book A — how many left?'), '5');
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();

    expect(find.text('Check your report'), findsOneWidget);
    expect(find.text('No sales today'), findsOneWidget);
    expect(find.text('Book A: 5'), findsOneWidget);
    expect(repo.submitted, isEmpty, reason: 'nothing is sent before confirmation');

    await tester.tap(find.text('Confirm and send'));
    await tester.pumpAndSettle();
    expect(repo.submitted.single['no_sales'], true);
    expect(repo.submitted.single['stock_counts'], [
      {'product_id': 'p-a', 'quantity': 5},
    ]);
    expect(find.textContaining('Report sent'), findsOneWidget);
  });

  testWidgets('a known phone number asks whether it is the same customer', (tester) async {
    repo = FakeReportsRepository(
      home: agentHome(),
      matches: const [PhoneMatch('cust-1', 'Ama', '024 *** **67')],
    );
    await pumpApp(tester, const SizedBox(), openReport: true);

    await tester.tap(find.text('Add a customer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Full name'), 'Ama Mensah');
    await tester.enterText(find.widgetWithText(TextFormField, 'Phone (optional)'), '0241234567');
    // Moving to another field triggers the lookup.
    await tester.tap(find.widgetWithText(TextFormField, 'Full name'));
    await tester.pumpAndSettle();

    expect(find.text('Is this the same customer?'), findsOneWidget);
    expect(find.textContaining('already associated with Ama'), findsOneWidget);
    await tester.tap(find.text('Yes, it is Ama'));
    await tester.pumpAndSettle();
    expect(find.text('Existing customer: Ama'), findsOneWidget);

    await tester.tap(find.text('I made no sales today'));
    await tester.tap(find.text('Review and send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm and send'));
    await tester.pumpAndSettle();

    final customers = repo.submitted.single['customers'] as List;
    expect(customers.single['customer_id'], 'cust-1');
    expect(customers.single.containsKey('full_name'), isFalse);
  });
}
