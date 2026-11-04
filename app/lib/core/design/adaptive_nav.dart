import 'package:flutter/material.dart';

import 'tokens.dart';

class NavItem {
  const NavItem({required this.label, required this.icon, required this.selectedIcon});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Navigation that adapts to width:
///  * compact: bottom bar (≤5 items) or a drawer (more items)
///  * medium: navigation rail
///  * expanded: extended navigation rail
class AdaptiveNavScaffold extends StatelessWidget {
  const AdaptiveNavScaffold({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.body,
    this.header,
  });

  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget body;

  /// Shown at the top of the rail or drawer (e.g. company name).
  final Widget? header;

  static const maxBottomBarItems = 5;

  @override
  Widget build(BuildContext context) {
    final size = windowSizeOf(context);
    final title = Text(items[selectedIndex].label);

    if (size == WindowSize.compact) {
      if (items.length <= maxBottomBarItems) {
        return Scaffold(
          appBar: AppBar(title: title),
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            destinations: [
              for (final item in items)
                NavigationDestination(icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: item.label),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: title),
        body: body,
        drawer: NavigationDrawer(
          selectedIndex: selectedIndex,
          onDestinationSelected: (i) {
            Navigator.of(context).pop();
            onSelected(i);
          },
          children: [
            if (header != null)
              Padding(padding: const EdgeInsets.fromLTRB(28, AppSpacing.lg, AppSpacing.lg, AppSpacing.md), child: header),
            for (final item in items)
              NavigationDrawerDestination(icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: Text(item.label)),
          ],
        ),
      );
    }

    final extended = size == WindowSize.expanded;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              extended: extended,
              selectedIndex: selectedIndex,
              onDestinationSelected: onSelected,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              leading: extended && header != null
                  ? SizedBox(width: 200, child: Padding(padding: const EdgeInsets.all(AppSpacing.sm), child: header))
                  : null,
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                      icon: Icon(item.icon), selectedIcon: Icon(item.selectedIcon), label: Text(item.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(appBar: AppBar(title: title), body: body),
            ),
          ],
        ),
      ),
    );
  }
}
