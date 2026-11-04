import 'package:field_sales/core/design/adaptive_nav.dart';
import 'package:field_sales/core/design/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<NavItem> items(int n) => [
      for (var i = 0; i < n; i++) NavItem(label: 'Item $i', icon: Icons.circle_outlined, selectedIcon: Icons.circle),
    ];

Future<void> pumpAt(WidgetTester tester, Size size, int count) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light(),
    home: AdaptiveNavScaffold(
      items: items(count),
      selectedIndex: 0,
      onSelected: (_) {},
      body: const Text('body'),
    ),
  ));
}

void main() {
  testWidgets('phone with few destinations uses a bottom bar', (tester) async {
    await pumpAt(tester, const Size(390, 800), 3);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('phone with many destinations uses a drawer', (tester) async {
    await pumpAt(tester, const Size(390, 800), 7);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDrawer), findsOneWidget);
    expect(find.text('Item 6'), findsOneWidget);
  });

  testWidgets('tablet uses a compact rail', (tester) async {
    await pumpAt(tester, const Size(800, 1000), 7);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isFalse);
  });

  testWidgets('desktop uses an extended rail', (tester) async {
    await pumpAt(tester, const Size(1400, 900), 7);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue);
    expect(tester.takeException(), isNull);
  });
}
