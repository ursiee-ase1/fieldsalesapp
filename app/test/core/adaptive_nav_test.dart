import 'package:field_sales/core/design/adaptive_nav.dart';
import 'package:field_sales/core/design/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<NavItem> items(int n) => [
      for (var i = 0; i < n; i++) NavItem(label: 'Item $i', icon: Icons.circle_outlined, selectedIcon: Icons.circle),
    ];

Future<List<int>> pumpAt(WidgetTester tester, Size size, int count, {int selected = 0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final chosen = <int>[];
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light(),
    home: AdaptiveNavScaffold(
      items: items(count),
      selectedIndex: selected,
      onSelected: chosen.add,
      body: const Text('body'),
    ),
  ));
  return chosen;
}

void main() {
  testWidgets('phone with few destinations uses a bottom bar', (tester) async {
    await pumpAt(tester, const Size(390, 800), 3);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('phone with many destinations: four in the bar, the rest under "More"', (tester) async {
    final chosen = await pumpAt(tester, const Size(390, 800), 7);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Item 3'), findsOneWidget);
    expect(find.text('Item 4'), findsNothing);
    expect(find.text('More'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Item 6'), findsOneWidget);
    await tester.tap(find.text('Item 5'));
    await tester.pumpAndSettle();
    expect(chosen, [5]);
  });

  testWidgets('a section opened from "More" is named in the bar', (tester) async {
    await pumpAt(tester, const Size(390, 800), 7, selected: 5);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 4, reason: 'the "More" slot is highlighted');
    expect(find.text('Item 5'), findsWidgets, reason: 'and labelled with the open section');
    expect(find.text('More'), findsNothing);
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
