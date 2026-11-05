import 'package:field_sales/core/design/theme.dart';
import 'package:field_sales/features/dashboard/data/dashboard_repository.dart';
import 'package:field_sales/features/dashboard/presentation/overview_screen.dart';
import 'package:field_sales/features/dashboard/presentation/reports_screen.dart';
import 'package:field_sales/features/members/data/members_repository.dart';
import 'package:field_sales/features/products/data/products_repository.dart';
import 'package:field_sales/features/reports/data/reports_repository.dart';
import 'package:field_sales/features/settings/presentation/company_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final day = DateTime(2026, 11, 4);

AgentToday agent(String name, ReportState state, {num amount = 0, int units = 0, List<TargetProgress> targets = const []}) =>
    AgentToday(
      agentId: name,
      name: name,
      state: state,
      salesCount: units,
      units: units,
      amount: amount,
      missingCounts: 0,
      targets: targets,
      lastReportAt: state == ReportState.none ? null : DateTime(2026, 11, 4, 15, 30),
    );

final sampleOverview = overviewFor(day);

/// The server answers for the requested day, or for its own "today" (`day`).
Overview overviewFor(DateTime date) => Overview(
  date: date,
  today: const Totals(2, 5, 210),
  week: const Totals(9, 30, 1240),
  weekByDay: [for (var i = 6; i >= 0; i--) DayPoint(day.subtract(Duration(days: i)), i * 100)],
  agents: [
    agent('Yaw Boateng', ReportState.none),
    agent('Ama Owusu', ReportState.zeroSales),
    agent('Kofi Mensah', ReportState.withSales, amount: 210, units: 5, targets: const [
      TargetProgress(metric: 'units', target: 10, achieved: 5, progressPct: 50, remaining: 5),
    ]),
  ],
  newCustomersToday: 1,
  newCustomersWeek: 4,
  followUpsDue: 2,
  openDiscrepancies: 1,
  duplicateReviews: 0,
  flaggedSalesToday: 0,
  stockInStore: 120,
  stockWithAgents: 75,
);

class FakeDashboard implements DashboardRepository {
  final patches = <Map<String, Object>>[];
  var settingsValue = const CompanySettings(twiVoiceEnabled: false, khayaMonthlyCalls: 100, maxDiscountPct: 20, khayaCallsUsed: 12);

  final requested = <DateTime?>[];

  @override
  Future<Overview> overview(DateTime? date) async {
    requested.add(date);
    return overviewFor(date ?? day);
  }


  @override
  Future<SalesReport> salesReport(ReportFilter f) async => SalesReport(
        days: 7,
        totals: const Totals(9, 30, 1240),
        byDay: [for (var i = 6; i >= 0; i--) DayPoint(day.subtract(Duration(days: i)), 100.0 + i)],
        byProduct: const [ProductSales('Book A', 20, 1000), ProductSales('Book B', 10, 240)],
        byAgent: const [
          AgentActivity(agentId: 'k', name: 'Kofi Mensah', salesCount: 9, units: 30, amount: 1240, daysReported: 6, zeroSaleDays: 1),
          AgentActivity(agentId: 'y', name: 'Yaw Boateng', salesCount: 0, units: 0, amount: 0, daysReported: 0, zeroSaleDays: 0),
        ],
        customersByDay: [for (var i = 6; i >= 0; i--) DayPoint(day.subtract(Duration(days: i)), 1)],
      );

  @override
  Future<List<ConversationSummary>> conversations(DateTime from, DateTime to) async => const [];

  @override
  Future<List<TranscriptLine>> transcript(String sessionId) async => const [];

  @override
  Future<CompanySettings> settings() async => settingsValue;

  @override
  Future<CompanySettings> updateSettings(Map<String, Object> patch) async {
    patches.add(patch);
    return settingsValue;
  }
}

Future<FakeDashboard> pump(WidgetTester tester, Widget child, {Size size = const Size(1200, 2400)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDashboard();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      dashboardRepositoryProvider.overrideWithValue(fake),
      membersProvider.overrideWith((ref) async => const []),
      productsProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: Scaffold(body: child)),
  ));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('overview: headline figures, who has not reported, and what needs attention', (tester) async {
    await pump(tester, const OverviewScreen());
    expect(find.text('GH₵ 210.00'), findsWidgets);
    expect(find.text('2 of 3'), findsOneWidget, reason: 'agents reported');
    expect(find.text('1 agent has not reported'), findsOneWidget);
    expect(find.text('1 stock count to check'), findsOneWidget);
    expect(find.text('2 customer follow-ups due'), findsOneWidget);

    // Report states use words (and icons), never colour alone.
    expect(find.text('Not reported'), findsOneWidget);
    expect(find.text('Reported, no sales'), findsOneWidget);
    expect(find.text('Reported'), findsOneWidget);
    expect(find.text('Has never reported'), findsOneWidget);
    expect(find.text('Target: 5 of 10 (50%)'), findsOneWidget);
  });

  testWidgets('day navigation: back two, forward two returns to the live "Today" view', (tester) async {
    final fake = await pump(tester, const OverviewScreen());
    Future<void> tap(String label) async {
      await tester.tap(find.widgetWithText(OutlinedButton, label));
      await tester.pumpAndSettle();
    }

    expect(find.text('Today, Wed 4 Nov'), findsOneWidget);
    expect(find.text('Next day'), findsNothing, reason: 'no stepping into the future');

    await tap('Previous day');
    await tap('Previous day');
    expect(find.text('Mon 2 Nov'), findsOneWidget);

    await tap('Next day');
    expect(find.text('Tue 3 Nov'), findsOneWidget);
    await tap('Next day');
    expect(find.text('Today, Wed 4 Nov'), findsOneWidget);
    expect(find.text('Next day'), findsNothing);
    expect(fake.requested.last, isNull, reason: 'back on the live view, not a fixed date');

    await tap('Previous day');
    expect(find.text('Tue 3 Nov'), findsOneWidget);
  });

  testWidgets('overview works on a phone without overflowing', (tester) async {
    await pump(tester, const OverviewScreen(), size: const Size(380, 3000));
    expect(tester.takeException(), isNull);
    expect(find.text('Needs attention'), findsOneWidget);
  });

  testWidgets('reports: charts with a table view, by product, by agent, activity', (tester) async {
    await pump(tester, const ReportsScreen());
    expect(find.text('GH₵ 1,240.00'), findsWidgets);
    expect(find.text('GH₵ 1,000.00 · 20 items'), findsOneWidget);
    expect(find.text('6 of 7'), findsWidgets, reason: 'days worked, in activity and best performers');
    expect(find.text('Best performers'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Show as table').first);
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsWidgets);
    expect(find.text('Show as chart'), findsOneWidget);
  });

  testWidgets('company settings: admins switch on Twi voice and save', (tester) async {
    final fake = await pump(tester, const SingleChildScrollView(child: CompanySettingsCard()));
    expect(find.textContaining('Used this month: 12'), findsOneWidget);
    await tester.tap(find.text('Twi voice for the assistant'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();
    expect(fake.patches.single, {'twi_voice_enabled': true, 'khaya_monthly_calls': 100, 'max_discount_pct': 20});
  });
}
